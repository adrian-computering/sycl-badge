//! Host tests for the received-cart slot (loader/beam_slot.zig) against the
//! slot format v1 contract in fork/CART_TRANSFER.md.
//!
//! Headers here are built from the spec's table with literal offsets, not
//! from beam_slot's constants, so a drift between the two shows up.
//!
//! Optional fixtures in src/os/tests/fixtures/ (tests skip without them):
//! - snouty-pong.uf2: a real RAM cart UF2;
//! - beam_slot_pong.bin: the slot (header sector + image) the monorepo's
//!   flattener makes from that same UF2.
const std = @import("std");
const testing = std.testing;
const beam_slot = @import("../loader/beam_slot.zig");
const uf2 = @import("../loader/uf2.zig");
const test_options = @import("test_options");

const CART_MAGIC: u32 = 0x54C1_CA41;
const CART_VERSION_V1: u32 = 0x54C126_01;

// The badge's memory map (src/os/linker.ld).
const ram: beam_slot.Region = .{ .start = 0x20020000, .end = 0x20080000 };
const xip: beam_slot.Region = .{ .start = 0x101C0000, .end = 0x10200000 };
/// 0x20020000 + @sizeOf(CartIPCData) on the badge (os_abi.zig asserts the
/// size; the host can't take it, CartIPCData holds a pointer). A slot image
/// may start no lower.
const ipc_end: u32 = 0x20035100;
const image_region: beam_slot.Region = .{ .start = ipc_end, .end = ram.end };
const area_size: u32 = 256 * 1024;

const Fields = struct {
    magic: u32 = 0x4D414542,
    version: u16 = 1,
    header_size: u16 = 96,
    load_addr: u32 = 0x20035100,
    image_len: u32 = 0x1000,
    image_crc32: u32 = 0,
    descriptor_offset: u32 = 0,
    source_size: u32 = 0x2400,
    sender_id: u32 = 0,
    name: []const u8 = "snouty-pong",
    name_len: ?u8 = null, // null = name.len
    fix_crc: bool = true,
};

/// The 96-byte header, by hand from the spec table.
fn makeHeader(f: Fields) [96]u8 {
    var h: [96]u8 = @splat(0);
    std.mem.writeInt(u32, h[0..4], f.magic, .little);
    std.mem.writeInt(u16, h[4..6], f.version, .little);
    std.mem.writeInt(u16, h[6..8], f.header_size, .little);
    std.mem.writeInt(u32, h[8..12], f.load_addr, .little);
    std.mem.writeInt(u32, h[12..16], f.image_len, .little);
    std.mem.writeInt(u32, h[16..20], f.image_crc32, .little);
    std.mem.writeInt(u32, h[20..24], f.descriptor_offset, .little);
    std.mem.writeInt(u32, h[24..28], f.source_size, .little);
    std.mem.writeInt(u32, h[28..32], f.sender_id, .little);
    h[32] = f.name_len orelse @intCast(f.name.len);
    @memcpy(h[36..][0..f.name.len], f.name);
    if (f.fix_crc) std.mem.writeInt(u32, h[92..96], std.hash.Crc32.hash(h[0..92]), .little);
    return h;
}

fn parse(h: [96]u8) beam_slot.HeaderError!beam_slot.Header {
    return beam_slot.parseHeader(&h, area_size, image_region);
}

test "crc32 is zlib's" {
    try testing.expectEqual(@as(u32, 0xCBF43926), beam_slot.crc32("123456789"));
}

test "golden header bytes parse" {
    const golden = makeHeader(.{
        .load_addr = 0x20035100,
        .image_len = 0x0000B000,
        .image_crc32 = 0xDEADBEEF,
        .descriptor_offset = 0x10,
        .source_size = 0x16000,
        .sender_id = 0x12345678,
        .name = "Snouty Pong",
    });
    // Spot-check the encoding against the table: "BEAM" in memory, LE fields.
    try testing.expectEqualSlices(u8, "BEAM", golden[0..4]);
    try testing.expectEqualSlices(u8, &.{ 1, 0, 96, 0 }, golden[4..8]);
    try testing.expectEqualSlices(u8, &.{ 0x00, 0x51, 0x03, 0x20 }, golden[8..12]);
    try testing.expectEqual(@as(u8, 11), golden[32]);
    try testing.expectEqualSlices(u8, "Snouty Pong", golden[36..47]);

    const h = try parse(golden);
    try testing.expectEqual(@as(u32, 0x20035100), h.load_addr);
    try testing.expectEqual(@as(u32, 0xB000), h.image_len);
    try testing.expectEqual(@as(u32, 0xDEADBEEF), h.image_crc32);
    try testing.expectEqual(@as(u32, 0x10), h.descriptor_offset);
    try testing.expectEqual(@as(u32, 0x16000), h.source_size);
    try testing.expectEqual(@as(u32, 0x12345678), h.sender_id);
    try testing.expectEqualStrings("Snouty Pong", h.name());
    var buf: [beam_slot.listed_name_max]u8 = undefined;
    try testing.expectEqualStrings("*Snouty Pong", h.listedName(&buf));

    // Reserved bytes are not checked (room for later versions).
    var with_reserved = golden;
    with_reserved[33] = 1;
    with_reserved[84] = 1;
    std.mem.writeInt(u32, with_reserved[92..96], std.hash.Crc32.hash(with_reserved[0..92]), .little);
    _ = try parse(with_reserved);
}

