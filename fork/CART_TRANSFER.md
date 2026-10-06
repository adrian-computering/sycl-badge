# Cart transfer (received-cart slot)

Badges pass carts to each other over the UART-header link cable. A
transfer cart (`carts/snouty-beam` in the snouty-badge monorepo) reads a
UF2 from the sending badge's drive and sends it. The receiving cart
writes it into the external flash's cart-writable area (see
[EXT_FLASH.md](EXT_FLASH.md)). This firmware lists that **slot** in the
menu and launches it like any other cart.

Branch `feature/cart-transfer`, based on `feature/ext-flash`, which it
needs: carts can only write the external chip through that feature, and
stock firmware lets a cart write no flash at all. Status: OS side built
and host-tested (`zig build test`), not yet run on a badge; the cart side
is `carts/snouty-beam` in the monorepo.

## Why a raw slot and not a file on SYCLEXTRA

The OS has no FAT write path, and a host that has the drive mounted
caches its FAT, so writing files behind its back is unsafe. Cart writes
to the 256 KB cart area already exist (mailbox `0x2B`). This feature only
adds reading the slot back in two places, the menu and the loader. The
slot holds the cart's **RAM image**, not the UF2: a UF2 is twice the
size of what it loads, so the image lets nearly every RAM cart fit.

## Slot format v1 (the contract between the cart and the OS)

All offsets are relative to the start of the cart area
(`0x11000000 + ext_flash_cart_offset_kb * 1024`). All fields are
little-endian.

| Area offset | Size | Contents |
|---|---|---|
| `0x0000` | 4 KB sector | header (below), the rest of the sector is erased (0xFF) |
| `0x1000` | `image_len` | the image: cart RAM bytes from `load_addr` up |

Header, 96 bytes at offset 0:

| Offset | Type | Field |
|---|---|---|
| 0 | u32 | `magic` = `0x4D414542` (`"BEAM"` in memory) |
| 4 | u16 | `version` = 1 |
| 6 | u16 | `header_size` = 96 |
| 8 | u32 | `load_addr`: cart RAM address of image byte 0 |
| 12 | u32 | `image_len`, at most cart-area size - 4096 |
| 16 | u32 | `image_crc32` (IEEE 802.3, zlib's `crc32`) over the image |
| 20 | u32 | `descriptor_offset`: offset in the image of the cart descriptor (the word `CART_MAGIC`), 4-aligned |
| 24 | u32 | `source_size`: size of the UF2 it came from (shown only) |
| 28 | u32 | `sender_id`: anything the sender wants to use to identify itself, 0 if none (shown only) |
| 32 | u8 | `name_len` (1-47) |
| 33 | [3]u8 | reserved, 0 |
| 36 | [48]u8 | `name`: printable ASCII, no extension, zero-padded |
| 84 | [8]u8 | reserved, 0 |
| 92 | u32 | `header_crc32` over bytes 0..92 |

**The image** is the flattened UF2. Every target must lie in cart RAM
(`[__process_ram_start__, __process_ram_end__]`). First, every block whose
whole target range lies below the **IPC block end** (`0x20020000 +
@sizeOf(CartIPCData)` = `0x20035100`) is dropped: these are the ELF and
program headers that the first `LOAD` segment of a monorepo RAM cart
carries (see "Decided" below), and the OS clears the IPC block at cart
start anyway. A block that straddles the IPC block end makes the UF2 not
transferable, as does any block in the XIP range. The kept payloads are
placed at `target_addr - load_addr`, gaps between payloads are zero, and
`load_addr` is the lowest kept target address. The descriptor is the
first `CART_MAGIC` word found the way the UF2 loader finds it: in block
order, within each kept block's payload, 4-aligned.

**Valid slot**: magic, version, header_size and header_crc32 all match;
`load_addr` and `load_addr + image_len` lie within
`[IPC block end, __process_ram_end__]`, so a slot never writes into the
IPC block (stricter than the UF2 loader's per-block rule, which starts at
`__process_ram_start__`); `image_len` fits the area; the descriptor lies
inside the image. The menu checks only this.
**Launchable** additionally requires that `image_crc32` matches and that
the descriptor passes the UF2 loader's v1 checks (magic, version, BSS and
entry bounds, thumb bit).

How this firmware reads those rules (`beam_slot.parseHeader`):

- `name_len` 1-47 and printable ASCII (0x20-0x7E) are part of "valid": the
  menu shows the name, so a slot with a bad name is not listed.
- "The descriptor lies inside the image" means the whole 20-byte v1
  descriptor: `descriptor_offset + 20 <= image_len`, and 4-aligned.
- The reserved bytes are not checked, so a later version can use them.
- `image_crc32` is checked over the copy in cart RAM, after copying and
  before anything reads the descriptor: it covers the bytes that will
  run, including any flash read glitch on the way.

