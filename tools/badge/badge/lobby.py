"""Lobby protocol v1 relay (`badge lobby`).

Protocol: fork/CART_SERIAL.md, "Lobby protocol v1". Three layers:

1. Lobby: the pure protocol state machine. No threads, no I/O. Feed it bytes
   per connection (`feed`), tell it about connects/disconnects, and collect
   the encoded frames it wants to send (`take_output`). Rooms, player ids,
   WELCOME/ROSTER/DATA/PONG/ERROR all live here, so it is unit-testable.

2. LobbyServer: one relay thread that owns the Lobby, plus a reader and a
   writer thread per link. Every connection is a `links.Link` (read / write /
   close, see links.py). The relay thread processes events in arrival order,
   one frame at a time, so each room has a single global order; after each
   batch of events it hands every connection all of its pending bytes in one
   write (coalescing). A link whose unsent backlog passes `queue_limit`
   bytes while its writer has been stuck for `stall_time` seconds (the cart
   stopped reading) is removed from the lobby and closed; frames are never
   dropped for a connected player.

3. Sources feed links into the server. The seam for other transports:

       class MySource:
           def start(self, server): ...   # spawn a thread that calls
                                          #   server.add_link(link)
                                          #   server.remove_key(key, reason)
           def stop(self): ...

   `server.add_link(link)` accepts any Link (SerialLink for badge cart ports,
   SocketLink for simulators or for sockets accepted from the network);
   `link.key` identifies it, and the server refuses a second link with a key
   that is open (`server.is_open(key)`), and tells sources to wait before
   reopening a key that just closed (`server.may_open(key)`). HotplugSource
   (USB badges, rescanned every second), SimSource (TCP simulators) and
   StaticSource (explicit --port) are the built-in sources.
"""

from __future__ import annotations

import collections
import queue
import threading
import time
from typing import Callable, Dict, Iterable, List, Optional, Tuple

from . import frames
from .frames import BROADCAST, MAX_PLAYERS
from .links import Link, LinkClosed, SerialLink, SocketLink, open_link  # noqa: F401  (re-exported)

EVERYONE = 0xFE  # SEND to everyone in the room including the sender
MAX_ROOMS = 255  # room numbers 1..255

LogFn = Callable[[str], None]


def _noop(_msg: str) -> None:
    pass


class Player:
    __slots__ = ("conn", "label", "game", "name", "room", "id", "rx", "tx", "sends", "joined_at")

    def __init__(self, conn, label: str):
        self.conn = conn
        self.label = label
        self.game: Optional[str] = None
        self.name = ""
        self.room: Optional[Room] = None
        self.id = -1
        self.rx = 0  # frames received
        self.tx = 0  # frames sent
        self.sends = 0  # SENDs relayed
        self.joined_at = 0.0

    def who(self) -> str:
        if self.name:
            return "%s %r" % (self.label, self.name)
        return self.label


class Room:
    __slots__ = ("number", "game", "size", "members", "relayed", "created")

    def __init__(self, number: int, game: str, size: int):
        self.number = number
        self.game = game
        self.size = size
        self.members: Dict[int, Player] = {}
        self.relayed = 0
        self.created = time.time()

    def ordered(self) -> List[Player]:
        return [self.members[i] for i in sorted(self.members)]

    def free_id(self) -> Optional[int]:
        for i in range(self.size):
            if i not in self.members:
                return i
        return None


