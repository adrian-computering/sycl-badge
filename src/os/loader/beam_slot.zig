//! The received-cart slot (fork/CART_TRANSFER.md, slot format v1).
//!
//! A transfer cart writes a cart's RAM image into the external flash's
//! cart-writable area: a 96-byte header in the first 4 KB sector, the image
//! from 4 KB on. storage.listCarts() lists a valid slot after both drives and
//! the loader launches it through loadSlot().
//!
//! Everything above "Badge glue" is plain code over byte slices and a
//! `Memory` description, so host tests (tests/beam_slot_test.zig) run it
//! against a RAM buffer; the badge glue maps it onto the real chip and cart
//! RAM.
const std = @import("std");
const abi = @import("../cart/os_abi.zig");

pub const magic: u32 = 0x4D414542; // "BEAM" in memory
pub const format_version: u16 = 1;
pub const header_size: u16 = 96;
/// The image starts at this offset in the cart area (the header's sector).
pub const image_offset: u32 = 4096;
pub const name_max: u8 = 47;

/// CartEntry.volume / CartInfo.volume of the slot. Never a real volume
/// index (there are at most 2).
pub const volume_id: u8 = 0xBE;

/// What the menu shows in front of the header's name, so a received cart
/// stands out from the files on the drives.
pub const name_mark = "*";
/// Longest listed name: mark + header name.
pub const listed_name_max = name_mark.len + name_max;

/// Size of a v1 cart descriptor (magic, version, bss_start, bss_end,
/// entry_point; 32-bit words on the badge).
pub const descriptor_v1_size: u32 = 20;

// Header field offsets (CART_TRANSFER.md, "Header").
const off_magic = 0;
const off_version = 4;
const off_header_size = 6;
const off_load_addr = 8;
const off_image_len = 12;
const off_image_crc32 = 16;
const off_descriptor_offset = 20;
const off_source_size = 24;
const off_sender_id = 28;
const off_name_len = 32;
const off_name = 36;
const name_field_len = 48;
const off_header_crc32 = 92;

pub const Header = struct {
    load_addr: u32,
    image_len: u32,
    image_crc32: u32,
    descriptor_offset: u32,
    source_size: u32,
    sender_id: u32,
    name_len: u8,
    name_buf: [name_field_len]u8,

    pub fn name(h: *const Header) []const u8 {
        return h.name_buf[0..h.name_len];
    }

    /// The name the menu lists: name_mark ++ name.
    pub fn listedName(h: *const Header, buf: *[listed_name_max]u8) []const u8 {
        @memcpy(buf[0..name_mark.len], name_mark);
        @memcpy(buf[name_mark.len..][0..h.name_len], h.name());
        return buf[0 .. name_mark.len + h.name_len];
    }
};

pub const HeaderError = error{
    BadMagic,
    BadVersion,
    BadHeaderSize,
    BadHeaderCrc,
    BadName,
    ImageTooLong,
    OutsideCartRam,
    BadDescriptorOffset,
};

/// An address range [start, end): cart RAM (the bounds the UF2 loader applies
/// to each block) or the cart_xip region.
pub const Region = struct {
    start: u32,
    end: u32,
};

fn readU16(b: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, b[off..][0..2], .little);
}

fn readU32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}

pub fn crc32(bytes: []const u8) u32 {
    return std.hash.Crc32.hash(bytes);
}

/// Parse and check a slot header: the "valid slot" rule, which is all the
/// menu checks. `area_size` is the size of the cart-writable area; `image`
/// is where an image may lie: cart RAM above the IPC block, so a slot can
/// never write into the block the OS shares with the cart.
pub fn parseHeader(bytes: *const [header_size]u8, area_size: u32, image: Region) HeaderError!Header {
    if (readU32(bytes, off_magic) != magic) return error.BadMagic;
    if (readU16(bytes, off_version) != format_version) return error.BadVersion;
    if (readU16(bytes, off_header_size) != header_size) return error.BadHeaderSize;
    if (readU32(bytes, off_header_crc32) != crc32(bytes[0..off_header_crc32])) return error.BadHeaderCrc;

    var h: Header = .{
        .load_addr = readU32(bytes, off_load_addr),
        .image_len = readU32(bytes, off_image_len),
        .image_crc32 = readU32(bytes, off_image_crc32),
        .descriptor_offset = readU32(bytes, off_descriptor_offset),
        .source_size = readU32(bytes, off_source_size),
        .sender_id = readU32(bytes, off_sender_id),
        .name_len = bytes[off_name_len],
        .name_buf = bytes[off_name..][0..name_field_len].*,
    };

    if (h.name_len == 0 or h.name_len > name_max) return error.BadName;
    for (h.name()) |c| if (c < 0x20 or c > 0x7E) return error.BadName;

    if (area_size < image_offset or h.image_len > area_size - image_offset) return error.ImageTooLong;

    const image_end = @as(u64, h.load_addr) + h.image_len;
    if (h.load_addr < image.start or image_end > image.end) return error.OutsideCartRam;

    if (h.descriptor_offset % 4 != 0 or
        @as(u64, h.descriptor_offset) + descriptor_v1_size > h.image_len)
        return error.BadDescriptorOffset;

    // Zero the unused tail so two equal headers compare equal.
    @memset(h.name_buf[h.name_len..], 0);
    return h;
}

/// Errors are a subset of loader.LoadError, so the menu and console report
/// them with their existing messages: a slot that stopped being valid is
/// "not found", a bad image CRC is a read error.
pub const LoadError = error{ FileNotFound, ReadError, AddressMismatch, VersionMismatch };

