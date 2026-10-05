//! Cart save store: small key -> blob store in a 256 KB internal-flash region.
//!
//! Pure logic over a `Flash` interface (no hardware imports), so the OS, the simulator
//! and badge-bench can share it. Format and rules are in SAVES_PLAN.md ("Store format").
//!
//! Region layout (64 x 4 KB blocks, offsets relative to the region start):
//!   block 0, 1   directory copies A and B (the valid one with the newer seq wins)
//!   block 2..63  data blocks
//!
//! Writes are copy-on-write: the new blob goes to blocks the live directory does not
//! reference (allocated next-fit from the directory's cursor, which spreads wear), each
//! block is erased, programmed and read back, then the new directory (seq + 1) goes to
//! the directory block that is NOT live, and is read back. A power cut at any point
//! leaves the previous directory, and so every previous blob, intact. A delete is a
//! directory write only.
//!
//! Flash work is a step machine so the OS can poll USB/audio between steps:
//! `beginWrite`/`beginDelete` validate and plan, then `step()` does at most one
//! `erase4k` plus that block's page programs, or one block read-back verify, per call.
//!
//! Unchanged writes: when the bytes equal the stored blob, `beginWrite` returns `.ok`
//! and the first `step()` returns `.done = .ok` without touching flash or spending a
//! rate-limit token.
//!
//! Lazy format: a region without a valid directory (all 0xFF, an old XIP cart image,
//! anything) mounts as an empty store and nothing is written until the first write,
//! which puts directory A (seq 1) down after its data blocks.
//!
//! Byte order: the on-flash structs are little-endian native layout (RP2350, x86-64 and
//! aarch64 hosts are all little-endian).

const std = @import("std");
const builtin = @import("builtin");

pub const block_size: u32 = 4096;
pub const block_count: u32 = 64; // region = 256 KB; blocks 0,1 = directory A/B, 2..63 data
pub const page_size: u32 = 256;
pub const max_blob: u32 = 64 * 1024;
pub const max_entries: u32 = 63;
pub const max_key: u32 = 32;

pub const abi_version: u32 = 1;
pub const region_size: u32 = block_size * block_count;
pub const first_data_block: u32 = 2;
pub const data_block_count: u32 = block_count - first_data_block; // 62
pub const data_capacity: u32 = data_block_count * block_size; // 253952
pub const max_blob_blocks: u32 = max_blob / block_size; // 16

/// Token bucket for commits (writes that change flash, and deletes).
pub const rate_burst: u32 = 8;
pub const rate_interval_us: u64 = 10 * std.time.us_per_s;

pub const Status = enum(u32) { ok = 0, not_found = 1, no_space = 2, bad_request = 3, bad_buffer = 4, rate_limited = 5, too_big = 6, io_error = 7, busy = 8 };

pub const Flash = struct { // offsets are relative to the region start
    ctx: *anyopaque,
    read: *const fn (ctx: *anyopaque, off: u32, dst: []u8) void,
    erase4k: *const fn (ctx: *anyopaque, off: u32) void, // off multiple of 4096
    program: *const fn (ctx: *anyopaque, off: u32, src: []const u8) void, // off and len multiples of 256
};

/// `region_bytes` is the data capacity (62 x 4 KB), so `free_bytes == region_bytes` on an
/// empty store. `free_bytes` is free data blocks x 4 KB (0 when the directory is full);
/// one blob still can't exceed `max_blob`.
pub const Stat = extern struct { version: u32, region_bytes: u32, free_bytes: u32, max_blob: u32, entries: u32, max_entries: u32, writes_left_now: u32, _r: u32 = 0 };
pub const ListEntry = extern struct { key_len: u32, key: [32]u8, size: u32 };
pub const ReadResult = struct { status: Status, size: u32 };
pub const Step = union(enum) { more, done: Status };

