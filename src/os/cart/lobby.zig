//! Multiplayer lobby for carts (fork firmware, see fork/CART_SERIAL.md).
//!
//! Plug several badges into one computer, run `badge lobby` there, and every
//! badge running your cart joins the same room. The lobby relays messages
//! between the players; your cart decides what the messages mean.
//!
//!     const cart = @import("cart-api");
//!
//!     var lobby: cart.lobby.Client = undefined;
//!
//!     pub fn start() void {
//!         lobby = .init(.{ .game = "DOTS", .name = "player" });
//!     }
//!
//!     pub fn update() void {
//!         while (lobby.poll()) |event| switch (event) {
//!             .joined => |j| { _ = j; },   // j.you = your player id
//!             .roster => {},               // lobby.players() changed
//!             .data => |d| { _ = d; },     // d.from sent you d.bytes
//!             else => {},
//!         };
//!         lobby.broadcast(&my_state_bytes) catch {};
//!     }
//!
//! Everything here is non-blocking and allocation-free; call `poll()` every
//! update(). On stock firmware `state()` is `.unsupported` and every send fails
//! with `error.NotJoined`, so the same cart runs single player there.
//!
//! What you get from the lobby:
//!
//! - A player id (`you()`, 0..max_players-1), fixed while you stay connected.
//! - The room roster (`players()`), sent again after every join and leave.
//! - Messages: `send(to, bytes)` to one player, `broadcast(bytes)` to everyone
//!   else, `broadcast_with_echo(bytes)` to everyone including yourself. Up to
//!   240 bytes each. They arrive in order and are never dropped while you are
//!   connected, and every player in a room sees the room's messages in the
//!   same global order. The lobby never invents game data: if your game needs
//!   an authority, pick one (for example the lowest player id).
//! - Round-trip latency to the host (`ping_ms()`).
//!
//! Joining is automatic: the client says HELLO when the port opens and again
//! whenever the host (re)connects, so a lobby restart or a replugged cable
//! heals by itself; you get a fresh `.joined` event each time.
//!
//! `Framer` is the message framing on its own (COBS, 0x00-delimited), for
//! carts that talk to their own host program instead of `badge lobby`.

const std = @import("std");

// ┌───────────────────────────────────────────────────────────────────────────┐
// │ Protocol constants (lobby protocol v1)                                    │
// └───────────────────────────────────────────────────────────────────────────┘

pub const protocol_version: u8 = 1;

/// Largest frame body (type byte + payload).
pub const max_body_len = 250;
/// Largest payload of `send()` and the like.
pub const max_data_len = 240;
/// Largest room the lobby makes.
pub const max_players = 16;
/// Game ids are up to 8 ASCII characters, names up to 12.
pub const game_len = 8;
pub const name_len = 12;

/// `send()` target meaning every other player in the room.
pub const everyone_else: u8 = 0xFF;
/// `send()` target meaning every player in the room, the sender included.
pub const everyone: u8 = 0xFE;

pub const msg = struct {
    // cart -> host
    pub const hello: u8 = 0x01;
    pub const send: u8 = 0x02;
    pub const ping: u8 = 0x03;
    pub const leave: u8 = 0x04;
    // host -> cart
    pub const welcome: u8 = 0x81;
    pub const roster: u8 = 0x82;
    pub const data: u8 = 0x83;
    pub const pong: u8 = 0x84;
    pub const @"error": u8 = 0x8F;
};

/// Codes of the host's ERROR message.
pub const ErrorCode = enum(u8) {
    unsupported_version = 1,
    /// The lobby is full.
    no_room = 2,
    /// SEND or LEAVE before WELCOME (the lobby does not know this badge).
    not_joined = 3,
    malformed = 4,
    _,
};

// ┌───────────────────────────────────────────────────────────────────────────┐
// │ Framing                                                                   │
// └───────────────────────────────────────────────────────────────────────────┘

/// Consistent Overhead Byte Stuffing, any length. `Framer` uses these with
/// the protocol's 250-byte limit.
pub const cobs = struct {
    /// Worst-case encoded size of `n` bytes (without the 0x00 delimiter).
    pub fn max_encoded_len(n: usize) usize {
        return n + n / 254 + 1;
    }

    /// Encode `body` into `out` (at least `max_encoded_len(body.len)` bytes).
    /// The result contains no 0x00 bytes. Returns the encoded length.
    pub fn encode(body: []const u8, out: []u8) usize {
        var code_index: usize = 0;
        var code: u8 = 1;
        var o: usize = 1;
        for (body) |b| {
            if (b == 0) {
                out[code_index] = code;
                code_index = o;
                o += 1;
                code = 1;
            } else {
                out[o] = b;
                o += 1;
                code += 1;
                if (code == 0xFF) {
                    out[code_index] = code;
                    code_index = o;
                    o += 1;
                    code = 1;
                }
            }
        }
        out[code_index] = code;
        return o;
    }

    /// Decode in place. Returns the decoded length, or null when `data` is
    /// not valid COBS (contains 0x00 or a block runs past the end).
    pub fn decode(data: []u8) ?usize {
        var i: usize = 0;
        var o: usize = 0;
        while (i < data.len) {
            const code = data[i];
            if (code == 0) return null;
            i += 1;
            const end = i + code - 1;
            if (end > data.len) return null;
            for (data[i..end]) |b| {
                if (b == 0) return null;
                data[o] = b;
                o += 1;
            }
            i = end;
            if (code != 0xFF and i < data.len) {
                data[o] = 0;
                o += 1;
            }
        }
        return o;
    }
};