const x48: [48]u8 = @splat('x');

test "each validity rule refuses its broken field" {
    const E = beam_slot.HeaderError;
    _ = try parse(makeHeader(.{}));

    try testing.expectError(E.BadMagic, parse(makeHeader(.{ .magic = 0x4D414543 })));
    try testing.expectError(E.BadVersion, parse(makeHeader(.{ .version = 2 })));
    try testing.expectError(E.BadHeaderSize, parse(makeHeader(.{ .header_size = 92 })));
    var bad_crc = makeHeader(.{});
    bad_crc[92] ^= 1;
    try testing.expectError(E.BadHeaderCrc, parse(bad_crc));
    var flipped = makeHeader(.{});
    flipped[40] ^= 0x20; // a name byte, CRC not updated
    try testing.expectError(E.BadHeaderCrc, parse(flipped));
    // An erased header sector (step 1 of the write order).
    try testing.expectError(E.BadMagic, parse(@splat(0xFF)));

    try testing.expectError(E.BadName, parse(makeHeader(.{ .name_len = 0 })));
    try testing.expectError(E.BadName, parse(makeHeader(.{ .name = &x48 })));
    _ = try parse(makeHeader(.{ .name = x48[0..47] }));
    try testing.expectError(E.BadName, parse(makeHeader(.{ .name = "a\x01b" })));
    try testing.expectError(E.BadName, parse(makeHeader(.{ .name = "a\x7Fb" })));

    // image_len at most area size - 4096.
    _ = try parse(makeHeader(.{ .load_addr = ipc_end, .image_len = area_size - 4096 }));
    try testing.expectError(E.ImageTooLong, parse(makeHeader(.{ .load_addr = ipc_end, .image_len = area_size - 4095 })));

    // load_addr and load_addr + image_len inside cart RAM above the IPC block.
    _ = try parse(makeHeader(.{ .load_addr = ipc_end }));
    try testing.expectError(E.OutsideCartRam, parse(makeHeader(.{ .load_addr = ipc_end - 4 })));
    try testing.expectError(E.OutsideCartRam, parse(makeHeader(.{ .load_addr = 0x20030000 })));
    try testing.expectError(E.OutsideCartRam, parse(makeHeader(.{ .load_addr = ram.start })));
    try testing.expectError(E.OutsideCartRam, parse(makeHeader(.{ .load_addr = ram.start - 4 })));
    try testing.expectError(E.OutsideCartRam, parse(makeHeader(.{ .load_addr = 0x101C0000 })));
    _ = try parse(makeHeader(.{ .load_addr = ram.end - 0x1000, .image_len = 0x1000 }));
    try testing.expectError(E.OutsideCartRam, parse(makeHeader(.{ .load_addr = ram.end - 0x1000 + 4, .image_len = 0x1000 })));
    try testing.expectError(E.OutsideCartRam, parse(makeHeader(.{ .load_addr = 0xFFFFF000, .image_len = 0x2000 })));

    // Descriptor 4-aligned and inside the image (a whole v1 descriptor).
    try testing.expectError(E.BadDescriptorOffset, parse(makeHeader(.{ .descriptor_offset = 2 })));
    _ = try parse(makeHeader(.{ .descriptor_offset = 0x1000 - 20 }));
    try testing.expectError(E.BadDescriptorOffset, parse(makeHeader(.{ .descriptor_offset = 0x1000 - 16 })));
    try testing.expectError(E.BadDescriptorOffset, parse(makeHeader(.{ .descriptor_offset = 0x1000 })));
    try testing.expectError(E.BadDescriptorOffset, parse(makeHeader(.{ .descriptor_offset = 0xFFFFFFFC })));
}

