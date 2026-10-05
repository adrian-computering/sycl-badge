//! Cart saves: OS glue between the cart's CART_SAVE_REQ mailbox message
//! (ABI v1, cart/os_abi.zig) and the save store (save_store.zig) in the
//! internal-flash region at __saves_region_start__ (the old cart_xip window).
//!
//! - kernel.handle_cart_message hands every CART_SAVE_REQ to onMessage(), which
//!   validates the request and either answers it at once (probe, read, stat,
//!   list, exit_watch, errors) or starts a store write/delete.
//! - kernel's main loop calls poll(): one store.step() per pass (at most one
//!   4 KB erase + its page programs, or one verify, inside one critical
//!   section), so USB and audio keep being polled between steps.
//! - The cart's buffered audio is stopped for a write/delete and restarted after
//!   (the DMA ping-pong would replay a stale buffer while interrupts are off).
//! - One request at a time; another one while a write/delete is in flight is
//!   answered `busy` at once.
//! - The OS answers only through the request struct: state pending -> busy ->
//!   done, status/result written before state = done (with dmb).
//! - cartReset() (multicore.haltCore1 / executeCart) aborts an in-flight
//!   write/delete and forgets the exit word.
//! - Exit hook: settings "Exit cart" -> kernel.request_cart_exit -> beginExit()
//!   writes 1 to the cart's exit word; the kernel keeps serving requests until
//!   exitReady() (the cart wrote 2, or 3 s passed), then stops the cart.
//!
//! The Flash backend (flashRead/flashErase/flashProgram) is the only code that
//! erases or programs the save region; it refuses offsets outside it.
const std = @import("std");
const abi = @import("../cart/os_abi.zig");
const save_store = @import("save_store.zig");
const flash_ops = @import("../drivers/flash_ops.zig");
const audio = @import("../drivers/audio.zig");
const timer = @import("../drivers/timer.zig");
const log = std.log.scoped(.saves);

extern const __saves_region_start__: u8;
extern const __saves_region_end__: u8;
extern const __process_ram_start__: u8;
extern const __process_ram_end__: u8;

// The cart ABI mirrors the store's types: keep them identical.
comptime {
    const st = @typeInfo(save_store.Status).@"enum";
    for (st.field_names, st.field_values) |name, value| {
        if (@backingInt(@field(abi.SaveStatus, name)) != value)
            @compileError("SaveStatus." ++ name ++ " differs from save_store.Status");
    }
    const at = @typeInfo(abi.SaveStatus).@"enum";
    for (at.field_names) |name| {
        if (!@hasField(save_store.Status, name))
            @compileError("SaveStatus." ++ name ++ " missing from save_store.Status");
    }
    sameLayout(abi.SaveStat, save_store.Stat);
    sameLayout(abi.SaveListEntry, save_store.ListEntry);
    std.debug.assert(save_store.max_key == 32);
}

fn sameLayout(comptime A: type, comptime B: type) void {
    if (@sizeOf(A) != @sizeOf(B)) @compileError("size mismatch: " ++ @typeName(A));
    for (@typeInfo(A).@"struct".field_names) |name| {
        if (@offsetOf(A, name) != @offsetOf(B, name)) @compileError("field offset mismatch: " ++ name);
    }
}

/// Time a cart gets to save after an exit request.
pub const exit_timeout_us: u64 = 3_000_000;

var store: save_store.Store = undefined;
var mounted: bool = false;

const Active = struct {
    req_addr: u32,
    op: abi.SaveOp,
    len: u32,
    audio_was_running: bool,
    start_us: u64,
};

/// The write/delete being stepped by poll(), if any.
var active: ?Active = null;
/// The in-flight op's key; the store may refer to it until the op is done.
var active_key: [save_store.max_key]u8 = undefined;

/// Address of the cart's exit word (0 = none registered).
var exit_word_addr: u32 = 0;
var exiting: bool = false;
var exit_deadline_us: u64 = 0;

// ┌───────────────────────────────────────────────────────────────────────────┐
// │ Region and Flash backend                                                  │
// └───────────────────────────────────────────────────────────────────────────┘

pub fn regionStart() u32 {
    return @intFromPtr(&__saves_region_start__);
}

pub fn regionEnd() u32 {
    return @intFromPtr(&__saves_region_end__);
}

fn regionSize() u32 {
    return regionEnd() - regionStart();
}

/// Bootrom flash offset of the region's first byte.
fn regionFlashOffset() u32 {
    return regionStart() - flash_ops.XIP_BASE;
}

var flash_ctx: u8 = 0;

