"""`badge monitor`: watch and talk to a cart serial port."""

from __future__ import annotations

import sys
import threading
import time

from . import frames
from .links import Link, LinkClosed

EOLS = {"lf": b"\n", "cr": b"\r", "crlf": b"\r\n", "none": b""}


def format_text(data: bytes) -> str:
    out = []
    for b in data:
        if b in (9, 10) or 0x20 <= b < 0x7F:
            out.append(chr(b))
        elif b == 13:
            continue
        else:
            out.append("\\x%02x" % b)
    return "".join(out)


def format_hex(data: bytes, offset: int) -> str:
    lines = []
    for i in range(0, len(data), 16):
        chunk = data[i : i + 16]
        text = "".join(chr(b) if 0x20 <= b < 0x7F else "." for b in chunk)
        lines.append("%08x  %-47s  |%s|" % (offset + i, chunk.hex(" "), text))
    return "\n".join(lines) + "\n"


def run(link: Link, mode: str = "text", eol: str = "lf", out=None) -> int:
    """mode: text | hex | frames. Reads stdin lines and sends them."""
    out = out or sys.stdout
    stop = threading.Event()
    decoder = frames.FrameDecoder()
    t0 = time.time()

    def reader():
        offset = 0
        try:
            while not stop.is_set():
                data = link.read(0.2)
                if not data:
                    continue
                if mode == "hex":
                    out.write(format_hex(data, offset))
                    offset += len(data)
                elif mode == "frames":
                    dropped = decoder.dropped
                    for body in decoder.feed(data):
                        try:
                            text = frames.describe(frames.unpack(body))
                        except frames.MalformedMessage as e:
                            text = "MALFORMED %s (%s)" % (body.hex(" "), e)
                        out.write("%8.3f <- %s\n" % (time.time() - t0, text))
                    if decoder.dropped != dropped:
                        out.write("%8.3f !! %d undecodable frame(s)\n" % (time.time() - t0, decoder.dropped - dropped))
                else:
                    out.write(format_text(data))
                out.flush()
        except LinkClosed as e:
            out.write("\n--- port closed: %s ---\n" % e)
            out.flush()
            stop.set()

    th = threading.Thread(target=reader, daemon=True)
    th.start()
    if mode == "frames":
        link.write(b"\x00")
        sys.stderr.write(
            "--- frames mode: type e.g. 'welcome 0 1 4', 'data 1 hello', 'pong 7', "
            "'roster 0=me 1=you', 'raw 83 01 41'; Ctrl-D or Ctrl-C quits ---\n"
        )
    else:
        sys.stderr.write("--- %s: lines you type are sent; Ctrl-D or Ctrl-C quits ---\n" % link.label)
    try:
        while not stop.is_set():
            line = sys.stdin.readline()
            if not line:
                break
            line = line.rstrip("\r\n")
            try:
                if mode == "frames":
                    if not line.strip():
                        continue
                    body = frames.parse_command(line)
                    link.write(frames.encode(body))
                    try:
                        desc = frames.describe(frames.unpack(body))
                    except frames.MalformedMessage:
                        desc = body.hex(" ")
                    out.write("%8.3f -> %s\n" % (time.time() - t0, desc))
                    out.flush()
                else:
                    link.write(line.encode("utf-8") + EOLS[eol])
            except ValueError as e:
                sys.stderr.write("!! %s\n" % e)
            except LinkClosed:
                break
    except KeyboardInterrupt:
        pass
    finally:
        stop.set()
        link.close()
    return 0
