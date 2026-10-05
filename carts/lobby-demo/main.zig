//! Lobby demo: every badge in the room is a colored square.
//!
//! Plug badges into one computer, run `badge lobby`, start this cart on each
//! and move your square with the d-pad; everyone sees everyone move. Press A
//! to show the roster. Up to 16 players per room.
//!
//! This is the reference for `cart.lobby` (src/os/cart/lobby.zig):
//!
//! - `start()` creates the client, which opens the cart serial port and joins
//!   automatically whenever a lobby is connected.
//! - `update()` drains `lobby.poll()` events, then broadcasts our position
//!   (on change, at most 25 times a second, plus a heartbeat every second so
//!   late joiners see idle players).
//! - The screen shows `lobby.state()` in plain words, including "Needs fork
//!   firmware" on stock firmware, where the cart still runs single player.
//!
//! In the simulator, run two copies and a lobby on the same machine:
//!
//!     zig-out/sim/lobby-demo & zig-out/sim/lobby-demo &
//!     badge lobby
//!
//! Wire format of our DATA messages: `'P', x, y` (field coordinates).

const std = @import("std");
const cart = @import("cart-api");
const Lobby = cart.lobby;

comptime {
    cart.export_start_code();
}

// ┌───────────────────────────────────────────────────────────────────────────┐
// │ Layout and colors                                                         │
// └───────────────────────────────────────────────────────────────────────────┘

const status_h = 11;
const field_y = status_h + 1;
const field_w = cart.screen_width;
const field_h = cart.screen_height - field_y;
const square = 10;
const max_x = field_w - square;
const max_y = field_h - square;
const speed = 2;

const bg: cart.DisplayColor = .rgb(0x0B1020);
const grid: cart.DisplayColor = .rgb(0x182038);
const bar_bg: cart.DisplayColor = .rgb(0x202A48);
const fg: cart.DisplayColor = .rgb(0xE8ECF4);
const dim: cart.DisplayColor = .rgb(0x8090B0);
const warn: cart.DisplayColor = .rgb(0xF0B040);
const bad: cart.DisplayColor = .rgb(0xF06060);
const good: cart.DisplayColor = .rgb(0x60E090);
const black: cart.DisplayColor = .rgb(0x000000);
const white: cart.DisplayColor = .rgb(0xFFFFFF);

/// One color per player id.
const palette = [Lobby.max_players]cart.DisplayColor{
    .rgb(0xFF5A5A), .rgb(0x5AA0FF), .rgb(0x60E070), .rgb(0xFFD040),
    .rgb(0xC070FF), .rgb(0x40E0E0), .rgb(0xFF9030), .rgb(0xFF70C0),
    .rgb(0xA0E040), .rgb(0x7080FF), .rgb(0xE0E0E0), .rgb(0x30B090),
    .rgb(0xD0A070), .rgb(0xB0B0FF), .rgb(0xFF4090), .rgb(0x90C0C0),
};

fn color_of(id: u8) cart.DisplayColor {
    return palette[id % palette.len];
}

// ┌───────────────────────────────────────────────────────────────────────────┐
// │ State                                                                     │
// └───────────────────────────────────────────────────────────────────────────┘

var lobby: Lobby.Client = undefined;
var name_buf: [Lobby.name_len]u8 = undefined;
var my_name: []const u8 = "";

const Square = struct {
    x: u8,
    y: u8,
    /// We have heard from this player (else it sits at its spawn point).
    known: bool = false,
};

/// Everyone's squares by player id, ours included once joined.
var squares: [Lobby.max_players]Square = undefined;

/// Our own position (also used single player, before joining).
var my_x: u8 = max_x / 2;
var my_y: u8 = max_y / 2;
var sent_x: u8 = 0xFF;
var sent_y: u8 = 0xFF;
var last_send_us: u64 = 0;
var force_send = false;

var show_roster = false;
var a_was_down = false;

