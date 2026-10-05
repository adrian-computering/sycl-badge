"""Lobby state machine: rooms, ids, roster, relay order, leave, errors."""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from badge import frames  # noqa: E402
from badge.lobby import EVERYONE, Lobby  # noqa: E402


class Harness:
    """A Lobby plus decoded per-connection inboxes."""

    def __init__(self, **kw):
        self.lobby = Lobby(**kw)
        self.inbox = {}
        self.decoders = {}

    def connect(self, conn):
        self.lobby.connect(conn, conn)
        self.inbox[conn] = []
        self.decoders[conn] = frames.FrameDecoder()

    def pump(self):
        for conn, data in self.lobby.take_output().items():
            if conn in self.decoders:
                self.inbox[conn] += [frames.unpack(b) for b in self.decoders[conn].feed(data)]

    def body(self, conn, body):
        self.lobby.feed(conn, frames.encode(body))
        self.pump()

    def hello(self, conn, game="DOTS", name=None, max_players=0, version=1):
        if conn not in self.inbox:
            self.connect(conn)
        self.body(conn, frames.Hello(game=game, name=name or conn, max_players=max_players, version=version).pack())
        return self.welcome(conn)

    def send(self, conn, to, data):
        self.body(conn, frames.Send(to=to, data=data).pack())

    def disconnect(self, conn):
        self.lobby.disconnect(conn)
        self.pump()

    def take(self, conn):
        msgs, self.inbox[conn] = self.inbox[conn], []
        return msgs

    def welcome(self, conn):
        w = [m for m in self.inbox[conn] if isinstance(m, frames.Welcome)]
        return w[-1] if w else None

    def roster(self, conn):
        r = [m for m in self.inbox[conn] if isinstance(m, frames.Roster)]
        return r[-1].players if r else None

    def data(self, conn):
        return [(m.sender, m.data) for m in self.inbox[conn] if isinstance(m, frames.Data)]

    def errors(self, conn):
        return [m.code for m in self.inbox[conn] if isinstance(m, frames.Error)]


class RoomTest(unittest.TestCase):
    def test_first_join(self):
        h = Harness()
        w = h.hello("a", max_players=4)
        self.assertEqual((w.version, w.you, w.room, w.max_players), (1, 0, 1, 4))
        msgs = h.take("a")
        self.assertIsInstance(msgs[0], frames.Welcome)  # WELCOME then ROSTER
        self.assertEqual(msgs[1], frames.Roster(players=[(0, "a")]))

    def test_ids_and_roster_to_everyone(self):
        h = Harness()
        h.hello("a")
        h.hello("b")
        h.hello("c")
        self.assertEqual(h.welcome("c").you, 2)
        for c in "abc":
            self.assertEqual(h.roster(c), [(0, "a"), (1, "b"), (2, "c")])

    def test_lowest_free_id_reused(self):
        h = Harness()
        for c in "abc":
            h.hello(c)
        h.disconnect("b")
        self.assertEqual(h.roster("a"), [(0, "a"), (2, "c")])
        self.assertEqual(h.roster("c"), [(0, "a"), (2, "c")])
        self.assertEqual(h.hello("d").you, 1)
        self.assertEqual(h.roster("a"), [(0, "a"), (1, "d"), (2, "c")])

    def test_room_full_opens_new_room(self):
        h = Harness()
        h.hello("a", max_players=2)
        h.hello("b", max_players=2)
        w = h.hello("c", max_players=2)
        self.assertEqual((w.room, w.you), (2, 0))
        self.assertEqual(h.roster("c"), [(0, "c")])
        self.assertEqual(h.roster("a"), [(0, "a"), (1, "b")])
        # a slot frees in room 1: the next player fills it, not room 2
        h.disconnect("b")
        w = h.hello("d", max_players=2)
        self.assertEqual((w.room, w.you), (1, 1))

    def test_room_size_from_first_member(self):
        h = Harness()
        h.hello("a", max_players=3)
        self.assertEqual(h.hello("b", max_players=16).max_players, 3)

    def test_size_default_and_caps(self):
        h = Harness(max_room=6)
        self.assertEqual(h.hello("a", max_players=0).max_players, 6)
        self.assertEqual(h.hello("b", game="X", max_players=1).max_players, 2)
        self.assertEqual(h.hello("c", game="Y", max_players=200).max_players, 6)
        h2 = Harness()
        self.assertEqual(h2.hello("a", max_players=0).max_players, 16)
        self.assertEqual(h2.hello("b", game="X", max_players=99).max_players, 16)

    def test_games_never_mix(self):
        h = Harness()
        wa = h.hello("a", game="DOTS")
        wb = h.hello("b", game="PONG")
        self.assertNotEqual(wa.room, wb.room)
        self.assertEqual(wb.you, 0)
        h.send("a", 0xFF, b"x")
        self.assertEqual(h.data("b"), [])

    def test_room_numbers_reused(self):
        h = Harness()
        h.hello("a", game="A")
        h.hello("b", game="B")
        h.disconnect("a")
        self.assertEqual(h.hello("c", game="C").room, 1)

    def test_lobby_full(self):
        h = Harness()
        for i in range(255):
            self.assertIsNotNone(h.hello("p%d" % i, game="G%d" % i))
        h.connect("late")
        h.body("late", frames.Hello(game="NEW", name="late").pack())
        self.assertEqual(h.errors("late"), [frames.ERR_NO_ROOM])
        self.assertIsNone(h.welcome("late"))


