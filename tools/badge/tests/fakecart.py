"""A fake simulator: a TCP endpoint speaking the cart side of protocol v1.

Like the real simulator it listens on a port and treats an accepted
connection as "host connected" (DTR high), sending HELLO when one arrives.
"""

import os
import socket
import sys
import threading
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from badge import frames  # noqa: E402


class FakeCart:
    def __init__(self, game="TEST", name="cart", max_players=0, host="127.0.0.1", port=0, hello=True):
        self.game = game
        self.name = name
        self.max_players = max_players
        self.hello = hello
        self.srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.srv.bind((host, port))
        self.srv.listen(4)
        self.host, self.port = self.srv.getsockname()
        self.conn = None
        self.msgs = []  # decoded messages, in order
        self.raw = bytearray()
        self.cond = threading.Condition()
        self.connections = 0
        self._closed = False
        self._t = threading.Thread(target=self._accept_loop, daemon=True)
        self._t.start()

    # -- control ---------------------------------------------------------

    def send_body(self, body: bytes) -> None:
        conn = self.wait_connected()
        conn.sendall(frames.encode(body))

    def send(self, to: int, data: bytes) -> None:
        self.send_body(frames.Send(to=to, data=data).pack())

    def send_raw(self, data: bytes) -> None:
        self.wait_connected().sendall(data)

    def wait_connected(self, timeout=5.0):
        end = time.time() + timeout
        with self.cond:
            while self.conn is None:
                left = end - time.time()
                if left <= 0:
                    raise TimeoutError("lobby never connected to fake cart on port %d" % self.port)
                self.cond.wait(left)
            return self.conn

    def wait_for(self, pred, timeout=5.0):
        """Wait until pred(msgs) is truthy; return its value."""
        end = time.time() + timeout
        with self.cond:
            while True:
                v = pred(self.msgs)
                if v:
                    return v
                left = end - time.time()
                if left <= 0:
                    raise TimeoutError("condition not met; got %r" % [frames.describe(m) for m in self.msgs])
                self.cond.wait(left)

    def of(self, cls):
        with self.cond:
            return [m for m in self.msgs if isinstance(m, cls)]

    def drop_connection(self) -> None:
        """Close the current connection (like the simulator quitting)."""
        with self.cond:
            conn, self.conn = self.conn, None
        if conn:
            try:
                conn.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            conn.close()

    def close(self) -> None:
        self._closed = True
        self.drop_connection()
        try:
            self.srv.close()
        except OSError:
            pass

    # -- threads ---------------------------------------------------------

    def _accept_loop(self):
        while not self._closed:
            try:
                conn, _ = self.srv.accept()
            except OSError:
                return
            conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            with self.cond:
                old, self.conn = self.conn, conn
                self.connections += 1
                self.cond.notify_all()
            if old:
                old.close()
            if self.hello:
                conn.sendall(b"\x00" + frames.encode(frames.Hello(game=self.game, name=self.name, max_players=self.max_players).pack()))
            threading.Thread(target=self._read_loop, args=(conn,), daemon=True).start()

    def _read_loop(self, conn):
        dec = frames.FrameDecoder()
        while True:
            try:
                data = conn.recv(4096)
            except OSError:
                data = b""
            if not data:
                with self.cond:
                    if self.conn is conn:
                        self.conn = None
                    self.cond.notify_all()
                return
            bodies = dec.feed(data)
            with self.cond:
                self.raw += data
                for b in bodies:
                    self.msgs.append(frames.unpack(b))
                self.cond.notify_all()
