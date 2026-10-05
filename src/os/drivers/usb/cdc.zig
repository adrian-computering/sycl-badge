//! USB CDC ACM class driver: a virtual serial port. The badge has two, the
//! kernel console and the cart serial port, each an instance of `CDC_Driver`.
//!
//! `CDC_Driver` works one packet at a time: a packet from the host stays in
//! the OUT endpoint buffer until the user `release`s it, and the endpoint is
//! only armed again after that, so a user that has no room yet makes the host
//! wait (USB NAK) instead of losing data. `Buffered` adds byte rings on top for
//! the console, and `pump` moves packets between a port and any pair of byte
//! queues.
const std = @import("std");
const microzig = @import("microzig");
const assert = microzig.assert;
const types = microzig.core.usb.types;
const descriptor = microzig.core.usb.descriptor;

const endpoint = @import("endpoint.zig");
const PacketIdentifier = endpoint.PacketIdentifier;

const log = std.log.scoped(.cdc);

/// Class requests sent to the communications interface
pub const Request = enum(u8) {
    set_line_coding = 0x20,
    get_line_coding = 0x21,
    set_control_line_state = 0x22,
    _,
};

/// Bit rate, stop bits, parity and data bits. A virtual port ignores the
/// values, but the host expects them to round trip.
pub const LineCoding = [7]u8;
const default_line_coding: LineCoding = .{ 0x00, 0xC2, 0x01, 0x00, 0, 0, 8 }; // 115200 8N1

/// Descriptors of one CDC ACM function: the interface association, the
/// communications interface with its functional descriptors and notification
/// endpoint, then the data interface with its bulk endpoints.
pub const FunctionDescriptors = extern struct {
    association: descriptor.InterfaceAssociation,
    comm_interface: descriptor.Interface,
    header: descriptor.cdc.Header,
    call_management: descriptor.cdc.CallManagement,
    acm: descriptor.cdc.AbstractControlModel,
    @"union": descriptor.cdc.Union,
    notification_ep: descriptor.Endpoint,
    data_interface: descriptor.Interface,
    in_ep: descriptor.Endpoint,
    out_ep: descriptor.Endpoint,

    comptime {
        // Descriptors are byte aligned, so there is no padding between them
        assert(@sizeOf(FunctionDescriptors) == 66, .{});
    }

    pub const Options = struct {
        /// The communications interface, the data interface is the next one
        first_interface: u8,
        /// String descriptor index of the function and interface names
        name: u8,
        /// Interrupt IN endpoint for notifications
        notification_ep: types.Endpoint.Num,
        /// Bulk IN and OUT endpoints for data
        data_ep: types.Endpoint.Num,
        max_packet_size: u16,
    };

    pub fn init(opts: Options) FunctionDescriptors {
        const comm = opts.first_interface;
        const data = opts.first_interface + 1;
        return .{
            .association = .{
                .first_interface = comm,
                .interface_count = 2,
                .function_class = @backingInt(types.ClassSubclassProtocol.ClassCode.CDC),
                .function_subclass = @backingInt(types.ClassSubclassProtocol.Subclass.CDC.Abstract),
                .function_protocol = @backingInt(types.ClassSubclassProtocol.Protocol.CDC.NoneRequired),
                .function = opts.name,
            },
            .comm_interface = .{
                .interface_number = comm,
                .alternate_setting = 0,
                .num_endpoints = 1,
                .interface_triple = .from(.CDC, .Abstract, .NoneRequired),
                .interface_s = opts.name,
            },
            .header = .{},
            .call_management = .{
                .capabilities = .none,
                .data_interface = data,
            },
            .acm = .{
                .capabilities = .{
                    .comm_feature = false,
                    .line_coding = true,
                    .send_break = false,
                    .network_connection = false,
                },
            },
            .@"union" = .{
                .master_interface = comm,
                .slave_interface_0 = data,
            },
            // Never armed: the host's polls get a NAK, there is nothing to notify
            .notification_ep = .interrupt(.{ .dir = .in, .num = opts.notification_ep }, 8, 16),
            .data_interface = .{
                .interface_number = data,
                .alternate_setting = 0,
                .num_endpoints = 2,
                .interface_triple = .{ .class = .CDC_Data, .subclass = 0x00, .protocol = 0x00 },
                .interface_s = opts.name,
            },
            .in_ep = .bulk(.{ .dir = .in, .num = opts.data_ep }, opts.max_packet_size),
            .out_ep = .bulk(.{ .dir = .out, .num = opts.data_ep }, opts.max_packet_size),
        };
    }
};

