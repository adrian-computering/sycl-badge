//! Host tests for save_store.zig against a simulated NOR flash with power-cut injection.
//! Run with `zig build test` (wired through src/os/test.zig).

const std = @import("std");
const ss = @import("save_store.zig");
const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;

/// Simulated NOR: erase sets 0xFF, program ANDs bits. Counts operations. With `budget`
/// set, the mutating call after `budget` erase/program calls is the power cut: it is
/// skipped (or, with `torn`, half applied) and every later call is a no-op.
const Sim = struct {
    mem: [ss.region_size]u8,
    erase_count: [ss.block_count]u32,
    n_read: u32,
    n_erase: u32,
    n_program: u32,
    mutating: u32,
    budget: ?u32,
    torn: bool,
    cut: bool,
    /// Program call index (counted like `mutating`) that silently clears one extra bit.
    flip_at: ?u32,
    /// Misuse: misaligned/out-of-range call, or a program over bytes that aren't erased.
    violation: bool,

    fn create(fill: u8) !*Sim {
        const s = try testing.allocator.create(Sim);
        @memset(&s.mem, fill);
        @memset(&s.erase_count, 0);
        s.resetCounters();
        return s;
    }

    fn clone(self: *const Sim) !*Sim {
        const s = try testing.allocator.create(Sim);
        s.* = self.*;
        s.resetCounters();
        return s;
    }

    fn destroy(self: *Sim) void {
        testing.allocator.destroy(self);
    }

    fn resetCounters(s: *Sim) void {
        s.n_read = 0;
        s.n_erase = 0;
        s.n_program = 0;
        s.mutating = 0;
        s.budget = null;
        s.torn = false;
        s.cut = false;
        s.flip_at = null;
        s.violation = false;
    }

    /// Power back on: the cut is over, counters restart.
    fn reboot(s: *Sim) void {
        const v = s.violation;
        s.resetCounters();
        s.violation = v;
    }

    fn flash(s: *Sim) ss.Flash {
        return .{ .ctx = s, .read = readFn, .erase4k = eraseFn, .program = programFn };
    }

    fn mutatingOps(s: *const Sim) u32 {
        return s.n_erase + s.n_program;
    }

    const Effect = enum { full, partial, none };

    fn mutate(s: *Sim) Effect {
        if (s.cut) return .none;
        if (s.budget) |b| if (s.mutating >= b) {
            s.cut = true;
            return if (s.torn) .partial else .none;
        };
        s.mutating += 1;
        return .full;
    }

    fn readFn(ctx: *anyopaque, off: u32, dst: []u8) void {
        const s: *Sim = @ptrCast(@alignCast(ctx));
        if (@as(u64, off) + dst.len > ss.region_size) {
            s.violation = true;
            return;
        }
        if (s.cut) return;
        s.n_read += 1;
        @memcpy(dst, s.mem[off..][0..dst.len]);
    }

    fn eraseFn(ctx: *anyopaque, off: u32) void {
        const s: *Sim = @ptrCast(@alignCast(ctx));
        if (off % ss.block_size != 0 or off >= ss.region_size) {
            s.violation = true;
            return;
        }
        const blk = s.mem[off..][0..ss.block_size];
        switch (s.mutate()) {
            .full => {
                @memset(blk, 0xFF);
                s.erase_count[off / ss.block_size] += 1;
                s.n_erase += 1;
            },
            .partial => @memset(blk[0 .. ss.block_size / 2], 0xFF),
            .none => {},
        }
    }

    fn programFn(ctx: *anyopaque, off: u32, src: []const u8) void {
        const s: *Sim = @ptrCast(@alignCast(ctx));
        if (off % ss.page_size != 0 or src.len % ss.page_size != 0 or src.len == 0 or
            @as(u64, off) + src.len > ss.region_size)
        {
            s.violation = true;
            return;
        }
        const dst = s.mem[off..][0..src.len];
        const idx = s.mutating;
        const n: usize = switch (s.mutate()) {
            .full => src.len,
            .partial => src.len / 2,
            .none => 0,
        };
        for (dst[0..n], src[0..n]) |*d, v| {
            if (d.* != 0xFF) s.violation = true; // programmed twice without an erase
            d.* &= v;
        }
        if (n == src.len) s.n_program += 1;
        if (s.flip_at) |fa| if (fa == idx) {
            for (dst[0..n]) |*d| if (d.* != 0) {
                d.* &= d.* - 1; // clear the lowest set bit
                break;
            };
        };
    }
};

var read_buf: [ss.max_blob + 64]u8 = undefined;

fn mount(st: *ss.Store, sim: *Sim) void {
    st.init(sim.flash(), 0);
}

/// Steps until done; null when the power was cut.
fn run(st: *ss.Store, sim: *Sim) ?ss.Status {
    var guard: u32 = 0;
    while (true) : (guard += 1) {
        if (guard > 1000) @panic("step machine does not terminate");
        if (sim.cut) return null;
        switch (st.step()) {
            .more => {},
            .done => |s| return if (sim.cut) null else s,
        }
    }
}

fn put(st: *ss.Store, sim: *Sim, key: []const u8, data: []const u8, now: u64) !ss.Status {
    const r = st.beginWrite(key, data, now);
    if (r != .ok) {
        try expect(!st.busy());
        return r;
    }
    return run(st, sim) orelse error.PowerCut;
}

