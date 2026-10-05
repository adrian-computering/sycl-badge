/// Program loader for UF2 cart files
/// Loads RAM carts (UF2 files) from FAT12 storage into process RAM.
/// XIP (execute-from-flash) carts are refused: the old cart_xip flash region now
/// holds the cart save store, and nothing but the store may erase it.
const std = @import("std");
const microzig = @import("microzig");
const storage = @import("storage.zig");
const uf2 = @import("uf2.zig");
const interrupt = microzig.interrupt;
const terry = @import("../system/terry.zig");
const multicore = @import("../system/multicore.zig");
const log_scope = .loader;
const log = std.log.scoped(log_scope);
const abi = @import("../cart/os_abi.zig");
const mailbox = @import("../ipc/mailbox.zig");

extern const __process_ram_start__: u8;
extern const __process_ram_end__: u8;

/// XIP (flash) address space. Any UF2 block aimed here is refused.
const XIP_SPACE_START: u32 = 0x10000000;
const XIP_SPACE_END: u32 = 0x20000000;

/// Cart load request structure (for IPC)
pub const CartLoadRequest = extern struct {
    start_cluster: u16,
    size: u32,
};

/// Cart state
pub const CartState = enum {
    none, // No cart loaded
    loading, // Currently loading
    ready, // Loaded and ready to execute
    running, // Currently executing on Core 1
    error_state, // Load error occurred (renamed to avoid keyword)
};

/// Cart load error types
pub const LoadError = error{
    FileNotFound,
    FileTooLarge,
    InvalidUF2,
    UnsupportedFamily,
    AddressMismatch,
    VersionMismatch,
    FlashWriteError,
    ReadError,
    /// The UF2 has blocks for XIP flash addresses (XIP carts are not supported).
    XipUnsupported,
};

/// Current cart state
var cart_state: terry.core0.TrackedStateMachine(CartState) = undefined;

/// Loaded cart entry point
var cart_entry_point: mailbox.MessageType.CartExecute = undefined;

/// Loaded cart info
var loaded_cart_name: [11:0]u8 = undefined;
var loaded_cart_size: u32 = 0;

pub fn getCartRamStart() u32 {
    return @intFromPtr(&__process_ram_start__);
}

pub fn getCartRamEnd() u32 {
    return @intFromPtr(&__process_ram_end__);
}

pub fn getCartRamSize() u32 {
    return getCartRamEnd() - getCartRamStart();
}

pub fn init() void {
    cart_state.register("loader.cart_state", .none, @src());
}

/// Get current cart state
pub fn getState() CartState {
    return cart_state.state;
}

/// Get loaded cart entry point
pub fn getEntryPoint() mailbox.MessageType.CartExecute {
    return cart_entry_point;
}

/// Check if a cart is ready to execute
pub fn isReady() bool {
    return cart_state.state == .ready;
}

/// Check if a cart is currently running
pub fn isRunning() bool {
    return cart_state.state == .running;
}

/// Mark cart as running (called when Core 1 starts execution)
pub fn markRunning() void {
    if (cart_state.state == .ready) {
        cart_state.set_state(.running, @src());
    }
}

/// Stop the current cart
pub fn stop() void {
    cart_state.set_state(.none, @src());
    cart_entry_point = undefined;
}

/// Auto-start cart if only one is present in storage
/// Returns true if a cart was auto-started, false otherwise
pub fn autoStartSingleCart() bool {
    // Count available carts
    var first_cart: storage.CartInfo = undefined;
    const cart_count = storage.countCarts(&first_cart);

    // Only auto-start if exactly one cart is present
    if (cart_count != 1) {
        return false;
    }

    // Get the cart name for loading
    const cart_name = if (first_cart.long_name_len > 0)
        first_cart.long_name[0..first_cart.long_name_len]
    else blk: {
        const end = std.mem.indexOfScalar(u8, first_cart.short_name[0..], 0) orelse first_cart.short_name.len;
        break :blk first_cart.short_name[0..end];
    };

    // Load the cart
    const entry_point = loadUF2Cart(cart_name) catch {
        return false;
    };

    // Execute the cart
    if (multicore.executeCart(entry_point)) {
        markRunning();
        return true;
    } else {
        return false;
    }
}
/// Load a UF2 RAM cart from FAT12 storage into process RAM
/// Returns the entry point address on success
pub fn loadUF2Cart(name: []const u8) LoadError!mailbox.MessageType.CartExecute {
    // If a cart is already running, stop Core 1 before overwriting its RAM.
    if (cart_state.state == .running) {
        multicore.haltCore1();
        multicore.resetCore1();
    }

    cart_state.set_state(.loading, @src());
    errdefer cart_state.set_state(.error_state, @src());

    // Find the cart in FAT12 storage
    const cart_info = storage.findCart(name) orelse {
        return LoadError.FileNotFound;
    };
    return loadUF2CartInfo(cart_info);
}

/// Load a cart the menu listed, by its exact location (names can repeat
/// across the two drives).
pub fn loadUF2CartEntry(entry: storage.CartEntry) LoadError!mailbox.MessageType.CartExecute {
    if (cart_state.state == .running) {
        multicore.haltCore1();
        multicore.resetCore1();
    }
    cart_state.set_state(.loading, @src());
    errdefer cart_state.set_state(.error_state, @src());
    return loadUF2CartInfo(.{
        .volume = entry.volume,
        .start_cluster = entry.start_cluster,
        .size = entry.size,
        .short_name = @splat(0),
        .long_name = undefined,
        .long_name_len = 0,
    });
}

