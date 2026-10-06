//! FAT directory name helpers shared by storage.zig (menu, console, delete)
//! and fat_write.zig (cart files), so every path agrees on what a name
//! matches. Pure: no flash access, host-tested.
const std = @import("std");

pub const SECTOR_SIZE: usize = 512;
pub const DIR_ENTRY_SIZE: usize = 32;
pub const DIR_NAME: usize = 0;
pub const DIR_EXT: usize = 8;
pub const DIR_ATTR: usize = 11;

/// The lookup rule of storage.findCart/deleteCart: `name` matches a file if it
/// equals its long name (ASCII case-insensitive), or if normalizeName(name)
/// equals its 8.3 name. `lfn` is the long name read by
/// readLfnEntriesMultiSector (empty when the file has none).
pub fn nameMatches(entry: []const u8, lfn: []const u8, name: []const u8) bool {
    if (lfn.len > 0 and std.ascii.eqlIgnoreCase(lfn, name)) return true;
    var target: [12]u8 = undefined;
    const target_len = normalizeName(name, &target);
    var name_buf: [12:0]u8 = undefined;
    return std.mem.eql(u8, formatShortName(entry, &name_buf), target[0..target_len]);
}

/// Get Unicode chars from LFN entry (little UTF-16)
pub fn getLfnChar(entry: []const u8, offset: usize) u16 {
    return @as(u16, entry[offset]) | (@as(u16, entry[offset + 1]) << 8);
}

/// Calc checksum for SFN
pub fn sfnChecksum(sfn: []const u8) u8 {
    var sum: u8 = 0;
    for (0..11) |i| {
        sum = ((sum & 1) << 7) +% (sum >> 1) +% sfn[i];
    }
    return sum;
}

/// Read LFN entries that span across two sectors
/// prev_sector: prev sector buffer (null if first sector)
/// curr_sector: curr sector buffer
/// start_idx: SFN entry idx in curr sector
/// out: output buffer for reconstructed flname
pub fn readLfnEntriesMultiSector(prev_sector: ?*const [SECTOR_SIZE]u8, curr_sector: []const u8, start_idx: usize, out: []u8) usize {
    // SFN entry to get checksum from
    const sfn_entry = curr_sector[start_idx .. start_idx + DIR_ENTRY_SIZE];
    const expected_checksum = sfnChecksum(sfn_entry[DIR_NAME .. DIR_NAME + 11]);

    var lfn_chars: [256]u16 = undefined;
    var total_chars: usize = 0;
    var found_first = false;

    // Scan backwards in curr sector
    if (start_idx > 0) {
        var pos: isize = @as(isize, @intCast(start_idx)) - @as(isize, DIR_ENTRY_SIZE);
        while (pos >= 0) : (pos -= DIR_ENTRY_SIZE) {
            const idx: usize = @intCast(pos);
            const entry = curr_sector[idx .. idx + DIR_ENTRY_SIZE];

            // Stop if not an LFN entry
            if (entry[DIR_ATTR] != 0x0F) break;
            if (entry[0] == 0xE5) break; // Deleted

            // Check checksum matches
            if (entry[13] != expected_checksum) break;

            // Extract chars from this entry (13 chars per LFN entry)
            // Chars 1-5: bytes 1-10
            for (0..5) |i| {
                const c = getLfnChar(entry, 1 + i * 2);
                if (c != 0 and c != 0xFFFF and total_chars < lfn_chars.len) {
                    lfn_chars[total_chars] = c;
                    total_chars += 1;
                } else if (c == 0) break;
            }
            // Chars 6-11: bytes 14-25
            for (0..6) |i| {
                const c = getLfnChar(entry, 14 + i * 2);
                if (c != 0 and c != 0xFFFF and total_chars < lfn_chars.len) {
                    lfn_chars[total_chars] = c;
                    total_chars += 1;
                } else if (c == 0) break;
            }
            // Chars 12-13: bytes 28-31
            for (0..2) |i| {
                const c = getLfnChar(entry, 28 + i * 2);
                if (c != 0 and c != 0xFFFF and total_chars < lfn_chars.len) {
                    lfn_chars[total_chars] = c;
                    total_chars += 1;
                } else if (c == 0) break;
            }

            // Check if first (last in seq) entry
            const seq = entry[0];
            if ((seq & 0x40) != 0) {
                found_first = true;
                break;
            }
        }
    }

    if (!found_first and prev_sector != null and (start_idx == 0 or total_chars > 0)) {
        var pos: isize = SECTOR_SIZE - DIR_ENTRY_SIZE;
        while (pos >= 0) : (pos -= DIR_ENTRY_SIZE) {
            const idx: usize = @intCast(pos);
            const entry = prev_sector.?[idx .. idx + DIR_ENTRY_SIZE];

            if (entry[DIR_ATTR] != 0x0F) break;
            if (entry[0] == 0xE5) break;
            if (entry[13] != expected_checksum) break;

            // Extract chars
            for (0..5) |i| {
                const c = getLfnChar(entry, 1 + i * 2);
                if (c != 0 and c != 0xFFFF and total_chars < lfn_chars.len) {
                    lfn_chars[total_chars] = c;
                    total_chars += 1;
                } else if (c == 0) break;
            }
            for (0..6) |i| {
                const c = getLfnChar(entry, 14 + i * 2);
                if (c != 0 and c != 0xFFFF and total_chars < lfn_chars.len) {
                    lfn_chars[total_chars] = c;
                    total_chars += 1;
                } else if (c == 0) break;
            }
            for (0..2) |i| {
                const c = getLfnChar(entry, 28 + i * 2);
                if (c != 0 and c != 0xFFFF and total_chars < lfn_chars.len) {
                    lfn_chars[total_chars] = c;
                    total_chars += 1;
                } else if (c == 0) break;
            }

            if ((entry[0] & 0x40) != 0) {
                found_first = true;
                break;
            }
        }
    }

    // If found complete LFN chain, convert to ASCII
    if (found_first and total_chars > 0) {
        var out_idx: usize = 0;
        for (0..total_chars) |i| {
            const c = lfn_chars[i];
            if (c < 0x80 and out_idx < out.len) {
                out[out_idx] = @truncate(c);
                out_idx += 1;
            }
        }
        return out_idx;
    }

    return 0;
}