pub fn start() void {
    cart.set_double_buffer_mode(.{ .clear_full_frame = bg });

    // A short random name. Real games might let the player pick one.
    const seed = cart.rand() ^ @as(u32, @truncate(cart.micros_since_boot() *% 2654435761));
    my_name = std.fmt.bufPrint(&name_buf, "DOT-{X:0>3}", .{@as(u12, @truncate(seed))}) catch unreachable;

    lobby = .init(.{ .game = "DOTS", .name = my_name, .max_players = Lobby.max_players });
    for (&squares, 0..) |*s, id| s.* = spawn_point(@intCast(id));
}

pub fn update() void {
    handle_events();
    move();
    send_position();

    const a = cart.controls.a;
    if (a and !a_was_down) show_roster = !show_roster;
    a_was_down = a;

    draw();
}

fn handle_events() void {
    while (lobby.poll()) |event| switch (event) {
        .joined => |j| {
            // A fresh room: forget everyone, start at our spawn point.
            for (&squares, 0..) |*s, id| s.* = spawn_point(@intCast(id));
            my_x = squares[j.you].x;
            my_y = squares[j.you].y;
            force_send = true;
        },
        .roster => {
            // Players who left go back to their spawn point for whoever
            // takes their id next. Newcomers need our position.
            for (&squares, 0..) |*s, id| {
                if (lobby.player(@intCast(id)) == null) s.* = spawn_point(@intCast(id));
            }
            force_send = true;
        },
        .data => |d| {
            if (d.bytes.len == 3 and d.bytes[0] == 'P' and d.from < squares.len) {
                squares[d.from] = .{
                    .x = @min(d.bytes[1], max_x),
                    .y = @min(d.bytes[2], max_y),
                    .known = true,
                };
            }
        },
        .left, .host_error => {},
    };
}

fn move() void {
    const c = cart.controls;
    if (c.left) my_x -|= speed;
    if (c.right) my_x = @min(my_x +| speed, max_x);
    if (c.up) my_y -|= speed;
    if (c.down) my_y = @min(my_y +| speed, max_y);
    if (lobby.you()) |id| squares[id] = .{ .x = my_x, .y = my_y, .known = true };
}

fn send_position() void {
    if (lobby.state() != .joined) return;
    const now = cart.micros_since_boot();
    const since = now -% last_send_us;
    const moved = my_x != sent_x or my_y != sent_y;
    if (!(force_send or (moved and since >= 40_000) or since >= 1_000_000)) return;

    lobby.broadcast(&.{ 'P', my_x, my_y }) catch return; // retry next frame
    sent_x = my_x;
    sent_y = my_y;
    last_send_us = now;
    force_send = false;
}

fn spawn_point(id: u8) Square {
    // A 4x4 grid of starting spots.
    const col: u32 = id % 4;
    const row: u32 = id / 4;
    return .{
        .x = @intCast(12 + col * (max_x - 24) / 3),
        .y = @intCast(8 + row * (max_y - 16) / 3),
    };
}

// ┌───────────────────────────────────────────────────────────────────────────┐
// │ Drawing                                                                   │
// └───────────────────────────────────────────────────────────────────────────┘

fn draw() void {
    draw_grid();

    switch (lobby.state()) {
        .joined => {
            const me = lobby.you().?;
            for (lobby.players()) |p| {
                if (p.id != me and p.id < squares.len) draw_square(p.id, squares[p.id], false);
            }
            draw_square(me, squares[me], true);
        },
        // Single player: just our own square, in neutral white.
        else => draw_plain_square(my_x, my_y),
    }

    draw_status();
    if (show_roster) draw_roster();
}

fn draw_grid() void {
    var x: i32 = 0;
    while (x < field_w) : (x += 20) cart.vline(.{ .x = x, .y = field_y, .len = field_h, .color = grid });
    var y: i32 = field_y;
    while (y < cart.screen_height) : (y += 20) cart.hline(.{ .x = 0, .y = y, .len = field_w, .color = grid });
}

