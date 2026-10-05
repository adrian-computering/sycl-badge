//! Cart serial in the simulator (fork, see fork/CART_SERIAL.md).
//!
//! The badge exposes the running cart's serial port as a USB serial port; the
//! simulator exposes it as a TCP server on 127.0.0.1. Host programs (for
//! example `badge lobby` or `badge monitor`) connect to it like any socket.
//!
//! Port choice, in order: `--serial-port N` on the command line, the
//! `SYCL_SERIAL_PORT` environment variable, else the first free port in
//! 7341..7356. The simulator prints `cart serial: tcp://127.0.0.1:<port>` on
//! stdout once it listens.
//!
//! One client at a time: while a client is connected, further connections are
//! accepted and closed immediately with a reset (refused), so a tool that
//! probes the port never kicks out the program that is using it. A client
//! whose connection is reset (or closed) right away knows the simulator is
//! busy. The simulator always closes with a reset, never a FIN, so its port
//! never lingers in TIME_WAIT and a restarted simulator gets the same port.
//!
//! Semantics match the badge: `connected()` is true while a client is
//! connected; bytes the cart writes with no client connected are discarded;
//! bytes from the client are never dropped while the cart has the port open,
//! because the simulator stops reading the socket while the cart's receive
//! ring is full (TCP flow control then blocks the client). Bytes that arrive
//! while the cart has not opened the port are discarded.
//!
//! The cart's ring buffers live in cart memory; the host side services them
//! under a mutex with three tasks: an accept loop, a reader per client and a
//! single writer.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const net = Io.net;

const log = std.log.scoped(.cart_serial);

pub const first_port: u16 = 7341;
pub const last_port: u16 = 7356;

var io: Io = undefined;
var server: net.Server = undefined;
var tasks: Io.Group = .init;

/// The TCP port the simulator listens on, 0 when cart serial is off.
pub var port: u16 = 0;

var mutex: Io.Mutex = .init;
/// Broadcast whenever anything below changes.
var changed: Io.Condition = .init;

// The cart's rings (cart memory), free-running indices like the badge ABI.
var cart_open: bool = false;
var rx_buf: [*]u8 = undefined;
var rx_cap: u32 = 0;
var rx_write: u32 = 0;
var rx_read: u32 = 0;
var tx_buf: [*]u8 = undefined;
var tx_cap: u32 = 0;
var tx_write: u32 = 0;
var tx_read: u32 = 0;

// The connected client, if any.
var client: ?net.Stream = null;
/// The client is going away; the reader closes it once the writer lets go.
var client_gone: bool = false;
/// The writer is using `client` outside the mutex.
var writer_busy: bool = false;

pub const StartError = error{ InvalidPort, NoFreePort } || net.IpAddress.ListenError || Io.ConcurrentError;

/// Parse the port choice from the command line and environment.
/// Returns null to scan for the first free port.
pub fn port_from_args(args: []const [:0]const u8, environ: *const std.process.Environ.Map) error{InvalidPort}!?u16 {
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--serial-port")) {
            if (i + 1 >= args.len) return error.InvalidPort;
            return std.fmt.parseInt(u16, args[i + 1], 10) catch error.InvalidPort;
        }
        if (std.mem.startsWith(u8, arg, "--serial-port=")) {
            return std.fmt.parseInt(u16, arg["--serial-port=".len..], 10) catch error.InvalidPort;
        }
    }
    if (environ.get("SYCL_SERIAL_PORT")) |value| {
        return std.fmt.parseInt(u16, value, 10) catch error.InvalidPort;
    }
    return null;
}

/// Start listening and print the address. `requested` null scans 7341..7356.
pub fn start(the_io: Io, requested: ?u16) StartError!void {
    io = the_io;
    if (requested) |p| {
        if (p == 0) return error.InvalidPort;
        var address: net.IpAddress = .{ .ip4 = .loopback(p) };
        server = try address.listen(io, .{});
        port = p;
    } else {
        var p = first_port;
        while (true) : (p += 1) {
            var address: net.IpAddress = .{ .ip4 = .loopback(p) };
            if (address.listen(io, .{})) |s| {
                server = s;
                port = p;
                break;
            } else |err| switch (err) {
                error.AddressInUse => if (p == last_port) return error.NoFreePort,
                else => |e| return e,
            }
        }
    }

    try tasks.concurrent(io, accept_loop, .{});
    try tasks.concurrent(io, writer_loop, .{});

    var buf: [64]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &buf);
    stdout.interface.print("cart serial: tcp://127.0.0.1:{d}\n", .{port}) catch {};
    stdout.interface.flush() catch {};
}

/// Stop the background tasks (on simulator exit).
pub fn stop() void {
    if (port == 0) return;
    tasks.cancel(io);
}

fn accept_loop() Io.Cancelable!void {
    while (true) {
        const stream = server.accept(io) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {
                log.warn("accept failed: {t}", .{err});
                try io.sleep(.fromMilliseconds(100), .awake);
                continue;
            },
        };
        // Every close from our side resets, so the port never sits in
        // TIME_WAIT (a refused client sees a reset instead of an EOF).
        set_abortive_close(stream);

        try mutex.lock(io);
        if (client != null) {
            mutex.unlock(io);
            stream.close(io); // busy: one client at a time
            continue;
        }
        client = stream;
        client_gone = false;
        // Stale bytes from before the connection never reach the new client.
        tx_read = tx_write;
        changed.broadcast(io);
        mutex.unlock(io);

        tasks.concurrent(io, reader_loop, .{stream}) catch {
            try mutex.lock(io);
            client = null;
            mutex.unlock(io);
            stream.close(io);
        };
    }
}

