"""Command line: badge list | console | monitor | flash | install | lobby."""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from typing import List, Optional

from . import __version__, discover, flash, frames
from .discover import Badge, SelectError


def eprint(*args) -> None:
    print(*args, file=sys.stderr)


def die(msg: str, code: int = 1) -> "None":
    eprint("badge: " + msg)
    raise SystemExit(code)


def stamp() -> str:
    return time.strftime("%H:%M:%S")


def tlog(msg: str) -> None:
    print("%s %s" % (stamp(), msg), flush=True)


# ---------------------------------------------------------------------------
# Helpers


def do_scan(args, drives: bool = True, probe: bool = True) -> discover.Scan:
    sims = None
    if getattr(args, "sim", None):
        sims = discover.parse_sim_spec(args.sim)
    return discover.scan(sims=sims, probe=probe, drives=drives)


def pick_one(badges: List[Badge], token: Optional[str], need: str) -> Badge:
    """One badge for console/monitor. `need` = 'console' or 'cart'."""
    pool = [b for b in badges if getattr(b, need)]
    if token:
        try:
            hits = discover.select(badges, [token])
        except SelectError as e:
            die(str(e))
        b = hits[0]
        if not getattr(b, need):
            die("%s has no %s port%s" % (b.name(), need, " (stock firmware?)" if need == "cart" else ""))
        return b
    if len(pool) == 1:
        return pool[0]
    if not pool:
        die("no badge with a %s port found (see `badge list`, or pass --port)" % need)
    die("several badges have a %s port, pick one: %s" % (need, ", ".join(b.name() for b in pool)))
    raise AssertionError


def print_unmounted(scan: discover.Scan) -> None:
    for dev, label in scan.unmounted:
        eprint("note: " + flash.mount_hint(dev, label))


# ---------------------------------------------------------------------------
# badge list


def cmd_list(args) -> int:
    s = do_scan(args, probe=not args.no_sim)
    if args.json:
        out = {
            "badges": [
                {k: getattr(b, k) for k in ("id", "short", "kind", "serial", "location", "console", "cart", "drive", "sim_port")}
                for b in s.badges
            ],
            "loose_drives": [v.path for v in s.loose_drives],
            "bootloader_drives": [v.path for v in s.bootloader],
            "unmounted": [{"device": d, "label": l} for d, l in s.unmounted],
        }
        print(json.dumps(out, indent=2))
        return 0
    rows = [("ID", "KIND", "CONSOLE", "CART", "DRIVE")]
    for b in s.badges:
        rows.append((b.name(), b.kind, b.console or "-", b.cart or "-", b.drive or "-"))
    if len(rows) == 1:
        print("No badges or simulators found.")
        print("  - Plug the badge in and switch it on (fork firmware shows console + cart ports).")
        print("  - Simulators are found on 127.0.0.1:7341-7356 while they run.")
    else:
        widths = [max(len(r[i]) for r in rows) for i in range(len(rows[0]))]
        for r in rows:
            print("  ".join(c.ljust(w) for c, w in zip(r, widths)).rstrip())
    for v in s.loose_drives:
        print("SYCLBADGE drive (badge not identified): %s" % v.path)
    for v in s.bootloader:
        print("RP2350 boot drive (badge in BOOTSEL mode): %s" % v.path)
    for dev, label in s.unmounted:
        print("%s drive not mounted: %s" % (label, dev))
    if args.verbose:
        for b in s.badges:
            print("%s: id=%s serial=%s location=%s" % (b.name(), b.id, b.serial, b.location))
    return 0


# ---------------------------------------------------------------------------
# badge console


def cmd_console(args) -> int:
    from . import console

    if args.port:
        device = args.port
    else:
        s = do_scan(args, drives=False, probe=False)
        device = pick_one(s.badges, args.badge, "console").console
    try:
        if args.command:
            print(console.run_command(device, " ".join(args.command), timeout=args.timeout))
            return 0
        return console.interactive(device)
    except Exception as e:
        if type(e).__name__ in ("SerialException", "PortNotOpenError") or isinstance(e, OSError):
            die("%s: %s" % (device, e))
        raise


# ---------------------------------------------------------------------------
# badge monitor


