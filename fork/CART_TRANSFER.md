# Cart transfer (received-cart slot)

Badges pass carts to each other over the UART-header link cable. A
transfer cart (`carts/snouty-beam` in the snouty-badge monorepo) reads a
UF2 from the sending badge's drive and sends it. The receiving cart
writes it into the external flash's cart-writable area (see
[EXT_FLASH.md](EXT_FLASH.md)). This firmware lists that **slot** in the
menu and launches it like any other cart.

Branch `feature/cart-transfer`, based on `feature/ext-flash`, which it
needs: carts can only write the external chip through that feature, and
stock firmware lets a cart write no flash at all. Status: plan.

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

**The image** is the flattened UF2. UF2 payloads are placed at
`target_addr - load_addr`, gaps between payloads are zero, and
`load_addr` is the lowest target address. Every target must lie in cart
RAM. A UF2 with any block in the XIP range is not transferable. The
descriptor is the first `CART_MAGIC` word found the way the UF2 loader
finds it: in block order, within each block's payload, 4-aligned.

**Valid slot**: magic, version, header_size and header_crc32 all match;
`load_addr` and `load_addr + image_len` lie within
`[__process_ram_start__, __process_ram_end__]`, the same rule the UF2
loader applies to each block; `image_len` fits the area; the descriptor
lies inside the image. The menu checks only this.
**Launchable** additionally requires that `image_crc32` matches and that
the descriptor passes the UF2 loader's v1 checks (magic, version, BSS and
entry bounds, thumb bit).

**Write order** (the receiving cart, so a power cut never leaves a slot
that looks valid but isn't):

1. Erase the header sector first. From then on the slot is invalid.
2. For each 4 KB image sector: erase it, then program it.
3. Read the image back through `0x11000000` and check `image_crc32`.
4. Program the header (one 256-byte page).

## OS changes

- `os_flags` bit 5 = `cart_transfer`: this firmware lists and launches
  the slot (ABI.md row). A transfer cart offers Receive only when bits 2
  (`ext_flash`) and 5 are both set.
- `src/os/loader/beam_slot.zig` (new): header parse and validation,
  image CRC, and the loader path `loadSlot()`. It copies the image to
  `load_addr`, then validates the descriptor, clears BSS and returns the
  entry exactly like `loadUF2FromStorage`. The parse/validate code is
  plain functions over a byte slice, so host tests cover it.
- `storage.listCarts` reports the slot after both volumes, with
  `visiting = .{ .volume = beam_slot.volume_id, ... }`. Its name is
  the header's name with a mark that says it was received (the exact mark
  depends on what the menu can draw). `loadUF2CartEntry` dispatches on
  that volume id. Every `listCarts` user (menu, cart hash, console `ls`)
  sees the slot with no other change.
- No new IPC words or mailbox messages.

## Tests

- Host tests (`zig build test`): golden header bytes, every validity rule
  (each field broken in turn), a CRC mismatch is refused at launch, and a
  fixture slot made by the monorepo's flattener from a real cart UF2
  loads into a RAM buffer byte-identical to what the UF2 path produces.
- Build: `zig build -Dsimulator=false`, and the full build including the
  simulator.

## Hardware check

See the monorepo `carts/snouty-beam/PLAN.md` (two badges on fork firmware
with this feature, the cable, Snouty Beam on both).
