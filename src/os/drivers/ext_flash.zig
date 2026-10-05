/// External QSPI flash driver (U8, GD25Q16 on the v2 badge)
///
/// The board carries a second 2 MB QSPI flash beside the RP2354B's in-package
/// flash. It shares SCK/SD0..SD3 with the internal flash and its chip select is
/// wired to GPIO0, which the RP2350 can drive as XIP_CS1n. Once enabled, QMI
/// window 1 maps it read-only at 0x11000000 (uncached alias 0x15000000).
///
/// Bring-up uses only XIP reads through window 1, so it never disturbs window 0
/// (the OS runs from it):
///   1. route GPIO0 to XIP_CS1,
///   2. point window 1 at the chip with the SFDP read command (5Ah) and check
///      for the "SFDP" signature and the JEDEC density,
///   3. declare CS1 in the bootrom's boot RAM copy of FLASH_DEVINFO.
///
/// Step 3 is what makes the bootrom flash routines handle the chip: with CS1
/// declared, flash_exit_xip also exits CS1. flash_range_erase/program pick the
/// chip from bit 24 of the offset alone (CS1 for 0x01000000 and up) and do NOT
/// bounds-check against devinfo, so checkRange() here is the only guard. So an XIP address 0x11000000 + n
/// maps to flash offset (addr - 0x10000000) exactly like the internal flash.
/// flash_enter_cmd_xip resets both windows to slow 03h reads; the rom.zig
/// wrapper calls applyReadMode() after it.
///
/// If the chip does not answer, GPIO0 and window 1 are put back the way they
/// were and the OS runs as if the chip did not exist.
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const rom = @import("rom.zig");
const timer = @import("timer.zig");
const log = std.log.scoped(.ext_flash);

const interrupt = microzig.interrupt;

/// Cached XIP address of byte 0 of the external flash.
pub const base: u32 = 0x11000000;
/// Uncached, non-allocating alias of the same bytes.
pub const base_nocache: u32 = 0x15000000;
/// Bootrom flash offset of byte 0 (offset >> 24 selects the chip).
pub const flash_offset: u32 = base - 0x10000000;

pub const sector_size: u32 = 4096;
pub const page_size: u32 = 256;
const SECTOR_ERASE_CMD: u8 = 0x20;

/// GPIO wired to the chip select (schematic net QSPI_CS -> RP2354B pin 77).
const CS1_GPIO: u5 = 0;

const QMI_BASE: usize = 0x400D0000;
const M1_TIMING = QMI_BASE + 0x20;
const M1_RFMT = QMI_BASE + 0x24;
const M1_RCMD = QMI_BASE + 0x28;
const IO_BANK0_GPIO_CTRL: usize = 0x40028000 + 0x04 + @as(usize, CS1_GPIO) * 8;
const PADS_BANK0_GPIO: usize = 0x40038000 + 0x04 + @as(usize, CS1_GPIO) * 4;
const PADS_GPIO_RESET: u32 = 0x116;
const PADS_ISO: u32 = 1 << 8;
const FUNC_XIP_CS1: u32 = 9;

// QMI Mx_RFMT fields (all transfer phases single-lane, width field 0)
const RFMT_PREFIX_LEN_8: u32 = 1 << 12;
const RFMT_DUMMY_LEN_8: u32 = 2 << 16;

// QMI Mx_TIMING fields
const TIMING_COOLDOWN_1: u32 = 1 << 30;
const TIMING_MIN_DESELECT_7: u32 = 7 << 12;
const TIMING_RXDELAY_2: u32 = 2 << 8;

/// clkdiv 4 (37.5 MHz) for detection: under every command's limit.
const DETECT_TIMING: u32 = TIMING_COOLDOWN_1 | TIMING_MIN_DESELECT_7 | TIMING_RXDELAY_2 | 4;
/// Run-time reads: 0Bh fast read (8 dummy clocks, 120 MHz part) at clkdiv 3
/// (50 MHz at 150 MHz clk_sys). No QE bit needed.
const READ_TIMING: u32 = TIMING_COOLDOWN_1 | TIMING_MIN_DESELECT_7 | TIMING_RXDELAY_2 | 3;
const READ_RFMT: u32 = RFMT_PREFIX_LEN_8 | RFMT_DUMMY_LEN_8;
const READ_CMD: u32 = 0x0B;

