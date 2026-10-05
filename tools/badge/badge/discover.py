"""Find badges, their serial ports and drives, and running simulators.

    from badge import discover
    scan = discover.scan()
    for b in scan.badges:
        print(b.id, b.kind, b.console, b.cart, b.drive)

A badge is one USB device. Fork firmware exposes three interfaces (see
fork/CART_SERIAL.md): mass storage (the SYCLBADGE drive, interface 0), the
console CDC port (interfaces 1-2) and the cart CDC port (interfaces 3-4), with
the RP2350 chip id as USB serial number. Upstream firmware with the USB
console has only the drive and the console (and every badge reports the same
serial string, so those are told apart by USB location). Upstream firmware
without the console shows only the drive.

Platform notes:
- Linux: ports from pyserial (interface number from the location suffix
  ":1.N"), drives from sysfs + /proc/mounts + /dev/disk/by-label.
- macOS: ports from pyserial; pyserial's `interface` field is unreliable there,
  so the USB interface number of each port and the BSD disk of the drive come
  from `ioreg -a -l -r -c IOUSBHostDevice`, and mount points from `mount`.
  Without ioreg, the two ports of a badge are told apart by name order.
- Windows: ports from pyserial (interface from location ":x.N"), drives are
  the volumes labelled SYCLBADGE; they are matched to badges only when that is
  unambiguous (one badge, one drive).
"""

from __future__ import annotations

import glob
import os
import plistlib
import re
import socket
import subprocess
import sys
from dataclasses import dataclass, field
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

# usb.zig: .vendor = .from(1234), .product = .from(1234) (decimal, = 0x04D2)
BADGE_VID = 1234
BADGE_PID = 1234
BADGE_PRODUCT = "SYCL Badge"
# RP2350 boot ROM (BOOTSEL mode)
RP2350_BOOT_VID = 0x2E8A
RP2350_BOOT_PID = 0x000F

DRIVE_LABEL = "SYCLBADGE"
BOOT_LABEL = "RP2350"

SIM_HOST = "127.0.0.1"
SIM_PORTS = range(7341, 7357)

CONSOLE_IFACES = (1, 2)
CART_IFACES = (3, 4)
CONSOLE_NAME = "SYCL Badge Console"
CART_NAME = "SYCL Badge Cart Serial"


@dataclass
class Badge:
    id: str  # USB serial (chip id), "usb:<location>" for old firmware, "sim:<port>"
    kind: str  # "fork" (has a cart port), "stock" (no cart port), "sim"
    serial: Optional[str] = None
    location: Optional[str] = None  # USB location ("1-1.2"), when known
    console: Optional[str] = None  # console port device
    cart: Optional[str] = None  # cart port device or socket:// URL
    drive: Optional[str] = None  # SYCLBADGE mount point
    sim_port: Optional[int] = None
    short: str = ""  # display id, filled in by scan()
    notes: List[str] = field(default_factory=list)

    @property
    def is_sim(self) -> bool:
        return self.kind == "sim"

    def name(self) -> str:
        return self.short or self.id


@dataclass
class Volume:
    path: str  # mount point / drive root
    device: Optional[str] = None  # /dev/sdb1, /dev/disk4, "E:"
    label: Optional[str] = None


@dataclass
class UsbDev:
    """A USB device as seen through sysfs (Linux) or ioreg (macOS)."""

    location: str  # "1-1.2" (Linux sysfs name / pyserial-style location)
    vid: Optional[int] = None
    pid: Optional[int] = None
    serial: Optional[str] = None
    product: Optional[str] = None
    ttys: Dict[str, int] = field(default_factory=dict)  # device -> interface number
    disks: List[str] = field(default_factory=list)  # block devices of the MSC interface

    @property
    def is_badge(self) -> bool:
        return is_badge_ids(self.vid, self.pid, self.product)

    @property
    def is_bootloader(self) -> bool:
        return self.vid == RP2350_BOOT_VID and self.pid == RP2350_BOOT_PID


