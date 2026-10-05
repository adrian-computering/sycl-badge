//! save-test: exercises the cart save ABI (fork/CART_SAVES.md).
//!
//! - Boot counter ("save-test/boot") that survives power-off.
//! - Write 1 KB / 32 KB / 64 KB patterned blobs and show the elapsed ms.
//! - Verify reads every test blob back and checks its pattern.
//! - List keys, delete the test blobs, show store stats.
//! - Exit hook: registered at start; on Start+Select -> Exit Cart it saves
//!   "save-test/exit" and calls exit_ready(). The next boot shows
//!   "saved on exit" (and deletes the marker).
//! - On firmware without saves: "SAVES UNSUPPORTED".
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

const key_boot = "save-test/boot";
const key_exit = "save-test/exit";

const Blob = struct { key: []const u8, size: u32, label: []const u8 };
const blobs = [_]Blob{
    .{ .key = "save-test/1k", .size = 1024, .label = "1k" },
    .{ .key = "save-test/32k", .size = 32 * 1024, .label = "32k" },
    .{ .key = "save-test/64k", .size = 64 * 1024, .label = "64k" },
};

const Action = enum(u8) { write_1k, write_32k, write_64k, verify, list, delete, stat };
const action_labels = [_][]const u8{ "Write 1 KB", "Write 32 KB", "Write 64 KB", "Verify blobs", "List keys", "Delete blobs", "Stat" };

var supported: bool = false;
var boot_count: u32 = 0;
var boot_line: [24]u8 = undefined;
var boot_line_len: usize = 0;
var exit_line: []const u8 = "";
var exit_line_color: cart.DisplayColor = gray;
var exiting: bool = false;

var selected: usize = 0;
var last_controls: cart.Controls = .none;

/// Output area: up to 6 lines of 20 chars.
const out_lines = 6;
var out: [out_lines][20]u8 = undefined;
var out_len: [out_lines]usize = @splat(0);
var out_color: [out_lines]cart.DisplayColor = @splat(white);
var out_count: usize = 0;

var big: [64 * 1024]u8 align(4) = undefined;
var list_buf: [cart.save_max_entries]cart.SaveListEntry = undefined;

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

fn fmtLen(buf: []u8, comptime fmt: []const u8, args: anytype) usize {
    const s = std.fmt.bufPrint(buf, fmt, args) catch return 0;
    return s.len;
}

fn errName(err: cart.SaveError) []const u8 {
    return switch (err) {
        error.Unsupported => "unsupported",
        error.NotFound => "not found",
        error.NoSpace => "no space",
        error.BadRequest => "bad request",
        error.BadBuffer => "bad buffer",
        error.RateLimited => "rate limited",
        error.TooBig => "too big",
        error.IoError => "io error",
        error.Busy => "busy",
    };
}

fn millisSince(t0: u64) u32 {
    return @intCast((cart.micros_since_boot() - t0) / 1000);
}

/// Byte i of a blob with this seed (bytes 0..8 hold seed and size).
fn pattern(seed: u32, i: usize) u8 {
    const x: u32 = @truncate(i);
    return @truncate((x *% 31) +% (seed *% 7) +% (x >> 9) +% (seed >> 8));
}

fn fill(seed: u32, buf: []u8) void {
    std.mem.writeInt(u32, buf[0..4], seed, .little);
    std.mem.writeInt(u32, buf[4..8], @intCast(buf.len), .little);
    for (buf[8..], 8..) |*b, i| b.* = pattern(seed, i);
}

fn check(buf: []const u8) bool {
    if (buf.len < 8) return false;
    const seed = std.mem.readInt(u32, buf[0..4], .little);
    if (std.mem.readInt(u32, buf[4..8], .little) != buf.len) return false;
    for (buf[8..], 8..) |b, i| if (b != pattern(seed, i)) return false;
    return true;
}

pub fn start() void {
    cart.set_double_buffer_mode(.{ .clear_full_frame = .rgb(0) });

    supported = cart.save_supported();
    if (!supported) return;

    // Boot counter.
    var word: [4]u8 = undefined;
    if (cart.save_read(key_boot, &word)) |n| {
        boot_count = if (n == 4) std.mem.readInt(u32, &word, .little) else 0;
    } else |_| {
        boot_count = 0;
    }
    boot_count +%= 1;
    std.mem.writeInt(u32, &word, boot_count, .little);
    const t0 = cart.micros_since_boot();
    if (cart.save_write(key_boot, &word)) {
        boot_line_len = fmtLen(&boot_line, "Boot #{d} ({d} ms)", .{ boot_count, millisSince(t0) });
    } else |err| {
        boot_line_len = fmtLen(&boot_line, "Boot #{d}: {s}", .{ boot_count, errName(err) });
    }

    // Did the previous run save on exit?
    var marker: [32]u8 = undefined;
    if (cart.save_read(key_exit, &marker)) |_| {
        exit_line = "Last exit: saved";
        exit_line_color = green;
        cart.save_delete(key_exit) catch {};
    } else |err| {
        exit_line = if (err == error.NotFound) "Last exit: not saved" else "Last exit: read err";
        exit_line_color = gray;
    }

    if (cart.save_watch_exit()) {
        say(gray, "exit hook on", .{});
    } else |err| {
        say(red, "exit hook: {s}", .{errName(err)});
    }
    cart.trace(boot_line[0..boot_line_len]);
}

