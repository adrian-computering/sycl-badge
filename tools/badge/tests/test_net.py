"""Network lobby (badge.net): a real LobbyServer hub, joiners, fake carts.

Run: python3 -m unittest discover tools/badge/tests
Real tailcat end to end (needs tailcat + internet): BADGE_TEST_TAILCAT=1
"""

import argparse
import os
import socket
import stat
import sys
import tempfile
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
sys.path.insert(0, HERE)

from badge import frames, net  # noqa: E402
from badge.links import open_link  # noqa: E402
from badge.lobby import Lobby, LobbyServer, SimSource  # noqa: E402
from fakecart import FakeCart  # noqa: E402

WAIT = 5.0


def until(pred, timeout=WAIT):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if pred():
            return True
        time.sleep(0.01)
    return False


def roster(cart):
    r = cart.of(frames.Roster)
    return sorted(n for _, n in r[-1].players) if r else None


def data_of(cart):
    return [m.data for m in cart.of(frames.Data)]


class Hub:
    """`badge lobby --listen` in-process: LobbyServer + ListenSource (+ local sims)."""

    def __init__(self, port=0, local=()):
        self.logs = []
        self.server = LobbyServer(Lobby(log=self.logs.append), log=self.logs.append,
                                  stats_interval=0, reopen_delay=0.2)
        self.src = net.ListenSource("127.0.0.1", port)
        self.port = self.src.port
        self.server.add_source(self.src)
        if local:
            self.server.add_source(SimSource([(c.host, c.port) for c in local], interval=0.1))
        self.thread = threading.Thread(target=self.server.run, daemon=True)
        self.thread.start()

    def close(self):
        self.src.stop()
        self.server.stop()
        self.thread.join(WAIT)


def fast_joiner(connect, carts, events=None, **kw):
    found = {"sim:%d" % c.port: "socket://127.0.0.1:%d" % c.port for c in carts}
    opts = dict(scan_interval=0.05, backoff_min=0.05, backoff_max=0.2, handshake=1.0)
    opts.update(kw)
    j = net.Joiner(connect, lambda: dict(found),
                   lambda key, url: open_link(url, key=key, timeout=0.5),
                   on_event=(events.append if events is not None else lambda e: None), **opts)
    j.found = found
    stop = threading.Event()
    t = threading.Thread(target=j.run, args=(stop,), daemon=True)
    t.start()
    j.stop_all = lambda: (stop.set(), t.join(WAIT))
    return j


class HostPortTest(unittest.TestCase):
    def test_parse(self):
        p = net.parse_hostport
        self.assertEqual(p(""), ("127.0.0.1", 7360))
        self.assertEqual(p("7400"), ("127.0.0.1", 7400))
        self.assertEqual(p("0.0.0.0:7361"), ("0.0.0.0", 7361))
        self.assertEqual(p("laptop.local"), ("laptop.local", 7360))
        self.assertEqual(p(":7362"), ("127.0.0.1", 7362))
        self.assertEqual(p("[::1]:7363"), ("::1", 7363))

    def test_tailcat_address(self):
        self.assertTrue(net.is_tailcat_address("tcpGFwWCD3xe_Yo2c8aY1vPKrHvbfzS-XBdsBbGhsOfYXXFX5LQ2FrW"))
        self.assertFalse(net.is_tailcat_address("laptop.local:7360"))
        self.assertFalse(net.is_tailcat_address("tc"))


class PingerTest(unittest.TestCase):
    def test_own_pongs_removed_everything_else_kept(self):
        p = net._Pinger(7)
        other = frames.encode(frames.Pong(token=8).pack())  # the cart's own PING reply
        data = frames.encode(frames.Data(sender=1, data=b"\x00hi").pack())
        stream = b"\x00" + p.pong + data + p.pong + other
        self.assertEqual(p.filter(stream), b"\x00" + data + other)
        self.assertEqual(p.pongs, 2)

    def test_split_frames_held_until_complete(self):
        p = net._Pinger(7)
        data = frames.encode(frames.Data(sender=2, data=b"abc").pack())
        stream = data + p.pong + data
        out = b"".join(p.filter(stream[i:i + 1]) for i in range(len(stream)))
        self.assertEqual(out, data + data)
        self.assertEqual(p.pongs, 1)


