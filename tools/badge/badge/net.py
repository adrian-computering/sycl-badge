"""Network lobby: badges on different computers share one `badge lobby`.

One computer runs the hub: an ordinary `badge lobby` that also listens for
TCP connections (`Listener`). Every accepted connection is one remote
player, and its byte stream is exactly what a cart serial port carries
(lobby protocol v1 COBS frames), so the relay treats it like another badge.

Other computers run `badge join` (`Joiner`). For every local badge or
simulator it opens one TCP connection to the hub and copies bytes both ways
without decoding them. While the hub cannot be reached the badge's cart port
stays closed, so the cart sees `connected()` false and shows "waiting for
host"; when the link comes back the port reopens and the cart says HELLO
again, as CART_SERIAL.md requires.

The hub is reached by `host:port` (same LAN, Tailscale, ssh -L) or by a
tailcat address (`Tailcat`): https://github.com/tailscale/tailcat gives a
WireGuard tunnel with NAT traversal and no account. The hub runs
`tailcat serve PORT`; a joiner runs `tailcat forward ADDR 0:PORT` and
connects to the local end.

Spec and plan: fork/NET_LOBBY.md. Standard library only.
"""

from __future__ import annotations

import os
import re
import shutil
import socket
import subprocess
import threading
import time
from dataclasses import dataclass
from typing import Callable, Dict, Hashable, Optional, Protocol

DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 7360

# Bytes copied per read, and how long a blocking read waits before
# re-checking whether the session should stop.
CHUNK = 4096
POLL_S = 0.05


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


def _tune(sock: socket.socket) -> socket.socket:
    # Lobby frames are small and latency matters more than throughput.
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    return sock


# ---------------------------------------------------------------- hub side


class Listener:
    """Accepts remote players for the hub's relay.

    `accept()` returns a connected socket (TCP_NODELAY set) or None after
    `timeout`. The relay wraps each socket as a player link; when the socket
    closes, that player leaves.
    """

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
        return _tune(conn)

    def close(self) -> None:
        self._sock.close()

    def __enter__(self) -> "Listener":
        return self

    def __exit__(self, *exc) -> None:
        self.close()


# ------------------------------------------------------------- joiner side


class Port(Protocol):
    """A local cart byte stream: a badge's cart serial port or a simulator.

    Opening it raises DTR (or connects to the simulator); `close()` drops it,
    which the cart sees as the host going away.
    """

    def read(self, n: int, timeout: float) -> bytes:
        """Up to n bytes, b"" on timeout. Raises OSError when the port is gone."""

    def write(self, data: bytes) -> None: ...

    def close(self) -> None: ...


@dataclass
class JoinerEvent:
    kind: str  # "added", "connected", "disconnected", "removed"
    key: Hashable
    detail: str = ""


class _Broken(Exception):
    pass


class _Session(threading.Thread):
    """One local endpoint <-> one TCP connection to the hub."""

    def __init__(self, joiner: "Joiner", key: Hashable, desc: object):
        super().__init__(name=f"join:{key}", daemon=True)
        self.j = joiner
        self.key = key
        self.desc = desc
        self.stopping = threading.Event()

    def run(self) -> None:
        backoff = self.j.backoff_min
        while not self.stopping.is_set():
            try:
                hub = self.j.connect()
            except OSError as e:
                self.j._emit("disconnected", self.key, f"hub unreachable: {e}")
                self.stopping.wait(backoff)
                backoff = min(backoff * 2, self.j.backoff_max)
                continue
            try:
                port = self.j.open_port(self.desc)
            except OSError as e:
                hub.close()
                self.j._emit("removed", self.key, f"port failed: {e}")
                return
            backoff = self.j.backoff_min
            self.j._emit("connected", self.key)
            why = self._pump(hub, port)
            self.j._emit("disconnected", self.key, why)
            if why.startswith("port"):
                return  # badge gone; discovery may add it again
            self.stopping.wait(self.j.backoff_min)

    def _pump(self, hub: socket.socket, port: Port) -> str:
        done = threading.Event()
        why: list[str] = []

        def finish(reason: str) -> None:
            if not done.is_set():
                why.append(reason)
                done.set()

        def side(name: str, op, *args):
            # Run one I/O call; on failure record which side broke.
            try:
                return op(*args)
            except socket.timeout:
                raise  # an idle poll, not a failure
            except OSError as e:
                finish(f"{name} error: {e}")
                raise _Broken from None

        def hub_to_port() -> None:
            hub.settimeout(POLL_S)
            try:
                while not done.is_set():
                    try:
                        data = side("hub", hub.recv, CHUNK)
                    except socket.timeout:
                        continue
                    if not data:
                        return finish("hub closed")
                    side("port", port.write, data)
            except _Broken:
                pass

        def port_to_hub() -> None:
            try:
                while not done.is_set():
                    data = side("port", port.read, CHUNK, POLL_S)
                    if data:
                        side("hub", hub.sendall, data)
            except _Broken:
                pass

        try:
            # A lone 0x00 ends any partial frame on either side (protocol v1).
            side("hub", hub.sendall, b"\x00")
            side("port", port.write, b"\x00")
        except _Broken:
            pass
        threads = [threading.Thread(target=f, daemon=True)
                   for f in (hub_to_port, port_to_hub)]
        if not done.is_set():
            for t in threads:
                t.start()
        while not done.wait(POLL_S):
            if self.stopping.is_set():
                finish("stopped")
        for s in (hub, port):
            try:
                s.close()
            except OSError:
                pass
        for t in threads:
            if t.is_alive():
                t.join(1.0)
        return why[0]

    def stop(self) -> None:
        self.stopping.set()


