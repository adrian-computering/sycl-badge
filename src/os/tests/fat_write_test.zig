//! Host tests for cart files (loader/fat_write.zig, fork/CART_FILES.md) on RAM
//! images of both badge volumes, formatted by storage.zig's own formatVolume and
//! accessed through its real sector cache (storage.host).
//!
//! fsck.fat and a FAT reader check the images too: src/os/tests/fat_images.py
//! (run `python3 src/os/tests/fat_images.py`), which uses fat_images.zig.
const std = @import("std");
const testing = std.testing;
const fat_write = @import("../loader/fat_write.zig");
const fat_names = @import("../loader/fat_names.zig");
const storage = @import("../loader/storage.zig");
const storage_disk = @import("../loader/storage_disk.zig");

const Writer = fat_write.Writer;
const Status = fat_write.Status;
const sector = fat_write.sector_size;

/// Both volumes as RAM images, mounted and formatted.
pub const Images = struct {
    bufs: [2][]u8,

    pub fn init(gpa: std.mem.Allocator) !Images {
        var self: Images = undefined;
        self.bufs[0] = try gpa.alloc(u8, storage.host.volumeSize(.romfs));
        errdefer gpa.free(self.bufs[0]);
        self.bufs[1] = try gpa.alloc(u8, storage.host.volumeSize(.ext));
        storage.host.mount(&self.bufs, true);
        writer.abort(); // a failed test may have left a file open
        return self;
    }

    pub fn deinit(self: *Images, gpa: std.mem.Allocator) void {
        for (self.bufs) |b| gpa.free(b);
    }

    /// Remount without formatting (a reboot: the pending cache is gone).
    pub fn reboot(self: *Images) void {
        storage.host.mount(&self.bufs, false);
    }
};

pub fn disk(v: u8) fat_write.Disk {
    return storage_disk.disk(v);
}

fn drain(w: *Writer) Status {
    while (true) switch (w.step()) {
        .more => {},
        .done => |s| return s,
    };
}

/// create, write in chunks of `chunk` bytes, commit.
pub fn writeFile(w: *Writer, v: u8, name: []const u8, data: []const u8, chunk: usize) Status {
    var st = w.create(disk(v), name, @intCast(data.len));
    if (st != .ok) return st;
    var off: usize = 0;
    while (off < data.len) {
        const n = @min(chunk, data.len - off);
        st = w.beginWrite(@intCast(off), data[off..][0..n]);
        if (st != .ok) return st;
        st = drain(w);
        if (st != .ok) return st;
        off += n;
    }
    st = w.beginCommit();
    if (st != .ok) return st;
    return drain(w);
}

pub fn pattern(seed: u32, buf: []u8) void {
    var x: u32 = seed *% 2654435761 +% 1;
    for (buf) |*b| {
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        b.* = @truncate(x);
    }
}

/// Reads a file back through storage.zig's lookup (the menu's rule).
fn readBack(gpa: std.mem.Allocator, v: u8, name: []const u8) !?[]u8 {
    const info = storage.host.find(v, name) orelse return null;
    const buf = try gpa.alloc(u8, info.size);
    const n = storage.readCart(info, buf);
    try testing.expectEqual(info.size, n);
    return buf;
}

fn expectFile(v: u8, name: []const u8, data: []const u8) !void {
    const got = (try readBack(testing.allocator, v, name)) orelse return error.FileMissing;
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, data, got);
}

// ── independent checker ───────────────────────────────────────────────────

pub const FsReport = struct {
    files: u32 = 0,
    used_clusters: u32 = 0,
    lost_clusters: u32 = 0,
    fats_differ: bool = false,
};

fn fatGet(img: []const u8, g: fat_write.Geometry, copy: u32, c: u32) u16 {
    const base = (g.fat_start + copy * g.fat_sectors) * sector;
    const off = base + c + c / 2;
    const pair = @as(u16, img[off]) | (@as(u16, img[off + 1]) << 8);
    return if (c & 1 == 0) pair & 0xFFF else pair >> 4;
}