class NetLobbyTest(unittest.TestCase):
    def setUp(self):
        self.carts, self.joiners, self.hubs, self.events = [], [], [], []

    def tearDown(self):
        for j in self.joiners:
            j.stop_all()
        for h in self.hubs:
            h.close()
        for c in self.carts:
            c.close()

    def cart(self, **kw):
        c = FakeCart(**kw)
        self.carts.append(c)
        return c

    def hub(self, **kw):
        h = Hub(**kw)
        self.hubs.append(h)
        return h

    def join(self, port, carts, **kw):
        j = fast_joiner(net.tcp_connector("127.0.0.1", port), carts, self.events, **kw)
        self.joiners.append(j)
        return j

    def test_local_and_remote_players_share_a_room(self):
        home = self.cart(game="DOTS", name="home")
        h = self.hub(local=[home])
        r1 = self.cart(game="DOTS", name="remote1")
        r2 = self.cart(game="DOTS", name="remote2")
        self.join(h.port, [r1])
        self.join(h.port, [r2])  # a second joiner computer
        everyone = ["home", "remote1", "remote2"]
        for c in (home, r1, r2):
            c.wait_for(lambda m, c=c: roster(c) == everyone)
        for i in range(30):
            r1.send(0xFF, bytes([i]))
        home.wait_for(lambda m: len(data_of(home)) == 30)
        r2.wait_for(lambda m: len(data_of(r2)) == 30)
        self.assertEqual(data_of(home), [bytes([i]) for i in range(30)])  # order kept
        self.assertEqual(data_of(r2), data_of(home))
        home.send(0xFF, b"back")
        r1.wait_for(lambda m: b"back" in data_of(r1))
        self.assertTrue(any(k.startswith("net:") for k in h.server.open_keys()))

    def test_hub_restart_rejoins(self):
        h = self.hub()
        a, b = self.cart(game="G", name="a"), self.cart(game="G", name="b")
        self.join(h.port, [a, b])
        a.wait_for(lambda m: roster(a) == ["a", "b"])
        port = h.port
        h.close()
        self.hubs.remove(h)
        # carts see the host go away while the hub is down
        self.assertTrue(until(lambda: a.conn is None and b.conn is None))
        time.sleep(0.3)
        self.assertIsNone(a.conn, "cart port must stay closed while the hub is down")
        self.hub(port=port)
        self.assertTrue(until(lambda: a.connections >= 2 and b.connections >= 2))
        a.wait_for(lambda m: len(a.of(frames.Welcome)) >= 2 and roster(a) == ["a", "b"])

    def test_no_hub_no_port(self):
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        dead = s.getsockname()[1]
        s.close()
        a = self.cart(name="a")
        troubles = []
        self.join(dead, [a], hub_trouble=lambda: troubles.append(1))
        time.sleep(0.5)
        self.assertEqual(a.connections, 0)
        self.assertGreater(len(troubles), 0, "a lost hub is reported (tailcat tunnels restart)")

    def test_tunnel_up_but_hub_down_keeps_port_closed(self):
        # tailcat's local end accepts even when the hub is gone; the handshake catches it
        mute = socket.socket()
        mute.bind(("127.0.0.1", 0))
        mute.listen(8)
        self.addCleanup(mute.close)
        a = self.cart(name="a")
        self.join(mute.getsockname()[1], [a], handshake=0.2)
        time.sleep(0.8)
        self.assertEqual(a.connections, 0)
        self.assertTrue(any("no answer from hub" in e.detail for e in self.events))

    def test_hub_goes_silent_closes_port(self):
        # answers the handshake PING, then never says anything again
        srv = socket.socket()
        srv.bind(("127.0.0.1", 0))
        srv.listen(8)
        self.addCleanup(srv.close)
        held = []

        def fake_hub():
            while True:
                try:
                    c, _ = srv.accept()
                except OSError:
                    return
                held.append(c)
                dec = frames.FrameDecoder()
                while True:
                    buf = c.recv(4096)
                    if not buf:
                        break
                    pings = [b for b in dec.feed(buf) if b[0] == frames.PING]
                    if pings:
                        c.sendall(frames.encode(frames.Pong(token=frames.unpack(pings[0]).token).pack()))
                        break
        threading.Thread(target=fake_hub, daemon=True).start()
        a = self.cart(name="a")
        self.join(srv.getsockname()[1], [a], heartbeat=0.1, dead_after=0.3)
        self.assertTrue(until(lambda: a.connections >= 1))
        self.assertTrue(until(lambda: any("hub silent" in e.detail for e in self.events)))
        for c in held:
            c.close()

    def test_heartbeat_pongs_never_reach_the_cart(self):
        h = self.hub()
        a = self.cart(game="G", name="a")
        self.join(h.port, [a], heartbeat=0.05, dead_after=1.0)
        a.wait_for(lambda m: roster(a) == ["a"])
        time.sleep(0.6)  # ~10 heartbeats
        self.assertEqual(a.of(frames.Pong), [])
        a.send_body(frames.Ping(token=99).pack())  # the cart's own ping still works
        a.wait_for(lambda m: frames.Pong(token=99) in m)
        self.assertIsNotNone(a.conn)

    def test_simulator_quits_player_leaves(self):
        h = self.hub()
        a, b = self.cart(game="G", name="a"), self.cart(game="G", name="b")
        j = self.join(h.port, [a, b])
        a.wait_for(lambda m: roster(a) == ["a", "b"])
        del j.found["sim:%d" % b.port]
        b.close()
        a.wait_for(lambda m: roster(a) == ["a"])
        self.assertTrue(until(lambda: any(e.kind == "removed" for e in self.events)))


