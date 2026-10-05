import os
import random
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from badge import frames  # noqa: E402
from badge.frames import FrameDecoder, cobs_decode, cobs_encode  # noqa: E402

# (decoded, encoded) pairs from the COBS paper / Wikipedia examples
VECTORS = [
    (b"", b"\x01"),
    (b"\x00", b"\x01\x01"),
    (b"\x00\x00", b"\x01\x01\x01"),
    (b"\x00\x11\x00", b"\x01\x02\x11\x01"),
    (b"\x11\x22\x00\x33", b"\x03\x11\x22\x02\x33"),
    (b"\x11\x22\x33\x44", b"\x05\x11\x22\x33\x44"),
    (b"\x11\x00\x00\x00", b"\x02\x11\x01\x01\x01"),
    (bytes(range(1, 255)), b"\xff" + bytes(range(1, 255)) + b"\x01"),
    (bytes(range(0, 255)), b"\x01\xff" + bytes(range(1, 255)) + b"\x01"),
    (bytes(range(1, 256)), b"\xff" + bytes(range(1, 255)) + b"\x02\xff"),
    (bytes(range(2, 256)) + b"\x00", b"\xff" + bytes(range(2, 256)) + b"\x01\x01"),
    (bytes(range(3, 256)) + b"\x00\x01", b"\xfe" + bytes(range(3, 256)) + b"\x02\x01"),
]


class CobsTest(unittest.TestCase):
    def test_vectors(self):
        for dec, enc in VECTORS:
            self.assertEqual(cobs_encode(dec), enc, dec.hex())
            self.assertEqual(cobs_decode(enc), dec, enc.hex())

    def test_fuzz_round_trip(self):
        rng = random.Random(1234)
        for _ in range(3000):
            n = rng.randrange(0, 600)
            zeros = rng.random()
            data = bytes(0 if rng.random() < zeros else rng.randrange(1, 256) for _ in range(n))
            enc = cobs_encode(data)
            self.assertNotIn(0, enc)
            self.assertLessEqual(len(enc), frames.max_encoded_len(n))
            self.assertEqual(cobs_decode(enc), data)

    def test_decode_errors(self):
        for bad in (b"\x00", b"\x05\x11", b"\x02\x00", b"\x03\x11\x00"):
            with self.assertRaises(ValueError):
                cobs_decode(bad)

    def test_encode_limits(self):
        self.assertEqual(frames.encode(b"\x04"), b"\x02\x04\x00")
        with self.assertRaises(ValueError):
            frames.encode(b"")
        with self.assertRaises(ValueError):
            frames.encode(b"\x01" * 251)
        self.assertEqual(len(frames.encode(b"\x01" * 250)), 252)


class DecoderTest(unittest.TestCase):
    def test_split_feeds(self):
        bodies = [bytes([0x83, i]) + bytes(range(i)) for i in range(1, 60)]
        stream = b"".join(frames.encode(b) for b in bodies)
        dec = FrameDecoder()
        got = []
        for i in range(len(stream)):
            got += dec.feed(stream[i : i + 1])
        self.assertEqual(got, bodies)
        self.assertEqual(dec.dropped, 0)

    def test_random_chunks(self):
        rng = random.Random(7)
        bodies = [bytes(rng.randrange(256) for _ in range(rng.randrange(1, 251))) for _ in range(200)]
        stream = b"".join(frames.encode(b) for b in bodies)
        dec = FrameDecoder()
        got, i = [], 0
        while i < len(stream):
            n = rng.randrange(1, 300)
            got += dec.feed(stream[i : i + n])
            i += n
        self.assertEqual(got, bodies)

    def test_empty_frames_ignored(self):
        dec = FrameDecoder()
        self.assertEqual(dec.feed(b"\x00\x00\x00" + frames.encode(b"\x04") + b"\x00"), [b"\x04"])
        self.assertEqual(dec.dropped, 0)

    def test_resync_after_garbage(self):
        dec = FrameDecoder()
        # starts mid-frame: the tail of some frame, then garbage that fails to decode
        got = dec.feed(b"\x11\x22\x33\x00" + b"\x09\x01\x00" + frames.encode(b"\x03abcd"))
        self.assertEqual(got, [b"\x03abcd"])
        self.assertEqual(dec.dropped, 2)

    def test_too_long_dropped(self):
        dec = FrameDecoder()
        long_frame = cobs_encode(b"\x83" * 300) + b"\x00"
        got = dec.feed(long_frame + frames.encode(b"\x04"))
        self.assertEqual(got, [b"\x04"])
        self.assertEqual(dec.dropped, 1)
        # endless garbage without a zero never grows the buffer past the limit
        dec.feed(b"\x01" * 100000)
        self.assertLessEqual(len(dec._buf), dec.max_encoded)
        self.assertEqual(dec.feed(b"\x00" + frames.encode(b"\x04")), [b"\x04"])

    def test_decodes_to_empty_dropped(self):
        dec = FrameDecoder()
        self.assertEqual(dec.feed(b"\x01\x00"), [])
        self.assertEqual(dec.dropped, 1)

    def test_max_body_accepted(self):
        dec = FrameDecoder()
        body = bytes([0x83]) + bytes(range(249))
        self.assertEqual(dec.feed(frames.encode(body)), [body])