/// Walks the root directory and FAT 1 of an image: every file's chain must be
/// in range, as long as its size needs and not shared with another file.
pub fn checkImage(gpa: std.mem.Allocator, img: []const u8) !FsReport {
    const g = fat_write.Geometry.parse(img[0..sector]) orelse return error.BadBootSector;
    var rep: FsReport = .{};
    const seen = try gpa.alloc(bool, g.clusters + 2);
    defer gpa.free(seen);
    @memset(seen, false);
    var idx: u32 = 0;
    while (idx < g.root_entries) : (idx += 1) {
        const e = img[(g.root_start * sector) + idx * 32 ..][0..32];
        if (e[0] == 0) break;
        if (e[0] == 0xE5 or e[11] == 0x0F or e[11] & 0x08 != 0) continue;
        rep.files += 1;
        const size = std.mem.readInt(u32, e[28..32], .little);
        var c: u32 = std.mem.readInt(u16, e[26..28], .little);
        const need = (size + sector - 1) / sector;
        if (need == 0) {
            if (c != 0) return error.EmptyFileWithCluster;
            continue;
        }
        var n: u32 = 0;
        while (true) {
            if (c < 2 or c >= g.clusters + 2) return error.ChainOutOfRange;
            if (seen[c]) return error.CrossLinked;
            seen[c] = true;
            n += 1;
            if (n > need) return error.ChainTooLong;
            const next = fatGet(img, g, 0, c);
            if (next >= 0xFF8) break;
            c = next;
        }
        if (n != need) return error.ChainTooShort;
    }
    var c: u32 = 2;
    while (c < g.clusters + 2) : (c += 1) {
        const v = fatGet(img, g, 0, c);
        if (v != 0) rep.used_clusters += 1;
        if (v != 0 and !seen[c]) rep.lost_clusters += 1;
        if (g.num_fats > 1 and v != fatGet(img, g, 1, c)) rep.fats_differ = true;
    }
    return rep;
}

/// Byte ranges of an image a cart file may change before commit: free data
/// clusters only. Returns true if `a` and `b` differ anywhere else.
fn differsOutsideFreeData(a: []const u8, b: []const u8) bool {
    const g = fat_write.Geometry.parse(a[0..sector]).?;
    if (!std.mem.eql(u8, a[0 .. g.data_start * sector], b[0 .. g.data_start * sector])) return true;
    var c: u32 = 2;
    while (c < g.clusters + 2) : (c += 1) {
        const off = (g.data_start + c - 2) * sector;
        if (fatGet(a, g, 0, c) != 0 and !std.mem.eql(u8, a[off..][0..sector], b[off..][0..sector])) return true;
    }
    return false;
}

fn rawAlias(img: []const u8, name: []const u8) ?[11]u8 {
    const g = fat_write.Geometry.parse(img[0..sector]).?;
    var lfn: [256]u8 = undefined;
    var idx: u32 = 0;
    while (idx < g.root_entries) : (idx += 1) {
        const off = g.root_start * sector + idx * 32;
        const e = img[off..][0..32];
        if (e[0] == 0) break;
        if (e[0] == 0xE5 or e[11] == 0x0F or e[11] & 0x08 != 0) continue;
        const sec_off = off - (off % sector);
        const prev: ?*const [sector]u8 = if (sec_off > g.root_start * sector) img[sec_off - sector ..][0..sector] else null;
        const n = fat_names.readLfnEntriesMultiSector(prev, img[sec_off..][0..sector], off % sector, &lfn);
        if (std.mem.eql(u8, lfn[0..n], name)) return e[0..11].*;
    }
    return null;
}

var writer: Writer = .{};

// ── tests ──────────────────────────────────────────────────────────────────

