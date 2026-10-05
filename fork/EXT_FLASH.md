# External flash: the badge's second 2 MB chip

The SYCL badge v2 board carries a second flash chip, U8 (GigaDevice
GD25Q16E, 16 Mbit = 2 MB QSPI NOR), next to the RP2354B's in-package flash.
Upstream firmware never enables it. This feature makes the OS use it:

- a second USB drive, **SYCLEXTRA** (1792 KB, FAT12), beside the usual one;
  carts copied there show in the menu and run, other files (ROMs, data) are
  readable by carts;
- carts can read the whole chip as memory at `0x11000000`, and write the last
  256 KB of it through the OS (save data, caches);
- with no chip, or on stock firmware, nothing changes: carts see the feature
  as absent.

Branch `feature/ext-flash`, based on upstream `main`. Status: hardware-tested
on one badge (detection, the drive, carts run from SYCLEXTRA, files survive
power cycles); the cart write API and the e2.3 ABI layout below await their
badge check.

## For badge users

Flash the firmware as usual. The first boot formats SYCLEXTRA (once); the
main drive is not touched, so its carts survive. Copy `.uf2` carts to either
drive. Going back to upstream firmware hides SYCLEXTRA but leaves its files
on the chip.

`carts/extflash-probe` is a diagnostic cart. Page 1 talks to the chip
directly, so it works on stock firmware too (CHIP ALIVE, SFDP 2048 KB, ID
C8 14). Page 3 shows what the OS found at boot and runs a write self-test on
the cart area (A), restoring what it overwrote.

## Hardware facts

Read from the v2 schematic and production netlist (`kicad/v2`):

- U8 shares QSPI_SCK and SD0..SD3 with the in-package flash. Its chip select,
  net `QSPI_CS`, goes to RP2354B pin 77 = **GPIO0**, which the RP2350 can
  drive as `XIP_CS1n` (function 9), with a pull-up (R37). Nothing else in the
  OS uses GPIO0.
- With GPIO0 on XIP_CS1n, QMI window 1 maps the chip at `0x11000000` (cached)
  and `0x15000000` (uncached). ATRANS4 resets to an identity map.
- GD25Q16E: 03h/0Bh/5Ah/90h serial reads work without setup. Its QE bit
  (status register 2, bit 1, non-volatile) ships clear.

## What the OS does

**Detection** (`src/os/drivers/ext_flash.zig`, at boot, before the storage
check): route GPIO0, point window 1 at the chip with the SFDP read (5Ah) and
check the "SFDP" signature and the JEDEC density; retry up to 10 times. If
the chip doesn't answer, GPIO0 and window 1 are put back.

**Bootrom support.** The RP2350 bootrom keeps a copy of OTP `FLASH_DEVINFO`
in boot RAM (data lookup `'F','D'`). Declaring CS1 there (size code and
GPIO) makes the bootrom handle the chip with no other code:
`connect_internal_flash` routes GPIO0, `flash_exit_xip` exits both chips,
and `flash_range_erase`/`flash_range_program` pick the chip from bit 24 of
the offset (`0x01000000 + n` = byte n of CS1). Those two do not bounds-check
(only `flash_op` does), so the OS's own range checks are the only guard.

**QE bit: required with a quad-mode OS.** With QE clear, SD2/SD3 are the
chip's WP#/HOLD# inputs. The in-package flash drives those lines during its
quad XIP reads, so CS1 reads come back garbled until the OS's window 0 drops
to serial reads (any bootrom flash write does that, see below). On a badge
this made the drive look unformatted at every power-on. The OS therefore sets
QE once, at boot, in QMI direct mode from RAM: `31h` (write status register
2), falling back to `01h` with two bytes, and only when both status
registers read the factory all-zeros (they also hold one-time lock bits).
Later boots check QE through window 1 (35h) and skip direct mode.

**Read mode.** Window 1 runs 0Bh fast read (8 dummy clocks) at clkdiv 3
(50 MHz at 150 MHz). `flash_enter_cmd_xip` resets both windows to 03h at
clkdiv 12, so the OS re-applies it after every flash write. Quad reads are
possible now that QE is set; not done yet.

**Never reformat on a bad read.** If SYCLEXTRA's boot sector fails the
check, the OS reformats only when two uncached passes over it agree;
otherwise the drive is left out for that boot.

**Upstream finding, independent of this chip.** After any OS flash write
(storage, settings), the bootrom's `flash_enter_cmd_xip` leaves window 0, the
OS's own code, in 03h serial reads at clkdiv 12 (12.5 MHz) until the next
reboot. The cart-saves feature restores window 0 after its writes.

## USB

The MSC interface gets a second LUN: `GET_MAX_LUN` answers 1 when the chip
is present, and SCSI commands carry their LUN (`storage.volume(lun)`). INQUIRY
names the LUNs "BadgeCarts" and "BadgeExtra". Without the chip, max LUN is 0
as before. The menu lists every file on both drives and remembers each row's
drive and first cluster, so the same name on both drives launches the right
file.

## Cart ABI

All offsets from the IPC block at `0x20020000` (`src/os/cart/os_abi.zig`);
see [ABI.md](ABI.md) for every owner.

| Where | Field | Meaning |
|---|---|---|
| `os_flags` bit 2 | `ext_flash` | the chip is mapped at `0x11000000` |
| `os_flags` bits 3-4 | `ext_volume` | what boot did with SYCLEXTRA: 0 none, 1 kept, 2 formatted, 3 reads unstable so not mounted |
| `0x200350F8` (u16) | `ext_flash_size_kb` | chip size in KB |
| `0x200350FA` (u16) | `ext_flash_cart_offset_kb` | start of the cart-writable area in KB (to the end of the chip) |
| `0x200350FC` (u32) | `ext_flash_diag` | boot report: `0xE2 << 24`, attempts (bit 7: found at cart start), QE status << 4 \| detect result, status register 2 |
| mailbox `0x2B` | `EXT_FLASH_REQ` / `EXT_FLASH_DONE` | one 4 KB erase or program in the cart area; payload = (request address - `0x20000000`) / 4 of an `ExtFlashRequest {op, offset, src, len}` in cart RAM; reply `0x2B << 24 \| status` |

Cart API (`src/os/cart/api.zig`): `ext_flash()` (whole chip, read-only, or
null), `ext_flash_cart_area()`, `ext_flash_erase(offset, len)` and
`ext_flash_program(offset, data)` (offsets relative to the cart area, 4 KB
erase and 256-byte program alignment), `ext_flash_diag()`,
`ext_flash_volume()`. The cart's core parks in RAM with interrupts masked
while core 0 writes, because XIP is off meanwhile.

Files on SYCLEXTRA are memory-mapped at `0x11000000` + offset with the same
FAT12 layout as the main drive (128 root entries), so a cart that reads ROMs
off the main drive needs only the second base address.

## Not done

- Quad reads on window 1.
- The console's `extflash` command (info / read / write self-test) needs the
  fork's USB console.
- A command for a LUN the host never asked about fails its CSW without
  stalling the data phase (like upstream's unhandled-opcode path).
