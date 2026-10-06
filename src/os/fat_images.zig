//! Root of the `fat-images` host tool (`zig build fat-images`), here so the
//! tool may import src/os/loader; the code is in tests/fat_images.zig.
const std = @import("std");

pub const main = @import("tests/fat_images.zig").main;
pub const std_options: std.Options = .{ .log_level = .warn };