fn flashBackend() save_store.Flash {
    return .{
        .ctx = &flash_ctx,
        .read = flashRead,
        .erase4k = flashErase,
        .program = flashProgram,
    };
}

/// Plain read through the cached XIP window (flash_ops flushes the cache after
/// every erase/program).
fn flashRead(_: *anyopaque, off: u32, dst: []u8) void {
    const size = regionSize();
    if (off >= size) {
        @memset(dst, 0xFF);
        return;
    }
    const n = @min(dst.len, size - off);
    const src: [*]const u8 = @ptrFromInt(regionStart() + off);
    @memcpy(dst[0..n], src[0..n]);
    if (n < dst.len) @memset(dst[n..], 0xFF);
}

fn flashErase(_: *anyopaque, off: u32) void {
    if (off % flash_ops.sector_size != 0 or off >= regionSize()) {
        log.err("refusing erase at region offset 0x{X}", .{off});
        return;
    }
    flash_ops.erase(regionFlashOffset() + off, flash_ops.sector_size);
}

fn flashProgram(_: *anyopaque, off: u32, src: []const u8) void {
    const size = regionSize();
    if (off >= size or src.len > size - off) {
        log.err("refusing program at region offset 0x{X} len {d}", .{ off, src.len });
        return;
    }
    flash_ops.programAny(regionFlashOffset() + off, src);
}

// ┌───────────────────────────────────────────────────────────────────────────┐
// │ Kernel interface                                                          │
// └───────────────────────────────────────────────────────────────────────────┘

/// Mount the store (reads only; a fresh region is formatted by the store on the
/// first write, never at boot).
pub fn init() void {
    const want = save_store.block_size * save_store.block_count;
    if (regionSize() != want) {
        log.err("save region is {d} bytes, store wants {d}: saves disabled", .{ regionSize(), want });
        return;
    }
    store.init(flashBackend(), timer.micros());
    mounted = true;
    const s = store.stat(timer.micros());
    log.info("save store: {d} entries, {d} bytes free", .{ s.entries, s.free_bytes });
}

/// Forget the cart's exit word and abort any in-flight request. Called on cart
/// start and stop (multicore.executeCart / haltCore1), on core 0.
pub fn cartReset() void {
    if (active != null) {
        log.warn("cart stopped during a save request: aborted", .{});
        store.abort();
        active = null;
        // Audio is reset with the cart; don't restart it.
    }
    exit_word_addr = 0;
    exiting = false;
}

/// True while a write/delete is being stepped.
pub fn isBusy() bool {
    return active != null;
}

