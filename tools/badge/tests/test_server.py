"""LobbyServer with in-memory links: threads, hot-plug, overflow, ordering."""

import os
import queue
import sys
import threading
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from badge import frames  # noqa: E402
from badge.links import Link, LinkClosed  # noqa: E402
from badge.lobby import HotplugSource, Lobby, LobbyServer  # noqa: E402


class FakeLink(Link):
    """In-memory link. `deliver` plays bytes from the cart, `got` collects
    what the server wrote. With stall=True, writes block until closed."""

    def __init__(self, key, stall=False):
        super().__init__()
        self.key = key
        self.label = key
        self.stall = stall
        self.inq = queue.Queue()
        self.out = bytearray()
        self.cond = threading.Condition()
        self.dec = frames.FrameDecoder()
        self.msgs = []

    def deliver(self, data):
        self.inq.put(data)

    def hello(self, game="G", name=None, max_players=0):
        self.deliver(frames.encode(frames.Hello(game=game, name=name or self.key, max_players=max_players).pack()))

    def send(self, to, data):
        self.deliver(frames.encode(frames.Send(to=to, data=data).pack()))

    def read(self, timeout=0.2):
        if self.closed:
            raise LinkClosed("closed")
        try:
            data = self.inq.get(timeout=timeout)
        except queue.Empty:
            return b""
        if data is None:
            raise LinkClosed("peer gone")
        return data

    def write(self, data):
        if self.stall:
            with self.cond:
                while not self.closed:
                    self.cond.wait(0.05)
            raise LinkClosed("closed")
        if self.closed:
            raise LinkClosed("closed")
        with self.cond:
            self.out += data
            self.msgs += [frames.unpack(b) for b in self.dec.feed(data)]
            self.cond.notify_all()

    def unplug(self):
        """The peer goes away (reader sees LinkClosed)."""
        self.inq.put(None)

    def close(self):
        with self.cond:
            self.closed = True
            self.cond.notify_all()
        self.inq.put(None)

    def wait_for(self, pred, timeout=5.0):
        end = time.time() + timeout
        with self.cond:
            while True:
                v = pred(self.msgs)
                if v:
                    return v
                left = end - time.time()
                if left <= 0:
                    raise TimeoutError([frames.describe(m) for m in self.msgs])
                self.cond.wait(left)


def roster_ids(msgs):
    r = [m for m in msgs if isinstance(m, frames.Roster)]
    return [i for i, _ in r[-1].players] if r else None


class ServerFixture(unittest.TestCase):
    def start(self, **kw):
        self.logs = []
        kw.setdefault("log", self.logs.append)
        kw.setdefault("stats_interval", 0)
        self.server = LobbyServer(Lobby(log=self.logs.append), **kw)
        self.thread = threading.Thread(target=self.server.run, daemon=True)
        self.thread.start()
        self.addCleanup(self.stop)
        return self.server

    def stop(self):
        self.server.stop()
        self.thread.join(5)
        self.assertFalse(self.thread.is_alive(), "relay thread did not stop")


