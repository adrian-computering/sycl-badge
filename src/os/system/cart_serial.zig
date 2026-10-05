//! Cart serial service (fork firmware, see fork/CART_SERIAL.md). Connects the
//! running cart's rings (`ipc_data.cart_serial`, a `CartSerialRings` in cart
//! RAM) to the "SYCL Badge Cart Serial" USB port. Runs on core 0, once per
//! kernel main loop pass.
//!
//! Rules, in the order the spec gives them:
//! - No valid rings (closed, or the cart's struct fails validation): packets
//!   from the host are dropped.
//! - Host not connected (DTR low, or the bus suspended): bytes the cart
//!   writes are dropped, so a cart never stalls on a closed port.
//! - Otherwise lossless: a packet from the host waits in the USB endpoint
//!   until the cart's receive ring has room for all of it, and the host's
//!   writes block meanwhile.
//!
//! The cart owns the struct and the rings, so every pass validates them again
//! and only ever touches memory inside cart RAM. The OS stops touching cart
//! RAM the moment core 1 is halted (`detach`).
const std = @import("std");
const builtin = @import("builtin");

const abi = @import("../cart/os_abi.zig");
const cdc = @import("../drivers/usb/cdc.zig");
const usb = @import("../drivers/usb.zig");
const loader = @import("../loader/loader.zig");

pub const magic = abi.CART_SERIAL_MAGIC;
pub const min_capacity = 64;

/// The fields of `CartSerialRings`, as u32 word indices. The OS reads the
/// struct as words so the same code runs in host tests, where pointers are
/// not 32 bits.
const Word = enum(u32) {
    magic,
    rx_buf,
    rx_cap,
    rx_write,
    rx_read,
    tx_buf,
    tx_cap,
    tx_write,
    tx_read,
    status,
};
const word_count = @typeInfo(Word).@"enum".field_names.len;
const struct_size = 4 * word_count;

comptime {
    if (@sizeOf(usize) == 4) {
        std.debug.assert(@sizeOf(abi.CartSerialRings) == struct_size);
        for (@typeInfo(Word).@"enum".field_names, 0..) |name, i| {
            std.debug.assert(@offsetOf(abi.CartSerialRings, name) == 4 * i);
        }
    }
}

/// Cart RAM as the service sees it: `bytes[0]` is at cart address `base`.
/// Both must be 4 byte aligned.
pub const Memory = struct {
    base: u32,
    bytes: []volatile u8,

    /// Offset of `[addr, addr + len)` in `bytes`, null unless all of it is
    /// inside
    fn offset_of(mem: Memory, addr: u32, len: u32) ?usize {
        if (addr < mem.base) return null;
        const offset = addr - mem.base;
        if (offset > mem.bytes.len or len > mem.bytes.len - offset) return null;
        return offset;
    }
};

const Ring = struct {
    addr: u32,
    /// `cap` bytes
    buf: []volatile u8,

    fn mask(ring: Ring) u32 {
        return @intCast(ring.buf.len - 1);
    }

    fn overlaps(ring: Ring, addr: u32, len: u32) bool {
        return ring.addr < addr + len and addr < ring.addr + ring.buf.len;
    }
};

/// A cart's rings that passed validation
pub const Rings = struct {
    words: *volatile [word_count]u32,
    rx: Ring,
    tx: Ring,

    fn get(rings: Rings, comptime word: Word) u32 {
        return rings.words[@backingInt(word)];
    }

    fn set(rings: Rings, comptime word: Word, value: u32) void {
        rings.words[@backingInt(word)] = value;
    }

    /// Bytes waiting for the cart to read
    pub fn rx_queued(rings: Rings) u32 {
        return rings.get(.rx_write) -% rings.get(.rx_read);
    }

    /// Bytes waiting for the host to read
    pub fn tx_queued(rings: Rings) u32 {
        return rings.get(.tx_write) -% rings.get(.tx_read);
    }
};