pub const Callbacks = struct {
    queue_packet: *const fn (data: []const u8, pid: PacketIdentifier) void,
    queue_receive: *const fn (pid: PacketIdentifier) void,
    get_buffer: *const fn () []const u8,
    /// Aborts whatever is armed on the IN (`.in`) or OUT (`.out`) endpoint
    disarm_endpoint: *const fn (dir: types.Dir) void,
};

pub const Config = struct {
    max_packet_size: u8,
    callbacks: Callbacks,
};

pub fn CDC_Driver(comptime SetupProcessor: type, comptime config: Config) type {
    return struct {
        pub const max_packet_size = config.max_packet_size;

        line_coding: LineCoding,
        /// Data Terminal Ready: the host has the port open
        dtr: bool,
        /// The host suspended the bus, or the cable is gone (VBUS detection is
        /// forced on, so an unplugged badge looks suspended)
        bus_suspended: bool,
        in_pid: PacketIdentifier,
        out_pid: PacketIdentifier,
        /// No packet waits in the IN endpoint buffer
        in_idle: bool,
        /// The last IN packet was full, so a zero length packet must end the
        /// transfer unless more data follows
        in_needs_zlp: bool,
        out: enum {
            /// Not armed, `poll` arms it
            idle,
            /// Waiting for a packet from the host
            armed,
            /// A packet waits in the endpoint buffer until `release`
            holding,
        },

        pub fn init(self: *@This()) void {
            self.* = .{
                .line_coding = default_line_coding,
                .dtr = false,
                .bus_suspended = false,
                .in_pid = .DATA0,
                .out_pid = .DATA0,
                .in_idle = true,
                .in_needs_zlp = false,
                .out = .idle,
            };
        }

        /// Call once the endpoints are configured, and on every bus reset
        pub fn reset(self: *@This()) void {
            config.callbacks.disarm_endpoint(.in);
            config.callbacks.disarm_endpoint(.out);
            self.init();
            self.poll();
        }

        /// CLEAR_FEATURE(ENDPOINT_HALT) on one of the data endpoints: restart
        /// its data toggle at DATA0. The port stays open.
        pub fn clear_halt(self: *@This(), dir: types.Dir) void {
            switch (dir) {
                .in => {
                    config.callbacks.disarm_endpoint(.in);
                    self.in_pid = .DATA0;
                    self.in_idle = true;
                    self.in_needs_zlp = false;
                },
                .out => {
                    self.out_pid = .DATA0;
                    // A packet that already arrived is kept, it was acknowledged
                    if (self.out == .armed) {
                        config.callbacks.disarm_endpoint(.out);
                        self.out = .idle;
                    }
                    self.poll();
                },
            }
        }

        /// True while a host program has the port open
        pub fn connected(self: *const @This()) bool {
            return self.dtr and !self.bus_suspended;
        }

        pub fn in_ready(self: *@This()) void {
            self.in_idle = true;
        }

        pub fn out_ready(self: *@This()) void {
            if (self.out != .armed) return;
            self.out = .holding;
            self.out_pid.toggle();
        }

        /// The packet the host sent, until `release` is called
        pub fn received(self: *const @This()) ?[]const u8 {
            return if (self.out == .holding) config.callbacks.get_buffer() else null;
        }

        /// Done with the packet from `received`, the host may send the next one
        pub fn release(self: *@This()) void {
            assert(self.out == .holding, .{});
            self.out = .idle;
            self.poll();
        }

        /// True when `send` may queue a packet
        pub fn can_send(self: *const @This()) bool {
            return self.in_idle;
        }

        /// True when the last packet was full and nothing followed it yet:
        /// send an empty packet if there is no more data, so the host's read
        /// completes
        pub fn needs_zlp(self: *const @This()) bool {
            return self.in_needs_zlp;
        }

        /// Queues one packet (at most `max_packet_size` bytes, empty for a
        /// zero length packet) for the host. Only call when `can_send`.
        pub fn send(self: *@This(), data: []const u8) void {
            assert(self.in_idle, .{});
            assert(data.len <= max_packet_size, .{});
            config.callbacks.queue_packet(data, self.in_pid);
            self.in_pid.toggle();
            self.in_idle = false;
            self.in_needs_zlp = data.len == max_packet_size;
        }

        pub fn poll(self: *@This()) void {
            if (self.out == .idle) {
                config.callbacks.queue_receive(self.out_pid);
                self.out = .armed;
            }
        }

        pub fn setup_handler(setup_processor: *SetupProcessor, ctx: ?*anyopaque, pkt: *const types.SetupPacket) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            const request: Request = @fromBackingInt(pkt.request);
            switch (request) {
                .set_line_coding => setup_processor.queue_out_xfer(pkt.length.native(), .{
                    .ctx = self,
                    .handler = set_line_coding,
                }),
                .get_line_coding => setup_processor.queue_in_xfer(&self.line_coding, pkt.length.native()),
                .set_control_line_state => {
                    self.dtr = (pkt.value.native() & 0x01) != 0;
                    log.info("SET_CONTROL_LINE_STATE interface={} dtr={}", .{ pkt.index.native(), self.dtr });
                    setup_processor.queue_in_xfer("", 0);
                },
                _ => {
                    log.warn("unsupported CDC request 0x{X}", .{pkt.request});
                    setup_processor.stall_ep0();
                },
            }
        }

        fn set_line_coding(ctx: ?*anyopaque, payload: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (payload.len >= self.line_coding.len)
                @memcpy(&self.line_coding, payload[0..self.line_coding.len]);
        }
    };
}