// FLASH_DEVINFO fields (OTP_DATA_FLASH_DEVINFO_*)
const DEVINFO_CS1_SIZE_LSB = 12;
const DEVINFO_CS1_SIZE_MASK: u16 = 0xF000;
const DEVINFO_CS1_GPIO_MASK: u16 = 0x003F;

pub const Info = struct {
    size: u32,
    manufacturer: u8,
    device: u8,
    sfdp_major: u8,
    sfdp_minor: u8,
};

var info: ?Info = null;

/// Boot detection outcome for carts (ipc ext_flash_diag), so a probe can tell
/// this firmware from stock even when the chip check fails:
/// magic 0xE2 << 24 | attempts << 16 | DetectResult << 8 | first SFDP byte seen.
pub const diag_magic: u32 = 0xE2;
pub const DetectResult = enum(u8) { ok = 0, no_signature = 1, not_jedec = 2, bad_density = 3 };
var diag: u32 = 0;

pub fn bootDiag() u32 {
    return diag;
}

/// Detection attempts at boot, each preceded by a release-from-power-down
/// (ABh) read, in case the chip is not ready yet right after power-up.
const detect_attempts: u32 = 10;
const detect_retry_ms: u32 = 5;

/// Size in bytes, or 0 when no chip was found.
pub fn size() u32 {
    return if (info) |i| i.size else 0;
}

pub fn present() bool {
    return info != null;
}

pub fn getInfo() ?Info {
    return info;
}

/// Read-only view of the whole chip through the cached window.
pub fn bytes() ?[]const u8 {
    const i = info orelse return null;
    const p: [*]const u8 = @ptrFromInt(base);
    return p[0..i.size];
}

fn reg(addr: usize) *volatile u32 {
    return @ptrFromInt(addr);
}

fn readNoCache(offset: u32, dst: []u8) void {
    const src: [*]const volatile u8 = @ptrFromInt(base_nocache + offset);
    for (dst, 0..) |*b, i| b.* = src[i];
}

fn setWindow1(timing: u32, rfmt: u32, cmd: u32) void {
    reg(M1_TIMING).* = timing;
    reg(M1_RFMT).* = rfmt;
    reg(M1_RCMD).* = cmd;
    asm volatile ("dsb; isb" ::: .{ .memory = true });
}

/// Detect the chip and enable it. Call on core 0 before core 1 starts, after
/// rom.connect_internal_flash() (QSPI pads) and before calling it again
/// (which then keeps GPIO0 on XIP_CS1).
pub fn init() void {
    bringUp(detect_attempts);
}

/// One more detection attempt when a cart starts, if boot didn't find the
/// chip: carts then get it, but the second USB drive only appears after a
/// reboot. Marks the diag word with late_flag. Call on core 0 while no cart
/// runs.
pub fn retryLate() void {
    if (info != null) return;
    const boot_diag = diag;
    bringUp(1);
    // Keep the boot report unless this attempt worked.
    diag = if (info != null) diag | (late_flag << 16) else boot_diag;
}

/// Set in the attempts byte of the diag word when retryLate() found the chip.
pub const late_flag: u32 = 0x80;

fn bringUp(attempts: u32) void {
    const saved_ctrl = reg(IO_BANK0_GPIO_CTRL).*;
    const saved_pad = reg(PADS_BANK0_GPIO).*;
    const saved_timing = reg(M1_TIMING).*;
    const saved_rfmt = reg(M1_RFMT).*;
    const saved_rcmd = reg(M1_RCMD).*;

    // Same sequence the bootrom uses for an OTP-declared CS1.
    reg(PADS_BANK0_GPIO).* = PADS_GPIO_RESET;
    reg(IO_BANK0_GPIO_CTRL).* = FUNC_XIP_CS1;
    reg(PADS_BANK0_GPIO).* = PADS_GPIO_RESET & ~PADS_ISO;

    var result: DetectResult = .no_signature;
    var first_byte: u8 = 0;
    var found_info: ?Info = null;
    var attempt: u32 = 0;
    while (attempt < attempts) {
        if (attempt != 0) timer.sleep_ms(detect_retry_ms);
        attempt += 1;
        wake();
        found_info = detect(&result, &first_byte);
        if (found_info != null) break;
    }
    diag = (diag_magic << 24) | (attempt << 16) | (@as(u32, @intFromEnum(result)) << 8) | first_byte;

    if (found_info) |found| {
        info = found;
        setDevinfo(found.size);
        applyReadMode();
        log.info("external flash: {d} KB, id {X:0>2} {X:0>2}, SFDP {d}.{d}", .{
            found.size / 1024, found.manufacturer, found.device, found.sfdp_major, found.sfdp_minor,
        });
    } else {
        setWindow1(saved_timing, saved_rfmt, saved_rcmd);
        reg(IO_BANK0_GPIO_CTRL).* = saved_ctrl;
        reg(PADS_BANK0_GPIO).* = saved_pad;
        log.info("external flash: not found (result {d}, first byte 0x{X:0>2})", .{ @intFromEnum(result), first_byte });
    }
}