FAKE_TAILCAT = r"""#!/usr/bin/env python3
import os, sys, time
mode = os.environ.get("FAKE_TAILCAT_MODE", "ok")
cmd = sys.argv[1]
if os.environ.get("FAKE_TAILCAT_LOG"):
    with open(os.environ["FAKE_TAILCAT_LOG"], "a") as f:
        f.write(cmd + "\n")
if mode == "die":
    print("2026/10/05 boom: no DERP", file=sys.stderr); sys.exit(1)
if cmd == "serve":
    print("# Selected bootstrap relay region 302, San Francisco", file=sys.stderr)
    print("# \U0001F408 Server listening with new address: tcFAKEaddrFAKEaddrFAKEaddrFAKEaddr0123", file=sys.stderr)
elif cmd == "forward":
    print("# forwarding 127.0.0.1:%s -> remote localhost:%s" % (os.environ["FAKE_TAILCAT_LOCAL"], sys.argv[3].split(":")[1]), file=sys.stderr)
elif cmd == "ping":
    print("pong in 22.9ms via DERP(sfo)"); print("pong in 580µs via 10.0.0.2:41641"); sys.exit(0)
sys.stderr.flush()
time.sleep(60)
"""

ADDR = "tcFAKEaddrFAKEaddrFAKEaddrFAKEaddr0123"


def join_args(target, **kw):
    a = argparse.Namespace(target=target, remote_port=net.DEFAULT_PORT, sim="none", no_sim=False,
                           no_usb=True, port=None, tailcat_bin=None)
    for k, v in kw.items():
        setattr(a, k, v)
    return a


class TailcatTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.bin = os.path.join(self.dir.name, "tailcat")
        with open(self.bin, "w") as f:
            f.write(FAKE_TAILCAT)
        os.chmod(self.bin, os.stat(self.bin).st_mode | stat.S_IEXEC)
        os.environ["FAKE_TAILCAT_MODE"] = "ok"

    def tearDown(self):
        self.dir.cleanup()

    def test_serve_parses_address(self):
        p, addr = net.Tailcat(self.bin).serve(7360)
        try:
            self.assertEqual(addr, ADDR)
            self.assertIn("--key=new", p.argv)
            self.assertTrue(p.alive())
        finally:
            p.close()
        self.assertFalse(p.alive())

    def test_serve_saved_key(self):
        p, _ = net.Tailcat(self.bin).serve(7360, key="show")
        p.close()
        self.assertIn("--key=show", p.argv)

    def test_forward_parses_local_port(self):
        os.environ["FAKE_TAILCAT_LOCAL"] = "43303"
        p, host, port = net.Tailcat(self.bin).forward(ADDR, 7360)
        p.close()
        self.assertEqual((host, port), ("127.0.0.1", 43303))
        self.assertEqual(p.argv[-1], "0:7360")

    def test_path(self):
        self.assertEqual(net.Tailcat(self.bin).path("tcX"), "direct via 10.0.0.2:41641, 580µs")

    def test_early_exit_is_an_error(self):
        os.environ["FAKE_TAILCAT_MODE"] = "die"
        with self.assertRaises(net.TailcatError) as cm:
            net.Tailcat(self.bin).serve(7360)
        self.assertIn("no DERP", str(cm.exception))

    def test_missing_binary(self):
        old_path, old_home = os.environ["PATH"], os.environ.get("HOME")
        os.environ["PATH"] = self.dir.name + "/nowhere"
        os.environ["HOME"] = self.dir.name
        try:
            with self.assertRaises(net.TailcatMissing):
                net.Tailcat()
        finally:
            os.environ["PATH"] = old_path
            if old_home is not None:
                os.environ["HOME"] = old_home

    def test_tunnel_restarts_on_trouble(self):
        logf = os.path.join(self.dir.name, "calls")
        os.environ["FAKE_TAILCAT_LOG"] = logf
        os.environ["FAKE_TAILCAT_LOCAL"] = "43303"
        logs = []
        try:
            t = net.TailcatTunnel(net.Tailcat(self.bin), ADDR, 7360, logs.append, min_age=0.3)
            t.trouble()  # too soon after start: ignored (many sessions report at once)
            self.assertEqual(t.restarts, 0)
            time.sleep(0.35)
            t.trouble()
            t.trouble()
            self.assertEqual(t.restarts, 1)
            t._proc.close()  # tailcat died: the next connect starts a new one
            with self.assertRaises(OSError):
                t.connect()  # nothing listens on the fake local port
            self.assertEqual(t.restarts, 2)
            t.close()
            self.assertIsNone(t._proc)
            with open(logf) as f:
                self.assertEqual(f.read().split(), ["forward"] * 3)
            self.assertTrue(any("restarting the tailcat tunnel" in l for l in logs))
        finally:
            del os.environ["FAKE_TAILCAT_LOG"]

    def test_lobby_flags_print_join_line(self):
        server = argparse.Namespace(add_source=lambda src: None)
        logs = []
        args = argparse.Namespace(listen="127.0.0.1:0", tailcat=True, tailcat_key=None, tailcat_bin=self.bin)
        cleanup = net.start_lobby_network(args, server, logs.append)
        cleanup()
        self.assertTrue(any("badge join " + ADDR in l for l in logs), logs)
        self.assertTrue(any("--remote-port" in l for l in logs), "port 0 is not the default port")

    def test_cmd_join_over_fake_tunnel(self):
        h = Hub()
        a = FakeCart(game="G", name="far")
        os.environ["FAKE_TAILCAT_LOCAL"] = str(h.port)  # the "tunnel" goes straight to the hub
        logs, stop = [], threading.Event()
        args = join_args(ADDR, port=["socket://127.0.0.1:%d" % a.port], tailcat_bin=self.bin)
        t = threading.Thread(target=net.cmd_join, args=(args,), kwargs=dict(log=logs.append, stop=stop), daemon=True)
        t.start()
        try:
            a.wait_for(lambda m: roster(a) == ["far"])
            self.assertTrue(until(lambda: any("tailcat path: direct" in l for l in logs)))
            self.assertTrue(any("in the lobby" in l for l in logs), logs)
        finally:
            stop.set()
            t.join(WAIT)
            h.close()
            a.close()
        self.assertFalse(t.is_alive())