/// Splits a byte stream into frames and builds frames for sending.
///
/// A frame on the wire is COBS(body) followed by one 0x00. Bodies are 1-250
/// bytes. Bad frames (invalid COBS or too long) are dropped and decoding
/// resumes after the next 0x00, so a reader that starts mid-stream finds its
/// feet by itself. Empty frames are ignored.
///
///     var framer: cart.lobby.Framer = .{};
///     var buf: [64]u8 = undefined;
///     const n = cart.serial.read(&buf);
///     for (buf[0..n]) |byte| {
///         if (framer.push(byte)) |body| handle(body);
///     }
///
///     var frame: cart.lobby.Framer.Frame = undefined;
///     const bytes = try cart.lobby.Framer.encode(&.{ 0x10, 42 }, &frame);
///     _ = cart.serial.write(bytes);
pub const Framer = struct {
    /// Longest encoded frame without its delimiter.
    pub const max_encoded_len = cobs.max_encoded_len(max_body_len);
    /// Room for one encoded frame including its delimiter.
    pub const Frame = [max_encoded_len + 1]u8;

    buf: [max_encoded_len]u8 = undefined,
    len: usize = 0,
    /// Skipping an oversized frame until the next 0x00.
    overflow: bool = false,
    /// Frames dropped because they were malformed or too long.
    dropped: u32 = 0,

    /// Feed one received byte. Returns a complete frame body when `byte`
    /// ends one. The slice points into the framer and is valid until the
    /// next `push()` or `reset()`.
    pub fn push(f: *Framer, byte: u8) ?[]const u8 {
        if (byte != 0) {
            if (f.len == f.buf.len) {
                f.overflow = true;
            } else if (!f.overflow) {
                f.buf[f.len] = byte;
                f.len += 1;
            }
            return null;
        }
        const len = f.len;
        const overflow = f.overflow;
        f.len = 0;
        f.overflow = false;
        if (overflow) {
            f.dropped +%= 1;
            return null;
        }
        if (len == 0) return null; // empty frame: a delimiter flush
        const n = cobs.decode(f.buf[0..len]) orelse {
            f.dropped +%= 1;
            return null;
        };
        if (n > max_body_len) {
            f.dropped +%= 1;
            return null;
        }
        if (n == 0) return null;
        return f.buf[0..n];
    }

    /// Forget any partial frame (after a reconnect, for example).
    pub fn reset(f: *Framer) void {
        f.len = 0;
        f.overflow = false;
    }

    /// Encode `body` as one frame, delimiter included, into `out`.
    pub fn encode(body: []const u8, out: *Frame) error{TooLong}![]const u8 {
        if (body.len > max_body_len) return error.TooLong;
        const n = cobs.encode(body, out);
        out[n] = 0;
        return out[0 .. n + 1];
    }
};

// ┌───────────────────────────────────────────────────────────────────────────┐
// │ Client                                                                    │
// └───────────────────────────────────────────────────────────────────────────┘

/// The lobby client for carts: talks to `badge lobby` over `cart.serial`.
pub const Client = ClientOver(CartPort);

pub const Options = struct {
    /// Game id, up to 8 ASCII characters. Only badges with the same game id
    /// share a room, so one lobby can host several games at once.
    game: []const u8,
    /// Player name shown in rosters, up to 12 ASCII characters.
    name: []const u8,
    /// Room size, 2-16. The room takes the size its first player asks for;
    /// 0 lets the lobby choose.
    max_players: u8 = 0,
    /// How often to measure latency while joined.
    ping_interval_ms: u32 = 1000,
};

pub const State = enum {
    /// Stock firmware: no cart serial port. Hide multiplayer.
    unsupported,
    /// No lobby program has the port open. Tell the player to plug in the
    /// badge and run `badge lobby`.
    waiting_for_host,
    /// Said HELLO, waiting for WELCOME.
    joining,
    /// In a room: `you()` and `players()` are valid.
    joined,
};