comptime {
    std.debug.assert(builtin.cpu.arch.endian() == .little);
    std.debug.assert(@sizeOf(DirHeader) == 64);
    std.debug.assert(@sizeOf(DirEntry) == 64);
    std.debug.assert(@sizeOf(Dir) == block_size);
    std.debug.assert(@sizeOf(ListEntry) == 40);
    std.debug.assert(@sizeOf(Stat) == 32);
}

const dir_magic = [4]u8{ 'S', 'V', 'D', '1' };

const DirHeader = extern struct {
    magic: [4]u8,
    seq: u32,
    next_fit: u8, // next data block to try (2..63)
    count: u8, // used entries
    _pad: [2]u8,
    crc: u32, // CRC-32 (ISO-HDLC) of the whole 4 KB block with this field zeroed
    _r: [48]u8,
};

const DirEntry = extern struct {
    key_len: u8, // 0 = free slot
    key: [32]u8,
    nblocks: u8,
    _pad: [2]u8,
    size: u32,
    crc: u32, // CRC-32 of the blob
    blocks: [16]u8, // data block indices, nblocks used
    flags: u32,
};

const Dir = extern struct {
    hdr: DirHeader,
    entries: [max_entries]DirEntry,
};

const Phase = enum(u8) { idle, noop, erase_other, data_program, data_verify, dir_program, dir_verify };

