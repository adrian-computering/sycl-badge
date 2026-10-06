//! Cart files (fork/CART_FILES.md): create one new file in the root directory
//! of a FAT12 volume, over a sector interface (storage.readSector/writeSector/
//! flushPendingWrites on the badge, RAM images in host tests).
//!
//! - create: checks the name, finds room in the root directory and reserves
//!   the first free clusters (first fit), in RAM only.
//! - write: sequential bytes into those clusters. They are free space, so the
//!   drive is unchanged until commit.
//! - commit: FAT 1, FAT 2, then the directory entries (long name + a unique
//!   8.3 alias), flushed. A power cut inside commit can leave lost clusters,
//!   never a cross-linked or half-visible file.
//! - abort: forget the reservation.
//!
//! Writes are stepped: one step writes the sectors of one 4 KB erase block,
//! flushes and reads them back (CRC), so a caller can poll USB and audio
//! between erases. Sectors are visited in ascending LBA order (data clusters
//! ascending, FAT 1 < FAT 2 < root directory), so every block is erased once
//! per step.
const std = @import("std");
const names = @import("fat_names.zig");

pub const sector_size = 512;
/// Sectors per 4 KB erase block (volumes start 4 KB aligned).
pub const sectors_per_block = 8;
/// Longest file name (bytes).
pub const max_name = 63;
/// Most bytes per write.
pub const max_write = 4096;
/// FAT12 has fewer than 4085 data clusters (numbered from 2).
pub const max_clusters = 4096;
const entries_per_sector = sector_size / 32;
const lfn_chars_per_entry = 13;
/// Long-name entries + the 8.3 entry for the longest name.
pub const max_dir_entries = (max_name + lfn_chars_per_entry - 1) / lfn_chars_per_entry + 1;

const ATTR_LFN: u8 = 0x0F;
const ATTR_VOLUME: u8 = 0x08;
const ATTR_ARCHIVE: u8 = 0x20;
const FAT12_EOC: u16 = 0xFFF;

/// Date and time stamped on created files (the badge has no clock): 2026-01-01 00:00.
pub const fat_date: u16 = ((2026 - 1980) << 9) | (1 << 5) | 1;
pub const fat_time: u16 = 0;

/// Values match os_abi.FileStatus (cart_files.zig checks it at compile time).
pub const Status = enum(u32) {
    ok = 0,
    exists = 1,
    no_space = 2,
    dir_full = 3,
    bad_request = 4,
    bad_name = 6,
    no_volume = 9,
    io_error = 11,
};

pub const Step = union(enum) { more, done: Status };

pub const Disk = struct {
    ctx: ?*anyopaque = null,
    read: *const fn (ctx: ?*anyopaque, lba: u32, dst: *[sector_size]u8) void,
    write: *const fn (ctx: ?*anyopaque, lba: u32, src: *const [sector_size]u8) void,
    flush: *const fn (ctx: ?*anyopaque) void,
};

pub const Stat = extern struct {
    free_bytes: u32,
    free_root_entries: u32,
    cluster_size: u32,
    total_bytes: u32,
};

/// Volume layout from the boot sector. Only what the badge formats (and what a
/// host may reformat it to) is accepted: 512-byte sectors, 1 sector per
/// cluster, FAT12.
pub const Geometry = struct {
    fat_start: u32,
    fat_sectors: u32,
    num_fats: u32,
    root_start: u32,
    root_sectors: u32,
    root_entries: u32,
    data_start: u32,
    /// Data clusters, numbered 2..clusters+1.
    clusters: u32,

    pub fn parse(bs: *const [sector_size]u8) ?Geometry {
        if (rd16(bs, 510) != 0xAA55) return null;
        if (rd16(bs, 11) != sector_size or bs[13] != 1) return null;
        const reserved: u32 = rd16(bs, 14);
        const num_fats: u32 = bs[16];
        const root_entries: u32 = rd16(bs, 17);
        const total: u32 = if (rd16(bs, 19) != 0) rd16(bs, 19) else rd32(bs, 32);
        const fat_sectors: u32 = rd16(bs, 22);
        if (reserved == 0 or num_fats == 0 or num_fats > 2 or fat_sectors == 0) return null;
        if (root_entries == 0 or root_entries % entries_per_sector != 0) return null;
        const root_sectors = root_entries / entries_per_sector;
        const data_start = reserved + num_fats * fat_sectors + root_sectors;
        if (total <= data_start) return null;
        const clusters = total - data_start;
        if (clusters + 2 > max_clusters or clusters >= 4085) return null;
        // Every cluster needs its 12-bit entry.
        if ((clusters + 2) * 3 > fat_sectors * sector_size * 2) return null;
        return .{
            .fat_start = reserved,
            .fat_sectors = fat_sectors,
            .num_fats = num_fats,
            .root_start = reserved + num_fats * fat_sectors,
            .root_sectors = root_sectors,
            .root_entries = root_entries,
            .data_start = data_start,
            .clusters = clusters,
        };
    }
};