**Write order** (the receiving cart, so a power cut never leaves a slot
that looks valid but isn't):

1. Erase the header sector first. From then on the slot is invalid.
2. For each 4 KB image sector: erase it, then program it.
3. Read the image back through `0x11000000` and check `image_crc32`.
4. Program the header (one 256-byte page).

## OS changes

- `os_flags` bit 5 = `cart_transfer`: this firmware lists and launches
  the slot. The OS sets it at cart start whenever bit 2 (`ext_flash`) is
  set, since the slot lives on the chip. A transfer cart offers Receive
  only when bits 2 and 5 are both set; the cart API's `cart_transfer()`
  checks both (false in the simulator).
- `src/os/loader/beam_slot.zig` (new): header parse and validation
  (`parseHeader`), image CRC, and the loader path. `loadInto(slot, mem)`
  copies the image to `load_addr`, checks the CRC over the copy, then
  checks the descriptor, clears BSS and returns the descriptor offset;
  `loadSlot()` runs it on the real chip and cart RAM and returns the same
  `CartExecute` as `loadUF2FromStorage` gives a RAM cart. The loading
  core takes the RAM bounds and the bytes backing them as a parameter, so
  host tests load into a buffer. The UF2 loader now calls the same
  `findDescriptor` and `checkDescriptorV1`, so both paths find and check
  the descriptor with one piece of code.
- `storage.listCarts` reports a valid slot (header checks only) after both
  volumes, with `visiting = .{ .volume = beam_slot.volume_id (0xBE),
  .start_cluster = 0, .size = image_len }`. `loadUF2CartInfo` dispatches
  that volume id to `beam_slot.loadSlot()`, which covers the menu
  (`loadUF2CartEntry`) and the name-based path.
- **Menu name**: `*` followed by the header's name, e.g. `*Snouty Pong`
  (with the cursor: `>*Snouty Pong`). The menu font is 8x8 ASCII, 20
  columns, one color per row, so a prefix is the mark that stays visible
  however long the name is. `*` can't occur in a FAT file name, so the
  row never matches a file on either drive.
- Every `listCarts` user sees the slot with no other change: the menu
  count/collect/draw (the `.UF2` stripping doesn't apply, the name has no
  extension) and the console's `cart list` and completions. The menu's
  change hash covers name and `image_len`: the slot appearing,
  disappearing (header erased, step 1 of the write order) or changing name
  or size redraws the menu; a new cart with the same name and size needs
  no redraw, as launching always reads the slot afresh.
- `findCart` finds the slot by its listed name (case-insensitive) after
  both drives, and `countCarts` counts it, so console `cart run`/`load`
  and the (disabled) single-cart autostart can launch it. `deleteCart`
  does not touch the slot (it only deletes drive files).
- Errors use the existing messages: a slot that is no longer valid at
  launch reads "Cart not found", an image CRC mismatch "Read error", a
  bad descriptor "Wrong address" or "Bad Cart Version".
- **XIP cache**: the menu and loader read the slot through the cached
  window at `0x11000000`. That is safe: every cart erase/program
  (`EXT_FLASH_REQ`, `ext_flash.eraseRaw`/`programRaw`) ends with the
  bootrom's `flash_flush_cache`, which invalidates the whole XIP cache
  (shared by both windows and both cores), so neither the cart's
  read-back nor the OS sees stale lines.
- Bounds: the image may cover `[IPC block end, __process_ram_end__)`
  (0x20035100-0x20080000). The OS takes the IPC block end from the real
  `ipc_data` address plus `@sizeOf(CartIPCData)`, not a constant. The
  descriptor checks (BSS, entry point) keep the UF2 loader's bounds,
  `[__process_ram_start__, __process_ram_end__)`. Above the IPC block,
  process RAM holds nothing the OS uses while loading a RAM cart (the UF2
  loader's flash buffer there is only used for XIP carts).
- No new IPC words or mailbox messages.

### Cart ABI

| Where | Field | Meaning |
|---|---|---|
| `os_flags` bit 5 | `cart_transfer` | this OS lists and launches the received-cart slot (set only with bit 2) |

Row for `fork/ABI.md` (on fork main) when this branch is merged:
`| 5 | cart_transfer | fork feature/cart-transfer ([CART_TRANSFER.md](CART_TRANSFER.md)) |`,
with the free range becoming `6-15`.

## Tests

- Host tests (`zig build test`, `src/os/tests/beam_slot_test.zig`):
  golden header bytes built from the table above, every validity rule
  (each field broken in turn), a CRC mismatch is refused at launch, the
  v1 descriptor checks, a slot whose image starts inside the IPC block
  is refused and writes nothing, and slot-vs-UF2 loads compared byte for
  byte in a RAM buffer over `[IPC block end, process RAM end)` (the UF2
  side runs the loader's RAM-cart path: same parser, bounds, descriptor
  search and checks; below the IPC end it also writes the dropped
  header blocks, and the slot side must have written nothing there).
  Cases: a synthetic cart with a dropped header block and a gap (plus a
  straddling block refused by the flattener); `src/os/tests/fixtures/snouty-pong.uf2` flattened by the test's
  own copy of the flattening rule; and, when present,
  `src/os/tests/fixtures/beam_slot_pong.bin` (header sector + image, as
  the monorepo's flattener writes it from that same `snouty-pong.uf2`):
  its header must match the test's flattening and it must load like the
  UF2. Without the `.bin` that test is skipped. Replace both fixtures
  together: the `.bin` must come from the committed `.uf2`.
- Build: `zig build -Dsimulator=false`, and the full build including the
  simulator.

## Decided: ELF headers in RAM cart UF2s are dropped

Carts built by the monorepo (checked: `snouty-pong.uf2`) carry two UF2
blocks at `0x20030000` holding the ELF and program headers (the first
`LOAD` segment includes them), inside the IPC block (`0x20020000` up to
`0x20035100`). The UF2 loader copies them there and the OS clears the IPC
block at cart start, so they never reach a running cart. Kept in the
image, they would set `load_addr = 0x20030000` and pad every image with a
~20 KB zero gap (pong: 44544 bytes instead of 23808), cutting the largest
transferable cart from 252 KB to about 232 KB.

Decision (format still v1, nothing had shipped): the flattener drops every
block wholly below the IPC block end, a straddling block makes the UF2 not
transferable, and the OS refuses a slot whose `load_addr` is below the
IPC block end (see "The image" and "Valid slot" above).

## Hardware check

See the monorepo `carts/snouty-beam/PLAN.md` (two badges on fork firmware
with this feature, the cable, Snouty Beam on both).
