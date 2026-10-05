const api = @import("api.zig");
const os_abi = @import("os_abi.zig");

pub const screen_width = api.screen_width;
pub const screen_height = api.screen_height;

pub const Framebuffer = api.Framebuffer;
pub const DisplayColor = api.DisplayColor;
pub const NeopixelColor = api.NeopixelColor;
pub const Controls = api.Controls;
pub const Unsigned12 = api.Unsigned12;
pub const Rect8 = api.Rect8;

pub const SaveRequest = os_abi.SaveRequest;
pub const SaveOp = os_abi.SaveOp;
pub const SaveState = os_abi.SaveState;
pub const SaveStatus = os_abi.SaveStatus;
pub const SaveStat = os_abi.SaveStat;
pub const SaveListEntry = os_abi.SaveListEntry;
pub const SAVE_MAGIC = os_abi.SAVE_MAGIC;
pub const SAVE_ABI_VERSION = os_abi.SAVE_ABI_VERSION;

pub const SimulatorAPI = extern struct {
    is_running: *const fn () callconv(.c) bool,
    micros_since_boot: *const fn () callconv(.c) u64,
    check_flags: *const fn (u32) callconv(.c) bool,
    wait_for_flags: *const fn (u32) callconv(.c) void,
    set_flags: *const fn (u32) callconv(.c) void,

    // Cart serial over TCP (fork, see fork/CART_SERIAL.md). The simulator
    // services the cart's own ring buffers; all calls are non-blocking.
    serial_open: *const fn (rx: [*]u8, rx_cap: u32, tx: [*]u8, tx_cap: u32) callconv(.c) void,
    serial_close: *const fn () callconv(.c) void,
    serial_connected: *const fn () callconv(.c) bool,
    serial_read: *const fn (buf: [*]u8, len: usize) callconv(.c) usize,
    serial_write: *const fn (bytes: [*]const u8, len: usize) callconv(.c) usize,
    serial_bytes_available: *const fn () callconv(.c) usize,
    serial_space_available: *const fn () callconv(.c) usize,
    /// Serves one cart save request synchronously (the simulator's save store
    /// is a file-backed fake NOR). `buf` stands in for req.buf, which can't hold
    /// a host pointer.
    save_request: *const fn (req: *SaveRequest, buf: ?[*]u8) callconv(.c) void,
};

pub const SimulatorIO = extern struct {
    framebuffers: [2]api.Framebuffer align(api.framebuffer_alignment),
    neopixels: [5]NeopixelColor align(4),
    _pad: u8 = 0,
    controls: Controls = @bitCast(@as(u16, 0)),
    light_level: Unsigned12,
    battery_level: u8,
    user_led: bool = false,
    sim_running: bool,
    dirty_rect: Rect8,
    clear_color: DisplayColor,
    framebuffer_index: u8,
    audio_buffer_ptr: ?*anyopaque,
    audio_buffer_len: u32,
    audio_buffer_tail: u32,
    audio_buffer_head: u32,
    audio_volume: f32,

    api: *const SimulatorAPI,
};

pub const FLAG_PRESENT_METADATA = 1 << 0;
pub const FLAG_PRESENT_FRAME = 1 << 1;
pub const FLAG_AUDIO_VOLUME = 1 << 2;
pub const FLAG_START_AUDIO = 1 << 3;
pub const FLAG_STOP_AUDIO = 1 << 4;
