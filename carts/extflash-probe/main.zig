//! External flash probe.
//!
//! The v2 badge has a 2 MB GD25Q16 QSPI flash (U8) sharing the QSPI bus with
//! the RP2354B's in-package flash, its chip select wired to GPIO0 (XIP_CS1n).
//! Stock firmware never enables it. This cart routes GPIO0 to XIP_CS1, points
//! QMI window 1 at it with a few read commands that fit the XIP read format
//! and reads the results through the uncached CS1 alias (0x15000000):
//!
//!   - 5Ah SFDP read: the chip answers "SFDP" and a JEDEC parameter table
//!     that holds its density.
//!   - 90h manufacturer/device ID: GigaDevice = C8, GD25Q16 = 14.
//!   - 03h serial read: the first bytes of the array and a read speed test.
//!
//! None of this touches window 0, which the OS executes from, so it is safe
//! to run beside the stock OS. Window 1's registers are restored afterwards.
//!
//! The third page tests OS support (ext-flash firmware): cart.ext_flash()
//! and a write self-test of the last cart-area sector through the OS
//! (contents saved and restored).
//!
//! B: next page   A: run again (on the OS page: run the write test)

const std = @import("std");
const builtin = @import("builtin");
const cart = @import("cart-api");

comptime {
    cart.export_start_code();
}

const on_badge = builtin.target.cpu.arch == .thumb;

const QMI_BASE: usize = 0x400D0000;
const M0_TIMING = QMI_BASE + 0x0C;
const M0_RFMT = QMI_BASE + 0x10;
const M0_RCMD = QMI_BASE + 0x14;
const M1_TIMING = QMI_BASE + 0x20;
const M1_RFMT = QMI_BASE + 0x24;
const M1_RCMD = QMI_BASE + 0x28;
const ATRANS4 = QMI_BASE + 0x44;
const IO_BANK0_GPIO0_CTRL: usize = 0x40028000 + 0x04;
const PADS_BANK0_GPIO0: usize = 0x40038000 + 0x04;
const PADS_GPIO0_RESET: u32 = 0x116;
const PADS_ISO: u32 = 1 << 8;
const FUNC_XIP_CS1: u32 = 9;
/// Uncached, non-allocating alias of the CS1 window: no stale lines, and the
/// probe doesn't evict OS code from the shared XIP cache.
const CS1_NOCACHE: usize = 0x15000000;

// M1_RFMT fields (all widths single-lane = 0)
const RFMT_PREFIX_LEN_8: u32 = 1 << 12;
const RFMT_DUMMY_LEN_8: u32 = 2 << 16;

fn reg(addr: usize) *volatile u32 {
    return @ptrFromInt(addr);
}

/// clkdiv 4 = 37.5 MHz at 150 MHz: within every read command's limit
/// (03h and 90h are the slowest at 80 MHz on the GD25Q16C datasheet). RXDELAY 2, MIN_DESELECT 7,
/// COOLDOWN 1 as the bootrom uses.
const PROBE_TIMING: u32 = (1 << 30) | (7 << 12) | (2 << 8) | 4;

const Result = struct {
    m0_timing: u32 = 0,
    m0_rfmt: u32 = 0,
    m0_rcmd: u32 = 0,
    m1_rcmd_before: u32 = 0,
    atrans4: u32 = 0,
    gpio0_ctrl_before: u32 = 0,
    sfdp: [64]u8 = @splat(0),
    sfdp_ok: bool = false,
    density_bytes: u32 = 0,
    mfr: u8 = 0,
    dev: u8 = 0,
    first: [8]u8 = @splat(0),
    blank_64k: bool = false,
    kbps: u32 = 0,
};

var result: Result = .{};
var page: u2 = 0;
const page_count = 3;

const WriteTest = struct {
    ran: bool = false,
    err: ?anyerror = null,
    erase_us: u64 = 0,
    program_us: u64 = 0,
    not_ff: u32 = 0,
    wrong: u32 = 0,
    cached_ok: bool = false,
    restored: u32 = 0,
};
var write_test: WriteTest = .{};
var saved_sector: [4096]u8 align(4) = undefined;
var pattern: [4096]u8 align(4) = undefined;
var last: cart.Controls = .none;

fn setWindow1(cmd: u8, rfmt_extra: u32) void {
    reg(M1_TIMING).* = PROBE_TIMING;
    reg(M1_RFMT).* = RFMT_PREFIX_LEN_8 | rfmt_extra;
    reg(M1_RCMD).* = cmd;
    asm volatile ("dsb; isb" ::: .{ .memory = true });
}

fn setWindow1Raw(v: [3]u32) void {
    reg(M1_TIMING).* = v[0];
    reg(M1_RFMT).* = v[1];
    reg(M1_RCMD).* = v[2];
    asm volatile ("dsb; isb" ::: .{ .memory = true });
}

