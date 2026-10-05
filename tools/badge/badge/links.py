"""Byte-stream links to a badge's cart port, a simulator, or any peer.

A Link is the one path by which bytes reach the lobby relay (and `badge
monitor`). Every link has the same small interface:

    link.key            stable id (USB serial + "cart", "sim:7341", ...)
    link.label          short human name for logs
    link.read(timeout)  -> bytes; b"" when nothing arrived within `timeout`
                           seconds; raises LinkClosed when the peer is gone
    link.write(data)    blocking write of all of `data`; raises LinkClosed
    link.close()        idempotent; unblocks a reader or writer in another
                        thread
    link.closed         True once closed (by either side)

Optional fast path (the lobby relay uses it when fileno() is not None, so
one thread serves every such link through a selector):

    link.fileno()         -> int, or None when the link cannot be selected
    link.read_nowait()    -> bytes available now (b"" if none); raises
                             LinkClosed at end of stream
    link.write_nowait(b)  -> number of bytes written (0 if it would block)

Calling read_nowait / write_nowait puts the link in non-blocking mode for
good; use either the blocking or the non-blocking calls on one link.

Implementations: SerialLink (pyserial, DTR asserted, used for badge cart
ports; selectable on Linux and macOS, threads on Windows) and SocketLink (a
connected TCP socket: simulators, and inbound connections accepted by a
network lobby). open_link(url) picks one.
"""

from __future__ import annotations

import errno
import os
import select
import socket
import threading
from typing import Optional, Tuple


class LinkClosed(Exception):
    """The link is closed or the peer went away."""


class Link:
    key: str = ""
    label: str = ""

    def __init__(self) -> None:
        self.closed = False

    def read(self, timeout: float = 0.2) -> bytes:  # pragma: no cover - interface
        raise NotImplementedError

    def write(self, data: bytes) -> None:  # pragma: no cover - interface
        raise NotImplementedError

    def close(self) -> None:  # pragma: no cover - interface
        self.closed = True

    def fileno(self) -> Optional[int]:
        return None

    def read_nowait(self) -> bytes:  # pragma: no cover - interface
        raise NotImplementedError

    def write_nowait(self, data: bytes) -> int:  # pragma: no cover - interface
        raise NotImplementedError

    def __repr__(self) -> str:
        return "<%s %s>" % (type(self).__name__, self.key or self.label)


# Lobby traffic is small (16 players x 60 Hz is about 10 KB/s per link), so a
# 4 KB send buffer (Linux doubles it) does not limit throughput, even over a
# tunnel with 100 ms round trips.
SOCKET_SNDBUF = 4 * 1024


class SocketLink(Link):
    """A connected stream socket. Reads use select, writes block."""

    def __init__(self, sock: socket.socket, key: str = "", label: str = ""):
        super().__init__()
        self.sock = sock
        self.key = key
        self.label = label or key
        self._lock = threading.Lock()
        self._nonblocking = False
        sock.setblocking(True)
        try:
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        except OSError:
            pass
        try:
            # A small kernel buffer, so a peer that stops reading shows up as
            # a stuck write within a few KB instead of after the OS default
            # (often 45 KB+), and the relay's stall rules can see it.
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, SOCKET_SNDBUF)
        except OSError:
            pass

    @classmethod
    def connect(cls, host: str, port: int, key: str = "", label: str = "", timeout: float = 1.0) -> "SocketLink":
        sock = socket.create_connection((host, port), timeout=timeout)
        sock.settimeout(None)
        return cls(sock, key=key or "tcp:%s:%d" % (host, port), label=label)

    def read(self, timeout: float = 0.2) -> bytes:
        if self.closed:
            raise LinkClosed("closed")
        try:
            ready, _, _ = select.select([self.sock], [], [], timeout)
            if not ready:
                return b""
            data = self.sock.recv(4096)
        except (OSError, ValueError) as e:
            self.close()
            raise LinkClosed(str(e))
        if not data:
            self.close()
            raise LinkClosed("peer closed the connection")
        return data

    def write(self, data: bytes) -> None:
        if self.closed:
            raise LinkClosed("closed")
        try:
            self.sock.sendall(data)
        except OSError as e:
            self.close()
            raise LinkClosed(str(e))

    def fileno(self) -> Optional[int]:
        return None if self.closed else self.sock.fileno()

    def _go_nonblocking(self) -> None:
        if not self._nonblocking:
            self.sock.setblocking(False)
            self._nonblocking = True

    def read_nowait(self) -> bytes:
        if self.closed:
            raise LinkClosed("closed")
        self._go_nonblocking()
        try:
            data = self.sock.recv(65536)
        except (BlockingIOError, InterruptedError):
            return b""
        except OSError as e:
            self.close()
            raise LinkClosed(str(e))
        if not data:
            self.close()
            raise LinkClosed("peer closed the connection")
        return data

    def write_nowait(self, data: bytes) -> int:
        if self.closed:
            raise LinkClosed("closed")
        self._go_nonblocking()
        try:
            return self.sock.send(data)
        except (BlockingIOError, InterruptedError):
            return 0
        except OSError as e:
            self.close()
            raise LinkClosed(str(e))

    def close(self) -> None:
        with self._lock:
            if self.closed:
                return
            self.closed = True
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            self.sock.close()
        except OSError:
            pass


