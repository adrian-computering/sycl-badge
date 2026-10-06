# Cart files (carts write new files to the USB drives)

A cart can create a file on the badge's USB drives (SYCLBADGE, and SYCLEXTRA
when the external chip is present). The first user is Snouty Beam
(`carts/snouty-beam` in the snouty-badge monorepo): a received cart is saved
as an ordinary `.uf2` on the drive, so it shows in the menu like any other
cart, survives anything the slot would not, can be copied back to a laptop,
and is not limited to 252 KB or to RAM carts.

Branch `feature/cart-files`, based on fork `main` 298deab (it needs
ext-flash's volume table and cart-saves' `flash_ops.zig`). Status: plan.
Not merged into `main` until a badge check passes.

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

## OS design

- `src/os/loader/fat_write.zig` (new): free-cluster scan, reservation,
  sequential data writes, commit, 8.3 name generation and LFN entries, on top
  of `storage.readSector/writeSector/flushPendingWrites`. Pure logic over a
  sector interface so host tests run it on a RAM image.
- `src/os/system/cart_files.zig` (new): request validation, one step per
  kernel main-loop pass (as `saves.zig`), reset on cart start/stop.
- USB: track "configured by a host" (SET_CONFIGURATION seen since the last
  bus reset / disconnect) in the USB driver, read by `cart_files`.
- Simulator: a backend that writes the file into the simulator's cart
  directory, so carts can be tried there.
- Menu: nothing new; the menu lists the drive when it comes back.

## Gates

- Host tests on RAM volume images of both geometries: create/write/commit,
  exists, no_space, dir_full, names (LFN across sectors, 8.3 collisions),
  abort, and a power cut after every flash write: the image passes
  `fsck.fat -n` (lost clusters allowed only for cuts inside commit) and the
  file is either absent or complete.
- `fsck.fat -n` and `mdir`-style listing of an image after writing files
  with long names.
- Badge-only and full builds, `zig build test`, Python tool tests.
- Merge check: a throwaway merge into `main` builds and tests green.

## Decisions taken by default (Adrian may change)

1. USB host attached: the OS refuses, the cart warns. (Alternative: warn and
   allow.)
2. Name taken: `create` reports `exists`; the cart picks `name-2.uf2`,
   `name-3.uf2`. (Alternative: replace.)
3. Branch only: not in `main`, not in `fork/sync-upstream.sh` FEATURES,
   until the badge check.