test "create, write, commit on both volumes; storage finds and reads them" {
    const gpa = testing.allocator;
    var imgs = try Images.init(gpa);
    defer imgs.deinit(gpa);

    const small = "hello from a cart\n";
    const big = try gpa.alloc(u8, 100 * 1024 + 123);
    defer gpa.free(big);
    pattern(1, big);
    const huge = try gpa.alloc(u8, 1500 * 1024);
    defer gpa.free(huge);
    pattern(2, huge);

    for ([_]u8{ 0, 1 }) |v| {
        try testing.expectEqual(Status.ok, writeFile(&writer, v, "hello.txt", small, 4096));
        try testing.expectEqual(Status.ok, writeFile(&writer, v, "Snouty Beam received cart.uf2", big, 4096));
        // Odd chunk sizes: partial sectors continued across writes.
        try testing.expectEqual(Status.ok, writeFile(&writer, v, "odd chunks.bin", big[0..5000], 333));
        try testing.expectEqual(Status.ok, writeFile(&writer, v, "empty", "", 4096));
        try expectFile(v, "hello.txt", small);
        try expectFile(v, "HELLO.TXT", small);
        try expectFile(v, "snouty beam received cart.uf2", big);
        try expectFile(v, "odd chunks.bin", big[0..5000]);
        try expectFile(v, "empty", "");
    }
    // Only the external volume has room for 1.5 MB.
    try testing.expectEqual(Status.no_space, writeFile(&writer, 0, "huge.bin", huge, 4096));
    try testing.expectEqual(Status.ok, writeFile(&writer, 1, "huge.bin", huge, 4096));
    try expectFile(1, "huge.bin", huge);

    imgs.reboot();
    for (imgs.bufs, [_]u32{ 4, 5 }) |img, files| {
        const rep = try checkImage(gpa, img);
        try testing.expectEqual(files, rep.files);
        try testing.expectEqual(@as(u32, 0), rep.lost_clusters);
        try testing.expect(!rep.fats_differ);
    }
    try expectFile(1, "huge.bin", huge);
}

test "stat counts free space, reservations and root entries" {
    const gpa = testing.allocator;
    var imgs = try Images.init(gpa);
    defer imgs.deinit(gpa);

    const s0 = writer.stat(disk(0), false).?;
    try testing.expectEqual(@as(u32, 512), s0.cluster_size);
    try testing.expectEqual(@as(u32, 31), s0.free_root_entries); // the label takes one
    try testing.expectEqual(s0.total_bytes, s0.free_bytes);
    const s1 = writer.stat(disk(1), false).?;
    try testing.expectEqual(@as(u32, 127), s1.free_root_entries);
    try testing.expect(s1.total_bytes > 1700 * 1024);

    try testing.expectEqual(Status.ok, writer.create(disk(0), "reserved.bin", 10_000));
    const s2 = writer.stat(disk(0), true).?;
    try testing.expectEqual(s0.free_bytes - 20 * 512, s2.free_bytes);
    writer.abort();

    var data: [1000]u8 = undefined;
    pattern(3, &data);
    try testing.expectEqual(Status.ok, writeFile(&writer, 0, "a.bin", &data, 4096));
    const s3 = writer.stat(disk(0), false).?;
    try testing.expectEqual(s0.free_bytes - 1024, s3.free_bytes);
    try testing.expectEqual(@as(u32, 29), s3.free_root_entries);
}

test "exists matches long and 8.3 names, any case" {
    const gpa = testing.allocator;
    var imgs = try Images.init(gpa);
    defer imgs.deinit(gpa);

    try testing.expectEqual(Status.ok, writeFile(&writer, 0, "snouty-pong.uf2", "x", 4096));
    try testing.expectEqual(Status.exists, writer.create(disk(0), "snouty-pong.uf2", 1));
    try testing.expectEqual(Status.exists, writer.create(disk(0), "SNOUTY-PONG.UF2", 1));
    try testing.expectEqual(Status.exists, writer.create(disk(0), "SNOUTY~1.UF2", 1));
    try testing.expectEqual(Status.exists, writer.create(disk(0), "snouty~1.uf2", 1));
    // The stored 8.3 name is the alias, not the long name cut to 8 + 3.
    try testing.expectEqual(Status.ok, writer.create(disk(0), "SNOUTY-P.UF2", 1));
    writer.abort();
    try testing.expectEqual(Status.ok, writer.create(disk(0), "snouty-pong2.uf2", 1));
    writer.abort();
    // The other volume is separate.
    try testing.expectEqual(Status.ok, writer.create(disk(1), "snouty-pong.uf2", 1));
    writer.abort();
}

