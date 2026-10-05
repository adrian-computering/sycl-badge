//! RAM-resident internal flash erase/program (core 0 only).
//!
//! Every operation runs in one critical section from `.ram_text`:
//!   save QMI window 0 (M0_TIMING/M0_RFMT/M0_RCMD), flash_exit_xip, erase or
//!   program, flash_flush_cache, flash_enter_cmd_xip, restore window 0.
//!
//! The restore matters: the bootrom's flash_enter_cmd_xip puts window 0 in 03h
//! serial reads at clkdiv 12, and without it the OS keeps running from flash in
//! that slow mode until the next reboot (found on the ext-flash branch).
//!
//! The bootrom function pointers are looked up once, from flash, before the first
//! operation (the lookup helpers are not RAM-resident), so nothing between
//! flash_exit_xip and the restore touches XIP.
//!
//! Core 1 must not touch XIP while an operation runs (carts are RAM carts and
//! mask their interrupts while they wait on a save; see SAVES.md).
const std = @import("std");
const microzig = @import("microzig");
const rom_api = microzig.hal.rom;
const interrupt = microzig.interrupt;

pub const XIP_BASE: u32 = 0x10000000;
pub const sector_size: u32 = 4096;
pub const page_size: u32 = 256;
const SECTOR_ERASE_CMD: u8 = 0x20;

// QMI (RP2350 datasheet 12.14), window 0 = the internal flash on CS0.
const QMI_BASE: usize = 0x400D0000;
const M0_TIMING: *volatile u32 = @ptrFromInt(QMI_BASE + 0x0C);
const M0_RFMT: *volatile u32 = @ptrFromInt(QMI_BASE + 0x10);
const M0_RCMD: *volatile u32 = @ptrFromInt(QMI_BASE + 0x14);
const RFMT_PREFIX_LEN_8: u32 = 1 << 12;
/// Uncached, non-allocating alias of window 0: a read here always reaches the chip.
const XIP_NOCACHE_NOALLOC_BASE: usize = 0x14000000;

const sig = rom_api.signatures;

const RomFns = struct {
    exit_xip: *const sig.flash_exit_xip,
    enter_cmd_xip: *const sig.flash_enter_cmd_xip,
    flush_cache: *const sig.flash_flush_cache,
    range_erase: *const sig.flash_range_erase,
    range_program: *const sig.flash_range_program,
};

var fns: RomFns = undefined;
var fns_ready: bool = false;

fn lookup() void {
    if (fns_ready) return;
    fns = .{
        .exit_xip = @ptrCast(@alignCast(rom_api.lookup_function(.flash_exit_xip))),
        .enter_cmd_xip = @ptrCast(@alignCast(rom_api.lookup_function(.flash_enter_cmd_xip))),
        .flush_cache = @ptrCast(@alignCast(rom_api.lookup_function(.flash_flush_cache))),
        .range_erase = @ptrCast(@alignCast(rom_api.lookup_function(.flash_range_erase))),
        .range_program = @ptrCast(@alignCast(rom_api.lookup_function(.flash_range_program))),
    };
    fns_ready = true;
}

const OP_ERASE: u32 = 1;
const OP_PROGRAM: u32 = 2;