@dataclass
class Scan:
    badges: List[Badge] = field(default_factory=list)
    loose_drives: List[Volume] = field(default_factory=list)  # SYCLBADGE drives not matched to a badge
    unmounted: List[Tuple[str, str]] = field(default_factory=list)  # (block device, "SYCLBADGE"/"RP2350")
    bootloader: List[Volume] = field(default_factory=list)  # mounted RP2350 drives


# ---------------------------------------------------------------------------
# Serial ports


def is_badge_ids(vid, pid, product=None, manufacturer=None) -> bool:
    if vid == BADGE_VID and pid == BADGE_PID:
        return True
    return bool(product and BADGE_PRODUCT in product)


def is_badge_port(p) -> bool:
    return is_badge_ids(getattr(p, "vid", None), getattr(p, "pid", None), getattr(p, "product", None))


def valid_serial(s: Optional[str]) -> bool:
    """True for a per-badge serial (fork firmware's chip id), false for the
    shared placeholder older firmware reports."""
    if not s:
        return False
    s = s.strip()
    if s.lower() in ("serial number", "serial", "0", "n/a"):
        return False
    return re.fullmatch(r"[0-9A-Za-z_]{4,64}", s) is not None


_LOC_RE = re.compile(r"^(?P<dev>\d+-[\d.]+)(?::(?:\d+|x)\.(?P<iface>\d+))?$")


def split_location(loc: Optional[str]) -> Tuple[Optional[str], Optional[int]]:
    """'1-1.2:1.3' -> ('1-1.2', 3); '1-2:x.1' (Windows) -> ('1-2', 1);
    '20-1.2' (macOS) -> ('20-1.2', None)."""
    if not loc:
        return None, None
    m = _LOC_RE.match(loc.strip())
    if not m:
        return loc.strip(), None
    iface = m.group("iface")
    return m.group("dev"), int(iface) if iface is not None else None


def list_serial_ports() -> list:
    try:
        from serial.tools import list_ports
    except ImportError:
        raise SystemExit("badge: pyserial is not installed (pip install pyserial)")
    return list(list_ports.comports())


def _role_from_iface(n: Optional[int]) -> Optional[str]:
    if n in CONSOLE_IFACES:
        return "console"
    if n in CART_IFACES:
        return "cart"
    return None


def _role_from_name(name: Optional[str]) -> Optional[str]:
    if not name:
        return None
    low = name.lower()
    if "cart" in low:
        return "cart"
    if "console" in low:
        return "console"
    return None


def group_ports(ports: Iterable, iface_hints: Optional[Dict[str, int]] = None) -> List[Badge]:
    """Group badge serial ports into Badge objects (no drives yet).

    `iface_hints` maps port device -> USB interface number (from ioreg on
    macOS) and wins over everything else.
    """
    iface_hints = iface_hints or {}
    groups: Dict[str, dict] = {}
    for p in ports:
        if not is_badge_port(p):
            continue
        serial = (getattr(p, "serial_number", None) or "").strip() or None
        dev_loc, iface = split_location(getattr(p, "location", None))
        if valid_serial(serial):
            key = serial
        elif dev_loc:
            key = "usb:" + dev_loc
        else:
            key = "port:" + p.device
        g = groups.setdefault(key, {"serial": serial if valid_serial(serial) else None, "loc": dev_loc, "ports": []})
        if g["loc"] is None:
            g["loc"] = dev_loc
        if p.device in iface_hints:
            iface = iface_hints[p.device]
        g["ports"].append((p.device, iface, getattr(p, "interface", None)))

    badges = []
    for key, g in groups.items():
        ports_ = g["ports"]
        roles: Dict[str, str] = {}
        # 1. interface numbers (location suffix or ioreg)
        for dev, iface, _ in ports_:
            r = _role_from_iface(iface)
            if r:
                roles[dev] = r
        # 2. interface strings, only when they differ between the ports
        #    (pyserial on macOS reports one device-wide name for all ports)
        names = {name for _, _, name in ports_ if name}
        if len(names) == len(ports_) or len(ports_) == 1:
            for dev, _, name in ports_:
                if dev not in roles:
                    r = _role_from_name(name)
                    if r:
                        roles[dev] = r
        # 3. name order: console (lower interface) sorts first
        rest = sorted((dev for dev, _, _ in ports_ if dev not in roles), key=_natural_key)
        taken = set(roles.values())
        for dev in rest:
            for r in ("console", "cart"):
                if r not in taken:
                    roles[dev] = r
                    taken.add(r)
                    break
        b = Badge(id=key, kind="stock", serial=g["serial"], location=g["loc"])
        for dev, r in roles.items():
            if r == "console" and not b.console:
                b.console = dev
            elif r == "cart" and not b.cart:
                b.cart = dev
        if b.cart:
            b.kind = "fork"
        badges.append(b)
    return badges