test "8.3 aliases are unique: ~1, ~2, ~3" {
    const gpa = testing.allocator;
    var imgs = try Images.init(gpa);
    defer imgs.deinit(gpa);

    const want = [_]struct { []const u8, *const [11]u8 }{
        .{ "snouty-beam.uf2", "SNOUTY~1UF2" },
        .{ "snouty-bear.uf2", "SNOUTY~2UF2" },
        .{ "Snouty Beast.uf2", "SNOUTY~3UF2" },
        .{ "a+b;c=d[e].tar.gz", "A_B_C_~1GZ " },
        .{ "noext", "NOEXT~1    " },
        .{ "x.verylongext", "X~1     VER" },
    };
    for (want) |w| try testing.expectEqual(Status.ok, writeFile(&writer, 0, w[0], "data", 4096));
    for (want) |w| {
        const got = rawAlias(imgs.bufs[0], w[0]) orelse return error.FileMissing;
        try testing.expectEqualStrings(w[1], &got);
        try expectFile(0, w[0], "data");
    }

    var alias: [11]u8 = undefined;
    fat_write.aliasFor("abcdefghijk.uf2", 12, &alias);
    try testing.expectEqualStrings("ABCDE~12UF2", &alias);
}

test "bad names" {
    const gpa = testing.allocator;
    var imgs = try Images.init(gpa);
    defer imgs.deinit(gpa);

    const bad = [_][]const u8{
        "",            " lead",                   "trail ", ".hidden", "dot.",
        "a/b",         "a\\b",                    "a:b",    "a*b",     "a?b",
        "a\"b",        "a<b",                     "a>b",    "a|b",     "tab\there",
        "caf\xc3\xa9", &@as([64]u8, @splat('x')),
    };
    for (bad) |n| try testing.expectEqual(Status.bad_name, writer.create(disk(0), n, 1));
    try testing.expectEqual(Status.ok, writer.create(disk(0), &@as([63]u8, @splat('x')), 1));
    writer.abort();
    try testing.expectEqual(Status.ok, writer.create(disk(0), "a", 1));
    writer.abort();
}

test "order and range errors" {
    const gpa = testing.allocator;
    var imgs = try Images.init(gpa);
    defer imgs.deinit(gpa);

    var data: [4097]u8 = undefined;
    pattern(4, &data);
    try testing.expectEqual(Status.bad_request, writer.beginWrite(0, data[0..10]));
    try testing.expectEqual(Status.bad_request, writer.beginCommit());

    try testing.expectEqual(Status.ok, writer.create(disk(0), "f.bin", 5000));
    try testing.expectEqual(Status.bad_request, writer.create(disk(0), "g.bin", 1)); // one open file
    try testing.expectEqual(Status.bad_request, writer.beginCommit()); // nothing written
    try testing.expectEqual(Status.bad_request, writer.beginWrite(1, data[0..10])); // not sequential
    try testing.expectEqual(Status.bad_request, writer.beginWrite(0, data[0..0]));
    try testing.expectEqual(Status.bad_request, writer.beginWrite(0, data[0..4097]));
    try testing.expectEqual(Status.ok, writer.beginWrite(0, data[0..4096]));
    try testing.expectEqual(Status.bad_request, writer.beginWrite(4096, data[0..10])); // in flight
    try testing.expectEqual(Status.ok, drain(&writer));
    try testing.expectEqual(Status.bad_request, writer.beginWrite(4096, data[0..905])); // past the end
    try testing.expectEqual(Status.ok, writer.beginWrite(4096, data[0..904]));
    try testing.expectEqual(Status.ok, drain(&writer));
    try testing.expectEqual(Status.ok, writer.beginCommit());
    try testing.expectEqual(Status.ok, drain(&writer));
    try testing.expect(!writer.isOpen());
    try testing.expectEqual(Status.bad_request, writer.beginWrite(5000, data[0..1]));
}