/// Checks the struct at cart address `addr`: magic, capacities (powers of
/// two, at least 64), and that the struct and both rings lie entirely inside
/// `mem` without overlapping each other. Every field is read once, so a cart
/// changing them meanwhile cannot get past the checks.
pub fn validate(mem: Memory, addr: u32) ?Rings {
    if (addr == 0 or addr % 4 != 0) return null;
    const offset = mem.offset_of(addr, struct_size) orelse return null;
    const words: *volatile [word_count]u32 = @ptrCast(@alignCast(&mem.bytes[offset]));

    if (words[@backingInt(Word.magic)] != magic) return null;
    const rx = make_ring(mem, words[@backingInt(Word.rx_buf)], words[@backingInt(Word.rx_cap)]) orelse return null;
    const tx = make_ring(mem, words[@backingInt(Word.tx_buf)], words[@backingInt(Word.tx_cap)]) orelse return null;

    // The OS writes the rx ring and the struct, keep them apart
    if (rx.overlaps(addr, struct_size) or tx.overlaps(addr, struct_size) or rx.overlaps(tx.addr, @intCast(tx.buf.len)))
        return null;

    return .{ .words = words, .rx = rx, .tx = tx };
}

fn make_ring(mem: Memory, addr: u32, cap: u32) ?Ring {
    if (cap < min_capacity or !std.math.isPowerOfTwo(cap)) return null;
    const offset = mem.offset_of(addr, cap) orelse return null;
    return .{ .addr = addr, .buf = mem.bytes[offset..][0..cap] };
}

pub const Stats = struct {
    /// Bytes moved from the host to the cart
    rx_bytes: u32 = 0,
    /// Bytes moved from the cart to the host
    tx_bytes: u32 = 0,
    /// Bytes from the host dropped because no cart had the port open
    rx_dropped: u32 = 0,
    /// Bytes from the cart dropped because no host had the port open
    tx_dropped: u32 = 0,
};

pub const State = enum {
    /// `cart_serial` is 0
    closed,
    /// `cart_serial` points at something that failed validation
    invalid,
    /// Serviced
    open,
};

/// One pass of the service over the struct at cart address `addr`. `port` is
/// a `cdc.CDC_Driver` (or `cdc.FakePort` in tests).
pub fn service(mem: Memory, addr: u32, port: anytype, stats: *Stats) State {
    const rings = validate(mem, addr) orelse {
        // No cart has the port open: drop what the host sends
        if (port.received()) |pkt| {
            stats.rx_dropped +%= @intCast(pkt.len);
            port.release();
        }
        return if (addr == 0) .closed else .invalid;
    };

    const host_open = port.connected();
    // Nobody reads, or the cart wrote nonsense indices: drop everything queued
    const tx_queued = rings.tx_queued();
    if (!host_open or tx_queued > rings.tx.buf.len) {
        const write = rings.get(.tx_write);
        dmb();
        rings.set(.tx_read, write);
        stats.tx_dropped +%= tx_queued;
    }

    var rx: RxQueue = .{ .rings = rings, .stats = stats };
    var tx: TxQueue = .{ .rings = rings, .stats = stats };
    cdc.pump(port, &rx, &tx);

    rings.set(.status, @bitCast(abi.CartSerialStatus{
        .host_open = host_open,
        .attached = true,
    }));
    return .open;
}

/// The receive ring from the writer's side (the OS)
const RxQueue = struct {
    rings: Rings,
    stats: *Stats,

    pub fn free(q: *const RxQueue) usize {
        const used = q.rings.rx_queued();
        // The cart's reads of the old bytes complete before the OS reuses them
        dmb();
        return if (used > q.rings.rx.buf.len) 0 else q.rings.rx.buf.len - used;
    }

    pub fn push(q: *RxQueue, data: []const u8) void {
        var write = q.rings.get(.rx_write);
        for (data) |byte| {
            q.rings.rx.buf[write & q.rings.rx.mask()] = byte;
            write +%= 1;
        }
        // Data, then the index
        dmb();
        q.rings.set(.rx_write, write);
        q.stats.rx_bytes +%= @intCast(data.len);
    }
};

