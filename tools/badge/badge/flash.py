"""UF2 checks, copying to drives, and the firmware flashing flow."""

from __future__ import annotations

import os
import shutil
import struct
import subprocess
import sys
import time
from dataclasses import dataclass, field
from typing import Callable, List, Optional, Set

from . import discover

UF2_MAGIC0 = 0x0A324655  # "UF2\n"
UF2_MAGIC1 = 0x9E5D5157
UF2_MAGIC_END = 0x0AB16F30
UF2_FLAG_FAMILY = 0x00002000
UF2_FLAG_NOT_MAIN_FLASH = 0x00000001
BLOCK = 512

FAMILIES = {
    0xE48BFF59: "RP2350 ARM-S",
    0xE48BFF5A: "RP2350 RISC-V",
    0xE48BFF5B: "RP2350 ARM-NS",
    0xE48BFF56: "RP2040",
    0xE48BFF57: "absolute",
    0xE48BFF58: "data",
}

FLASH_BASE = 0x10000000  # the OS image starts here; carts never write it


class UF2Error(ValueError):
    pass


@dataclass
class UF2Info:
    path: str
    size: int
    blocks: int
    families: Set[int] = field(default_factory=set)
    lowest: int = 0xFFFFFFFF
    highest: int = 0

    @property
    def looks_like_firmware(self) -> bool:
        return self.lowest == FLASH_BASE

    def family_names(self) -> str:
        return ", ".join(FAMILIES.get(f, "0x%08X" % f) for f in sorted(self.families)) or "none"


def read_uf2(path: str) -> UF2Info:
    """Validate a UF2 file (every block's magic numbers) and summarize it."""
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError as e:
        raise UF2Error("%s: %s" % (path, e.strerror or e))
    return parse_uf2(data, path)