// ---------------------------------------------------------------------------
// Loading

const fill_pattern: u8 = 0xA5;

const TestRam = struct {
    bytes: []u8,

    fn init(fill: u8) !TestRam {
        const bytes = try testing.allocator.alloc(u8, ram.end - ram.start);
        @memset(bytes, fill);
        return .{ .bytes = bytes };
    }

    fn deinit(t: TestRam) void {
        testing.allocator.free(t.bytes);
    }

    fn memory(t: TestRam) beam_slot.Memory {
        return .{ .ram = ram, .ipc_end = ipc_end, .bytes = t.bytes };
    }

    fn at(t: TestRam, addr: u32, len: usize) []u8 {
        return t.bytes[addr - ram.start ..][0..len];
    }
};

/// A small RAM cart image: descriptor at desc_off, then a counting pattern.
const Cart = struct {
    load_addr: u32 = 0x20035100,
    len: u32 = 0x800,
    desc_off: u32 = 0x40,
    version: u32 = CART_VERSION_V1,
    magic: u32 = CART_MAGIC,
    bss_start: u32 = 0x20035100 + 0x800,
    bss_end: u32 = 0x20035100 + 0x900,
    entry: u32 = 0x20035100 + 0x101,

    fn image(c: Cart, buf: []u8) []u8 {
        const img = buf[0..c.len];
        for (img, 0..) |*b, i| b.* = @truncate(i *% 7 +% 3);
        const d = img[c.desc_off..][0..20];
        std.mem.writeInt(u32, d[0..4], c.magic, .little);
        std.mem.writeInt(u32, d[4..8], c.version, .little);
        std.mem.writeInt(u32, d[8..12], c.bss_start, .little);
        std.mem.writeInt(u32, d[12..16], c.bss_end, .little);
        std.mem.writeInt(u32, d[16..20], c.entry, .little);
        return img;
    }
};

/// A whole cart area (erased) holding a slot for `image`.
fn makeSlot(image: []const u8, load_addr: u32, desc_off: u32) ![]u8 {
    const area = try testing.allocator.alloc(u8, area_size);
    @memset(area, 0xFF);
    const h = makeHeader(.{
        .load_addr = load_addr,
        .image_len = @intCast(image.len),
        .image_crc32 = std.hash.Crc32.hash(image),
        .descriptor_offset = desc_off,
    });
    @memcpy(area[0..96], &h);
    @memcpy(area[4096..][0..image.len], image);
    return area;
}

fn loadCart(c: Cart, t: TestRam) beam_slot.LoadError!u32 {
    var img_buf: [0x1000]u8 = undefined;
    const img = c.image(&img_buf);
    const area = makeSlot(img, c.load_addr, c.desc_off) catch unreachable;
    defer testing.allocator.free(area);
    return beam_slot.loadInto(area, t.memory());
}

test "load copies the image, clears BSS, returns the descriptor offset" {
    const t = try TestRam.init(fill_pattern);
    defer t.deinit();
    const c: Cart = .{};
    const offset = try loadCart(c, t);
    try testing.expectEqual(c.load_addr + c.desc_off - ram.start, offset);

    var img_buf: [0x1000]u8 = undefined;
    try testing.expectEqualSlices(u8, c.image(&img_buf), t.at(c.load_addr, c.len));
    for (t.at(c.bss_start, c.bss_end - c.bss_start)) |b| try testing.expectEqual(@as(u8, 0), b);
    // Nothing else touched.
    for (t.bytes[0 .. c.load_addr - ram.start]) |b| try testing.expectEqual(fill_pattern, b);
    for (t.bytes[c.bss_end - ram.start ..]) |b| try testing.expectEqual(fill_pattern, b);
}

test "load: BSS may be empty" {
    const t = try TestRam.init(fill_pattern);
    defer t.deinit();
    _ = try loadCart(.{ .bss_start = ram.end, .bss_end = ram.end }, t);
}

test "load refuses an entry point in cart_xip (a slot is RAM only)" {
    const t = try TestRam.init(fill_pattern);
    defer t.deinit();
    try testing.expectError(error.AddressMismatch, loadCart(.{ .entry = xip.start + 0x201 }, t));
}

