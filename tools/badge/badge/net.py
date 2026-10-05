"""Network lobby: badges on different computers share one `badge lobby`.

One computer runs the hub: an ordinary `badge lobby` with `--listen` (and
optionally `--tailcat`). `ListenSource` accepts TCP connections and hands
each one to the relay as a `SocketLink`, so a remote player is just another
link: its byte stream is exactly what a cart serial port carries (lobby
protocol v1 frames), it gets the same per-room ordering, and closing it is
the badge leaving.

Other computers run `badge join TARGET` (`Joiner`). For every local badge or
simulator it opens one TCP connection to the hub and copies bytes both ways
in order. Two small additions keep carts honest about the link:

- Handshake: before opening a badge's cart port the joiner sends a lobby
  PING through the new connection and waits for the hub's PONG. Only then is
  the port opened (DTR up). So while the hub cannot be reached the cart sees
  `connected()` false and shows "waiting for host", even through tailcat,
  whose local end accepts connections whether or not the hub is up.
- Heartbeat: when the hub has been silent for `heartbeat` seconds the joiner
  sends another PING, between frames only, and removes its own PONGs from
  the hub's stream before it reaches the cart. No reply within `dead_after`
  closes the connection and the cart port; a hub that vanished without
  closing anything (a laptop leaving Wi-Fi) is noticed this way. The joiner
  reconnects with backoff, and the cart says HELLO again when its port
  reopens (CART_SERIAL.md).

The hub is reached by `host:port` (same LAN, Tailscale, ssh -L) or by a
tailcat address (`Tailcat`): https://github.com/tailscale/tailcat gives a
WireGuard tunnel with NAT traversal and no account. The hub runs
`tailcat serve PORT`; a joiner runs `tailcat forward ADDR 0:PORT` and
connects to the local end.

Spec and plan: fork/NET_LOBBY.md. Standard library only.
"""

from __future__ import annotations

import os
import random
import re
import shutil
import socket
import subprocess
import threading
import time
from dataclasses import dataclass
from typing import Callable, Dict, Optional

from . import frames
from .links import Link, LinkClosed, SocketLink, open_link

DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 7360
MAX_REMOTE = 64  # remote links a hub accepts at once (rooms cap players anyway)

POLL_S = 0.05  # read timeout; how quickly sessions notice a stop
HANDSHAKE_S = 10.0  # first PONG through a fresh tunnel (DERP setup takes a few s)
HEARTBEAT_S = 3.0
DEAD_AFTER_S = 10.0


def parse_hostport(text: str, default_host: str = DEFAULT_HOST,
                   default_port: int = DEFAULT_PORT) -> tuple[str, int]:
    """Parse `PORT`, `HOST`, `HOST:PORT` or `[V6]:PORT`."""
    text = text.strip()
    if not text:
        return default_host, default_port
    if text.isdigit():
        return default_host, int(text)
    m = re.fullmatch(r"\[([^\]]+)\](?::(\d+))?", text)
    if m:
        return m.group(1), int(m.group(2) or default_port)
    if text.count(":") == 1:
        host, port = text.split(":")
        return host or default_host, int(port) if port else default_port
    return text, default_port


_TAILCAT_ADDR = re.compile(r"tc[A-Za-z0-9_-]{30,}")


def is_tailcat_address(text: str) -> bool:
    return _TAILCAT_ADDR.fullmatch(text.strip()) is not None


# ---------------------------------------------------------------- hub side


class Listener:
    """A listening TCP socket; `accept()` returns a connected socket or None."""

    def __init__(self, host: str = DEFAULT_HOST, port: int = DEFAULT_PORT):
        family = socket.AF_INET6 if ":" in host else socket.AF_INET
        self._sock = socket.socket(family, socket.SOCK_STREAM)
        self._sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._sock.bind((host, port))
        self._sock.listen(16)
        self.host, self.port = self._sock.getsockname()[:2]

    def accept(self, timeout: Optional[float] = None) -> Optional[socket.socket]:
        self._sock.settimeout(timeout)
        try:
            conn, _ = self._sock.accept()
        except (socket.timeout, OSError):
            return None
        conn.settimeout(None)
        return conn

    def close(self) -> None:
        self._sock.close()


