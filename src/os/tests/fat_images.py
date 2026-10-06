#!/usr/bin/env python3
"""Checks FAT images written by cart files (fork/CART_FILES.md) with real FAT tools.

Builds and runs the `fat-images` host tool (src/os/tests/fat_images.zig): it
writes images of both badge volumes through loader/fat_write.zig and
storage.zig, plus a power cut after every flash write of one
create/write/commit, and a manifest of the files each image must hold.

For every image:
- `fsck.fat -n` must report nothing, except for cuts inside commit, where
  "FATs differ" (FAT 1 written, FAT 2 not yet) and reclaimed lost clusters
  are allowed;
- a FAT reader lists the root directory: exactly the manifest's files (long
  names), sizes and SHA-256 of the contents. For a cut inside commit the new
  file is either absent or complete.

The reader is mtools (mdir/mcopy) when installed, else pyfatfs when importable
(pip install pyfatfs); without either the listing is skipped (said so).

Run from the repository root:  python3 src/os/tests/fat_images.py
Environment: ZIG (default: zig on PATH), FSCK_FAT (default: fsck.fat on PATH or
/usr/sbin/fsck.fat).
"""
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))

ALLOWED_IN_COMMIT = [
    re.compile(r"^FATs differ but appear to be intact\.$"),
    re.compile(r"^\s*Using first FAT\.$"),
    re.compile(r"^Reclaimed \d+ unused clusters \(\d+ bytes\)\.$"),
    re.compile(r"^Leaving filesystem unchanged\.$"),
]


def find_fsck():
    for cand in (os.environ.get("FSCK_FAT"), shutil.which("fsck.fat"), "/usr/sbin/fsck.fat", "/sbin/fsck.fat"):
        if cand and os.path.exists(cand):
            return cand
    return None


def fsck(fsck_path, image):
    p = subprocess.run([fsck_path, "-n", image], capture_output=True, text=True)
    lines = []
    for line in (p.stdout + p.stderr).splitlines():
        if not line.strip() or line.startswith("fsck.fat ") or line.startswith(image + ":"):
            continue
        lines.append(line)
    return p.returncode, lines


class MtoolsReader:
    name = "mtools"

    @staticmethod
    def available():
        return shutil.which("mdir") is not None and shutil.which("mcopy") is not None

    def files(self, image):
        env = dict(os.environ, MTOOLS_SKIP_CHECK="1", MTOOLS_LOWER_CASE="0")
        out = subprocess.run(["mdir", "-i", image, "-a", "-b", "::"], capture_output=True, text=True, env=env, check=True).stdout
        result = {}
        for path in out.splitlines():
            path = path.strip()
            if not path or path.endswith("/"):
                continue
            name = path.split("/")[-1]
            data = subprocess.run(["mcopy", "-n", "-i", image, "::" + name, "-"], capture_output=True, env=env, check=True).stdout
            result[name] = data
        return result


class PyfatfsReader:
    name = "pyfatfs"

    @staticmethod
    def available():
        try:
            import pyfatfs.PyFatFS  # noqa: F401
            return True
        except Exception:
            return False

    def files(self, image):
        from pyfatfs.PyFatFS import PyFatFS
        fs = PyFatFS(image, read_only=True)
        try:
            result = {}
            for name in fs.listdir("/"):
                if fs.isdir("/" + name):
                    continue
                with fs.openbin("/" + name) as f:
                    result[name] = f.read()
            return result
        finally:
            fs.close()


def check_listing(reader, image, entry):
    got = reader.files(image)
    want = {f["name"]: f for f in entry["files"]}
    maybe = entry.get("maybe")
    if maybe and maybe["name"] in got:
        want[maybe["name"]] = maybe
    errors = []
    if set(got) != set(want):
        errors.append("files %s, want %s" % (sorted(got), sorted(want)))
    for name, f in want.items():
        if name not in got:
            continue
        data = got[name]
        if len(data) != f["size"] or hashlib.sha256(data).hexdigest() != f["sha256"]:
            errors.append("%s: %d bytes, content %s" % (name, len(data), "differs" if len(data) == f["size"] else "?"))
    return errors


def main():
    zig = os.environ.get("ZIG", "zig")
    fsck_path = find_fsck()
    if fsck_path is None:
        print("fat_images: fsck.fat not found (dosfstools): skipped")
        return 0
    readers = [r for r in (MtoolsReader, PyfatfsReader) if r.available()]
    reader = readers[0]() if readers else None

    subprocess.run([zig, "build", "fat-images"], cwd=REPO, check=True)
    tool = os.path.join(REPO, "zig-out", "bin", "fat-images")
    failures = 0
    with tempfile.TemporaryDirectory(prefix="fat-images-") as out:
        subprocess.run([tool, out], check=True)
        with open(os.path.join(out, "manifest.json")) as f:
            manifest = json.load(f)
        counts = {}
        for entry in manifest:
            image = os.path.join(out, entry["image"])
            phase = entry["phase"]
            counts[phase] = counts.get(phase, 0) + 1
            rc, lines = fsck(fsck_path, image)
            errors = []
            if phase == "in_commit":
                bad = [l for l in lines if not any(p.match(l) for p in ALLOWED_IN_COMMIT)]
                if rc not in (0, 1) or bad:
                    errors.append("fsck.fat rc=%d: %s" % (rc, bad or lines))
            elif rc != 0 or lines:
                errors.append("fsck.fat rc=%d: %s" % (rc, lines))
            if reader is not None:
                errors += check_listing(reader, image, entry)
            if errors:
                failures += 1
                print("FAIL %s (%s): %s" % (entry["image"], phase, "; ".join(errors)))
        listing = "listed with %s" % reader.name if reader else "NOT listed (no mtools or pyfatfs)"
        print("fat_images: %d images (%s), fsck.fat -n, %s: %s" % (
            len(manifest),
            ", ".join("%d %s" % (n, p) for p, n in sorted(counts.items())),
            listing,
            "%d FAILED" % failures if failures else "all ok"))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