fn draw_square(id: u8, s: Square, mine: bool) void {
    const x: i32 = s.x;
    const y: i32 = @as(i32, s.y) + field_y;
    if (mine) cart.rect(.{ .x = x - 2, .y = y - 2, .width = square + 4, .height = square + 4, .stroke_color = white });
    cart.rect(.{ .x = x, .y = y, .width = square, .height = square, .fill_color = color_of(id), .stroke_color = if (s.known) null else black });
    cart.text(.{ .str = hex_digit(id), .x = x + 1, .y = y + 1, .text_color = black });
}

fn hex_digit(id: u8) []const u8 {
    return "0123456789ABCDEF"[id & 0xF ..][0..1];
}

fn draw_plain_square(x: u8, y: u8) void {
    cart.rect(.{ .x = x, .y = @as(i32, y) + field_y, .width = square, .height = square, .fill_color = white });
}

fn draw_status() void {
    cart.rect(.{ .x = 0, .y = 0, .width = cart.screen_width, .height = status_h, .fill_color = bar_bg });
    var buf: [24]u8 = undefined;
    switch (lobby.state()) {
        .unsupported => status_text("Needs fork firmware", bad),
        .waiting_for_host => status_text("Run: badge lobby", warn),
        .joining => status_text("Joining lobby...", warn),
        .joined => {
            const me = lobby.you().?;
            cart.rect(.{ .x = 2, .y = 2, .width = 7, .height = 7, .fill_color = color_of(me) });
            const left = std.fmt.bufPrint(&buf, "P{X} {d}/16", .{ me, lobby.players().len }) catch "";
            cart.text(.{ .str = left, .x = 12, .y = 2, .text_color = fg });
            if (lobby.ping_ms()) |ms| {
                const right = std.fmt.bufPrint(&buf, "{d}ms", .{@min(ms, 9999)}) catch "";
                cart.text(.{ .str = right, .x = @intCast(cart.screen_width - 2 - right.len * 8), .y = 2, .text_color = good });
            }
        },
    }
}

fn status_text(str: []const u8, color: cart.DisplayColor) void {
    cart.text(.{ .str = str, .x = 2, .y = 2, .text_color = color });
}

fn draw_roster() void {
    const panel_x = 4;
    const panel_y = field_y + 4;
    const row_h = 11;
    cart.rect(.{ .x = panel_x, .y = panel_y, .width = cart.screen_width - 8, .height = 14 + 8 * row_h, .fill_color = bar_bg, .stroke_color = dim });

    if (lobby.state() != .joined) {
        cart.text(.{ .str = "Not in a room", .x = panel_x + 4, .y = panel_y + 4, .text_color = dim });
        cart.text(.{ .str = my_name, .x = panel_x + 4, .y = panel_y + 18, .text_color = fg });
        return;
    }
    cart.text(.{ .str = "ROSTER    A: close", .x = panel_x + 4, .y = panel_y + 3, .text_color = dim });

    // Two columns of eight.
    const me = lobby.you().?;
    for (lobby.players(), 0..) |p, i| {
        const col: i32 = @intCast(i / 8);
        const row: i32 = @intCast(i % 8);
        const x = panel_x + 3 + col * 74;
        const y = panel_y + 14 + row * row_h;
        if (p.id == me) cart.rect(.{ .x = x - 1, .y = y - 1, .width = 72, .height = 10, .fill_color = .rgb(0x405080) });
        // The swatch carries the id, like the squares on the field.
        cart.rect(.{ .x = x, .y = y - 1, .width = square, .height = square, .fill_color = color_of(p.id) });
        cart.text(.{ .str = hex_digit(p.id), .x = x + 1, .y = y, .text_color = black });
        const name = p.name();
        cart.text(.{ .str = name[0..@min(name.len, 7)], .x = x + square + 2, .y = y, .text_color = if (p.id == me) white else fg });
    }
}