class ListenSource:
    """Lobby source: every accepted connection is one remote player.

    Binds in the constructor, so a busy port fails before the lobby starts.
    """

    def __init__(self, host: str = DEFAULT_HOST, port: int = DEFAULT_PORT,
                 max_links: int = MAX_REMOTE):
        self.listener = Listener(host, port)
        self.host, self.port = self.listener.host, self.listener.port
        self.max_links = max_links
        self._stop = threading.Event()
        self._n = 0

    def start(self, server) -> None:
        self.server = server
        threading.Thread(target=self._loop, name="ListenSource", daemon=True).start()

    def stop(self) -> None:
        self._stop.set()
        self.listener.close()

    def _loop(self) -> None:
        while not self._stop.is_set():
            sock = self.listener.accept(0.2)
            if sock is None:
                continue
            try:
                peer = sock.getpeername()[0]
            except OSError:
                sock.close()
                continue
            remote = [k for k in self.server.open_keys() if k.startswith("net:")]
            if len(remote) >= self.max_links:
                self.server.log("! refused remote player from %s: %d already connected" % (peer, len(remote)))
                sock.close()
                continue
            self._n += 1
            key = "net:%d" % self._n
            # Through tailcat every peer is 127.0.0.1; the cart's name in
            # HELLO is what tells players apart in the log.
            label = key if peer in ("127.0.0.1", "::1") else "%s(%s)" % (key, peer)
            self.server.add_link(SocketLink(sock, key=key, label=label))


# ------------------------------------------------------------- joiner side


@dataclass
class JoinerEvent:
    kind: str  # "added", "connected", "disconnected", "removed"
    key: str
    detail: str = ""


class _HubSilent(Exception):
    pass


class _Pinger:
    """Our PINGs on a hub stream, and removing their PONGs from it.

    The hub never sends anything to a link before its cart says HELLO except
    replies to PINGs, and every frame ends in 0x00, so the hub -> cart stream
    can be cut at each 0x00 and a segment equal to our encoded PONG dropped.
    """

    def __init__(self, token: int):
        self.ping = b"\x00" + frames.encode(frames.Ping(token=token).pack())
        self.pong = frames.encode(frames.Pong(token=token).pack())
        self._partial = bytearray()
        self.pongs = 0

    def filter(self, data: bytes) -> bytes:
        """Hub bytes -> bytes for the cart, minus our PONGs. Keeps a partial
        trailing frame until its 0x00 arrives (the cart could not use it
        earlier anyway)."""
        buf = self._partial + data
        out = bytearray()
        start = 0
        while True:
            zero = buf.find(b"\x00", start)
            if zero < 0:
                break
            seg = bytes(buf[start:zero + 1])
            if seg == self.pong:
                self.pongs += 1
            else:
                out += seg
            start = zero + 1
        rest = buf[start:]
        if len(rest) > 2 * frames.max_encoded_len(frames.MAX_BODY):
            out += rest  # no terminator in sight: not ours, pass it on
            rest = bytearray()
        self._partial = bytearray(rest)
        return bytes(out)