pub const Player = struct {
    id: u8,
    name_buf: [name_len]u8,
    name_len: u8,

    pub fn name(p: *const Player) []const u8 {
        return p.name_buf[0..p.name_len];
    }
};

pub const Event = union(enum) {
    /// You are in a room (again). Also sent after a reconnect.
    joined: Joined,
    /// The roster changed: read `players()`.
    roster,
    /// A player sent you a message. `bytes` is valid until the next poll().
    data: Data,
    /// You are no longer in a room: the host went away. The client rejoins
    /// by itself when the host comes back.
    left,
    /// The host reported a problem (for example `.no_room` when the lobby is
    /// full; the client keeps retrying). `message` is valid until the next
    /// poll().
    host_error: HostError,

    pub const Joined = struct { you: u8, room: u8, max_players: u8 };
    pub const Data = struct { from: u8, bytes: []const u8 };
    pub const HostError = struct { code: ErrorCode, message: []const u8 };
};

pub const SendError = error{
    /// Not in a room (yet), or no fork firmware.
    NotJoined,
    /// More than `max_data_len` bytes.
    TooLong,
    /// The outgoing buffer is full because the host is not reading. Nothing
    /// was sent; try again next frame.
    QueueFull,
};

/// The default transport: the cart serial port and the badge clock.
pub const CartPort = struct {
    const api = @import("api.zig");

    pub fn open(_: CartPort) bool {
        api.serial.open() catch return false;
        return true;
    }
    pub fn connected(_: CartPort) bool {
        return api.serial.connected();
    }
    pub fn read(_: CartPort, buf: []u8) usize {
        return api.serial.read(buf);
    }
    pub fn write(_: CartPort, bytes: []const u8) usize {
        return api.serial.write(bytes);
    }
    pub fn space_available(_: CartPort) usize {
        return api.serial.space_available();
    }
    pub fn micros(_: CartPort) u64 {
        return api.micros_since_boot();
    }
};

