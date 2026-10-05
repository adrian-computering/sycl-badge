# Cart saves: plan

Branch `cart-saves` of /home/exedev/sycl-badge, off upstream main 5955625. Local only,
not for upstream. Cart-side work lives on a branch of the snouty-badge monorepo and is
NOT merged to its main while it needs this OS (Adrian, 2026-10-05).

Goal: carts store small blobs (emulator battery RAM, game progress, high scores) that
survive cart switches, power-off and OS updates, on badges running this OS, and degrade
to "no saves" on stock firmware.

## Decisions (Adrian, 2026-10-05)

- Saves live in internal flash, in the 256 KB that was the `cart_xip` window
  (0x101C0000..0x10200000). The external CS1 chip (branch `ext-flash`) can become a
  second backend later behind the same ABI.
- The loader refuses UF2s with XIP blocks (XIP is dead on this badge). Nothing may erase
  the save region except the save store.
- Not sent upstream.
- First users: test cart, Snouty Boy battery RAM, Paperclips, Snouty GCP career mode.

## Why not files on the USB drive

A host that has the drive mounted keeps its own copy of the FAT, so the badge writing
the FS behind its back corrupts it. The root dir holds 32 entries, the drive is full,
and an in-place rewrite loses the file if power goes mid-erase. The save region is
invisible to USB, so none of that applies.

## ABI v1 (frozen; cart and OS sides build against this)

No CartIPCData fields and no `os_flags` bits are used (both are contested by the
ext-flash branch and the cart-serial fork). One mailbox message type:

```
CART_SAVE_REQ: u8 = 0x2C   // cart -> OS, payload = (request address - 0x20000000) / 4
```