/// The transmit ring from the reader's side (the OS)
const TxQueue = struct {
    rings: Rings,
    stats: *Stats,

    pub fn peek(q: *const TxQueue, out: []u8) usize {
        const read = q.rings.get(.tx_read);
        const queued = q.rings.get(.tx_write) -% read;
        // The index, then the data
        dmb();
        // `service` dropped a nonsense count already, this is a cart racing it
        if (queued > q.rings.tx.buf.len) return 0;
        const n = @min(queued, out.len);
        for (out[0..n], 0..) |*byte, i| {
            byte.* = q.rings.tx.buf[(read +% @as(u32, @intCast(i))) & q.rings.tx.mask()];
        }
        return n;
    }

    pub fn consume(q: *TxQueue, n: usize) void {
        // The data is copied out before the cart may overwrite it
        dmb();
        q.rings.set(.tx_read, q.rings.get(.tx_read) +% @as(u32, @intCast(n)));
        q.stats.tx_bytes +%= @intCast(n);
    }
};

inline fn dmb() void {
    switch (builtin.cpu.arch) {
        .arm, .armeb, .thumb, .thumbeb => asm volatile ("dmb" ::: .{ .memory = true }),
        // Host tests: a compiler barrier is enough on one thread
        else => asm volatile ("" ::: .{ .memory = true }),
    }
}

// ┌───────────────────────────────────────────────────────────────────────────┐
// │ Badge glue                                                                │
// └───────────────────────────────────────────────────────────────────────────┘

var service_stats: Stats = .{};
var service_state: State = .closed;

/// Cart RAM: process RAM after the IPC block, where badge_cart.ld links carts
fn cart_memory() Memory {
    const start: u32 = @intCast(@intFromPtr(abi.ipc_data) + @sizeOf(abi.CartIPCData));
    const end = loader.getCartRamEnd();
    const bytes: [*]volatile u8 = @ptrFromInt(start);
    return .{ .base = start, .bytes = bytes[0 .. end - start] };
}

fn cart_running() bool {
    const cart_state = loader.getState();
    return cart_state == .running or cart_state == .ready;
}

/// Call once at boot: whatever process RAM holds after reset is not a cart's
pub fn init() void {
    detach();
}

/// Call from the kernel main loop, next to `usb.poll`
pub fn poll() void {
    const port = usb.cart_port();
    if (!cart_running()) {
        service_state = .closed;
        if (port.received()) |pkt| {
            service_stats.rx_dropped +%= @intCast(pkt.len);
            port.release();
        }
        return;
    }

    const addr: u32 = @intCast(@intFromPtr(abi.ipc_data.cart_serial));
    service_state = service(cart_memory(), addr, port, &service_stats);
}

/// Closes the port on the OS side. Core 1 is halted when this runs (cart stop),
/// or about to start a new cart, so the cart's rings are gone: forget them and
/// never touch that memory again. The host side of the port stays open.
pub fn detach() void {
    abi.ipc_data.cart_serial = null;
    abi.ipc_data.os_flags.cart_serial_supported = true;
    service_state = .closed;
}

pub const Info = struct {
    state: State,
    host_open: bool,
    rx_queued: u32,
    tx_queued: u32,
    /// Bytes of a packet from the host waiting for room in the rx ring
    rx_pending: usize,
    stats: Stats,
};

/// For the console's `id` command
pub fn info() Info {
    const port = usb.cart_port();
    var result: Info = .{
        .state = service_state,
        .host_open = port.connected(),
        .rx_queued = 0,
        .tx_queued = 0,
        .rx_pending = if (port.received()) |pkt| pkt.len else 0,
        .stats = service_stats,
    };
    if (service_state == .open and cart_running()) {
        if (validate(cart_memory(), @intCast(@intFromPtr(abi.ipc_data.cart_serial)))) |rings| {
            result.rx_queued = rings.rx_queued();
            result.tx_queued = rings.tx_queued();
        }
    }
    return result;
}

// ┌───────────────────────────────────────────────────────────────────────────┐
// │ Tests                                                                     │
// └───────────────────────────────────────────────────────────────────────────┘

const testing = std.testing;

