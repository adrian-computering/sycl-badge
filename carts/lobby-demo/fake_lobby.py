#!/usr/bin/env python3
"""Scripted check of lobby-demo against a fake lobby, no badge tool needed.

Start the simulator headless, then run this against its cart serial port:

    SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy zig-out/sim/lobby-demo &
    python3 carts/lobby-demo/fake_lobby.py --port 7341

It plays the host side of lobby protocol v1 (fork/CART_SERIAL.md) for one
cart: expects the leading 0x00 and HELLO, sends WELCOME, ROSTER and DATA,
checks that the cart broadcasts its position, answers PING with PONG, then
drops the connection and checks that the cart says HELLO again on reconnect.
Exits 0 on success. Python 3.9+, standard library only.
"""

import argparse
import socket
import struct
import sys
import time


def cobs_encode(body: bytes) -> bytes:
    out = bytearray([0])
    code_index, code = 0, 1
    for b in body:
        if b == 0:
            out[code_index] = code
            code_index, code = len(out), 1
            out.append(0)
        else:
            out.append(b)
            code += 1
            if code == 0xFF:
                out[code_index] = code
                code_index, code = len(out), 1
                out.append(0)
    out[code_index] = code
    return bytes(out)


def cobs_decode(data: bytes):
    out, i = bytearray(), 0
    while i < len(data):
        code = data[i]
        if code == 0 or i + code > len(data):
            return None
        out += data[i + 1 : i + code]
        i += code
        if code != 0xFF and i < len(data):
            out.append(0)
    return bytes(out)


class Conn:
    def __init__(self, port: int):
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=5)
        self.buf = bytearray()
        self.raw = bytearray()  # every byte received, for checks

    def send(self, body: bytes):
        self.sock.sendall(cobs_encode(body) + b"\x00")

    def frame(self, timeout=5.0):
        """Next non-empty frame body, or None on timeout."""
        deadline = time.monotonic() + timeout
        while True:
            if 0 in self.buf:
                i = self.buf.index(0)
                enc, self.buf = bytes(self.buf[:i]), self.buf[i + 1 :]
                if enc:
                    body = cobs_decode(enc)
                    if body:
                        return body
                continue
            left = deadline - time.monotonic()
            if left <= 0:
                return None
            self.sock.settimeout(left)
            try:
                chunk = self.sock.recv(4096)
            except socket.timeout:
                return None
            if not chunk:
                raise ConnectionError("simulator closed the connection")
            self.buf += chunk
            self.raw += chunk

    def expect(self, kind: int, timeout=5.0, skip=(0x03,)):
        """Wait for a frame of `kind`, answering PINGs on the way."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            body = self.frame(deadline - time.monotonic())
            if body is None:
                break
            if body[0] == kind:
                return body
            if body[0] == 0x03:  # PING -> PONG
                self.send(b"\x84" + body[1:5])
            elif body[0] not in skip:
                print(f"  (ignoring frame {body.hex()})")
        raise AssertionError(f"no frame of type 0x{kind:02x} within {timeout}s")

    def close(self):
        self.sock.close()


def name12(s: bytes) -> bytes:
    return s[:12].ljust(12, b"\x00")


def check(cond, what):
    if not cond:
        raise AssertionError(what)
    print(f"ok  {what}")


def run(port: int):
    c = Conn(port)
    hello = c.expect(0x01)
    check(c.raw[:1] == b"\x00", "cart sent a leading 0x00 on connect")
    check(len(hello) == 23 and hello[1] == 1, "HELLO is version 1, 23-byte body")
    game = hello[2:10].rstrip(b"\x00")
    name = hello[10:22].rstrip(b"\x00")
    check(game == b"DOTS", f"HELLO game id {game!r}")
    check(len(name) > 0, f"HELLO name {name!r}")
    check(hello[22] == 16, "HELLO max_players 16")

    you = 3
    c.send(bytes([0x81, 1, you, 0, 16]))  # WELCOME
    c.send(bytes([0x82, 2, 0]) + name12(b"HOST") + bytes([you]) + name12(name))  # ROSTER
    c.send(bytes([0x83, 0, ord("P"), 40, 50]))  # DATA from player 0

    # The cart answers the roster with its position, to everyone else.
    send = c.expect(0x02)
    check(send[1] == 0xFF, "SEND goes to everyone else (0xFF)")
    check(len(send) == 5 and send[2] == ord("P"), f"SEND carries a position {send[2:].hex()}")

    # It pings right after joining, and keeps sending a heartbeat.
    ping = c.expect(0x03, skip=(0x02,))
    check(len(ping) == 5, "PING carries a 4-byte token")
    c.send(b"\x84" + ping[1:5])
    beat = c.expect(0x02, timeout=3)
    check(beat[1] == 0xFF, "heartbeat SEND within a second or two")

    # Lobby goes away and comes back: the cart says HELLO again.
    c.close()
    time.sleep(0.5)
    c = Conn(port)
    hello2 = c.expect(0x01)
    check(c.raw[:1] == b"\x00", "leading 0x00 again on reconnect")
    check(hello2 == hello, "same HELLO on reconnect")

    # Not welcomed yet: the cart must not send game data.
    try:
        body = c.expect(0x02, timeout=1.5, skip=(0x01,))
        raise AssertionError(f"SEND before WELCOME: {body.hex()}")
    except AssertionError as e:
        if "SEND before" in str(e):
            raise
    check(True, "no SEND before WELCOME")
    c.send(bytes([0x81, 1, 0, 0, 16]))
    c.send(bytes([0x82, 1, 0]) + name12(name))
    send = c.expect(0x02)
    check(send[1] == 0xFF, "rejoined and broadcasting again")
    c.close()


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--port", type=int, default=7341)
    args = ap.parse_args()
    try:
        run(args.port)
    except (AssertionError, ConnectionError, OSError) as e:
        print(f"FAIL {e}")
        sys.exit(1)
    print("PASS")


if __name__ == "__main__":
    main()