def cmd_monitor(args) -> int:
    from . import monitor
    from .links import LinkClosed, open_link

    if args.port:
        url = args.port
    else:
        s = do_scan(args, drives=False, probe=True)
        url = pick_one(s.badges, args.badge, "cart").cart
    try:
        link = open_link(url)
    except LinkClosed as e:
        die("cannot open %s: %s" % (url, e))
    mode = "hex" if args.hex else "frames" if args.frames else "text"
    return monitor.run(link, mode=mode, eol=args.eol)


def cmd_echo_test(args) -> int:
    from . import echotest
    from .links import LinkClosed, open_link

    if args.port:
        url = args.port
    else:
        s = do_scan(args, drives=False, probe=True)
        url = pick_one(s.badges, args.badge, "cart").cart
    try:
        link = open_link(url)
    except LinkClosed as e:
        die("cannot open %s: %s" % (url, e))
    try:
        return echotest.run(link, rate=args.rate, size=args.size, seconds=args.seconds)
    finally:
        link.close()


# ---------------------------------------------------------------------------
# badge flash


def _targets(args, scan: discover.Scan, verb: str) -> List[Badge]:
    real = [b for b in scan.badges if not b.is_sim]
    if args.all:
        return real
    if args.badges:
        try:
            return [b for b in discover.select(scan.badges, args.badges)]
        except SelectError as e:
            die(str(e))
    if len(real) == 1:
        return real
    if not real:
        return []
    die("%d badges connected; name them (see `badge list`) or use --all to %s every one" % (len(real), verb))
    raise AssertionError


def cmd_flash(args) -> int:
    try:
        info = flash.read_uf2(args.firmware)
    except flash.UF2Error as e:
        die(str(e))
    if not info.looks_like_firmware and not args.force:
        die(
            "%s does not start at 0x%08X, so it looks like a cart, not OS firmware. "
            "Use `badge install` for carts, or --force." % (args.firmware, flash.FLASH_BASE)
        )
    print("%s: %d blocks, %s" % (args.firmware, info.blocks, info.family_names()))
    s = do_scan(args, probe=False)
    targets = _targets(args, s, "flash")
    manual = 0
    if args.all:
        # drives no badge claims; on Windows these are usually the drives of
        # targets we already reach through their console
        manual = max(0, len(s.loose_drives) - len([b for b in targets if not b.drive and b.console]))
    if not targets and not manual and not s.bootloader and not args.loop:
        print("No badge found. On the badge: %s. Waiting..." % flash.BOOTSEL_STEPS)
        manual = 1
    results = flash.flash_many(
        args.firmware,
        targets,
        manual=manual,
        timeout=args.timeout,
        manual_timeout=args.manual_timeout,
        loop=args.loop,
        log=print,
        auto_mount=not args.no_mount,
        rescan=lambda: discover.scan(probe=False, drives=False).badges,
    )
    ok = [r for r in results if r.ok]
    bad = [r for r in results if not r.ok and "skipped" not in r.detail]
    print("flashed %d, failed %d" % (len(ok), len(bad)))
    for r in bad:
        print("  FAILED %s: %s" % (r.target, r.detail))
    return 0 if not bad and (ok or not results) else 1


# ---------------------------------------------------------------------------
# badge install