def _natural_key(s: str):
    return [int(t) if t.isdigit() else t for t in re.split(r"(\d+)", s)]


# ---------------------------------------------------------------------------
# Linux: sysfs


def _read(path: str) -> Optional[str]:
    try:
        with open(path, "r", errors="replace") as f:
            return f.read().strip()
    except OSError:
        return None


def _hex(s: Optional[str]) -> Optional[int]:
    try:
        return int(s, 16) if s else None
    except ValueError:
        return None


def scan_sysfs(root: str = "/sys", dev_root: str = "/dev") -> List[UsbDev]:
    """USB devices with their tty ports (by interface) and block devices."""
    base = os.path.join(root, "bus", "usb", "devices")
    out = []
    try:
        names = sorted(os.listdir(base))
    except OSError:
        return out
    for name in names:
        if ":" in name or name.startswith("usb"):
            continue
        d = os.path.join(base, name)
        dev = UsbDev(
            location=name,
            vid=_hex(_read(os.path.join(d, "idVendor"))),
            pid=_hex(_read(os.path.join(d, "idProduct"))),
            serial=_read(os.path.join(d, "serial")),
            product=_read(os.path.join(d, "product")),
        )
        for idir in sorted(glob.glob(os.path.join(base, name + ":*"))) + sorted(glob.glob(os.path.join(d, name + ":*"))):
            ifnum = _hex(_read(os.path.join(idir, "bInterfaceNumber")))
            for tty in glob.glob(os.path.join(idir, "tty", "*")):
                dev.ttys[os.path.join(dev_root, os.path.basename(tty))] = ifnum if ifnum is not None else -1
            for blk in sorted(glob.glob(os.path.join(idir, "host*", "target*", "*", "block", "*"))):
                # SCSI address H:C:T:L. Ext-flash firmware adds LUN 1, the
                # SYCLEXTRA drive (fork/EXT_FLASH.md); the cart drive is LUN 0.
                hctl = os.path.basename(os.path.dirname(os.path.dirname(blk)))
                if hctl.rsplit(":", 1)[-1] not in ("0", hctl):
                    continue
                bname = os.path.basename(blk)
                path = os.path.join(dev_root, bname)
                if path not in dev.disks:
                    dev.disks.append(path)
                for part in sorted(glob.glob(os.path.join(blk, bname + "*"))):
                    ppath = os.path.join(dev_root, os.path.basename(part))
                    if ppath not in dev.disks:
                        dev.disks.append(ppath)
        out.append(dev)
    return out


def _unescape_mount(s: str) -> str:
    return re.sub(r"\\([0-7]{3})", lambda m: chr(int(m.group(1), 8)), s)


FAT_TYPES = ("vfat", "msdos", "fat", "exfat", "fuseblk", "fuse.exfat")