/// Cart RAM with a struct at the start and the rings after it
const TestCart = struct {
    const base = 0x2003_5100;
    const struct_addr = base;
    const rx_addr = base + 0x100;
    const tx_addr = base + 0x200;

    ram: [0x400]u8 align(4) = @splat(0xAA),

    fn mem(cart: *TestCart) Memory {
        return .{ .base = base, .bytes = &cart.ram };
    }

    fn words(cart: *TestCart) *[word_count]u32 {
        return @ptrCast(&cart.ram);
    }

    fn word(cart: *TestCart, comptime w: Word) *u32 {
        return &cart.words()[@backingInt(w)];
    }

    /// What the cart does to open the port
    fn open(cart: *TestCart, rx_cap: u32, tx_cap: u32) void {
        cart.words().* = .{ magic, rx_addr, rx_cap, 0, 0, tx_addr, tx_cap, 0, 0, 0 };
    }

    fn status(cart: *TestCart) abi.CartSerialStatus {
        return @bitCast(cart.word(.status).*);
    }

    /// The cart writes to its tx ring, returns how many bytes fit
    fn cart_write(cart: *TestCart, data: []const u8) usize {
        const cap = cart.word(.tx_cap).*;
        const write = cart.word(.tx_write).*;
        const free = cap - (write -% cart.word(.tx_read).*);
        const n = @min(free, data.len);
        for (data[0..n], 0..) |byte, i| {
            cart.ram[tx_addr - base + ((write +% @as(u32, @intCast(i))) & (cap - 1))] = byte;
        }
        cart.word(.tx_write).* = write +% @as(u32, @intCast(n));
        return n;
    }

    /// The cart reads from its rx ring
    fn cart_read(cart: *TestCart, out: []u8) usize {
        const cap = cart.word(.rx_cap).*;
        const read = cart.word(.rx_read).*;
        const n = @min(out.len, cart.word(.rx_write).* -% read);
        for (out[0..n], 0..) |*byte, i| {
            byte.* = cart.ram[rx_addr - base + ((read +% @as(u32, @intCast(i))) & (cap - 1))];
        }
        cart.word(.rx_read).* = read +% @as(u32, @intCast(n));
        return n;
    }
};

fn pattern(comptime len: usize, seed: u8) [len]u8 {
    var out: [len]u8 = undefined;
    for (&out, 0..) |*byte, i| byte.* = seed +% @as(u8, @truncate(i));
    return out;
}

test "host to cart and back" {
    var cart: TestCart = .{};
    var port: cdc.FakePort = .{ .dtr = true };
    defer port.deinit();
    var s: Stats = .{};

    cart.open(64, 64);
    try testing.expectEqual(.open, service(cart.mem(), TestCart.struct_addr, &port, &s));
    try testing.expect(cart.status().attached);
    try testing.expect(cart.status().host_open);

    try port.host_send("hello");
    _ = service(cart.mem(), TestCart.struct_addr, &port, &s);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("hello", buf[0..cart.cart_read(&buf)]);
    try testing.expectEqual(null, port.holding);

    try testing.expectEqual(3, cart.cart_write("hi!"));
    _ = service(cart.mem(), TestCart.struct_addr, &port, &s);
    try testing.expectEqual(1, port.sent.items.len);
    try testing.expectEqualStrings("hi!", port.sent.items[0]);
    try testing.expectEqual(3, cart.word(.tx_read).*);

    try testing.expectEqual(5, s.rx_bytes);
    try testing.expectEqual(3, s.tx_bytes);
}