fn del(st: *ss.Store, sim: *Sim, key: []const u8, now: u64) !ss.Status {
    const r = st.beginDelete(key, now);
    if (r != .ok) return r;
    return run(st, sim) orelse error.PowerCut;
}

fn putOk(st: *ss.Store, sim: *Sim, key: []const u8, data: []const u8, now: u64) !void {
    try expectEqual(ss.Status.ok, try put(st, sim, key, data, now));
}

/// true when `key` reads back exactly as `want` (null = absent).
fn holds(st: *ss.Store, key: []const u8, want: ?[]const u8) bool {
    const r = st.read(key, &read_buf);
    if (want) |w| {
        return r.status == .ok and r.size == w.len and std.mem.eql(u8, read_buf[0..r.size], w);
    }
    return r.status == .not_found;
}

fn expectBlob(st: *ss.Store, key: []const u8, want: ?[]const u8) !void {
    if (!holds(st, key, want)) {
        std.debug.print("key '{s}' does not hold the expected blob\n", .{key});
        return error.TestUnexpectedResult;
    }
}

fn pattern(buf: []u8, seed: u64) []u8 {
    var prng = std.Random.DefaultPrng.init(seed);
    prng.random().bytes(buf);
    return buf;
}

fn blob(comptime n: usize, seed: u64) ![]u8 {
    const b = try testing.allocator.alloc(u8, n);
    return pattern(b, seed);
}

const KV = struct { key: []const u8, data: ?[]const u8 };

fn expectAll(st: *ss.Store, kvs: []const KV) !void {
    for (kvs) |kv| try expectBlob(st, kv.key, kv.data);
}

// ---------------------------------------------------------------------------------------

test "Store fits the kernel RAM budget" {
    std.debug.print("save_store: @sizeOf(Store) = {d} bytes\n", .{@sizeOf(ss.Store)});
    try expect(@sizeOf(ss.Store) <= 10 * 1024);
}

test "round trip survives remount" {
    const sim = try Sim.create(0xFF);
    defer sim.destroy();
    var st: ss.Store = undefined;
    mount(&st, sim);
    try expectEqual(@as(u32, 0), st.stat(0).entries);
    try expectBlob(&st, "boy/TETRIS", null);

    var b1: [1000]u8 = undefined;
    var b2: [5000]u8 = undefined;
    var b3: [4096]u8 = undefined;
    try putOk(&st, sim, "boy/TETRIS", pattern(&b1, 1), 0);
    try putOk(&st, sim, "paperclips/game", pattern(&b2, 2), 0);
    try putOk(&st, sim, "x", pattern(&b3, 3), 0);
    try expectBlob(&st, "boy/TETRIS", &b1);
    try expectBlob(&st, "paperclips/game", &b2);
    try expectBlob(&st, "x", &b3);
    try expect(!sim.violation);

    var st2: ss.Store = undefined;
    mount(&st2, sim);
    try expectBlob(&st2, "boy/TETRIS", &b1);
    try expectBlob(&st2, "paperclips/game", &b2);
    try expectBlob(&st2, "x", &b3);
    try expectEqual(@as(u32, 3), st2.stat(0).entries);
}

test "overwrite grows and shrinks" {
    const sim = try Sim.create(0xFF);
    defer sim.destroy();
    var st: ss.Store = undefined;
    mount(&st, sim);
    const small = try blob(100, 10);
    defer testing.allocator.free(small);
    const big = try blob(40000, 11);
    defer testing.allocator.free(big);
    const mid = try blob(4097, 12);
    defer testing.allocator.free(mid);

    try putOk(&st, sim, "k", small, 0);
    try putOk(&st, sim, "other", mid, 0);
    try putOk(&st, sim, "k", big, 0);
    try expectBlob(&st, "k", big);
    try putOk(&st, sim, "k", mid, 0);
    try expectBlob(&st, "k", mid);
    try putOk(&st, sim, "k", small, 0);
    try expectBlob(&st, "k", small);
    try expectBlob(&st, "other", mid);
    const s = st.stat(0);
    try expectEqual(@as(u32, 2), s.entries);
    // small = 1 block, mid = 2 blocks: old copies are freed after each overwrite.
    try expectEqual(ss.data_capacity - 3 * ss.block_size, s.free_bytes);

    var st2: ss.Store = undefined;
    mount(&st2, sim);
    try expectBlob(&st2, "k", small);
    try expectBlob(&st2, "other", mid);
    try expect(!sim.violation);
}

test "delete" {
    const sim = try Sim.create(0xFF);
    defer sim.destroy();
    var st: ss.Store = undefined;
    mount(&st, sim);
    var a: [300]u8 = undefined;
    var b: [9000]u8 = undefined;
    try putOk(&st, sim, "a", pattern(&a, 20), 0);
    try putOk(&st, sim, "b", pattern(&b, 21), 0);
    const before = sim.mutatingOps();
    try expectEqual(ss.Status.ok, try del(&st, sim, "b", 0));
    // directory only: 1 erase + 16 pages
    try expectEqual(@as(u32, 17), sim.mutatingOps() - before);
    try expectBlob(&st, "b", null);
    try expectBlob(&st, "a", &a);
    try expectEqual(ss.Status.not_found, try del(&st, sim, "b", 0));
    try expectEqual(ss.data_capacity - ss.block_size, st.stat(0).free_bytes);

    var st2: ss.Store = undefined;
    mount(&st2, sim);
    try expectBlob(&st2, "b", null);
    try expectBlob(&st2, "a", &a);
    try expectEqual(@as(u32, 1), st2.stat(0).entries);
    // the key can come back
    try putOk(&st2, sim, "b", &a, 0);
    try expectBlob(&st2, "b", &a);
}