/// A lobby client over any transport `Port` with the methods of `CartPort`
/// (open, connected, read, write, space_available, micros). Carts use
/// `Client`; this exists so the protocol logic can be tested on a host.
pub fn ClientOver(comptime Port: type) type {
    return struct {
        const Self = @This();

        const hello_retry_us = 2_000_000;

        port: Port,
        options: Options,
        current: State,
        was_connected: bool = false,
        framer: Framer = .{},
        in_buf: [128]u8 = undefined,
        in_pos: usize = 0,
        in_len: usize = 0,
        pending_left: bool = false,

        my_id: u8 = 0,
        roster_buf: [max_players]Player = undefined,
        roster_len: usize = 0,

        last_hello_us: u64 = 0,
        last_ping_us: u64 = 0,
        ping_token: u32 = 0,
        ping_outstanding: bool = false,
        last_rtt_ms: ?u32 = null,

        /// Open the cart serial port and start joining. Never fails: on
        /// stock firmware the client is simply `.unsupported`.
        pub fn init(options: Options) Self {
            return init_with_port(.{}, options);
        }

        /// `init` over a custom transport (tests, other SDKs).
        pub fn init_with_port(port: Port, options: Options) Self {
            var self: Self = .{
                .port = port,
                .options = options,
                .current = .unsupported,
            };
            if (self.port.open()) self.current = .waiting_for_host;
            return self;
        }

        /// Run the client and return the next event, or null when there is
        /// nothing more this frame. Call it in a loop every update():
        /// `while (lobby.poll()) |event| ...`.
        pub fn poll(self: *Self) ?Event {
            if (self.current == .unsupported) return null;

            const now = self.port.micros();
            const is_connected = self.port.connected();
            if (is_connected != self.was_connected) {
                self.was_connected = is_connected;
                if (is_connected) {
                    self.framer.reset();
                    self.in_pos = 0;
                    self.in_len = 0;
                    // Flush any partial frame on the host side, then join.
                    _ = self.port.write(&.{0});
                    self.say_hello(now);
                } else {
                    if (self.current == .joined) self.pending_left = true;
                    self.current = .waiting_for_host;
                    self.roster_len = 0;
                    self.ping_outstanding = false;
                }
            }
            if (self.pending_left) {
                self.pending_left = false;
                return .left;
            }
            if (!is_connected) {
                // Throw away whatever is still queued from the old host.
                while (self.port.read(&self.in_buf) > 0) {}
                return null;
            }

            switch (self.current) {
                .joining => if (now -% self.last_hello_us >= hello_retry_us) self.say_hello(now),
                .joined => if (now -% self.last_ping_us >= @as(u64, self.options.ping_interval_ms) * 1000) {
                    self.last_ping_us = now;
                    self.ping_token = @truncate(now);
                    if (self.write_message(msg.ping, &std.mem.toBytes(std.mem.nativeToLittle(u32, self.ping_token)), &.{}))
                        self.ping_outstanding = true;
                },
                else => {},
            }

            while (true) {
                if (self.in_pos == self.in_len) {
                    self.in_pos = 0;
                    self.in_len = self.port.read(&self.in_buf);
                    if (self.in_len == 0) return null;
                }
                const byte = self.in_buf[self.in_pos];
                self.in_pos += 1;
                if (self.framer.push(byte)) |body| {
                    if (self.handle(body, now)) |event| return event;
                }
            }
        }

        /// Send `bytes` to player `to` (or `everyone_else` / `everyone`).
        pub fn send(self: *Self, to: u8, bytes: []const u8) SendError!void {
            if (self.current != .joined) return error.NotJoined;
            if (bytes.len > max_data_len) return error.TooLong;
            if (!self.write_message(msg.send, &.{to}, bytes)) return error.QueueFull;
        }

        /// Send `bytes` to every other player in the room.
        pub fn broadcast(self: *Self, bytes: []const u8) SendError!void {
            return self.send(everyone_else, bytes);
        }

        /// Send `bytes` to every player in the room including yourself: you
        /// get your own message back as a `.data` event with `from == you()`,
        /// at its place in the room's global order. Use it when every badge
        /// must apply all inputs in exactly the same order, as on a shared
        /// serial line where each console hears its own bytes too (for
        /// example emulating the Lynx's ComLynx cable). Apply your own input
        /// when it comes back, not when you send it.
        pub fn broadcast_with_echo(self: *Self, bytes: []const u8) SendError!void {
            return self.send(everyone, bytes);
        }

        pub fn state(self: *const Self) State {
            return self.current;
        }

        /// Your player id, or null when not in a room.
        pub fn you(self: *const Self) ?u8 {
            return if (self.current == .joined) self.my_id else null;
        }

        /// The room's players including you, in the host's order. Empty when
        /// not in a room.
        pub fn players(self: *const Self) []const Player {
            return self.roster_buf[0..self.roster_len];
        }

        /// The roster entry for `id`, if that player is in the room.
        pub fn player(self: *const Self, id: u8) ?*const Player {
            for (self.players()) |*p| if (p.id == id) return p;
            return null;
        }

        /// Latest round trip to the host in milliseconds, null until measured.
        pub fn ping_ms(self: *const Self) ?u32 {
            return if (self.current == .joined) self.last_rtt_ms else null;
        }

        fn say_hello(self: *Self, now: u64) void {
            var payload: [1 + game_len + name_len + 1]u8 = @splat(0);
            payload[0] = protocol_version;
            copy_ascii(payload[1..][0..game_len], self.options.game);
            copy_ascii(payload[1 + game_len ..][0..name_len], self.options.name);
            payload[1 + game_len + name_len] = @min(self.options.max_players, max_players);
            _ = self.write_message(msg.hello, &payload, &.{});
            self.last_hello_us = now;
            self.current = .joining;
        }

        /// Write one frame `kind ++ head ++ tail`, or nothing when it does not
        /// fit in the transmit buffer (a partial frame would corrupt the
        /// stream).
        fn write_message(self: *Self, kind: u8, head: []const u8, tail: []const u8) bool {
            var body: [max_body_len]u8 = undefined;
            const len = 1 + head.len + tail.len;
            body[0] = kind;
            @memcpy(body[1..][0..head.len], head);
            @memcpy(body[1 + head.len ..][0..tail.len], tail);
            var frame: Framer.Frame = undefined;
            const bytes = Framer.encode(body[0..len], &frame) catch return false;
            if (self.port.space_available() < bytes.len) return false;
            return self.port.write(bytes) == bytes.len;
        }

        fn handle(self: *Self, body: []const u8, now: u64) ?Event {
            const payload = body[1..];
            switch (body[0]) {
                msg.welcome => {
                    if (payload.len < 4) return null;
                    self.my_id = payload[1];
                    self.current = .joined;
                    self.roster_len = 0;
                    // Measure latency right away.
                    self.last_ping_us = now -% @as(u64, self.options.ping_interval_ms) * 1000;
                    return .{ .joined = .{ .you = payload[1], .room = payload[2], .max_players = payload[3] } };
                },
                msg.roster => {
                    if (payload.len < 1) return null;
                    const count = @min(payload[0], max_players);
                    if (payload.len < 1 + @as(usize, count) * (1 + name_len)) return null;
                    for (0..count) |i| {
                        const entry = payload[1 + i * (1 + name_len) ..][0 .. 1 + name_len];
                        const p = &self.roster_buf[i];
                        p.id = entry[0];
                        @memcpy(&p.name_buf, entry[1..]);
                        p.name_len = @intCast(std.mem.indexOfScalar(u8, &p.name_buf, 0) orelse name_len);
                    }
                    self.roster_len = count;
                    return .roster;
                },
                msg.data => {
                    if (payload.len < 1 or self.current != .joined) return null;
                    return .{ .data = .{ .from = payload[0], .bytes = payload[1..] } };
                },
                msg.pong => {
                    if (payload.len < 4 or !self.ping_outstanding) return null;
                    const token = std.mem.readInt(u32, payload[0..4], .little);
                    if (token != self.ping_token) return null;
                    self.ping_outstanding = false;
                    self.last_rtt_ms = @intCast(@min((now -% self.last_ping_us) / 1000, std.math.maxInt(u32)));
                    return null;
                },
                msg.@"error" => {
                    if (payload.len < 1) return null;
                    const code: ErrorCode = @enumFromInt(payload[0]);
                    if (code == .not_joined and self.current == .joined) {
                        // The lobby restarted without us noticing: rejoin.
                        self.roster_len = 0;
                        self.say_hello(now);
                    }
                    return .{ .host_error = .{ .code = code, .message = payload[1..] } };
                },
                else => return null, // unknown types are for later versions
            }
        }
    };
}

