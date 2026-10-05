"""`badge echo-test`: measure cart serial round trips through serial-echo.

Run the serial-echo cart on the badge (or simulator), then this sends
fixed-size timestamped records at a steady rate and times each one coming
back. Half the round trip approximates one direction of the USB path, so
badge -> lobby -> badge costs about one round trip plus the relay.

Every record is `magic, seq: u32, sent_ns: u64` padded to `size` bytes. The
echo preserves order, so records are parsed back in sequence; anything that
does not line up counts as an error.
"""

from __future__ import annotations

import struct
import time
from typing import List, Optional

from .links import Link, LinkClosed

MAGIC = 0xEC
HEADER = struct.Struct("<BIQ")


def percentile(sorted_vals: List[float], p: float) -> float:
    if not sorted_vals:
        return float("nan")
    i = min(len(sorted_vals) - 1, max(0, int(round(p / 100.0 * (len(sorted_vals) - 1)))))
    return sorted_vals[i]


def run(link: Link, rate: float = 60.0, size: int = 16, seconds: float = 10.0, out=print) -> int:
    if size < HEADER.size:
        raise ValueError("size must be at least %d" % HEADER.size)
    # Drain whatever the cart had queued, then check that it echoes at all.
    _drain(link, 0.3)
    if not _probe(link):
        out("no echo: is the serial-echo cart running, and is this the cart port?")
        return 1

    pad = bytes(size - HEADER.size)
    rtts: List[float] = []
    errors = 0
    buf = bytearray()
    sent = 0
    received = 0
    interval = 1.0 / rate
    start = time.monotonic()
    next_send = start
    deadline = start + seconds
    while True:
        now = time.monotonic()
        if now < deadline and now >= next_send:
            link.write(HEADER.pack(MAGIC, sent, time.perf_counter_ns()) + pad)
            sent += 1
            next_send += interval
        if now >= deadline and received >= sent:
            break
        if now >= deadline + 2.0:
            break  # give stragglers two seconds
        wait = max(0.0, min(next_send - time.monotonic(), 0.005)) if now < deadline else 0.05
        try:
            data = link.read(wait)
        except LinkClosed as e:
            out("port closed: %s" % e)
            return 1
        if not data:
            continue
        got = time.perf_counter_ns()
        buf += data
        while len(buf) >= size:
            magic, seq, t0 = HEADER.unpack_from(buf)
            del buf[:size]
            if magic != MAGIC or seq != received:
                errors += 1
                received = seq + 1 if magic == MAGIC else received + 1
                continue
            rtts.append((got - t0) / 1e6)
            received += 1

    elapsed = time.monotonic() - start
    rtts.sort()
    out("sent %d records of %d bytes at %g Hz (%.1f KB/s each way)" % (sent, size, rate, sent * size / elapsed / 1024))
    out("echoed %d, lost %d, out of order/corrupt %d" % (len(rtts), sent - len(rtts) - errors, errors))
    if rtts:
        out(
            "round trip: p50 %.2f ms, p99 %.2f ms, max %.2f ms (one way ~ half)"
            % (percentile(rtts, 50), percentile(rtts, 99), rtts[-1])
        )
    return 0 if rtts and errors == 0 and len(rtts) == sent else 1


def _drain(link: Link, seconds: float) -> None:
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        try:
            link.read(0.05)
        except LinkClosed:
            return


def _probe(link: Link, tries: int = 10) -> Optional[bool]:
    token = b"\xEC\xFFprobe\xFF"
    for _ in range(tries):
        link.write(token)
        end = time.monotonic() + 0.3
        got = bytearray()
        while time.monotonic() < end:
            try:
                got += link.read(0.05)
            except LinkClosed:
                return False
            if token in got:
                _drain(link, 0.1)
                return True
    return False