/// Socket -> cart rx ring, for one client. Owns closing the stream.
fn reader_loop(stream: net.Stream) Io.Cancelable!void {
    defer {
        mutex.lockUncancelable(io);
        client_gone = true;
        changed.broadcast(io);
        stream.shutdown(io, .both) catch {};
        while (writer_busy) changed.waitUncancelable(io, &mutex);
        client = null;
        changed.broadcast(io);
        mutex.unlock(io);
        stream.close(io);
    }

    var chunk: [1024]u8 = undefined;
    while (true) {
        // Wait for room in the cart's ring (backpressure). With the port
        // closed, bytes are read and discarded.
        try mutex.lock(io);
        while (cart_open and rx_cap - (rx_write -% rx_read) == 0 and !client_gone) {
            changed.wait(io, &mutex) catch |err| {
                mutex.unlock(io);
                return err;
            };
        }
        const gone = client_gone;
        const space: usize = if (cart_open) rx_cap - (rx_write -% rx_read) else chunk.len;
        mutex.unlock(io);
        if (gone) return;

        var bufs: [1][]u8 = .{chunk[0..@min(space, chunk.len)]};
        // (Stream.read does not compile in this Zig; readWithControl does.)
        const result = stream.readWithControl(io, &bufs, &.{}) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return,
        };
        const n = result.data_len;
        if (n == 0) return; // client closed

        try mutex.lock(io);
        if (cart_open) {
            // The ring can only have grown, unless the cart reopened the
            // port with a smaller one; drop what no longer fits.
            const room = rx_cap - (rx_write -% rx_read);
            for (chunk[0..@min(n, room)]) |b| {
                rx_buf[rx_write & (rx_cap - 1)] = b;
                rx_write +%= 1;
            }
        }
        mutex.unlock(io);
    }
}

/// Cart tx ring -> socket, for whichever client is connected.
fn writer_loop() Io.Cancelable!void {
    var chunk: [1024]u8 = undefined;
    while (true) {
        try mutex.lock(io);
        while (client == null or client_gone or !cart_open or tx_write == tx_read) {
            changed.wait(io, &mutex) catch |err| {
                mutex.unlock(io);
                return err;
            };
        }
        const stream = client.?;
        const n: u32 = @intCast(@min(tx_write -% tx_read, chunk.len));
        for (chunk[0..n], 0..) |*b, i| b.* = tx_buf[(tx_read +% @as(u32, @intCast(i))) & (tx_cap - 1)];
        writer_busy = true;
        mutex.unlock(io);

        var writer = stream.writer(io, &.{});
        const ok = if (writer.interface.writeAll(chunk[0..n])) true else |_| false;

        mutex.lockUncancelable(io);
        writer_busy = false;
        if (ok) {
            // Unless the cart reopened the port in the meantime.
            if (tx_write -% tx_read >= n) tx_read +%= n;
        } else if (!client_gone) {
            client_gone = true;
            stream.shutdown(io, .both) catch {};
        }
        changed.broadcast(io);
        mutex.unlock(io);
    }
}

/// Close with RST instead of FIN so the simulator's port never sits in
/// TIME_WAIT, which would make the next simulator pick a different port.
fn set_abortive_close(stream: net.Stream) void {
    if (builtin.os.tag == .windows) return;
    const Linger = extern struct { onoff: c_int, linger: c_int };
    const value: Linger = .{ .onoff = 1, .linger = 0 };
    std.posix.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.LINGER, std.mem.asBytes(&value)) catch {};
}

// ┌───────────────────────────────────────────────────────────────────────────┐
// │ Cart side (SimulatorAPI), called on the cart thread. Never blocks long.   │
// └───────────────────────────────────────────────────────────────────────────┘

pub fn cart_serial_open(rx: [*]u8, rx_capacity: u32, tx: [*]u8, tx_capacity: u32) callconv(.c) void {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    rx_buf = rx;
    rx_cap = rx_capacity;
    rx_write = 0;
    rx_read = 0;
    tx_buf = tx;
    tx_cap = tx_capacity;
    tx_write = 0;
    tx_read = 0;
    cart_open = true;
    changed.broadcast(io);
}

pub fn cart_serial_close() callconv(.c) void {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    cart_open = false;
    rx_cap = 0;
    tx_cap = 0;
    rx_write = 0;
    rx_read = 0;
    tx_write = 0;
    tx_read = 0;
    changed.broadcast(io);
}

pub fn cart_serial_connected() callconv(.c) bool {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    return client != null and !client_gone;
}

pub fn cart_serial_read(buf: [*]u8, len: usize) callconv(.c) usize {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if (!cart_open) return 0;
    const n: u32 = @intCast(@min(len, rx_write -% rx_read));
    for (buf[0..n], 0..) |*b, i| b.* = rx_buf[(rx_read +% @as(u32, @intCast(i))) & (rx_cap - 1)];
    rx_read +%= n;
    if (n > 0) changed.broadcast(io);
    return n;
}

pub fn cart_serial_write(bytes: [*]const u8, len: usize) callconv(.c) usize {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if (!cart_open) return 0;
    // No client: discard, like the badge with DTR low.
    if (client == null or client_gone) return len;
    const space = tx_cap - (tx_write -% tx_read);
    const n: u32 = @intCast(@min(len, space));
    for (bytes[0..n], 0..) |b, i| tx_buf[(tx_write +% @as(u32, @intCast(i))) & (tx_cap - 1)] = b;
    tx_write +%= n;
    if (n > 0) changed.broadcast(io);
    return n;
}

pub fn cart_serial_bytes_available() callconv(.c) usize {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if (!cart_open) return 0;
    return rx_write -% rx_read;
}

pub fn cart_serial_space_available() callconv(.c) usize {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if (!cart_open) return 0;
    if (client == null or client_gone) return tx_cap;
    return tx_cap - (tx_write -% tx_read);
}