fn copy_ascii(dst: []u8, src: []const u8) void {
    const n = @min(dst.len, src.len);
    for (dst[0..n], src[0..n]) |*d, s| d.* = if (s >= 0x20 and s < 0x7F) s else '?';
}

// ┌───────────────────────────────────────────────────────────────────────────┐
// │ Tests (zig build test)                                                    │
// └───────────────────────────────────────────────────────────────────────────┘

const testing = std.testing;

fn expect_round_trip(body: []const u8) !void {
    var enc: [1200]u8 = undefined;
    const n = cobs.encode(body, &enc);
    try testing.expect(n <= cobs.max_encoded_len(body.len));
    try testing.expect(std.mem.indexOfScalar(u8, enc[0..n], 0) == null);
    const m = cobs.decode(enc[0..n]) orelse return error.DecodeFailed;
    try testing.expectEqualSlices(u8, body, enc[0..m]);
}

test "cobs known vectors" {
    var out: [16]u8 = undefined;
    try testing.expectEqualSlices(u8, &.{0x01}, out[0..cobs.encode(&.{}, &out)]);
    try testing.expectEqualSlices(u8, &.{ 0x01, 0x01 }, out[0..cobs.encode(&.{0}, &out)]);
    try testing.expectEqualSlices(u8, &.{ 0x01, 0x01, 0x01 }, out[0..cobs.encode(&.{ 0, 0 }, &out)]);
    try testing.expectEqualSlices(u8, &.{ 0x03, 0x11, 0x22, 0x02, 0x33 }, out[0..cobs.encode(&.{ 0x11, 0x22, 0x00, 0x33 }, &out)]);
    try testing.expectEqualSlices(u8, &.{ 0x02, 0x11, 0x01, 0x01, 0x01 }, out[0..cobs.encode(&.{ 0x11, 0, 0, 0 }, &out)]);
}

test "cobs round trips: zero runs, 254-byte blocks, long bodies" {
    try expect_round_trip(&.{});
    try expect_round_trip(&(@as([1]u8, @splat(0))));
    try expect_round_trip(&(@as([300]u8, @splat(0))));
    var buf: [1000]u8 = undefined;
    for ([_]usize{ 1, 253, 254, 255, 256, 508, 509, 1000 }) |len| {
        for (buf[0..len], 0..) |*b, i| b.* = @intCast(i % 255 + 1); // no zeros
        try expect_round_trip(buf[0..len]);
        buf[len - 1] = 0;
        try expect_round_trip(buf[0..len]);
        buf[0] = 0;
        try expect_round_trip(buf[0..len]);
    }
    for (&buf, 0..) |*b, i| b.* = @truncate(i * 7);
    try expect_round_trip(&buf);

    // 254 non-zero bytes: one full block, code 0xFF.
    var block: [254]u8 = @splat(0x42);
    var enc: [300]u8 = undefined;
    const n = cobs.encode(&block, &enc);
    try testing.expectEqual(@as(u8, 0xFF), enc[0]);
    try testing.expect(n <= cobs.max_encoded_len(block.len));
    try expect_round_trip(&block);
}

test "cobs rejects invalid input" {
    var a = [_]u8{ 0x05, 0x11, 0x22 }; // block runs past the end
    try testing.expect(cobs.decode(&a) == null);
    var b = [_]u8{ 0x03, 0x11, 0x00 }; // contains a zero
    try testing.expect(cobs.decode(&b) == null);
}

fn feed(f: *Framer, bytes: []const u8, out: *std.ArrayList(u8), count: *usize) void {
    for (bytes) |b| {
        if (f.push(b)) |body| {
            out.appendSliceAssumeCapacity(body);
            out.appendAssumeCapacity('|');
            count.* += 1;
        }
    }
}

