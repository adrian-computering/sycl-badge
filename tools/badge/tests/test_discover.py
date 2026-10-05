"""Discovery with canned pyserial / sysfs / ioreg / mount data per platform."""

import os
import plistlib
import sys
import tempfile
import unittest
from types import SimpleNamespace

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from badge import discover  # noqa: E402
from badge.discover import Volume  # noqa: E402

SER_A = "E6614C311B4A7A31"
SER_B = "E6614C311B4A9F02"


def port(device, serial=None, location=None, interface=None, vid=1234, pid=1234, product="SYCL Badge V2"):
    return SimpleNamespace(
        device=device,
        vid=vid,
        pid=pid,
        serial_number=serial,
        location=location,
        interface=interface,
        product=product,
        manufacturer="Zig Embedded Group",
    )


FTDI = port("/dev/ttyUSB0", serial="A10K1234", location="1-4", vid=0x0403, pid=0x6001, product="FT232R USB UART")


class LocationTest(unittest.TestCase):
    def test_split(self):
        self.assertEqual(discover.split_location("1-1.2:1.3"), ("1-1.2", 3))
        self.assertEqual(discover.split_location("1-2:x.1"), ("1-2", 1))
        self.assertEqual(discover.split_location("20-1.2"), ("20-1.2", None))
        self.assertEqual(discover.split_location("3-10.4.1:1.0"), ("3-10.4.1", 0))
        self.assertEqual(discover.split_location(None), (None, None))

    def test_mac_location_formula(self):
        self.assertEqual(discover.location_to_string(0x14120000), "20-1.2")
        self.assertEqual(discover.location_to_string(0x01100000), "1-1")

    def test_valid_serial(self):
        self.assertTrue(discover.valid_serial(SER_A))
        for bad in (None, "", "serial number", "Serial Number", "n/a"):
            self.assertFalse(discover.valid_serial(bad))


