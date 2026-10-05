//! Cart serial: a byte pipe between the running cart and a program on the
//! computer the badge is plugged into. Fork firmware only; on stock firmware
//! `supported()` is false and `open()` returns `error.Unsupported`, so carts
//! can offer multiplayer when it is there and hide it when it is not.
//!
//! On the badge the pipe is the "SYCL Badge Cart Serial" USB port (a second
//! serial port next to the OS console). In the simulator it is a TCP socket on
//! 127.0.0.1 (the simulator prints the port at startup). Host programs open
//! either one the same way; see tools/badge and fork/CART_SERIAL.md.
//!
//! The pipe is reliable and ordered, like a TCP stream. Nothing is lost while
//! the host has the port open: when your receive ring is full the badge stops
//! accepting USB data until you read. Bytes you write while no host program
//! has the port open are discarded.
//!
//! All calls are non-blocking and cheap enough to call every frame.
//!
//!     const cart = @import("cart-api");
//!
//!     pub fn start() void {
//!         cart.serial.open() catch {}; // no fork firmware: single player only
//!     }
//!
//!     pub fn update() void {
//!         var buf: [64]u8 = undefined;
//!         const n = cart.serial.read(&buf);
//!         _ = cart.serial.write(buf[0..n]); // echo
//!     }
//!
//! For messages instead of bytes (and a ready-made multiplayer lobby), use
//! `cart.lobby`, which is built on top of this.

const api = @import("api.zig");
const platform = api.platform;

pub const OpenError = error{
    /// The firmware on this badge has no cart serial port.
    Unsupported,
};

pub const Options = struct {
    /// Receive ring size in bytes (host -> cart). Power of two, at least 64.
    rx_size: u32 = 2048,
    /// Transmit ring size in bytes (cart -> host). Power of two, at least 64.
    tx_size: u32 = 2048,
};

/// True when the firmware offers the cart serial port.
pub fn supported() bool {
    return platform.serial_supported();
}

/// Open the port with the default 2 KiB rings. Call once, usually in start().
/// Opening an already open port does nothing.
pub fn open() OpenError!void {
    return open_with(.{});
}

/// Open the port with custom ring sizes. The rings live in static cart memory
/// sized at compile time, so each distinct `options` value costs its own RAM.
pub fn open_with(comptime options: Options) OpenError!void {
    comptime {
        if (!is_valid_size(options.rx_size)) @compileError("serial rx_size must be a power of two >= 64");
        if (!is_valid_size(options.tx_size)) @compileError("serial tx_size must be a power of two >= 64");
    }
    const Static = struct {
        var rx: [options.rx_size]u8 = undefined;
        var tx: [options.tx_size]u8 = undefined;
    };
    return platform.serial_open(&Static.rx, &Static.tx);
}

/// Close the port. Queued bytes in both directions are dropped. The OS also
/// closes the port when the cart exits, so most carts never call this.
pub fn close() void {
    platform.serial_close();
}

/// True between a successful open() and close().
pub fn is_open() bool {
    return platform.serial_is_open();
}

/// True while a program on the host has the port open. Use it to show
/// "waiting for lobby" instead of sending into the void.
pub fn connected() bool {
    return platform.serial_connected();
}

/// Queue bytes for the host. Returns how many were queued, which is less than
/// `bytes.len` when the transmit ring is full (or 0 when the port is closed).
pub fn write(bytes: []const u8) usize {
    return platform.serial_write(bytes);
}

/// Copy received bytes into `buf`. Returns how many were copied (0 when
/// nothing is waiting or the port is closed).
pub fn read(buf: []u8) usize {
    return platform.serial_read(buf);
}

/// Bytes waiting to be read.
pub fn bytes_available() usize {
    return platform.serial_bytes_available();
}

/// Bytes that write() can queue right now without truncating.
pub fn space_available() usize {
    return platform.serial_space_available();
}

fn is_valid_size(n: u32) bool {
    return n >= 64 and (n & (n - 1)) == 0;
}