test "no_space and dir_full" {
    const gpa = testing.allocator;
    var imgs = try Images.init(gpa);
    defer imgs.deinit(gpa);

    const free = writer.stat(disk(0), false).?.free_bytes;
    try testing.expectEqual(Status.no_space, writer.create(disk(0), "big", free + 1));
    try testing.expectEqual(Status.ok, writer.create(disk(0), "big", free));
    writer.abort();

    // 31 free entries: 15 files with 1 long-name entry each take 30.
    var name_buf: [16]u8 = undefined;
    for (0..15) |i| {
        const n = try std.fmt.bufPrint(&name_buf, "f{d}.bin", .{i});
        try testing.expectEqual(Status.ok, writeFile(&writer, 0, n, "z", 4096));
    }
    try testing.expectEqual(@as(u32, 1), writer.stat(disk(0), false).?.free_root_entries);
    try testing.expectEqual(Status.dir_full, writer.create(disk(0), "g.bin", 1));
    // A deleted file's entries are reused.
    try testing.expect(storage.deleteCart("f3.bin"));
    try testing.expectEqual(Status.ok, writeFile(&writer, 0, "g.bin", "y", 4096));
    try expectFile(0, "g.bin", "y");
    const rep = try checkImage(gpa, imgs.bufs[0]);
    try testing.expectEqual(@as(u32, 15), rep.files);
}

test "abort leaves the drive as it was" {
    const gpa = testing.allocator;
    var imgs = try Images.init(gpa);
    defer imgs.deinit(gpa);

    try testing.expectEqual(Status.ok, writeFile(&writer, 0, "keep.txt", "keep", 4096));
    const before = try gpa.dupe(u8, imgs.bufs[0]);
    defer gpa.free(before);

    try testing.expectEqual(Status.ok, writer.create(disk(0), "dropped.bin", 9000));
    writer.abort();
    try testing.expectEqualSlices(u8, before, imgs.bufs[0]);

    var data: [9000]u8 = undefined;
    pattern(5, &data);
    try testing.expectEqual(Status.ok, writer.create(disk(0), "dropped.bin", 9000));
    try testing.expectEqual(Status.ok, writer.beginWrite(0, data[0..4096]));
    try testing.expectEqual(Status.ok, drain(&writer));
    writer.abort();
    // Only free clusters' contents changed.
    try testing.expect(!differsOutsideFreeData(before, imgs.bufs[0]));
    try testing.expect(storage.host.find(0, "dropped.bin") == null);
}

