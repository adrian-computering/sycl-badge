"""Tests for badge.net (network lobby). Run: python3 -m unittest discover tools/badge/tests"""

import os
import queue
import socket
import stat
import sys
import tempfile
import threading
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from badge import net  # noqa: E402

WAIT = 5.0


def until(pred, timeout=WAIT):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if pred():
            return True
        time.sleep(0.01)
    return False


class FakePort:
    """A cart serial port: the test plays the cart through `to_host` / `from_host`."""

    def __init__(self, registry):
        self.to_host = queue.Queue()
        self.from_host = bytearray()
        self.closed = False
        self.fail = None
        registry.append(self)

    def read(self, n, timeout):
        if self.fail:
            raise self.fail
        if self.closed:
            raise OSError("closed")
        try:
            return self.to_host.get(timeout=timeout)
        except queue.Empty:
            return b""

    def write(self, data):
        if self.fail:
            raise self.fail
        self.from_host += data

    def close(self):
        self.closed = True


class FakeHub:
    """Accepts joiner streams; records bytes per connection and can reply."""

    def __init__(self, port=0):
        self.listener = net.Listener("127.0.0.1", port)
        self.port = self.listener.port
        self.conns = []
        self.data = {}
        self._stop = threading.Event()
        self._t = threading.Thread(target=self._accept, daemon=True)
        self._t.start()

    def _accept(self):
        while not self._stop.is_set():
            c = self.listener.accept(0.05)
            if c is None:
                continue
            i = len(self.conns)
            self.conns.append(c)
            self.data[i] = bytearray()
            threading.Thread(target=self._read, args=(i, c), daemon=True).start()

    def _read(self, i, c):
        try:
            while d := c.recv(4096):
                self.data[i] += d
        except OSError:
            pass
        self.data[i] += b"<EOF>"

    def close(self):
        self._stop.set()
        self._t.join()
        self.listener.close()
        for c in self.conns:
            try:
                c.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            c.close()


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


class JoinerTest(unittest.TestCase):
    def setUp(self):
        self.hub = FakeHub()
        self.ports = []
        self.found = {"badge-A": "A"}
        self.events = []
        self.joiner = net.Joiner(
            net.tcp_connector("127.0.0.1", self.hub.port),
            lambda: dict(self.found),
            lambda desc: FakePort(self.ports),
            on_event=self.events.append,
            scan_interval=0.05, backoff_min=0.05, backoff_max=0.2)
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self.joiner.run, args=(self.stop,), daemon=True)
        self.thread.start()

    def tearDown(self):
        self.stop.set()
        self.thread.join(WAIT)
        self.hub.close()

    def kinds(self, key="badge-A"):
        return [e.kind for e in self.events if e.key == key]

    def test_bytes_pass_through_both_ways(self):
        self.assertTrue(until(lambda: self.ports and self.hub.conns))
        port, conn = self.ports[0], self.hub.conns[0]
        port.to_host.put(b"\x02hello\x00")
        self.assertTrue(until(lambda: self.hub.data[0] == b"\x00\x02hello\x00"))
        conn.sendall(b"\x03from-hub\x00")
        self.assertTrue(until(lambda: port.from_host == b"\x00\x03from-hub\x00"))

    def test_hub_restart_cycles_the_port(self):
        self.assertTrue(until(lambda: self.ports and self.hub.conns))
        old = self.hub.port
        self.hub.close()
        # Cart must see the host go away while the hub is down.
        self.assertTrue(until(lambda: self.ports[0].closed))
        self.assertTrue(until(lambda: "disconnected" in self.kinds()))
        self.hub = FakeHub(old)
        self.assertTrue(until(lambda: len(self.ports) == 2 and self.hub.conns))
        self.assertFalse(self.ports[1].closed)
        self.ports[1].to_host.put(b"\x01again\x00")
        self.assertTrue(until(lambda: self.hub.data[0].endswith(b"\x01again\x00")))

    def test_unreachable_hub_keeps_port_closed(self):
        old = self.hub.port
        self.hub.close()
        self.assertTrue(until(lambda: self.ports and self.ports[-1].closed))
        n = len(self.ports)
        time.sleep(0.3)
        self.assertEqual(len(self.ports), n, "port must not reopen while the hub is down")

    def test_port_failure_ends_session_and_hub_sees_leave(self):
        self.assertTrue(until(lambda: self.ports and self.hub.conns))
        self.found.clear()  # unplugged: discovery no longer lists it
        self.ports[0].fail = OSError("device disconnected")
        self.assertTrue(until(lambda: self.hub.data[0].endswith(b"<EOF>")))
        self.assertTrue(until(lambda: "removed" in self.kinds()))

    def test_hot_plug(self):
        self.assertTrue(until(lambda: len(self.hub.conns) == 1))
        self.found["badge-B"] = "B"
        self.assertTrue(until(lambda: len(self.hub.conns) == 2))
        del self.found["badge-A"]
        self.assertTrue(until(lambda: self.hub.data[0].endswith(b"<EOF>")))
        self.assertFalse(self.hub.data[1].endswith(b"<EOF>"))


