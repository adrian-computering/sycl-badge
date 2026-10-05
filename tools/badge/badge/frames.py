"""COBS framing and lobby protocol v1 messages.

The wire format is specified in fork/CART_SERIAL.md ("Lobby protocol v1").
This module has no dependencies, so any host program can reuse it:

    from badge import frames

    port.write(frames.encode(frames.Hello(game="DOTS", name="host").pack()))
    decoder = frames.FrameDecoder()
    for body in decoder.feed(port.read(256)):
        msg = frames.unpack(body)
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import List, Optional, Tuple, Union

# Limits
MAX_BODY = 250  # type byte + payload
MAX_DATA = 240  # SEND / DATA payload
MAX_PLAYERS = 16
VERSION = 1
BROADCAST = 0xFF
GAME_LEN = 8
NAME_LEN = 12

# Message types, cart to host
HELLO = 0x01
SEND = 0x02
PING = 0x03
LEAVE = 0x04
# Message types, host to cart
WELCOME = 0x81
ROSTER = 0x82
DATA = 0x83
PONG = 0x84
ERROR = 0x8F

# ERROR codes
ERR_VERSION = 1
ERR_NO_ROOM = 2
ERR_NOT_JOINED = 3
ERR_MALFORMED = 4

ERROR_NAMES = {
    ERR_VERSION: "unsupported version",
    ERR_NO_ROOM: "no room",
    ERR_NOT_JOINED: "not joined",
    ERR_MALFORMED: "malformed message",
}


class MalformedMessage(ValueError):
    """A frame body that does not match its message type's layout."""


# ---------------------------------------------------------------------------
# COBS


def cobs_encode(data: bytes) -> bytes:
    """COBS-encode `data`. The result contains no 0x00 bytes."""
    out = bytearray()
    code_pos = 0
    out.append(0)  # placeholder for the first code byte
    code = 1
    for byte in data:
        if byte == 0:
            out[code_pos] = code
            code_pos = len(out)
            out.append(0)
            code = 1
            continue
        out.append(byte)
        code += 1
        if code == 0xFF:
            out[code_pos] = code
            code_pos = len(out)
            out.append(0)
            code = 1
    out[code_pos] = code
    return bytes(out)


def cobs_decode(data: bytes) -> bytes:
    """Decode one COBS block (without the trailing 0x00).

    Raises ValueError on a zero byte or a code that runs past the end.
    """
    out = bytearray()
    i = 0
    n = len(data)
    while i < n:
        code = data[i]
        if code == 0:
            raise ValueError("zero byte inside COBS data")
        end = i + code
        if end > n:
            raise ValueError("COBS code runs past the end")
        chunk = data[i + 1 : end]
        if 0 in chunk:
            raise ValueError("zero byte inside COBS data")
        out += chunk
        i = end
        if code != 0xFF and i < n:
            out.append(0)
    return bytes(out)