(0x2B is ext-flash's EXT_FLASH_REQ.) The OS replies through the request struct only, never
through the FIFO, so it can't confuse a cart waiting on other FIFO replies.

```zig
pub const SaveRequest = extern struct {        // in cart RAM, 4-byte aligned, 64 bytes
    magic: u32 = 0x31564153,                   // "SAV1"
    op: SaveOp,                                // u32
    state: SaveState,                          // u32, see protocol
    status: SaveStatus,                        // u32, written by the OS
    key_len: u32,                              // 1..32
    key: [32]u8,                               // bytes 0x20..0x7E, no '/' rule enforced
    buf: u32,                                  // address in cart RAM (0x20020000..0x20080000)
    len: u32,                                  // bytes at buf
    result: u32,                               // written by the OS, per op
};
pub const SaveOp = enum(u32) {
    probe = 1,      // result = ABI version (1); len/buf unused
    read = 2,       // copy up to len bytes of key into buf; result = stored size
    write = 3,      // store len bytes from buf as key, atomically (0 < len <= max_blob)
    delete = 4,     // remove key (not_found if absent)
    stat = 5,       // result = free bytes for a new blob; buf/len optional: SaveStat
    list = 6,       // fill buf with up to len/40 SaveListEntry; result = entry count
    exit_watch = 7, // buf = address of a u32 exit word in cart RAM (0 = unregister)
    _,
};
pub const SaveState = enum(u32) { idle = 0, pending = 1, busy = 2, done = 3, _ };
pub const SaveStatus = enum(u32) {
    ok = 0, not_found = 1, no_space = 2, bad_request = 3, bad_buffer = 4,
    rate_limited = 5, too_big = 6, io_error = 7, busy = 8, _,
};
pub const SaveStat = extern struct { version: u32, region_bytes: u32, free_bytes: u32,
    max_blob: u32, entries: u32, max_entries: u32, writes_left_now: u32, _r: u32 };
pub const SaveListEntry = extern struct { key_len: u32, key: [32]u8, size: u32 };
```

Protocol (cart side):
1. Fill the struct, `state = pending`, `dmb`, send `(0x2C << 24) | ((addr - 0x20000000) >> 2)`.
2. Wait until `state == done` (read with `dmb`), in a loop that runs from RAM and touches
   no XIP address (no drive ROM reads, no flash-resident handlers). For `write` and
   `delete`, mask core 1 interrupts (PRIMASK) while waiting. Core 0 switches XIP off
   while it erases.
3. `probe` on stock firmware never completes: the cart gives up after 250 ms of no state
   change and treats saves as unsupported (cache the answer per boot). A
   probe that reaches `busy` but not `done` keeps waiting.

OS side:
- Validates magic, op, key_len, the struct and `buf..buf+len` within process RAM
  (0x20020000..0x20080000, past the IPC block), else `bad_request` / `bad_buffer`.
- Sets `state = busy`, works, writes `status`/`result`, `dmb`, then `state = done`.
- Requests are served one at a time; a second request while one is in progress is
  answered `busy` at once.
- On cart start and stop the OS forgets any exit word and in-flight request.

Exit hook: if a cart registered an exit word, the settings "Exit cart" entry writes 1
to it, shows "Saving..." and keeps the main loop running (requests still served) until
the cart writes 2, or 3 s pass, then stops the cart as today. Carts check the word once
a frame.

## Store format (internal flash, 0x101C0000, 64 x 4 KB blocks)

- Blocks 0 and 1: directory copies A and B. Blocks 2..63: data (62 x 4 KB = 248 KB).
- Directory block = header (64 B) + 63 entries (64 B each):
  - header: magic "SVD1", seq u32 (newest valid wins), next_fit u8 (allocation
    cursor), entry count, CRC32 of the whole block with the CRC field zeroed.
  - entry: key_len u8, key [32]u8, nblocks u8, size u32, crc32 u32 (of the blob),
    blocks [16]u8 (data block indices), flags/pad to 64 B.
- Limits: max blob 64 KB (16 blocks), max 63 keys, key 1..32 bytes.
- Write = copy-on-write: allocate free blocks (not referenced by the live directory)
  next-fit from `next_fit` (spreads wear), erase + program + verify each, then
  write the directory with seq+1 to the OTHER directory block (erase + program + verify).
  Power loss at any point leaves the previous directory, and so the previous blob,
  intact. Delete = directory write only.
- A write whose bytes equal the stored blob returns ok without touching flash.
- Free-space rule: a write needs ceil(len/4096) free blocks while the old copy still
  exists; else `no_space`.
- Rate limit: token bucket, 8 commits burst, 1 token per 10 s; empty -> `rate_limited`
  (no flash touched). Protects the directory blocks from a cart saving every frame.
- Boot: read both directory blocks, keep the valid one with the higher seq. If neither is
  valid (fresh badge, region still holds an old XIP cart or 0xFF), the store formats
  itself (write directory A with seq 1, erase B) the first time a write arrives, not at
  boot, so an OS update never erases anything a user didn't ask to save.
- Corrupt blob (CRC mismatch on read) -> `io_error`, entry kept so the cart can rewrite.

## Flash operation rules (OS)

- Core 0 does one flash step (one 4 KB erase + its 16 page programs, or one verify)
  per main-loop pass, each inside a critical section with XIP off, from `.ram_text`
  code, so USB and audio keep being polled between steps.
- Audio is muted (stop_buffered) for the whole request and restarted after; the
  cart is parked anyway.
- After every bootrom flash call, restore QMI window 0's TIMING/RFMT/RCMD to the values
  saved before it: the bootrom's `flash_enter_cmd_xip` leaves the OS's own flash in 03h
  serial at clkdiv 12 until reboot (found on the ext-flash branch). The same helper wraps
  storage.zig's writes (one small upstream-file edit).
- Expected cost (datasheet typical, to measure on hardware): ~45 ms erase + ~10 ms
  program per 4 KB. 1 KB save ~0.1 s (blob + directory), 32 KB ~0.5 s.

## Layout of the work

Firmware (this repo, branch cart-saves):
- `src/os/system/save_store.zig`: pure store logic over a `Flash` interface
  (`read(off, dst)`, `erase4k(off)`, `program(off, src)`), resumable as a step
  machine (`begin(op…)`, `step() -> .more|.done`). No hardware imports. Host tests in
  `src/os/system/save_store_test.zig` against a simulated NOR (erase sets 0xFF, program
  only clears bits) with a power cut injected at every flash call: after a cut and a
  reboot the store must show either the old or the new blob, never anything else.
- `src/os/system/saves.zig`: OS glue (request validation, kernel main-loop step, audio
  mute, QMI restore, exit hook state).
- `src/os/drivers/flash_ops.zig` (or inside saves.zig): the RAM-resident erase/program
  wrappers with the QMI window 0 restore.
- linker.ld: `cart_xip` region renamed `saves` (same address/length), symbols
  `__saves_region_start__/__saves_region_end__`; loader refuses XIP blocks
  (`LoadError.XipUnsupported`, menu text "XIP not supported").
- kernel.zig: `0x2C` in handle_cart_message, `saves.poll()` in the main loop,
  settings exit hook; cart start/stop reset.
- SDK (api.zig + platform_badge.zig + platform_simulator.zig): `save_supported()`,
  `save_read`, `save_write`, `save_delete`, `save_stat`, `save_list`,
  `save_watch_exit` / `exit_requested()` / `exit_ready()`. The simulator backs the
  store with a file next to the binary through the same save_store.zig.
- `carts/save-test`: boot counter that survives power-off, write 1 KB / 32 KB / 64 KB
  with timings on screen, list keys, delete, stat, exit-hook demo.

Monorepo (snouty-badge, branch `saves/m1`, never merged to main until Adrian says):
- `lib/save.zig`: ABI v1 client written against the raw mailbox (carts are pinned to
  the old SDK), with the 250 ms probe, a host fake, and doc comments. Wasm/simulator:
  unsupported.
- badge-bench: serves `0x2C` from a file-backed store using save_store.zig's logic
  (copied file, kept identical) and charges the modeled flash time to the frame.
- Snouty Boy: battery RAM (MBC1/2/3/5) keyed `boy/<header title>/<global checksum>`.
  Flush on menu open, on exit request, and 1 s after the game stops writing SRAM (at
  most once per 30 s); load at ROM start; import `<rom>.sav` from the drive once if no
  internal save. RTC not persisted.
- Paperclips: save/continue (key `paperclips/game`), autosave every 60 s and on exit.
- Snouty GCP career mode: after the GC session's career work lands; key `gcp/career`.

## Milestones

- S0 firmware: store + host tests (Track A), OS glue + loader + SDK + test cart (Track B).
  Gate: host tests (incl. power-cut sweep) green, OS builds, save-test runs in the
  simulator, badge flash by Adrian.
- S1 monorepo: lib/save.zig + badge-bench (Track C). Gate: bench run of a test cart.
- S2 Snouty Boy battery saves (Track D, after C's interface commit).
- S3 Paperclips, then GCP career.
- Later: CS1 backend, console `save` commands (needs the fork's USB console),
  export/import of saves via the drive, Tufty OS implementation of the same ABI.

## Hardware test (S0)

1. Flash `sycl-os-saves.uf2` (BOOT_SEL + RESET, copy to the RP2350 drive). Keep the
   organizers' OS UF2 to go back. Only the OS region is rewritten.
2. Run save-test: boot counter starts at 1. Power off, on, run again: 2.
3. Write 32 KB: note the time on screen. Pull power mid-write once: after reboot the
   counter and the previous blob are intact.
4. Start+Select -> Exit cart: save-test shows "saved on exit" next boot.

## Merging with ext-flash (agreed with the ext-flash session, 2026-10-05)

No ABI clash: saves use msg 0x2C and no IPC fields; ext-flash uses 0x2B, os_flags bits
2-4 and 0x200350F8/FC (cart serial keeps bit 1 + 0x200350F4). On merge:

1. `flash_ops.runRaw` saves and restores QMI window 1 too (M1_TIMING/RFMT/RCMD at
   0x400D0020/24/28), the same way as window 0. With CS1 in FLASH_DEVINFO the bootrom's
   `flash_enter_cmd_xip` resets both windows. Window 1 uses 0Bh serial reads (no
   continuous mode), so a register restore is enough; no re-entry read.
2. The window 0 quad restore is skipped while CS1 is mapped and the external chip's QE
   bit is not set (ext_flash QeStatus): with QE clear, SD2/SD3 are that chip's
   WP#/HOLD# and quad traffic garbles it. The ext-flash side owns this condition.
3. Every flash write goes through flash_ops: storage.zig (per-Volume flushPending,
   eraseBlock, wipeVolume) and ext_flash.zig's eraseRaw/programRaw. CS1 offsets are
   0x01000000 + n (the bootrom picks CS1 from bit 24). flash_ops only checks alignment
   and SRAM source; it must never assert offsets into the internal 4 MB.
   `ext_flash.checkRange` stays the CS1 guard.
4. Convention for both: a cart waiting on a flash write or erase parks in RAM with
   PRIMASK set.
5. Expected textual conflicts, all mechanical: loader.zig (XIP removal vs
   loadUF2CartEntry), the kernel.zig main loop (both poll one flash step per pass),
   console.zig, storage.zig.
6. Open, for Adrian, after saves ship: whether ext-flash's 256 KB raw cart area at the
   chip's end becomes a second save-store backend or stays raw scratch.