test "load refuses an image whose CRC fails" {
    const t = try TestRam.init(fill_pattern);
    defer t.deinit();
    const c: Cart = .{};
    var img_buf: [0x1000]u8 = undefined;
    const img = c.image(&img_buf);
    const area = try makeSlot(img, c.load_addr, c.desc_off);
    defer testing.allocator.free(area);
    area[4096 + 0x300] ^= 0x01;
    try testing.expectError(error.ReadError, beam_slot.loadInto(area, t.memory()));
    // BSS was not cleared: the descriptor was never acted on.
    for (t.at(c.bss_start, c.bss_end - c.bss_start)) |b| try testing.expectEqual(fill_pattern, b);
}

test "load refuses an invalid header as not found" {
    const t = try TestRam.init(fill_pattern);
    defer t.deinit();
    const c: Cart = .{};
    var img_buf: [0x1000]u8 = undefined;
    const area = try makeSlot(c.image(&img_buf), c.load_addr, c.desc_off);
    defer testing.allocator.free(area);
    area[0] = 0xFF;
    try testing.expectError(error.FileNotFound, beam_slot.loadInto(area, t.memory()));
    try testing.expectError(error.FileNotFound, beam_slot.loadInto(area[0..100], t.memory()));
    for (t.bytes) |b| try testing.expectEqual(fill_pattern, b);
}

test "load refuses a slot whose image starts inside the IPC block" {
    const t = try TestRam.init(fill_pattern);
    defer t.deinit();
    const c: Cart = .{ .load_addr = 0x20030000, .bss_start = 0x20035100, .bss_end = 0x20035200, .entry = 0x20030101 };
    try testing.expectError(error.FileNotFound, loadCart(c, t));
    try testing.expectError(error.FileNotFound, loadCart(.{ .load_addr = ipc_end - 0x100 }, t));
    for (t.bytes) |b| try testing.expectEqual(fill_pattern, b);
}

test "load applies the UF2 loader's v1 descriptor checks" {
    const t = try TestRam.init(fill_pattern);
    defer t.deinit();
    const base: u32 = 0x20035100;
    try testing.expectError(error.AddressMismatch, loadCart(.{ .magic = 0x12345678 }, t));
    try testing.expectError(error.VersionMismatch, loadCart(.{ .version = 0x54C12602 }, t));
    try testing.expectError(error.AddressMismatch, loadCart(.{ .bss_start = ram.start - 4 }, t));
    try testing.expectError(error.AddressMismatch, loadCart(.{ .bss_end = ram.end + 4 }, t));
    try testing.expectError(error.AddressMismatch, loadCart(.{ .bss_start = base + 0x900, .bss_end = base + 0x800 }, t));
    try testing.expectError(error.AddressMismatch, loadCart(.{ .entry = base + 0x100 }, t)); // no thumb bit
    try testing.expectError(error.AddressMismatch, loadCart(.{ .entry = ram.end + 1 }, t));
    try testing.expectError(error.AddressMismatch, loadCart(.{ .entry = xip.end + 1 }, t));
    try testing.expectError(error.AddressMismatch, loadCart(.{ .entry = 0x10000001 }, t));
}

// ---------------------------------------------------------------------------
// The UF2 path, on the same Memory

const UF2_FAMILY_RP2350_ARM_S: u32 = 0xE48BFF59;

/// A UF2 with one block per payload (target, bytes).
fn makeUf2(payloads: []const struct { u32, []const u8 }) ![]u8 {
    const file = try testing.allocator.alloc(u8, payloads.len * 512);
    @memset(file, 0);
    for (payloads, 0..) |p, i| {
        const blk = file[i * 512 ..][0..512];
        std.mem.writeInt(u32, blk[0..4], uf2.MAGIC_START0, .little);
        std.mem.writeInt(u32, blk[4..8], uf2.MAGIC_START1, .little);
        std.mem.writeInt(u32, blk[8..12], uf2.Flags.FAMILY_ID_PRESENT, .little);
        std.mem.writeInt(u32, blk[12..16], p[0], .little);
        std.mem.writeInt(u32, blk[16..20], @intCast(p[1].len), .little);
        std.mem.writeInt(u32, blk[20..24], @intCast(i), .little);
        std.mem.writeInt(u32, blk[24..28], @intCast(payloads.len), .little);
        std.mem.writeInt(u32, blk[28..32], UF2_FAMILY_RP2350_ARM_S, .little);
        @memcpy(blk[32..][0..p[1].len], p[1]);
        std.mem.writeInt(u32, blk[508..512], uf2.MAGIC_END, .little);
    }
    return file;
}

