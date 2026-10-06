//! file-test: exercises the cart files ABI (fork/CART_FILES.md).
//!
//! - Shows the ABI version, whether a USB host has the drive, and free space
//!   and root directory entries per volume.
//! - Writes a small text file or a 100 KB file to volume 0 (SYCLBADGE) or 1
//!   (SYCLEXTRA), named file-test-N.txt / file-test-100k-N.txt (the first N
//!   not taken), and shows the ms for create, writes and commit.
//! - "Create + abort" checks an aborted file leaves free space unchanged.
//! - On firmware without cart files: "CART FILES UNSUPPORTED".
//!
//! Controls: Up/Down pick an action, A runs it.
const std = @import("std");
const cart = @import("cart-api");

comptime {
    cart.export_start_code();
}

const white: cart.DisplayColor = .rgb(0xFFFFFF);
const gray: cart.DisplayColor = .rgb(0x808080);
const yellow: cart.DisplayColor = .rgb(0xFFFF00);
const green: cart.DisplayColor = .rgb(0x00FF40);
const red: cart.DisplayColor = .rgb(0xFF4040);
const cyan: cart.DisplayColor = .rgb(0x00FFFF);

const Action = enum(u8) { small0, big0, small1, big1, abort0, refresh };
const action_labels = [_][]const u8{ "Small file vol 0", "100 KB file vol 0", "Small file vol 1", "100 KB file vol 1", "Create + abort", "Refresh" };

const big_size: u32 = 100 * 1024;

var supported = false;
var version: u32 = 0;
var selected: usize = 0;
var last_controls: cart.Controls = .none;
var last_refresh_us: u64 = 0;

/// Status lines: up to 6 of 20 chars.
const out_lines = 6;
var out: [out_lines][20]u8 = undefined;
var out_len: [out_lines]usize = @splat(0);
var out_color: [out_lines]cart.DisplayColor = @splat(white);
var out_count: usize = 0;

var vol_line: [2][32]u8 = undefined;
var vol_line_len: [2]usize = @splat(0);
var vol_color: [2]cart.DisplayColor = @splat(gray);

var chunk: [4096]u8 align(4) = undefined;

fn clearOut() void {
    out_count = 0;
}

fn say(color: cart.DisplayColor, comptime fmt: []const u8, args: anytype) void {
    if (out_count >= out_lines) return;
    const s = std.fmt.bufPrint(&out[out_count], fmt, args) catch out[out_count][0..];
    out_len[out_count] = s.len;
    out_color[out_count] = color;
    out_count += 1;
}

fn errName(err: cart.FileError) []const u8 {
    return switch (err) {
        error.Unsupported => "unsupported",
        error.Exists => "exists",
        error.NoSpace => "no space",
        error.DirFull => "dir full",
        error.BadRequest => "bad request",
        error.BadBuffer => "bad buffer",
        error.BadName => "bad name",
        error.UsbHost => "UNPLUG USB",
        error.Busy => "busy",
        error.NoVolume => "no volume",
        error.NotOpen => "not open",
        error.IoError => "io error",
    };
}

fn millisSince(t0: u64) u32 {
    return @intCast((cart.micros_since_boot() - t0) / 1000);
}

fn refresh() void {
    version = cart.file_probe() catch 0;
    for (0..2) |v| {
        const line = &vol_line[v];
        if (cart.file_stat(@intCast(v))) |st| {
            vol_line_len[v] = (std.fmt.bufPrint(line, "v{d} {d}K free {d} ent", .{ v, st.free_bytes / 1024, st.free_root_entries }) catch @as([]u8, line[0..0])).len;
            vol_color[v] = white;
        } else |err| {
            vol_line_len[v] = (std.fmt.bufPrint(line, "v{d} {s}", .{ v, errName(err) }) catch @as([]u8, line[0..0])).len;
            vol_color[v] = gray;
        }
    }
    last_refresh_us = cart.micros_since_boot();
}

/// Line i (from 1) of the 100 KB file: 32 bytes, so a host can check it.
fn bigLine(i: u32, dst: *[32]u8) void {
    _ = std.fmt.bufPrint(dst, "file-test 100k line {d:0>6} ok.\r\n", .{i}) catch unreachable;
}

fn fillBig(offset: u32, dst: []u8) void {
    var line: [32]u8 = undefined;
    for (dst, 0..) |*b, k| {
        const at = offset + @as(u32, @intCast(k));
        if (at % 32 == 0 or k == 0) bigLine(at / 32 + 1, &line);
        b.* = line[at % 32];
    }
}

/// Creates the first free name from `fmt` (N = 1..99).
fn createFree(volume: u8, comptime fmt: []const u8, size: u32, name_out: *[32]u8) cart.FileError![]const u8 {
    var n: u32 = 1;
    while (n < 100) : (n += 1) {
        const name = std.fmt.bufPrint(name_out, fmt, .{n}) catch unreachable;
        cart.file_create(volume, name, size) catch |err| switch (err) {
            error.Exists => continue,
            else => return err,
        };
        return name;
    }
    return error.Exists;
}

