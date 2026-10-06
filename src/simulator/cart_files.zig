//! Cart files in the simulator (fork/CART_FILES.md): volume 0 (SYCLBADGE) is a
//! `SYCLBADGE` directory next to the simulator binary, so a file a cart writes
//! shows up there and can be copied to a badge. There is no volume 1 and never
//! a USB host. Requests are served synchronously on the cart thread with the
//! OS's rules (names, one open file, sequential writes, the order of calls),
//! and the badge volume's limits: about 1.24 MB and 31 root directory entries
//! (a long name takes one per 13 characters, plus one). An open file is written
//! to `.cart-file.part` and renamed on commit, so an abort or a simulator exit
//! before commit leaves no file under the cart's name. Flash time is not
//! modeled.
const std = @import("std");
const abi = @import("sim_abi");
const fat_write = @import("fat_write");
const root = @import("root");

const log = std.log.scoped(.cart_files);

const dir_name = "SYCLBADGE";
const part_name = ".cart-file.part";
/// The badge's SYCLBADGE volume (src/os/loader/storage.zig): 2541 data
/// clusters of 512 bytes, 32 root entries of which the label takes one.
const volume_bytes: u32 = 2541 * 512;
const root_entries: u32 = 31;

var dir: ?std.Io.Dir = null;
var dir_tried = false;

var open = false;
var part: ?std.Io.File = null;
var name_buf: [fat_write.max_name]u8 = undefined;
var name_len: usize = 0;
var size: u32 = 0;
var written: u32 = 0;

fn openDir() ?std.Io.Dir {
    if (dir_tried) return dir;
    dir_tried = true;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = std.process.executableDirPath(root.io, &path_buf) catch 0;
    var path: []const u8 = dir_name;
    if (dir_len > 0 and dir_len + 1 + dir_name.len <= path_buf.len) {
        path_buf[dir_len] = '/';
        @memcpy(path_buf[dir_len + 1 ..][0..dir_name.len], dir_name);
        path = path_buf[0 .. dir_len + 1 + dir_name.len];
    }
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(root.io, path) catch |err| {
        log.warn("can't create {s} ({s}): no cart files", .{ path, @errorName(err) });
        return null;
    };
    dir = cwd.openDir(root.io, path, .{ .iterate = true }) catch |err| {
        log.warn("can't open {s} ({s}): no cart files", .{ path, @errorName(err) });
        return null;
    };
    log.info("cart files go to {s}", .{path});
    return dir;
}

const Usage = struct { used_bytes: u32 = 0, used_entries: u32 = 0, exists: bool = false };

/// Space and entries the files in the directory take, and whether `name`
/// (any case) is one of them.
fn usage(d: std.Io.Dir, name: []const u8) Usage {
    var u: Usage = .{};
    var it = d.iterate();
    while (it.next(root.io) catch null) |e| {
        if (e.kind != .file or std.mem.eql(u8, e.name, part_name)) continue;
        if (name.len > 0 and std.ascii.eqlIgnoreCase(e.name, name)) u.exists = true;
        const st = d.statFile(root.io, e.name, .{}) catch continue;
        const clusters = std.math.divCeil(u64, st.size, 512) catch 0;
        u.used_bytes +|= @intCast(@min(clusters * 512, std.math.maxInt(u32)));
        u.used_entries += fat_write.dirEntriesFor(@min(e.name.len, 255));
    }
    return u;
}

fn closePart(d: std.Io.Dir, delete: bool) void {
    if (part) |f| f.close(root.io);
    part = null;
    if (delete) d.deleteFile(root.io, part_name) catch {};
    open = false;
}

fn finish(req: *abi.FileRequest, status: abi.FileStatus, result: u32) void {
    req.status = status;
    req.result = result;
    req.flags = @bitCast(abi.FileFlags{ .usb_host = false, .ext_volume = false });
    @atomicStore(abi.FileState, &req.state, .done, .release);
}

pub fn handle(req: *abi.FileRequest, buf: ?[*]u8) void {
    if (req.magic == 0) return; // abandoned by the client
    req.state = .busy;
    if (req.magic != abi.FILE_MAGIC) return finish(req, .bad_request, 0);
    const len = req.len;
    const op = req.op;
    if (op == .probe) return finish(req, .ok, abi.FILE_ABI_VERSION);
    const d = openDir() orelse return finish(req, .io_error, 0);
    switch (op) {
        .stat => {
            if (req.volume != 0) return finish(req, .no_volume, 0);
            const u = usage(d, "");
            const reserved: u32 = if (open) @intCast((@as(u64, size) + 511) / 512 * 512) else 0;
            const st: abi.FileStat = .{
                .free_bytes = volume_bytes -| u.used_bytes -| reserved,
                .free_root_entries = root_entries -| u.used_entries,
                .cluster_size = 512,
                .total_bytes = volume_bytes,
            };
            if (len != 0) {
                const p = buf orelse return finish(req, .bad_buffer, 0);
                const n = @min(len, @sizeOf(abi.FileStat));
                @memcpy(p[0..n], std.mem.asBytes(&st)[0..n]);
            }
            finish(req, .ok, st.free_bytes);
        },
        .create => {
            if (open) return finish(req, .bad_request, 0);
            if (req.volume != 0) return finish(req, .no_volume, 0);
            if (len == 0 or len > fat_write.max_name) return finish(req, .bad_name, 0);
            const p = buf orelse return finish(req, .bad_buffer, 0);
            const name = p[0..len];
            if (!fat_write.validName(name)) return finish(req, .bad_name, 0);
            const u = usage(d, name);
            if (u.exists) return finish(req, .exists, 0);
            if (u.used_entries + fat_write.dirEntriesFor(name.len) > root_entries) return finish(req, .dir_full, 0);
            const need: u64 = (@as(u64, req.offset) + 511) / 512 * 512;
            if (need > volume_bytes -| u.used_bytes) return finish(req, .no_space, 0);
            part = d.createFile(root.io, part_name, .{ .truncate = true }) catch return finish(req, .io_error, 0);
            @memcpy(name_buf[0..len], name);
            name_len = len;
            size = req.offset;
            written = 0;
            open = true;
            finish(req, .ok, @intCast(need));
        },
        .write => {
            if (!open) return finish(req, .not_open, 0);
            if (len == 0 or len > fat_write.max_write) return finish(req, .bad_request, 0);
            if (req.offset != written or len > size - written) return finish(req, .bad_request, 0);
            const p = buf orelse return finish(req, .bad_buffer, 0);
            part.?.writePositionalAll(root.io, p[0..len], written) catch return finish(req, .io_error, 0);
            written += len;
            finish(req, .ok, written);
        },
        .commit => {
            if (!open) return finish(req, .not_open, 0);
            if (written != size) return finish(req, .bad_request, 0);
            const name = name_buf[0..name_len];
            // Someone may have put a file there meanwhile.
            if (usage(d, name).exists) {
                closePart(d, true);
                return finish(req, .exists, 0);
            }
            closePart(d, false);
            d.rename(part_name, d, name, root.io) catch {
                d.deleteFile(root.io, part_name) catch {};
                return finish(req, .io_error, 0);
            };
            log.info("cart wrote {s}/{s} ({d} bytes)", .{ dir_name, name, size });
            finish(req, .ok, size);
        },
        .abort => {
            if (!open) return finish(req, .not_open, 0);
            closePart(d, true);
            finish(req, .ok, 0);
        },
        else => finish(req, .bad_request, 0),
    }
}
