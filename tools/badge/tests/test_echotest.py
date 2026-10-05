import os
import socket
import sys
import threading
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from badge import echotest  # noqa: E402
from badge.links import SocketLink  # noqa: E402


def echo_peer(sock, corrupt_after=None):
    seen = 0
    try:
        while True:
            data = sock.recv(4096)
            if not data:
                return
            if corrupt_after is not None and seen <= corrupt_after < seen + len(data):
                i = corrupt_after - seen
                data = data[:i] + b"\x00" + data[i + 1 :]
            seen += len(data)
            sock.sendall(data)
    except OSError:
        pass


class EchoTestTest(unittest.TestCase):
    def run_against(self, **peer_kw):
        a, b = socket.socketpair()
        self.addCleanup(a.close)
        self.addCleanup(b.close)
        threading.Thread(target=echo_peer, args=(b,), kwargs=peer_kw, daemon=True).start()
        lines = []
        rc = echotest.run(SocketLink(a, key="t"), rate=200, size=16, seconds=0.5, out=lines.append)
        return rc, lines

    def test_clean_echo(self):
        rc, lines = self.run_against()
        self.assertEqual(rc, 0, lines)
        self.assertIn("lost 0, out of order/corrupt 0", lines[1])
        self.assertIn("round trip: p50", lines[2])

    def test_corruption_is_reported(self):
        # flip the magic byte of a record well after the probe
        rc, lines = self.run_against(corrupt_after=8 + 16 * 20)  # 8-byte probe, then record 20
        self.assertEqual(rc, 1, lines)
        self.assertNotIn("corrupt 0", lines[1])

    def test_no_echo(self):
        a, b = socket.socketpair()
        self.addCleanup(a.close)
        self.addCleanup(b.close)
        lines = []
        rc = echotest.run(SocketLink(a, key="t"), seconds=0.2, out=lines.append)
        self.assertEqual(rc, 1)
        self.assertIn("no echo", lines[0])


if __name__ == "__main__":
    unittest.main()