class LinuxPortsTest(unittest.TestCase):
    def test_fork_and_stock(self):
        ports = [
            port("/dev/ttyACM0", SER_A, "1-1.2:1.1", "SYCL Badge Console"),
            port("/dev/ttyACM1", SER_A, "1-1.2:1.3", "SYCL Badge Cart Serial"),
            port("/dev/ttyACM2", "serial number", "1-1.3:1.1", "SYCL Badge Console"),
            port("/dev/ttyACM3", "serial number", "1-1.4:1.1", None),
            FTDI,
        ]
        s = discover.scan(ports=ports, probe=False, drives=False, platform="linux")
        by = {b.id: b for b in s.badges}
        self.assertEqual(set(by), {SER_A, "usb:1-1.3", "usb:1-1.4"})
        a = by[SER_A]
        self.assertEqual((a.kind, a.console, a.cart), ("fork", "/dev/ttyACM0", "/dev/ttyACM1"))
        self.assertEqual(a.short, SER_A[-6:])
        self.assertEqual((by["usb:1-1.3"].kind, by["usb:1-1.3"].console, by["usb:1-1.3"].cart), ("stock", "/dev/ttyACM2", None))
        self.assertEqual(by["usb:1-1.4"].console, "/dev/ttyACM3")

    def test_interface_numbers_beat_names(self):
        # ports listed in reverse order and without interface strings
        ports = [port("/dev/ttyACM7", SER_A, "1-1.2:1.3"), port("/dev/ttyACM6", SER_A, "1-1.2:1.1")]
        (b,) = discover.group_ports(ports)
        self.assertEqual((b.console, b.cart), ("/dev/ttyACM6", "/dev/ttyACM7"))

    def test_sysfs_drives_and_drive_only_badge(self):
        root = tempfile.mkdtemp()
        self.addCleanup(lambda: __import__("shutil").rmtree(root))
        base = os.path.join(root, "bus", "usb", "devices")

        def mk(path, files=None):
            os.makedirs(path, exist_ok=True)
            for k, v in (files or {}).items():
                with open(os.path.join(path, k), "w") as f:
                    f.write(v + "\n")

        def device(name, vid, pid, serial, product, ifaces):
            mk(os.path.join(base, name), {"idVendor": vid, "idProduct": pid, "serial": serial, "product": product})
            for n, kind, dev in ifaces:
                idir = os.path.join(base, "%s:1.%d" % (name, n))
                mk(idir, {"bInterfaceNumber": "%02x" % n})
                if kind == "tty":
                    mk(os.path.join(idir, "tty", dev))
                elif kind == "blk":
                    blk = os.path.join(idir, "host3", "target3:0:0", "3:0:0:0", "block", dev)
                    mk(blk)
                elif kind == "part":
                    blk = os.path.join(idir, "host4", "target4:0:0", "4:0:0:0", "block", dev)
                    mk(os.path.join(blk, dev + "1"))

        device("1-1.2", "04d2", "04d2", SER_A, "SYCL Badge V2", [(0, "blk", "sdb"), (1, "tty", "ttyACM0"), (3, "tty", "ttyACM1")])
        device("1-1.5", "04d2", "04d2", "serial number", "SYCL Badge V2", [(0, "blk", "sdd")])  # upstream, MSC only
        device("1-1.6", "2e8a", "000f", SER_B, "RP2350 Boot", [(0, "part", "sdc"), (1, "none", "")])
        device("1-1.7", "046d", "c52b", "", "Receiver", [])
        usb = discover.scan_sysfs(root)
        self.assertEqual([d.location for d in usb], ["1-1.2", "1-1.5", "1-1.6", "1-1.7"])
        self.assertEqual(usb[0].ttys, {"/dev/ttyACM0": 1, "/dev/ttyACM1": 3})
        self.assertEqual(usb[0].disks, ["/dev/sdb"])
        self.assertEqual(usb[2].disks, ["/dev/sdc", "/dev/sdc1"])
        self.assertTrue(usb[2].is_bootloader)

        mounts = (
            "/dev/sda1 / ext4 rw 0 0\n"
            "/dev/sdb /media/me/SYCLBADGE vfat rw,nosuid 0 0\n"
            "/dev/sdd /media/me/SYCLBADGE1 vfat rw 0 0\n"
        )
        labels = {"/dev/sdb": "SYCLBADGE", "/dev/sdd": "SYCLBADGE", "/dev/sdc1": "RP2350"}
        vols = discover.linux_volumes(mounts, labels)
        ports = [
            port("/dev/ttyACM0", SER_A, "1-1.2:1.1", "SYCL Badge Console"),
            port("/dev/ttyACM1", SER_A, "1-1.2:1.3", "SYCL Badge Cart Serial"),
        ]
        s = discover.scan(ports=ports, probe=False, platform="linux", usb=usb, volumes=vols)
        by = {b.id: b for b in s.badges}
        self.assertEqual(by[SER_A].drive, "/media/me/SYCLBADGE")
        self.assertEqual(by["usb:1-1.5"].kind, "stock")
        self.assertEqual(by["usb:1-1.5"].drive, "/media/me/SYCLBADGE1")
        self.assertIsNone(by["usb:1-1.5"].console)
        self.assertEqual(s.unmounted, [("/dev/sdc1", "RP2350")])
        self.assertEqual(s.loose_drives, [])

    def test_proc_mounts_escapes(self):
        m = discover.parse_proc_mounts("/dev/sdb /media/me/MY\\040DRIVE vfat rw 0 0\n")
        self.assertEqual(m, [("/dev/sdb", "/media/me/MY DRIVE", "vfat")])