test "bad requests" {
    const sim = try Sim.create(0xFF);
    defer sim.destroy();
    var st: ss.Store = undefined;
    mount(&st, sim);
    var d: [16]u8 = @splat(7);
    const long_key = "0123456789abcdef0123456789abcdefX"; // 33
    try expectEqual(ss.Status.bad_request, st.beginWrite("", &d, 0));
    try expectEqual(ss.Status.bad_request, st.beginWrite(long_key, &d, 0));
    try expectEqual(ss.Status.bad_request, st.beginWrite("tab\tkey", &d, 0));
    try expectEqual(ss.Status.bad_request, st.beginWrite("k", &.{}, 0));
    try expectEqual(ss.Status.bad_request, st.beginDelete("", 0));
    try expectEqual(ss.Status.bad_request, st.read(long_key, &read_buf).status);
    try expectEqual(ss.Status.not_found, st.beginDelete("missing", 0));
    try expectEqual(ss.ReadResult{ .status = .not_found, .size = 0 }, st.read("missing", &read_buf));
    const too_big = try testing.allocator.alloc(u8, ss.max_blob + 1);
    defer testing.allocator.free(too_big);
    try expectEqual(ss.Status.too_big, st.beginWrite("k", too_big, 0));
    // a 32-byte key is fine
    try putOk(&st, sim, long_key[0..32], &d, 0);
    try expectBlob(&st, long_key[0..32], &d);

    // one op at a time
    var e: [16]u8 = @splat(8);
    try expectEqual(ss.Status.ok, st.beginWrite("k", &e, 0));
    try expect(st.busy());
    try expectEqual(ss.Status.busy, st.beginWrite("k2", &e, 0));
    try expectEqual(ss.Status.busy, st.beginDelete(long_key[0..32], 0));
    try expectEqual(ss.Status.ok, run(&st, sim).?);
    try expect(!st.busy());
    try expectEqual(ss.Step{ .done = .ok }, st.step()); // idle step is harmless
    try expect(sim.mutatingOps() == 2 * (1 + 1 + 17));
    try expect(!sim.violation);
}

test "list and stat" {
    const sim = try Sim.create(0xFF);
    defer sim.destroy();
    var st: ss.Store = undefined;
    mount(&st, sim);
    var s = st.stat(0);
    try expectEqual(ss.Stat{
        .version = 1,
        .region_bytes = ss.data_capacity,
        .free_bytes = ss.data_capacity,
        .max_blob = ss.max_blob,
        .entries = 0,
        .max_entries = 63,
        .writes_left_now = 8,
    }, s);
    var d: [5000]u8 = @splat(1);
    try putOk(&st, sim, "one", d[0..10], 0);
    try putOk(&st, sim, "two", &d, 0);
    try putOk(&st, sim, "three", d[0..4096], 0);
    _ = try del(&st, sim, "two", 0);
    s = st.stat(0);
    try expectEqual(@as(u32, 2), s.entries);
    try expectEqual(ss.data_capacity - 2 * ss.block_size, s.free_bytes);
    try expectEqual(@as(u32, 4), s.writes_left_now);

    var out: [4]ss.ListEntry = undefined;
    try expectEqual(@as(u32, 2), st.list(&out));
    try expectEqual(@as(u32, 3), out[0].key_len);
    try expect(std.mem.eql(u8, out[0].key[0..3], "one"));
    try expect(std.mem.allEqual(u8, out[0].key[3..], 0));
    try expectEqual(@as(u32, 10), out[0].size);
    try expect(std.mem.eql(u8, out[1].key[0..5], "three"));
    try expectEqual(@as(u32, 4096), out[1].size);
    try expectEqual(@as(u32, 1), st.list(out[0..1]));
    try expectEqual(@as(u32, 0), st.list(out[0..0]));
}

