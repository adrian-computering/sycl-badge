"""The badge OS console (the "SYCL Badge Console" serial port)."""

from __future__ import annotations

import sys
import time
from typing import Optional

PROMPT = b"SYCL> "


def open_port(device: str, timeout: float = 0.1):
    import serial

    port = serial.Serial()
    port.port = device
    port.baudrate = 115200
    port.timeout = timeout
    port.dtr = True
    port.rts = True
    port.open()
    return port


def _drain(port, quiet: float = 0.15, limit: float = 1.0) -> bytes:
    """Read until nothing arrives for `quiet` seconds (at most `limit`)."""
    out = bytearray()
    end = time.time() + limit
    last = time.time()
    while time.time() < end:
        n = port.in_waiting
        if n:
            out += port.read(n)
            last = time.time()
        elif time.time() - last >= quiet:
            break
        else:
            time.sleep(0.02)
    return bytes(out)


def clean_reply(raw: bytes, command: str) -> str:
    """Strip the echoed command line and the trailing prompt."""
    text = raw.decode("utf-8", "replace").replace("\r\n", "\n").replace("\r", "\n")
    lines = text.split("\n")
    # drop everything up to and including the echoed command
    for i, line in enumerate(lines):
        if line.rstrip().endswith(command.strip()):
            lines = lines[i + 1 :]
            break
    while lines and lines[-1].strip() in ("", PROMPT.decode().strip()):
        lines.pop()
    while lines and not lines[0].strip():
        lines.pop(0)
    return "\n".join(lines)


def run_command(device: str, command: str, timeout: float = 3.0, port=None) -> str:
    """Send one command line and return its output (up to the next prompt,
    or until the console has been quiet for a moment after `timeout`)."""
    own = port is None
    if own:
        port = open_port(device)
    try:
        port.write(b"\x03")  # Ctrl-C: clear a half-typed line
        _drain(port, quiet=0.1, limit=0.5)
        port.write(command.encode("utf-8") + b"\r")
        buf = bytearray()
        end = time.time() + timeout
        echoed = False
        while time.time() < end:
            chunk = port.read(max(1, port.in_waiting))
            if chunk:
                buf += chunk
                if not echoed and command.encode() in buf:
                    echoed = True
                if echoed and buf.rstrip(b" ").endswith(PROMPT.rstrip()):
                    break
        return clean_reply(bytes(buf), command)
    finally:
        if own:
            port.close()


def reboot_bootsel(device: str) -> None:
    """Ask the badge OS to restart into the RP2350 USB boot loader."""
    port = open_port(device)
    try:
        port.write(b"\x03")
        time.sleep(0.05)
        port.write(b"reboot bootsel\r")
        port.flush()
        time.sleep(0.2)
    finally:
        try:
            port.close()
        except Exception:
            pass  # the device may already be gone


def interactive(device: str) -> int:
    """Pass-through terminal. Ctrl-] quits, Ctrl-T Ctrl-H shows miniterm's menu."""
    from serial.tools import miniterm

    port = open_port(device, timeout=1)
    term = miniterm.Miniterm(port, echo=False, eol="cr", filters=["direct"])
    term.exit_character = chr(0x1D)  # Ctrl-]
    term.menu_character = chr(0x14)  # Ctrl-T
    term.raw = True
    term.set_rx_encoding("utf-8", errors="replace")
    term.set_tx_encoding("utf-8")
    sys.stderr.write("--- %s  (Ctrl-] quits) ---\n" % device)
    term.start()
    try:
        port.write(b"\r")  # show a prompt
    except Exception:
        pass
    try:
        term.join(True)
    except KeyboardInterrupt:
        pass
    sys.stderr.write("\n--- closed ---\n")
    term.join()
    term.close()
    return 0