class RejoinLeaveTest(unittest.TestCase):
    def test_rejoin_leaves_old_room_first(self):
        h = Harness()
        h.hello("a")
        h.hello("b")
        h.take("a")
        h.take("b")
        w = h.hello("a")  # same game again, e.g. the cable was replugged
        self.assertEqual(w.room, 1)
        self.assertEqual(w.you, 0)
        # b saw a leave, then a join
        rosters = [m.players for m in h.take("b") if isinstance(m, frames.Roster)]
        self.assertEqual(rosters, [[(1, "b")], [(0, "a"), (1, "b")]])

    def test_hello_other_game_switches(self):
        h = Harness()
        h.hello("a", game="DOTS")
        h.hello("b", game="DOTS")
        w = h.hello("a", game="PONG")
        self.assertEqual((w.room, w.you), (2, 0))
        self.assertEqual(h.roster("b"), [(1, "b")])

    def test_leave_message(self):
        h = Harness()
        h.hello("a")
        h.hello("b")
        h.take("a")
        h.body("a", frames.Leave().pack())
        self.assertEqual(h.roster("b"), [(1, "b")])
        self.assertEqual(h.take("a"), [])  # the leaver gets nothing
        h.send("a", 0xFF, b"x")
        self.assertEqual(h.errors("a"), [frames.ERR_NOT_JOINED])
        self.assertEqual(h.hello("a").you, 0)  # can join again on the same port

    def test_disconnect_empties_room(self):
        h = Harness()
        h.hello("a")
        h.disconnect("a")
        self.assertEqual(h.lobby.rooms, {})
        self.assertEqual(h.lobby.players, {})

    def test_leave_ordering(self):
        """The ROSTER removing a player comes after every frame it sent."""
        h = Harness()
        for c in "abc":
            h.hello(c)
        for c in "abc":
            h.take(c)
        h.lobby.feed("a", b"".join(frames.encode(frames.Send(to=0xFF, data=bytes([i])).pack()) for i in range(5)))
        h.lobby.disconnect("a")
        h.pump()
        for c in "bc":
            msgs = h.take(c)
            self.assertEqual([type(m).__name__ for m in msgs], ["Data"] * 5 + ["Roster"])
            self.assertEqual([m.data for m in msgs[:5]], [bytes([i]) for i in range(5)])
            self.assertEqual(msgs[-1].players, [(1, "b"), (2, "c")])


