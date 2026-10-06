//! Cart files: OS glue between the cart's CART_FILE_REQ mailbox message (ABI
//! v1, cart/os_abi.zig, fork/CART_FILES.md) and loader/fat_write.zig over the
//! USB drives (storage.zig).
//!
//! - kernel.handle_cart_message hands every CART_FILE_REQ to onMessage(), which
//!   validates the request and either answers it at once (probe, stat, create,
//!   abort, errors) or starts a write/commit.
//! - kernel's main loop calls poll(): one fat_write step per pass (one 4 KB
//!   erase + program in one critical section, then a read-back), so USB and
//!   audio keep being polled between steps. The cart is parked meanwhile, its
//!   interrupts masked, spinning in RAM (as for cart saves).
//! - The cart's buffered audio is stopped for a write/commit and restarted after.
//! - One request at a time; another one while a write/commit is in flight is
//!   answered `busy` at once. One open file.
//! - Refused with `usb_host` while a USB host has configured the device, and
//!   for an open file once a host appeared since its create (usb.zig).
//! - The OS answers only through the request struct: state pending -> busy ->
//!   done; status, result and flags written before state = done (with dmb).
//! - cartReset() (multicore.haltCore1 / executeCart) aborts the open file.
const std = @import("std");
const abi = @import("../cart/os_abi.zig");
const fat_write = @import("../loader/fat_write.zig");
const storage = @import("../loader/storage.zig");
const storage_disk = @import("../loader/storage_disk.zig");
const usb = @import("../drivers/usb.zig");
const audio = @import("../drivers/audio.zig");
const timer = @import("../drivers/timer.zig");
const log = std.log.scoped(.cart_files);

extern const __process_ram_start__: u8;
extern const __process_ram_end__: u8;

// The cart ABI mirrors fat_write's types: keep them identical.
comptime {
    const st = @typeInfo(fat_write.Status).@"enum";
    for (st.field_names, st.field_values) |name, value| {
        if (@backingInt(@field(abi.FileStatus, name)) != value)
            @compileError("FileStatus." ++ name ++ " differs from fat_write.Status");
    }
    if (@sizeOf(abi.FileStat) != @sizeOf(fat_write.Stat)) @compileError("FileStat size");
    for (@typeInfo(abi.FileStat).@"struct".field_names) |name| {
        if (@offsetOf(abi.FileStat, name) != @offsetOf(fat_write.Stat, name)) @compileError("FileStat." ++ name);
    }
    std.debug.assert(fat_write.max_write == 4096);
}

var writer: fat_write.Writer = .{};
/// Volume of the open file.
var open_volume: u8 = 0;
/// usb.hostGeneration() when the open file was created.
var open_generation: u32 = 0;
/// The open file's name (fat_write keeps its own copy; this is the cart's bytes).
var name_buf: [fat_write.max_name]u8 = undefined;

const Active = struct {
    req_addr: u32,
    op: abi.FileOp,
    audio_was_running: bool,
    start_us: u64,
};

/// The write/commit being stepped by poll(), if any.
var active: ?Active = null;

// ┌───────────────────────────────────────────────────────────────────────────┐
// │ Kernel interface                                                          │
// └───────────────────────────────────────────────────────────────────────────┘

/// Abort the open file (and a write/commit in flight). Called on cart start
/// and stop (multicore.executeCart / haltCore1), on core 0, between steps:
/// every step ends flushed. Before commit the drive is unchanged; stopped
/// inside commit it can have lost clusters (as after a power cut there),
/// never a cross-linked or half-visible file.
pub fn cartReset() void {
    if (active != null) {
        log.warn("cart stopped during a file request: aborted", .{});
        active = null;
        // Audio is reset with the cart; don't restart it.
    }
    if (writer.isOpen()) writer.abort();
}

/// True while a write/commit is being stepped.
pub fn isBusy() bool {
    return active != null;
}

/// kernel.handle_cart_message: CART_FILE_REQ with payload = (addr - 0x20000000) / 4.
pub fn onMessage(payload: u24) void {
    const addr: u32 = 0x20000000 + @as(u32, payload) * 4;
    if (!inCartRam(addr, @sizeOf(abi.FileRequest))) {
        // Can't answer: the struct isn't somewhere we may write.
        log.warn("file request at 0x{X} outside cart RAM: ignored", .{addr});
        return;
    }
    const req: *volatile abi.FileRequest = @ptrFromInt(addr);

    // A client that gave up on a request zeroes its magic: leave it alone.
    if (req.magic == 0) return;

    if (active) |a| {
        // The in-flight request is answered when it finishes; a different one
        // is told to come back later.
        if (a.req_addr != addr) finish(req, .busy, 0);
        return;
    }

    req.state = .busy;
    dmb();
    serve(req, addr);
}

