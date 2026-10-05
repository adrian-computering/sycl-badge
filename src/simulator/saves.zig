//! Cart saves in the simulator: the OS's save_store.zig over a fake NOR flash
//! (erase sets 0xFF, program only clears bits) kept in `saves.bin` next to the
//! simulator binary, so saves survive simulator restarts like they survive
//! power-off on the badge. Requests are served synchronously on the cart thread
//! with the same validation as src/os/system/saves.zig (minus the RAM-range
//! checks, which have no meaning for host pointers). Flash time is not modeled:
//! writes complete instantly.
const std = @import("std");
const abi = @import("sim_abi");
const save_store = @import("save_store");
const root = @import("root");

const log = std.log.scoped(.saves);

const region_size = save_store.block_size * save_store.block_count;

var image: [region_size]u8 = @splat(0xFF);
var file: ?std.Io.File = null;
var store: save_store.Store = undefined;
var opened: bool = false;
var flash_ctx: u8 = 0;

fn open(now_us: u64) void {
    opened = true;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = std.process.executableDirPath(root.io, &path_buf) catch 0;
    const name = "saves.bin";
    var path: []const u8 = name;
    if (dir_len > 0 and dir_len + 1 + name.len <= path_buf.len) {
        path_buf[dir_len] = '/';
        @memcpy(path_buf[dir_len + 1 ..][0..name.len], name);
        path = path_buf[0 .. dir_len + 1 + name.len];
    }
    if (std.Io.Dir.cwd().createFile(root.io, path, .{ .read = true, .truncate = false })) |f| {
        file = f;
        const n = f.readPositionalAll(root.io, &image, 0) catch 0;
        if (n < region_size) {
            // New (or short) file: the rest is erased flash.
            @memset(image[n..], 0xFF);
            persist(0, region_size);
        }
        log.info("save store backed by {s}", .{path});
    } else |err| {
        log.warn("can't open {s} ({s}): saves last until the simulator exits", .{ path, @errorName(err) });
    }
    store.init(.{ .ctx = &flash_ctx, .read = flashRead, .erase4k = flashErase, .program = flashProgram }, now_us);
}

fn persist(off: u32, len: usize) void {
    const f = file orelse return;
    f.writePositionalAll(root.io, image[off..][0..len], off) catch |err| {
        log.warn("writing saves.bin failed: {s}", .{@errorName(err)});
    };
}

fn flashRead(_: *anyopaque, off: u32, dst: []u8) void {
    if (off >= region_size) return @memset(dst, 0xFF);
    const n = @min(dst.len, region_size - off);
    @memcpy(dst[0..n], image[off..][0..n]);
    if (n < dst.len) @memset(dst[n..], 0xFF);
}

fn flashErase(_: *anyopaque, off: u32) void {
    if (off % save_store.block_size != 0 or off >= region_size) return;
    @memset(image[off..][0..save_store.block_size], 0xFF);
    persist(off, save_store.block_size);
}

fn flashProgram(_: *anyopaque, off: u32, src: []const u8) void {
    if (off >= region_size or src.len > region_size - off) return;
    for (image[off..][0..src.len], src) |*d, s| d.* &= s; // NOR: program only clears bits
    persist(off, src.len);
}

fn validKey(req: *const abi.SaveRequest) ?[]const u8 {
    const n = req.key_len;
    if (n == 0 or n > save_store.max_key) return null;
    for (req.key[0..n]) |c| if (c < 0x20 or c > 0x7E) return null;
    return req.key[0..n];
}

fn toAbi(s: save_store.Status) abi.SaveStatus {
    return @fromBackingInt(@backingInt(s));
}

fn finish(req: *abi.SaveRequest, status: abi.SaveStatus, result: u32) void {
    req.status = status;
    req.result = result;
    @atomicStore(abi.SaveState, &req.state, .done, .release);
}

pub fn handle(req: *abi.SaveRequest, buf: ?[*]u8, now_us: u64) void {
    if (!opened) open(now_us);
    if (req.magic == 0) return; // abandoned by the client
    req.state = .busy;
    if (req.magic != abi.SAVE_MAGIC) return finish(req, .bad_request, 0);
    const len = req.len;
    switch (req.op) {
        .probe => finish(req, .ok, abi.SAVE_ABI_VERSION),
        .read => {
            const key = validKey(req) orelse return finish(req, .bad_request, 0);
            if (len > 0 and buf == null) return finish(req, .bad_buffer, 0);
            const dst: []u8 = if (len > 0) buf.?[0..len] else &.{};
            const r = store.read(key, dst);
            finish(req, toAbi(r.status), r.size);
        },
        .write, .delete => {
            const key = validKey(req) orelse return finish(req, .bad_request, 0);
            const status = if (req.op == .write) blk: {
                if (len == 0) return finish(req, .bad_request, 0);
                if (len > save_store.max_blob) return finish(req, .too_big, 0);
                const src = (buf orelse return finish(req, .bad_buffer, 0))[0..len];
                break :blk store.beginWrite(key, src, now_us);
            } else store.beginDelete(key, now_us);
            if (status != .ok) return finish(req, toAbi(status), 0);
            const done = while (true) switch (store.step()) {
                .more => {},
                .done => |s| break s,
            };
            finish(req, toAbi(done), if (req.op == .write and done == .ok) len else 0);
        },
        .stat => {
            const s = store.stat(now_us);
            if (len != 0) {
                const p = buf orelse return finish(req, .bad_buffer, 0);
                const n = @min(len, @sizeOf(abi.SaveStat));
                @memcpy(p[0..n], std.mem.asBytes(&s)[0..n]);
            }
            finish(req, .ok, s.free_bytes);
        },
        .list => {
            const n = @min(len / @sizeOf(abi.SaveListEntry), save_store.max_entries);
            if (n == 0) return finish(req, .ok, 0);
            const p = buf orelse return finish(req, .bad_buffer, 0);
            if (@intFromPtr(p) % @alignOf(save_store.ListEntry) != 0) return finish(req, .bad_buffer, 0);
            const out = @as([*]save_store.ListEntry, @ptrCast(@alignCast(p)))[0..n];
            finish(req, .ok, store.list(out));
        },
        .exit_watch => finish(req, .ok, 0),
        else => finish(req, .bad_request, 0),
    }
}