test "framer: frames, max length, too long, empty frames" {
    var f: Framer = .{};
    var frame: Framer.Frame = undefined;

    // Max length body with zeros.
    var body: [max_body_len]u8 = undefined;
    for (&body, 0..) |*b, i| b.* = @truncate(i);
    const bytes = try Framer.encode(&body, &frame);
    try testing.expect(bytes.len <= frame.len);
    var got: ?[]const u8 = null;
    for (bytes) |b| got = f.push(b) orelse got;
    try testing.expectEqualSlices(u8, &body, got.?);

    try testing.expectError(error.TooLong, Framer.encode(&(@as([max_body_len + 1]u8, @splat(1))), &frame));

    // Empty frames are ignored and are not errors.
    try testing.expect(f.push(0) == null);
    try testing.expect(f.push(0) == null);
    try testing.expectEqual(@as(u32, 0), f.dropped);

    // A 251-byte decoded body is dropped even though it encodes in 252 bytes.
    var long_body: [max_body_len + 1]u8 = @splat(7);
    var long_enc: [300]u8 = undefined;
    const ln = cobs.encode(&long_body, &long_enc);
    for (long_enc[0..ln]) |b| try testing.expect(f.push(b) == null);
    try testing.expect(f.push(0) == null);
    try testing.expectEqual(@as(u32, 1), f.dropped);
}

test "framer resyncs after garbage and mid-stream starts" {
    var f: Framer = .{};
    var storage: [600]u8 = undefined;
    var out: std.ArrayList(u8) = .initBuffer(&storage);
    var count: usize = 0;
    var frame: Framer.Frame = undefined;

    // Starting mid-frame: the tail of some frame, then a good one.
    feed(&f, &.{ 0x41, 0x42, 0x00 }, &out, &count);
    feed(&f, try Framer.encode("hi", &frame), &out, &count);
    // Invalid COBS, then a good frame.
    feed(&f, &.{ 0x09, 0x01, 0x02, 0x00 }, &out, &count);
    feed(&f, try Framer.encode("ok", &frame), &out, &count);
    // An oversized run of junk without delimiters, then a good frame.
    var junk: [400]u8 = @splat(0x55);
    feed(&f, &junk, &out, &count);
    feed(&f, &.{0}, &out, &count);
    feed(&f, try Framer.encode(&.{ 0, 1, 0 }, &frame), &out, &count);

    // The partial frame, the invalid one and the junk are dropped.
    try testing.expectEqualSlices(u8, "hi|ok|\x00\x01\x00|", out.items);
    try testing.expectEqual(@as(u32, 3), f.dropped);
}

const FakePort = struct {
    supported: bool = true,
    is_connected: bool = false,
    now: u64 = 0,
    /// host -> cart bytes not yet read
    rx: [4096]u8 = undefined,
    rx_head: usize = 0,
    rx_len: usize = 0,
    /// cart -> host bytes
    tx: [4096]u8 = undefined,
    tx_len: usize = 0,
    tx_space: usize = 4096,

    pub fn open(p: *FakePort) bool {
        return p.supported;
    }
    pub fn connected(p: *FakePort) bool {
        return p.is_connected;
    }
    pub fn read(p: *FakePort, buf: []u8) usize {
        const n = @min(buf.len, p.rx_len - p.rx_head);
        @memcpy(buf[0..n], p.rx[p.rx_head..][0..n]);
        p.rx_head += n;
        return n;
    }
    pub fn write(p: *FakePort, bytes: []const u8) usize {
        const n = @min(bytes.len, p.tx_space);
        @memcpy(p.tx[p.tx_len..][0..n], bytes[0..n]);
        p.tx_len += n;
        p.tx_space -= n;
        return n;
    }
    pub fn space_available(p: *FakePort) usize {
        return p.tx_space;
    }
    pub fn micros(p: *FakePort) u64 {
        return p.now;
    }

    /// Queue a host -> cart message.
    fn host_sends(p: *FakePort, body: []const u8) void {
        var frame: Framer.Frame = undefined;
        const bytes = Framer.encode(body, &frame) catch unreachable;
        @memcpy(p.rx[p.rx_len..][0..bytes.len], bytes);
        p.rx_len += bytes.len;
    }

    /// Decode everything the cart sent so far, then clear it.
    fn cart_sent(p: *FakePort, bodies: *[16][max_body_len]u8, lens: *[16]usize) usize {
        var f: Framer = .{};
        var count: usize = 0;
        for (p.tx[0..p.tx_len]) |b| {
            if (f.push(b)) |body| {
                @memcpy(bodies[count][0..body.len], body);
                lens[count] = body.len;
                count += 1;
            }
        }
        p.tx_space += p.tx_len;
        p.tx_len = 0;
        return count;
    }
};