class ServerTest(ServerFixture):
    def test_leading_zero_and_join(self):
        s = self.start()
        a = FakeLink("a")
        self.assertTrue(s.add_link(a))
        a.hello()
        a.wait_for(lambda m: roster_ids(m) == [0])
        self.assertEqual(a.out[0], 0)  # the lone 0x00 sent on open
        self.assertTrue(s.is_open("a"))

    def test_duplicate_key_refused(self):
        s = self.start()
        a1, a2 = FakeLink("a"), FakeLink("a")
        self.assertTrue(s.add_link(a1))
        self.assertFalse(s.add_link(a2))
        self.assertTrue(a2.closed)

    def test_relay_and_unplug(self):
        s = self.start()
        a, b = FakeLink("a"), FakeLink("b")
        s.add_link(a)
        s.add_link(b)
        a.hello()
        a.wait_for(lambda m: roster_ids(m) == [0])
        b.hello()
        a.wait_for(lambda m: roster_ids(m) == [0, 1])
        for i in range(50):
            a.send(0xFF, bytes([i]))
        a.unplug()
        msgs = b.wait_for(lambda m: m if roster_ids(m) == [1] else None)
        data = [m.data for m in msgs if isinstance(m, frames.Data)]
        self.assertEqual(data, [bytes([i]) for i in range(50)])
        # ROSTER without a comes after all of a's frames
        self.assertIsInstance(msgs[-1], frames.Roster)
        end = time.time() + 2
        while s.is_open("a") and time.time() < end:
            time.sleep(0.01)
        self.assertFalse(s.is_open("a"))
        self.assertFalse(s.may_open("a"))  # reopen delay

    def test_overflow_removes_player(self):
        s = self.start(queue_limit=2000, stall_time=0.1)
        a, b, slow = FakeLink("a"), FakeLink("b"), FakeLink("slow", stall=True)
        for link in (a, b, slow):
            s.add_link(link)
        a.hello()
        a.wait_for(lambda m: roster_ids(m) == [0])
        b.hello()
        a.wait_for(lambda m: roster_ids(m) == [0, 1])
        slow.hello()
        a.wait_for(lambda m: roster_ids(m) == [0, 1, 2])
        for i in range(300):
            a.send(0xFF, b"x" * 20 + bytes([i % 256]))
            if i == 150:
                time.sleep(0.3)  # second wave finds slow's backlog over the limit
        # slow never reads: it is removed, and the others see a ROSTER without it
        a.wait_for(lambda m: roster_ids(m) == [0, 1])
        msgs = b.wait_for(lambda m: m if len([x for x in m if isinstance(x, frames.Data)]) == 300 else None)
        # b lost nothing
        data = [m.data[-1] for m in msgs if isinstance(m, frames.Data)]
        self.assertEqual(data, [i % 256 for i in range(300)])
        self.assertTrue(slow.closed)
        self.assertTrue(any("not reading" in l for l in self.logs), self.logs)

    def test_remove_key(self):
        s = self.start()
        a, b = FakeLink("a"), FakeLink("b")
        s.add_link(a)
        s.add_link(b)
        a.hello()
        a.wait_for(lambda m: roster_ids(m) == [0])
        b.hello()
        a.wait_for(lambda m: roster_ids(m) == [0, 1])
        s.remove_key("b", "badge disappeared")
        a.wait_for(lambda m: roster_ids(m) == [0])
        self.assertTrue(b.closed)


class HotplugTest(ServerFixture):
    def test_hotplug_open_and_vanish(self):
        present = {}
        links = {}

        def scan():
            return dict(present)

        def opener(dev, key, label):
            link = FakeLink(key)
            links[key] = link
            return link

        s = self.start(reopen_delay=0.1)
        src = HotplugSource(interval=0.05, scan_fn=scan, open_fn=opener)
        src.start(s)
        self.addCleanup(src.stop)
        present["usb:AAA"] = ("/dev/fake0", "AAA")
        deadline = time.time() + 3
        while "usb:AAA" not in links and time.time() < deadline:
            time.sleep(0.01)
        a = links["usb:AAA"]
        a.hello()
        a.wait_for(lambda m: roster_ids(m) == [0])
        present["usb:BBB"] = ("/dev/fake1", "BBB")
        while "usb:BBB" not in links and time.time() < deadline:
            time.sleep(0.01)
        b = links["usb:BBB"]
        b.hello()
        a.wait_for(lambda m: roster_ids(m) == [0, 1])
        del present["usb:BBB"]  # unplugged
        a.wait_for(lambda m: roster_ids(m) == [0])
        self.assertTrue(b.closed)
        # comes back: a fresh link, the cart says HELLO again
        present["usb:BBB"] = ("/dev/fake1", "BBB")
        while links["usb:BBB"] is b and time.time() < deadline:
            time.sleep(0.01)
        links["usb:BBB"].hello()
        a.wait_for(lambda m: roster_ids(m) == [0, 1])

    def test_open_failure_retried(self):
        attempts = []

        def opener(dev, key, label):
            attempts.append(key)
            raise LinkClosed("busy")

        s = self.start()
        src = HotplugSource(interval=0.02, scan_fn=lambda: {"usb:X": ("/dev/x", "X")}, open_fn=opener)
        src.start(s)
        self.addCleanup(src.stop)
        deadline = time.time() + 2
        while len(attempts) < 3 and time.time() < deadline:
            time.sleep(0.01)
        self.assertGreaterEqual(len(attempts), 3)
        self.assertEqual(sum("cannot open" in l for l in self.logs), 1)  # logged once


if __name__ == "__main__":
    unittest.main()