class MacTest(unittest.TestCase):
    CU_CONSOLE = "/dev/cu.usbmodem%s2" % SER_A
    CU_CART = "/dev/cu.usbmodem%s4" % SER_A

    def mac_ports(self, interface="SYCL Badge Console"):
        # pyserial on macOS: one location for both ports, the same (or no)
        # interface name for both, serial may be missing
        return [
            port(self.CU_CART, SER_A, "20-1.2", interface),
            port(self.CU_CONSOLE, SER_A, "20-1.2", interface),
        ]

    def test_name_order_fallback(self):
        for iface in ("SYCL Badge Console", None):
            (b,) = discover.group_ports(self.mac_ports(iface))
            self.assertEqual((b.console, b.cart, b.kind), (self.CU_CONSOLE, self.CU_CART, "fork"), iface)

    def test_missing_serial_groups_by_location(self):
        ports = [
            port("/dev/cu.usbmodem14102", None, "20-1.1"),
            port("/dev/cu.usbmodem14104", None, "20-1.1"),
            port("/dev/cu.usbmodem14202", "serial number", "20-1.2"),
        ]
        bs = {b.id: b for b in discover.group_ports(ports)}
        self.assertEqual(set(bs), {"usb:20-1.1", "usb:20-1.2"})
        self.assertEqual(bs["usb:20-1.1"].cart, "/dev/cu.usbmodem14104")
        self.assertEqual(bs["usb:20-1.2"].kind, "stock")

    def ioreg_plist(self):
        def iface(n, children):
            return {"IOObjectClass": "IOUSBHostInterface", "bInterfaceNumber": n, "IORegistryEntryChildren": children}

        badge = {
            "IOObjectClass": "IOUSBHostDevice",
            "IORegistryEntryName": "SYCL Badge V2",
            "idVendor": 1234,
            "idProduct": 1234,
            "locationID": 0x14120000,
            "USB Serial Number": SER_A,
            "USB Product Name": "SYCL Badge V2",
            "IORegistryEntryChildren": [
                iface(0, [{"IOObjectClass": "IOUSBMassStorageInterfaceNub", "IORegistryEntryChildren": [
                    {"IOObjectClass": "IOMedia", "BSD Name": "disk4", "Whole": True, "IORegistryEntryChildren": []}
                ]}]),
                iface(1, [{"IOObjectClass": "AppleUSBACMControl"}]),
                iface(2, [{"IOObjectClass": "AppleUSBACMData", "IORegistryEntryChildren": [
                    {"IOObjectClass": "IOSerialBSDClient", "IOCalloutDevice": self.CU_CONSOLE, "IODialinDevice": "/dev/tty.x"}
                ]}]),
                iface(3, [{"IOObjectClass": "AppleUSBACMControl"}]),
                iface(4, [{"IOObjectClass": "AppleUSBACMData", "IORegistryEntryChildren": [
                    {"IOObjectClass": "IOSerialBSDClient", "IOCalloutDevice": self.CU_CART}
                ]}]),
            ],
        }
        upstream = {  # MSC-only upstream badge on another port
            "IOObjectClass": "IOUSBHostDevice",
            "idVendor": 1234,
            "idProduct": 1234,
            "locationID": 0x14130000,
            "kUSBSerialNumberString": "serial number",
            "kUSBProductString": "SYCL Badge V2",
            "IORegistryEntryChildren": [iface(0, [{"BSD Name": "disk5", "Whole": True}])],
        }
        hub = {"IOObjectClass": "IOUSBHostDevice", "idVendor": 0x05AC, "idProduct": 1, "locationID": 0x14000000,
               "IORegistryEntryChildren": []}
        hub_with_child = dict(hub, IORegistryEntryChildren=[{"IOObjectClass": "AppleUSB20HubPort", "IORegistryEntryChildren": [badge]}])
        return plistlib.dumps([hub_with_child, badge, upstream])

    def test_parse_ioreg(self):
        devs = discover.parse_ioreg(self.ioreg_plist())
        self.assertEqual(len(devs), 3)
        b = devs[1]
        self.assertEqual((b.location, b.serial, b.disks), ("20-1.2", SER_A, ["/dev/disk4"]))
        self.assertEqual(b.ttys, {self.CU_CONSOLE: 2, self.CU_CART: 4})
        self.assertTrue(b.is_badge)
        self.assertEqual(devs[2].serial, "serial number")
        self.assertEqual(devs[2].disks, ["/dev/disk5"])
        self.assertEqual(discover.parse_ioreg(b"not a plist"), [])

    def test_scan_with_ioreg_and_mount(self):
        usb = discover.parse_ioreg(self.ioreg_plist())
        mount = (
            "/dev/disk3s1s1 on / (apfs, sealed, local, read-only, journaled)\n"
            "/dev/disk4 on /Volumes/SYCLBADGE (msdos, local, nodev, nosuid, noowners, noatime, fskit)\n"
            "/dev/disk5 on /Volumes/SYCLBADGE 1 (msdos, local, nodev, nosuid, noowners)\n"
        )
        vols = discover.mac_volumes(mount)
        self.assertEqual([(v.path, v.label) for v in vols], [("/Volumes/SYCLBADGE", "SYCLBADGE"), ("/Volumes/SYCLBADGE 1", "SYCLBADGE")])
        # pyserial lists the ports in the "wrong" order with a shared interface name
        s = discover.scan(ports=self.mac_ports()[::-1], probe=False, platform="darwin", usb=usb, volumes=vols)
        by = {b.id: b for b in s.badges}
        self.assertEqual(by[SER_A].console, self.CU_CONSOLE)
        self.assertEqual(by[SER_A].cart, self.CU_CART)
        self.assertEqual(by[SER_A].drive, "/Volumes/SYCLBADGE")
        self.assertEqual(by["usb:20-1.3"].drive, "/Volumes/SYCLBADGE 1")
        self.assertEqual(by["usb:20-1.3"].kind, "stock")

    def test_scan_without_ioreg_pairs_single_drive(self):
        vols = discover.mac_volumes("/dev/disk4 on /Volumes/SYCLBADGE (msdos, local)\n")
        s = discover.scan(ports=self.mac_ports(None), probe=False, platform="darwin", usb=[], volumes=vols)
        self.assertEqual(s.badges[0].drive, "/Volumes/SYCLBADGE")


