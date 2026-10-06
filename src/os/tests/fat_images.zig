//! Host tool for src/os/tests/fat_images.py: writes FAT images made by
//! loader/fat_write.zig (through storage.zig's host backend, as the unit tests
//! do) plus a manifest, so real FAT tools (fsck.fat, mtools or pyfatfs) can
//! check them. Built by `zig build fat-images`.
//!
//! Usage: fat-images OUT_DIR
//! Writes OUT_DIR/*.img and OUT_DIR/manifest.json:
//!   [{"image": "...", "phase": "complete"|"before_commit"|"in_commit",
//!     "files": [{"name": "...", "size": N, "sha256": "..."}],
//!     "maybe": {...}}]   // in_commit: the new file, present or absent
const std = @import("std");
const t = @import("fat_write_test.zig");
const fat_write = @import("../loader/fat_write.zig");
const storage = @import("../loader/storage.zig");

const File = struct { name: []const u8, data: []const u8 };

const Entry = struct {
    image: []const u8,
    phase: []const u8,
    files: []const File,
    maybe: ?File = null,
};

var writer: fat_write.Writer = .{};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) {
        std.debug.print("usage: fat-images OUT_DIR\n", .{});
        std.process.exit(2);
    }
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, args[1]);
    var out = try cwd.openDir(io, args[1], .{});
    defer out.close(io);

    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(gpa);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var imgs = try t.Images.init(gpa);
    defer imgs.deinit(gpa);

    // ── many files with long names, aliases, a sector-straddling long name,
    // an empty file, a deleted one ──────────────────────────────────────────
    const big = try arena.alloc(u8, 100 * 1024 + 7);
    t.pattern(11, big);
    const files_template = [_]File{
        .{ .name = "hello.txt", .data = "hello from a cart\r\n" },
        .{ .name = "snouty-beam.uf2", .data = big[0..3000] },
        .{ .name = "snouty-bear.uf2", .data = big[100..2100] },
        .{ .name = "Snouty Beast.uf2", .data = big[0..512] },
        .{ .name = "A long name that fills sixty-three characters for this test.uf2", .data = big[0..4096] },
        .{ .name = "received cart 100k.uf2", .data = big },
        .{ .name = "empty", .data = "" },
        .{ .name = "a+b;c=d[e].tar.gz", .data = "odd characters\n" },
    };
    for ([_]u8{ 0, 1 }) |v| {
        for (files_template) |f| try expectOk(t.writeFile(&writer, v, f.name, f.data, 4096));
        try expectOk(t.writeFile(&writer, v, "deleted later.bin", big[0..9000], 4096));
        if (!storage.deleteCart("deleted later.bin")) return error.DeleteFailed;
        // Reuses the deleted file's space.
        try expectOk(t.writeFile(&writer, v, "after delete.txt", big[0..700], 333));
    }
    var all: std.ArrayList(File) = .empty;
    try all.appendSlice(arena, &files_template);
    try all.append(arena, .{ .name = "after delete.txt", .data = big[0..700] });
    for ([_]u8{ 0, 1 }, [_][]const u8{ "files-syclbadge.img", "files-syclextra.img" }) |v, name| {
        try save(io, out, name, imgs.bufs[v]);
        try entries.append(gpa, .{ .image = name, .phase = "complete", .files = all.items });
    }

    // ── a power cut after every flash write of one create/write/commit ────
    const data = big[0 .. 30 * 1024 + 77];
    const other = big[50_000..59_000];
    const new_file: File = .{ .name = "Received cart.uf2", .data = data };
    for ([_]u8{ 0, 1 }) |v| {
        storage.host.mount(&imgs.bufs, true);
        try expectOk(t.writeFile(&writer, v, "before.uf2", other, 4096));
        try expectOk(t.writeFile(&writer, v, "hole.uf2", other[0..3000], 4096));
        try expectOk(t.writeFile(&writer, v, "after.uf2", other, 4096));
        if (!storage.deleteCart("hole.uf2")) return error.DeleteFailed;
        const base = try arena.dupe(u8, imgs.bufs[v]);
        const base_files = try arena.dupe(File, &.{ .{ .name = "before.uf2", .data = other }, .{ .name = "after.uf2", .data = other } });
        const with_new = try arena.dupe(File, &.{ base_files[0], base_files[1], new_file });

        imgs.reboot();
        const first_commit, const total = run(v, data);
        var k: u32 = 0;
        while (k <= total) : (k += 1) {
            @memcpy(imgs.bufs[v], base);
            imgs.reboot();
            storage.host.flush_budget = k;
            _ = run(v, data);
            imgs.reboot();
            const name = try std.fmt.allocPrint(arena, "cut-v{d}-{d:0>3}.img", .{ v, k });
            try save(io, out, name, imgs.bufs[v]);
            try entries.append(gpa, if (k <= first_commit)
                .{ .image = name, .phase = "before_commit", .files = base_files }
            else if (k == total)
                .{ .image = name, .phase = "complete", .files = with_new }
            else
                .{ .image = name, .phase = "in_commit", .files = base_files, .maybe = new_file });
        }
    }

    // ── manifest ──────────────────────────────────────────────────────────
    var json: std.Io.Writer.Allocating = .init(gpa);
    defer json.deinit();
    const w = &json.writer;
    try w.writeAll("[\n");
    for (entries.items, 0..) |e, i| {
        try w.print("  {{\"image\": \"{s}\", \"phase\": \"{s}\", \"files\": [", .{ e.image, e.phase });
        for (e.files, 0..) |f, j| {
            if (j > 0) try w.writeAll(", ");
            try writeFileJson(w, f);
        }
        try w.writeAll("]");
        if (e.maybe) |f| {
            try w.writeAll(", \"maybe\": ");
            try writeFileJson(w, f);
        }
        try w.writeAll(if (i + 1 < entries.items.len) "},\n" else "}\n");
    }
    try w.writeAll("]\n");
    try out.writeFile(io, .{ .sub_path = "manifest.json", .data = json.written() });
}

fn run(v: u8, data: []const u8) struct { u32, u32 } {
    _ = writer.create(t.disk(v), "Received cart.uf2", @intCast(data.len));
    var off: usize = 0;
    while (off < data.len) {
        const n = @min(4096, data.len - off);
        _ = writer.beginWrite(@intCast(off), data[off..][0..n]);
        while (writer.step() == .more) {}
        off += n;
    }
    const first_commit = storage.host.flush_count;
    _ = writer.beginCommit();
    while (writer.step() == .more) {}
    writer.abort();
    return .{ first_commit, storage.host.flush_count };
}

fn expectOk(s: fat_write.Status) !void {
    if (s != .ok) {
        std.debug.print("fat_write: {s}\n", .{@tagName(s)});
        return error.WriteFailed;
    }
}

fn save(io: std.Io, dir: std.Io.Dir, name: []const u8, img: []const u8) !void {
    try dir.writeFile(io, .{ .sub_path = name, .data = img });
}

fn writeFileJson(w: *std.Io.Writer, f: File) !void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(f.data, &digest, .{});
    try w.print("{{\"name\": \"{s}\", \"size\": {d}, \"sha256\": \"{x}\"}}", .{ f.name, f.data.len, &digest });
}