def cmd_install(args) -> int:
    try:
        info = flash.read_uf2(args.cart)
    except flash.UF2Error as e:
        die(str(e))
    if info.looks_like_firmware and not args.force:
        die("%s writes to 0x%08X, so it looks like OS firmware. Use `badge flash`, or --force." % (args.cart, flash.FLASH_BASE))
    name = args.name or os.path.basename(args.cart)
    if not name.lower().endswith(".uf2"):
        name += ".uf2"
    s = do_scan(args, probe=False)
    if not args.no_mount and s.unmounted and sys.platform.startswith("linux"):
        mounted_any = False
        for dev, label in s.unmounted:
            if label == discover.DRIVE_LABEL and flash.try_mount(dev):
                mounted_any = True
        if mounted_any:
            s = do_scan(args, probe=False)
    drives = []  # (label, path)
    if args.all:
        drives = [(b.name(), b.drive) for b in s.badges if b.drive]
        drives += [(v.path, v.path) for v in s.loose_drives]
    elif args.badges:
        try:
            chosen = discover.select(s.badges, args.badges)
        except SelectError as e:
            die(str(e))
        for b in chosen:
            if not b.drive:
                print_unmounted(s)
                die("%s: no SYCLBADGE drive found for this badge" % b.name())
            drives.append((b.name(), b.drive))
    else:
        drives = [(b.name(), b.drive) for b in s.badges if b.drive]
        drives += [(v.path, v.path) for v in s.loose_drives]
        if len(drives) > 1:
            die("%d badge drives found; name badges or use --all" % len(drives))
    if not drives:
        print_unmounted(s)
        die("no SYCLBADGE drive found (badge plugged in and switched on?)")
    failed = 0
    for label, path in drives:
        existing = os.path.join(path, name)
        free = flash.free_space(path)
        reclaim = os.path.getsize(existing) if os.path.exists(existing) else 0
        if free is not None and free + reclaim < info.size:
            print("%s: not enough space on %s (%d KB free, need %d KB); delete a cart first" % (label, path, free // 1024, info.size // 1024))
            failed += 1
            continue
        try:
            dst = flash.copy_to_drive(args.cart, path, name)
        except OSError as e:
            hint = ""
            if getattr(e, "errno", None) in (28,):  # ENOSPC: data or root directory full
                hint = " (drive full: the badge drive holds 32 root entries; delete a cart)"
            print("%s: copy to %s failed: %s%s" % (label, path, e, hint))
            failed += 1
            continue
        print("%s: installed %s (%d KB)" % (label, dst, info.size // 1024))
    if not failed:
        print("Done. Pick the cart from the badge menu.")
    return 1 if failed else 0


# ---------------------------------------------------------------------------
# badge lobby


def cmd_lobby(args) -> int:
    from . import lobby as lobby_mod

    log = tlog
    lob = lobby_mod.Lobby(max_room=args.max_room, log=log, verbose=args.verbose)
    server = lobby_mod.LobbyServer(lob, queue_limit=args.queue_limit, log=log, stats_interval=args.stats)
    what = []
    if not args.no_usb:
        server.add_source(lobby_mod.HotplugSource())
        what.append("USB badges")
    if not args.no_sim:
        targets = discover.parse_sim_spec(args.sim) if args.sim else [(discover.SIM_HOST, p) for p in discover.SIM_PORTS]
        if targets:
            server.add_source(lobby_mod.SimSource(targets))
            what.append("simulators on %s" % (args.sim or "127.0.0.1:7341-7356"))
    if args.port:
        server.add_source(lobby_mod.StaticSource(args.port))
        what.append(", ".join(args.port))
    log("lobby v%d: watching %s; Ctrl-C stops" % (frames.VERSION, ", ".join(what) or "nothing"))
    try:
        server.run()
    except KeyboardInterrupt:
        pass
    print()
    log("lobby stopped: %d frames in, %d out" % (server.frames_in, server.frames_out))
    return 0


# ---------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="badge", description="SYCL badge host tool: list, console, monitor, flash, install, lobby.")
    p.add_argument("--version", action="version", version="badge " + __version__)
    sub = p.add_subparsers(dest="cmd", metavar="COMMAND")

    sp = sub.add_parser("list", help="list badges and simulators")
    sp.add_argument("--json", action="store_true", help="machine-readable output")
    sp.add_argument("--sim", metavar="PORTS", help="simulator ports to probe (default 7341-7356)")
    sp.add_argument("--no-sim", action="store_true", help="do not probe simulators")
    sp.add_argument("-v", "--verbose", action="store_true")
    sp.set_defaults(func=cmd_list)

    sp = sub.add_parser("console", help="terminal on a badge's OS console")
    sp.add_argument("badge", nargs="?", help="badge id (from `badge list`), serial or port")
    sp.add_argument("-c", "--command", nargs=argparse.REMAINDER, help="run one command, print the reply, exit")
    sp.add_argument("--port", help="console port to open instead of discovering one")
    sp.add_argument("--timeout", type=float, default=3.0, help="seconds to wait for a -c reply (default 3)")
    sp.set_defaults(func=cmd_console)

    sp = sub.add_parser("monitor", help="watch / talk to a cart serial port")
    sp.add_argument("badge", nargs="?", help="badge id, serial, sim:PORT or port")
    g = sp.add_mutually_exclusive_group()
    g.add_argument("--hex", action="store_true", help="hex dump incoming bytes")
    g.add_argument("--frames", action="store_true", help="decode lobby frames; typed lines are frame commands")
    sp.add_argument("--eol", choices=sorted(monitor_eols()), default="lf", help="line ending for typed lines (default lf)")
    sp.add_argument("--port", help="device path or socket://host:port to open")
    sp.add_argument("--sim", metavar="PORTS", help="simulator ports to probe (default 7341-7356)")
    sp.set_defaults(func=cmd_monitor)

    sp = sub.add_parser("echo-test", help="time cart serial round trips (run the serial-echo cart)")
    sp.add_argument("badge", nargs="?", help="badge id, serial, sim:PORT or port")
    sp.add_argument("--rate", type=float, default=60.0, help="records per second (default 60)")
    sp.add_argument("--size", type=int, default=16, help="bytes per record, at least 13 (default 16)")
    sp.add_argument("--seconds", type=float, default=10.0, help="how long to send (default 10)")
    sp.add_argument("--port", help="device path or socket://host:port to open")
    sp.add_argument("--sim", metavar="PORTS", help="simulator ports to probe (default 7341-7356)")
    sp.set_defaults(func=cmd_echo_test)

    sp = sub.add_parser("flash", help="flash OS firmware onto badges")
    sp.add_argument("firmware", help="firmware UF2 (zig-out/firmware/sycl-os-kernel.uf2)")
    sp.add_argument("badges", nargs="*", help="badges to flash (default: the only one)")
    sp.add_argument("--all", action="store_true", help="every connected badge, one after another")
    sp.add_argument("--loop", action="store_true", help="then keep flashing every RP2350 drive that appears")
    sp.add_argument("--force", action="store_true", help="flash even if the file looks like a cart")
    sp.add_argument("--timeout", type=float, default=20.0, help="seconds to wait for the RP2350 drive (default 20)")
    sp.add_argument("--manual-timeout", type=float, default=120.0, help="seconds to wait for BOOT_SEL+RESET (default 120)")
    sp.add_argument("--no-mount", action="store_true", help="Linux: do not try udisksctl to mount drives")
    sp.set_defaults(func=cmd_flash)

    sp = sub.add_parser("install", help="copy a cart UF2 onto badge drives")
    sp.add_argument("cart", help="cart UF2 (zig-out/carts/NAME.uf2)")
    sp.add_argument("badges", nargs="*", help="badges (default: the only one)")
    sp.add_argument("--all", action="store_true", help="every SYCLBADGE drive")
    sp.add_argument("--name", help="file name on the badge (default: the cart's file name)")
    sp.add_argument("--force", action="store_true", help="install even if the file looks like firmware")
    sp.add_argument("--no-mount", action="store_true", help="Linux: do not try udisksctl to mount drives")
    sp.set_defaults(func=cmd_install)

    sp = sub.add_parser("lobby", help="run the multiplayer lobby relay (protocol v1)")
    sp.add_argument("--sim", metavar="PORTS", help="simulator ports, e.g. 7341,7342 or 7341-7344 or host:port (default 7341-7356)")
    sp.add_argument("--no-sim", action="store_true", help="ignore simulators")
    sp.add_argument("--no-usb", action="store_true", help="ignore USB badges")
    sp.add_argument("--port", action="append", metavar="PATH_OR_URL", help="also use this port or socket://host:port (repeatable)")
    sp.add_argument("--max-room", type=int, default=16, help="room size for carts that ask for the default, and the cap (2-16, default 16)")
    sp.add_argument("--stats", type=float, default=10.0, metavar="SECONDS", help="print per-player rates every N seconds (0 = off, default 10)")
    sp.add_argument("--queue-limit", type=int, default=64 * 1024, metavar="BYTES", help="drop a player that stops reading once this much output is waiting (default 65536)")
    sp.add_argument("-v", "--verbose", action="store_true", help="log every message")
    sp.set_defaults(func=cmd_lobby)
    return p


def monitor_eols():
    from .monitor import EOLS

    return EOLS.keys()


def main(argv: Optional[List[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if not getattr(args, "func", None):
        parser.print_help()
        return 2
    try:
        return args.func(args) or 0
    except KeyboardInterrupt:
        eprint("")
        return 130


if __name__ == "__main__":
    sys.exit(main())
