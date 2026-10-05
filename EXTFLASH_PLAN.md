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

### E1 — OS bring-up (DONE, 7750276; untested on hardware)
- `src/os/drivers/ext_flash.zig`: detect at boot (SFDP signature + JEDEC density via
  window 1, no direct mode needed), on success declare CS1 in boot RAM devinfo
  (GPIO0, size from SFDP), set window 1 to 0Bh fast read; on failure restore GPIO0 /
  window 1 so the OS behaves exactly as before.
- Re-apply the window 1 read mode after every bootrom flash write (storage, loader).
- `erase` / `program` helpers (RAM-resident, critical section, same pattern as storage).
- Cart ABI: `os_flags.ext_flash` + `ext_flash_size` (was `_reserved[0]`); cart API
  `ext_flash()` returns the read-only 0x11000000 slice or null (old OS, no chip, sim).
- Console: `extflash` (info), `extflash read <off> [len]`, `extflash test confirm`
  (save sector, erase, program pattern, verify, restore). NOTE: upstream's USB CDC
  input is stubbed (usb.receive returns 0), so the console is unreachable today; the
  probe cart's OS page runs the same write self-test through the cart API instead.

### E2 — second USB drive on the external chip (DONE; untested on hardware)
- USB MSC LUN 1 = a FAT12 volume "SYCLEXTRA" spanning the chip (2 MB fits FAT12 with
  512 B clusters). LUN 0 stays byte-identical: no reformat of existing drives on update.
  Without the chip, max LUN stays 0 = today's behaviour.
- storage.zig refactored around a Volume (base, size, label); the 4 KB pending write
  buffer stays shared (block addresses differ per chip).
- Cart menu, console `cart` and loader list/run carts from both volumes.
- Cart-visible: files on the extra volume are memory-mapped at 0x11000000 + offset,
  same FAT12 layout as the main drive, so drive-ROM readers only need the base.
- Volume = chip minus the 256 KB cart area = 1792 KB, 128 root entries, formatted on
  first boot with the chip. Duplicate cart names: the main drive's copy wins.

### E3 — later / deferred
- Quad reads (QE bit via direct mode at boot) if the 0Bh speed is not enough.
- (Cart write API moved into E1: cart.ext_flash_erase/program on the last 256 KB.)
- Monorepo: romfs reader + emulator ROM pickers scan the extra volume.

## Deferred questions (defaults taken)
- Second drive vs one bigger drive: second LUN chosen (no reformat, safe fallback).
  One bigger drive would mean a reformat on update and a non-contiguous drive map.
- Volume label `SYCLEXTRA`.

## Hardware test (files in animated-badge:~/extflash-dist/)

Step 1, stock firmware, zero risk: copy `extflash-probe.uf2` to the badge drive and run it.
- Page 1: "CHIP ALIVE", "SFDP ok 2048KB", "ID C8 14 GD25Q16", a KB/s figure. The
  "OS window 0" lines show how the show firmware reads its own flash.
- If it says NO ANSWER, stop here and photograph pages 1 and 2 (B flips pages).

Step 2, patched OS (`sycl-os-extflash-e2.uf2`): hold BOOT_SEL while power-cycling (or
RESET+BOOT_SEL, release RESET first), copy the UF2 to the RP2350 drive. Only the 512 KB
OS region is rewritten; the cart drive survives. Keep the organizers' OS UF2 to go back
(`sycl-os-upstream-5955625.uf2` is plain upstream main if theirs is missing).
- The computer should now mount TWO drives: the usual one and an empty "SYCLEXTRA".
- Probe cart page 3 ("OS SUPPORT"): "ext_flash 2048KB", "cart area 256KB", then A runs
  the write self-test: expect WRITE TEST PASS (erase ~45 ms, program a few ms).
- Copy a cart UF2 onto SYCLEXTRA: it should appear in the badge menu and run.
- If boot hangs or the drive misbehaves: re-flash the organizers' OS UF2.