/// Moves data between a CDC port and a pair of byte queues. The packet the
/// host sent goes to `rx` once all of it fits (until then the host waits), and
/// while the host has the port open up to one packet from `tx` goes to the IN
/// endpoint, followed by a zero length packet when a transfer ends on a full
/// packet.
///
/// `port` is a `CDC_Driver`, or anything with the same packet interface.
/// `rx` needs `free() usize` and `push([]const u8)`, `tx` needs
/// `peek([]u8) usize` (copy without consuming) and `consume(usize)`.
pub fn pump(port: anytype, rx: anytype, tx: anytype) void {
    if (port.received()) |pkt| {
        if (rx.free() >= pkt.len) {
            rx.push(pkt);
            port.release();
        }
    }

    if (!port.connected() or !port.can_send()) return;

    var pkt: [@TypeOf(port.*).max_packet_size]u8 = undefined;
    const n = tx.peek(&pkt);
    if (n > 0) {
        port.send(pkt[0..n]);
        tx.consume(n);
    } else if (port.needs_zlp()) {
        port.send(&.{});
    }
}

/// Fixed capacity byte FIFO
pub fn Ring(comptime capacity: usize) type {
    return struct {
        buf: [capacity]u8 = undefined,
        head: usize = 0,
        len: usize = 0,

        pub fn free(self: *const @This()) usize {
            return capacity - self.len;
        }

        /// Copies as much of `data` as fits, returns how many bytes were copied
        pub fn write(self: *@This(), data: []const u8) usize {
            const n = @min(data.len, self.free());
            for (data[0..n]) |byte| {
                self.buf[(self.head + self.len) % capacity] = byte;
                self.len += 1;
            }
            return n;
        }

        /// Copies all of `data`, which must fit
        pub fn push(self: *@This(), data: []const u8) void {
            assert(self.write(data) == data.len, .{});
        }

        /// Copies up to `out.len` bytes into `out` without removing them,
        /// returns how many bytes were copied
        pub fn peek(self: *const @This(), out: []u8) usize {
            const n = @min(out.len, self.len);
            for (out[0..n], 0..) |*byte, i| {
                byte.* = self.buf[(self.head + i) % capacity];
            }
            return n;
        }

        /// Removes `n` bytes, at most `len`
        pub fn consume(self: *@This(), n: usize) void {
            assert(n <= self.len, .{});
            self.head = (self.head + n) % capacity;
            self.len -= n;
        }

        /// Moves up to `out.len` bytes into `out`, returns how many bytes were moved
        pub fn pop(self: *@This(), out: []u8) usize {
            const n = self.peek(out);
            self.consume(n);
            return n;
        }
    };
}