/// kernel main loop: advance an in-flight write/commit by one erase block.
pub fn poll() void {
    const a = active orelse return;
    switch (writer.step()) {
        .more => {},
        .done => |status| {
            active = null;
            const req: *volatile abi.FileRequest = @ptrFromInt(a.req_addr);
            const result: u32 = if (status != .ok) 0 else if (a.op == .write) writer.written else writer.size;
            finish(req, toAbi(status), result);
            if (a.audio_was_running) audio.start_buffered();
            log.info("file {s} done: {s} in {d} ms", .{
                @tagName(a.op),
                @tagName(status),
                (timer.micros() - a.start_us) / 1000,
            });
        },
    }
}

// ┌───────────────────────────────────────────────────────────────────────────┐
// │ Request handling                                                          │
// └───────────────────────────────────────────────────────────────────────────┘

inline fn dmb() void {
    asm volatile ("dmb" ::: .{ .memory = true });
}

fn currentFlags() abi.FileFlags {
    return .{
        .usb_host = usb.hostHasDrive(),
        .ext_volume = storage.volumeCount() > 1,
    };
}

fn finish(req: *volatile abi.FileRequest, status: abi.FileStatus, result: u32) void {
    req.status = status;
    req.result = result;
    req.flags = @bitCast(currentFlags());
    dmb();
    req.state = .done;
    dmb();
}

fn toAbi(s: fat_write.Status) abi.FileStatus {
    return @fromBackingInt(@backingInt(s));
}

/// [addr, addr+len) lies in process RAM past the cart IPC block.
fn inCartRam(addr: u32, len: u32) bool {
    const lo: u32 = @intFromPtr(&__process_ram_start__) + @sizeOf(abi.CartIPCData);
    const hi: u32 = @intFromPtr(&__process_ram_end__);
    return addr >= lo and addr <= hi and len <= hi - addr;
}

/// A host has the drive now, or appeared since the open file was created.
fn hostBlocksOpenFile() bool {
    return usb.hostHasDrive() or usb.hostGeneration() != open_generation;
}

fn serve(req: *volatile abi.FileRequest, addr: u32) void {
    if (req.magic != abi.FILE_MAGIC) return finish(req, .bad_request, 0);
    const op = req.op;
    const buf = req.buf;
    const len = req.len;
    const volume = req.volume;

    switch (op) {
        .probe => finish(req, .ok, abi.FILE_ABI_VERSION),
        .stat => {
            if (volume >= storage.volumeCount()) return finish(req, .no_volume, 0);
            const v: u8 = @intCast(volume);
            const s = writer.stat(storage_disk.disk(v), writer.isOpen() and open_volume == v) orelse
                return finish(req, .no_volume, 0);
            if (len != 0) {
                // Copy min(len, @sizeOf(FileStat)) bytes, byte by byte (any alignment).
                const n: u32 = @min(len, @sizeOf(abi.FileStat));
                if (!inCartRam(buf, n)) return finish(req, .bad_buffer, 0);
                const bytes = std.mem.asBytes(&s);
                const out: [*]volatile u8 = @ptrFromInt(buf);
                for (0..n) |i| out[i] = bytes[i];
            }
            finish(req, .ok, s.free_bytes);
        },
        .create => {
            if (writer.isOpen()) return finish(req, .bad_request, 0);
            if (usb.hostHasDrive()) return finish(req, .usb_host, 0);
            if (volume >= storage.volumeCount()) return finish(req, .no_volume, 0);
            if (len == 0 or len > fat_write.max_name) return finish(req, .bad_name, 0);
            if (!inCartRam(buf, len)) return finish(req, .bad_buffer, 0);
            const src: [*]const volatile u8 = @ptrFromInt(buf);
            for (0..len) |i| name_buf[i] = src[i];
            const v: u8 = @intCast(volume);
            const status = writer.create(storage_disk.disk(v), name_buf[0..len], req.offset);
            if (status != .ok) return finish(req, toAbi(status), 0);
            open_volume = v;
            open_generation = usb.hostGeneration();
            log.info("file create '{s}' ({d} bytes) on volume {d}", .{ name_buf[0..len], req.offset, v });
            finish(req, .ok, writer.cluster_count * fat_write.sector_size);
        },
        .write, .commit => {
            if (!writer.isOpen()) return finish(req, .not_open, 0);
            if (hostBlocksOpenFile()) return finish(req, .usb_host, 0);
            const status = if (op == .write) blk: {
                if (len == 0 or len > fat_write.max_write) return finish(req, .bad_request, 0);
                if (!inCartRam(buf, len)) return finish(req, .bad_buffer, 0);
                const data = @as([*]const u8, @ptrFromInt(buf))[0..len];
                break :blk writer.beginWrite(req.offset, data);
            } else writer.beginCommit();
            if (status != .ok) return finish(req, toAbi(status), 0);

            // Started: the cart is parked in its wait loop until poll() finishes.
            const audio_was_running = audio.is_buffered_running();
            if (audio_was_running) audio.stop_buffered();
            active = .{
                .req_addr = addr,
                .op = op,
                .audio_was_running = audio_was_running,
                .start_us = timer.micros(),
            };
        },
        .abort => {
            if (!writer.isOpen()) return finish(req, .not_open, 0);
            writer.abort();
            finish(req, .ok, 0);
        },
        else => finish(req, .bad_request, 0),
    }
}
