"""The lobby over real localhost TCP with fake simulator carts."""

import os
import signal
import subprocess
import sys
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
sys.path.insert(0, HERE)

from badge import frames  # noqa: E402
from badge.lobby import EVERYONE, Lobby, LobbyServer, SimSource  # noqa: E402
from fakecart import FakeCart  # noqa: E402


def last_roster(msgs):
    r = [m for m in msgs if isinstance(m, frames.Roster)]
    return r[-1].players if r else None


def data_of(msgs):
    return [(m.sender, m.data) for m in msgs if isinstance(m, frames.Data)]


class TcpLobbyTest(unittest.TestCase):
    def setUp(self):
        self.carts = []
        self.logs = []
        self.server = LobbyServer(Lobby(log=self.logs.append), log=self.logs.append, stats_interval=0, reopen_delay=0.2)

    def tearDown(self):
        self.server.stop()
        if hasattr(self, "thread"):
            self.thread.join(5)
        for c in self.carts:
            c.close()

    def cart(self, **kw):
        c = FakeCart(**kw)
        self.carts.append(c)
        return c

    def run_server(self):
        src = SimSource([(c.host, c.port) for c in self.carts], interval=0.1)
        self.server.add_source(src)
        self.thread = threading.Thread(target=self.server.run, daemon=True)
        self.thread.start()

    def test_three_carts_two_games(self):
        a = self.cart(game="DOTS", name="alice", max_players=4)
        b = self.cart(game="DOTS", name="bob", max_players=4)
        c = self.cart(game="PONG", name="carol")
        self.run_server()
        a.wait_for(lambda m: last_roster(m) == [(0, "alice"), (1, "bob")] or last_roster(m) == [(0, "bob"), (1, "alice")])
        names = dict((n, i) for i, n in last_roster(a.msgs))
        w = c.wait_for(lambda m: [x for x in m if isinstance(x, frames.Welcome)])[0]
        self.assertEqual((w.you, w.max_players), (0, 16))
        self.assertEqual(c.raw[0], 0)  # leading 0x00 from the lobby

        a.send(0xFF, b"from alice")
        b.wait_for(lambda m: data_of(m) == [(names["alice"], b"from alice")])
        b.send(EVERYONE, b"echo")
        b.wait_for(lambda m: (names["bob"], b"echo") in data_of(m))
        a.wait_for(lambda m: (names["bob"], b"echo") in data_of(m))
        b.send_body(frames.Ping(token=42).pack())
        b.wait_for(lambda m: frames.Pong(token=42) in m)
        time.sleep(0.1)
        self.assertEqual(data_of(c.msgs), [])  # other game hears nothing

    def test_disconnect_and_rejoin(self):
        a = self.cart(game="G", name="a")
        b = self.cart(game="G", name="b")
        self.run_server()
        a.wait_for(lambda m: last_roster(m) is not None and len(last_roster(m)) == 2)
        b.wait_for(lambda m: last_roster(m) is not None and len(last_roster(m)) == 2)
        for i in range(20):
            b.send(0xFF, bytes([i]))
        b.drop_connection()  # simulator quit / cable pulled
        a.wait_for(lambda m: last_roster(m) is not None and len(last_roster(m)) == 1)
        got = [d for _, d in data_of(a.msgs)]
        self.assertEqual(got, [bytes([i]) for i in range(20)])  # all before the ROSTER
        self.assertIsInstance([m for m in a.msgs if isinstance(m, (frames.Data, frames.Roster))][-1], frames.Roster)
        # the lobby reconnects to the simulator, which says HELLO again
        a.wait_for(lambda m: last_roster(m) is not None and len(last_roster(m)) == 2, timeout=5)
        self.assertGreaterEqual(b.connections, 2)

    def test_garbage_and_sixteen_players(self):
        carts = [self.cart(game="BIG", name="p%d" % i) for i in range(17)]
        self.run_server()
        for c in carts:
            c.wait_for(lambda m: [x for x in m if isinstance(x, frames.Welcome)], timeout=10)
        rooms = {}
        for c in carts:
            w = [x for x in c.msgs if isinstance(x, frames.Welcome)][0]
            rooms.setdefault(w.room, []).append(w.you)
        self.assertEqual(sorted(len(v) for v in rooms.values()), [1, 16])
        big = [ids for ids in rooms.values() if len(ids) == 16][0]
        self.assertEqual(sorted(big), list(range(16)))
        # garbage on one port does not hurt anyone
        carts[0].send_raw(b"\xde\xad\xbe\xef" * 100 + b"\x00")
        carts[0].send_body(frames.Ping(token=1).pack())
        carts[0].wait_for(lambda m: frames.Pong(token=1) in m)


class CliLobbyTest(unittest.TestCase):
    def test_cli_lobby_runs_and_stops_cleanly(self):
        a = FakeCart(game="CLI", name="a")
        b = FakeCart(game="CLI", name="b")
        self.addCleanup(a.close)
        self.addCleanup(b.close)
        cmd = [
            sys.executable,
            os.path.join(HERE, "..", "badge.py"),
            "lobby",
            "--no-usb",
            "--sim",
            "%d,%d" % (a.port, b.port),
            "--stats",
            "0.5",
        ]
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
        try:
            a.wait_for(lambda m: last_roster(m) is not None and len(last_roster(m)) == 2, timeout=10)
            a.send(0xFF, b"hi")
            b.wait_for(lambda m: data_of(m), timeout=5)
            time.sleep(0.8)
        finally:
            proc.send_signal(signal.SIGINT)
            out, _ = proc.communicate(timeout=10)
        self.assertEqual(proc.returncode, 0, out)
        self.assertIn("join", out)
        self.assertIn("room 1 opened for CLI", out)
        self.assertIn("stats", out)
        self.assertIn("lobby stopped", out)


if __name__ == "__main__":
    unittest.main()