class Lobby:
    """Protocol v1 state machine. Connection ids are any hashable values."""

    def __init__(self, max_room: int = MAX_PLAYERS, log: LogFn = _noop, verbose: bool = False):
        self.max_room = max(2, min(MAX_PLAYERS, max_room))
        self.log = log
        self.verbose = verbose
        self.players: Dict[object, Player] = {}
        self.decoders: Dict[object, frames.FrameDecoder] = {}
        self.rooms: Dict[int, Room] = {}
        self._out: Dict[object, List[bytes]] = {}
        self.unknown = 0
        self.malformed = 0
        self.dropped_sends = 0

    # -- connections -----------------------------------------------------

    def connect(self, conn, label: str = "") -> None:
        self.players[conn] = Player(conn, label or str(conn))
        self.decoders[conn] = frames.FrameDecoder()

    def disconnect(self, conn, reason: str = "port closed") -> None:
        p = self.players.pop(conn, None)
        self.decoders.pop(conn, None)
        self._out.pop(conn, None)
        if p is not None and p.room is not None:
            self._leave(p, reason, notify_self=False)

    def feed(self, conn, data: bytes) -> None:
        dec = self.decoders.get(conn)
        if dec is None:
            return
        for body in dec.feed(data):
            self.handle(conn, body)

    def take_output(self) -> Dict[object, bytes]:
        """Encoded bytes to write, per connection, since the last call."""
        out = self._out
        self._out = {}
        return {c: b"".join(chunks) for c, chunks in out.items()}

    # -- frames ----------------------------------------------------------

    def _queue(self, conn, frame: bytes) -> None:
        q = self._out.get(conn)
        if q is None:
            self._out[conn] = [frame]
        else:
            q.append(frame)
        p = self.players.get(conn)
        if p is not None:
            p.tx += 1

    def _send(self, p: Player, msg) -> None:
        if self.verbose:
            self.log("  -> %s %s" % (p.label, frames.describe(msg)))
        self._queue(p.conn, frames.encode(msg.pack()))

    def _error(self, p: Player, code: int, text: str) -> None:
        self._send(p, frames.Error(code=code, message=text))

    def handle(self, conn, body: bytes) -> None:
        p = self.players.get(conn)
        if p is None:
            return
        p.rx += 1
        try:
            msg = frames.unpack(body)
        except frames.MalformedMessage as e:
            self.malformed += 1
            self._error(p, frames.ERR_MALFORMED, str(e))
            return
        t = body[0]
        if t == frames.SEND:
            self._relay(p, msg)
            return
        if self.verbose:
            self.log("  <- %s %s" % (p.label, frames.describe(msg)))
        if t == frames.HELLO:
            self._hello(p, msg)
        elif t == frames.PING:
            self._send(p, frames.Pong(token=msg.token))
        elif t == frames.LEAVE:
            if p.room is None:
                self._error(p, frames.ERR_NOT_JOINED, "LEAVE before WELCOME")
            else:
                self._leave(p, "left", notify_self=False)
        else:
            self.unknown += 1  # unknown types (and host-only types) are ignored

    def _hello(self, p: Player, msg: frames.Hello) -> None:
        if p.room is not None:
            self._leave(p, "rejoin" if msg.game == p.game else "switched game", notify_self=False)
        if msg.version != frames.VERSION:
            self._error(p, frames.ERR_VERSION, "lobby speaks version %d" % frames.VERSION)
            return
        size = msg.max_players or self.max_room
        size = max(2, min(size, self.max_room, MAX_PLAYERS))
        room = None
        for number in sorted(self.rooms):
            r = self.rooms[number]
            if r.game == msg.game and len(r.members) < r.size:
                room = r
                break
        if room is None:
            number = next((n for n in range(1, MAX_ROOMS + 1) if n not in self.rooms), None)
            if number is None:
                self._error(p, frames.ERR_NO_ROOM, "lobby full")
                return
            room = Room(number, msg.game, size)
            self.rooms[number] = room
            self.log("room %d opened for %s (size %d)" % (number, msg.game or "''", size))
        pid = room.free_id()
        assert pid is not None
        p.game = msg.game
        p.name = msg.name
        p.room = room
        p.id = pid
        p.joined_at = time.time()
        room.members[pid] = p
        self.log(
            "join  %s -> %s room %d as %d (%d/%d)"
            % (p.who(), room.game or "''", room.number, pid, len(room.members), room.size)
        )
        self._send(p, frames.Welcome(you=pid, room=room.number, max_players=room.size))
        self._roster(room)

    def _roster(self, room: Room) -> None:
        players = room.ordered()
        msg = frames.Roster(players=[(m.id, m.name) for m in players])
        frame = frames.encode(msg.pack())
        if self.verbose:
            self.log("  -> room %d %s" % (room.number, frames.describe(msg)))
        for m in players:
            self._queue(m.conn, frame)

    def _leave(self, p: Player, reason: str, notify_self: bool) -> None:
        room = p.room
        if room is None:
            return
        room.members.pop(p.id, None)
        self.log(
            "leave %s from %s room %d as %d (%s, %d left)"
            % (p.who(), room.game or "''", room.number, p.id, reason, len(room.members))
        )
        p.room = None
        p.id = -1
        if room.members:
            self._roster(room)
        else:
            del self.rooms[room.number]
            self.log("room %d closed" % room.number)

    def _relay(self, p: Player, msg: frames.Send) -> None:
        room = p.room
        if room is None:
            self._error(p, frames.ERR_NOT_JOINED, "SEND before WELCOME")
            return
        to = msg.to
        frame = frames.encode(bytes((frames.DATA, p.id)) + msg.data)
        p.sends += 1
        room.relayed += 1
        if self.verbose:
            self.log("  <- %s %s" % (p.label, frames.describe(msg)))
        if to == BROADCAST:
            for m in room.ordered():
                if m is not p:
                    self._queue(m.conn, frame)
        elif to == EVERYONE:
            for m in room.ordered():
                self._queue(m.conn, frame)
        else:
            m = room.members.get(to)
            if m is None:
                self.dropped_sends += 1
                return
            self._queue(m.conn, frame)