const Uf2Error = error{ InvalidUF2, UnsupportedFamily, AddressMismatch, VersionMismatch, NotRamCart };

fn block(file: []const u8, i: usize, scratch: *align(4) [512]u8) *align(4) const [512]u8 {
    @memcpy(scratch, file[i * 512 ..][0..512]);
    return scratch;
}

/// loader.loadUF2FromStorage's RAM-cart path over `mem`: the same parser,
/// block bounds, descriptor search, v1 checks and BSS clear.
fn uf2LoadRam(file: []const u8, mem: beam_slot.Memory) Uf2Error!u32 {
    if (file.len % 512 != 0 or file.len == 0) return error.InvalidUF2;
    var parser: uf2.Parser = .{};
    var descriptor: ?u32 = null;
    var scratch: [512]u8 align(4) = undefined;
    for (0..file.len / 512) |i| {
        const blk = parser.parseBlock(block(file, i, &scratch)) catch return error.InvalidUF2;
        if (i == 0 and blk.hasFamilyId() and !blk.isRP235X()) return error.UnsupportedFamily;
        const payload = blk.getPayload();
        if (payload.len == 0) return error.InvalidUF2;
        const target = blk.header.target_addr;
        if (target >= xip.start and target + payload.len < xip.end) return error.NotRamCart;
        if (!(target >= mem.ram.start and target + payload.len <= mem.ram.end)) return error.AddressMismatch;
        if (descriptor == null) {
            if (beam_slot.findDescriptor(payload)) |off| descriptor = target + @as(u32, @intCast(off));
        }
        @memcpy(mem.bytes[target - mem.ram.start ..][0..payload.len], payload);
    }
    if (!parser.isComplete()) return error.InvalidUF2;
    const d_addr = descriptor orelse return error.NotRamCart;
    const d = mem.bytes[d_addr - mem.ram.start ..][0..20];
    if (std.mem.readInt(u32, d[4..8], .little) != CART_VERSION_V1) return error.VersionMismatch;
    const bss_start = std.mem.readInt(u32, d[8..12], .little);
    const bss_end = std.mem.readInt(u32, d[12..16], .little);
    try beam_slot.checkDescriptorV1(bss_start, bss_end, std.mem.readInt(u32, d[16..20], .little), mem.ram, xip);
    @memset(mem.bytes[bss_start - mem.ram.start .. bss_end - mem.ram.start], 0);
    return d_addr - mem.ram.start;
}

const Flat = struct {
    load_addr: u32,
    image: []u8,
    descriptor_offset: u32,

    fn deinit(f: Flat) void {
        testing.allocator.free(f.image);
    }
};

/// The spec's flattening ("The image"), written from CART_TRANSFER.md.
fn flatten(file: []const u8) !Flat {
    var lo: u32 = std.math.maxInt(u32);
    var hi: u32 = 0;
    var descriptor: ?u32 = null;
    var scratch: [512]u8 align(4) = undefined;
    var parser: uf2.Parser = .{};
    for (0..file.len / 512) |i| {
        const blk = try parser.parseBlock(block(file, i, &scratch));
        const payload = blk.getPayload();
        const target = blk.header.target_addr;
        if (target < ram.start or target + payload.len > ram.end) return error.NotTransferable;
        if (target + payload.len <= ipc_end) continue; // ELF headers: dropped
        if (target < ipc_end) return error.NotTransferable; // straddles the IPC end
        lo = @min(lo, target);
        hi = @max(hi, target + @as(u32, @intCast(payload.len)));
        if (descriptor == null) {
            if (beam_slot.findDescriptor(payload)) |off| descriptor = target + @as(u32, @intCast(off));
        }
    }
    const image = try testing.allocator.alloc(u8, hi - lo);
    @memset(image, 0);
    for (0..file.len / 512) |i| {
        const blk = try parser.parseBlock(block(file, i, &scratch));
        const payload = blk.getPayload();
        if (blk.header.target_addr + payload.len <= ipc_end) continue;
        @memcpy(image[blk.header.target_addr - lo ..][0..payload.len], payload);
    }
    return .{ .load_addr = lo, .image = image, .descriptor_offset = (descriptor orelse return error.NoDescriptor) - lo };
}