/// kernel.handle_cart_message: CART_SAVE_REQ with payload = (addr - 0x20000000) / 4.
pub fn onMessage(payload: u24) void {
    const addr: u32 = 0x20000000 + @as(u32, payload) * 4;
    if (!inCartRam(addr, @sizeOf(abi.SaveRequest))) {
        // Can't answer: the struct isn't somewhere we may write.
        log.warn("save request at 0x{X} outside cart RAM: ignored", .{addr});
        return;
    }
    const req: *volatile abi.SaveRequest = @ptrFromInt(addr);

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

/// kernel main loop: advance an in-flight write/delete by one store step.
pub fn poll() void {
    const a = active orelse return;
    switch (store.step()) {
        .more => {},
        .done => |status| {
            active = null;
            const req: *volatile abi.SaveRequest = @ptrFromInt(a.req_addr);
            finish(req, toAbi(status), if (a.op == .write and status == .ok) a.len else 0);
            if (a.audio_was_running) audio.start_buffered();
            log.info("save {s} done: {s} in {d} ms", .{
                @tagName(a.op),
                @tagName(status),
                (timer.micros() - a.start_us) / 1000,
            });
        },
    }
}

/// settings "Exit cart": ask the cart to save first. Returns false if the cart
/// registered no exit word (stop it right away).
pub fn beginExit(now_us: u64) bool {
    if (exit_word_addr == 0) return false;
    const word: *volatile u32 = @ptrFromInt(exit_word_addr);
    word.* = abi.EXIT_WORD_REQUESTED;
    dmb();
    exiting = true;
    exit_deadline_us = now_us + exit_timeout_us;
    return true;
}

/// True once the cart may be stopped: it wrote 2 to its exit word (and no
/// request is in flight), or the timeout passed.
pub fn exitReady(now_us: u64) bool {
    if (!exiting or exit_word_addr == 0) return true;
    if (now_us >= exit_deadline_us) {
        log.warn("cart did not finish saving within {d} ms", .{exit_timeout_us / 1000});
        return true;
    }
    dmb();
    const word: *const volatile u32 = @ptrFromInt(exit_word_addr);
    return word.* == abi.EXIT_WORD_READY and active == null;
}

// ┌───────────────────────────────────────────────────────────────────────────┐
// │ Request handling                                                          │
// └───────────────────────────────────────────────────────────────────────────┘

inline fn dmb() void {
    asm volatile ("dmb" ::: .{ .memory = true });
}

fn finish(req: *volatile abi.SaveRequest, status: abi.SaveStatus, result: u32) void {
    req.status = status;
    req.result = result;
    dmb();
    req.state = .done;
    dmb();
}

fn toAbi(s: save_store.Status) abi.SaveStatus {
    return @fromBackingInt(@backingInt(s));
}

/// [addr, addr+len) lies in process RAM past the cart IPC block.
fn inCartRam(addr: u32, len: u32) bool {
    const lo: u32 = @intFromPtr(&__process_ram_start__) + @sizeOf(abi.CartIPCData);
    const hi: u32 = @intFromPtr(&__process_ram_end__);
    return addr >= lo and addr <= hi and len <= hi - addr;
}

/// Copy and check the key: 1..32 bytes, each 0x20..0x7E.
fn takeKey(req: *volatile abi.SaveRequest) ?[]const u8 {
    const n = req.key_len;
    if (n == 0 or n > save_store.max_key) return null;
    for (0..n) |i| {
        const c = req.key[i];
        if (c < 0x20 or c > 0x7E) return null;
        active_key[i] = c;
    }
    return active_key[0..n];
}

fn serve(req: *volatile abi.SaveRequest, addr: u32) void {
    if (req.magic != abi.SAVE_MAGIC) return finish(req, .bad_request, 0);
    const op = req.op;
    if (op == .probe) return finish(req, .ok, abi.SAVE_ABI_VERSION);
    if (!mounted) return finish(req, .io_error, 0);

    const buf = req.buf;
    const len = req.len;
    const now = timer.micros();

    switch (op) {
        .read => {
            const key = takeKey(req) orelse return finish(req, .bad_request, 0);
            if (len > 0 and !inCartRam(buf, len)) return finish(req, .bad_buffer, 0);
            const dst: []u8 = if (len > 0) @as([*]u8, @ptrFromInt(buf))[0..len] else &.{};
            const r = store.read(key, dst);
            finish(req, toAbi(r.status), r.size);
        },
        .write, .delete => {
            const key = takeKey(req) orelse return finish(req, .bad_request, 0);
            const status = if (op == .write) blk: {
                if (len == 0) return finish(req, .bad_request, 0);
                if (len > save_store.max_blob) return finish(req, .too_big, 0);
                if (!inCartRam(buf, len)) return finish(req, .bad_buffer, 0);
                const src = @as([*]const u8, @ptrFromInt(buf))[0..len];
                break :blk store.beginWrite(key, src, now);
            } else store.beginDelete(key, now);
            if (status != .ok) return finish(req, toAbi(status), 0);

            // Started: the cart is parked in its wait loop until poll() finishes.
            const audio_was_running = audio.is_buffered_running();
            if (audio_was_running) audio.stop_buffered();
            active = .{
                .req_addr = addr,
                .op = op,
                .len = len,
                .audio_was_running = audio_was_running,
                .start_us = now,
            };
        },
        .stat => {
            const s = store.stat(now);
            if (len != 0) {
                // Copy min(len, @sizeOf(SaveStat)) bytes, byte by byte (any alignment).
                const n: u32 = @min(len, @sizeOf(abi.SaveStat));
                if (!inCartRam(buf, n)) return finish(req, .bad_buffer, 0);
                const bytes = std.mem.asBytes(&s);
                const out: [*]volatile u8 = @ptrFromInt(buf);
                for (0..n) |i| out[i] = bytes[i];
            }
            finish(req, .ok, s.free_bytes);
        },
        .list => {
            const n = @min(len / @sizeOf(abi.SaveListEntry), save_store.max_entries);
            if (n == 0) return finish(req, .ok, 0);
            const bytes = n * @sizeOf(abi.SaveListEntry);
            if (buf % 4 != 0 or !inCartRam(buf, bytes)) return finish(req, .bad_buffer, 0);
            const out = @as([*]save_store.ListEntry, @ptrFromInt(buf))[0..n];
            finish(req, .ok, store.list(out));
        },
        .exit_watch => {
            if (buf == 0) {
                exit_word_addr = 0;
                exiting = false;
            } else {
                if (buf % 4 != 0 or !inCartRam(buf, 4)) return finish(req, .bad_buffer, 0);
                exit_word_addr = buf;
            }
            finish(req, .ok, 0);
        },
        else => finish(req, .bad_request, 0),
    }
}