FAKE_TAILCAT = r"""#!/usr/bin/env python3
import os, sys, time
mode = os.environ.get("FAKE_TAILCAT_MODE", "ok")
cmd = sys.argv[1]
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
            self.assertEqual(addr, "tcFAKEaddrFAKEaddrFAKEaddrFAKEaddr0123")
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
        p, host, port = net.Tailcat(self.bin).forward("tcFAKEaddrFAKEaddrFAKEaddrFAKEaddr0123", 7360)
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
        old = os.environ["PATH"]
        os.environ["PATH"] = self.dir.name + "/nowhere"
        try:
            home = os.environ.get("HOME")
            os.environ["HOME"] = self.dir.name
            with self.assertRaises(net.TailcatMissing):
                net.Tailcat()
        finally:
            os.environ["PATH"] = old
            if home is not None:
                os.environ["HOME"] = home

    def test_join_command_over_fake_tunnel(self):
        hub = FakeHub()
        os.environ["FAKE_TAILCAT_LOCAL"] = str(hub.port)  # "tunnel" = straight to the hub
        ports, log, stop = [], [], threading.Event()
        t = threading.Thread(target=net.join_command, kwargs=dict(
            target="tcFAKEaddrFAKEaddrFAKEaddrFAKEaddr0123",
            discover=lambda: {"badge-A": 1}, open_port=lambda d: FakePort(ports),
            tailcat_bin=self.bin, log=log.append, stop=stop), daemon=True)
        t.start()
        try:
            self.assertTrue(until(lambda: ports and hub.conns))
            ports[0].to_host.put(b"\x03ping\x00")
            self.assertTrue(until(lambda: hub.data[0].endswith(b"\x03ping\x00")))
            self.assertTrue(until(lambda: any("tailcat path: direct" in l for l in log)))
        finally:
            stop.set()
            t.join(WAIT)
            hub.close()
        self.assertFalse(t.is_alive())


@unittest.skipUnless(os.environ.get("BADGE_TEST_TAILCAT"), "set BADGE_TEST_TAILCAT=1 (needs tailcat + internet)")
class RealTailcatTest(unittest.TestCase):
    """Hub listener served by real `tailcat serve`, joiner through real `tailcat forward`."""

    def test_end_to_end(self):
        hub = FakeHub()
        serve, addr = net.start_hub_tailcat(hub.port)
        ports, log, stop = [], [], threading.Event()
        t = threading.Thread(target=net.join_command, kwargs=dict(
            target=addr, discover=lambda: {"A": 1, "B": 2},
            open_port=lambda d: FakePort(ports), remote_port=hub.port,
            log=log.append, stop=stop), daemon=True)
        t.start()
        try:
            self.assertTrue(until(lambda: len(ports) == 2 and len(hub.conns) == 2, 30))
            ports[0].to_host.put(b"\x02over-the-tunnel\x00")
            self.assertTrue(until(lambda: any(d.endswith(b"\x02over-the-tunnel\x00")
                                              for d in hub.data.values()), 10))
            hub.conns[1].sendall(b"\x83back\x00")
            self.assertTrue(until(lambda: any(p.from_host.endswith(b"\x83back\x00") for p in ports), 10))
            self.assertTrue(until(lambda: any(l.startswith("tailcat path:") for l in log), 20))
            print("\n" + "\n".join(l for l in log if "path" in l))
        finally:
            stop.set()
            t.join(WAIT)
            serve.close()
            hub.close()


if __name__ == "__main__":
    unittest.main()