pub const Store = struct {
    flash: Flash,
    /// dirs[i] mirrors directory block i. dirs[live] is the live directory; the other
    /// one is scratch for the next directory while an op runs.
    dirs: [2]Dir,
    live: u1,
    /// Directory block `other` may hold a valid directory newer than the live one (an
    /// op was aborted, or failed verify, after it was programmed). The next write erases
    /// it before touching any data block.
    other_dirty: bool,
    tokens: u32,
    refill_us: u64,

    phase: Phase,
    dir_touched: bool,
    slot: u8, // entry index of the op in the next directory
    blk: u8, // data block being written (index into the entry's block list)
    src: []const u8,
    page: [page_size]u8,

    /// Mount: reads both directory blocks, never writes.
    pub fn init(self: *Store, flash: Flash, now_us: u64) void {
        self.flash = flash;
        self.other_dirty = false;
        self.tokens = rate_burst;
        self.refill_us = now_us;
        self.phase = .idle;
        self.dir_touched = false;
        self.slot = 0;
        self.blk = 0;
        self.src = &.{};

        flash.read(flash.ctx, 0, std.mem.asBytes(&self.dirs[0]));
        flash.read(flash.ctx, block_size, std.mem.asBytes(&self.dirs[1]));
        const v0 = validDir(&self.dirs[0]);
        const v1 = validDir(&self.dirs[1]);
        if (v0 and v1) {
            const d: i32 = @bitCast(self.dirs[1].hdr.seq -% self.dirs[0].hdr.seq);
            self.live = if (d > 0) 1 else 0;
        } else if (v0) {
            self.live = 0;
        } else if (v1) {
            self.live = 1;
        } else {
            // Unformatted: empty directory with seq 0, so the first commit writes block 0
            // (A) with seq 1.
            self.live = 1;
            emptyDir(&self.dirs[1]);
        }
    }

    /// Copies min(size, dst.len) bytes of the blob into dst. The whole blob is CRC-checked
    /// (io_error on mismatch, bytes still copied, size still reported).
    pub fn read(self: *Store, key: []const u8, dst: []u8) ReadResult {
        if (!validKey(key)) return .{ .status = .bad_request, .size = 0 };
        const d = &self.dirs[self.live];
        const i = findKey(d, key) orelse return .{ .status = .not_found, .size = 0 };
        const e = &d.entries[i];
        var crc = std.hash.Crc32.init();
        var pos: u32 = 0;
        for (e.blocks[0..e.nblocks]) |b| {
            const off = @as(u32, b) * block_size;
            const n = @min(block_size, e.size - pos);
            var q: u32 = 0;
            if (pos < dst.len) {
                q = @intCast(@min(n, dst.len - pos));
                const part = dst[pos..][0..q];
                self.flash.read(self.flash.ctx, off, part);
                crc.update(part);
            }
            while (q < n) {
                const k = @min(page_size, n - q);
                self.flash.read(self.flash.ctx, off + q, self.page[0..k]);
                crc.update(self.page[0..k]);
                q += k;
            }
            pos += n;
        }
        return .{ .status = if (crc.final() == e.crc) .ok else .io_error, .size = e.size };
    }

    pub fn stat(self: *Store, now_us: u64) Stat {
        self.refill(now_us);
        const d = &self.dirs[self.live];
        const free = freeBlockCount(d);
        return .{
            .version = abi_version,
            .region_bytes = data_capacity,
            .free_bytes = if (d.hdr.count >= max_entries) 0 else free * block_size,
            .max_blob = max_blob,
            .entries = d.hdr.count,
            .max_entries = max_entries,
            .writes_left_now = self.tokens,
        };
    }

    /// Fills `out` with up to out.len entries (key zero-padded) in directory order.
    /// Returns the number written; `stat().entries` is the total.
    pub fn list(self: *Store, out: []ListEntry) u32 {
        const d = &self.dirs[self.live];
        var n: u32 = 0;
        for (&d.entries) |*e| {
            if (e.key_len == 0) continue;
            if (n >= out.len) break;
            out[n] = .{ .key_len = e.key_len, .key = e.key, .size = e.size };
            n += 1;
        }
        return n;
    }

    /// `.ok` = started; then call step() until `.done`. Validation errors, busy,
    /// no_space, rate_limited and too_big return at once with nothing started.
    /// Unchanged content returns `.ok` and the first step() returns `.done = .ok`
    /// with no flash access. `src` must stay valid and unchanged until `.done`.
    pub fn beginWrite(self: *Store, key: []const u8, src: []const u8, now_us: u64) Status {
        if (self.phase != .idle) return .busy;
        if (!validKey(key)) return .bad_request;
        if (src.len == 0) return .bad_request;
        if (src.len > max_blob) return .too_big;

        const cur = &self.dirs[self.live];
        const size: u32 = @intCast(src.len);
        const crc = std.hash.Crc32.hash(src);
        const found = findKey(cur, key);
        if (found) |i| {
            const e = &cur.entries[i];
            if (e.size == size and e.crc == crc and self.blobEquals(e, src)) {
                self.phase = .noop;
                return .ok;
            }
        }
        const slot = found orelse freeSlot(cur) orelse return .no_space;
        const nblocks = (size + block_size - 1) / block_size;
        const used = usedBlocks(cur);
        if (data_block_count - @popCount(used) < nblocks) return .no_space;
        if (!self.takeToken(now_us)) return .rate_limited;

        const other = &self.dirs[1 - @as(u2, self.live)];
        other.* = cur.*;
        const e = &other.entries[slot];
        e.* = std.mem.zeroes(DirEntry);
        e.key_len = @intCast(key.len);
        @memcpy(e.key[0..key.len], key);
        e.nblocks = @intCast(nblocks);
        e.size = size;
        e.crc = crc;
        var b: u32 = cur.hdr.next_fit;
        var n: u32 = 0;
        while (n < nblocks) {
            if (used & bit(b) == 0) {
                e.blocks[n] = @intCast(b);
                n += 1;
            }
            b = if (b + 1 == block_count) first_data_block else b + 1;
        }
        other.hdr.next_fit = @intCast(b);
        if (found == null) other.hdr.count += 1;
        sealDir(other, cur.hdr.seq +% 1);

        self.slot = slot;
        self.blk = 0;
        self.src = src;
        self.dir_touched = false;
        self.phase = if (self.other_dirty) .erase_other else .data_program;
        return .ok;
    }

    /// `.ok` = started (directory write only); not_found if the key is absent.
    pub fn beginDelete(self: *Store, key: []const u8, now_us: u64) Status {
        if (self.phase != .idle) return .busy;
        if (!validKey(key)) return .bad_request;
        const cur = &self.dirs[self.live];
        const slot = findKey(cur, key) orelse return .not_found;
        if (!self.takeToken(now_us)) return .rate_limited;

        const other = &self.dirs[1 - @as(u2, self.live)];
        other.* = cur.*;
        other.entries[slot] = std.mem.zeroes(DirEntry);
        other.hdr.count -= 1;
        sealDir(other, cur.hdr.seq +% 1);

        self.slot = slot;
        self.src = &.{};
        self.dir_touched = false;
        self.phase = .dir_program;
        return .ok;
    }

    /// At most one erase4k plus that block's page programs, or one block verify.
    /// Returns `.done = .ok` (no effect) when idle.
    pub fn step(self: *Store) Step {
        const f = self.flash;
        const other: u32 = 1 - @as(u32, self.live);
        switch (self.phase) {
            .idle => return .{ .done = .ok },
            .noop => return self.finish(.ok),
            .erase_other => {
                f.erase4k(f.ctx, other * block_size);
                self.other_dirty = false;
                self.phase = .data_program;
                return .more;
            },
            .data_program => {
                const off, const chunk = self.dataChunk();
                f.erase4k(f.ctx, off);
                self.programBlock(off, chunk);
                self.phase = .data_verify;
                return .more;
            },
            .data_verify => {
                const off, const chunk = self.dataChunk();
                if (!self.verify(off, chunk)) return self.finish(.io_error);
                self.blk += 1;
                const e = &self.dirs[other].entries[self.slot];
                self.phase = if (self.blk == e.nblocks) .dir_program else .data_program;
                return .more;
            },
            .dir_program => {
                self.dir_touched = true;
                f.erase4k(f.ctx, other * block_size);
                self.programBlock(other * block_size, std.mem.asBytes(&self.dirs[other]));
                self.phase = .dir_verify;
                return .more;
            },
            .dir_verify => {
                if (!self.verify(other * block_size, std.mem.asBytes(&self.dirs[other]))) {
                    self.other_dirty = true;
                    return self.finish(.io_error);
                }
                self.live = @intCast(other);
                self.other_dirty = false;
                return self.finish(.ok);
            },
        }
    }

    pub fn busy(self: *const Store) bool {
        return self.phase != .idle;
    }

    /// Cart stopped mid-write: drop the op; the live directory stays the old one. If the
    /// new directory may already be on flash, the next write erases it first.
    pub fn abort(self: *Store) void {
        if (self.phase == .idle) return;
        if (self.dir_touched) self.other_dirty = true;
        _ = self.finish(.ok);
    }

    fn finish(self: *Store, status: Status) Step {
        self.phase = .idle;
        self.dir_touched = false;
        self.src = &.{};
        return .{ .done = status };
    }

    /// Region offset of the data block being written and its slice of src.
    fn dataChunk(self: *Store) struct { u32, []const u8 } {
        const other: u32 = 1 - @as(u32, self.live);
        const e = &self.dirs[other].entries[self.slot];
        const start = @as(u32, self.blk) * block_size;
        const end = @min(start + block_size, e.size);
        return .{ @as(u32, e.blocks[self.blk]) * block_size, self.src[start..end] };
    }

    /// Programs `data` (<= 4 KB) page by page at `off`; a partial last page is padded
    /// with 0xFF.
    fn programBlock(self: *Store, off: u32, data: []const u8) void {
        const f = self.flash;
        var p: u32 = 0;
        while (p < data.len) : (p += page_size) {
            const rest = data.len - p;
            if (rest >= page_size) {
                f.program(f.ctx, off + p, data[p..][0..page_size]);
            } else {
                @memcpy(self.page[0..rest], data[p..]);
                @memset(self.page[rest..], 0xFF);
                f.program(f.ctx, off + p, &self.page);
            }
        }
    }

    fn verify(self: *Store, off: u32, expect: []const u8) bool {
        var p: u32 = 0;
        var ok = true;
        while (p < expect.len) : (p += page_size) {
            const n = @min(page_size, expect.len - p);
            self.flash.read(self.flash.ctx, off + p, self.page[0..n]);
            if (!std.mem.eql(u8, self.page[0..n], expect[p..][0..n])) ok = false;
        }
        return ok;
    }

    fn blobEquals(self: *Store, e: *const DirEntry, src: []const u8) bool {
        var pos: u32 = 0;
        for (e.blocks[0..e.nblocks]) |b| {
            const n = @min(block_size, e.size - pos);
            if (!self.verify(@as(u32, b) * block_size, src[pos..][0..n])) return false;
            pos += n;
        }
        return true;
    }

    fn refill(self: *Store, now_us: u64) void {
        if (now_us < self.refill_us or self.tokens >= rate_burst) {
            self.refill_us = now_us;
            return;
        }
        const add = (now_us - self.refill_us) / rate_interval_us;
        if (add == 0) return;
        self.tokens = @intCast(@min(@as(u64, rate_burst), self.tokens + add));
        self.refill_us += add * rate_interval_us;
        if (self.tokens >= rate_burst) self.refill_us = now_us;
    }

    fn takeToken(self: *Store, now_us: u64) bool {
        self.refill(now_us);
        if (self.tokens == 0) return false;
        self.tokens -= 1;
        return true;
    }
};