# ---------------------------------------------------------------------------
# Threads and links


class Conn:
    """One open link inside the server: reader + writer thread, out buffer."""

    def __init__(self, cid: int, link: Link, server: "LobbyServer"):
        self.cid = cid
        self.link = link
        self.key = link.key
        self.label = link.label or link.key
        self.server = server
        self.cond = threading.Condition()
        self.buf = bytearray()
        self.dead = False
        self.opened = time.time()
        self.bytes_in = 0
        self.bytes_out = 0
        self.writing_since: Optional[float] = None  # set while link.write() runs
        self.reader = threading.Thread(target=self._read_loop, name="rx " + self.label, daemon=True)
        self.writer = threading.Thread(target=self._write_loop, name="tx " + self.label, daemon=True)

    def start(self) -> None:
        self.reader.start()
        self.writer.start()

    def queued(self) -> int:
        return len(self.buf)

    def push(self, data: bytes) -> bool:
        """Queue bytes for the writer. False when the queue limit is passed."""
        with self.cond:
            if self.dead:
                return True
            # Overflow = a backlog past the limit while one write has been
            # blocked for stall_time (the cart stopped reading), or a backlog
            # past the hard cap. A big burst to a player that keeps up is fine.
            backlog = len(self.buf)
            if backlog > self.server.queue_limit:
                since = self.writing_since
                stalled = since is not None and time.monotonic() - since > self.server.stall_time
                if stalled or backlog > 16 * self.server.queue_limit:
                    return False
            self.buf += data
            self.cond.notify()
        return True

    def kill(self) -> None:
        with self.cond:
            self.dead = True
            self.cond.notify()
        self.link.close()

    def _read_loop(self) -> None:
        post = self.server.events.put
        try:
            while not self.dead:
                data = self.link.read(0.2)
                if data:
                    self.bytes_in += len(data)
                    post(("rx", self.cid, data))
        except LinkClosed as e:
            post(("closed", self.cid, str(e) or "port closed"))
        except Exception as e:  # never let a reader die silently
            post(("closed", self.cid, "read error: %s" % e))

    def _write_loop(self) -> None:
        try:
            while True:
                with self.cond:
                    while not self.buf and not self.dead:
                        self.cond.wait()
                    if self.dead:
                        return
                    data = bytes(self.buf)
                    self.buf.clear()
                    self.writing_since = time.monotonic()
                self.link.write(data)
                self.writing_since = None
                self.bytes_out += len(data)
        except LinkClosed as e:
            self.server.events.put(("closed", self.cid, str(e) or "write failed"))
        except Exception as e:
            self.server.events.put(("closed", self.cid, "write error: %s" % e))


