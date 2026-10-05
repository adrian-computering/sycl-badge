"""Command line commands with fake badges, drives, consoles and carts."""

import contextlib
import io
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
sys.path.insert(0, HERE)

from badge import cli, console, discover, frames  # noqa: E402
from fakecart import FakeCart  # noqa: E402
from test_flash import CART, FIRMWARE  # noqa: E402

BADGE_PY = os.path.join(HERE, "..", "badge.py")


def run_cli(argv):
    out, err = io.StringIO(), io.StringIO()
    code = 0
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        try:
            code = cli.main(argv)
        except SystemExit as e:
            code = e.code
    return code, out.getvalue(), err.getvalue()


class FakeScanMixin:
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.drive_a = os.path.join(self.tmp, "SYCLBADGE")
        self.drive_b = os.path.join(self.tmp, "SYCLBADGE 1")
        os.makedirs(self.drive_a)
        os.makedirs(self.drive_b)
        self.cart = os.path.join(self.tmp, "lobby-demo.uf2")
        with open(self.cart, "wb") as f:
            f.write(CART)
        self.fw = os.path.join(self.tmp, "sycl-os-kernel.uf2")
        with open(self.fw, "wb") as f:
            f.write(FIRMWARE)

    def fake_scan(self, two=True, loose=False):
        a = discover.Badge(id="E6614C311B4A7A31", kind="fork", serial="E6614C311B4A7A31",
                           console="/dev/ttyACM0", cart="/dev/ttyACM1", drive=self.drive_a)
        b = discover.Badge(id="usb:1-1.3", kind="stock", location="1-1.3", console="/dev/ttyACM2",
                           drive=None if loose else self.drive_b)
        sim = discover.sim_badge(7341)
        badges = [a, b, sim] if two else [a, sim]
        discover.assign_short_ids(badges)
        s = discover.Scan(badges=badges)
        if loose:
            s.loose_drives = [discover.Volume(self.drive_b, None, "SYCLBADGE")]
        return mock.patch.object(discover, "scan", lambda **kw: s)


class ListTest(FakeScanMixin, unittest.TestCase):
    def test_table(self):
        with self.fake_scan():
            code, out, _ = run_cli(["list"])
        self.assertEqual(code, 0)
        lines = out.splitlines()
        self.assertTrue(lines[0].startswith("ID"))
        self.assertIn("4A7A31", lines[1])
        self.assertIn("/dev/ttyACM1", lines[1])
        self.assertIn("usb:1-1.3", lines[2])
        self.assertIn("socket://127.0.0.1:7341", lines[3])

    def test_json(self):
        import json

        with self.fake_scan(loose=True):
            code, out, _ = run_cli(["list", "--json"])
        data = json.loads(out)
        self.assertEqual(data["badges"][0]["kind"], "fork")
        self.assertEqual(data["loose_drives"], [self.drive_b])

    def test_empty(self):
        with mock.patch.object(discover, "scan", lambda **kw: discover.Scan()):
            code, out, _ = run_cli(["list"])
        self.assertIn("No badges", out)


class InstallTest(FakeScanMixin, unittest.TestCase):
    def test_install_all(self):
        with self.fake_scan():
            code, out, _ = run_cli(["install", self.cart, "--all"])
        self.assertEqual(code, 0, out)
        for d in (self.drive_a, self.drive_b):
            with open(os.path.join(d, "lobby-demo.uf2"), "rb") as f:
                self.assertEqual(f.read(), CART)

    def test_install_loose_drive_with_all(self):
        with self.fake_scan(loose=True):
            code, out, _ = run_cli(["install", self.cart, "--all", "--name", "demo"])
        self.assertEqual(code, 0, out)
        self.assertTrue(os.path.exists(os.path.join(self.drive_b, "demo.uf2")))

    def test_install_one_by_id(self):
        with self.fake_scan():
            code, out, _ = run_cli(["install", self.cart, "4a7a31"])
        self.assertEqual(code, 0, out)
        self.assertTrue(os.path.exists(os.path.join(self.drive_a, "lobby-demo.uf2")))
        self.assertFalse(os.path.exists(os.path.join(self.drive_b, "lobby-demo.uf2")))

    def test_ambiguous_without_all(self):
        with self.fake_scan():
            code, _, err = run_cli(["install", self.cart])
        self.assertEqual(code, 1)
        self.assertIn("--all", err)

    def test_refuses_firmware_and_junk(self):
        with self.fake_scan():
            code, _, err = run_cli(["install", self.fw, "--all"])
            self.assertEqual(code, 1)
            self.assertIn("badge flash", err)
            junk = os.path.join(self.tmp, "junk.uf2")
            with open(junk, "wb") as f:
                f.write(b"hello")
            code, _, err = run_cli(["install", junk, "--all"])
            self.assertEqual(code, 1)
            self.assertIn("512-byte", err)