class SerialLink(Link):
    """A serial port (USB CDC) through pyserial, opened with DTR asserted.

    The fork firmware treats DTR as "host connected": while it is low, bytes
    the cart writes are discarded.
    """

    def __init__(self, device: str, key: str = "", label: str = "", exclusive: bool = True):
        super().__init__()
        import serial  # imported here so frames/discover work without pyserial

        self.device = device
        self.key = key or device
        self.label = label or device
        self._serial_mod = serial
        kwargs = dict(baudrate=115200, timeout=0.2, write_timeout=None, rtscts=False, dsrdtr=False)
        if exclusive and os.name == "posix":
            kwargs["exclusive"] = True  # posix only: refuse a port another program holds
        try:
            port = serial.Serial(**kwargs)
            port.port = device
            # Open with DTR low, then raise it. pyserial flushes the input
            # buffer inside open(), after setting the lines; a cart that
            # answers DTR with HELLO right away would lose it. The firmware
            # discards cart output while DTR is low, so nothing stale waits.
            port.dtr = False
            port.rts = True
            port.open()
            try:
                port.dtr = True
            except OSError as e:
                # ptys and some adapters have no modem lines; open() ignores
                # the same errors.
                if e.errno not in (errno.EINVAL, errno.ENOTTY):
                    raise
        except (serial.SerialException, OSError, ValueError) as e:
            raise LinkClosed(str(e))
        self.port = port
        self._lock = threading.Lock()
        self._nonblocking = False

    def read(self, timeout: float = 0.2) -> bytes:
        if self.closed:
            raise LinkClosed("closed")
        try:
            if self.port.timeout != timeout:
                self.port.timeout = timeout
            data = self.port.read(1)
            if data:
                waiting = self.port.in_waiting
                if waiting:
                    data += self.port.read(waiting)
            return data
        except Exception as e:  # SerialException, OSError, TypeError on a closed fd
            self.close()
            raise LinkClosed(str(e) or type(e).__name__)

    def write(self, data: bytes) -> None:
        if self.closed:
            raise LinkClosed("closed")
        try:
            self.port.write(data)
        except Exception as e:
            self.close()
            raise LinkClosed(str(e) or type(e).__name__)

    def fileno(self) -> Optional[int]:
        if os.name != "posix" or self.closed:
            return None  # Windows serial handles cannot be selected
        try:
            return self.port.fileno()
        except Exception:
            return None

    def _fd(self) -> int:
        fd = self.port.fileno()
        if not self._nonblocking:
            import fcntl

            fcntl.fcntl(fd, fcntl.F_SETFL, fcntl.fcntl(fd, fcntl.F_GETFL) | os.O_NONBLOCK)
            self._nonblocking = True
        return fd

    def read_nowait(self) -> bytes:
        if self.closed:
            raise LinkClosed("closed")
        try:
            data = os.read(self._fd(), 65536)
        except (BlockingIOError, InterruptedError):
            return b""
        except Exception as e:  # EIO when the badge is unplugged
            self.close()
            raise LinkClosed(str(e) or type(e).__name__)
        if not data:
            # readable but empty: the device went away (pyserial treats it so too)
            self.close()
            raise LinkClosed("device disconnected")
        return data

    def write_nowait(self, data: bytes) -> int:
        if self.closed:
            raise LinkClosed("closed")
        try:
            return os.write(self._fd(), data)
        except (BlockingIOError, InterruptedError):
            return 0
        except Exception as e:
            self.close()
            raise LinkClosed(str(e) or type(e).__name__)

    def close(self) -> None:
        with self._lock:
            if self.closed:
                return
            self.closed = True
        for cancel in ("cancel_write", "cancel_read"):
            try:
                getattr(self.port, cancel)()
            except Exception:
                pass
        try:
            self.port.close()
        except Exception:
            pass


def parse_tcp_url(url: str) -> Optional[Tuple[str, int]]:
    """'socket://host:port', 'tcp://host:port' -> (host, port), else None."""
    for scheme in ("socket://", "tcp://"):
        if url.startswith(scheme):
            rest = url[len(scheme) :].split("/", 1)[0].split("?", 1)[0]
            host, _, port = rest.rpartition(":")
            if not host or not port.isdigit():
                raise ValueError("bad TCP url %r (want %shost:port)" % (url, scheme))
            return host.strip("[]"), int(port)
    return None


def open_link(url: str, key: str = "", label: str = "", timeout: float = 1.0) -> Link:
    """Open a serial device path or a socket://host:port / tcp://host:port URL."""
    tcp = parse_tcp_url(url)
    if tcp is not None:
        try:
            return SocketLink.connect(tcp[0], tcp[1], key=key or url, label=label or url, timeout=timeout)
        except OSError as e:
            raise LinkClosed(str(e))
    return SerialLink(url, key=key or url, label=label or url)
