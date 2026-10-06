//! fat_write.Disk over storage.zig's sector cache: reads see pending writes,
//! writes go through the 4 KB pending block, flush erases and programs it.
const fat_write = @import("fat_write.zig");
const storage = @import("storage.zig");

/// Indices are passed as ctx; these give each volume a stable address.
const ids = [2]u8{ 0, 1 };

pub fn disk(index: u8) fat_write.Disk {
    return .{
        .ctx = @ptrCast(@constCast(&ids[index])),
        .read = read,
        .write = write,
        .flush = flush,
    };
}

fn volumeOf(ctx: ?*anyopaque) *const storage.Volume {
    const id: *const u8 = @ptrCast(ctx.?);
    return storage.volume(id.*);
}

fn read(ctx: ?*anyopaque, lba: u32, dst: *[fat_write.sector_size]u8) void {
    storage.readSector(volumeOf(ctx), lba, dst);
}

fn write(ctx: ?*anyopaque, lba: u32, src: *const [fat_write.sector_size]u8) void {
    storage.writeSector(volumeOf(ctx), lba, src);
}

fn flush(_: ?*anyopaque) void {
    storage.flushPendingWrites();
}