class LobbyServer:
    """Runs a Lobby over links. Thread-safe entry points: add_link,
    remove_key, is_open, may_open, stop."""

    def __init__(
        self,
        lobby: Optional[Lobby] = None,
        queue_limit: int = 64 * 1024,
        log: LogFn = print,
        reopen_delay: float = 2.0,
        stats_interval: float = 10.0,
        stall_time: float = 1.0,
    ):
        self.log = log
        self.lobby = lobby or Lobby(log=log)
        self.queue_limit = queue_limit
        self.stall_time = stall_time
        self.reopen_delay = reopen_delay
        self.stats_interval = stats_interval
        self.events: "queue.Queue[tuple]" = queue.Queue()
        self.conns: Dict[int, Conn] = {}
        self._keys: Dict[str, int] = {}
        self._closed_at: Dict[str, float] = {}
        self._lock = threading.Lock()
        self._next_cid = 1
        self._stop = threading.Event()
        self.sources: list = []
        self.frames_in = 0
        self.frames_out = 0
        self._last_stats = time.time()
        self._stats_prev: Dict[int, Tuple[int, int]] = {}

    # -- thread-safe API -------------------------------------------------

    def add_source(self, source) -> None:
        self.sources.append(source)

    def is_open(self, key: str) -> bool:
        with self._lock:
            return key in self._keys

    def may_open(self, key: str) -> bool:
        with self._lock:
            if key in self._keys:
                return False
            t = self._closed_at.get(key)
            return t is None or time.time() - t >= self.reopen_delay

    def open_keys(self) -> List[str]:
        with self._lock:
            return list(self._keys)

    def add_link(self, link: Link) -> bool:
        """Hand a freshly opened link to the relay. Returns False (and closes
        the link) when a link with the same key is already open."""
        with self._lock:
            if link.key in self._keys or self._stop.is_set():
                dup = True
            else:
                dup = False
                cid = self._next_cid
                self._next_cid += 1
                self._keys[link.key] = cid
        if dup:
            link.close()
            return False
        self.events.put(("link", cid, link))
        return True

    def remove_key(self, key: str, reason: str) -> None:
        with self._lock:
            cid = self._keys.get(key)
        if cid is not None:
            self.events.put(("closed", cid, reason))

    def stop(self) -> None:
        self._stop.set()
        self.events.put(("wake",))

    # -- relay thread ----------------------------------------------------

    def run(self) -> None:
        for s in self.sources:
            s.start(self)
        try:
            while not self._stop.is_set():
                try:
                    ev = self.events.get(timeout=0.5)
                except queue.Empty:
                    ev = None
                n = 0
                while ev is not None:
                    self._handle(ev)
                    n += 1
                    if n >= 512:
                        break
                    try:
                        ev = self.events.get_nowait()
                    except queue.Empty:
                        ev = None
                self._flush()
                if self.stats_interval and time.time() - self._last_stats >= self.stats_interval:
                    self._print_stats()
        finally:
            for s in self.sources:
                try:
                    s.stop()
                except Exception:
                    pass
            for c in list(self.conns.values()):
                c.kill()
            self.conns.clear()
            with self._lock:
                self._keys.clear()

    def _handle(self, ev: tuple) -> None:
        kind = ev[0]
        if kind == "rx":
            c = self.conns.get(ev[1])
            if c is not None:
                before = self.lobby.players.get(c.cid)
                rx0 = before.rx if before else 0
                self.lobby.feed(c.cid, ev[2])
                after = self.lobby.players.get(c.cid)
                if after:
                    self.frames_in += after.rx - rx0
        elif kind == "link":
            cid, link = ev[1], ev[2]
            c = Conn(cid, link, self)
            self.conns[cid] = c
            self.lobby.connect(cid, c.label)
            c.push(b"\x00")  # flush any partial frame on the cart side
            c.start()
            self.log("+ %s" % c.label)
        elif kind == "closed":
            self._close(ev[1], ev[2])

    def _close(self, cid: int, reason: str) -> None:
        c = self.conns.pop(cid, None)
        if c is None:
            return
        self.lobby.disconnect(cid, reason)
        c.kill()
        with self._lock:
            if self._keys.get(c.key) == cid:
                del self._keys[c.key]
            self._closed_at[c.key] = time.time()
        self.log("- %s (%s)" % (c.label, reason))

    def _flush(self) -> None:
        # Overflow removals generate ROSTERs, which need another pass.
        for _ in range(4):
            out = self.lobby.take_output()
            if not out:
                return
            over = []
            for cid, data in out.items():
                c = self.conns.get(cid)
                if c is None:
                    continue
                self.frames_out += data.count(0)
                if not c.push(data):
                    over.append(c)
            for c in over:
                self._close(c.cid, "not reading: %d bytes queued" % c.queued())

    def _print_stats(self) -> None:
        now = time.time()
        dt = max(1e-6, now - self._last_stats)
        self._last_stats = now
        lines = []
        for number in sorted(self.lobby.rooms):
            r = self.lobby.rooms[number]
            parts = []
            for p in r.ordered():
                prev = self._stats_prev.get(p.conn, (p.rx, p.tx))
                parts.append(
                    "%d %s %.0f/%.0f" % (p.id, p.name or p.label, (p.rx - prev[0]) / dt, (p.tx - prev[1]) / dt)
                )
            lines.append(
                "room %d %s %d/%d: %s" % (number, r.game or "''", len(r.members), r.size, ", ".join(parts))
            )
        self._stats_prev = {cid: (p.rx, p.tx) for cid, p in self.lobby.players.items()}
        if lines:
            self.log("stats (frames/s in/out): " + " | ".join(lines))