fn bit(b: u32) u64 {
    return @as(u64, 1) << @intCast(b);
}

fn validKey(key: []const u8) bool {
    if (key.len == 0 or key.len > max_key) return false;
    for (key) |c| if (c < 0x20 or c > 0x7E) return false;
    return true;
}

fn findKey(d: *const Dir, key: []const u8) ?u8 {
    for (&d.entries, 0..) |*e, i| {
        if (e.key_len == key.len and std.mem.eql(u8, e.key[0..key.len], key)) return @intCast(i);
    }
    return null;
}

fn freeSlot(d: *const Dir) ?u8 {
    for (&d.entries, 0..) |*e, i| if (e.key_len == 0) return @intCast(i);
    return null;
}

fn usedBlocks(d: *const Dir) u64 {
    var used: u64 = 0;
    for (&d.entries) |*e| {
        if (e.key_len == 0) continue;
        for (e.blocks[0..e.nblocks]) |b| used |= bit(b);
    }
    return used;
}

fn freeBlockCount(d: *const Dir) u32 {
    return data_block_count - @popCount(usedBlocks(d));
}

fn emptyDir(d: *Dir) void {
    @memset(std.mem.asBytes(d), 0);
    d.hdr.magic = dir_magic;
    d.hdr.next_fit = first_data_block;
}