fn runWriteTest() void {
    var t: WriteTest = .{ .ran = true };
    defer write_test = t;
    const area = cart.ext_flash_cart_area() orelse {
        t.err = error.Unsupported;
        return;
    };
    const off: u32 = @intCast(area.len - 4096);
    const nocache: [*]const volatile u8 = @ptrFromInt(@intFromPtr(area.ptr) - 0x11000000 + CS1_NOCACHE + off);
    for (&saved_sector, 0..) |*b, i| b.* = nocache[i];
    for (&pattern, 0..) |*b, i| b.* = @truncate(i *% 7 +% (i >> 8) +% 0x5A);

    const t0 = cart.micros_since_boot();
    cart.ext_flash_erase(off, 4096) catch |e| {
        t.err = e;
        return;
    };
    const t1 = cart.micros_since_boot();
    for (0..4096) |i| t.not_ff += @intFromBool(nocache[i] != 0xFF);
    const t2 = cart.micros_since_boot();
    cart.ext_flash_program(off, &pattern) catch |e| {
        t.err = e;
        return;
    };
    const t3 = cart.micros_since_boot();
    for (0..4096) |i| t.wrong += @intFromBool(nocache[i] != pattern[i]);
    t.cached_ok = std.mem.eql(u8, area[off..][0..4096], &pattern);
    t.erase_us = t1 - t0;
    t.program_us = t3 - t2;

    cart.ext_flash_erase(off, 4096) catch {};
    cart.ext_flash_program(off, &saved_sector) catch {};
    for (0..4096) |i| t.restored += @intFromBool(nocache[i] == saved_sector[i]);
}

fn readCs1(offset: usize, dst: []u8) void {
    const src: [*]const volatile u8 = @ptrFromInt(CS1_NOCACHE + offset);
    for (dst, 0..) |*b, i| b.* = src[i];
}

fn probe() void {
    const saved_m1 = [3]u32{ reg(M1_TIMING).*, reg(M1_RFMT).*, reg(M1_RCMD).* };
    defer setWindow1Raw(saved_m1);
    var r: Result = .{};
    r.m0_timing = reg(M0_TIMING).*;
    r.m0_rfmt = reg(M0_RFMT).*;
    r.m0_rcmd = reg(M0_RCMD).*;
    r.m1_rcmd_before = reg(M1_RCMD).*;
    r.atrans4 = reg(ATRANS4).*;
    r.gpio0_ctrl_before = reg(IO_BANK0_GPIO0_CTRL).*;

    // Route GPIO0 to XIP_CS1n the way the bootrom does for an OTP-declared
    // CS1: reset the pad, select the function, then release pad isolation.
    reg(PADS_BANK0_GPIO0).* = PADS_GPIO0_RESET;
    reg(IO_BANK0_GPIO0_CTRL).* = FUNC_XIP_CS1;
    reg(PADS_BANK0_GPIO0).* = PADS_GPIO0_RESET & ~PADS_ISO;

    // 5Ah: SFDP, 24-bit address + 8 dummy clocks.
    setWindow1(0x5A, RFMT_DUMMY_LEN_8);
    readCs1(0, &r.sfdp);
    r.sfdp_ok = std.mem.eql(u8, r.sfdp[0..4], "SFDP");
    if (r.sfdp_ok) {
        // Parameter header 0 (JEDEC basic table) at 8: pointer in bytes 12..14.
        const ptp: usize = @as(usize, r.sfdp[12]) | (@as(usize, r.sfdp[13]) << 8) | (@as(usize, r.sfdp[14]) << 16);
        var dw2: [4]u8 = undefined;
        readCs1(ptp + 4, &dw2);
        const density = std.mem.readInt(u32, &dw2, .little);
        if (density & 0x8000_0000 == 0) {
            r.density_bytes = (density +% 1) / 8;
        } else {
            const n: u5 = @truncate(density & 0x1f);
            r.density_bytes = if (n >= 3) @as(u32, 1) << (n - 3) else 0;
        }
    }

    // 90h: manufacturer then device ID, repeating, after a 24-bit address of 0.
    setWindow1(0x90, 0);
    var id: [2]u8 = undefined;
    readCs1(0, &id);
    r.mfr = id[0];
    r.dev = id[1];

    // 03h: plain serial read, the mode the bootrom uses after flash writes.
    setWindow1(0x03, 0);
    readCs1(0, &r.first);
    const len: usize = 64 * 1024;
    const src: [*]const volatile u32 = @ptrFromInt(CS1_NOCACHE);
    var acc: u32 = 0xFFFF_FFFF;
    const t0 = cart.micros_since_boot();
    for (0..len / 4) |i| acc &= src[i];
    const dt = cart.micros_since_boot() - t0;
    r.blank_64k = acc == 0xFFFF_FFFF;
    r.kbps = if (dt == 0) 0 else @intCast((@as(u64, len) * 1_000_000 / 1024) / dt);

    result = r;
}

