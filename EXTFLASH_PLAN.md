# External flash (U8) support — plan

Branch `ext-flash` of a fresh upstream clone (base 5955625). Local only; not pushed anywhere.

## Hardware facts (kicad/v2 schematic + production netlist)

- U8 = GigaDevice GD25Q16ESIGR, 16 Mbit = 2 MB QSPI NOR flash.
- Shares QSPI_SCK / SD0..SD3 with the RP2354B in-package flash (CS0).
- Chip select net `QSPI_CS` -> IC1 pin 77 = GPIO0 (function 9 = XIP_CS1n), pull-up R37.
- Nothing in the OS touches GPIO0 (UART0 is on GPIO28/29; the uart.zig comment is stale).
- QMI window 1: cached 0x11000000, uncached 0x15000000. ATRANS4 reset maps it 1:1.
- GD25Q16C datasheet: 03h/90h up to 80 MHz, 0Bh up to 120 MHz, QE bit non-volatile,
  default 0 (quad reads need it set; HOLD#/WP# are active while QE=0).

## Bootrom facts (raspberrypi/pico-bootrom-rp2350)

- The bootrom keeps a FLASH_DEVINFO copy in boot RAM (`flash_devinfo16_ptr`, 'F','D').
  With CS1_SIZE/CS1_GPIO set there:
  - `connect_internal_flash` routes the CS1 GPIO to XIP_CS1 and clears pad isolation,
  - `flash_exit_xip` sends the XIP exit sequence to both chip selects,
  - `flash_range_erase/program` pick the chip from `offset >> 24`
    (offset 0x01000000 + n = CS1 byte n), bounds-checked against devinfo,
  - `flash_enter_cmd_xip` puts BOTH windows into 03h serial at clkdiv 12.
- So the OS's existing write path (`addr - 0x10000000` as the flash offset) works for
  CS1 addresses 0x11xxxxxx unchanged once devinfo declares CS1.
- Side finding for the organizers: after any OS flash write, window 0 (the OS itself)
  is left in 03h serial at clkdiv 12 (12.5 MHz) until reboot.

## Milestones

### E0 — probe cart (DONE, 538f97c)
`carts/extflash-probe`: works on stock firmware. Routes GPIO0, reads SFDP (5Ah),
ID (90h), 03h data and a 64 KB speed test through window 1. Hardware result pending.

### E1 — OS bring-up
- `src/os/drivers/ext_flash.zig`: detect at boot (SFDP signature + JEDEC density via
  window 1, no direct mode needed), on success declare CS1 in boot RAM devinfo
  (GPIO0, size from SFDP), set window 1 to 0Bh fast read; on failure restore GPIO0 /
  window 1 so the OS behaves exactly as before.
- Re-apply the window 1 read mode after every bootrom flash write (storage, loader).
- `erase` / `program` helpers (RAM-resident, critical section, same pattern as storage).
- Cart ABI: `os_flags.ext_flash` + `ext_flash_size` (was `_reserved[0]`); cart API
  `ext_flash()` returns the read-only 0x11000000 slice or null (old OS, no chip, sim).
- Console: `extflash` (info), `extflash read <off> [len]`, `extflash test confirm`
  (save sector, erase, program pattern, verify, restore).

### E2 — second USB drive on the external chip
- USB MSC LUN 1 = a FAT12 volume "SYCLEXTRA" spanning the chip (2 MB fits FAT12 with
  512 B clusters). LUN 0 stays byte-identical: no reformat of existing drives on update.
  Without the chip, max LUN stays 0 = today's behaviour.
- storage.zig refactored around a Volume (base, size, label); the 4 KB pending write
  buffer stays shared (block addresses differ per chip).
- Cart menu, console `cart` and loader list/run carts from both volumes.
- Cart-visible: files on the extra volume are memory-mapped at 0x11000000 + offset,
  same FAT12 layout as the main drive, so drive-ROM readers only need the base.

### E3 — later / deferred
- Quad reads (QE bit via direct mode at boot) if the 0Bh speed is not enough.
- Cart write API (saves) through a mailbox request to core 0.
- Monorepo: romfs reader + emulator ROM pickers scan the extra volume.

## Deferred questions (defaults taken)
- Second drive vs one bigger drive: second LUN chosen (no reformat, safe fallback).
  One bigger drive would mean a reformat on update and a non-contiguous drive map.
- Volume label `SYCLEXTRA`.