/// ABh (release from deep power-down): command, three dummy bytes in the
/// address phase, then the chip clocks out its electronic ID. Harmless when
/// the chip is already awake; tRES1 is a few microseconds.
fn wake() void {
    setWindow1(DETECT_TIMING, RFMT_PREFIX_LEN_8, 0xAB);
    var id: [1]u8 = undefined;
    readNoCache(0, &id);
    timer.sleep_us(50);
}

fn detect(result: *DetectResult, first_byte: *u8) ?Info {
    // 5Ah SFDP: 24-bit address, 8 dummy clocks.
    setWindow1(DETECT_TIMING, RFMT_PREFIX_LEN_8 | RFMT_DUMMY_LEN_8, 0x5A);
    var header: [16]u8 = undefined;
    readNoCache(0, &header);
    first_byte.* = header[0];
    result.* = .no_signature;
    if (!std.mem.eql(u8, header[0..4], "SFDP")) return null;

    // Parameter header 0 must be the JEDEC basic flash parameter table (ID 0xFF00).
    result.* = .not_jedec;
    if (header[8] != 0x00 or header[15] != 0xFF) return null;
    const table: u32 = @as(u32, header[12]) | (@as(u32, header[13]) << 8) | (@as(u32, header[14]) << 16);
    var dw2: [4]u8 = undefined;
    readNoCache(table + 4, &dw2);
    const density = std.mem.readInt(u32, &dw2, .little);
    const chip_bytes: u64 = if (density & 0x8000_0000 == 0)
        (@as(u64, density) + 1) / 8
    else if (density & 0x7FFF_FFFF >= 3 and density & 0x7FFF_FFFF < 40)
        @as(u64, 1) << @intCast((density & 0x7FFF_FFFF) - 3)
    else
        0;
    // FLASH_DEVINFO encodes 8 KB .. 16 MB as log2(size / 4 KB); window 1 is 16 MB.
    if (chip_bytes < 8 * 1024 or chip_bytes > 16 * 1024 * 1024 or !std.math.isPowerOfTwo(chip_bytes)) {
        log.warn("external flash: SFDP density 0x{X:0>8} unusable", .{density});
        result.* = .bad_density;
        return null;
    }

    // 90h: manufacturer and device ID after a 24-bit address of zero.
    setWindow1(DETECT_TIMING, RFMT_PREFIX_LEN_8, 0x90);
    var id: [2]u8 = undefined;
    readNoCache(0, &id);

    result.* = .ok;
    return .{
        .size = @intCast(chip_bytes),
        .manufacturer = id[0],
        .device = id[1],
        .sfdp_major = header[5],
        .sfdp_minor = header[4],
    };
}

/// rom_data_lookup. microzig's hal.rom.lookup_data doesn't compile for Arm
/// (ROM_DATA_LOOKUP_* pass a pointer to @ptrFromInt); on Arm, data lookups use
/// the same table lookup function as code, with the data flag.
fn romDataLookup(code: [2]u8) ?*const anyopaque {
    const RT_FLAG_DATA: u32 = 0x40;
    const lookup_addr: usize = if (hal.rom.get_version_number() < 2)
        @as(*const u32, @ptrFromInt(0x18)).*
    else
        @as(*const u16, @ptrFromInt(0x16)).*;
    const lookup: *const fn (u32, u32) callconv(.c) ?*const anyopaque = @ptrFromInt(lookup_addr);
    return lookup(@as(u32, code[0]) | (@as(u32, code[1]) << 8), RT_FLAG_DATA);
}