class _Session(threading.Thread):
    """One local endpoint <-> one TCP connection to the hub."""

    def __init__(self, joiner: "Joiner", key: str, desc: object):
        super().__init__(name="join:%s" % key, daemon=True)
        self.j = joiner
        self.key = key
        self.desc = desc
        self.stopping = threading.Event()

    def run(self) -> None:
        backoff = self.j.backoff_min
        while not self.stopping.is_set():
            pinger = _Pinger(random.getrandbits(32))
            try:
                hub = self.j.connect()
            except (OSError, LinkClosed) as e:
                hub = None
                why = "hub unreachable: %s" % e
            else:
                try:
                    early = self._handshake(hub, pinger)
                    why = ""
                except (OSError, LinkClosed, _HubSilent) as e:
                    hub.close()
                    hub = None
                    why = "no answer from hub: %s" % (e or type(e).__name__)
            if hub is None:
                self.j._emit("disconnected", self.key, why)
                self.stopping.wait(backoff)
                backoff = min(backoff * 2, self.j.backoff_max)
                continue
            try:
                port = self.j.open_port(self.key, self.desc)
            except (OSError, LinkClosed) as e:
                hub.close()
                self.j._emit("removed", self.key, "cannot open: %s" % e)
                return
            backoff = self.j.backoff_min
            self.j._emit("connected", self.key)
            why = self._pump(hub, port, pinger, early)
            self.j._emit("disconnected", self.key, why)
            if why.startswith("port"):
                return  # badge or simulator gone; the next scan may add it again
            self.stopping.wait(self.j.backoff_min)

    def _handshake(self, hub: Link, pinger: _Pinger) -> bytes:
        """PING the hub, wait for our PONG. Returns any bytes after it."""
        hub.write(pinger.ping)
        end = time.monotonic() + self.j.handshake
        early = b""
        while pinger.pongs == 0:
            if self.stopping.is_set() or time.monotonic() > end:
                raise _HubSilent("timed out")
            early += pinger.filter(hub.read(POLL_S))
        return early

    def _pump(self, hub: Link, port: Link, pinger: _Pinger, early: bytes) -> str:
        done = threading.Event()
        why: list = []
        lock = threading.Lock()  # guards the liveness fields below
        last_heard = [time.monotonic()]
        ping_sent = [0.0]  # 0 = no PING outstanding

        def finish(reason: str) -> None:
            if not done.is_set():
                why.append(reason)
                done.set()

        def side(name: str, op, *args):
            try:
                return op(*args)
            except (OSError, LinkClosed) as e:
                finish("%s closed: %s" % (name, e))
                raise _Broken from None

        def hub_to_port() -> None:
            try:
                if early:
                    side("port", port.write, early)
                while not done.is_set():
                    data = side("hub", hub.read, POLL_S)
                    if not data:
                        continue
                    seen = pinger.pongs
                    out = pinger.filter(data)
                    with lock:
                        last_heard[0] = time.monotonic()
                        if pinger.pongs != seen:
                            ping_sent[0] = 0.0
                    if out:
                        side("port", port.write, out)
            except _Broken:
                pass

        def port_to_hub() -> None:
            # The only writer to the hub, so a PING never lands inside a frame.
            at_boundary = True
            try:
                while not done.is_set():
                    data = side("port", port.read, POLL_S)
                    if data:
                        side("hub", hub.write, data)
                        at_boundary = data.endswith(b"\x00")
                    now = time.monotonic()
                    with lock:
                        quiet = now - last_heard[0]
                        outstanding = ping_sent[0]
                    if outstanding and now - outstanding > self.j.dead_after:
                        return finish("hub silent for %.0f s" % (now - outstanding))
                    if not outstanding and quiet > self.j.heartbeat and at_boundary:
                        with lock:
                            ping_sent[0] = now
                        side("hub", hub.write, pinger.ping)
            except _Broken:
                pass

        threads = [threading.Thread(target=f, daemon=True) for f in (hub_to_port, port_to_hub)]
        for t in threads:
            t.start()
        while not done.wait(POLL_S):
            if self.stopping.is_set():
                finish("stopped")
        hub.close()
        port.close()
        for t in threads:
            t.join(1.0)
        return why[0]

    def stop(self) -> None:
        self.stopping.set()


class _Broken(Exception):
    pass