test "long name entries spanning two directory sectors" {
    const gpa = testing.allocator;
    var imgs = try Images.init(gpa);
    defer imgs.deinit(gpa);

    // Label + 6 files x 2 entries = 13 entries: the next file starts at
    // entry 13 and a 63-character name (6 entries) runs to entry 18.
    var name_buf: [16]u8 = undefined;
    for (0..6) |i| {
        const n = try std.fmt.bufPrint(&name_buf, "file{d}.txt", .{i});
        try testing.expectEqual(Status.ok, writeFile(&writer, 0, n, "ab", 4096));
    }
    const long = "A long name that fills sixty-three characters for this test.uf2";
    try testing.expectEqual(@as(usize, 63), long.len);
    var data: [2000]u8 = undefined;
    pattern(6, &data);
    try testing.expectEqual(Status.ok, writeFile(&writer, 0, long, &data, 4096));
    try expectFile(0, long, &data);
    try testing.expect(rawAlias(imgs.bufs[0], long) != null);

    // And the 8.3 entry itself first in a sector (LFN wholly in the previous one).
    var imgs2 = try Images.init(gpa);
    defer imgs2.deinit(gpa);
    for (0..5) |i| {
        const n = try std.fmt.bufPrint(&name_buf, "file{d}.txt", .{i});
        try testing.expectEqual(Status.ok, writeFile(&writer, 0, n, "ab", 4096));
    }
    // Label + 5 files x 2 = 11 entries: a 53-character name takes 11..15
    // (long name) and 16, the first entry of the second sector (8.3).
    const name53 = &@as([53]u8, @splat('x'));
    try testing.expectEqual(@as(u32, 6), fat_write.dirEntriesFor(name53.len));
    try testing.expectEqual(Status.ok, writeFile(&writer, 0, name53, &data, 4096));
    try expectFile(0, name53, &data);
    try testing.expect(storage.deleteCart(name53));
    try testing.expect(storage.host.find(0, name53) == null);
    _ = try checkImage(gpa, imgs2.bufs[0]);
}

test "files created here are deleted by storage.deleteCart" {
    const gpa = testing.allocator;
    var imgs = try Images.init(gpa);
    defer imgs.deinit(gpa);

    for ([_]u8{ 0, 1 }) |v| {
        const empty_stat = writer.stat(disk(v), false).?;
        var data: [30000]u8 = undefined;
        pattern(7, &data);
        try testing.expectEqual(Status.ok, writeFile(&writer, v, "first.uf2", data[0..1000], 4096));
        try testing.expectEqual(Status.ok, writeFile(&writer, v, "Second cart with a long name.uf2", &data, 4096));
        try testing.expectEqual(Status.ok, writeFile(&writer, v, "third.uf2", data[0..7000], 4096));
        try testing.expect(storage.deleteCart("Second cart with a long name.uf2"));
        try testing.expect(storage.host.find(v, "Second cart with a long name.uf2") == null);
        try expectFile(v, "first.uf2", data[0..1000]);
        try expectFile(v, "third.uf2", data[0..7000]);
        // The freed clusters (in the middle) are reused first fit.
        try testing.expectEqual(Status.ok, writeFile(&writer, v, "fourth.uf2", &data, 4096));
        try expectFile(v, "fourth.uf2", &data);
        try testing.expect(storage.deleteCart("first.uf2"));
        try testing.expect(storage.deleteCart("THIRD~1.UF2"));
        try testing.expect(storage.deleteCart("fourth.uf2"));
        const rep = try checkImage(gpa, imgs.bufs[v]);
        try testing.expectEqual(@as(u32, 0), rep.files);
        try testing.expectEqual(@as(u32, 0), rep.used_clusters);
        const s = writer.stat(disk(v), false).?;
        try testing.expectEqual(empty_stat.free_bytes, s.free_bytes);
        try testing.expectEqual(empty_stat.free_root_entries, s.free_root_entries);
    }
}

test "files a host left after the end marker or with holes" {
    const gpa = testing.allocator;
    var imgs = try Images.init(gpa);
    defer imgs.deinit(gpa);

    try testing.expectEqual(Status.ok, writeFile(&writer, 0, "one.txt", "1", 4096));
    // Garbage after the end marker (a non-zeroed directory): the new file's
    // entries must end with a fresh end marker.
    const g = fat_write.Geometry.parse(imgs.bufs[0][0..sector]).?;
    const root = imgs.bufs[0][g.root_start * sector ..][0 .. g.root_sectors * sector];
    @memset(root[3 * 32 + 1 ..], 0x41);
    root[3 * 32] = 0; // label, LFN, 8.3: entry 3 is the end marker
    imgs.reboot();
    try testing.expectEqual(Status.ok, writeFile(&writer, 0, "two.txt", "2", 4096));
    // two.txt took entries 3 and 4; entry 5 is the new end marker.
    try testing.expectEqual(@as(u8, 0), root[5 * 32]);
    try expectFile(0, "two.txt", "2");
    const rep = try checkImage(gpa, imgs.bufs[0]);
    try testing.expectEqual(@as(u32, 2), rep.files);
}