@unittest.skipUnless(os.environ.get("BADGE_TEST_TAILCAT"), "set BADGE_TEST_TAILCAT=1 (needs tailcat + internet)")
class RealTailcatTest(unittest.TestCase):
    """`badge lobby --listen --tailcat` hub; `badge join tc...` through real tailcat."""

    def test_end_to_end(self):
        home = FakeCart(game="DOTS", name="home")
        server = LobbyServer(Lobby(log=lambda m: None), log=lambda m: None, stats_interval=0, reopen_delay=0.2)
        server.add_source(SimSource([(home.host, home.port)], interval=0.1))
        logs, stop = [], threading.Event()
        args = argparse.Namespace(listen="127.0.0.1:0", tailcat=True, tailcat_key=None, tailcat_bin=None)
        cleanup = net.start_lobby_network(args, server, logs.append)
        hub_thread = threading.Thread(target=server.run, daemon=True)
        hub_thread.start()
        line = next(l for l in logs if "badge join " in l).split("badge join ")[1].split()
        addr, port = line[0], int(line[2])
        farA, farB = FakeCart(game="DOTS", name="farA"), FakeCart(game="DOTS", name="farB")
        jargs = join_args(addr, remote_port=port,
                          port=["socket://127.0.0.1:%d" % c.port for c in (farA, farB)])
        t = threading.Thread(target=net.cmd_join, args=(jargs,), kwargs=dict(log=logs.append, stop=stop), daemon=True)
        t.start()
        try:
            for c in (home, farA, farB):
                c.wait_for(lambda m, c=c: roster(c) == ["farA", "farB", "home"], timeout=30)
            farA.send(0xFF, b"over-the-tunnel")
            home.wait_for(lambda m: b"over-the-tunnel" in data_of(home), timeout=10)
            farB.wait_for(lambda m: b"over-the-tunnel" in data_of(farB), timeout=10)
            self.assertTrue(until(lambda: any(l.startswith("tailcat path:") for l in logs), 20))
            print("\n" + "\n".join(l for l in logs if "path" in l))
        finally:
            stop.set()
            t.join(WAIT)
            cleanup()
            server.stop()
            hub_thread.join(WAIT)
            for c in (home, farA, farB):
                c.close()


if __name__ == "__main__":
    unittest.main()