test "many keys: every data block holds a key" {
    // Each key takes at least one 4 KB block and there are 62 data blocks, so the block
    // limit (62 keys) is reached before the 63-entry directory is full.
    const sim = try Sim.create(0xFF);
    defer sim.destroy();
    var st: ss.Store = undefined;
    mount(&st, sim);
    var now: u64 = 0;
    var key_buf: [16]u8 = undefined;
    var d: [64]u8 = undefined;
    for (0..ss.data_block_count) |i| {
        const key = try std.fmt.bufPrint(&key_buf, "key{d}", .{i});
        try putOk(&st, sim, key, pattern(&d, i), now);
        now += ss.rate_interval_us;
    }
    try expectEqual(@as(u32, 62), st.stat(now).entries);
    try expectEqual(@as(u32, 0), st.stat(now).free_bytes);
    try expectEqual(ss.Status.no_space, st.beginWrite("one-more", &d, now));
    // copy-on-write: an overwrite needs a free block too
    try expectEqual(ss.Status.no_space, st.beginWrite("key5", "new five", now));
    // ... but an unchanged write is still fine
    try expectEqual(ss.Status.ok, try put(&st, sim, "key5", pattern(&d, 5), now));
    try expectEqual(ss.Status.ok, try del(&st, sim, "key7", now));
    now += ss.rate_interval_us;
    try putOk(&st, sim, "key5", "new five", now);
    now += ss.rate_interval_us;
    try putOk(&st, sim, "one-more", "hi", now);

    var st2: ss.Store = undefined;
    mount(&st2, sim);
    var out: [63]ss.ListEntry = undefined;
    try expectEqual(@as(u32, 62), st2.list(&out));
    for (0..ss.data_block_count) |i| {
        const key = try std.fmt.bufPrint(&key_buf, "key{d}", .{i});
        if (i == 5) {
            try expectBlob(&st2, key, "new five");
        } else if (i == 7) {
            try expectBlob(&st2, key, null);
        } else {
            try expectBlob(&st2, key, pattern(&d, i));
        }
    }
    try expectBlob(&st2, "one-more", "hi");
    try expect(!sim.violation);
}

test "full region: no_space" {
    const sim = try Sim.create(0xFF);
    defer sim.destroy();
    var st: ss.Store = undefined;
    mount(&st, sim);
    const max = try blob(ss.max_blob, 30);
    defer testing.allocator.free(max);
    var now: u64 = 0;
    var key_buf: [16]u8 = undefined;
    // 3 x 16 blocks + 14 x 1 block = 62 data blocks
    for (0..3) |i| {
        try putOk(&st, sim, try std.fmt.bufPrint(&key_buf, "big{d}", .{i}), max, now);
        now += ss.rate_interval_us;
    }
    for (0..14) |i| {
        try putOk(&st, sim, try std.fmt.bufPrint(&key_buf, "small{d}", .{i}), max[i .. i + 4096], now);
        now += ss.rate_interval_us;
    }
    try expectEqual(@as(u32, 0), st.stat(now).free_bytes);
    const before = sim.mutatingOps();
    try expectEqual(ss.Status.no_space, st.beginWrite("new", "x", now));
    // copy-on-write needs a free block while the old copy exists
    try expectEqual(ss.Status.no_space, st.beginWrite("small3", "changed", now));
    try expectEqual(before, sim.mutatingOps());
    try expectEqual(ss.Status.ok, try del(&st, sim, "small0", now));
    now += ss.rate_interval_us;
    try putOk(&st, sim, "small3", "changed", now);
    now += ss.rate_interval_us;
    // small3's old block is free again
    try putOk(&st, sim, "new", "x", now);

    var st2: ss.Store = undefined;
    mount(&st2, sim);
    for (0..3) |i| try expectBlob(&st2, try std.fmt.bufPrint(&key_buf, "big{d}", .{i}), max);
    try expectBlob(&st2, "small3", "changed");
    try expectBlob(&st2, "small0", null);
    try expectBlob(&st2, "small13", max[13 .. 13 + 4096]);
    try expectBlob(&st2, "new", "x");
    try expect(!sim.violation);
}

test "max blob and short reads" {
    const sim = try Sim.create(0xFF);
    defer sim.destroy();
    var st: ss.Store = undefined;
    mount(&st, sim);
    const max = try blob(ss.max_blob, 40);
    defer testing.allocator.free(max);
    try putOk(&st, sim, "max", max, 0);
    try expectBlob(&st, "max", max);
    var small: [100]u8 = undefined;
    const r = st.read("max", &small);
    try expectEqual(ss.ReadResult{ .status = .ok, .size = ss.max_blob }, r);
    try expect(std.mem.eql(u8, &small, max[0..100]));
    const r0 = st.read("max", read_buf[0..0]);
    try expectEqual(ss.ReadResult{ .status = .ok, .size = ss.max_blob }, r0);
    var st2: ss.Store = undefined;
    mount(&st2, sim);
    try expectBlob(&st2, "max", max);
}

test "unchanged write touches no flash and spends no token" {
    const sim = try Sim.create(0xFF);
    defer sim.destroy();
    var st: ss.Store = undefined;
    mount(&st, sim);
    const d = try blob(20000, 50);
    defer testing.allocator.free(d);
    try putOk(&st, sim, "k", d, 0);
    const before = sim.mutatingOps();
    const tokens = st.stat(0).writes_left_now;
    for (0..20) |_| {
        try expectEqual(ss.Status.ok, st.beginWrite("k", d, 0));
        try expect(st.busy());
        try expectEqual(ss.Step{ .done = .ok }, st.step());
        try expect(!st.busy());
    }
    try expectEqual(before, sim.mutatingOps());
    try expectEqual(tokens, st.stat(0).writes_left_now);
    // a one-byte change is a real write
    d[19999] ^= 1;
    try putOk(&st, sim, "k", d, 0);
    try expect(sim.mutatingOps() > before);
    try expectBlob(&st, "k", d);
}