/// A port with byte rings on both sides, for the console: output waits in
/// `tx` until a terminal opens the port and is dropped when it closes, input
/// waits in `rx` until it is read.
pub fn Buffered(comptime Driver: type, comptime tx_capacity: usize, comptime rx_capacity: usize) type {
    return struct {
        port: Driver,
        tx: Ring(tx_capacity),
        rx: Ring(rx_capacity),
        was_connected: bool,

        pub fn init(self: *@This()) void {
            self.port.init();
            self.tx = .{};
            self.rx = .{};
            self.was_connected = false;
        }

        /// Call once the endpoints are configured, and on every bus reset
        pub fn reset(self: *@This()) void {
            self.port.reset();
            self.tx = .{};
            self.rx = .{};
            self.was_connected = false;
        }

        pub fn connected(self: *const @This()) bool {
            return self.port.connected();
        }

        /// Queues bytes for the host, returns how many bytes fit
        pub fn write(self: *@This(), data: []const u8) usize {
            return self.tx.write(data);
        }

        /// Takes bytes received from the host, returns how many bytes were copied
        pub fn read(self: *@This(), out: []u8) usize {
            return self.rx.pop(out);
        }

        pub fn poll(self: *@This()) void {
            self.port.poll();

            // The terminal closed the port, drop output it will never read
            const now_connected = self.port.connected();
            if (self.was_connected and !now_connected) self.tx = .{};
            self.was_connected = now_connected;

            pump(&self.port, &self.rx, &self.tx);
        }
    };
}

const testing = std.testing;

test Ring {
    var ring: Ring(4) = .{};
    var out: [4]u8 = undefined;

    try testing.expectEqual(0, ring.pop(&out));
    try testing.expectEqual(3, ring.write("abc"));
    // Only one byte of room is left
    try testing.expectEqual(1, ring.write("de"));
    try testing.expectEqual(0, ring.free());

    try testing.expectEqual(2, ring.pop(out[0..2]));
    try testing.expectEqualStrings("ab", out[0..2]);

    // Wraps around the end of the buffer
    try testing.expectEqual(2, ring.write("fg"));
    try testing.expectEqual(4, ring.peek(&out));
    try testing.expectEqualStrings("cdfg", &out);
    try testing.expectEqual(4, ring.pop(&out));
    try testing.expectEqualStrings("cdfg", &out);
}

/// A CDC port without hardware, for testing `pump` and its users
pub const FakePort = struct {
    pub const max_packet_size = 64;

    dtr: bool = false,
    in_idle: bool = true,
    in_needs_zlp: bool = false,
    /// The packet the host sent, null when the endpoint is armed
    holding: ?[]const u8 = null,
    /// Every packet sent to the host, in order, empty packets included
    sent: std.ArrayList([]const u8) = .empty,

    pub fn deinit(self: *FakePort) void {
        for (self.sent.items) |pkt| testing.allocator.free(pkt);
        self.sent.deinit(testing.allocator);
    }

    /// The host sends a packet, the endpoint must be armed
    pub fn host_send(self: *FakePort, data: []const u8) !void {
        try testing.expect(self.holding == null);
        self.holding = data;
    }

    /// The host reads the packet waiting in the IN endpoint
    pub fn host_read(self: *FakePort) void {
        self.in_idle = true;
    }

    pub fn connected(self: *const FakePort) bool {
        return self.dtr;
    }

    pub fn received(self: *const FakePort) ?[]const u8 {
        return self.holding;
    }

    pub fn release(self: *FakePort) void {
        std.debug.assert(self.holding != null);
        self.holding = null;
    }

    pub fn can_send(self: *const FakePort) bool {
        return self.in_idle;
    }

    pub fn needs_zlp(self: *const FakePort) bool {
        return self.in_needs_zlp;
    }

    pub fn send(self: *FakePort, data: []const u8) void {
        std.debug.assert(self.in_idle and data.len <= max_packet_size);
        self.sent.append(testing.allocator, testing.allocator.dupe(u8, data) catch @panic("oom")) catch @panic("oom");
        self.in_idle = false;
        self.in_needs_zlp = data.len == max_packet_size;
    }
};

test "pump holds a packet until it fits" {
    var port: FakePort = .{};
    defer port.deinit();
    var rx: Ring(80) = .{};
    var tx: Ring(16) = .{};

    try port.host_send(&@as([64]u8, @splat('a')));
    pump(&port, &rx, &tx);
    try testing.expectEqual(64, rx.len);
    try testing.expectEqual(null, port.holding);

    // 16 bytes of room left, the packet waits in the endpoint
    try port.host_send(&@as([20]u8, @splat('b')));
    pump(&port, &rx, &tx);
    try testing.expect(port.holding != null);
    try testing.expectEqual(64, rx.len);

    var out: [64]u8 = undefined;
    _ = rx.pop(out[0..10]);
    pump(&port, &rx, &tx);
    try testing.expectEqual(null, port.holding);
    try testing.expectEqual(74, rx.len);
}