class Joiner:
    """Links every local endpoint to the hub, one TCP stream each.

    connect():             a new Link to the hub (raises OSError/LinkClosed)
    discover():            {key: descriptor} of local endpoints right now
    open_port(key, desc):  opens one endpoint as a Link (raises LinkClosed)

    Endpoints that appear get a session; endpoints that vanish lose theirs.
    A session outlives hub restarts (its port stays closed meanwhile) and
    ends when its port fails. Bytes are never reordered.
    """

    def __init__(self, connect: Callable[[], Link],
                 discover: Callable[[], Dict[str, object]],
                 open_port: Callable[[str, object], Link],
                 on_event: Callable[[JoinerEvent], None] = lambda e: None,
                 scan_interval: float = 1.0,
                 backoff_min: float = 0.5, backoff_max: float = 8.0,
                 handshake: float = HANDSHAKE_S, heartbeat: float = HEARTBEAT_S,
                 dead_after: float = DEAD_AFTER_S):
        self.connect = connect
        self.discover = discover
        self.open_port = open_port
        self.on_event = on_event
        self.scan_interval = scan_interval
        self.backoff_min = backoff_min
        self.backoff_max = backoff_max
        self.handshake = handshake
        self.heartbeat = heartbeat
        self.dead_after = dead_after
        self.sessions: Dict[str, _Session] = {}
        self._lock = threading.Lock()

    def _emit(self, kind: str, key: str, detail: str = "") -> None:
        self.on_event(JoinerEvent(kind, key, detail))

    def active(self) -> set:
        with self._lock:
            return {k for k, s in self.sessions.items() if s.is_alive()}

    def scan(self) -> None:
        found = self.discover()
        with self._lock:
            for key, s in list(self.sessions.items()):
                if not s.is_alive() or key not in found:
                    s.stop()
                    del self.sessions[key]
                    if key not in found:
                        self._emit("removed", key)
            for key, desc in found.items():
                if key not in self.sessions:
                    s = _Session(self, key, desc)
                    self.sessions[key] = s
                    self._emit("added", key)
                    s.start()

    def run(self, stop: threading.Event) -> None:
        try:
            while not stop.is_set():
                self.scan()
                stop.wait(self.scan_interval)
        finally:
            self.close()

    def close(self) -> None:
        with self._lock:
            sessions = list(self.sessions.values())
            self.sessions.clear()
        for s in sessions:
            s.stop()
        for s in sessions:
            s.join(2.0)


def tcp_connector(host: str, port: int, timeout: float = 5.0) -> Callable[[], Link]:
    def connect() -> Link:
        return SocketLink.connect(host, port, key="hub", label="hub", timeout=timeout)
    return connect


# ----------------------------------------------------------------- tailcat


class TailcatMissing(RuntimeError):
    def __init__(self) -> None:
        super().__init__(
            "tailcat not found. Install it from "
            "https://github.com/tailscale/tailcat#install "
            "(brew install tailcat, scoop install tailcat, a release binary, "
            "or go install github.com/tailscale/tailcat/cmd/tailcat@latest), "
            "or pass --tailcat-bin PATH.")


class TailcatError(RuntimeError):
    pass


_SERVE_LINE = re.compile(r"listening with (?:new address|saved key \"[^\"]*\"): (tc\S+)")
_FORWARD_LINE = re.compile(r"forwarding (\S+):(\d+) ->")


class TailcatProcess:
    """A running tailcat child; stderr is parsed for the line we wait for."""

    def __init__(self, argv: list[str], pattern: re.Pattern, timeout: float):
        self.argv = argv
        self.proc = subprocess.Popen(
            argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE, text=True, errors="replace")
        self.lines: list[str] = []
        self._match: Optional[re.Match] = None
        self._found = threading.Event()
        self._pattern = pattern
        threading.Thread(target=self._read, daemon=True).start()
        if not self._found.wait(timeout) or self._match is None:
            self.close()
            tail = "".join(self.lines[-5:]).strip() or "(no output)"
            raise TailcatError(f"{' '.join(argv[:2])} did not start: {tail}")

    def _read(self) -> None:
        assert self.proc.stderr is not None
        for line in self.proc.stderr:
            self.lines.append(line)
            if self._match is None:
                m = self._pattern.search(line)
                if m:
                    self._match = m
                    self._found.set()
        self.proc.stderr.close()
        self._found.set()  # exited; wake a waiter that has no match yet

    @property
    def match(self) -> re.Match:
        assert self._match is not None
        return self._match

    def alive(self) -> bool:
        return self.proc.poll() is None

    def close(self) -> None:
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(3)
            except subprocess.TimeoutExpired:
                self.proc.kill()