test "rate limit" {
    const sim = try Sim.create(0xFF);
    defer sim.destroy();
    var st: ss.Store = undefined;
    st.init(sim.flash(), 1_000_000);
    var d: [32]u8 = undefined;
    var t: u64 = 1_000_000;
    for (0..8) |i| try putOk(&st, sim, "k", pattern(&d, i), t);
    try expectEqual(@as(u32, 0), st.stat(t).writes_left_now);
    const before = sim.mutatingOps();
    const reads_before = sim.n_read;
    try expectEqual(ss.Status.rate_limited, st.beginWrite("k", pattern(&d, 100), t));
    try expectEqual(ss.Status.rate_limited, st.beginDelete("k", t));
    try expect(!st.busy());
    try expectEqual(before, sim.mutatingOps());
    try expectEqual(reads_before, sim.n_read);
    // reads and unchanged writes still work
    try expectBlob(&st, "k", pattern(&d, 7));
    try expectEqual(ss.Status.ok, try put(&st, sim, "k", pattern(&d, 7), t));
    // +1 token per 10 s
    t += ss.rate_interval_us - 1;
    try expectEqual(ss.Status.rate_limited, st.beginWrite("k", pattern(&d, 100), t));
    t += 1;
    try putOk(&st, sim, "k", pattern(&d, 100), t);
    try expectEqual(ss.Status.rate_limited, st.beginWrite("k", pattern(&d, 101), t));
    // tokens refill up to the burst only
    t += 100 * ss.rate_interval_us;
    try expectEqual(@as(u32, 8), st.stat(t).writes_left_now);
    for (0..8) |i| try putOk(&st, sim, "k", pattern(&d, 200 + i), t);
    try expectEqual(ss.Status.rate_limited, st.beginWrite("k", pattern(&d, 300), t));
    // a clock that goes backwards doesn't mint tokens
    try expectEqual(ss.Status.rate_limited, st.beginWrite("k", pattern(&d, 300), 0));
    try expectEqual(ss.Status.rate_limited, st.beginWrite("k", pattern(&d, 300), ss.rate_interval_us - 1));
    try putOk(&st, sim, "k", pattern(&d, 300), ss.rate_interval_us);
}

test "corrupt blob reads io_error and can be rewritten" {
    const sim = try Sim.create(0xFF);
    defer sim.destroy();
    var st: ss.Store = undefined;
    mount(&st, sim);
    const d = try blob(6000, 60);
    defer testing.allocator.free(d);
    try putOk(&st, sim, "k", d, 0);
    try putOk(&st, sim, "other", "fine", 0);
    // flip a bit in k's second data block (first allocation: blocks 2, 3)
    sim.mem[3 * ss.block_size + 17] ^= 0x10;
    var st2: ss.Store = undefined;
    mount(&st2, sim);
    const r = st2.read("k", &read_buf);
    try expectEqual(ss.ReadResult{ .status = .io_error, .size = 6000 }, r);
    try expectEqual(@as(u32, 2), st2.stat(0).entries); // entry kept
    try expectBlob(&st2, "other", "fine");
    // same bytes as the CRC promises, but flash differs: a real write, which repairs it
    const before = sim.mutatingOps();
    try putOk(&st2, sim, "k", d, 0);
    try expect(sim.mutatingOps() > before);
    try expectBlob(&st2, "k", d);
}

test "garbage region mounts empty and formats lazily" {
    const fills = [_]enum { erased, random, xip_like }{ .erased, .random, .xip_like };
    for (fills) |fill| {
        const sim = try Sim.create(0xFF);
        defer sim.destroy();
        switch (fill) {
            .erased => {},
            .random => _ = pattern(&sim.mem, 70),
            .xip_like => {
                // an old cart image, plus a directory-looking block with a bad CRC
                _ = pattern(&sim.mem, 71);
                @memcpy(sim.mem[0..4], "SVD1");
                @memcpy(sim.mem[ss.block_size..][0..4], "SVD1");
            },
        }
        const snapshot = try sim.clone();
        defer snapshot.destroy();
        var st: ss.Store = undefined;
        mount(&st, sim);
        try expectEqual(@as(u32, 0), sim.mutatingOps()); // mount never writes
        try expectEqual(@as(u32, 0), st.stat(0).entries);
        try expectEqual(ss.data_capacity, st.stat(0).free_bytes);
        var out: [4]ss.ListEntry = undefined;
        try expectEqual(@as(u32, 0), st.list(&out));
        try expectBlob(&st, "k", null);
        try expectEqual(ss.Status.not_found, st.beginDelete("k", 0));
        try expect(std.mem.eql(u8, &sim.mem, &snapshot.mem));

        var d: [3000]u8 = undefined;
        try putOk(&st, sim, "k", pattern(&d, 72), 0);
        // first commit: one data block + directory A; nothing else erased
        try expectEqual(@as(u32, 2), sim.n_erase);
        try expectEqual(@as(u32, 1), sim.erase_count[0]);
        try expectEqual(@as(u32, 0), sim.erase_count[1]);
        try expect(std.mem.eql(u8, sim.mem[ss.block_size .. 2 * ss.block_size], snapshot.mem[ss.block_size .. 2 * ss.block_size]));

        var st2: ss.Store = undefined;
        mount(&st2, sim);
        try expectBlob(&st2, "k", &d);
        var e: [5000]u8 = undefined;
        try putOk(&st2, sim, "k2", pattern(&e, 73), 0); // directory B
        try putOk(&st2, sim, "k", pattern(&d, 74), 0); // directory A again
        var st3: ss.Store = undefined;
        mount(&st3, sim);
        try expectBlob(&st3, "k", &d);
        try expectBlob(&st3, "k2", &e);
        try expectEqual(@as(u32, 2), sim.erase_count[0]);
        try expectEqual(@as(u32, 1), sim.erase_count[1]);
        try expect(!sim.violation);
    }
}

