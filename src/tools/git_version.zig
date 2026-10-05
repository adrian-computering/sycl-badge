//! Prints a Zig source file holding `git describe` of the working directory,
//! or "unknown" when git or the repository is missing, so a build never fails
//! over it. build.zig runs it for the kernel's firmware version (console `id`).
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const describe = blk: {
        const result = std.process.run(init.arena.allocator(), init.io, .{
            .argv = &.{ "git", "describe", "--tags", "--always", "--dirty" },
        }) catch break :blk "unknown";
        if (result.term != .exited or result.term.exited != 0) break :blk "unknown";
        break :blk std.mem.trim(u8, result.stdout, " \r\n");
    };

    var buffer: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    try stdout.interface.print("pub const git_describe = \"{f}\";\n", .{std.zig.fmtString(describe)});
    try stdout.interface.flush();
}
