"""UF2 validation, drive copies and the flash flow with fake drives."""

import os
import shutil
import struct
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from badge import discover, flash  # noqa: E402


def uf2(addrs, family=0xE48BFF59, flags=0x2000, corrupt=None):
    out = bytearray()
    for i, addr in enumerate(addrs):
        block = struct.pack("<8I", flash.UF2_MAGIC0, flash.UF2_MAGIC1, flags, addr, 256, i, len(addrs), family)
        block += bytes(476) + struct.pack("<I", flash.UF2_MAGIC_END)
        out += block
    if corrupt is not None:
        out[corrupt * 512 + 508] ^= 0xFF
    return bytes(out)


FIRMWARE = uf2([0x10000000 + 256 * i for i in range(8)])
CART = uf2([0x20030000 + 256 * i for i in range(4)])


class UF2Test(unittest.TestCase):
    def test_firmware_vs_cart(self):
        fw = flash.parse_uf2(FIRMWARE)
        self.assertEqual(fw.blocks, 8)
        self.assertTrue(fw.looks_like_firmware)
        self.assertEqual(fw.family_names(), "RP2350 ARM-S")
        cart = flash.parse_uf2(CART)
        self.assertFalse(cart.looks_like_firmware)
        self.assertEqual((cart.lowest, cart.highest), (0x20030000, 0x20030400))

    def test_rejects(self):
        for data, why in (
            (b"", "empty"),
            (FIRMWARE[:700], "whole number"),
            (b"\x7fELF" + bytes(508), "magic"),
            (uf2([0x10000000, 0x10000100], corrupt=1), "block 1"),
        ):
            with self.assertRaises(flash.UF2Error) as cm:
                flash.parse_uf2(data)
            self.assertIn(why, str(cm.exception))

    def test_read_missing(self):
        with self.assertRaises(flash.UF2Error):
            flash.read_uf2("/nonexistent/x.uf2")


class CopyTest(unittest.TestCase):
    def test_copy(self):
        src_dir, drive = tempfile.mkdtemp(), tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, src_dir)
        self.addCleanup(shutil.rmtree, drive)
        src = os.path.join(src_dir, "lobby-demo.uf2")
        with open(src, "wb") as f:
            f.write(CART)
        dst = flash.copy_to_drive(src, drive)
        self.assertEqual(dst, os.path.join(drive, "lobby-demo.uf2"))
        with open(dst, "rb") as f:
            self.assertEqual(f.read(), CART)
        self.assertEqual(os.listdir(drive), ["lobby-demo.uf2"])
        flash.copy_to_drive(src, drive, "other.uf2")
        self.assertEqual(sorted(os.listdir(drive)), ["lobby-demo.uf2", "other.uf2"])


class FakeBootloader:
    """Pretends to be the RP2350 boot ROM: reboot_bootsel makes a drive
    appear; a complete UF2 written to it makes the drive vanish."""

    def __init__(self, root):
        self.root = root
        self.drives = []
        self.flashed = []
        self.rebooted = []

    def reboot(self, device):
        self.rebooted.append(device)
        threading.Timer(0.2, self.appear).start()

    def appear(self):
        path = os.path.join(self.root, "RP2350-%d" % len(self.drives))
        os.makedirs(path)
        with open(os.path.join(path, "INFO_UF2.TXT"), "w") as f:
            f.write("Model: Raspberry Pi RP2350\n")
        self.drives.append(path)
        threading.Thread(target=self._watch, args=(path,), daemon=True).start()

    def _watch(self, path):
        while True:
            for n in os.listdir(path):
                if n.endswith(".uf2") and os.path.getsize(os.path.join(path, n)) == len(FIRMWARE):
                    time.sleep(0.1)
                    self.flashed.append(path)
                    shutil.rmtree(path)
                    return
            time.sleep(0.05)

    def find(self):
        return [d for d in self.drives if os.path.exists(d)]


class FlashFlowTest(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.root, True)
        self.fw = os.path.join(self.root, "sycl-os-kernel.uf2")
        with open(self.fw, "wb") as f:
            f.write(FIRMWARE)
        self.boot = FakeBootloader(self.root)
        p1 = mock.patch.object(flash.BootDrives, "find", lambda _self: self.boot.find())
        p2 = mock.patch("badge.console.reboot_bootsel", self.boot.reboot)
        p1.start()
        p2.start()
        self.addCleanup(p1.stop)
        self.addCleanup(p2.stop)
        self.log = []

    def test_two_badges_in_turn(self):
        a = discover.Badge(id="A", kind="fork", serial="A", console="/dev/ttyACM0", short="A")
        b = discover.Badge(id="B", kind="stock", serial="B", console="/dev/ttyACM2", short="B")
        res = flash.flash_many(self.fw, [a, b], timeout=5, log=self.log.append)
        self.assertEqual([(r.target, r.ok) for r in res], [("A", True), ("B", True)])
        self.assertEqual(self.boot.rebooted, ["/dev/ttyACM0", "/dev/ttyACM2"])
        self.assertEqual(len(self.boot.flashed), 2)

    def test_existing_boot_drive_copied_first(self):
        self.boot.appear()
        res = flash.flash_many(self.fw, [], timeout=5, log=self.log.append)
        self.assertEqual([r.ok for r in res], [True])
        self.assertEqual(self.boot.rebooted, [])

    def test_no_drive_times_out(self):
        a = discover.Badge(id="A", kind="fork", serial="A", console="/dev/ttyACM0", short="A")
        with mock.patch("badge.console.reboot_bootsel", lambda dev: None):
            res = flash.flash_many(self.fw, [a], timeout=0.5, log=self.log.append)
        self.assertFalse(res[0].ok)
        self.assertIn("BOOT_SEL", res[0].detail)

    def test_manual_badge_without_console(self):
        a = discover.Badge(id="usb:1-1", kind="stock", short="usb:1-1")
        threading.Timer(0.3, self.boot.appear).start()  # the person pressed the buttons
        res = flash.flash_many(self.fw, [a], manual_timeout=5, log=self.log.append)
        self.assertTrue(res[0].ok)
        self.assertTrue(any("BOOT_SEL" in l for l in self.log))

    def test_sim_skipped(self):
        res = flash.flash_many(self.fw, [discover.sim_badge(7341)], log=self.log.append)
        self.assertEqual(res[0].detail, "simulator, skipped")


if __name__ == "__main__":
    unittest.main()