test "flash op counts for 1 KB and 32 KB writes" {
    const sizes = [_]u32{ 1024, 32 * 1024 };
    const want_erase = [_]u32{ 2, 9 };
    const want_program = [_]u32{ 4 + 16, 128 + 16 };
    for (sizes, want_erase, want_program) |n, we, wp| {
        const sim = try Sim.create(0xFF);
        defer sim.destroy();
        var st: ss.Store = undefined;
        mount(&st, sim);
        const d = try testing.allocator.alloc(u8, n);
        defer testing.allocator.free(d);
        _ = pattern(d, n);
        sim.resetCounters();
        try expectEqual(ss.Status.ok, st.beginWrite("k", d, 0));
        var steps: u32 = 0;
        while (st.step() == .more) steps += 1;
        steps += 1;
        std.debug.print("save_store: {d} B write = {d} steps, {d} erase4k, {d} page programs, {d} reads\n", .{ n, steps, sim.n_erase, sim.n_program, sim.n_read });
        try expectEqual(we, sim.n_erase);
        try expectEqual(wp, sim.n_program);
        try expectEqual(2 * (we - 1) + 2, steps);
    }
}

test "wear: next-fit spreads erases over the data blocks" {
    const sim = try Sim.create(0xFF);
    defer sim.destroy();
    var st: ss.Store = undefined;
    mount(&st, sim);
    var now: u64 = 0;
    var s1: [8192]u8 = undefined;
    var s2: [4096]u8 = undefined;
    try putOk(&st, sim, "static1", pattern(&s1, 80), now);
    try putOk(&st, sim, "static2", pattern(&s2, 81), now);
    var hot: [1024]u8 = undefined;
    for (0..1000) |i| {
        now += ss.rate_interval_us;
        try putOk(&st, sim, "hot", pattern(&hot, 1000 + i), now);
    }
    var lo: u32 = std.math.maxInt(u32);
    var hi: u32 = 0;
    var lo_all: u32 = std.math.maxInt(u32);
    for (ss.first_data_block..ss.block_count) |b| {
        const c = sim.erase_count[b];
        lo_all = @min(lo_all, c);
        if (c <= 1) continue; // the static keys' blocks
        lo = @min(lo, c);
        hi = @max(hi, c);
    }
    std.debug.print("save_store: wear after 1000 x 1 KB writes: data blocks max {d} min {d} (static-key blocks {d}), dir A {d} dir B {d}\n", .{ hi, lo, lo_all, sim.erase_count[0], sim.erase_count[1] });
    try expect(hi - lo <= 1);
    try expect(hi <= 18);
    try expect(sim.erase_count[0] + sim.erase_count[1] == 1002);
    var st2: ss.Store = undefined;
    mount(&st2, sim);
    try expectBlob(&st2, "hot", &hot);
    try expectBlob(&st2, "static1", &s1);
    try expectBlob(&st2, "static2", &s2);
    try expect(!sim.violation);
}

test "verify failure returns io_error and keeps the live directory" {
    // data block verify fails, then directory verify fails
    for ([_]bool{ false, true }) |in_dir| {
        const sim = try Sim.create(0xFF);
        defer sim.destroy();
        var st: ss.Store = undefined;
        mount(&st, sim);
        var old: [5000]u8 = undefined;
        var new: [5000]u8 = undefined;
        try putOk(&st, sim, "k", pattern(&old, 90), 0);
        try putOk(&st, sim, "o", "other", 0);
        sim.resetCounters();
        // 5000 B = 2 data blocks: erase, 16 pages, erase, 4 pages, then the directory
        sim.flip_at = if (in_dir) 1 + 16 + 1 + 4 + 1 else 1 + 16 + 1 + 2; // dir page 0 / block 2 page 2
        try expectEqual(ss.Status.io_error, try put(&st, sim, "k", pattern(&new, 91), 0));
        try expect(!st.busy());
        try expectBlob(&st, "k", &old);
        try expectBlob(&st, "o", "other");
        var re: ss.Store = undefined;
        mount(&re, sim);
        try expectBlob(&re, "k", &old);
        // the store keeps working; a later commit wins over whatever is on flash
        try putOk(&st, sim, "p", "third", 0);
        try expectBlob(&st, "k", &old);
        mount(&re, sim);
        try expectBlob(&re, "k", &old);
        try expectBlob(&re, "o", "other");
        try expectBlob(&re, "p", "third");
        try putOk(&st, sim, "k", &new, 0);
        mount(&re, sim);
        try expectBlob(&re, "k", &new);
        try expect(!sim.violation);
    }
}

// --- power cuts ------------------------------------------------------------------------

const Op = union(enum) { write: []const u8, delete };

