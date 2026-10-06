# Cart ABI allocations

Upstream's IPC block (`src/os/cart/os_abi.zig`, `CartIPCData` at
`0x20020000`, 0x15100 bytes) is fixed in size: carts link against it, so it
cannot grow. Upstream left 3 spare words and 15 spare `os_flags` bits. This
file says who owns each piece the fork or a sibling OS branch has taken, so two
patches never claim the same bytes. Check it before touching `os_abi.zig`, and
add a row in the same commit.

## `os_flags` (u16 at `0x200350EA`)

| Bit | Name | Owner |
|---|---|---|
| 0 | `os_clear_supported` | upstream |
| 1 | `cart_serial_supported` | fork `feature/cart-serial` ([CART_SERIAL.md](CART_SERIAL.md)) |
| 2 | `ext_flash` | fork `feature/ext-flash` ([EXT_FLASH.md](EXT_FLASH.md)), e2.3 and later |
| 3-4 | `ext_volume` (0 none, 1 kept, 2 formatted, 3 unstable) | fork `feature/ext-flash` |
| 5 | `cart_transfer` | fork `feature/cart-transfer` ([CART_TRANSFER.md](CART_TRANSFER.md)) |
| 6 | `cart_files` | fork `feature/cart-files` ([CART_FILES.md](CART_FILES.md)) |
| 7-15 | free | |

## Spare words (upstream `_reserved: [3]u32`)

| Address | Contents | Owner |
|---|---|---|
| `0x200350F4` | `cart_serial`: `*CartSerialRings` in cart RAM, written by the cart, zeroed by the OS at cart start | fork `feature/cart-serial` |
| `0x200350F8` | low u16 = ext flash size in KB, high u16 = start of the cart-writable area in KB | fork `feature/ext-flash` |
| `0x200350FC` | `ext_flash_diag`, boot detection result (0 = no ext-flash support) | fork `feature/ext-flash` |

No words are left. A new feature talks to the OS through a mailbox message
instead, the way cart saves do, and gets its row below.

## Mailbox message types (`ipc_data` mailbox, cart -> OS)

| Type | Name | Owner |
|---|---|---|
| `0x25`, `0x26`, `0x29`, `0x2A` | framebuffer, trace, audio, time | upstream |
| `0x2B` | `EXT_FLASH_REQ` / `EXT_FLASH_DONE` | fork `feature/ext-flash` |
| `0x2C` | `CART_SAVE_REQ` | fork `feature/cart-saves` ([CART_SAVES.md](CART_SAVES.md)) |
| `0x2D` | `CART_FILE_REQ` | fork `feature/cart-files` ([CART_FILES.md](CART_FILES.md)) |

## Rules

- Take only free space from these tables. Never reuse a bit or word another
  owner has, even if that firmware isn't merged into the fork. Badges in the
  wild may run it, and a cart built for one firmware must not misread another.
- Every fork bit has to read 0 on stock firmware, and the cart side has to
  degrade when it is 0.
- A cart-written word must be one the OS clears at cart start, so the cart can
  tell this firmware from another that sets the same flag
  (`serial_supported()` checks this).
- If upstream starts using a word or bit listed here, the fork moves to a
  mailbox query in the next sync, and the table records the move.

## History

- 2026-10-05: ext-flash e2.2 and earlier used bit 1 and all three words,
  colliding with cart serial. Adrian chose this layout: ext-flash moved in
  e2.3. Cart serial checks that `0x200350F4` is 0 before opening, so
  multiplayer carts treat e2.2 as stock firmware rather than writing over its
  flash size.