const TestClient = ClientOver(*FakePort);

fn drain(c: *TestClient, events: []Event) usize {
    var n: usize = 0;
    while (c.poll()) |e| {
        events[n] = e;
        n += 1;
    }
    return n;
}

fn roster_body(comptime entries: []const struct { u8, []const u8 }) [2 + entries.len * 13]u8 {
    var b: [2 + entries.len * 13]u8 = @splat(0);
    b[0] = msg.roster;
    b[1] = entries.len;
    for (entries, 0..) |e, i| {
        b[2 + i * 13] = e[0];
        @memcpy(b[3 + i * 13 ..][0..e[1].len], e[1]);
    }
    return b;
}

test "client: unsupported firmware" {
    var port: FakePort = .{ .supported = false };
    var c = TestClient.init_with_port(&port, .{ .game = "DOTS", .name = "me" });
    try testing.expectEqual(State.unsupported, c.state());
    try testing.expect(c.poll() == null);
    try testing.expectError(error.NotJoined, c.broadcast("x"));
}

test "client: hello, welcome, roster, data, send, ping, reconnect" {
    var port: FakePort = .{};
    var c = TestClient.init_with_port(&port, .{ .game = "DOTS", .name = "adrian", .max_players = 4 });
    var events: [8]Event = undefined;
    var bodies: [16][max_body_len]u8 = undefined;
    var lens: [16]usize = undefined;

    try testing.expectEqual(State.waiting_for_host, c.state());
    try testing.expectEqual(@as(usize, 0), drain(&c, &events));
    try testing.expectEqual(@as(usize, 0), port.tx_len);

    // Host connects: leading 0x00, then HELLO.
    port.is_connected = true;
    try testing.expectEqual(@as(usize, 0), drain(&c, &events));
    try testing.expectEqual(State.joining, c.state());
    try testing.expectEqual(@as(u8, 0), port.tx[0]);
    try testing.expectEqual(@as(usize, 1), port.cart_sent(&bodies, &lens));
    try testing.expectEqualSlices(u8, "\x01\x01DOTS\x00\x00\x00\x00adrian\x00\x00\x00\x00\x00\x00\x04", bodies[0][0..lens[0]]);
    try testing.expectError(error.NotJoined, c.broadcast("x"));

    // WELCOME + ROSTER + DATA arrive in one read.
    port.host_sends(&.{ msg.welcome, 1, 2, 0, 4 });
    port.host_sends(&roster_body(&.{ .{ 0, "bob" }, .{ 2, "adrian" } }));
    port.host_sends(&.{ msg.data, 0, 0xAA, 0x00, 0xBB });
    try testing.expectEqual(@as(usize, 3), drain(&c, &events));
    try testing.expectEqual(Event.Joined{ .you = 2, .room = 0, .max_players = 4 }, events[0].joined);
    try testing.expect(events[1] == .roster);
    try testing.expectEqual(@as(u8, 0), events[2].data.from);
    try testing.expectEqual(State.joined, c.state());
    try testing.expectEqual(@as(?u8, 2), c.you());
    try testing.expectEqual(@as(usize, 2), c.players().len);
    try testing.expectEqualStrings("bob", c.players()[0].name());
    try testing.expectEqualStrings("adrian", c.player(2).?.name());

    // The client pinged right after joining.
    var n = port.cart_sent(&bodies, &lens);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(msg.ping, bodies[0][0]);
    const token = bodies[0][1..5].*;
    port.now += 12_000;
    port.host_sends(&([_]u8{msg.pong} ++ token));
    try testing.expectEqual(@as(usize, 0), drain(&c, &events));
    try testing.expectEqual(@as(?u32, 12), c.ping_ms());

    // Sends.
    try c.send(0, "hey");
    try c.broadcast(&.{ 1, 0, 2 });
    try c.broadcast_with_echo("all");
    try testing.expectError(error.TooLong, c.broadcast(&(@as([max_data_len + 1]u8, @splat(1)))));
    n = port.cart_sent(&bodies, &lens);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualSlices(u8, "\x02\x00hey", bodies[0][0..lens[0]]);
    try testing.expectEqualSlices(u8, "\x02\xff\x01\x00\x02", bodies[1][0..lens[1]]);
    try testing.expectEqualSlices(u8, "\x02\xfeall", bodies[2][0..lens[2]]);

    // Full transmit buffer: nothing partial goes out.
    port.tx_space = 3;
    try testing.expectError(error.QueueFull, c.broadcast("abcdef"));
    try testing.expectEqual(@as(usize, 0), port.tx_len);
    port.tx_space = 4096;

    // Host goes away: .left once, roster cleared.
    port.is_connected = false;
    try testing.expectEqual(@as(usize, 1), drain(&c, &events));
    try testing.expect(events[0] == .left);
    try testing.expectEqual(State.waiting_for_host, c.state());
    try testing.expectEqual(@as(usize, 0), c.players().len);
    try testing.expect(c.you() == null);

    // Host comes back: 0x00 + HELLO again.
    port.now += 5_000_000;
    port.is_connected = true;
    _ = drain(&c, &events);
    try testing.expectEqual(State.joining, c.state());
    try testing.expectEqual(@as(u8, 0), port.tx[0]);
    n = port.cart_sent(&bodies, &lens);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(msg.hello, bodies[0][0]);

    // HELLO is retried while no WELCOME comes.
    port.now += 2_000_000;
    _ = drain(&c, &events);
    n = port.cart_sent(&bodies, &lens);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(msg.hello, bodies[0][0]);
}

