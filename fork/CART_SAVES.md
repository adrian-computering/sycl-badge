# Cart saves

Carts can store small named blobs (high scores, progress, emulator battery RAM) that
survive cart switches, power-off and OS updates. They live in the badge's internal
flash, in the 256 KB that used to be the XIP cart window (0x101C0000..0x10200000),
invisible to the USB drive. On stock firmware the calls report "unsupported", so a cart
can fall back to "no saves". The full design is in [CART_SAVES_PLAN.md](CART_SAVES_PLAN.md).

XIP (execute-from-flash) carts are gone with this: the loader refuses a UF2 with
blocks for flash addresses ("XIP not supported" in the menu). RAM carts, which is what
`add_cart` builds, are unaffected.

## For cart authors (cart-api)

```zig
const cart = @import("cart-api");

if (cart.save_supported()) {                 // probes once per boot (<= 250 ms on stock firmware)
    var buf: [256]u8 = undefined;
    const n = cart.save_read("mygame/slot1", &buf) catch |e| switch (e) {
        error.NotFound => 0,                  // first run
        else => return,
    };
    // ... use buf[0..@min(n, buf.len)] (n is the stored size, may exceed buf.len)
    try cart.save_write("mygame/slot1", progress_bytes);
}
```

| Function | Does |
| --- | --- |
| `save_supported() bool` | the OS has cart saves (cached per boot) |
| `save_read(key, dst) SaveError!usize` | copies up to `dst.len` bytes, returns the stored size |
| `save_write(key, src) SaveError!void` | stores 1..65536 bytes atomically (old or new after a power cut) |
| `save_delete(key) SaveError!void` | removes the key (`NotFound` if absent) |
| `save_stat() SaveError!SaveStat` | `free_bytes` for a new key, `entries`/`max_entries`, `writes_left_now` |
| `save_list(out) SaveError!usize` | fills `out` with `SaveListEntry` rows, returns how many |
| `save_watch_exit() SaveError!void` | ask to be told when the player picks "Exit Cart" |
| `exit_requested() bool` | check once a frame after `save_watch_exit()` |
| `exit_ready() void` | done saving: the OS may stop the cart now |

Rules and limits:
- Keys: 1..32 bytes of printable ASCII (0x20..0x7E). Prefix them with your cart's name.
- Blob: up to 64 KB. Store: 184 KB usable for blobs, up to 46 keys, each key takes whole
  4 KB blocks (a 1-byte blob uses 4 KB). 16 blocks are always kept free so an overwrite
  of an existing key never fails with `NoSpace`.
- A write or delete blocks the cart (datasheet estimate: ~0.1 s for 1 KB, ~0.5 s for
  32 KB, to be measured). The cart's streaming audio pauses meanwhile. A write of the
  bytes already stored returns at once without touching flash.
- Rate limit: 8 writes/deletes in a burst, then 1 per 10 s (`RateLimited`). Save on
  events (level end, pause menu, exit request), never every frame.
- Exit hook: after `save_watch_exit()`, Start+Select -> Exit Cart sets
  `exit_requested()`, shows "Saving..." and keeps the cart running (input is not
  delivered) until it calls `exit_ready()`, or 3 s pass.
- The simulator has saves too: the same store over `saves.bin` next to the simulator
  binary (instant, no flash timing). It has no Exit Cart menu, so `exit_requested()`
  stays false there.

## ABI v1 (for code that doesn't use cart-api)

Types are in `src/os/cart/os_abi.zig` (`SaveRequest`, `SaveOp`, `SaveState`,
`SaveStatus`, `SaveStat`, `SaveListEntry`, `CART_SAVE_REQ`). One mailbox message,
cart -> OS: `(0x2C << 24) | ((request_addr - 0x20000000) >> 2)`. The OS answers only
through the 64-byte request struct, never the FIFO.

1. Fill a `SaveRequest` in cart RAM (0x20035100..0x20080000, 4-byte aligned),
   `state = pending`, `dmb`, send the message.
2. Spin until `state == done` (read with `dmb`) from RAM code that touches no XIP
   address; drain FIFO replies meanwhile. For `write` and `delete`, mask interrupts
   (PRIMASK) before sending: core 0 turns XIP off while it erases.
3. Read `status` and `result`.
   - `probe`: result = 1. On stock firmware nothing answers: give up after 250 ms of
     `pending`. A request still `pending` after a timeout should get `magic = 0`
     (the OS ignores a request with magic 0); once `busy`, wait for `done`.
   - `read`: result = stored size. `stat`: result = free bytes; with `buf`, the OS
     copies `min(len, 32)` bytes of `SaveStat`. `list`: result = rows written
     (`len / 40` max). `exit_watch`: `buf` = address of a u32 exit word, 0 to
     unregister; the OS writes 1 to request an exit, the cart writes 2 when ready.
   - A second request while a write/delete is in flight gets `busy` at once.

## Flashing the OS

`zig build` writes `zig-out/firmware/sycl-os-saves.uf2` (same image as
`sycl-os-kernel.uf2`). Hold BOOT_SEL, tap RESET, copy the UF2 to the RP2350 drive.
Only the OS region is rewritten: carts on the USB drive and saves are kept (the save
region is not in the UF2). Keep the organizers' OS UF2 to go back. The stock OS ignores
the save region, except that loading an XIP cart there erases it.

## Hardware test (S0)

Build installs `zig-out/carts/save-test.uf2`; copy it to the badge drive.

1. Flash `sycl-os-saves.uf2` as above.
2. Run save-test: "Boot #1". Power off, on, run again: "Boot #2".
3. Pick "Write 32 KB": note the ms on screen (also try 1 KB and 64 KB). "Verify blobs"
   shows ok for each written blob. Pull power during a write once: after reboot the
   boot counter and "Verify blobs" still show the previous data intact.
4. Start+Select -> Exit Cart: "Saving..." flashes in the settings box, the menu comes
   back. Run save-test again: "Last exit: saved".
5. On the organizers' OS, save-test shows "SAVES UNSUPPORTED".

## Implementation map

- `src/os/system/save_store.zig`: the store (format, copy-on-write, rate limit),
  host-tested with power cuts in `save_store_test.zig`.
- `src/os/system/saves.zig`: request validation, one store step per kernel main-loop
  pass, audio pause, exit hook, reset on cart start/stop.
- `src/os/drivers/flash_ops.zig`: RAM-resident erase/program in a critical section
  with XIP off; restores QMI window 0 (TIMING/RFMT/RCMD) after the bootrom's
  `flash_enter_cmd_xip`, which would otherwise leave the OS running from flash in slow
  03h mode. storage.zig (the USB drive) uses it too. Flash reads go through the cached
  XIP window; every erase/program ends with the bootrom's cache flush.
- `src/simulator/saves.zig`: the simulator backend.
- `carts/save-test`: the test cart.