def parse_uf2(data: bytes, path: str = "<data>") -> UF2Info:
    if not data:
        raise UF2Error("%s: empty file" % path)
    if len(data) % BLOCK:
        raise UF2Error("%s: %d bytes is not a whole number of 512-byte UF2 blocks" % (path, len(data)))
    info = UF2Info(path=path, size=len(data), blocks=len(data) // BLOCK)
    for i in range(info.blocks):
        off = i * BLOCK
        m0, m1, flags, addr, size, _seq, _n, fam = struct.unpack_from("<8I", data, off)
        (mend,) = struct.unpack_from("<I", data, off + BLOCK - 4)
        if m0 != UF2_MAGIC0 or m1 != UF2_MAGIC1 or mend != UF2_MAGIC_END:
            raise UF2Error("%s: block %d has bad UF2 magic (not a UF2 file?)" % (path, i))
        if size > 476:
            raise UF2Error("%s: block %d payload size %d > 476" % (path, i, size))
        if flags & UF2_FLAG_NOT_MAIN_FLASH:
            continue
        if flags & UF2_FLAG_FAMILY:
            info.families.add(fam)
        info.lowest = min(info.lowest, addr)
        info.highest = max(info.highest, addr + size)
    return info


# ---------------------------------------------------------------------------
# Copying


def copy_to_drive(src: str, drive: str, name: Optional[str] = None, expect_vanish: bool = False) -> str:
    """Write `src` to `drive`/`name` with plain writes (no extended attributes,
    so macOS does not leave '._' files), then flush to the device.

    With expect_vanish (the RP2350 boot ROM reboots as soon as the last block
    lands), errors after all bytes were written are not fatal.
    """
    name = name or os.path.basename(src)
    dst = os.path.join(drive, name)
    with open(src, "rb") as f:
        data = f.read()
    written = False
    try:
        with open(dst, "wb") as out:
            out.write(data)
            out.flush()
            written = True
            try:
                os.fsync(out.fileno())
            except OSError:
                if not expect_vanish:
                    raise
    except OSError:
        if not (expect_vanish and written):
            raise
    if hasattr(os, "sync") and not expect_vanish:
        os.sync()
    if sys.platform == "darwin":
        # A Finder copy may have left an AppleDouble file; each costs a root
        # directory entry (the badge drive has 32) and shows up as a cart.
        ghost = os.path.join(drive, "._" + name)
        try:
            os.remove(ghost)
        except OSError:
            pass
    return dst


def free_space(drive: str) -> Optional[int]:
    try:
        return shutil.disk_usage(drive).free
    except OSError:
        return None


# ---------------------------------------------------------------------------
# Mounting help (Linux without an automounter)


def try_mount(device: str) -> Optional[str]:
    """Mount a block device with udisksctl (no root needed on desktops).
    Returns the mount point, or None."""
    if not sys.platform.startswith("linux") or not shutil.which("udisksctl"):
        return None
    try:
        r = subprocess.run(
            ["udisksctl", "mount", "--no-user-interaction", "-b", device],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            universal_newlines=True,
            timeout=15,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if r.returncode != 0:
        return None
    # "Mounted /dev/sdb1 at /media/user/RP2350"
    out = r.stdout.strip().rstrip(".")
    if " at " in out:
        return out.split(" at ", 1)[1]
    return None


def mount_hint(device: str, label: str) -> str:
    mnt = "/mnt/" + label.lower()
    return (
        "%s (%s) is not mounted. Mount it, for example:\n"
        "    udisksctl mount -b %s\n"
        "or  sudo mkdir -p %s && sudo mount -o uid=$(id -u),gid=$(id -g) %s %s"
        % (device, label, device, mnt, device, mnt)
    )


# ---------------------------------------------------------------------------
# Waiting for drives


def wait_for(cond: Callable[[], Optional[object]], timeout: float, interval: float = 0.25):
    deadline = time.time() + timeout
    while True:
        v = cond()
        if v:
            return v
        if time.time() >= deadline:
            return None
        time.sleep(interval)


class BootDrives:
    """Finds mounted RP2350 boot drives, and on Linux tries to mount (or
    explains how to mount) one that showed up unmounted."""

    def __init__(self, log: Callable[[str], None] = print, auto_mount: bool = True):
        self.log = log
        self.auto_mount = auto_mount
        self._hinted: Set[str] = set()
        self._tried: Set[str] = set()

    def find(self) -> List[str]:
        vols = discover.bootloader_volumes()
        if vols:
            return [v.path for v in vols]
        if sys.platform.startswith("linux"):
            for dev in discover.scan_sysfs():
                if not dev.is_bootloader or not dev.disks:
                    continue
                target = dev.disks[-1]
                if self.auto_mount and target not in self._tried:
                    self._tried.add(target)
                    path = try_mount(target)
                    if path:
                        self.log("  mounted %s at %s" % (target, path))
                        return [path]
                if target not in self._hinted:
                    self._hinted.add(target)
                    self.log("  " + mount_hint(target, discover.BOOT_LABEL).replace("\n", "\n  "))
        return []


# ---------------------------------------------------------------------------
# Firmware flashing flow (badge flash)

BOOTSEL_STEPS = (
    "hold BOOT_SEL on the back of the badge, tap RESET, then let go of BOOT_SEL "
    "(the screen stays dark and an RP2350 drive appears)"
)


@dataclass
class FlashResult:
    target: str
    ok: bool
    detail: str


def _flash_drive(uf2: str, path: str, log, vanish_timeout: float = 30.0) -> Optional[str]:
    """Copy to a boot drive and wait for it to go away. Returns an error or None."""
    try:
        copy_to_drive(uf2, path, expect_vanish=True)
    except OSError as e:
        return "copy to %s failed: %s" % (path, e)
    if not wait_for(lambda: not os.path.exists(path) or not os.path.exists(os.path.join(path, "INFO_UF2.TXT")), vanish_timeout):
        return "%s did not go away after the copy (badge did not reboot?)" % path
    return None


def flash_many(
    uf2: str,
    targets: list,
    manual: int = 0,
    timeout: float = 20.0,
    manual_timeout: float = 120.0,
    loop: bool = False,
    log: Callable[[str], None] = print,
    auto_mount: bool = True,
    rescan: Optional[Callable[[], list]] = None,
) -> List[FlashResult]:
    """Flash `uf2` onto each target badge, one at a time.

    targets: Badge objects; those with a console are rebooted into the boot
    loader with `reboot bootsel`, the others get BOOT_SEL + RESET steps.
    manual: extra badges with no known console (loose drives) to wait for.
    loop: afterwards keep flashing every RP2350 drive that appears (Ctrl-C).
    """
    from . import console

    boot = BootDrives(log=log, auto_mount=auto_mount)
    results: List[FlashResult] = []

    def first_new(before):
        now = boot.find()
        new = [p for p in now if p not in before]
        return new

    present = boot.find()
    for path in present:
        log("%s: RP2350 drive already present, copying" % path)
        err = _flash_drive(uf2, path, log)
        results.append(FlashResult(path, err is None, err or "flashed"))
        log("  " + (err or "done, badge rebooting"))

    for b in targets:
        name = b.name()
        if b.is_sim:
            results.append(FlashResult(name, False, "simulator, skipped"))
            continue
        before = boot.find()
        if b.console:
            log("%s: rebooting into the boot loader (%s)" % (name, b.console))
            try:
                console.reboot_bootsel(b.console)
            except Exception as e:
                results.append(FlashResult(name, False, "could not open console %s: %s" % (b.console, e)))
                log("  failed: %s" % e)
                continue
            wait = timeout
        else:
            log("%s: no console port (stock firmware). On this badge: %s" % (name, BOOTSEL_STEPS))
            wait = manual_timeout
        new = wait_for(lambda: first_new(before), wait)
        if not new:
            msg = "no RP2350 drive appeared within %.0f s" % wait
            if b.console:
                msg += "; try: %s" % BOOTSEL_STEPS
            results.append(FlashResult(name, False, msg))
            log("  " + msg)
            continue
        for path in new:
            log("  copying to %s" % path)
            err = _flash_drive(uf2, path, log)
            if err:
                results.append(FlashResult(name, False, err))
                log("  " + err)
                break
        else:
            detail = "flashed"
            if rescan is not None and b.serial:
                again = wait_for(lambda: [x for x in rescan() if x.serial == b.serial], 15.0, 0.5)
                if again:
                    detail = "flashed, back as %s firmware" % again[0].kind
                else:
                    detail = "flashed (badge not seen again yet)"
            results.append(FlashResult(name, True, detail))
            log("  " + detail)

    remaining = manual
    if remaining or loop:
        if remaining:
            log("%d badge(s) need the buttons: %s." % (remaining, BOOTSEL_STEPS))
        log("Waiting for RP2350 drives%s (Ctrl-C to stop)..." % ("" if loop else ", one badge at a time"))
        try:
            while remaining > 0 or loop:
                new = wait_for(boot.find, manual_timeout if not loop else 3600 * 24)
                if not new:
                    log("  timed out")
                    break
                for path in new:
                    log("  copying to %s" % path)
                    err = _flash_drive(uf2, path, log)
                    results.append(FlashResult(path, err is None, err or "flashed"))
                    log("  " + (err or "done"))
                    remaining -= 1
        except KeyboardInterrupt:
            log("  stopped")
    return results