class RelayTest(unittest.TestCase):
    def setUp(self):
        self.h = Harness()
        for c in "abc":
            self.h.hello(c)
        for c in "abc":
            self.h.take(c)

    def test_broadcast_excludes_sender(self):
        self.h.send("b", 0xFF, b"hi")
        self.assertEqual(self.h.data("a"), [(1, b"hi")])
        self.assertEqual(self.h.data("c"), [(1, b"hi")])
        self.assertEqual(self.h.data("b"), [])

    def test_direct(self):
        self.h.send("a", 2, b"psst")
        self.assertEqual(self.h.data("c"), [(0, b"psst")])
        self.assertEqual(self.h.data("b"), [])

    def test_to_missing_id_dropped(self):
        self.h.send("a", 9, b"void")
        for c in "abc":
            self.assertEqual(self.h.inbox[c], [])
        self.assertEqual(self.h.lobby.dropped_sends, 1)

    def test_empty_data(self):
        self.h.send("a", 0xFF, b"")
        self.assertEqual(self.h.data("b"), [(0, b"")])

    def test_max_data(self):
        self.h.send("a", 1, b"z" * 240)
        self.assertEqual(self.h.data("b"), [(0, b"z" * 240)])

    def test_self_echo_order(self):
        """0xFE: everyone including the sender, all in one room order."""
        h = self.h
        stream = {
            "a": [frames.Send(to=EVERYONE, data=b"a%d" % i).pack() for i in range(3)],
            "b": [frames.Send(to=0xFF, data=b"b%d" % i).pack() for i in range(3)],
            "c": [frames.Send(to=EVERYONE, data=b"c%d" % i).pack() for i in range(3)],
        }
        order = []
        for i in range(3):
            for c in "abc":
                h.lobby.feed(c, frames.encode(stream[c][i]))
                order.append((c, i))
        h.pump()
        ids = {"a": 0, "b": 1, "c": 2}
        global_order = [(ids[c], b"%s%d" % (c.encode(), i)) for c, i in order]
        for c in "abc":
            # everyone sees the global order, minus b's own 0xFF frames for b
            expect = [d for d in global_order if not (c == "b" and d[0] == 1)]
            self.assertEqual(h.data(c), expect, c)

    def test_send_to_self_by_id(self):
        self.h.send("a", 0, b"me")
        self.assertEqual(self.h.data("a"), [(0, b"me")])

    def test_relay_bytes_shared_per_frame(self):
        self.h.send("a", 0xFF, b"q")
        self.assertEqual(self.h.lobby.players["a"].sends, 1)
        self.assertEqual(self.h.lobby.players["b"].rx, 1)  # the HELLO only


class ErrorTest(unittest.TestCase):
    def test_send_before_welcome(self):
        h = Harness()
        h.connect("a")
        h.send("a", 0xFF, b"x")
        self.assertEqual(h.errors("a"), [frames.ERR_NOT_JOINED])

    def test_leave_before_welcome(self):
        h = Harness()
        h.connect("a")
        h.body("a", frames.Leave().pack())
        self.assertEqual(h.errors("a"), [frames.ERR_NOT_JOINED])

    def test_bad_version(self):
        h = Harness()
        h.connect("a")
        self.assertIsNone(h.hello("a", version=2))
        self.assertEqual(h.errors("a"), [frames.ERR_VERSION])

    def test_malformed(self):
        h = Harness()
        h.connect("a")
        h.body("a", b"\x01\x01DO")
        h.body("a", b"\x03\x01")
        self.assertEqual(h.errors("a"), [frames.ERR_MALFORMED, frames.ERR_MALFORMED])

    def test_unknown_ignored(self):
        h = Harness()
        h.hello("a")
        h.take("a")
        h.body("a", b"\x42whatever")
        h.body("a", frames.Welcome().pack())  # host-only type from a cart: ignored
        self.assertEqual(h.take("a"), [])
        self.assertEqual(h.lobby.unknown, 2)

    def test_ping_any_time(self):
        h = Harness()
        h.connect("a")
        h.body("a", frames.Ping(token=0xDEADBEEF).pack())
        self.assertEqual(h.take("a"), [frames.Pong(token=0xDEADBEEF)])

    def test_garbage_then_hello(self):
        h = Harness()
        h.connect("a")
        h.lobby.feed("a", b"\x13\x37garbage\x00")
        h.pump()
        self.assertIsNotNone(h.hello("a"))


if __name__ == "__main__":
    unittest.main()