fn writeTest(volume: u8, big: bool) void {
    clearOut();
    var name_buf: [32]u8 = undefined;
    var text_buf: [96]u8 = undefined;
    const msg = std.fmt.bufPrint(&text_buf, "Hello from file-test on volume {d}.\r\nBoot time {d} ms.\r\n", .{ volume, cart.micros_since_boot() / 1000 }) catch unreachable;
    const size: u32 = if (big) big_size else @intCast(msg.len);

    const t0 = cart.micros_since_boot();
    const created = if (big)
        createFree(volume, "file-test-100k-{d}.txt", size, &name_buf)
    else
        createFree(volume, "file-test-{d}.txt", size, &name_buf);
    const name = created catch |err| {
        say(red, "create: {s}", .{errName(err)});
        return;
    };
    const t_create = millisSince(t0);
    say(white, "{s}", .{name[0..@min(name.len, 20)]});

    const t1 = cart.micros_since_boot();
    var off: u32 = 0;
    while (off < size) {
        const n: u32 = @min(size - off, chunk.len);
        if (big) fillBig(off, chunk[0..n]) else @memcpy(chunk[0..n], msg[off..][0..n]);
        cart.file_write(off, chunk[0..n]) catch |err| {
            say(red, "write@{d}: {s}", .{ off, errName(err) });
            cart.file_abort() catch {};
            return;
        };
        off += n;
    }
    const t_write = millisSince(t1);

    const t2 = cart.micros_since_boot();
    cart.file_commit() catch |err| {
        say(red, "commit: {s}", .{errName(err)});
        cart.file_abort() catch {};
        return;
    };
    const t_commit = millisSince(t2);
    say(green, "ok {d} B {d} ms", .{ size, millisSince(t0) });
    say(white, "cr {d} wr {d} co {d}", .{ t_create, t_write, t_commit });
    if (big) say(gray, "{d} ms per 4 KB", .{t_write * 4096 / size});
    refresh();
}

fn abortTest() void {
    clearOut();
    const before = cart.file_stat(0) catch |err| {
        say(red, "stat: {s}", .{errName(err)});
        return;
    };
    var name_buf: [32]u8 = undefined;
    _ = createFree(0, "file-test-abort-{d}.bin", 20_000, &name_buf) catch |err| {
        say(red, "create: {s}", .{errName(err)});
        return;
    };
    const during = cart.file_stat(0) catch before;
    chunk[0] = 'x';
    cart.file_write(0, chunk[0..4096]) catch |err| say(red, "write: {s}", .{errName(err)});
    cart.file_abort() catch |err| say(red, "abort: {s}", .{errName(err)});
    const after = cart.file_stat(0) catch before;
    say(white, "free {d}/{d}/{d}K", .{ before.free_bytes / 1024, during.free_bytes / 1024, after.free_bytes / 1024 });
    const ok = after.free_bytes == before.free_bytes and after.free_root_entries == before.free_root_entries and
        during.free_bytes + 20_480 == before.free_bytes;
    say(if (ok) green else red, "abort {s}", .{if (ok) "ok" else "MISMATCH"});
    // No commit: a second abort has nothing to drop.
    if (cart.file_abort()) say(red, "2nd abort: ok?", .{}) else |err| say(if (err == error.NotOpen) green else red, "2nd abort: {s}", .{errName(err)});
}

fn run(action: Action) void {
    switch (action) {
        .small0 => writeTest(0, false),
        .big0 => writeTest(0, true),
        .small1 => writeTest(1, false),
        .big1 => writeTest(1, true),
        .abort0 => abortTest(),
        .refresh => {
            clearOut();
            refresh();
            say(gray, "refreshed", .{});
        },
    }
}

pub fn start() void {
    cart.set_double_buffer_mode(.{ .clear_full_frame = .rgb(0) });
    supported = cart.cart_files();
    if (supported) refresh();
}

fn text(str: []const u8, x: i32, row: i32, color: cart.DisplayColor) void {
    cart.text(.{ .str = str, .x = x, .y = row * 8, .text_color = color });
}

pub fn update() void {
    if (!supported) {
        text("CART FILES", 24, 4, red);
        text("UNSUPPORTED", 20, 5, red);
        text("This OS can't write", 4, 7, white);
        text("files. Flash the", 4, 8, white);
        text("cart-files OS.", 4, 9, yellow);
        return;
    }

    // The USB host flag comes with every reply: re-probe once a second.
    if (cart.micros_since_boot() - last_refresh_us > 1_000_000) {
        version = cart.file_probe() catch 0;
        last_refresh_us = cart.micros_since_boot();
    }

    const c = cart.controls.*;
    const pressed: cart.Controls = @fromBackingInt(@backingInt(c) & ~@backingInt(last_controls));
    last_controls = c;
    if (pressed.up) selected = if (selected == 0) action_labels.len - 1 else selected - 1;
    if (pressed.down) selected = (selected + 1) % action_labels.len;
    if (pressed.a) run(@fromBackingInt(@as(u8, @intCast(selected))));

    const flags = cart.file_flags();
    var head: [20]u8 = undefined;
    text("FILE TEST", 0, 0, cyan);
    text((std.fmt.bufPrint(&head, "v{d}", .{version}) catch @as([]u8, head[0..0])), 80, 0, gray);
    text(if (flags.usb_host) "USB HOST: unplug" else "USB host: no", 0, 1, if (flags.usb_host) red else green);
    for (0..2) |v| text(vol_line[v][0..vol_line_len[v]], 0, 2 + @as(i32, @intCast(v)), vol_color[v]);
    for (action_labels, 0..) |label, i| {
        const row: i32 = 4 + @as(i32, @intCast(i));
        const sel = i == selected;
        if (sel) text(">", 0, row, yellow);
        text(label, 8, row, if (sel) yellow else white);
    }
    for (0..out_count) |i| {
        text(out[i][0..out_len[i]], 0, 10 + @as(i32, @intCast(i)), out_color[i]);
    }
}