test "pump sends only while connected and ends full packets with a ZLP" {
    var port: FakePort = .{};
    defer port.deinit();
    var rx: Ring(64) = .{};
    var tx: Ring(256) = .{};

    try testing.expectEqual(100, tx.write(&@as([100]u8, @splat('x'))));
    pump(&port, &rx, &tx);
    try testing.expectEqual(0, port.sent.items.len);

    port.dtr = true;
    pump(&port, &rx, &tx);
    try testing.expectEqual(1, port.sent.items.len);
    try testing.expectEqual(64, port.sent.items[0].len);

    // Busy until the host reads
    pump(&port, &rx, &tx);
    try testing.expectEqual(1, port.sent.items.len);

    port.host_read();
    pump(&port, &rx, &tx);
    try testing.expectEqual(36, port.sent.items[1].len);

    // Exactly one full packet, then a zero length packet once the data runs out
    try testing.expectEqual(64, tx.write(&@as([64]u8, @splat('y'))));
    port.host_read();
    pump(&port, &rx, &tx);
    port.host_read();
    pump(&port, &rx, &tx);
    try testing.expectEqual(4, port.sent.items.len);
    try testing.expectEqual(64, port.sent.items[2].len);
    try testing.expectEqual(0, port.sent.items[3].len);

    // Nothing more to say
    port.host_read();
    pump(&port, &rx, &tx);
    try testing.expectEqual(4, port.sent.items.len);
}

test CDC_Driver {
    const hw = struct {
        var armed: ?PacketIdentifier = null;
        var queued: ?PacketIdentifier = null;
        var queued_len: usize = 0;
        var buffer: []const u8 = "";
        var disarms: usize = 0;

        fn queue_packet(data: []const u8, pid: PacketIdentifier) void {
            queued = pid;
            queued_len = data.len;
        }
        fn queue_receive(pid: PacketIdentifier) void {
            armed = pid;
        }
        fn get_buffer() []const u8 {
            return buffer;
        }
        fn disarm_endpoint(dir: types.Dir) void {
            if (dir == .out) armed = null;
            disarms += 1;
        }
    };
    const Driver = CDC_Driver(void, .{
        .max_packet_size = 64,
        .callbacks = .{
            .queue_packet = hw.queue_packet,
            .queue_receive = hw.queue_receive,
            .get_buffer = hw.get_buffer,
            .disarm_endpoint = hw.disarm_endpoint,
        },
    });

    var port: Driver = undefined;
    port.init();
    port.reset();
    try testing.expectEqual(.DATA0, hw.armed.?);

    // A packet arrives: held, and the endpoint stays unarmed until released
    hw.armed = null;
    hw.buffer = "abc";
    port.out_ready();
    try testing.expectEqualStrings("abc", port.received().?);
    port.poll();
    try testing.expectEqual(null, hw.armed);
    port.release();
    try testing.expectEqual(null, port.received());
    try testing.expectEqual(.DATA1, hw.armed.?);

    // IN packets alternate DATA0/DATA1, a full packet asks for a ZLP
    try testing.expect(port.can_send());
    port.send(&@as([64]u8, @splat(0)));
    try testing.expectEqual(.DATA0, hw.queued.?);
    try testing.expect(!port.can_send());
    try testing.expect(port.needs_zlp());
    port.in_ready();
    port.send(&.{});
    try testing.expectEqual(.DATA1, hw.queued.?);
    try testing.expect(!port.needs_zlp());

    // CLEAR_FEATURE(ENDPOINT_HALT) restarts the toggle, the port stays open
    port.dtr = true;
    port.in_ready();
    port.clear_halt(.in);
    port.send("x");
    try testing.expectEqual(.DATA0, hw.queued.?);
    port.clear_halt(.out);
    try testing.expectEqual(.DATA0, hw.armed.?);
    try testing.expect(port.connected());

    // A suspended bus reads as closed
    port.bus_suspended = true;
    try testing.expect(!port.connected());
}