/// The only code that runs with XIP off. No calls except through `fns`, no
/// aggregate copies (the compiler could emit a memcpy call into flash), no
/// bounds checks.
noinline fn runRaw(ops: u32, flash_off: u32, erase_len: u32, src: [*]const u8, src_len: u32) linksection(".ram_text") void {
    const timing = M0_TIMING.*;
    const rfmt = M0_RFMT.*;
    const rcmd = M0_RCMD.*;
    const f_exit = fns.exit_xip;
    const f_enter = fns.enter_cmd_xip;
    const f_flush = fns.flush_cache;
    const f_erase = fns.range_erase;
    const f_program = fns.range_program;
    asm volatile ("" ::: .{ .memory = true });

    f_exit();
    if (ops & OP_ERASE != 0) f_erase(flash_off, erase_len, sector_size, SECTOR_ERASE_CMD);
    if (ops & OP_PROGRAM != 0) f_program(flash_off, src, src_len);
    f_flush();
    f_enter();

    // Put window 0 back the way the OS had it.
    M0_TIMING.* = timing;
    M0_RCMD.* = rcmd;
    if (rfmt & RFMT_PREFIX_LEN_8 == 0) {
        // Continuous-read mode (no command prefix per transfer): flash_exit_xip
        // took the chip out of it, so send one read WITH the prefix; its mode
        // bits (RCMD suffix) put the chip back before the prefix is dropped.
        M0_RFMT.* = rfmt | RFMT_PREFIX_LEN_8;
        asm volatile ("dsb; isb" ::: .{ .memory = true });
        _ = @as(*const volatile u32, @ptrFromInt(XIP_NOCACHE_NOALLOC_BASE)).*;
    }
    M0_RFMT.* = rfmt;
    asm volatile ("dsb; isb" ::: .{ .memory = true });
}

fn run(ops: u32, flash_off: u32, erase_len: u32, src: [*]const u8, src_len: u32) void {
    lookup();
    const cs = interrupt.enter_critical_section();
    defer cs.leave();
    runRaw(ops, flash_off, erase_len, src, src_len);
}

fn inSram(p: [*]const u8, len: usize) bool {
    const a = @intFromPtr(p);
    return a >= 0x20000000 and a + len <= 0x20082000;
}

/// Erase `len` bytes at flash offset `flash_off` (both 4 KB multiples).
pub fn erase(flash_off: u32, len: u32) void {
    std.debug.assert(flash_off % sector_size == 0 and len % sector_size == 0);
    run(OP_ERASE, flash_off, len, undefined, 0);
}

/// Program `data` at flash offset `flash_off` (both 256-byte multiples, data in SRAM).
pub fn program(flash_off: u32, data: []const u8) void {
    std.debug.assert(flash_off % page_size == 0 and data.len % page_size == 0);
    std.debug.assert(inSram(data.ptr, data.len));
    run(OP_PROGRAM, flash_off, 0, data.ptr, @intCast(data.len));
}

/// Erase then program in the same critical section (storage.zig's sector rewrite).
pub fn eraseAndProgram(flash_off: u32, erase_len: u32, data: []const u8) void {
    std.debug.assert(flash_off % sector_size == 0 and erase_len % sector_size == 0);
    std.debug.assert(data.len % page_size == 0 and data.len <= erase_len);
    std.debug.assert(inSram(data.ptr, data.len));
    run(OP_ERASE | OP_PROGRAM, flash_off, erase_len, data.ptr, @intCast(data.len));
}

/// 0xFF-padded page for programs that are not whole SRAM-resident pages.
var bounce: [page_size]u8 align(4) = undefined;

/// Program any byte range: whole pages straight from SRAM, the rest (unaligned
/// head/tail, or a source outside SRAM) one page at a time through a 0xFF-padded
/// bounce page (programming 0xFF leaves a NOR bit unchanged).
pub fn programAny(flash_off: u32, data: []const u8) void {
    var off = flash_off;
    var rest = data;
    while (rest.len > 0) {
        const in_page = off % page_size;
        const room = page_size - in_page;
        if (in_page == 0 and rest.len >= page_size and inSram(rest.ptr, page_size)) {
            // Longest run of whole pages.
            var n: usize = rest.len - rest.len % page_size;
            if (!inSram(rest.ptr, n)) n = page_size;
            program(off, rest[0..n]);
            off += @intCast(n);
            rest = rest[n..];
        } else {
            const n: u32 = @intCast(@min(room, rest.len));
            @memset(&bounce, 0xFF);
            @memcpy(bounce[in_page..][0..n], rest[0..n]);
            program(off - in_page, &bounce);
            off += n;
            rest = rest[n..];
        }
    }
}