test "client: echoed data arrives with from == you, in order, not deduped" {
    var port: FakePort = .{ .is_connected = true };
    var c = TestClient.init_with_port(&port, .{ .game = "LYNX", .name = "a" });
    var events: [8]Event = undefined;
    var bodies: [16][max_body_len]u8 = undefined;
    var lens: [16]usize = undefined;
    _ = drain(&c, &events);
    port.host_sends(&.{ msg.welcome, 1, 1, 0, 2 });
    _ = drain(&c, &events);
    _ = port.cart_sent(&bodies, &lens);

    try c.broadcast_with_echo("in");
    try testing.expectEqual(@as(usize, 1), port.cart_sent(&bodies, &lens));
    try testing.expectEqualSlices(u8, "\x02\xfein", bodies[0][0..lens[0]]);

    // The room's order: player 0, then our own echo, then player 0 again
    // with identical bytes (must not be merged).
    port.host_sends(&.{ msg.data, 0, 'x' });
    port.host_sends(&.{ msg.data, 1, 'i', 'n' });
    port.host_sends(&.{ msg.data, 0, 'x' });
    try testing.expectEqual(@as(usize, 3), drain(&c, &events));
    try testing.expectEqual(@as(u8, 0), events[0].data.from);
    try testing.expectEqual(@as(u8, 1), events[1].data.from);
    try testing.expectEqual(c.you().?, events[1].data.from);
    try testing.expectEqual(@as(u8, 0), events[2].data.from);
}

test "client: data bytes stay valid until the next poll" {
    var port: FakePort = .{ .is_connected = true };
    var c = TestClient.init_with_port(&port, .{ .game = "G", .name = "n" });
    var events: [8]Event = undefined;
    _ = drain(&c, &events);
    port.host_sends(&.{ msg.welcome, 1, 0, 0, 2 });
    port.host_sends(&.{ msg.data, 1, 'a', 'b', 'c' });
    port.host_sends(&.{ msg.data, 1, 'd' });
    try testing.expect(c.poll().? == .joined);
    const e = c.poll().?;
    try testing.expectEqualStrings("abc", e.data.bytes);
    try testing.expectEqualStrings("d", c.poll().?.data.bytes);
}

test "client: lobby restart detected by NOT JOINED error" {
    var port: FakePort = .{ .is_connected = true };
    var c = TestClient.init_with_port(&port, .{ .game = "G", .name = "n" });
    var events: [8]Event = undefined;
    var bodies: [16][max_body_len]u8 = undefined;
    var lens: [16]usize = undefined;
    _ = drain(&c, &events);
    port.host_sends(&.{ msg.welcome, 1, 0, 0, 2 });
    _ = drain(&c, &events);
    _ = port.cart_sent(&bodies, &lens);

    port.host_sends(&.{ msg.@"error", 3, 'n', 'o' });
    try testing.expectEqual(@as(usize, 1), drain(&c, &events));
    try testing.expectEqual(ErrorCode.not_joined, events[0].host_error.code);
    try testing.expectEqualStrings("no", events[0].host_error.message);
    try testing.expectEqual(State.joining, c.state());
    try testing.expectEqual(@as(usize, 1), port.cart_sent(&bodies, &lens));
    try testing.expectEqual(msg.hello, bodies[0][0]);
}

test "client: unknown and malformed messages are ignored" {
    var port: FakePort = .{ .is_connected = true };
    var c = TestClient.init_with_port(&port, .{ .game = "G", .name = "n" });
    var events: [8]Event = undefined;
    _ = drain(&c, &events);
    port.host_sends(&.{ 0x99, 1, 2, 3 });
    port.host_sends(&.{msg.welcome});
    port.host_sends(&.{ msg.roster, 3, 0 });
    port.host_sends(&.{ msg.data, 0, 1 }); // before WELCOME: dropped
    try testing.expectEqual(@as(usize, 0), drain(&c, &events));
    try testing.expectEqual(State.joining, c.state());
}