class Joiner:
    """Links every local endpoint to the hub, one TCP stream each.

    connect():        a new connected socket to the hub (raises OSError)
    discover():       {key: descriptor} of local endpoints right now
    open_port(desc):  opens one endpoint as a `Port` (raises OSError)

    Endpoints that appear get a session; endpoints that vanish lose theirs.
    A session survives hub restarts (closing the port meanwhile) and ends
    when its port fails.
    """

    def __init__(self, connect: Callable[[], socket.socket],
                 discover: Callable[[], Dict[Hashable, object]],
                 open_port: Callable[[object], Port],
                 on_event: Callable[[JoinerEvent], None] = lambda e: None,
                 scan_interval: float = 1.0,
                 backoff_min: float = 0.5, backoff_max: float = 8.0):
        self.connect = connect
        self.discover = discover
        self.open_port = open_port
        self.on_event = on_event
        self.scan_interval = scan_interval
        self.backoff_min = backoff_min
        self.backoff_max = backoff_max
        self.sessions: Dict[Hashable, _Session] = {}
        self._lock = threading.Lock()

    def _emit(self, kind: str, key: Hashable, detail: str = "") -> None:
        self.on_event(JoinerEvent(kind, key, detail))

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
        while not stop.is_set():
            self.scan()
            stop.wait(self.scan_interval)
        self.close()

    def close(self) -> None:
        with self._lock:
            sessions = list(self.sessions.values())
            self.sessions.clear()
        for s in sessions:
            s.stop()
        for s in sessions:
            s.join(2.0)


def tcp_connector(host: str, port: int, timeout: float = 5.0) -> Callable[[], socket.socket]:
    def connect() -> socket.socket:
        sock = socket.create_connection((host, port), timeout=timeout)
        sock.settimeout(None)
        return _tune(sock)
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


# ------------------------------------------------------------- CLI helpers


def join_command(target: str, discover, open_port, *, tailcat_bin: Optional[str] = None,
                 remote_port: int = DEFAULT_PORT, log=print,
                 stop: Optional[threading.Event] = None) -> int:
    """`badge join TARGET`: runs until Ctrl-C (or `stop`). Returns an exit code."""
    stop = stop or threading.Event()
    tunnel = None
    try:
        if is_tailcat_address(target):
            tc = Tailcat(tailcat_bin)
            log("starting tailcat tunnel to the hub...")
            tunnel, host, port = tc.forward(target.strip(), remote_port)

            def report_path() -> None:
                log(f"tailcat path: {tc.path(target.strip())}")
            threading.Thread(target=report_path, daemon=True).start()
        else:
            host, port = parse_hostport(target, default_host=target)
    except (TailcatMissing, TailcatError) as e:
        log(f"error: {e}")
        return 2

    def on_event(e: JoinerEvent) -> None:
        log(f"{e.key}: {e.kind}{' (' + e.detail + ')' if e.detail else ''}")

    log(f"joining hub at {target if tunnel else f'{host}:{port}'}; Ctrl-C to stop")
    joiner = Joiner(tcp_connector(host, port), discover, open_port, on_event)
    try:
        joiner.run(stop)
    except KeyboardInterrupt:
        joiner.close()
    finally:
        if tunnel:
            tunnel.close()
    return 0


def start_hub_tailcat(port: int, key: Optional[str] = None,
                      tailcat_bin: Optional[str] = None) -> tuple[TailcatProcess, str]:
    """`badge lobby --tailcat`: serve the hub's listen port over tailcat."""
    return Tailcat(tailcat_bin).serve(port, key)


def join_hint(address: str) -> str:
    return f"others join with:\n\n    badge join {address}\n"


def wait_listening(host: str, port: int, timeout: float = 5.0) -> bool:
    """True once something accepts on host:port (tests and scripts)."""
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        try:
            socket.create_connection((host, port), timeout=0.5).close()
            return True
        except OSError:
            time.sleep(0.05)
    return False