# ---------------------------------------------------------------------------
# Sources


class _PollingSource:
    interval = 1.0

    def __init__(self) -> None:
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None
        self.server: Optional[LobbyServer] = None

    def start(self, server: LobbyServer) -> None:
        self.server = server
        self._thread = threading.Thread(target=self._loop, name=type(self).__name__, daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()

    def _loop(self) -> None:
        while not self._stop.is_set():
            try:
                self.poll()
            except Exception as e:  # keep scanning whatever happens
                if self.server:
                    self.server.log("scan error: %s" % e)
            self._stop.wait(self.interval)

    def poll(self) -> None:  # pragma: no cover - interface
        raise NotImplementedError


class HotplugSource(_PollingSource):
    """USB badges with a cart port, rescanned every `interval` seconds."""

    def __init__(self, interval: float = 1.0, scan_fn=None, open_fn=None):
        super().__init__()
        self.interval = interval
        self._scan = scan_fn
        self._open = open_fn or (lambda dev, key, label: SerialLink(dev, key=key, label=label))
        self._mine: Dict[str, str] = {}  # key -> device
        self._busy_logged: set = set()

    def cart_ports(self) -> Dict[str, Tuple[str, str]]:
        if self._scan is not None:
            return self._scan()
        from . import discover

        s = discover.scan(probe=False, drives=False)
        return {"usb:" + b.id: (b.cart, b.short) for b in s.badges if b.cart}

    def poll(self) -> None:
        server = self.server
        found = self.cart_ports()
        for key, dev in list(self._mine.items()):
            if key not in found and server.is_open(key):
                server.remove_key(key, "badge disappeared")
            if key not in found:
                del self._mine[key]
        for key, (dev, label) in found.items():
            if not server.may_open(key):
                continue
            try:
                link = self._open(dev, key, label)
            except LinkClosed as e:
                if key not in self._busy_logged:
                    server.log("! %s: cannot open %s: %s" % (label, dev, e))
                    self._busy_logged.add(key)
                continue
            self._busy_logged.discard(key)
            self._mine[key] = dev
            server.add_link(link)


class SimSource(_PollingSource):
    """Simulators (or any TCP cart serial port) at fixed host:port pairs."""

    def __init__(self, targets: Iterable[Tuple[str, int]], interval: float = 1.0, timeout: float = 0.2):
        super().__init__()
        self.targets = list(targets)
        self.interval = interval
        self.timeout = timeout

    def poll(self) -> None:
        from .discover import SIM_HOST

        for host, port in self.targets:
            key = "sim:%d" % port if host == SIM_HOST else "sim:%s:%d" % (host, port)
            if not self.server.may_open(key):
                continue
            try:
                link = SocketLink.connect(host, port, key=key, label=key, timeout=self.timeout)
            except OSError:
                continue
            self.server.add_link(link)


class StaticSource(_PollingSource):
    """Explicit ports / URLs (`--port`), reopened when they come back."""

    def __init__(self, urls: Iterable[str], interval: float = 1.0):
        super().__init__()
        self.urls = list(urls)
        self.interval = interval
        self._logged: set = set()

    def poll(self) -> None:
        for url in self.urls:
            if not self.server.may_open(url):
                continue
            try:
                link = open_link(url, key=url, label=url, timeout=0.3)
            except LinkClosed as e:
                if url not in self._logged:
                    self.server.log("! cannot open %s: %s (retrying)" % (url, e))
                    self._logged.add(url)
                continue
            self._logged.discard(url)
            self.server.add_link(link)