fn dirCrc(d: *Dir) u32 {
    const saved = d.hdr.crc;
    d.hdr.crc = 0;
    const c = std.hash.Crc32.hash(std.mem.asBytes(d));
    d.hdr.crc = saved;
    return c;
}

fn sealDir(d: *Dir, seq: u32) void {
    d.hdr.magic = dir_magic;
    d.hdr.seq = seq;
    d.hdr.crc = dirCrc(d);
}

/// Magic, CRC, and every entry sane (key, size, block list, no block used twice).
fn validDir(d: *Dir) bool {
    if (!std.mem.eql(u8, &d.hdr.magic, &dir_magic)) return false;
    if (dirCrc(d) != d.hdr.crc) return false;
    if (d.hdr.next_fit < first_data_block or d.hdr.next_fit >= block_count) return false;
    var used: u64 = 0;
    var count: u32 = 0;
    for (&d.entries) |*e| {
        if (e.key_len == 0) continue;
        if (e.key_len > max_key or !validKey(e.key[0..e.key_len])) return false;
        if (e.size == 0 or e.size > max_blob) return false;
        if (e.nblocks != (e.size + block_size - 1) / block_size) return false;
        for (e.blocks[0..e.nblocks]) |b| {
            if (b < first_data_block or b >= block_count) return false;
            if (used & bit(b) != 0) return false;
            used |= bit(b);
        }
        count += 1;
    }
    return count == d.hdr.count;
}
