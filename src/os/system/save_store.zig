//! STUB of Track A's save store (interface only). Replaced by the real
//! src/os/system/save_store.zig at merge. Nothing here is relied on: writes and
//! deletes fail with io_error, reads find nothing.
const std = @import("std");

pub const block_size: u32 = 4096;
pub const block_count: u32 = 64;
pub const page_size: u32 = 256;
pub const max_blob: u32 = 64 * 1024;
pub const max_entries: u32 = 63;
pub const max_key: u32 = 32;

pub const Status = enum(u32) { ok = 0, not_found = 1, no_space = 2, bad_request = 3, bad_buffer = 4, rate_limited = 5, too_big = 6, io_error = 7, busy = 8 };

pub const Flash = struct {
    ctx: *anyopaque,
    read: *const fn (ctx: *anyopaque, off: u32, dst: []u8) void,
    erase4k: *const fn (ctx: *anyopaque, off: u32) void,
    program: *const fn (ctx: *anyopaque, off: u32, src: []const u8) void,
}; // offsets relative to region start

pub const Stat = extern struct { version: u32, region_bytes: u32, free_bytes: u32, max_blob: u32, entries: u32, max_entries: u32, writes_left_now: u32, _r: u32 = 0 };
pub const ListEntry = extern struct { key_len: u32, key: [32]u8, size: u32 };
pub const ReadResult = struct { status: Status, size: u32 };
pub const Step = union(enum) { more, done: Status };

pub const Store = struct {
    flash: Flash = undefined,

    pub fn init(self: *Store, flash: Flash, now_us: u64) void {
        _ = now_us;
        self.flash = flash;
    }
    pub fn read(self: *Store, key: []const u8, dst: []u8) ReadResult {
        _ = self;
        _ = key;
        _ = dst;
        return .{ .status = .not_found, .size = 0 };
    }
    pub fn stat(self: *Store, now_us: u64) Stat {
        _ = self;
        _ = now_us;
        return .{ .version = 1, .region_bytes = block_size * block_count, .free_bytes = 0, .max_blob = max_blob, .entries = 0, .max_entries = max_entries, .writes_left_now = 0 };
    }
    pub fn list(self: *Store, out: []ListEntry) u32 {
        _ = self;
        _ = out;
        return 0;
    }
    pub fn beginWrite(self: *Store, key: []const u8, src: []const u8, now_us: u64) Status {
        _ = self;
        _ = key;
        _ = src;
        _ = now_us;
        return .io_error;
    }
    pub fn beginDelete(self: *Store, key: []const u8, now_us: u64) Status {
        _ = self;
        _ = key;
        _ = now_us;
        return .io_error;
    }
    pub fn step(self: *Store) Step {
        _ = self;
        return .{ .done = .io_error };
    }
    pub fn busy(self: *const Store) bool {
        _ = self;
        return false;
    }
    pub fn abort(self: *Store) void {
        _ = self;
    }
};