fn beginOp(st: *ss.Store, key: []const u8, op: Op) ss.Status {
    return switch (op) {
        .write => |d| st.beginWrite(key, d, 0),
        .delete => st.beginDelete(key, 0),
    };
}

/// Old-or-new check after a reboot, then a follow-up commit on the rebooted store, which
/// must work and must not disturb anything.
fn checkAfterCut(sim: *Sim, key: []const u8, old: ?[]const u8, new: ?[]const u8, others: []const KV, completed: bool) !void {
    sim.reboot();
    var st: ss.Store = undefined;
    mount(&st, sim);
    const is_new = holds(&st, key, new);
    const is_old = holds(&st, key, old);
    if (!(is_new or is_old) or (completed and !is_new)) {
        std.debug.print("after cut: key '{s}' new={} old={} completed={}\n", .{ key, is_new, is_old, completed });
        return error.TestUnexpectedResult;
    }
    try expectAll(&st, others);
    const now_val = if (is_new) new else old;

    try putOk(&st, sim, "follow-up", "after the cut", 0);
    var st2: ss.Store = undefined;
    mount(&st2, sim);
    try expectBlob(&st2, key, now_val);
    try expectBlob(&st2, "follow-up", "after the cut");
    try expectAll(&st2, others);
    try expect(!sim.violation);
}

/// For every N in 0..=T (T = mutating flash calls of the whole op), cut the power at
/// call N (skipped, or half applied when torn), reboot, check.
fn sweep(base: *const Sim, key: []const u8, old: ?[]const u8, op: Op, others: []const KV) !u32 {
    const new: ?[]const u8 = switch (op) {
        .write => |d| d,
        .delete => null,
    };
    const sim = try base.clone();
    defer sim.destroy();

    var st: ss.Store = undefined;
    mount(&st, sim);
    try expectEqual(ss.Status.ok, beginOp(&st, key, op));
    try expectEqual(ss.Status.ok, run(&st, sim).?);
    const total = sim.mutatingOps();

    for ([_]bool{ false, true }) |torn| {
        var n: u32 = 0;
        while (n <= total) : (n += 1) {
            sim.* = base.*;
            sim.resetCounters();
            sim.budget = n;
            sim.torn = torn;
            mount(&st, sim);
            try expectEqual(ss.Status.ok, beginOp(&st, key, op));
            const r = run(&st, sim);
            if (n == total) try expectEqual(ss.Status.ok, r.?);
            checkAfterCut(sim, key, old, new, others, n == total) catch |err| {
                std.debug.print("power cut at call {d}/{d} torn={}\n", .{ n, total, torn });
                return err;
            };
        }
    }
    return total;
}

const Fixture = struct {
    sim: *Sim,
    k_old: []u8,
    k_new: []u8,
    a: []u8,
    b: []u8,
    others: [3]KV,

    fn init(old_len: usize, new_len: usize, with_k: bool) !Fixture {
        var f: Fixture = undefined;
        f.sim = try Sim.create(0xFF);
        f.k_old = try testing.allocator.alloc(u8, old_len);
        f.k_new = try testing.allocator.alloc(u8, new_len);
        f.a = try testing.allocator.alloc(u8, 4096);
        f.b = try testing.allocator.alloc(u8, 10000);
        _ = pattern(f.k_old, 100);
        _ = pattern(f.k_new, 101);
        _ = pattern(f.a, 102);
        _ = pattern(f.b, 103);
        var st: ss.Store = undefined;
        mount(&st, f.sim);
        try putOk(&st, f.sim, "a", f.a, 0);
        if (with_k) try putOk(&st, f.sim, "k", f.k_old, 0);
        try putOk(&st, f.sim, "b", f.b, 0);
        try putOk(&st, f.sim, "c", "tiny", 0);
        _ = try del(&st, f.sim, "c", 0); // directory history: several generations
        try putOk(&st, f.sim, "c", "tiny again", 0);
        f.others = .{ .{ .key = "a", .data = f.a }, .{ .key = "b", .data = f.b }, .{ .key = "c", .data = "tiny again" } };
        f.sim.resetCounters();
        return f;
    }

    fn deinit(f: *Fixture) void {
        f.sim.destroy();
        testing.allocator.free(f.k_old);
        testing.allocator.free(f.k_new);
        testing.allocator.free(f.a);
        testing.allocator.free(f.b);
    }
};

test "power-cut sweep: overwrite" {
    var f = try Fixture.init(5000, 9000, true);
    defer f.deinit();
    const t = try sweep(f.sim, "k", f.k_old, .{ .write = f.k_new }, &f.others);
    try expectEqual(@as(u32, (1 + 16) + (1 + 16) + (1 + 4) + (1 + 16)), t); // 9000 B = 3 blocks + directory
}

test "power-cut sweep: 64 KB overwrite" {
    var f = try Fixture.init(ss.max_blob, ss.max_blob, true);
    defer f.deinit();
    _ = try sweep(f.sim, "k", f.k_old, .{ .write = f.k_new }, &f.others);
}

test "power-cut sweep: new key" {
    var f = try Fixture.init(1, 1024, false);
    defer f.deinit();
    _ = try sweep(f.sim, "k", null, .{ .write = f.k_new }, &f.others);
}