class FlashCliTest(FakeScanMixin, unittest.TestCase):
    def test_refuses_cart(self):
        code, _, err = run_cli(["flash", self.cart])
        self.assertEqual(code, 1)
        self.assertIn("looks like a cart", err)

    def test_needs_choice_with_several(self):
        with self.fake_scan():
            code, _, err = run_cli(["flash", self.fw])
        self.assertEqual(code, 1)
        self.assertIn("--all", err)

    def test_all_hands_targets_to_flow(self):
        seen = {}

        def fake_flow(uf2, targets, **kw):
            seen["targets"] = [t.name() for t in targets]
            return []

        with self.fake_scan(), mock.patch("badge.flash.flash_many", fake_flow):
            code, out, _ = run_cli(["flash", self.fw, "--all"])
        self.assertEqual(code, 0, out)
        self.assertEqual(seen["targets"], ["4A7A31", "usb:1-1.3"])  # not the simulator


@unittest.skipUnless(hasattr(os, "openpty"), "needs a pty")
class ConsoleTest(unittest.TestCase):
    """console.run_command against a pty playing the badge OS console."""

    def fake_os(self, master, replies):
        def loop():
            buf = b""
            while True:
                try:
                    data = os.read(master, 1024)
                except OSError:
                    return
                if not data:
                    return
                for ch in data:
                    if ch == 3:
                        os.write(master, b"^C\r\nSYCL> ")
                        buf = b""
                    elif ch in (13, 10):
                        os.write(master, b"\r\n")
                        line = buf.decode()
                        buf = b""
                        if line in replies:
                            os.write(master, replies[line].encode())
                        os.write(master, b"SYCL> ")
                    else:
                        buf += bytes([ch])
                        os.write(master, bytes([ch]))  # echo

        t = threading.Thread(target=loop, daemon=True)
        t.start()
        return t

    def test_run_command(self):
        import tty

        master, slave = os.openpty()
        tty.setraw(master)
        tty.setraw(slave)
        self.addCleanup(os.close, master)
        path = os.ttyname(slave)
        self.fake_os(master, {"uptime": "Uptime: 12.3 s\r\n", "reboot bootsel": "\r\nRebooting to BootSelect...\r\n"})
        reply = console.run_command(path, "uptime", timeout=3)
        self.assertEqual(reply, "Uptime: 12.3 s")
        code, out, _ = run_cli(["console", "--port", path, "-c", "uptime"])
        self.assertEqual((code, out.strip()), (0, "Uptime: 12.3 s"))
        console.reboot_bootsel(path)
        os.close(slave)


class MonitorTest(unittest.TestCase):
    def test_frames_mode_against_fake_cart(self):
        cart = FakeCart(game="MON", name="cart")
        self.addCleanup(cart.close)
        proc = subprocess.Popen(
            [sys.executable, BADGE_PY, "monitor", "--frames", "--port", "socket://127.0.0.1:%d" % cart.port],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            universal_newlines=True,
        )
        try:
            cart.wait_connected()
            proc.stdin.write("welcome 0 1 4\ndata 3 hello\nbogus\n")
            proc.stdin.flush()
            cart.wait_for(lambda m: frames.Data(sender=3, data=b"hello") in m)
            self.assertIn(frames.Welcome(you=0, room=1, max_players=4), cart.msgs)
            cart.send_body(frames.Ping(token=9).pack())
            time.sleep(0.3)
        finally:
            out, err = proc.communicate(timeout=10)
        self.assertIn("<- HELLO v1 game='MON' name='cart'", out)
        self.assertIn("<- PING token=9", out)
        self.assertIn("-> WELCOME", out)
        self.assertIn("unknown command", err)
        self.assertEqual(cart.raw[0], 0)

    def test_text_mode(self):
        cart = FakeCart(hello=False)
        self.addCleanup(cart.close)
        proc = subprocess.Popen(
            [sys.executable, BADGE_PY, "monitor", "--port", "socket://127.0.0.1:%d" % cart.port, "--eol", "crlf"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            universal_newlines=True,
        )
        try:
            cart.wait_connected()
            cart.send_raw(b"echo: hi\n\x01")
            proc.stdin.write("ping\n")
            proc.stdin.flush()
            cart.wait_for(lambda m: True if b"ping\r\n" in cart.raw else None)
            time.sleep(0.3)
        finally:
            out, _ = proc.communicate(timeout=10)
        self.assertIn("echo: hi\n\\x01", out)


class EntryPointTest(unittest.TestCase):
    def test_help_and_version(self):
        out = subprocess.run([sys.executable, BADGE_PY, "--version"], stdout=subprocess.PIPE, universal_newlines=True).stdout
        self.assertIn("badge 0.1.0", out)
        r = subprocess.run([sys.executable, "-m", "badge", "--help"], stdout=subprocess.PIPE, universal_newlines=True,
                           cwd=os.path.join(HERE, ".."))
        for cmd in ("list", "console", "monitor", "flash", "install", "lobby"):
            self.assertIn(cmd, r.stdout)


if __name__ == "__main__":
    unittest.main()
