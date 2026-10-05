//! The console's `id` command (fork firmware): which badge this is, which
//! firmware it runs, and the state of the cart serial port. `badge list` and
//! show-day debugging read it.
const std = @import("std");
const builtin = @import("builtin");

const console = @import("console.zig");
const cart_serial = @import("cart_serial.zig");
const usb = @import("../drivers/usb.zig");
const rev = @import("../drivers/rev.zig");
const firmware_version = @import("firmware_version");

pub fn cmd_id(iter: *std.mem.TokenIterator(u8, .scalar)) void {
    _ = iter;
    const info = cart_serial.info();

    console.printf("\r\nChip id:     {s} (USB serial number)\r\n", .{usb.chip_id_string()});
    console.printf("Firmware:    {s} (fork, cart serial v1), zig {s}\r\n", .{ firmware_version.git_describe, builtin.zig_version_string });
    console.printf("Hardware:    rev{s}\r\n", .{rev.revision.str()});
    console.printf("Cart serial: {s}, attached={}, host_open={}\r\n", .{
        @tagName(info.state),
        info.state == .open,
        info.host_open,
    });
    console.printf("  queued:    rx {d} B (+{d} B waiting in USB), tx {d} B\r\n", .{ info.rx_queued, info.rx_pending, info.tx_queued });
    console.printf("  totals:    rx {d} B, tx {d} B, dropped rx {d} B, tx {d} B\r\n\r\n", .{
        info.stats.rx_bytes,
        info.stats.tx_bytes,
        info.stats.rx_dropped,
        info.stats.tx_dropped,
    });
}