test "indices wrap around at 2^32" {
    var cart: TestCart = .{};
    var port: cdc.FakePort = .{ .dtr = true };
    defer port.deinit();
    var s: Stats = .{};

    cart.open(64, 64);
    const start: u32 = 0xFFFF_FFF0;
    inline for (.{ Word.rx_write, Word.rx_read, Word.tx_write, Word.tx_read }) |w| cart.word(w).* = start;

    // 40 bytes in, crossing 2^32 after 16
    const in = pattern(40, 1);
    try port.host_send(&in);
    _ = service(cart.mem(), TestCart.struct_addr, &port, &s);
    try testing.expectEqual(start +% 40, cart.word(.rx_write).*);
    try testing.expectEqual(24, cart.word(.rx_write).*);
    var buf: [64]u8 = undefined;
    try testing.expectEqualSlices(u8, &in, buf[0..cart.cart_read(&buf)]);

    // 40 bytes out, same crossing
    const out = pattern(40, 100);
    try testing.expectEqual(40, cart.cart_write(&out));
    _ = service(cart.mem(), TestCart.struct_addr, &port, &s);
    try testing.expectEqualSlices(u8, &out, port.sent.items[0]);
    try testing.expectEqual(24, cart.word(.tx_read).*);
}

test "a full rx ring holds the packet back, nothing is lost" {
    var cart: TestCart = .{};
    var port: cdc.FakePort = .{ .dtr = true };
    defer port.deinit();
    var s: Stats = .{};

    cart.open(64, 64);
    const first = pattern(60, 0);
    try port.host_send(&first);
    _ = service(cart.mem(), TestCart.struct_addr, &port, &s);
    try testing.expectEqual(60, cart.word(.rx_write).*);

    // 4 bytes of room, the 10 byte packet waits in the endpoint (host NAKed)
    const second = pattern(10, 60);
    try port.host_send(&second);
    for (0..3) |_| _ = service(cart.mem(), TestCart.struct_addr, &port, &s);
    try testing.expect(port.holding != null);
    try testing.expectEqual(60, cart.word(.rx_write).*);

    // The cart reads 6 bytes, now all 10 fit
    var buf: [70]u8 = undefined;
    try testing.expectEqual(6, cart.cart_read(buf[0..6]));
    _ = service(cart.mem(), TestCart.struct_addr, &port, &s);
    try testing.expectEqual(null, port.holding);
    try testing.expectEqual(70, cart.word(.rx_write).*);

    const n = cart.cart_read(buf[6..]);
    try testing.expectEqual(64, n);
    try testing.expectEqualSlices(u8, &(first ++ second), buf[0..70]);
    try testing.expectEqual(0, s.rx_dropped);
}

test "cart output is dropped while the host has the port closed" {
    var cart: TestCart = .{};
    var port: cdc.FakePort = .{ .dtr = false };
    defer port.deinit();
    var s: Stats = .{};

    cart.open(64, 128);
    try testing.expectEqual(100, cart.cart_write(&pattern(100, 0)));
    _ = service(cart.mem(), TestCart.struct_addr, &port, &s);
    try testing.expectEqual(0, port.sent.items.len);
    try testing.expectEqual(100, cart.word(.tx_read).*);
    try testing.expectEqual(100, s.tx_dropped);
    try testing.expect(!cart.status().host_open);
    try testing.expect(cart.status().attached);

    // The cart can keep writing, the ring never fills
    try testing.expectEqual(128, cart.cart_write(&pattern(128, 0)));
    _ = service(cart.mem(), TestCart.struct_addr, &port, &s);
    try testing.expectEqual(0, cart.word(.tx_write).* -% cart.word(.tx_read).*);

    // The host opens the port: only new output arrives
    port.dtr = true;
    try testing.expectEqual(2, cart.cart_write("ok"));
    _ = service(cart.mem(), TestCart.struct_addr, &port, &s);
    try testing.expect(cart.status().host_open);
    try testing.expectEqual(1, port.sent.items.len);
    try testing.expectEqualStrings("ok", port.sent.items[0]);
}

test "host data is received while DTR is low" {
    var cart: TestCart = .{};
    var port: cdc.FakePort = .{ .dtr = false };
    defer port.deinit();
    var s: Stats = .{};

    cart.open(64, 64);
    try port.host_send("abc");
    _ = service(cart.mem(), TestCart.struct_addr, &port, &s);
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings("abc", buf[0..cart.cart_read(&buf)]);
}