def parse_proc_mounts(text: str) -> List[Tuple[str, str, str]]:
    """(device, mount point, fs type) for each line of /proc/mounts."""
    out = []
    for line in text.splitlines():
        f = line.split()
        if len(f) < 3:
            continue
        out.append((_unescape_mount(f[0]), _unescape_mount(f[1]), f[2]))
    return out


def linux_labels(by_label: str = "/dev/disk/by-label") -> Dict[str, str]:
    """real block device -> filesystem label."""
    out = {}
    try:
        names = os.listdir(by_label)
    except OSError:
        return out
    for n in names:
        label = re.sub(r"\\x([0-9a-fA-F]{2})", lambda m: chr(int(m.group(1), 16)), n)
        out[os.path.realpath(os.path.join(by_label, n))] = label
    return out


def linux_volumes(mounts_text: Optional[str] = None, labels: Optional[Dict[str, str]] = None) -> List[Volume]:
    if mounts_text is None:
        mounts_text = _read("/proc/mounts") or ""
    if labels is None:
        labels = linux_labels()
    vols = []
    for dev, path, fstype in parse_proc_mounts(mounts_text):
        if fstype not in FAT_TYPES:
            continue
        real = os.path.realpath(dev) if dev.startswith("/dev/") else dev
        vols.append(Volume(path=path, device=real, label=labels.get(real) or labels.get(dev)))
    return vols


# ---------------------------------------------------------------------------
# macOS: ioreg + mount


def location_to_string(location_id: int) -> str:
    """Same formula as pyserial's list_ports_osx."""
    loc = ["{}-".format(location_id >> 24)]
    while location_id & 0xF00000:
        if len(loc) > 1:
            loc.append(".")
        loc.append("{}".format((location_id >> 20) & 0xF))
        location_id <<= 4
    return "".join(loc)


def _ioreg_str(node: dict, *keys) -> Optional[str]:
    for k in keys:
        v = node.get(k)
        if isinstance(v, str) and v:
            return v
    return None


def parse_ioreg(data: bytes) -> List[UsbDev]:
    """Parse `ioreg -a -l -r -c IOUSBHostDevice` output (a plist array).

    The walk is structural rather than tied to driver class names: a node with
    idVendor + locationID is a device, the nearest ancestor with
    bInterfaceNumber gives a port's interface, IOCalloutDevice marks a serial
    port and "BSD Name" (on a node with "Whole") marks a disk.
    """
    try:
        root = plistlib.loads(data)
    except Exception:
        return []
    if isinstance(root, dict):
        root = [root]
    devices: List[UsbDev] = []

    def walk(node, dev: Optional[UsbDev], iface: Optional[int]):
        if not isinstance(node, dict):
            return
        if "idVendor" in node and "locationID" in node and "bInterfaceNumber" not in node:
            dev = UsbDev(
                location=location_to_string(int(node.get("locationID") or 0)),
                vid=node.get("idVendor"),
                pid=node.get("idProduct"),
                serial=_ioreg_str(node, "USB Serial Number", "kUSBSerialNumberString"),
                product=_ioreg_str(node, "USB Product Name", "kUSBProductString", "IORegistryEntryName"),
            )
            devices.append(dev)
            iface = None
        if "bInterfaceNumber" in node:
            iface = node.get("bInterfaceNumber")
        if dev is not None:
            callout = node.get("IOCalloutDevice")
            if isinstance(callout, str):
                dev.ttys[callout] = iface if iface is not None else -1
            bsd = node.get("BSD Name")
            if isinstance(bsd, str) and "Whole" in node:
                path = "/dev/" + bsd
                if path not in dev.disks:
                    dev.disks.append(path)
        for child in node.get("IORegistryEntryChildren", []) or []:
            walk(child, dev, iface)

    for n in root:
        walk(n, None, None)
    # hubs nest their devices, so a device can show up twice; keep the
    # entry with the most detail
    unique: Dict[Tuple[str, Optional[str]], UsbDev] = {}
    for d in devices:
        k = (d.location, d.serial)
        old = unique.get(k)
        if old is None or len(d.ttys) + len(d.disks) > len(old.ttys) + len(old.disks):
            unique[k] = d
    return list(unique.values())