fn setDevinfo(chip_bytes: u32) void {
    const pp: *const *volatile u16 = @ptrCast(@alignCast(romDataLookup(.{ 'F', 'D' }) orelse {
        log.err("external flash: bootrom has no FLASH_DEVINFO pointer", .{});
        return;
    }));
    const devinfo = pp.*;
    const size_code: u16 = @intCast(std.math.log2_int(u32, chip_bytes / 4096));
    const wanted: u16 = (size_code << DEVINFO_CS1_SIZE_LSB) | CS1_GPIO;
    const mask: u16 = DEVINFO_CS1_SIZE_MASK | DEVINFO_CS1_GPIO_MASK;
    // Plain read-modify-write, as the bootrom itself stores this field; core 1
    // isn't running yet, so nothing races it.
    devinfo.* = (devinfo.* & ~mask) | wanted;
    log.debug("FLASH_DEVINFO now 0x{X:0>4}", .{devinfo.*});
}

/// Put window 1 back into the run-time read mode. rom.flash_enter_cmd_xip()
/// calls this, because the bootrom resets both windows to 03h at clkdiv 12.
pub fn applyReadMode() linksection(".ram_text") void {
    if (info == null) return;
    reg(M1_TIMING).* = READ_TIMING;
    reg(M1_RFMT).* = READ_RFMT;
    reg(M1_RCMD).* = READ_CMD;
    asm volatile ("dsb; isb" ::: .{ .memory = true });
}

pub const Error = error{ NotPresent, OutOfRange, Misaligned };

/// Carts may write only the last part of the chip (saves, caches); the rest
/// is reserved for OS-managed storage.
const cart_area_size: u32 = 256 * 1024;

/// Byte offset where the cart-writable area starts (it runs to size()).
pub fn cartAreaOffset() u32 {
    const total = size();
    return total - @min(cart_area_size, total / 2);
}

/// Largest cart request: core 0 handles it inside its main loop, where USB is
/// polled, so a request is one sector (erase up to ~300 ms worst case per the
/// datasheet, ~45 ms typical). The cart API loops over larger ranges.
pub const cart_max_request: u32 = sector_size;

/// erase() limited to the cart area and one request's size.
pub fn cartErase(offset: u32, len: usize) Error!void {
    if (offset < cartAreaOffset() or len > cart_max_request) return error.OutOfRange;
    return erase(offset, len);
}

/// program() limited to the cart area and one request's size.
pub fn cartProgram(offset: u32, data: []const u8) Error!void {
    if (offset < cartAreaOffset() or data.len > cart_max_request) return error.OutOfRange;
    return program(offset, data);
}

fn checkRange(offset: u32, len: usize, alignment: u32) Error!void {
    const total = size();
    if (total == 0) return error.NotPresent;
    if (offset % alignment != 0 or len % alignment != 0) return error.Misaligned;
    if (offset > total or len > total - offset) return error.OutOfRange;
}

/// Erase whole 4 KB sectors. offset and len must be sector aligned.
/// Core 1 must not touch XIP flash while this runs. One sector per critical
/// section (~45 ms typical), so interrupts get serviced in between.
pub fn erase(offset: u32, len: usize) Error!void {
    try checkRange(offset, len, sector_size);
    var done: u32 = 0;
    while (done < len) : (done += sector_size) {
        eraseRaw(flash_offset + offset + done, sector_size);
    }
}

/// Program erased bytes. offset and data.len must be 256-byte aligned.
/// Core 1 must not touch XIP flash while this runs. Up to one sector per
/// critical section.
pub fn program(offset: u32, data: []const u8) Error!void {
    try checkRange(offset, data.len, page_size);
    var done: u32 = 0;
    while (done < data.len) {
        const n = @min(data.len - done, sector_size);
        programRaw(flash_offset + offset + done, data[done..][0..n]);
        done += n;
    }
}

noinline fn eraseRaw(off: u32, len: usize) linksection(".ram_text") void {
    const cs = interrupt.enter_critical_section();
    defer cs.leave();
    rom.flash_exit_xip();
    rom.flash_range_erase(off, len, sector_size, SECTOR_ERASE_CMD);
    rom.flash_flush_cache();
    rom.flash_enter_cmd_xip();
}

noinline fn programRaw(off: u32, data: []const u8) linksection(".ram_text") void {
    const cs = interrupt.enter_critical_section();
    defer cs.leave();
    rom.flash_exit_xip();
    rom.flash_range_program(off, data);
    rom.flash_flush_cache();
    rom.flash_enter_cmd_xip();
}