def max_encoded_len(body_len: int) -> int:
    return body_len + (body_len // 254) + 1


def encode(body: bytes) -> bytes:
    """Frame a message body: COBS(body) + 0x00."""
    if not body:
        raise ValueError("empty frame body")
    if len(body) > MAX_BODY:
        raise ValueError("frame body is %d bytes, max %d" % (len(body), MAX_BODY))
    return cobs_encode(body) + b"\x00"


class FrameDecoder:
    """Incremental frame decoder.

    feed() bytes as they arrive and get back complete frame bodies. Frames
    that fail to decode, are empty after decoding or are longer than
    `max_body` are dropped (counted in `dropped`) and decoding resumes after
    the next 0x00, so a decoder that starts mid-stream resynchronizes.
    """

    def __init__(self, max_body: int = MAX_BODY):
        self.max_body = max_body
        self.max_encoded = max_encoded_len(max_body)
        self._buf = bytearray()
        self._overflow = False
        self.frames = 0
        self.dropped = 0

    def reset(self) -> None:
        self._buf.clear()
        self._overflow = False

    def feed(self, data: bytes) -> List[bytes]:
        bodies = []
        start = 0
        while True:
            zero = data.find(b"\x00", start)
            if zero < 0:
                self._append(data[start:])
                break
            self._append(data[start:zero])
            body = self._finish()
            if body is not None:
                bodies.append(body)
            start = zero + 1
        return bodies

    def _append(self, chunk: bytes) -> None:
        if self._overflow or not chunk:
            return
        self._buf += chunk
        if len(self._buf) > self.max_encoded:
            self._overflow = True
            self._buf.clear()

    def _finish(self) -> Optional[bytes]:
        if self._overflow:
            self._overflow = False
            self.dropped += 1
            return None
        if not self._buf:
            return None  # empty frame: ignored, not an error
        raw = bytes(self._buf)
        self._buf.clear()
        try:
            body = cobs_decode(raw)
        except ValueError:
            self.dropped += 1
            return None
        if not body or len(body) > self.max_body:
            self.dropped += 1
            return None
        self.frames += 1
        return body


# ---------------------------------------------------------------------------
# Fixed-width ASCII fields


def pack_str(value: Union[str, bytes], length: int) -> bytes:
    """ASCII, truncated and zero-padded to `length` bytes."""
    if isinstance(value, str):
        value = value.encode("ascii", "replace")
    value = bytes(value)[:length]
    return value + b"\x00" * (length - len(value))


def unpack_str(raw: bytes) -> str:
    """Up to the first 0x00, non-printable bytes shown as '?'."""
    end = raw.find(b"\x00")
    if end >= 0:
        raw = raw[:end]
    return "".join(chr(b) if 0x20 <= b < 0x7F else "?" for b in raw)


# ---------------------------------------------------------------------------
# Messages


@dataclass
class Hello:
    game: str = ""
    name: str = ""
    max_players: int = 0
    version: int = VERSION
    type = HELLO

    def pack(self) -> bytes:
        return (
            bytes([HELLO, self.version & 0xFF])
            + pack_str(self.game, GAME_LEN)
            + pack_str(self.name, NAME_LEN)
            + bytes([self.max_players & 0xFF])
        )


@dataclass
class Send:
    to: int = BROADCAST
    data: bytes = b""
    type = SEND

    def pack(self) -> bytes:
        _check_data(self.data)
        return bytes([SEND, self.to & 0xFF]) + bytes(self.data)


@dataclass
class Ping:
    token: int = 0
    type = PING

    def pack(self) -> bytes:
        return bytes([PING]) + (self.token & 0xFFFFFFFF).to_bytes(4, "little")


@dataclass
class Leave:
    type = LEAVE

    def pack(self) -> bytes:
        return bytes([LEAVE])


@dataclass
class Welcome:
    you: int = 0
    room: int = 0
    max_players: int = 0
    version: int = VERSION
    type = WELCOME

    def pack(self) -> bytes:
        return bytes([WELCOME, self.version, self.you, self.room, self.max_players])


@dataclass
class Roster:
    players: List[Tuple[int, str]] = field(default_factory=list)
    type = ROSTER

    def pack(self) -> bytes:
        if len(self.players) > MAX_PLAYERS:
            raise ValueError("roster has %d players, max %d" % (len(self.players), MAX_PLAYERS))
        out = bytearray([ROSTER, len(self.players)])
        for pid, name in self.players:
            out.append(pid & 0xFF)
            out += pack_str(name, NAME_LEN)
        return bytes(out)


@dataclass
class Data:
    sender: int = 0
    data: bytes = b""
    type = DATA

    def pack(self) -> bytes:
        _check_data(self.data)
        return bytes([DATA, self.sender & 0xFF]) + bytes(self.data)


@dataclass
class Pong:
    token: int = 0
    type = PONG

    def pack(self) -> bytes:
        return bytes([PONG]) + (self.token & 0xFFFFFFFF).to_bytes(4, "little")


@dataclass
class Error:
    code: int = 0
    message: str = ""
    type = ERROR

    def pack(self) -> bytes:
        msg = self.message.encode("ascii", "replace")[: MAX_BODY - 2]
        return bytes([ERROR, self.code & 0xFF]) + msg


@dataclass
class Unknown:
    """A message type this version does not know. Receivers ignore it."""

    type: int = 0
    payload: bytes = b""

    def pack(self) -> bytes:
        return bytes([self.type]) + self.payload


Message = Union[Hello, Send, Ping, Leave, Welcome, Roster, Data, Pong, Error, Unknown]


def _check_data(data: bytes) -> None:
    if len(data) > MAX_DATA:
        raise ValueError("data is %d bytes, max %d" % (len(data), MAX_DATA))


def _need(body: bytes, length: int, name: str) -> None:
    if len(body) < length:
        raise MalformedMessage("%s needs %d bytes, got %d" % (name, length, len(body)))


def unpack(body: bytes) -> Message:
    """Parse a frame body into a message object.

    Trailing bytes after a fixed-size message are ignored (room for later
    versions). Raises MalformedMessage when a known message is too short or
    its data is too long.
    """
    if not body:
        raise MalformedMessage("empty body")
    t = body[0]
    if t == HELLO:
        _need(body, 23, "HELLO")
        return Hello(
            version=body[1],
            game=unpack_str(body[2:10]),
            name=unpack_str(body[10:22]),
            max_players=body[22],
        )
    if t == SEND:
        _need(body, 2, "SEND")
        if len(body) - 2 > MAX_DATA:
            raise MalformedMessage("SEND data is %d bytes, max %d" % (len(body) - 2, MAX_DATA))
        return Send(to=body[1], data=bytes(body[2:]))
    if t == PING:
        _need(body, 5, "PING")
        return Ping(token=int.from_bytes(body[1:5], "little"))
    if t == LEAVE:
        return Leave()
    if t == WELCOME:
        _need(body, 5, "WELCOME")
        return Welcome(version=body[1], you=body[2], room=body[3], max_players=body[4])
    if t == ROSTER:
        _need(body, 2, "ROSTER")
        count = body[1]
        _need(body, 2 + count * (1 + NAME_LEN), "ROSTER")
        players = []
        for i in range(count):
            off = 2 + i * (1 + NAME_LEN)
            players.append((body[off], unpack_str(body[off + 1 : off + 1 + NAME_LEN])))
        return Roster(players=players)
    if t == DATA:
        _need(body, 2, "DATA")
        if len(body) - 2 > MAX_DATA:
            raise MalformedMessage("DATA data is %d bytes, max %d" % (len(body) - 2, MAX_DATA))
        return Data(sender=body[1], data=bytes(body[2:]))
    if t == PONG:
        _need(body, 5, "PONG")
        return Pong(token=int.from_bytes(body[1:5], "little"))
    if t == ERROR:
        _need(body, 2, "ERROR")
        return Error(code=body[1], message=body[2:].decode("ascii", "replace"))
    return Unknown(type=t, payload=bytes(body[1:]))


def game_key(game: str) -> str:
    """Rooms match on the game id exactly as sent (after the zero padding)."""
    return game


# ---------------------------------------------------------------------------
# Human-readable forms (badge monitor --frames, badge lobby --verbose)


def _fmt_data(data: bytes, limit: int = 24) -> str:
    shown = data[:limit]
    text = "".join(chr(b) if 0x20 <= b < 0x7F else "." for b in shown)
    more = "..." if len(data) > limit else ""
    return "%d bytes %s%s |%s%s|" % (len(data), shown.hex(" "), more and " " + more, text, more)


def describe(msg: Message) -> str:
    if isinstance(msg, Hello):
        return "HELLO v%d game=%r name=%r max=%d" % (msg.version, msg.game, msg.name, msg.max_players)
    if isinstance(msg, Send):
        to = "all" if msg.to == BROADCAST else str(msg.to)
        return "SEND to=%s %s" % (to, _fmt_data(msg.data))
    if isinstance(msg, Ping):
        return "PING token=%d" % msg.token
    if isinstance(msg, Leave):
        return "LEAVE"
    if isinstance(msg, Welcome):
        return "WELCOME v%d you=%d room=%d max=%d" % (msg.version, msg.you, msg.room, msg.max_players)
    if isinstance(msg, Roster):
        return "ROSTER %d: %s" % (len(msg.players), ", ".join("%d=%s" % (i, n) for i, n in msg.players))
    if isinstance(msg, Data):
        return "DATA from=%d %s" % (msg.sender, _fmt_data(msg.data))
    if isinstance(msg, Pong):
        return "PONG token=%d" % msg.token
    if isinstance(msg, Error):
        return "ERROR %d (%s) %r" % (msg.code, ERROR_NAMES.get(msg.code, "?"), msg.message)
    return "UNKNOWN type=0x%02X %s" % (msg.type, _fmt_data(msg.payload))


def parse_command(line: str) -> bytes:
    """Turn a typed command into a frame body (for `badge monitor --frames`).

    hello GAME NAME [MAX] | send TO|all TEXT | ping [TOKEN] | leave |
    welcome YOU ROOM MAX | roster ID=NAME ... | data FROM TEXT |
    pong TOKEN | error CODE TEXT | raw HEX
    TEXT may be `hex:0011ff` for binary data.
    """
    parts = line.strip().split(None, 1)
    if not parts:
        raise ValueError("empty command")
    cmd = parts[0].lower()
    rest = parts[1] if len(parts) > 1 else ""

    def text(value: str) -> bytes:
        if value.startswith("hex:"):
            return bytes.fromhex(value[4:])
        return value.encode("utf-8")

    def ints(value: str, count: int) -> List[int]:
        fields = value.split()
        if len(fields) < count:
            raise ValueError("%s needs %d numbers" % (cmd, count))
        return [int(f, 0) for f in fields[:count]]

    if cmd == "hello":
        f = rest.split()
        if len(f) < 2:
            raise ValueError("usage: hello GAME NAME [MAX]")
        return Hello(game=f[0], name=f[1], max_players=int(f[2], 0) if len(f) > 2 else 0).pack()
    if cmd == "send":
        f = rest.split(None, 1)
        if not f:
            raise ValueError("usage: send TO|all TEXT")
        to = BROADCAST if f[0].lower() in ("all", "ff", "0xff") else int(f[0], 0)
        return Send(to=to, data=text(f[1] if len(f) > 1 else "")).pack()
    if cmd == "ping":
        return Ping(token=int(rest, 0) if rest else 0).pack()
    if cmd == "leave":
        return Leave().pack()
    if cmd == "welcome":
        you, room, mx = ints(rest, 3)
        return Welcome(you=you, room=room, max_players=mx).pack()
    if cmd == "roster":
        players = []
        for item in rest.split():
            pid, _, name = item.partition("=")
            players.append((int(pid, 0), name))
        return Roster(players=players).pack()
    if cmd == "data":
        f = rest.split(None, 1)
        if not f:
            raise ValueError("usage: data FROM TEXT")
        return Data(sender=int(f[0], 0), data=text(f[1] if len(f) > 1 else "")).pack()
    if cmd == "pong":
        return Pong(token=int(rest, 0) if rest else 0).pack()
    if cmd == "error":
        f = rest.split(None, 1)
        if not f:
            raise ValueError("usage: error CODE TEXT")
        return Error(code=int(f[0], 0), message=f[1] if len(f) > 1 else "").pack()
    if cmd == "raw":
        return bytes.fromhex(rest)
    raise ValueError("unknown command %r" % cmd)
