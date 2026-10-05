//! Serial echo: the smallest `cart.serial` example.
//!
//! Every byte the host sends comes straight back, and the last line received
//! is shown on screen. Try it with `badge monitor`, any serial terminal on the
//! "SYCL Badge Cart Serial" port, or in the simulator:
//!
//!     zig-out/sim/serial-echo            # prints cart serial: tcp://127.0.0.1:7341
//!     nc 127.0.0.1 7341                  # type a line, see it echoed
//!
//! On stock firmware the port is unsupported and the cart says so.

const std = @import("std");
const cart = @import("cart-api");

comptime {
    cart.export_start_code();
}

const bg: cart.DisplayColor = .rgb(0x101820);
const fg: cart.DisplayColor = .rgb(0xE0E0E0);
const dim: cart.DisplayColor = .rgb(0x708090);
const good: cart.DisplayColor = .rgb(0x40D070);
const bad: cart.DisplayColor = .rgb(0xE05050);
const accent: cart.DisplayColor = .rgb(0xF0C040);

const line_chars = cart.screen_width / cart.font_width; // 20

var open_error: bool = false;
var rx_total: u32 = 0;
var tx_total: u32 = 0;
/// The line being received and the last complete one.
var partial: [64]u8 = undefined;
var partial_len: usize = 0;
var last_line: [64]u8 = undefined;
var last_line_len: usize = 0;

pub fn start() void {
    cart.set_double_buffer_mode(.{ .clear_full_frame = bg });
    cart.serial.open() catch {
        open_error = true;
    };
}

pub fn update() void {
    // Echo everything, a chunk at a time, never more than the host can take.
    var buf: [256]u8 = undefined;
    while (true) {
        const room = @min(buf.len, cart.serial.space_available());
        if (room == 0) break;
        const n = cart.serial.read(buf[0..room]);
        if (n == 0) break;
        rx_total +%= @intCast(n);
        tx_total +%= @intCast(cart.serial.write(buf[0..n]));
        for (buf[0..n]) |c| collect(c);
    }

    draw();
}

fn collect(c: u8) void {
    if (c == '\n' or c == '\r') {
        if (partial_len > 0 or c == '\n') {
            @memcpy(last_line[0..partial_len], partial[0..partial_len]);
            last_line_len = partial_len;
        }
        partial_len = 0;
    } else if (partial_len < partial.len) {
        partial[partial_len] = if (c >= 0x20 and c < 0x7F) c else '.';
        partial_len += 1;
    }
}

fn draw() void {
    text("SERIAL ECHO", 0, 2, accent);

    if (!cart.serial.supported()) {
        text("Needs fork", 0, 24, bad);
        text("firmware", 0, 34, bad);
        text("(no cart serial", 0, 54, dim);
        text(" port on stock", 0, 64, dim);
        text(" firmware)", 0, 74, dim);
        return;
    }

    flag("supported", true, 18);
    flag("open", cart.serial.is_open(), 28);
    flag("connected", cart.serial.connected(), 38);

    var tmp: [line_chars + 1]u8 = undefined;
    text(std.fmt.bufPrint(&tmp, "rx {d}", .{rx_total}) catch "", 0, 52, fg);
    text(std.fmt.bufPrint(&tmp, "tx {d}", .{tx_total}) catch "", 80, 52, fg);

    text("last line:", 0, 68, dim);
    // Wrap the line over up to four rows.
    var y: i32 = 80;
    var rest = last_line[0..last_line_len];
    while (rest.len > 0 and y < 120) : (y += 10) {
        const n = @min(rest.len, line_chars - 1);
        text(rest[0..n], 0, y, fg);
        rest = rest[n..];
    }
    if (last_line_len == 0) {
        text(if (cart.serial.connected()) "(send a line)" else "(connect a host)", 0, 80, dim);
    }
}

fn flag(label: []const u8, on: bool, y: i32) void {
    text(label, 0, y, fg);
    text(if (on) "yes" else "no", 112, y, if (on) good else bad);
}

fn text(str: []const u8, x: i32, y: i32, color: cart.DisplayColor) void {
    cart.text(.{ .str = str, .x = x + 4, .y = y, .text_color = color });
}