const white: cart.DisplayColor = .rgb(0xFFFFFF);
const grey: cart.DisplayColor = .rgb(0x9090A0);
const green: cart.DisplayColor = .rgb(0x40FF60);
const red: cart.DisplayColor = .rgb(0xFF4040);
const yellow: cart.DisplayColor = .rgb(0xFFE040);
const bg: cart.DisplayColor = .rgb(0x101018);

var line_y: i32 = 0;

fn say(color: cart.DisplayColor, comptime fmt: []const u8, args: anytype) void {
    var buf: [40]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..];
    cart.text(.{ .str = s, .x = 0, .y = line_y, .text_color = color });
    line_y += 8;
}

fn draw() void {
    cart.rect(.{ .x = 0, .y = 0, .width = cart.screen_width, .height = cart.screen_height, .fill_color = bg });
    line_y = 0;
    const r = &result;
    if (!on_badge) {
        say(yellow, "EXT FLASH PROBE", .{});
        say(grey, "badge only", .{});
        return;
    }
    if (page == 2) {
        say(yellow, "OS SUPPORT", .{});
        const all = cart.ext_flash();
        if (all) |a| {
            say(green, "ext_flash {d}KB", .{a.len / 1024});
            const area = cart.ext_flash_cart_area().?;
            say(white, "cart area {d}KB @{X}", .{ area.len / 1024, a.len - area.len });
        } else {
            say(red, "not mapped by OS", .{});
            say(grey, "(stock firmware?)", .{});
        }
        line_y += 4;
        const t = &write_test;
        if (!t.ran) {
            say(grey, "A: write test", .{});
            say(grey, "(last sector, restored)", .{});
        } else if (t.err) |e| {
            say(red, "write test: {s}", .{@errorName(e)});
        } else {
            const pass = t.not_ff == 0 and t.wrong == 0 and t.cached_ok and t.restored == 4096;
            say(if (pass) green else red, "WRITE TEST {s}", .{if (pass) "PASS" else "FAIL"});
            say(white, "erase {d}us {d} !FF", .{ t.erase_us, t.not_ff });
            say(white, "prog {d}us {d} bad", .{ t.program_us, t.wrong });
            say(white, "cached view {s}", .{if (t.cached_ok) "ok" else "STALE"});
            say(white, "restored {d}/4096", .{t.restored});
        }
        return;
    }
    if (page == 1) {
        say(yellow, "SFDP RAW", .{});
        var i: usize = 0;
        while (i < r.sfdp.len) : (i += 4) {
            say(white, "{X:0>2} {X:0>2}{X:0>2}{X:0>2}{X:0>2}", .{ i, r.sfdp[i], r.sfdp[i + 1], r.sfdp[i + 2], r.sfdp[i + 3] });
        }
        return;
    }
    const alive = r.sfdp_ok and r.density_bytes != 0;
    say(yellow, "EXT FLASH PROBE", .{});
    say(if (alive) green else red, "{s}", .{if (alive) "CHIP ALIVE" else "NO ANSWER"});
    say(if (r.sfdp_ok) green else red, "SFDP {s} {d}KB", .{ if (r.sfdp_ok) "ok" else "--", r.density_bytes / 1024 });
    const gd = r.mfr == 0xC8;
    say(if (gd) green else white, "ID {X:0>2} {X:0>2} {s}", .{ r.mfr, r.dev, if (gd and r.dev == 0x14) "GD25Q16" else if (gd) "GigaDev" else "?" });
    say(white, "03h {X:0>2}{X:0>2}{X:0>2}{X:0>2}{X:0>2}{X:0>2}{X:0>2}{X:0>2}", .{ r.first[0], r.first[1], r.first[2], r.first[3], r.first[4], r.first[5], r.first[6], r.first[7] });
    say(white, "64K {s} {d}KB/s", .{ if (r.blank_64k) "blank" else "data", r.kbps });
    line_y += 4;
    say(grey, "OS window 0:", .{});
    say(grey, " T {X:0>8}", .{r.m0_timing});
    say(grey, " F {X:0>8} C {X:0>2}", .{ r.m0_rfmt, r.m0_rcmd & 0xFF });
    say(grey, "before: G0 {X:0>2} C1 {X:0>2}", .{ r.gpio0_ctrl_before & 0x1F, r.m1_rcmd_before & 0xFF });
    say(grey, "ATRANS4 {X:0>8}", .{r.atrans4});
    line_y += 4;
    say(grey, "A rerun  B next page", .{});
}

pub fn start() void {
    if (on_badge) probe();
    draw();
}

pub fn update() void {
    const c = cart.controls.*;
    if (c.a and !last.a) {
        if (on_badge) {
            if (page == 2) runWriteTest() else probe();
        }
        draw();
    }
    if (c.b and !last.b) {
        page = if (page + 1 == page_count) 0 else page + 1;
        draw();
    }
    last = c;
}
