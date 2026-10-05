//! Stand-in for the microzig module in host unit tests (`zig build test`):
//! the portable parts only, USB descriptor types and `assert`. Code that
//! touches chip peripherals is not reachable from the tests.
const std = @import("std");

pub const core = @import("mz_core");

pub const AssertOptions = struct {};

pub fn assert(expr: bool, opts: AssertOptions) void {
    _ = opts;
    std.debug.assert(expr);
}