class Tailcat:
    def __init__(self, binary: Optional[str] = None, timeout: float = 30.0):
        self.binary = binary or self.find()
        self.timeout = timeout

    @staticmethod
    def find() -> str:
        path = shutil.which("tailcat")
        if path:
            return path
        for cand in ("~/.local/bin/tailcat", "~/go/bin/tailcat"):
            cand = os.path.expanduser(cand)
            if os.access(cand, os.X_OK):
                return cand
        raise TailcatMissing()

    def serve(self, port: int, key: Optional[str] = None) -> tuple[TailcatProcess, str]:
        """Serve local TCP `port`; returns (process, tailcat address).

        key=None forces a fresh one-run address (`--key=new`), so a saved
        `default` key is never picked up by surprise.
        """
        argv = [self.binary, "serve", f"--key={key or 'new'}", str(port)]
        p = TailcatProcess(argv, _SERVE_LINE, self.timeout)
        return p, p.match.group(1)

    def forward(self, address: str, remote_port: int) -> tuple[TailcatProcess, str, int]:
        """Forward a free local port to `remote_port` on the tailcat server."""
        argv = [self.binary, "forward", address, f"0:{remote_port}"]
        p = TailcatProcess(argv, _FORWARD_LINE, self.timeout)
        return p, p.match.group(1), int(p.match.group(2))

    def path(self, address: str, timeout: float = 10.0) -> str:
        """'direct via IP:PORT, 1.2ms' or 'relayed via DERP(sfo), 23ms'."""
        try:
            out = subprocess.run(
                [self.binary, "ping", "--until-direct", f"--timeout={int(timeout)}s", address],
                capture_output=True, text=True, timeout=timeout + 5)
        except (subprocess.TimeoutExpired, OSError) as e:
            return f"unknown ({e})"
        pongs = re.findall(r"pong in (\S+) via (\S+)", out.stdout + out.stderr)
        if not pongs:
            return "unknown (no pong)"
        rtt, via = pongs[-1]
        return f"relayed via {via}, {rtt}" if via.startswith("DERP") else f"direct via {via}, {rtt}"


# ------------------------------------------------------------- CLI glue


def join_hint(address: str, port: int = DEFAULT_PORT) -> str:
    extra = "" if port == DEFAULT_PORT else " --remote-port %d" % port
    return "others join with:  badge join %s%s" % (address, extra)


def add_lobby_args(sp) -> None:
    """`badge lobby` network flags."""
    g = sp.add_argument_group("network (players on other computers; fork/NET_LOBBY.md)")
    g.add_argument("--listen", nargs="?", const="%s:%d" % (DEFAULT_HOST, DEFAULT_PORT), metavar="[ADDR:]PORT",
                   help="accept `badge join` connections (default %s:%d; 0.0.0.0:%d for the whole LAN)"
                   % (DEFAULT_HOST, DEFAULT_PORT, DEFAULT_PORT))
    g.add_argument("--tailcat", action="store_true",
                   help="also serve the listen port over tailcat and print a join address (implies --listen)")
    g.add_argument("--tailcat-key", metavar="NAME",
                   help="saved tailcat key (tailcat genkey --key=NAME) for an address that survives restarts")
    g.add_argument("--tailcat-bin", metavar="PATH", help="tailcat binary (default: on PATH)")


def start_lobby_network(args, server, log) -> Callable[[], None]:
    """Adds --listen / --tailcat to a LobbyServer. Returns a cleanup function.
    Raises SystemExit with a message when the port or tailcat fails."""
    if not (args.listen or args.tailcat):
        return lambda: None
    host, port = parse_hostport(args.listen or "")
    try:
        src = ListenSource(host, port)
    except OSError as e:
        raise SystemExit("badge: cannot listen on %s:%d: %s" % (host, port, e))
    server.add_source(src)
    log("listening for `badge join` on %s:%d" % (src.host, src.port))
    tunnel = None
    if args.tailcat:
        if src.host not in ("127.0.0.1", "0.0.0.0", "::", "::1", "localhost"):
            log("! tailcat connects to localhost:%d, but --listen is bound to %s only" % (src.port, src.host))
        try:
            tunnel, address = Tailcat(args.tailcat_bin).serve(src.port, args.tailcat_key)
        except (TailcatMissing, TailcatError) as e:
            src.stop()
            raise SystemExit("badge: %s" % e)
        log("tailcat ready (%s address); %s"
            % ("saved" if args.tailcat_key else "one-run", join_hint(address, src.port)))
    elif src.host in ("0.0.0.0", "::"):
        log("others join with:  badge join <this computer's address>%s"
            % ("" if src.port == DEFAULT_PORT else ":%d" % src.port))

    def cleanup() -> None:
        src.stop()
        if tunnel:
            tunnel.close()
    return cleanup