/// Names: 1..63 bytes of printable ASCII, none of \ / : * ? " < > |, no
/// leading or trailing space or dot.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name) return false;
    for (name) |c| {
        if (c < 0x20 or c > 0x7E) return false;
        if (std.mem.indexOfScalar(u8, "\\/:*?\"<>|", c) != null) return false;
    }
    const first = name[0];
    const last = name[name.len - 1];
    return first != ' ' and first != '.' and last != ' ' and last != '.';
}

/// Directory entries a name takes: one per 13 characters, plus the 8.3 entry.
pub fn dirEntriesFor(name_len: usize) u32 {
    return @intCast((name_len + lfn_chars_per_entry - 1) / lfn_chars_per_entry + 1);
}

/// The 8.3 alias "BASIS~N.EXT" for a long name: base from the part before the
/// last dot, extension from the part after it (first 3 characters), spaces and
/// dots dropped, lower case raised, characters 8.3 names can't hold as '_'.
pub fn aliasFor(name: []const u8, n: u32, out: *[11]u8) void {
    @memset(out, ' ');
    const dot = std.mem.lastIndexOfScalar(u8, name, '.');
    const base_src = if (dot) |d| name[0..d] else name;
    var base: [8]u8 = undefined;
    var base_len: usize = 0;
    for (base_src) |c| {
        if (base_len == base.len) break;
        if (sfnChar(c)) |m| {
            base[base_len] = m;
            base_len += 1;
        }
    }
    if (base_len == 0) {
        @memcpy(base[0..4], "FILE");
        base_len = 4;
    }
    var suffix_buf: [8]u8 = undefined;
    const suffix = std.fmt.bufPrint(&suffix_buf, "~{d}", .{n}) catch unreachable;
    const keep = @min(base_len, 8 - suffix.len);
    @memcpy(out[0..keep], base[0..keep]);
    @memcpy(out[keep..][0..suffix.len], suffix);
    if (dot) |d| {
        var ext_len: usize = 0;
        for (name[d + 1 ..]) |c| {
            if (ext_len == 3) break;
            if (sfnChar(c)) |m| {
                out[8 + ext_len] = m;
                ext_len += 1;
            }
        }
    }
}

/// An 8.3 name character for c, null to drop it (space, dot).
fn sfnChar(c: u8) ?u8 {
    if (c == ' ' or c == '.') return null;
    if (std.ascii.isAlphanumeric(c)) return std.ascii.toUpper(c);
    if (std.mem.indexOfScalar(u8, "!#$%&'()-@^_`{}~", c) != null) return c;
    return '_';
}

/// "NAME    EXT" -> "NAME.EXT".
fn formatAlias(alias: *const [11]u8, out: *[12]u8) []const u8 {
    var name_buf: [12:0]u8 = undefined;
    const s = names.formatShortName(alias, &name_buf);
    @memcpy(out[0..s.len], s);
    return out[0..s.len];
}

