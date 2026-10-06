# Cart files (carts write new files to the USB drives)

A cart can create a file on the badge's USB drives (SYCLBADGE, and SYCLEXTRA
when the external chip is present). The first user is Snouty Beam
(`carts/snouty-beam` in the snouty-badge monorepo): a received cart is saved
as an ordinary `.uf2` on the drive, so it shows in the menu like any other
cart, survives anything the slot would not, can be copied back to a laptop,
and is not limited to 252 KB or to RAM carts.

Branch `feature/cart-files`, based on fork `main` 298deab (it needs
ext-flash's volume table and cart-saves' `flash_ops.zig`). Status:
implemented, host-tested (power-cut sweeps, `fsck.fat`, a FAT reader) and
tried in the simulator; **untested on hardware**. Not merged into `main` until
a badge check passes (see [Hardware test](#hardware-test-f0)).

## Why this is safe, and when it is not

The firmware already changes the FAT itself: the console's delete
(`storage.deleteCart`) and formatting. It has no "create file" path. A
cart-written file is safe as long as no computer has the drive mounted: a
mounted host caches the FAT and directory and will write its stale copy back
over ours. Badges trading carts are not plugged into a laptop, so the OS
refuses writes while a USB host has configured the device, and the cart
shows a warning ("Unplug from the computer to receive"). A charger or power
bank never configures the device, so it does not count.

## Cart ABI (v1)

- `os_flags` bit 6 = `cart_files` (set when this feature is built in).
- Mailbox `0x2D` = `CART_FILE_REQ`, cart -> OS, payload
  `(request_addr - 0x20000000) >> 2`, same shape as `CART_SAVE_REQ`. The OS
  answers only through the request struct, never the FIFO.

```zig
pub const FILE_MAGIC: u32 = 0x314C4946; // "FIL1"

/// Lives in cart RAM (0x20035100..0x20080000), 4-byte aligned, 64 bytes.
pub const FileRequest = extern struct {
    magic: u32 = FILE_MAGIC,
    op: FileOp,
    state: FileState = .idle,      // idle -> pending (cart) -> busy -> done (OS)
    status: FileStatus = .ok,      // written by the OS
    volume: u32 = 0,               // 0 = SYCLBADGE, 1 = SYCLEXTRA
    offset: u32 = 0,               // create: total file size; write: byte offset
    buf: u32 = 0,                  // address in cart RAM
    len: u32 = 0,                  // bytes at buf
    result: u32 = 0,               // per op, written by the OS
    flags: u32 = 0,                // written by the OS on every reply, FileFlags
    _reserved: [6]u32 = @splat(0),
};

pub const FileOp = enum(u32) {
    probe = 1,  // result = ABI version (1)
    stat = 2,   // volume -> result = free bytes; buf/len optional: FileStat
    create = 3, // volume, buf/len = name, offset = size: reserve space, open
    write = 4,  // offset (must equal bytes written so far), buf, len 1..4096
    commit = 5, // all bytes written: link the file into the FAT and directory
    abort = 6,  // drop the open file; nothing on the drive changes
    _,
};

pub const FileState = enum(u32) { idle = 0, pending = 1, busy = 2, done = 3, _ };

pub const FileStatus = enum(u32) {
    ok = 0,
    exists = 1,       // create: a file with this name (long or 8.3) exists
    no_space = 2,     // create: not enough free clusters
    dir_full = 3,     // create: not enough free root directory entries
    bad_request = 4,  // bad op/volume/offset/len, or wrong order
    bad_buffer = 5,   // buf..buf+len not inside cart RAM
    bad_name = 6,     // name rules below
    usb_host = 7,     // a USB host has the drive: refused
    busy = 8,         // another request is in flight
    no_volume = 9,    // volume index not mounted
    not_open = 10,    // write/commit/abort with no open file
    io_error = 11,    // read-back after program did not match
    _,
};

pub const FileFlags = packed struct(u32) {
    usb_host: bool,   // a USB host has configured the device right now
    ext_volume: bool, // volume 1 (SYCLEXTRA) is mounted
    _: u30 = 0,
};

pub const FileStat = extern struct {
    free_bytes: u32,
    free_root_entries: u32,
    cluster_size: u32,
    total_bytes: u32,
};
```

Request flow (as cart saves):

1. Fill a `FileRequest`, `state = pending`, `dmb`, send the mailbox message.
2. For `create`, `write` and `commit`, mask interrupts first and spin from RAM
   code until `state == done`: core 0 turns XIP off while it erases.
   `probe`, `stat` and `abort` touch no flash.
3. On stock firmware nothing answers: give up after 250 ms of `pending`, then
   set `magic = 0` (the OS ignores magic 0).

`result` per op (the OS's choice where the table above says "per op"):
`probe` 1 (the ABI version), `stat` free bytes, `create` the bytes reserved
(the size rounded up to 512), `write` the bytes written so far, `commit` the
file size, `abort` and every error 0.

Rules:

- **Names:** 1-63 bytes, printable ASCII, none of `\ / : * ? " < > |`, no
  leading/trailing space or dot. The OS writes long-name entries plus a
  generated 8.3 name (`SNOUTY~1.UF2` style, unique on the volume).
- **One open file** at a time. Cart start and cart exit abort it.
- `create` reserves clusters and directory entries in RAM only. `write` goes
  sequentially into those clusters (free space, so a power cut leaves the
  drive as it was). `commit` writes FAT 1, FAT 2, then the directory entries,
  and flushes. A power cut inside commit can leave clusters marked used by no
  file (lost space a host's disk check reclaims), never a cross-linked or
  half-visible file.
- `usb_host` is checked by `create`, every `write` and `commit`. A host
  that attaches mid-file makes the next call fail; the cart then aborts.
- Root directory only (both volumes are flat: SYCLBADGE has 32 entries,
  SYCLEXTRA 128; a long name takes 1 entry per 13 characters plus one).

## For cart authors (cart-api)

```zig
const cart = @import("cart-api");

if (cart.cart_files()) {                       // os_flags bit 6, no probe needed
    if (cart.file_flags().usb_host) { /* "Unplug from the computer" */ }
    const st = try cart.file_stat(0);           // free_bytes, free_root_entries
    try cart.file_create(0, "pong.uf2", size);  // error.Exists: try "pong-2.uf2"
    errdefer cart.file_abort() catch {};
    try cart.file_write(0, first_part);         // sequential; any length
    try cart.file_write(first_part.len, rest);
    try cart.file_commit();                     // now the menu lists it
}
```

| Function | Does |
| --- | --- |
| `cart_files() bool` | the OS has cart files (os_flags bit 6) |
| `file_flags() FileFlags` | `usb_host`, `ext_volume` from the OS's last reply |
| `file_probe() FileError!u32` | ABI version; refreshes `file_flags()` |
| `file_stat(volume) FileError!FileStat` | free bytes and root entries (an open file's reservation counts as used) |
| `file_create(volume, name, size)` | checks the name, reserves space, opens |
| `file_write(offset, data)` | sequential bytes, sent in 4096-byte requests |
| `file_commit()` | links the file into the FAT and directory |
| `file_abort()` | drops the open file (`NotOpen` if none) |

Errors map one to one onto `FileStatus` (`Exists`, `NoSpace`, `DirFull`,
`BadRequest`, `BadBuffer`, `BadName`, `UsbHost`, `Busy`, `NoVolume`,
`NotOpen`, `IoError`), plus `Unsupported` when bit 6 is 0.

Timing (datasheet figures, to be measured with file-test): each 4 KB erase
block costs one erase (45 ms typical, 400 ms worst) and 16 page programs
(about 0.7 ms each), with the cart parked and its streaming audio paused. A
file written in 4096-byte pieces erases each block it covers once, so about
60 ms per 4 KB, roughly 1.5 s for 100 KB and 4 s for a 252 KB cart; commit adds
three erases. `create` (reads only) takes a few ms.

## OS design

- `src/os/loader/fat_write.zig`: pure logic over a sector interface
  (`storage_disk.zig` adapts `storage.readSector/writeSector/
  flushPendingWrites`). `create` parses the boot sector, scans the root
  directory (`exists` by the same rule as the menu, contiguous free entries:
  deleted ones and everything from the end marker on) and FAT 1, and reserves
  the first free clusters (first fit) in a 512-byte bitmap. `write` fills
  sectors in cluster order; a sector the file already started is read back,
  a new one starts zeroed. `commit` re-checks the name and that the reserved
  clusters are still free, picks the first free run of entries and the first
  free alias `BASIS~N.EXT` (no file may match it by long or 8.3 name), then
  writes FAT 1, FAT 2, the long-name entries (checksums from the alias) and
  the 8.3 entry, and an end marker after them when they went past the old
  one. A step erases at most one 4 KB block and reads back the sectors it
  wrote (CRC); a data block the next write continues in stays in the sector
  cache until then.
- `src/os/loader/fat_names.zig`: the name helpers `storage.zig` used
  (`normalizeName`, `formatShortName`, `readLfnEntriesMultiSector`,
  `sfnChecksum`), moved so the menu, console and cart files share one rule.
  Two one-past-the-end writes for full 8.3 names (`NAME1234.EXT`) are fixed
  there: `CartInfo.short_name` and the loader's name are `[12:0]` now.
- `src/os/system/cart_files.zig`: request validation (magic, 64-byte struct
  and buffers inside cart RAM), one open file, `busy` for a second request,
  probe/stat/create/abort answered at once, write/commit stepped one block
  per kernel main-loop pass (beside `saves.poll()`), buffered audio paused,
  `flags` on every reply, `cartReset()` on cart start/stop (from
  `multicore.zig`). Flash work runs on core 0 through `flash_ops.zig`, as for
  saves and the USB drive; the cart is parked with interrupts masked.
- `src/os/drivers/usb.zig` (+ a `set_configuration` callback in
  `usb/setup.zig`): "a host has the drive" = SET_CONFIGURATION since the last
  bus reset, and start-of-frame packets still arriving (VBUS detection is
  forced on, so an unplugged cable looks like a suspended bus). A generation
  counter goes up whenever a host (re)appears; a file opened before that is
  refused (`usb_host`) until the cart aborts it.
- `src/os/loader/storage.zig`: a host backend (RAM images, a flush budget
  for power cuts) so host tests run its real sector cache, `formatVolume` and
  `deleteCart`; no change on the badge apart from the name fix.
- Menu: nothing new; it lists the drive when it comes back.

### Simulator

`src/simulator/cart_files.zig`: volume 0 is a `SYCLBADGE` directory next to
the simulator binary (`zig-out/sim/SYCLBADGE/`), so a file a cart writes can
be copied to a badge. Same name rules, order and errors as the badge, and the
badge volume's limits (about 1.24 MB, 31 root entries); `exists` compares
long names only (no 8.3 names there). The open file is
`SYCLBADGE/.cart-file.part`, renamed on commit, deleted on abort. No volume 1,
never a USB host, no flash timing.

### Power cuts and shared erase blocks

The flash erases 4 KB blocks, the FAT works in 512-byte sectors, so a block
can hold FAT, directory and other files' sectors next to the ones being
written; the sector cache rewrites the whole block. A power cut between that
block's erase and its program (a ~50 ms window per block) loses its other
sectors too. That exposure is the same as for any write or delete through the
USB drive on this OS; the tests model each block write as atomic. Every other
cut leaves the drive as the rules above say.

## Gates

- `zig build test`: `src/os/tests/fat_write_test.zig` on RAM images of both
  geometries: create/write/commit (odd chunk sizes, an empty file, 1.5 MB on
  SYCLEXTRA), stat, exists (long, 8.3, case), `~1`/`~2`/`~3` aliases,
  bad names, wrong order and ranges, no_space, dir_full (and reuse after a
  delete), abort (byte-identical, or only free data changed), long names
  across a directory sector boundary, files deleted by `storage.deleteCart`,
  garbage after the end marker, and a power cut after every flash write on
  both volumes (file absent or complete, no cross-links, lost clusters and
  differing FATs only inside commit).
- `python3 src/os/tests/fat_images.py`: builds `zig build fat-images`, writes
  images (many files, long names, aliases, a delete, every power cut) and runs
  `fsck.fat -n` on each (clean, except "FATs differ" and reclaimed lost
  clusters for cuts inside commit), then lists each with mtools or pyfatfs and
  checks names, sizes and SHA-256 against the manifest (skipped, and said so,
  without either reader).
- Badge-only (`zig build -Dsimulator=false`) and full builds, `zig build
  test`, `python3 -m unittest discover -q tools/badge/tests`.
- Merge check: `main` is the branch's base (298deab), so a merge is a fast
  forward and the branch gates are the merge's.

## Flashing

`zig build` writes `zig-out/firmware/sycl-os-kernel.uf2` (the cart-saves name
`sycl-os-saves.uf2` is the same image). Hold BOOT_SEL, tap RESET, copy the UF2
to the RP2350 drive, or `badge flash zig-out/firmware/sycl-os-kernel.uf2` on a
badge already running fork firmware. Carts on the drives and saves are kept.
Keep the current fork OS UF2 to go back.

## Hardware test (F0)

The build installs `zig-out/carts/file-test.uf2`; copy it to SYCLBADGE.

1. Flash the OS as above. Unplug USB (or power from a charger), run
   file-test: "USB host: no", "v0 ...K free N ent", and a v1 line when
   SYCLEXTRA is mounted.
2. Pick "Small file vol 0": `file-test-1.txt`, "ok", ms for create, writes
   and commit. Then "100 KB file vol 0": note the ms and "ms per 4 KB". Same
   for vol 1 if present. Pick "Create + abort": "abort ok", "2nd abort: not
   open".
3. Exit the cart: the menu lists the new files. Plug into a laptop: the files
   are on the drives; `file-test-100k-1.txt` is 3200 lines
   `file-test 100k line NNNNNN ok.` in order. Run the host's disk check
   (`fsck.fat -n /dev/...` or Windows' scan): no errors.
4. With the laptop plugged in (drive mounted), run file-test: "USB HOST:
   unplug" in red, and a write shows "UNPLUG USB". Unplug: the next write
   works (the line turns green within a second).
5. Pull power during a 100 KB write once: after reboot the drive has either
   no new file or a complete one (step 3's checks), never a broken one.
6. On the organizers' OS or older fork firmware: "CART FILES UNSUPPORTED".

## Decisions taken by default (Adrian may change)

1. USB host attached: the OS refuses, the cart warns. (Alternative: warn and
   allow.)
2. Name taken: `create` reports `exists`; the cart picks `name-2.uf2`,
   `name-3.uf2`. (Alternative: replace.)
3. Branch only: not in `main`, not in `fork/sync-upstream.sh` FEATURES,
   until the badge check.
