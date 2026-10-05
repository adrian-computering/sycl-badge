#!/usr/bin/env python3
"""Benchmark `badge lobby`: N fake carts over localhost TCP, each sending a
small broadcast SEND at a fixed rate, like a game sending its state every
frame. Reports relay CPU, frames/s in and out, and relay latency.

    python3 tools/badge/bench_lobby.py                  # 16 players x 60 Hz x 6 bytes, 10 s
    python3 tools/badge/bench_lobby.py --players 8 --rate 30 --seconds 5

The relay runs as a real `badge lobby` subprocess (simulator source), so
the numbers include the whole path: socket reads, decoding, relay, coalesced
writes. The fake carts share one selector loop in this process.
"""

import argparse
import os
import selectors
import signal
import socket
import struct
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from badge import frames  # noqa: E402


def proc_cpu(pid):
    """utime + stime of a process in seconds (Linux /proc), or None."""
    try:
        with open("/proc/%d/stat" % pid) as f:
            fields = f.read().rsplit(")", 1)[1].split()
        return (int(fields[11]) + int(fields[12])) / os.sysconf("SC_CLK_TCK")
    except (OSError, ValueError, IndexError):
        return None


class Cart:
    def __init__(self, index, srv):
        self.index = index
        self.srv = srv
        self.port = srv.getsockname()[1]
        self.conn = None
        self.dec = frames.FrameDecoder()
        self.id = None
        self.roster = 0
        self.seq = 0
        self.next_send = 0.0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--players", type=int, default=16)
    ap.add_argument("--rate", type=float, default=60.0, help="SENDs per second per player")
    ap.add_argument("--size", type=int, default=6, help="SEND payload bytes (>= 6)")
    ap.add_argument("--seconds", type=float, default=10.0, help="measurement time")
    ap.add_argument("--warmup", type=float, default=1.0)
    args = ap.parse_args()
    size = max(6, args.size)

    sel = selectors.DefaultSelector()
    carts = []
    for i in range(args.players):
        srv = socket.socket()
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("127.0.0.1", 0))
        srv.listen(1)
        srv.setblocking(False)
        c = Cart(i, srv)
        carts.append(c)
        sel.register(srv, selectors.EVENT_READ, ("accept", c))

    spec = ",".join(str(c.port) for c in carts)
    cmd = [sys.executable, os.path.join(HERE, "badge.py"), "lobby", "--no-usb", "--sim", spec, "--stats", "0"]
    relay = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    sent_at = {}
    lat = []
    frames_out = 0  # SENDs written by carts
    frames_back = 0  # DATA received by carts
    phase = "join"
    t_start = t_end = t_drain = 0.0
    wall = my_cpu = 0.0
    cpu0 = cpu1 = None
    wall0 = 0.0
    my_cpu0 = 0.0
    period = 1.0 / args.rate
    deadline = time.time() + 20

    def handle(c, data):
        nonlocal frames_back
        now = time.perf_counter()
        for body in c.dec.feed(data):
            t = body[0]
            if t == frames.DATA:
                if phase in ("measure", "drain"):
                    seq, sender = struct.unpack_from("<IB", body, 2)
                    t0 = sent_at.get((sender, seq))
                    if t0 is not None:  # sent during the measurement
                        frames_back += 1
                        lat.append(now - t0)
            elif t == frames.WELCOME:
                c.id = body[2]
            elif t == frames.ROSTER:
                c.roster = body[1]

    try:
        while True:
            now = time.perf_counter()
            if phase == "join":
                if all(c.roster == args.players for c in carts):
                    phase = "warmup"
                    t_start = now + args.warmup
                    for c in carts:
                        c.next_send = now + period * c.index / args.players
                elif time.time() > deadline:
                    raise SystemExit("players did not all join within 20 s (is the relay running?)")
            elif phase == "warmup" and now >= t_start:
                phase = "measure"
                t_end = now + args.seconds
                cpu0 = proc_cpu(relay.pid)
                wall0 = now
                my_cpu0 = time.process_time()
            elif phase == "measure" and now >= t_end:
                cpu1 = proc_cpu(relay.pid)
                wall = now - wall0
                my_cpu = time.process_time() - my_cpu0
                phase = "drain"  # stop sending, collect frames still in flight
                t_drain = now + 0.5
            elif phase == "drain" and now >= t_drain:
                break
            if phase in ("warmup", "measure"):
                for c in carts:
                    while c.conn is not None and now >= c.next_send:
                        c.seq += 1
                        payload = struct.pack("<IB", c.seq, c.id) + bytes(size - 5)
                        if phase == "measure":
                            sent_at[(c.id, c.seq)] = time.perf_counter()
                            frames_out += 1
                        c.conn.sendall(frames.encode(bytes((frames.SEND, 0xFF)) + payload))
                        c.next_send += period
                timeout = max(0.0, min(c.next_send for c in carts) - time.perf_counter())
            else:
                timeout = 0.05
            for key, _ in sel.select(timeout):
                kind, c = key.data
                if kind == "accept":
                    conn, _ = c.srv.accept()
                    conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                    c.conn = conn
                    sel.register(conn, selectors.EVENT_READ, ("data", c))
                    conn.sendall(b"\x00" + frames.encode(frames.Hello(game="BENCH", name="p%d" % c.index, max_players=16).pack()))
                else:
                    data = key.fileobj.recv(65536)
                    if not data:
                        raise SystemExit("relay closed a connection")
                    handle(c, data)
    finally:
        relay.send_signal(signal.SIGINT)
        try:
            relay.wait(5)
        except subprocess.TimeoutExpired:
            relay.kill()

    lat.sort()

    def pct(p):
        return lat[min(len(lat) - 1, int(p / 100.0 * len(lat)))] * 1000 if lat else float("nan")

    expect = frames_out * (args.players - 1)
    print("players %d, %.0f Hz, %d-byte payload, %.1f s measured" % (args.players, args.rate, size, wall))
    print("frames in  (SEND to relay):  %8.0f /s" % (frames_out / wall))
    print("frames out (DATA from relay): %8.0f /s  (%d of %d expected = %.2f%%)" % (frames_back / wall, frames_back, expect, 100.0 * frames_back / max(1, expect)))
    print("latency SEND -> DATA: p50 %.2f ms, p99 %.2f ms, max %.2f ms" % (pct(50), pct(99), lat[-1] * 1000 if lat else float("nan")))
    if cpu0 is not None and cpu1 is not None:
        print("relay CPU: %.0f%% of one core" % (100.0 * (cpu1 - cpu0) / wall))
    else:
        print("relay CPU: n/a (needs /proc)")
    print("fake carts CPU (this process): %.0f%% of one core" % (100.0 * my_cpu / wall))
    return 0


if __name__ == "__main__":
    sys.exit(main())