/// One open file being created. All state is static-size (about 3 KB).
pub const Writer = struct {
    disk: Disk = undefined,
    geo: Geometry = undefined,
    open: bool = false,
    size: u32 = 0,
    name_buf: [max_name]u8 = undefined,
    name_len: usize = 0,
    /// Reserved clusters (bit c = cluster c).
    reserved: [max_clusters / 8]u8 = @splat(0),
    cluster_count: u32 = 0,
    first_cluster: u16 = 0,
    /// Bytes written so far.
    written: u32 = 0,
    /// Cluster holding file byte `written` (when written < size).
    cursor: u16 = 0,

    job: enum { none, write, commit } = .none,
    src: []const u8 = &.{},
    src_done: usize = 0,
    commit: Commit = .{},
    entries: [max_dir_entries][32]u8 = undefined,

    sector: [sector_size]u8 align(4) = undefined,
    dir_bufs: [2][sector_size]u8 align(4) = undefined,
    cache: [sector_size]u8 align(4) = undefined,
    cache_lba: ?u32 = null,
    lfn: [256]u8 = undefined,
    /// Sectors written in the current step, read back after its flush.
    step_lba: [sectors_per_block]u32 = undefined,
    step_crc: [sectors_per_block]u32 = undefined,
    step_n: usize = 0,

    const Commit = struct {
        phase: enum { prepare, fat, dir } = .prepare,
        fat_copy: u32 = 0,
        /// FAT sector index (fat phase) or root directory sector (dir phase).
        sec: u32 = 0,
        run_start: u32 = 0,
        /// Directory entries the file takes, plus one when the entry after
        /// them must become the end-of-directory marker.
        run_len: u32 = 0,
        entry_count: u32 = 0,
    };

    pub fn isOpen(w: *const Writer) bool {
        return w.open;
    }

    /// True while a write or commit is being stepped.
    pub fn isBusy(w: *const Writer) bool {
        return w.job != .none;
    }

    pub fn name(w: *const Writer) []const u8 {
        return w.name_buf[0..w.name_len];
    }

    // ── create / write / commit / abort ────────────────────────────────────

    /// Reserve room for a file of `size` bytes called `file_name` and open it.
    /// Reads only.
    pub fn create(w: *Writer, disk: Disk, file_name: []const u8, size: u32) Status {
        if (w.open) return .bad_request;
        if (!validName(file_name)) return .bad_name;
        w.disk = disk;
        w.cache_lba = null;
        w.disk.read(w.disk.ctx, 0, &w.sector);
        w.geo = Geometry.parse(&w.sector) orelse return .no_volume;

        const dir = w.scanDir(file_name, dirEntriesFor(file_name.len));
        if (dir.exists) return .exists;
        if (dir.run_start == null) return .dir_full;

        const need = std.math.divCeil(u32, size, sector_size) catch unreachable;
        if (need > w.geo.clusters) return .no_space;
        @memset(&w.reserved, 0);
        var got: u32 = 0;
        var c: u32 = 2;
        while (got < need and c < w.geo.clusters + 2) : (c += 1) {
            if (w.fatGet(c) == 0) {
                setBit(&w.reserved, c);
                got += 1;
            }
        }
        if (got < need) {
            @memset(&w.reserved, 0);
            return .no_space;
        }
        w.cluster_count = need;
        w.first_cluster = if (need == 0) 0 else w.nextReserved(1).?;
        w.cursor = w.first_cluster;
        w.written = 0;
        w.size = size;
        @memcpy(w.name_buf[0..file_name.len], file_name);
        w.name_len = file_name.len;
        w.job = .none;
        w.open = true;
        return .ok;
    }

    /// Start writing `data` (1..4096 bytes) at byte `offset`, which must be the
    /// number of bytes written so far. `data` must stay valid until done.
    pub fn beginWrite(w: *Writer, offset: u32, data: []const u8) Status {
        if (!w.open or w.job != .none) return .bad_request;
        if (offset != w.written or data.len == 0 or data.len > max_write) return .bad_request;
        if (data.len > w.size - w.written) return .bad_request;
        w.src = data;
        w.src_done = 0;
        w.job = .write;
        return .ok;
    }

    /// Start linking the file in. All `size` bytes must have been written.
    pub fn beginCommit(w: *Writer) Status {
        if (!w.open or w.job != .none) return .bad_request;
        if (w.written != w.size) return .bad_request;
        w.commit = .{};
        w.job = .commit;
        return .ok;
    }

    /// Drop the open file. Nothing the directory or FAT can see has changed.
    pub fn abort(w: *Writer) void {
        w.open = false;
        w.job = .none;
        w.src = &.{};
        @memset(&w.reserved, 0);
    }

    /// Advance the write or commit in flight by one erase block.
    pub fn step(w: *Writer) Step {
        w.cache_lba = null;
        w.step_n = 0;
        return switch (w.job) {
            .none => .{ .done = .bad_request },
            .write => w.stepWrite(),
            .commit => w.stepCommit(),
        };
    }

    // ── stat ───────────────────────────────────────────────────────────────

    /// Free space and root directory entries of the volume on `disk`. The
    /// open file's reserved clusters count as used when it is on `disk`
    /// (`same_volume`).
    pub fn stat(w: *Writer, disk: Disk, same_volume: bool) ?Stat {
        const saved_disk = w.disk;
        const saved_geo = w.geo;
        defer {
            w.disk = saved_disk;
            w.geo = saved_geo;
            w.cache_lba = null;
        }
        w.disk = disk;
        w.cache_lba = null;
        w.disk.read(w.disk.ctx, 0, &w.sector);
        w.geo = Geometry.parse(&w.sector) orelse return null;
        var free: u32 = 0;
        var c: u32 = 2;
        while (c < w.geo.clusters + 2) : (c += 1) {
            if (w.fatGet(c) == 0) free += 1;
        }
        if (same_volume and w.open and free >= w.cluster_count) free -= w.cluster_count;
        const dir = w.scanDir("", 1);
        return .{
            .free_bytes = free * sector_size,
            .free_root_entries = dir.free_total,
            .cluster_size = sector_size,
            .total_bytes = w.geo.clusters * sector_size,
        };
    }

    // ── stepping ───────────────────────────────────────────────────────────

    fn stepWrite(w: *Writer) Step {
        var block: ?u32 = null;
        while (w.src_done < w.src.len) {
            const lba = w.geo.data_start + (@as(u32, w.cursor) - 2);
            if (block) |b| if (b != lba / sectors_per_block) break;
            block = lba / sectors_per_block;

            const in_sector = w.written % sector_size;
            // A sector this file already started is read back; a new one
            // starts zeroed (the tail past the file's end stays 0).
            if (in_sector == 0) @memset(&w.sector, 0) else w.disk.read(w.disk.ctx, lba, &w.sector);
            const n: u32 = @intCast(@min(sector_size - in_sector, w.src.len - w.src_done));
            @memcpy(w.sector[in_sector..][0..n], w.src[w.src_done..][0..n]);
            w.put(lba, &w.sector);
            w.src_done += n;
            w.written += n;
            if (w.written % sector_size == 0 and w.written < w.size) {
                w.cursor = w.nextReserved(w.cursor).?;
            }
        }
        if (!w.flushAndVerify()) {
            w.job = .none;
            return .{ .done = .io_error };
        }
        if (w.src_done < w.src.len) return .more;
        w.job = .none;
        w.src = &.{};
        return .{ .done = .ok };
    }

    fn stepCommit(w: *Writer) Step {
        if (w.commit.phase == .prepare) {
            const status = w.prepareCommit();
            if (status != .ok) {
                w.abort();
                return .{ .done = status };
            }
            w.commit.phase = .fat;
            w.commit.fat_copy = 0;
            w.commit.sec = 0;
        }
        var block: ?u32 = null;
        while (w.nextCommitSector()) |lba| {
            if (block) |b| if (b != lba / sectors_per_block) break;
            block = lba / sectors_per_block;
            w.disk.read(w.disk.ctx, lba, &w.sector);
            switch (w.commit.phase) {
                .fat => w.patchFatSector(w.commit.sec),
                .dir => w.patchDirSector(w.commit.sec),
                .prepare => unreachable,
            }
            w.put(lba, &w.sector);
            w.commit.sec += 1;
        }
        const ok = w.flushAndVerify();
        if (!ok or w.nextCommitSector() == null) {
            w.abort();
            return .{ .done = if (ok) .ok else .io_error };
        }
        return .more;
    }

    /// Checks nothing changed under the open file, picks the directory slot
    /// and the 8.3 alias, and builds the entries.
    fn prepareCommit(w: *Writer) Status {
        // The reserved clusters must still be free (a USB host could have
        // written the drive since create; cart_files refuses that case too).
        var c: u32 = 2;
        while (c < w.geo.clusters + 2) : (c += 1) {
            if (getBit(&w.reserved, c) and w.fatGet(c) != 0) return .io_error;
        }
        const file_name = w.name();
        const count = dirEntriesFor(file_name.len);
        const dir = w.scanDir(file_name, count);
        if (dir.exists) return .exists;
        const run_start = dir.run_start orelse return .dir_full;

        // A unique alias: no file may match it by long or 8.3 name.
        var alias: [11]u8 = undefined;
        var n: u32 = 1;
        while (true) : (n += 1) {
            if (n > w.geo.root_entries + 1) return .dir_full; // unreachable in practice
            aliasFor(file_name, n, &alias);
            var formatted: [12]u8 = undefined;
            if (!w.scanDir(formatAlias(&alias, &formatted), 1).exists) break;
        }

        // Long-name entries, last part first, then the 8.3 entry.
        const lfn_count = count - 1;
        const checksum = names.sfnChecksum(&alias);
        for (0..lfn_count) |k| {
            const seq: u32 = @intCast(lfn_count - k); // on-disk order: highest first
            const e = &w.entries[k];
            @memset(e, 0);
            e[0] = @intCast(seq | if (seq == lfn_count) @as(u32, 0x40) else 0);
            e[11] = ATTR_LFN;
            e[13] = checksum;
            const offsets = [lfn_chars_per_entry]usize{ 1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30 };
            for (offsets, 0..) |off, j| {
                const ci = (seq - 1) * lfn_chars_per_entry + j;
                const ch: u16 = if (ci < file_name.len) file_name[ci] else if (ci == file_name.len) 0 else 0xFFFF;
                e[off] = @truncate(ch);
                e[off + 1] = @truncate(ch >> 8);
            }
        }
        const sfn = &w.entries[lfn_count];
        @memset(sfn, 0);
        @memcpy(sfn[0..11], &alias);
        sfn[11] = ATTR_ARCHIVE;
        wr16(sfn, 14, fat_time);
        wr16(sfn, 16, fat_date);
        wr16(sfn, 18, fat_date);
        wr16(sfn, 22, fat_time);
        wr16(sfn, 24, fat_date);
        wr16(sfn, 26, w.first_cluster);
        wr32(sfn, 28, w.size);

        w.commit.run_start = run_start;
        w.commit.entry_count = count;
        w.commit.run_len = count;
        // Placed at or past the end marker: the entry after the file must
        // read as the end of the directory.
        const after = run_start + count;
        if (after < w.geo.root_entries and dir.end_index <= run_start + count - 1) {
            w.readDirEntry(after, &w.cache);
            if (w.cache[0] != 0) w.commit.run_len = count + 1;
        }
        return .ok;
    }

    /// The LBA of the next sector commit writes, advancing past FAT sectors
    /// the file doesn't touch; null when all are written.
    fn nextCommitSector(w: *Writer) ?u32 {
        const g = &w.geo;
        while (w.commit.phase == .fat) {
            if (w.commit.sec >= g.fat_sectors) {
                w.commit.fat_copy += 1;
                w.commit.sec = 0;
                if (w.commit.fat_copy >= g.num_fats) {
                    w.commit.phase = .dir;
                    w.commit.sec = (w.commit.run_start * 32) / sector_size;
                    break;
                }
                continue;
            }
            if (w.fatSectorTouched(w.commit.sec)) return g.fat_start + w.commit.fat_copy * g.fat_sectors + w.commit.sec;
            w.commit.sec += 1;
        }
        const last = ((w.commit.run_start + w.commit.run_len) * 32 - 1) / sector_size;
        if (w.commit.sec > last) return null;
        return g.root_start + w.commit.sec;
    }

    /// Clusters whose 12-bit entries may have a byte in FAT sector s.
    fn fatClusterRange(w: *const Writer, s: u32) struct { lo: u32, hi: u32 } {
        const lo_byte = s * sector_size;
        const lo = @max(2, (lo_byte * 2) / 3 -| 1);
        const hi = @min(w.geo.clusters + 1, ((lo_byte + sector_size) * 2) / 3 + 1);
        return .{ .lo = lo, .hi = hi };
    }

    fn fatSectorTouched(w: *const Writer, s: u32) bool {
        if (w.cluster_count == 0) return false;
        const r = w.fatClusterRange(s);
        var c = r.lo;
        while (c <= r.hi) : (c += 1) {
            if (!getBit(&w.reserved, c)) continue;
            const off = c + c / 2;
            if (off / sector_size == s or (off + 1) / sector_size == s) return true;
        }
        return false;
    }

    /// Write the file's chain into FAT sector s (in w.sector).
    fn patchFatSector(w: *Writer, s: u32) void {
        const r = w.fatClusterRange(s);
        const base = s * sector_size;
        var c = r.lo;
        while (c <= r.hi) : (c += 1) {
            if (!getBit(&w.reserved, c)) continue;
            const v: u16 = if (w.nextReserved(@intCast(c))) |next| next else FAT12_EOC;
            const off = c + c / 2;
            const lo_new: u8, const lo_mask: u8, const hi_new: u8, const hi_mask: u8 = if (c & 1 == 0)
                .{ @truncate(v), 0x00, @truncate(v >> 8), 0xF0 }
            else
                .{ @truncate(v << 4), 0x0F, @truncate(v >> 4), 0x00 };
            if (off >= base and off < base + sector_size) {
                const i = off - base;
                w.sector[i] = (w.sector[i] & lo_mask) | lo_new;
            }
            if (off + 1 >= base and off + 1 < base + sector_size) {
                const i = off + 1 - base;
                w.sector[i] = (w.sector[i] & hi_mask) | hi_new;
            }
        }
    }

    /// Put the file's entries (and the end marker, if needed) into root
    /// directory sector s (in w.sector).
    fn patchDirSector(w: *Writer, s: u32) void {
        const first = s * entries_per_sector;
        var i: u32 = 0;
        while (i < entries_per_sector) : (i += 1) {
            const idx = first + i;
            if (idx < w.commit.run_start or idx >= w.commit.run_start + w.commit.run_len) continue;
            const k = idx - w.commit.run_start;
            const dst = w.sector[i * 32 ..][0..32];
            if (k < w.commit.entry_count) dst.* = w.entries[k] else @memset(dst, 0);
        }
    }

    // ── helpers ────────────────────────────────────────────────────────────

    fn put(w: *Writer, lba: u32, buf: *const [sector_size]u8) void {
        std.debug.assert(w.step_n < sectors_per_block);
        w.step_lba[w.step_n] = lba;
        w.step_crc[w.step_n] = std.hash.Crc32.hash(buf);
        w.step_n += 1;
        if (w.cache_lba == lba) w.cache_lba = null;
        w.disk.write(w.disk.ctx, lba, buf);
    }

    /// Flush the step's block and read every sector it wrote back.
    fn flushAndVerify(w: *Writer) bool {
        w.disk.flush(w.disk.ctx);
        w.cache_lba = null;
        for (w.step_lba[0..w.step_n], w.step_crc[0..w.step_n]) |lba, crc| {
            w.disk.read(w.disk.ctx, lba, &w.cache);
            if (std.hash.Crc32.hash(&w.cache) != crc) return false;
        }
        w.step_n = 0;
        return true;
    }

    fn readCached(w: *Writer, lba: u32) *const [sector_size]u8 {
        if (w.cache_lba != lba) {
            w.disk.read(w.disk.ctx, lba, &w.cache);
            w.cache_lba = lba;
        }
        return &w.cache;
    }

    /// FAT 1 entry of cluster c.
    fn fatGet(w: *Writer, c: u32) u16 {
        const off = c + c / 2;
        const lba = w.geo.fat_start + off / sector_size;
        const i = off % sector_size;
        const b0 = w.readCached(lba)[i];
        const b1 = if (i + 1 < sector_size) w.readCached(lba)[i + 1] else w.readCached(lba + 1)[0];
        const pair = @as(u16, b0) | (@as(u16, b1) << 8);
        return if (c & 1 == 0) pair & 0xFFF else pair >> 4;
    }

    fn nextReserved(w: *const Writer, c: u32) ?u16 {
        var n = c + 1;
        const end = w.geo.clusters + 2;
        while (n < end) {
            if (n % 8 == 0 and w.reserved[n / 8] == 0) {
                n += 8;
                continue;
            }
            if (getBit(&w.reserved, n)) return @intCast(n);
            n += 1;
        }
        return null;
    }

    fn readDirEntry(w: *Writer, idx: u32, out: *[sector_size]u8) void {
        if (out == &w.cache) w.cache_lba = null;
        w.disk.read(w.disk.ctx, w.geo.root_start + (idx * 32) / sector_size, out);
        const at = (idx * 32) % sector_size;
        std.mem.copyForwards(u8, out[0..32], out[at..][0..32]);
    }

    const DirInfo = struct {
        /// A file or directory matches the name (long or 8.3, see fat_names).
        exists: bool = false,
        /// Free entries (deleted, or at/after the end marker).
        free_total: u32 = 0,
        /// First run of `need` free entries.
        run_start: ?u32 = null,
        /// Index of the end-of-directory marker (root_entries if none).
        end_index: u32,
    };

    fn scanDir(w: *Writer, file_name: []const u8, need: u32) DirInfo {
        const g = &w.geo;
        var info: DirInfo = .{ .end_index = g.root_entries };
        var run_len: u32 = 0;
        var run_from: u32 = 0;
        var ended = false;
        var cur: u1 = 0;
        var sec: u32 = 0;
        while (sec < g.root_sectors) : (sec += 1) {
            const buf = &w.dir_bufs[cur];
            const prev = &w.dir_bufs[cur ^ 1];
            w.disk.read(w.disk.ctx, g.root_start + sec, buf);
            var e: u32 = 0;
            while (e < entries_per_sector) : (e += 1) {
                const idx = sec * entries_per_sector + e;
                const entry = buf[e * 32 ..][0..32];
                if (!ended and entry[0] == 0) {
                    ended = true;
                    info.end_index = idx;
                }
                if (ended or entry[0] == 0xE5) {
                    if (run_len == 0) run_from = idx;
                    run_len += 1;
                    info.free_total += 1;
                    if (run_len >= need and info.run_start == null) info.run_start = run_from;
                    continue;
                }
                run_len = 0;
                const attr = entry[11];
                if (attr == ATTR_LFN or attr & ATTR_VOLUME != 0) continue;
                if (file_name.len == 0 or info.exists) continue;
                const lfn_len = names.readLfnEntriesMultiSector(if (sec > 0) prev else null, buf, e * 32, &w.lfn);
                if (names.nameMatches(entry, w.lfn[0..lfn_len], file_name)) info.exists = true;
            }
            cur ^= 1;
        }
        return info;
    }
};

fn getBit(bits: []const u8, i: u32) bool {
    return bits[i / 8] & (@as(u8, 1) << @intCast(i % 8)) != 0;
}

fn setBit(bits: []u8, i: u32) void {
    bits[i / 8] |= @as(u8, 1) << @intCast(i % 8);
}

fn rd16(b: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, b[off..][0..2], .little);
}

fn rd32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}

fn wr16(b: []u8, off: usize, v: u16) void {
    std.mem.writeInt(u16, b[off..][0..2], v, .little);
}

fn wr32(b: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, b[off..][0..4], v, .little);
}