test "output ending on a full packet is followed by a zero length packet" {
    var cart: TestCart = .{};
    var port: cdc.FakePort = .{ .dtr = true };
    defer port.deinit();
    var s: Stats = .{};

    cart.open(64, 128);
    try testing.expectEqual(64, cart.cart_write(&pattern(64, 0)));
    _ = service(cart.mem(), TestCart.struct_addr, &port, &s);
    port.host_read();
    _ = service(cart.mem(), TestCart.struct_addr, &port, &s);
    try testing.expectEqual(2, port.sent.items.len);
    try testing.expectEqual(64, port.sent.items[0].len);
    try testing.expectEqual(0, port.sent.items[1].len);
}

test "no rings: host data is dropped" {
    var cart: TestCart = .{};
    var port: cdc.FakePort = .{ .dtr = true };
    defer port.deinit();
    var s: Stats = .{};

    try port.host_send("lost");
    try testing.expectEqual(.closed, service(cart.mem(), 0, &port, &s));
    try testing.expectEqual(null, port.holding);
    try testing.expectEqual(4, s.rx_dropped);
}

test "invalid rings are rejected" {
    var cart: TestCart = .{};
    var port: cdc.FakePort = .{ .dtr = true };
    defer port.deinit();
    var s: Stats = .{};
    const addr = TestCart.struct_addr;

    cart.open(64, 64);
    try testing.expect(validate(cart.mem(), addr) != null);

    // Struct address
    try testing.expect(validate(cart.mem(), addr + 2) == null); // misaligned
    try testing.expect(validate(cart.mem(), addr - 4) == null); // before cart RAM
    try testing.expect(validate(cart.mem(), TestCart.base + 0x400 - 36) == null); // runs past the end
    try testing.expect(validate(cart.mem(), TestCart.base + 0x400) == null); // past the end

    const cases = [_]struct { word: Word, value: u32 }{
        .{ .word = .magic, .value = magic + 1 },
        .{ .word = .rx_cap, .value = 32 }, // too small
        .{ .word = .tx_cap, .value = 96 }, // not a power of two
        .{ .word = .rx_cap, .value = 0 },
        .{ .word = .tx_cap, .value = 0x8000_0000 }, // larger than RAM
        .{ .word = .rx_buf, .value = TestCart.base - 64 }, // before cart RAM
        .{ .word = .tx_buf, .value = TestCart.base + 0x400 - 32 }, // runs past the end
        .{ .word = .tx_buf, .value = 0xFFFF_FFC0 }, // address arithmetic would overflow
        .{ .word = .rx_buf, .value = TestCart.struct_addr }, // over the struct
        .{ .word = .tx_buf, .value = TestCart.rx_addr + 32 }, // over the rx ring
    };
    for (cases) |case| {
        cart.open(64, 64);
        switch (case.word) {
            inline else => |w| cart.word(w).* = case.value,
        }
        try testing.expect(validate(cart.mem(), addr) == null);

        // The service treats it as closed and never writes the struct
        try port.host_send("x");
        try testing.expectEqual(.invalid, service(cart.mem(), addr, &port, &s));
        try testing.expectEqual(null, port.holding);
        try testing.expectEqual(0, cart.word(.status).*);
    }
}

test "nonsense tx indices are dropped, not sent" {
    var cart: TestCart = .{};
    var port: cdc.FakePort = .{ .dtr = true };
    defer port.deinit();
    var s: Stats = .{};

    cart.open(64, 64);
    cart.word(.tx_write).* = 1000; // more than the capacity queued
    _ = service(cart.mem(), TestCart.struct_addr, &port, &s);
    try testing.expectEqual(0, port.sent.items.len);
    try testing.expectEqual(1000, cart.word(.tx_read).*);
}

test "struct layout matches the ABI" {
    // CART_SERIAL.md documents byte offsets; the word order must match them
    try testing.expectEqual(10, word_count);
    try testing.expectEqual(3, @backingInt(Word.rx_write));
    try testing.expectEqual(8, @backingInt(Word.tx_read));
    try testing.expectEqual(9, @backingInt(Word.status));
    try testing.expectEqual(0b10, @as(u32, @bitCast(abi.CartSerialStatus{ .attached = true })));
}