/// Where a cart may live, and the bytes backing its RAM. On the badge `ram`
/// is cart RAM itself; host tests pass a buffer standing in for it.
pub const Memory = struct {
    ram: Region,
    /// End of the IPC block at the start of cart RAM: the lowest address an
    /// image may start at (the descriptor checks still use `ram`, as the UF2
    /// loader does).
    ipc_end: u32,
    /// cart_xip region: a v1 entry point may also lie there.
    xip: Region,
    /// Bytes of [ram.start, ram.end).
    bytes: []u8,

    pub fn imageRegion(mem: Memory) Region {
        return .{ .start = mem.ipc_end, .end = mem.ram.end };
    }
};

/// Offset in a UF2 payload of the first CART_MAGIC word, 4-aligned: how the
/// UF2 loader finds a RAM cart's descriptor (shared, so both agree).
pub fn findDescriptor(payload: []align(4) const u8) ?usize {
    const words = std.mem.bytesAsSlice(u32, payload[0..std.mem.alignBackward(usize, payload.len, @alignOf(u32))]);
    const index = std.mem.indexOfScalar(u32, words, abi.CART_MAGIC) orelse return null;
    return index * @sizeOf(u32);
}

/// The UF2 loader's v1 descriptor rule (shared): BSS inside cart RAM, entry
/// point in cart RAM or cart_xip, thumb bit set.
pub fn checkDescriptorV1(bss_start: u32, bss_end: u32, entry_point: u32, ram: Region, xip: Region) error{AddressMismatch}!void {
    const ram_start = ram.start;
    const ram_end = ram.end;
    if (bss_start < ram_start or bss_start > ram_end or
        bss_end < ram_start or bss_end > ram_end or
        bss_start > bss_end or
        !(entry_point >= ram_start and entry_point < ram_end or
            entry_point >= xip.start and entry_point < xip.end) or
        entry_point & 1 == 0) // entry_point must be thumb
    {
        return error.AddressMismatch;
    }
}

/// Load a slot into `mem`: copy the image to load_addr, check its CRC over
/// the copy (what will run), check the descriptor, clear BSS. `slot` is the
/// whole cart area (header at 0, image at image_offset). Returns the
/// descriptor's offset from mem.ram.start (CartExecute.offset for a RAM
/// cart). Nothing may run the image if this fails.
pub fn loadInto(slot: []const u8, mem: Memory) LoadError!u32 {
    if (slot.len < image_offset) return error.FileNotFound;
    const h = parseHeader(slot[0..header_size], @intCast(@min(slot.len, std.math.maxInt(u32))), mem.imageRegion()) catch
        return error.FileNotFound;

    const image = slot[image_offset..][0..h.image_len];
    const dst_off = h.load_addr - mem.ram.start;
    const dst = mem.bytes[dst_off..][0..h.image_len];
    @memcpy(dst, image);
    if (crc32(dst) != h.image_crc32) return error.ReadError;

    const desc = dst[h.descriptor_offset..][0..descriptor_v1_size];
    if (readU32(desc, 0) != abi.CART_MAGIC) return error.AddressMismatch;
    switch (readU32(desc, 4)) {
        abi.CART_VERSION_V1 => {
            const bss_start = readU32(desc, 8);
            const bss_end = readU32(desc, 12);
            try checkDescriptorV1(bss_start, bss_end, readU32(desc, 16), mem.ram, mem.xip);
            @memset(mem.bytes[bss_start - mem.ram.start .. bss_end - mem.ram.start], 0);
        },
        else => return error.VersionMismatch,
    }
    return dst_off + h.descriptor_offset;
}

// ---------------------------------------------------------------------------
// Badge glue (only analyzed when the kernel calls it)

/// The cart-writable area through the cached XIP window, or null with no
/// external flash. The cart's writes go through the bootrom, which flushes
/// the whole XIP cache after each erase/program, so cached reads are fresh.
pub fn slotArea() ?[]const u8 {
    const ext_flash = @import("../drivers/ext_flash.zig");
    const chip = ext_flash.bytes() orelse return null;
    const offset = ext_flash.cartAreaOffset();
    if (offset >= chip.len) return null;
    return chip[offset..];
}

fn badgeRam() Region {
    const loader = @import("loader.zig");
    return .{ .start = loader.getCartRamStart(), .end = loader.getCartRamEnd() };
}

/// End of the cart IPC block (0x20035100), the lowest address an image may use.
fn badgeIpcEnd() u32 {
    return @intFromPtr(abi.ipc_data) + @sizeOf(abi.CartIPCData);
}

/// The slot's header if the slot is valid (cheap: header checks only).
pub fn validHeader() ?Header {
    const area = slotArea() orelse return null;
    if (area.len < image_offset) return null;
    return parseHeader(area[0..header_size], @intCast(area.len), .{ .start = badgeIpcEnd(), .end = badgeRam().end }) catch null;
}

/// Load the slot into cart RAM (core 1 must be stopped). Same result as the
/// UF2 loader for a RAM cart.
pub fn loadSlot() LoadError!@import("../ipc/mailbox.zig").MessageType.CartExecute {
    const loader = @import("loader.zig");
    const area = slotArea() orelse return error.FileNotFound;
    const ram = badgeRam();
    const offset = try loadInto(area, .{
        .ram = ram,
        .ipc_end = badgeIpcEnd(),
        .xip = .{ .start = loader.getCartXipStart(), .end = loader.getCartXipEnd() },
        .bytes = @as([*]u8, @ptrFromInt(ram.start))[0 .. ram.end - ram.start],
    });
    // Flush the store pipe before core 1 runs it, as the UF2 loader does.
    asm volatile ("dmb" ::: .{ .memory = true });
    return .{ .xip = false, .offset = @intCast(offset) };
}