class WindowsTest(unittest.TestCase):
    def test_ports_and_drive_pairing(self):
        ports = [
            port("COM6", SER_A, "1-2:x.3", None),
            port("COM5", SER_A, "1-2:x.1", None),
            FTDI,
        ]
        vols = [Volume("E:\\", "E:", "SYCLBADGE"), Volume("C:\\", "C:", "Windows")]
        s = discover.scan(ports=ports, probe=False, platform="win32", usb=[], volumes=vols)
        (b,) = s.badges
        self.assertEqual((b.console, b.cart, b.drive), ("COM5", "COM6", "E:\\"))

    def test_ambiguous_drives_stay_loose(self):
        ports = [port("COM5", SER_A, "1-2:x.1"), port("COM7", SER_B, "1-3:x.1")]
        vols = [Volume("E:\\", "E:", "SYCLBADGE"), Volume("F:\\", "F:", "SYCLBADGE")]
        s = discover.scan(ports=ports, probe=False, platform="win32", usb=[], volumes=vols)
        self.assertTrue(all(b.drive is None for b in s.badges))
        self.assertEqual([v.path for v in s.loose_drives], ["E:\\", "F:\\"])

    def test_stock_serial_dropped_by_pyserial(self):
        # pyserial on Windows drops serials that are not \\w+ ("serial number")
        (b,) = discover.group_ports([port("COM3", None, "1-4:x.1")])
        self.assertEqual((b.id, b.console, b.kind), ("usb:1-4", "COM3", "stock"))


class BootDriveTest(unittest.TestCase):
    def test_info_uf2(self):
        d = tempfile.mkdtemp()
        with open(os.path.join(d, "INFO_UF2.TXT"), "w") as f:
            f.write("UF2 Bootloader v1.0\nModel: Raspberry Pi RP2350\nBoard-ID: RP2350\n")
        self.assertTrue(discover.is_bootloader_volume(Volume(d, None, "NO NAME")))
        self.assertTrue(discover.is_bootloader_volume(Volume("/nonexistent", None, "RP2350")))
        self.assertFalse(discover.is_bootloader_volume(Volume("/nonexistent", None, "SYCLBADGE")))