fn loadUF2CartInfo(cart_info: storage.CartInfo) LoadError!mailbox.MessageType.CartExecute {
    errdefer cart_state.set_state(.error_state, @src());

    // Validate size (UF2 blocks are 512 bytes each with up to 256 payload bytes,
    // so a UF2 that fills process RAM is about 2x its size)
    const max_uf2_size = getCartRamSize() * 2;
    if (cart_info.size > max_uf2_size) {
        return LoadError.FileTooLarge;
    }

    // Read and parse UF2 blocks
    const start_info = try loadUF2FromStorage(cart_info);

    // Save cart info
    @memcpy(&loaded_cart_name, &cart_info.short_name);
    loaded_cart_size = cart_info.size;
    cart_entry_point = start_info;
    cart_state.set_state(.ready, @src());
    return start_info;
}

/// Internal function to load a UF2 from storage into process RAM
fn loadUF2FromStorage(cart_info: storage.CartInfo) LoadError!mailbox.MessageType.CartExecute {
    const cart_ram_start = getCartRamStart();
    const cart_ram_end = getCartRamEnd();

    log.info("cart info: {f}", .{cart_info});

    if (cart_info.size % uf2.BLOCK_SIZE != 0) {
        return LoadError.InvalidUF2;
    }

    var file: storage.FileIterator = .init(cart_info);

    var parser = uf2.Parser{};

    var ram_cart_descriptor: ?[*]u32 = null;

    // Process each UF2 block from the buffer
    var block_index: u32 = 0;
    var file_pos: usize = 0;
    while (file.next()) |block_data| : (block_index += 1) {
        if (block_data.len != uf2.BLOCK_SIZE) {
            return LoadError.ReadError;
        }

        if (std.log.logEnabled(.debug, log_scope)) {
            for (0..512 / 8) |row| {
                const row_data = block_data[8 * row ..];
                log.debug("0x{X}: {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2}", .{
                    file_pos,
                    row_data[0],
                    row_data[1],
                    row_data[2],
                    row_data[3],
                    row_data[4],
                    row_data[5],
                    row_data[6],
                    row_data[7],
                });
                file_pos += 8;
            }
        }

        // Parse the block
        const block = parser.parseBlock(block_data[0..uf2.BLOCK_SIZE]) catch {
            log.err("Failed to parse block block_index={} num_blocks={}", .{ block_index, parser.expected_blocks });
            return LoadError.InvalidUF2;
        };

        // On first block, validate family and base address
        if (block_index == 0) {
            // Check family ID
            if (block.hasFamilyId() and !block.isRP235X()) {
                return LoadError.UnsupportedFamily;
            }
        }

        const payload = block.getPayload();
        if (payload.len == 0) {
            log.err("empty UF2 block payload", .{});
            return LoadError.InvalidUF2;
        }

        const target = block.header.target_addr;
        if (target >= XIP_SPACE_START and target < XIP_SPACE_END) {
            // XIP carts are gone: the old cart_xip region holds the save store,
            // and nothing but the store may erase it.
            log.err("UF2 block for XIP address 0x{X}: XIP carts are not supported", .{target});
            return LoadError.XipUnsupported;
        } else if (target >= cart_ram_start and target + payload.len <= cart_ram_end) {
            if (ram_cart_descriptor == null) {
                // See if we can find the cart descriptor
                const data_as_u32 = std.mem.bytesAsSlice(u32, payload[0..std.mem.alignBackward(usize, payload.len, @alignOf(u32))]);
                if (std.mem.indexOfScalar(u32, data_as_u32, abi.CART_MAGIC)) |index| {
                    const byte_offset = index * @sizeOf(u32);
                    ram_cart_descriptor = @ptrFromInt(target + byte_offset);
                }
            }

            const ptr: [*]u8 = @ptrFromInt(target);
            @memcpy(ptr, payload);
        } else {
            return LoadError.AddressMismatch;
        }
    }

    if (block_index == 0) {
        return LoadError.InvalidUF2;
    }

    if (!parser.isComplete()) {
        log.err("parser is not complete", .{});
        return LoadError.InvalidUF2;
    }

    const cart_descriptor = ram_cart_descriptor orelse {
        log.err("no cart descriptor found", .{});
        return LoadError.InvalidUF2;
    };

    // Verify the version
    switch (cart_descriptor[1]) {
        abi.CART_VERSION_V1 => {
            const descriptor: *abi.CartDescriptorTable_v1 = @ptrCast(cart_descriptor);
            const bss_start = @intFromPtr(descriptor.bss_start);
            const bss_end = @intFromPtr(descriptor.bss_end);
            const entry_point = @intFromPtr(descriptor.entry_point);
            // Verify the pointers
            if (bss_start < cart_ram_start or bss_start > cart_ram_end or
                bss_end < cart_ram_start or bss_end > cart_ram_end or
                bss_start > bss_end or
                !(entry_point >= cart_ram_start and entry_point < cart_ram_end) or
                entry_point & 1 == 0) // entry_point must be thumb
            {
                return LoadError.AddressMismatch;
            }

            // Clear BSS
            const bss = @as([*]u8, @ptrFromInt(bss_start))[0 .. bss_end - bss_start];
            @memset(bss, 0);

            // Flush store pipe
            asm volatile ("dmb" ::: .{ .memory = true });

            // Return the entry point
            return .{ .xip = false, .offset = @intCast(@intFromPtr(cart_descriptor) - cart_ram_start) };
        },
        else => {
            return LoadError.VersionMismatch;
        },
    }
}

/// Legacy cart loading (for backwards compatibility with old cart format)
pub fn loadCart(info: storage.CartInfo) bool {
    // This function is deprecated - use loadUF2Cart instead
    _ = info;
    return false;
}

/// Legacy tick function (RAM carts need no tick)
pub fn tick() void {}