def scan_ioreg() -> List[UsbDev]:
    try:
        out = subprocess.run(
            ["ioreg", "-a", "-l", "-r", "-c", "IOUSBHostDevice"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=10,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    return parse_ioreg(out)


_MAC_MOUNT_RE = re.compile(r"^(?P<dev>\S+) on (?P<path>.+) \((?P<opts>[^()]*)\)$")


def parse_mac_mount(text: str) -> List[Tuple[str, str, str]]:
    """(device, mount point, fs type) from macOS `mount` output."""
    out = []
    for line in text.splitlines():
        m = _MAC_MOUNT_RE.match(line.strip())
        if m:
            fstype = m.group("opts").split(",")[0].strip()
            out.append((m.group("dev"), m.group("path"), fstype))
    return out


def mac_volumes(mount_text: Optional[str] = None) -> List[Volume]:
    if mount_text is None:
        try:
            mount_text = subprocess.run(
                ["mount"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5, universal_newlines=True
            ).stdout
        except (OSError, subprocess.SubprocessError):
            mount_text = ""
    vols = []
    for dev, path, fstype in parse_mac_mount(mount_text):
        if fstype not in ("msdos", "exfat", "vfat") and not path.startswith("/Volumes/"):
            continue
        # duplicate volume names get " 1", " 2" appended to the mount point
        label = re.sub(r" \d+$", "", os.path.basename(path))
        vols.append(Volume(path=path, device=dev, label=label))
    return vols


# ---------------------------------------------------------------------------
# Windows: drive letters


def windows_volumes() -> List[Volume]:
    vols = []
    try:
        import ctypes
        import string

        kernel32 = ctypes.windll.kernel32  # type: ignore[attr-defined]
        kernel32.SetErrorMode(1)  # SEM_FAILCRITICALERRORS: no "insert a disk" dialogs
        mask = kernel32.GetLogicalDrives()
        for i, letter in enumerate(string.ascii_uppercase):
            if not mask & (1 << i):
                continue
            root = letter + ":\\"
            if kernel32.GetDriveTypeW(root) not in (2, 3):  # removable, fixed
                continue
            name = ctypes.create_unicode_buffer(261)
            fs = ctypes.create_unicode_buffer(261)
            ok = kernel32.GetVolumeInformationW(root, name, 261, None, None, None, fs, 261)
            if ok:
                vols.append(Volume(path=root, device=letter + ":", label=name.value))
    except Exception:
        pass
    return vols


# ---------------------------------------------------------------------------
# Volumes, all platforms


def list_volumes(platform: Optional[str] = None) -> List[Volume]:
    platform = platform or sys.platform
    if platform.startswith("linux"):
        return linux_volumes()
    if platform == "darwin":
        return mac_volumes()
    if platform.startswith("win"):
        return windows_volumes()
    return []


def is_bootloader_volume(v: Volume) -> bool:
    if v.label and v.label.upper() == BOOT_LABEL:
        return True
    info = _read(os.path.join(v.path, "INFO_UF2.TXT"))
    return bool(info and "RP2350" in info)


def is_badge_volume(v: Volume) -> bool:
    return bool(v.label and v.label.upper() == DRIVE_LABEL)


def bootloader_volumes(volumes: Optional[List[Volume]] = None) -> List[Volume]:
    vols = list_volumes() if volumes is None else volumes
    return [v for v in vols if is_bootloader_volume(v)]


def badge_volumes(volumes: Optional[List[Volume]] = None) -> List[Volume]:
    vols = list_volumes() if volumes is None else volumes
    return [v for v in vols if is_badge_volume(v)]


# ---------------------------------------------------------------------------
# Simulators


def probe_sims(ports: Iterable[int] = SIM_PORTS, host: str = SIM_HOST, timeout: float = 0.15) -> List[int]:
    """Ports on `host` that accept a TCP connection (connect, then close)."""
    found = []
    for port in ports:
        try:
            s = socket.create_connection((host, port), timeout=timeout)
        except OSError:
            continue
        try:
            s.close()
        except OSError:
            pass
        found.append(port)
    return found


def sim_badge(port: int, host: str = SIM_HOST) -> Badge:
    key = "sim:%d" % port if host == SIM_HOST else "sim:%s:%d" % (host, port)
    return Badge(id=key, kind="sim", cart="socket://%s:%d" % (host, port), sim_port=port, short=key)


def parse_sim_spec(spec: str) -> List[Tuple[str, int]]:
    """'7341,7342' | '7341-7344' | 'host:7341' | 'none' -> [(host, port)]."""
    out = []
    if not spec or spec.strip().lower() in ("none", "off", "no"):
        return out
    for item in spec.split(","):
        item = item.strip()
        if not item:
            continue
        host = SIM_HOST
        if ":" in item:
            host, _, item = item.rpartition(":")
        if "-" in item:
            a, _, b = item.partition("-")
            out.extend((host, p) for p in range(int(a), int(b) + 1))
        else:
            out.append((host, int(item)))
    return out


# ---------------------------------------------------------------------------
# Putting it together


def assign_short_ids(badges: Sequence[Badge], min_len: int = 6) -> None:
    serials = [b for b in badges if b.serial]
    for b in badges:
        if b.short:
            continue
        if not b.serial:
            b.short = b.id
            continue
        n = min(min_len, len(b.serial))
        while n < len(b.serial):
            suffix = b.serial[-n:].upper()
            if sum(1 for o in serials if o.serial.upper().endswith(suffix)) == 1:
                break
            n += 1
        b.short = b.serial[-n:].upper()


def attach_usb_info(badges: List[Badge], usb: List[UsbDev], volumes: List[Volume], scan_: Scan) -> None:
    """Match sysfs/ioreg devices to badges: drives, and drive-only badges."""
    by_dev = {v.device: v for v in volumes if v.device}
    used_volumes = set()
    for dev in usb:
        if dev.is_bootloader:
            mounted = [by_dev[d] for d in dev.disks if d in by_dev]
            if not mounted and dev.disks:
                scan_.unmounted.append((dev.disks[-1], BOOT_LABEL))
            continue
        if not dev.is_badge:
            continue
        badge = None
        for b in badges:
            if (b.serial and dev.serial and b.serial == dev.serial) or (b.location and b.location == dev.location):
                badge = b
                break
            if any(t in (b.console, b.cart) for t in dev.ttys):
                badge = b
                break
        if badge is None:
            serial = dev.serial if valid_serial(dev.serial) else None
            badge = Badge(id=serial or "usb:" + dev.location, kind="stock", serial=serial, location=dev.location)
            badges.append(badge)
        if not badge.location:
            badge.location = dev.location
        mounted = [by_dev[d] for d in dev.disks if d in by_dev]
        # With a second drive (SYCLEXTRA, LUN 1) mounted too, the cart drive is
        # the one labelled SYCLBADGE.
        labelled = [v for v in mounted if is_badge_volume(v)]
        if labelled:
            mounted = labelled
        if mounted:
            badge.drive = mounted[0].path
            used_volumes.add(mounted[0].path)
        elif dev.disks:
            scan_.unmounted.append((dev.disks[-1], DRIVE_LABEL))
    for v in badge_volumes(volumes):
        if v.path not in used_volumes:
            scan_.loose_drives.append(v)


def scan(
    sims: Optional[Iterable[Tuple[str, int]]] = None,
    probe: bool = True,
    drives: bool = True,
    platform: Optional[str] = None,
    ports: Optional[list] = None,
    usb: Optional[List[UsbDev]] = None,
    volumes: Optional[List[Volume]] = None,
) -> Scan:
    """Discover badges and simulators.

    sims:   (host, port) pairs to probe; default 127.0.0.1:7341-7356.
    probe:  False skips simulators entirely.
    drives: False skips drive lookup (faster; used by the lobby).
    ports, usb, volumes: canned data instead of asking the system (tests).
    """
    platform = platform or sys.platform
    result = Scan()
    if ports is None:
        ports = list_serial_ports()
    hints: Dict[str, int] = {}
    if usb is None:
        usb = []
        if platform.startswith("linux"):
            if drives:
                usb = scan_sysfs()
        elif platform == "darwin":
            if any(is_badge_port(p) for p in ports) or drives:
                usb = _cached_ioreg(tuple(sorted(p.device for p in ports)))
    if platform == "darwin":
        for d in usb:
            if d.is_badge:
                hints.update({t: n for t, n in d.ttys.items() if n is not None and n >= 0})
    badges = group_ports(ports, hints)
    if drives:
        if volumes is None:
            volumes = list_volumes(platform)
        attach_usb_info(badges, usb, volumes, result)
        result.bootloader = bootloader_volumes(volumes)
        if not platform.startswith("linux") and platform != "darwin":
            # Windows: only an unambiguous pairing
            missing = [b for b in badges if not b.drive]
            if len(missing) == 1 and len(result.loose_drives) == 1:
                missing[0].drive = result.loose_drives.pop().path
        elif platform == "darwin" and not usb:
            missing = [b for b in badges if not b.drive]
            if len(missing) == 1 and len(result.loose_drives) == 1:
                missing[0].drive = result.loose_drives.pop().path
    if probe:
        targets = list(sims) if sims is not None else [(SIM_HOST, p) for p in SIM_PORTS]
        for host, port in targets:
            if probe_sims([port], host):
                badges.append(sim_badge(port, host))
    badges.sort(key=lambda b: (b.is_sim, b.sim_port or 0, b.location or "", b.id))
    assign_short_ids(badges)
    result.badges = badges
    return result


_ioreg_cache: Tuple[Optional[tuple], List[UsbDev]] = (None, [])


def _cached_ioreg(key: tuple) -> List[UsbDev]:
    """ioreg costs ~0.1 s; the lobby rescans every second, so reuse the last
    answer while the set of serial ports is unchanged."""
    global _ioreg_cache
    if _ioreg_cache[0] == key:
        return _ioreg_cache[1]
    devs = scan_ioreg()
    _ioreg_cache = (key, devs)
    return devs


# ---------------------------------------------------------------------------
# Choosing badges from the command line


class SelectError(Exception):
    pass


def match(b: Badge, token: str) -> bool:
    t = token.strip()
    low = t.lower()
    if low in (b.id.lower(), b.short.lower()):
        return True
    if t in (b.console, b.cart, b.drive):
        return True
    if b.is_sim:
        if low in ("sim", "sims"):
            return True
        if t.isdigit() and int(t) == b.sim_port:
            return True
        if low.startswith("sim") and low[3:].lstrip(":").isdigit() and int(low[3:].lstrip(":")) == b.sim_port:
            return True
        return False
    if b.serial and len(t) >= 3 and low in b.serial.lower():
        return True
    if b.location and low in (b.location.lower(), "usb:" + b.location.lower()):
        return True
    return False


def select(badges: Sequence[Badge], tokens: Sequence[str]) -> List[Badge]:
    """Badges matching each token; each token must match exactly one badge
    (except 'sim', which matches every simulator)."""
    chosen: List[Badge] = []
    for tok in tokens:
        hits = [b for b in badges if match(b, tok)]
        if not hits:
            raise SelectError("no badge matches %r (see `badge list`)" % tok)
        if len(hits) > 1 and tok.lower() not in ("sim", "sims"):
            raise SelectError("%r matches several badges: %s" % (tok, ", ".join(b.name() for b in hits)))
        for b in hits:
            if b not in chosen:
                chosen.append(b)
    return chosen