fn run(action: Action) void {
    clearOut();
    switch (action) {
        .write_1k, .write_32k, .write_64k => {
            const b = blobs[@backingInt(action)];
            const buf = big[0..b.size];
            fill(@truncate(cart.micros_since_boot()), buf);
            const t0 = cart.micros_since_boot();
            if (cart.save_write(b.key, buf)) {
                say(green, "{s}: ok {d} ms", .{ b.label, millisSince(t0) });
            } else |err| {
                say(red, "{s}: {s}", .{ b.label, errName(err) });
            }
        },
        .verify => {
            for (blobs) |b| {
                const t0 = cart.micros_since_boot();
                if (cart.save_read(b.key, &big)) |n| {
                    if (n == b.size and check(big[0..n]))
                        say(green, "{s}: ok {d} ms", .{ b.label, millisSince(t0) })
                    else
                        say(red, "{s}: BAD ({d} B)", .{ b.label, n });
                } else |err| {
                    say(if (err == error.NotFound) gray else red, "{s}: {s}", .{ b.label, errName(err) });
                }
            }
        },
        .list => {
            if (cart.save_list(&list_buf)) |n| {
                if (n == 0) say(gray, "(no keys)", .{});
                for (list_buf[0..n]) |e| {
                    const k = e.key[0..@min(e.key_len, e.key.len)];
                    say(white, "{s} {d}", .{ k[0..@min(k.len, 13)], e.size });
                }
            } else |err| say(red, "list: {s}", .{errName(err)});
        },
        .delete => {
            for (blobs) |b| {
                if (cart.save_delete(b.key)) {
                    say(green, "{s}: deleted", .{b.label});
                } else |err| {
                    say(if (err == error.NotFound) gray else red, "{s}: {s}", .{ b.label, errName(err) });
                }
            }
        },
        .stat => {
            if (cart.save_stat()) |s| {
                say(white, "free {d} KB", .{s.free_bytes / 1024});
                say(white, "keys {d}/{d}", .{ s.entries, s.max_entries });
                say(white, "writes left {d}", .{s.writes_left_now});
                say(gray, "data {d} KB v{d}", .{ s.region_bytes / 1024, s.version });
            } else |err| say(red, "stat: {s}", .{errName(err)});
        },
    }
}

fn text(str: []const u8, x: i32, row: i32, color: cart.DisplayColor) void {
    cart.text(.{ .str = str, .x = x, .y = row * 8, .text_color = color });
}

pub fn update() void {
    if (!supported) {
        text("SAVES UNSUPPORTED", 12, 5, red);
        text("This OS has no", 24, 7, white);
        text("cart saves. Flash", 12, 8, white);
        text("sycl-os-saves.uf2", 12, 9, yellow);
        return;
    }

    if (cart.exit_requested() and !exiting) {
        exiting = true;
        var msg: [32]u8 = undefined;
        const s = msg[0..fmtLen(&msg, "exited cleanly, boot {d}", .{boot_count})];
        clearOut();
        if (cart.save_write(key_exit, s)) {
            say(green, "saved on exit", .{});
        } else |err| {
            say(red, "exit save: {s}", .{errName(err)});
        }
        cart.exit_ready();
    }

    const c = cart.controls.*;
    const pressed: cart.Controls = @fromBackingInt(@backingInt(c) & ~@backingInt(last_controls));
    last_controls = c;
    if (!exiting) {
        if (pressed.up) selected = if (selected == 0) action_labels.len - 1 else selected - 1;
        if (pressed.down) selected = (selected + 1) % action_labels.len;
        if (pressed.a) run(@fromBackingInt(@as(u8, @intCast(selected))));
    }

    text("SAVE TEST", 0, 0, cyan);
    text(boot_line[0..boot_line_len], 0, 1, white);
    text(exit_line, 0, 2, exit_line_color);
    for (action_labels, 0..) |label, i| {
        const row: i32 = 3 + @as(i32, @intCast(i));
        const sel = i == selected;
        if (sel) text(">", 0, row, yellow);
        text(label, 8, row, if (sel) yellow else white);
    }
    for (0..out_count) |i| {
        text(out[i][0..out_len[i]], 0, 10 + @as(i32, @intCast(i)), out_color[i]);
    }
}
