/// ROM driver for RP2354B
/// Provides access to bootrom functions and system reset capabilities
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const rom_api = hal.rom;
const ext_flash = @import("ext_flash.zig");

// -----------------------------------------------------------------------------
// System Control
// -----------------------------------------------------------------------------

/// Reset to USB bootloader (BOOTSEL mode)
pub fn reset_to_usb_boot() void {
    rom_api.reset_to_usb_boot();
}

// -----------------------------------------------------------------------------
// Flash Operations
// -----------------------------------------------------------------------------

/// Restore all QSPI pad controls to their default state
pub inline fn connect_internal_flash() void {
    rom_api.connect_internal_flash();
}

/// Configure the SSI to generate a standard 03h serial read command.
/// The bootrom does this for both QMI windows, so the external flash
/// window gets its faster read mode back afterwards.
pub inline fn flash_enter_cmd_xip() void {
    rom_api.flash_enter_cmd_xip();
    ext_flash.applyReadMode();
}

/// Set up SSI for serial-mode operations and issue XIP exit sequence
pub inline fn flash_exit_xip() void {
    rom_api.flash_exit_xip();
}

/// Flush the flash cache
pub inline fn flash_flush_cache() void {
    rom_api.flash_flush_cache();
}

/// Erase a range of flash
pub inline fn flash_range_erase(addr: u32, count: usize, block_size: u32, block_cmd: u8) void {
    rom_api.flash_range_erase(addr, count, block_size, block_cmd);
}

/// Program data to a range of flash addresses
pub inline fn flash_range_program(addr: u32, data: []const u8) void {
    rom_api.flash_range_program(addr, data);
}

// -----------------------------------------------------------------------------
// Chip Information
// -----------------------------------------------------------------------------

/// The 64-bit chip id burned into OTP at manufacture (CHIPID0-3), unique per
/// chip. Read through the bootrom's get_sys_info(SYS_INFO_CHIP_INFO), which
/// returns the flags word, then package_sel, device_id and wafer_id. The value
/// is wafer_id:device_id, the same 16 hex digits that picotool and the pico-sdk
/// (pico_get_unique_board_id) report for the chip.
/// Returns 0 if the bootrom call fails.
pub fn chip_id() u64 {
    const SYS_INFO_CHIP_INFO = 0x0001;
    var info: [4]u32 = @splat(0);
    const get_sys_info: *const rom_api.signatures.get_sys_info = @ptrCast(@alignCast(rom_api.lookup_function(.get_sys_info)));
    // The number of words written: the flags word plus three
    if (get_sys_info(&info, info.len, SYS_INFO_CHIP_INFO) != info.len) return 0;
    return (@as(u64, info[3]) << 32) | info[2];
}