class MessageTest(unittest.TestCase):
    def round_trip(self, msg):
        body = msg.pack()
        self.assertLessEqual(len(body), frames.MAX_BODY)
        back = frames.unpack(body)
        self.assertEqual(back, msg)
        return body

    def test_layouts(self):
        body = self.round_trip(frames.Hello(game="DOTS", name="adrian", max_players=4))
        self.assertEqual(body, b"\x01\x01DOTS\0\0\0\0adrian\0\0\0\0\0\0\x04")
        self.assertEqual(self.round_trip(frames.Send(to=0xFF, data=b"hi")), b"\x02\xffhi")
        self.assertEqual(self.round_trip(frames.Ping(token=0x01020304)), b"\x03\x04\x03\x02\x01")
        self.assertEqual(self.round_trip(frames.Leave()), b"\x04")
        self.assertEqual(self.round_trip(frames.Welcome(you=2, room=1, max_players=8)), b"\x81\x01\x02\x01\x08")
        body = self.round_trip(frames.Roster(players=[(0, "a"), (3, "b")]))
        self.assertEqual(body, b"\x82\x02\x00a" + b"\0" * 11 + b"\x03b" + b"\0" * 11)
        self.assertEqual(self.round_trip(frames.Data(sender=5, data=b"\x00\x01")), b"\x83\x05\x00\x01")
        self.assertEqual(self.round_trip(frames.Pong(token=7)), b"\x84\x07\0\0\0")
        self.assertEqual(self.round_trip(frames.Error(code=3, message="nope")), b"\x8f\x03nope")

    def test_full_roster_fits(self):
        r = frames.Roster(players=[(i, "player%05d" % i) for i in range(16)])
        self.assertEqual(len(r.pack()), 2 + 16 * 13)
        self.round_trip(r)

    def test_names_truncated_and_cleaned(self):
        body = frames.Hello(game="LONGGAMEID!", name="a" * 20).pack()
        msg = frames.unpack(body)
        self.assertEqual(msg.game, "LONGGAME")
        self.assertEqual(msg.name, "a" * 12)
        weird = bytearray(body)
        weird[10] = 0x07
        self.assertEqual(frames.unpack(bytes(weird)).name[0], "?")

    def test_malformed(self):
        for bad in (b"\x01\x01DOTS", b"\x02", b"\x03\x01\x02", b"\x82\x02\x00a", b"\x02\xff" + b"x" * 241):
            with self.assertRaises(frames.MalformedMessage):
                frames.unpack(bad)
        with self.assertRaises(ValueError):
            frames.Send(data=b"x" * 241).pack()

    def test_trailing_bytes_ignored(self):
        self.assertEqual(frames.unpack(b"\x03\x01\0\0\0extra"), frames.Ping(token=1))

    def test_unknown(self):
        msg = frames.unpack(b"\x42\x01\x02")
        self.assertIsInstance(msg, frames.Unknown)
        self.assertEqual((msg.type, msg.payload), (0x42, b"\x01\x02"))

    def test_describe_everything(self):
        for m in (
            frames.Hello(game="G", name="n"),
            frames.Send(to=1, data=b"x"),
            frames.Ping(),
            frames.Leave(),
            frames.Welcome(),
            frames.Roster(players=[(0, "a")]),
            frames.Data(data=b"\x00" * 40),
            frames.Pong(),
            frames.Error(code=2),
            frames.Unknown(type=0x55),
        ):
            self.assertTrue(frames.describe(m))

    def test_parse_command(self):
        self.assertEqual(frames.parse_command("welcome 0 1 4"), b"\x81\x01\x00\x01\x04")
        self.assertEqual(frames.parse_command("data 1 hi"), b"\x83\x01hi")
        self.assertEqual(frames.parse_command("data 1 hex:00ff"), b"\x83\x01\x00\xff")
        self.assertEqual(frames.parse_command("send all x"), b"\x02\xffx")
        self.assertEqual(frames.parse_command("raw 84 01 00 00 00"), b"\x84\x01\0\0\0")
        self.assertEqual(frames.unpack(frames.parse_command("roster 0=me 1=you")).players, [(0, "me"), (1, "you")])
        self.assertEqual(frames.unpack(frames.parse_command("hello DOTS bob 4")), frames.Hello("DOTS", "bob", 4))
        with self.assertRaises(ValueError):
            frames.parse_command("bogus")


if __name__ == "__main__":
    unittest.main()