/// Load `file` both ways into zeroed RAM buffers and check they match above
/// the IPC block (below it the UF2 path also writes the dropped ELF-header
/// blocks, which the OS clears at cart start).
fn expectSlotMatchesUf2(file: []const u8, slot_area: []const u8) !void {
    const via_uf2 = try TestRam.init(0);
    defer via_uf2.deinit();
    const via_slot = try TestRam.init(0);
    defer via_slot.deinit();
    const off_uf2 = try uf2LoadRam(file, via_uf2.memory());
    const off_slot = try beam_slot.loadInto(slot_area, via_slot.memory());
    try testing.expectEqual(off_uf2, off_slot);
    const from = ipc_end - ram.start;
    try testing.expect(std.mem.eql(u8, via_uf2.bytes[from..], via_slot.bytes[from..]));
    // The slot never writes below the IPC end.
    for (via_slot.bytes[0..from]) |b| try testing.expectEqual(@as(u8, 0), b);
}

test "slot and UF2 load the same RAM (synthetic cart with a gap)" {
    const c: Cart = .{ .load_addr = 0x20035100, .len = 0x300, .desc_off = 0, .bss_start = 0x20035800, .bss_end = 0x20035900 };
    var img_buf: [0x1000]u8 = undefined;
    const img = c.image(&img_buf);
    // An ELF-header block in the IPC block (dropped), two blocks, then a
    // 0x100 gap, then a short last block.
    const elf_header: [0x100]u8 = @splat(0x7F);
    const file = try makeUf2(&.{
        .{ 0x20030000, &elf_header },
        .{ 0x20035100, img[0..0x100] },
        .{ 0x20035200, img[0x100..0x200] },
        .{ 0x20035400, img[0x200..0x280] },
    });
    defer testing.allocator.free(file);

    const flat = try flatten(file);
    defer flat.deinit();
    try testing.expectEqual(@as(u32, 0x20035100), flat.load_addr);
    try testing.expectEqual(@as(usize, 0x380), flat.image.len);
    for (flat.image[0x200..0x300]) |b| try testing.expectEqual(@as(u8, 0), b);

    const area = try makeSlot(flat.image, flat.load_addr, flat.descriptor_offset);
    defer testing.allocator.free(area);
    try expectSlotMatchesUf2(file, area);

    // A block straddling the IPC end makes the UF2 non-transferable.
    const straddle = try makeUf2(&.{
        .{ 0x20035080, img[0..0x100] },
    });
    defer testing.allocator.free(straddle);
    try testing.expectError(error.NotTransferable, flatten(straddle));
}

fn readFixture(name: []const u8) ![]u8 {
    const path = try std.fs.path.join(testing.allocator, &.{ test_options.fixtures_dir, name });
    defer testing.allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
}

test "fixture: snouty-pong.uf2 through this flattener loads like the UF2" {
    const file = try readFixture("snouty-pong.uf2");
    defer testing.allocator.free(file);
    const flat = try flatten(file);
    defer flat.deinit();
    // Its ELF-header blocks at 0x20030000 are dropped: the cart starts at the IPC end.
    try testing.expectEqual(ipc_end, flat.load_addr);
    const area = try makeSlot(flat.image, flat.load_addr, flat.descriptor_offset);
    defer testing.allocator.free(area);
    try expectSlotMatchesUf2(file, area);
}

test "fixture: beam_slot_pong.bin (monorepo flattener) loads like snouty-pong.uf2" {
    const slot = try readFixture("beam_slot_pong.bin");
    defer testing.allocator.free(slot);
    const file = try readFixture("snouty-pong.uf2");
    defer testing.allocator.free(file);
    try testing.expect(slot.len >= 4096 and slot.len <= area_size);

    // The slot as it sits in the (erased) cart area.
    const area = try testing.allocator.alloc(u8, area_size);
    defer testing.allocator.free(area);
    @memset(area, 0xFF);
    @memcpy(area[0..slot.len], slot);

    const h = try beam_slot.parseHeader(area[0..96], area_size, image_region);
    try testing.expectEqual(@as(u32, @intCast(file.len)), h.source_size);
    // Same image, load address and descriptor as the spec flattening.
    const flat = try flatten(file);
    defer flat.deinit();
    try testing.expectEqual(flat.load_addr, h.load_addr);
    try testing.expectEqual(flat.descriptor_offset, h.descriptor_offset);
    try testing.expectEqualSlices(u8, flat.image, area[4096..][0..h.image_len]);
    // The rest of the header sector is erased.
    for (area[96..4096]) |b| try testing.expectEqual(@as(u8, 0xFF), b);

    try expectSlotMatchesUf2(file, area);
}