/// "NAME    EXT" -> "NAME.EXT" (up to 12 characters; the copy in storage.zig
/// took an [11:0] buffer and wrote one past it for full 8.3 names).
pub fn formatShortName(entry: []const u8, buf: *[12:0]u8) []const u8 {
    var idx: usize = 0;
    while (idx < 8 and entry[DIR_NAME + idx] != ' ') : (idx += 1) {
        buf[idx] = entry[DIR_NAME + idx];
    }
    if (entry[DIR_EXT] != ' ') {
        buf[idx] = '.';
        idx += 1;
        var j: usize = 0;
        while (j < 3 and entry[DIR_EXT + j] != ' ') : (j += 1) {
            buf[idx] = entry[DIR_EXT + j];
            idx += 1;
        }
    }
    buf[idx] = 0;
    return buf[0..idx];
}

pub fn normalizeName(name: []const u8, out: *[12]u8) usize {
    var i: usize = 0;
    var dot: ?usize = null;
    while (i < name.len) : (i += 1) {
        if (name[i] == '.') {
            dot = i;
            break;
        }
    }
    var out_idx: usize = 0;
    const base_end = dot orelse name.len;
    var bi: usize = 0;
    while (bi < base_end and out_idx < 8) : (bi += 1) {
        const ch = name[bi];
        out[out_idx] = std.ascii.toUpper(ch);
        out_idx += 1;
    }
    if (dot != null) {
        out[out_idx] = '.';
        out_idx += 1;
        var ei: usize = dot.? + 1;
        var ext_len: usize = 0;
        while (ei < name.len and ext_len < 3) : ({
            ei += 1;
            ext_len += 1;
        }) {
            out[out_idx] = std.ascii.toUpper(name[ei]);
            out_idx += 1;
        }
    }
    // A full 8.3 name fills all 12 bytes: no room for the terminator (the
    // copy in storage.zig wrote out[12], one past the end).
    if (out_idx < out.len) out[out_idx] = 0;
    return out_idx;
}