/// The flushes a full create/write/commit takes, and which of them start the commit.
const CutPlan = struct { total: u32, first_commit: u32 };

fn cutScenario(w: *Writer, v: u8, data: []const u8, plan: ?*CutPlan) void {
    _ = w.create(disk(v), "Received cart.uf2", @intCast(data.len));
    var off: usize = 0;
    while (off < data.len) {
        const n = @min(4096, data.len - off);
        _ = w.beginWrite(@intCast(off), data[off..][0..n]);
        _ = drain(w);
        off += n;
    }
    if (plan) |p| p.first_commit = storage.host.flush_count;
    _ = w.beginCommit();
    _ = drain(w);
    if (plan) |p| p.total = storage.host.flush_count;
    w.abort();
}

test "power cut after every flash write: file absent or complete, never cross-linked" {
    const gpa = testing.allocator;
    var imgs = try Images.init(gpa);
    defer imgs.deinit(gpa);

    var data: [30 * 1024 + 77]u8 = undefined;
    pattern(8, &data);
    var other: [9000]u8 = undefined;
    pattern(9, &other);

    for ([_]u8{ 0, 1 }) |v| {
        // Some files already there, with a hole, so the new file is fragmented.
        storage.host.mount(&imgs.bufs, true);
        try testing.expectEqual(Status.ok, writeFile(&writer, v, "before.uf2", &other, 4096));
        try testing.expectEqual(Status.ok, writeFile(&writer, v, "hole.uf2", other[0..3000], 4096));
        try testing.expectEqual(Status.ok, writeFile(&writer, v, "after.uf2", &other, 4096));
        try testing.expect(storage.deleteCart("hole.uf2"));
        const base = try gpa.dupe(u8, imgs.bufs[v]);
        defer gpa.free(base);
        const base_rep = try checkImage(gpa, base);

        var plan: CutPlan = undefined;
        imgs.reboot();
        cutScenario(&writer, v, &data, &plan);
        try expectFile(v, "Received cart.uf2", &data);
        try testing.expect(plan.total > plan.first_commit);

        var k: u32 = 0;
        while (k <= plan.total) : (k += 1) {
            @memcpy(imgs.bufs[v], base);
            imgs.reboot();
            storage.host.flush_budget = k;
            cutScenario(&writer, v, &data, null);
            imgs.reboot(); // power back: the pending block is lost

            const rep = checkImage(gpa, imgs.bufs[v]) catch |err| {
                std.debug.print("cut after flush {d} of {d} (volume {d}): {s}\n", .{ k, plan.total, v, @errorName(err) });
                return err;
            };
            try expectFile(v, "before.uf2", &other);
            try expectFile(v, "after.uf2", &other);
            const present = storage.host.find(v, "Received cart.uf2") != null;
            if (present) {
                try expectFile(v, "Received cart.uf2", &data);
                try testing.expectEqual(base_rep.files + 1, rep.files);
            } else {
                try testing.expectEqual(base_rep.files, rep.files);
            }
            if (k <= plan.first_commit) {
                // Before commit: only free clusters changed.
                try testing.expect(!present);
                try testing.expect(!differsOutsideFreeData(base, imgs.bufs[v]));
                try testing.expectEqual(@as(u32, 0), rep.lost_clusters);
                try testing.expect(!rep.fats_differ);
            } else if (k == plan.total) {
                try testing.expect(present);
                try testing.expectEqual(@as(u32, 0), rep.lost_clusters);
                try testing.expect(!rep.fats_differ);
            } else if (!present) {
                // Inside commit: lost clusters at most the file's own.
                try testing.expect(rep.lost_clusters <= (data.len + sector - 1) / sector);
            }
        }
    }
}