test "power-cut sweep: delete" {
    var f = try Fixture.init(7000, 1, true);
    defer f.deinit();
    const t = try sweep(f.sim, "k", f.k_old, .delete, &f.others);
    try expectEqual(@as(u32, 17), t);
}

test "power-cut sweep: first write on a garbage region" {
    const sim = try Sim.create(0);
    defer sim.destroy();
    _ = pattern(&sim.mem, 110);
    const d = try blob(6000, 111);
    defer testing.allocator.free(d);
    _ = try sweep(sim, "k", null, .{ .write = d }, &.{});
}

test "power cut mid data program and mid directory write" {
    var f = try Fixture.init(5000, 5000, true);
    defer f.deinit();
    // 5000 B: block 1 = erase + 16 pages, block 2 = erase + 4 pages, directory = erase + 16
    const cases = [_]struct { budget: u32, torn: bool }{
        .{ .budget = 1 + 8, .torn = false }, // half the first data block's pages
        .{ .budget = 1 + 8, .torn = true }, // ... and the 9th page half programmed
        .{ .budget = 17 + 1 + 2, .torn = true },
        .{ .budget = 22, .torn = false }, // before the directory erase
        .{ .budget = 22, .torn = true }, // directory erase torn
        .{ .budget = 22 + 1 + 8, .torn = false }, // half the directory's pages
        .{ .budget = 22 + 1 + 15, .torn = true }, // last directory page torn
    };
    for (cases) |c| {
        const sim = try f.sim.clone();
        defer sim.destroy();
        var st: ss.Store = undefined;
        mount(&st, sim);
        sim.budget = c.budget;
        sim.torn = c.torn;
        try expectEqual(ss.Status.ok, st.beginWrite("k", f.k_new, 0));
        try expect(run(&st, sim) == null);
        try expect(sim.cut);
        sim.reboot();
        var re: ss.Store = undefined;
        mount(&re, sim);
        try expectBlob(&re, "k", f.k_old); // every cut before the directory completes
        try expectAll(&re, &f.others);
        try checkAfterCut(sim, "k", f.k_old, f.k_new, &f.others, false);
    }
}

test "abort at every step, then reboot or keep going (with power cuts)" {
    var f = try Fixture.init(5000, 9000, true);
    defer f.deinit();
    const ops = [_]Op{ .{ .write = f.k_new }, .delete };
    for (ops) |op| {
        const new: ?[]const u8 = switch (op) {
            .write => f.k_new,
            .delete => null,
        };
        var k: u32 = 0;
        while (true) : (k += 1) {
            const sim = try f.sim.clone();
            defer sim.destroy();
            var st: ss.Store = undefined;
            mount(&st, sim);
            try expectEqual(ss.Status.ok, beginOp(&st, "k", op));
            var finished = false;
            for (0..k) |_| if (st.step() != .more) {
                finished = true;
                break;
            };
            if (finished) break;
            st.abort();
            try expect(!st.busy());
            try expectBlob(&st, "k", f.k_old); // RAM view: the old directory
            try expectAll(&st, &f.others);

            // power off right after the abort: old or new
            {
                const s2 = try sim.clone();
                defer s2.destroy();
                try checkAfterCut(s2, "k", f.k_old, new, &f.others, false);
            }
            // keep going on the same store: a follow-up write, cut at every call
            const total = blk: {
                const s2 = try sim.clone();
                defer s2.destroy();
                var st2 = st;
                st2.flash = s2.flash();
                try putOk(&st2, s2, "z", "zz", 0);
                // completed follow-up: flash now matches the RAM view (old k)
                var re: ss.Store = undefined;
                mount(&re, s2);
                try expectBlob(&re, "k", f.k_old);
                try expectBlob(&re, "z", "zz");
                try expectAll(&re, &f.others);
                break :blk s2.mutatingOps();
            };
            var n: u32 = 0;
            while (n <= total) : (n += 1) {
                for ([_]bool{ false, true }) |torn| {
                    const s2 = try sim.clone();
                    defer s2.destroy();
                    var st2 = st;
                    st2.flash = s2.flash();
                    s2.budget = n;
                    s2.torn = torn;
                    try expectEqual(ss.Status.ok, st2.beginWrite("z", "zz", 0));
                    _ = run(&st2, s2);
                    s2.reboot();
                    var re: ss.Store = undefined;
                    mount(&re, s2);
                    const ok_k = holds(&re, "k", f.k_old) or holds(&re, "k", new);
                    const ok_z = holds(&re, "z", null) or holds(&re, "z", "zz");
                    if (!ok_k or !ok_z) {
                        std.debug.print("abort after {d} steps, cut at {d} torn={}: k ok={} z ok={}\n", .{ k, n, torn, ok_k, ok_z });
                        return error.TestUnexpectedResult;
                    }
                    if (n == total) try expectBlob(&re, "k", f.k_old);
                    try expectAll(&re, &f.others);
                    try putOk(&re, s2, "follow-up", "x", 0);
                    var re2: ss.Store = undefined;
                    mount(&re2, s2);
                    try expectBlob(&re2, "follow-up", "x");
                    try expectAll(&re2, &f.others);
                    try expect(!s2.violation);
                }
            }
        }
    }
}