def add_join_parser(sub) -> None:
    sp = sub.add_parser("join", help="put this computer's badges in a lobby running on another computer")
    sp.add_argument("target", help="the hub: a tailcat address (tc...) or HOST[:PORT] (default port %d)" % DEFAULT_PORT)
    sp.add_argument("--remote-port", type=int, default=DEFAULT_PORT, metavar="N",
                    help="the hub's --listen port, for tailcat targets (default %d)" % DEFAULT_PORT)
    sp.add_argument("--sim", metavar="PORTS", help="simulator ports, e.g. 7341,7342 or 7341-7344 (default 7341-7356)")
    sp.add_argument("--no-sim", action="store_true", help="ignore simulators")
    sp.add_argument("--no-usb", action="store_true", help="ignore USB badges")
    sp.add_argument("--port", action="append", metavar="PATH_OR_URL", help="also link this port or socket://host:port (repeatable)")
    sp.add_argument("--tailcat-bin", metavar="PATH", help="tailcat binary (default: on PATH)")
    sp.set_defaults(func=cmd_join)


def local_endpoints(args, active: Callable[[], set]) -> Callable[[], Dict[str, str]]:
    """discover() for `badge join`: USB cart ports, live simulators, --port.

    Keys match `badge lobby`'s (usb:<id>, sim:<port>). Simulators are probed
    only while not linked, so a linked one is never poked by a probe."""
    from . import discover

    sims = []
    if not args.no_sim:
        sims = discover.parse_sim_spec(args.sim) if args.sim else [(discover.SIM_HOST, p) for p in discover.SIM_PORTS]

    def sim_key(host: str, port: int) -> str:
        return "sim:%d" % port if host == discover.SIM_HOST else "sim:%s:%d" % (host, port)

    def find() -> Dict[str, str]:
        found: Dict[str, str] = {}
        if not args.no_usb:
            s = discover.scan(probe=False, drives=False)
            found.update({"usb:" + b.id: b.cart for b in s.badges if b.cart and not b.is_sim})
        linked = active()
        by_host: Dict[str, list] = {}
        for host, port in sims:
            if sim_key(host, port) in linked:
                found[sim_key(host, port)] = "socket://%s:%d" % (host, port)
            else:
                by_host.setdefault(host, []).append(port)
        for host, ports in by_host.items():
            for port in discover.probe_sims(ports, host=host):
                found[sim_key(host, port)] = "socket://%s:%d" % (host, port)
        for url in args.port or []:
            found[url] = url
        return found
    return find


def cmd_join(args, log=None, stop: Optional[threading.Event] = None) -> int:
    log = log or _tlog
    stop = stop or threading.Event()
    target = args.target.strip()
    tunnel = None
    if is_tailcat_address(target):
        try:
            tc = Tailcat(args.tailcat_bin)
            tunnel, host, port = tc.forward(target, args.remote_port)
        except (TailcatMissing, TailcatError) as e:
            log("badge: %s" % e)
            return 2

        def report_path() -> None:
            log("tailcat path: %s" % tc.path(target))
        threading.Thread(target=report_path, daemon=True).start()
        where = "tailcat " + target[:12] + "..."
    else:
        host, port = parse_hostport(target, default_host=target)
        where = "%s:%d" % (host, port)

    def on_event(e: JoinerEvent) -> None:
        text = {"added": "found", "connected": "in the lobby", "disconnected": "waiting for hub",
                "removed": "gone"}[e.kind]
        log("%s: %s%s" % (e.key, text, " (%s)" % e.detail if e.detail else ""))

    joiner: Optional[Joiner] = None
    joiner = Joiner(tcp_connector(host, port),
                    local_endpoints(args, lambda: joiner.active() if joiner else set()),
                    lambda key, url: open_link(url, key=key, label=key, timeout=0.5),
                    on_event)
    log("joining the lobby at %s; Ctrl-C stops" % where)
    try:
        joiner.run(stop)
    except KeyboardInterrupt:
        pass
    finally:
        if tunnel:
            tunnel.close()
    return 0


def _tlog(msg: str) -> None:
    print("%s %s" % (time.strftime("%H:%M:%S"), msg), flush=True)