class SelectTest(unittest.TestCase):
    def badges(self):
        a = discover.Badge(id=SER_A, kind="fork", serial=SER_A, console="/dev/ttyACM0", cart="/dev/ttyACM1", location="1-1.2")
        b = discover.Badge(id=SER_B, kind="fork", serial=SER_B, console="/dev/ttyACM2", cart="/dev/ttyACM3", drive="/media/B")
        s1 = discover.sim_badge(7341)
        s2 = discover.sim_badge(7342)
        bs = [a, b, s1, s2]
        discover.assign_short_ids(bs)
        return bs

    def test_short_ids_unique(self):
        bs = self.badges()
        self.assertEqual(bs[0].short, "4A7A31")
        c = discover.Badge(id="X", kind="fork", serial="00000000004A7A31")
        d = discover.Badge(id="Y", kind="fork", serial="11111111114A7A31")
        discover.assign_short_ids([c, d])
        self.assertNotEqual(c.short, d.short)
        self.assertTrue(c.short.endswith("4A7A31"))

    def test_select(self):
        bs = self.badges()
        a, b, s1, s2 = bs
        self.assertEqual(discover.select(bs, ["4a7a31"]), [a])
        self.assertEqual(discover.select(bs, [SER_B]), [b])
        self.assertEqual(discover.select(bs, ["/dev/ttyACM1"]), [a])
        self.assertEqual(discover.select(bs, ["/media/B"]), [b])
        self.assertEqual(discover.select(bs, ["7342"]), [s2])
        self.assertEqual(discover.select(bs, ["sim:7341"]), [s1])
        self.assertEqual(discover.select(bs, ["sim"]), [s1, s2])
        self.assertEqual(discover.select(bs, ["1-1.2"]), [a])
        with self.assertRaises(discover.SelectError):
            discover.select(bs, ["E6614C311B4A"])  # prefix of both
        with self.assertRaises(discover.SelectError):
            discover.select(bs, ["nothing"])

    def test_sim_spec(self):
        self.assertEqual(discover.parse_sim_spec("7341,7343-7344"), [("127.0.0.1", 7341), ("127.0.0.1", 7343), ("127.0.0.1", 7344)])
        self.assertEqual(discover.parse_sim_spec("10.0.0.2:9000"), [("10.0.0.2", 9000)])
        self.assertEqual(discover.parse_sim_spec("none"), [])

    def test_probe_sims(self):
        import socket

        srv = socket.socket()
        srv.bind(("127.0.0.1", 0))
        srv.listen(1)
        p = srv.getsockname()[1]
        self.addCleanup(srv.close)
        closed = socket.socket()
        closed.bind(("127.0.0.1", 0))
        q = closed.getsockname()[1]
        closed.close()
        self.assertEqual(discover.probe_sims([p, q]), [p])
        b = discover.sim_badge(p)
        self.assertEqual(b.cart, "socket://127.0.0.1:%d" % p)


if __name__ == "__main__":
    unittest.main()


class ExtFlashDriveTests(unittest.TestCase):
    """Ext-flash firmware (fork/EXT_FLASH.md) adds LUN 1, the SYCLEXTRA drive."""

    def test_sysfs_keeps_lun0_only(self):
        root = tempfile.mkdtemp()
        self.addCleanup(lambda: __import__("shutil").rmtree(root))
        base = os.path.join(root, "bus", "usb", "devices")
        os.makedirs(os.path.join(base, "1-1.2"))
        for k, v in {"idVendor": "04d2", "idProduct": "04d2", "serial": SER_A, "product": "SYCL Badge V2"}.items():
            with open(os.path.join(base, "1-1.2", k), "w") as f:
                f.write(v + "\n")
        idir = os.path.join(base, "1-1.2:1.0")
        os.makedirs(idir)
        with open(os.path.join(idir, "bInterfaceNumber"), "w") as f:
            f.write("00\n")
        # LUN 1 sorts after LUN 0 here, but its disk name sorts first.
        os.makedirs(os.path.join(idir, "host3", "target3:0:0", "3:0:0:1", "block", "sda"))
        os.makedirs(os.path.join(idir, "host3", "target3:0:0", "3:0:0:0", "block", "sdb"))
        (dev,) = discover.scan_sysfs(root)
        self.assertEqual(dev.disks, ["/dev/sdb"])

    def test_labelled_drive_wins(self):
        dev = discover.UsbDev(location="1-1.2", vid=0x04D2, pid=0x04D2, serial=SER_A, product="SYCL Badge V2")
        dev.disks = ["/dev/disk5", "/dev/disk4"]
        vols = [
            discover.Volume(path="/Volumes/SYCLEXTRA", device="/dev/disk5", label="SYCLEXTRA"),
            discover.Volume(path="/Volumes/SYCLBADGE", device="/dev/disk4", label="SYCLBADGE"),
        ]
        s = discover.scan(ports=[], usb=[dev], volumes=vols, probe=False, platform="darwin")
        (b,) = s.badges
        self.assertEqual(b.drive, "/Volumes/SYCLBADGE")
        self.assertEqual(s.loose_drives, [])
