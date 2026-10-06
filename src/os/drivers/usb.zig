//! USB device driver
//!
//! The badge is a composite device (descriptors in usb/descriptors.zig): mass
//! storage on interface 0 for the cart drive, and two CDC ACM serial ports,
//! the kernel console on interfaces 1-2 and the running cart's serial port on
//! interfaces 3-4 (serviced by system/cart_serial.zig).
//!
//! Endpoints and their DPRAM buffers. Every buffer is single buffered and holds
//! one 64 byte packet; the controller requires 64 byte aligned buffers above
//! the 0x100 byte register area.
//!
//! | Endpoint | Type      | Use                          | DPRAM offset |
//! |----------|-----------|------------------------------|--------------|
//! | EP0 IN   | control   | setup requests (shared)      | 0x100        |
//! | EP0 OUT  | control   | setup requests (shared)      | 0x100        |
//! | EP1 IN   | bulk      | mass storage                 | 0x180        |
//! | EP1 OUT  | bulk      | mass storage                 | 0x1C0        |
//! | EP2 IN   | bulk      | console data                 | 0x200        |
//! | EP2 OUT  | bulk      | console data                 | 0x240        |
//! | EP3 IN   | interrupt | console notifications        | 0x280        |
//! | EP4 IN   | bulk      | cart serial data             | 0x2C0        |
//! | EP4 OUT  | bulk      | cart serial data             | 0x300        |
//! | EP5 IN   | interrupt | cart serial notifications    | 0x340        |
//!
//! 0x380-0xFFF is free. The notification endpoints are enabled so the
//! controller answers the host's polls with NAK, but never armed.
const std = @import("std");
const microzig = @import("microzig");
const assert = microzig.assert;
const rp2xxx = microzig.hal;
const core = microzig.core;
const descriptor = core.usb.descriptor;
const types = core.usb.types;
const Endpoint = types.Endpoint;
const USB = microzig.chip.peripherals.USB;
const USB_DPRAM = microzig.chip.peripherals.USB_DPRAM;
const SIO = microzig.chip.peripherals.SIO;
const EndpointType = microzig.chip.types.peripherals.USB_DPRAM.EndpointType;
const BufferControl = @FieldType(microzig.chip.types.peripherals.USB_DPRAM, "EP0_IN_BUFFER_CONTROL");
const EndpointControl = @FieldType(microzig.chip.types.peripherals.USB_DPRAM, "EP1_IN_CONTROL");

const setup = @import("usb/setup.zig");
const cdc = @import("usb/cdc.zig");
const usb_descriptors = @import("usb/descriptors.zig");
const timer = @import("timer.zig");
const endpoint = @import("usb/endpoint.zig");
const rom = @import("rom.zig");
const storage = @import("../loader/storage.zig");

const log = std.log.scoped(.usb_device);

const max_packet_size = usb_descriptors.max_packet_size;
const dpram_addr = @intFromPtr(USB_DPRAM);
const dpram_size = 4096;
const ep_ctrls: *volatile [32]EndpointControl = @ptrFromInt(dpram_addr + 0x00);
const buff_ctrls: *volatile [32]BufferControl = @ptrFromInt(dpram_addr + 0x80);

// DPRAM data buffers, see the table at the top. The hardware fixes the EP0
// buffer at 0x100 and shares it between both directions.
const ep0_buffer = 0x100;
const msc_in_buffer = 0x180;
const msc_out_buffer = 0x1C0;
const console_in_buffer = 0x200;
const console_out_buffer = 0x240;
const console_notification_buffer = 0x280;
const cart_in_buffer = 0x2C0;
const cart_out_buffer = 0x300;
const cart_notification_buffer = 0x340;

const msc_interface_num = usb_descriptors.msc_interface;

fn ep_idx(ep: Endpoint) usize {
    return (2 * @backingInt(ep.num)) + @as(usize, switch (ep.dir) {
        .in => 0,
        .out => 1,
    });
}

fn endpoint_control(ep: Endpoint) *volatile EndpointControl {
    assert(ep.num != .ep0, .{});
    // TODO: this is not how it works.
    return &ep_ctrls[ep_idx(ep)];
}

fn buffer_control(ep: Endpoint) *volatile BufferControl {
    return &buff_ctrls[ep_idx(ep)];
}

fn clear_dpram() void {
    const dpram: *[dpram_size]u8 = @ptrFromInt(dpram_addr);
    @memset(dpram, 0);
}

/// The serial number string descriptor: the chip id as 16 hex digits,
/// filled in by `init`
var serial_string: [2 + 2 * usb_descriptors.serial_len]u8 = undefined;
var chip_id_hex: [usb_descriptors.serial_len]u8 = undefined;

const runtime_strings = [_]setup.Descriptors.RuntimeString{
    .{ .index = usb_descriptors.strings.serial, .payload = &serial_string },
};

const SetupProcessor = setup.RequestPacketProcessor(.{
    .max_packet_size = max_packet_size,
    .max_transfer_size = max_packet_size,
    .callbacks = .{
        .queue_packet = queue_packet,
        .queue_receive = queue_receive,
        .set_address = set_address,
        .get_buffer = get_buffer,
        .clear_endpoint_halt = clear_endpoint_halt,
        .stall = stall,
        .set_configuration = on_set_configuration,
    },
});

// Cart files (fork/CART_FILES.md) must not write the drive while a host has
// it: a host caches the FAT and directory and writes its stale copy back.
// "Has it" = configured since the last bus reset, and start of frame packets
// still arriving (VBUS detection is forced on, so an unplugged cable looks
// like a suspended bus). A charger never configures the device.
var host_configured: bool = false;
var host_bus_active: bool = true;
/// Bumped whenever a host (re)appears: a SET_CONFIGURATION, or frames resuming
/// on a configured bus. A file opened before a bump is refused.
var host_generation: u32 = 0;

fn on_set_configuration(value: u16) void {
    host_configured = value != 0;
    host_generation +%= 1;
}

/// A USB host has configured the device and its bus is active.
pub fn hostHasDrive() bool {
    return host_configured and host_bus_active;
}

pub fn hostGeneration() u32 {
    return host_generation;
}

fn get_max_lun(_: ?*anyopaque) u4 {
    // One LUN per storage volume: the main drive, plus the external flash drive.
    return @intCast(storage.volumeCount() - 1);
}

fn bulk_only_mass_storage_reset(_: ?*anyopaque) void {}

const MSC_Driver = @import("usb/msc.zig").MSC_Driver(SetupProcessor, .{
    .max_packet_size = max_packet_size,
    .max_transfer_size = 512,
    .callbacks = .{
        .get_max_lun = get_max_lun,
        .bulk_only_mass_storage_reset = bulk_only_mass_storage_reset,
        .queue_packet = msc_queue_packet,
        .queue_receive = msc_queue_receive,
        .get_buffer = msc_get_buffer,
        .disarm_endpoints = msc_disarm_endpoints,
    },
});

/// The callbacks of a CDC port whose bulk endpoints are `ep_num` IN and OUT
fn CdcEndpoints(comptime ep_num: Endpoint.Num, comptime in_buffer: u16, comptime out_buffer: u16) type {
    return struct {
        fn send_packet(data: []const u8, pid: endpoint.PacketIdentifier) void {
            queue_in_packet(ep_num, in_buffer, data, pid);
        }

        fn arm(pid: endpoint.PacketIdentifier) void {
            queue_out_packet(ep_num, pid);
        }

        fn received() []const u8 {
            return received_packet(ep_num, out_buffer);
        }

        fn disarm(dir: types.Dir) void {
            switch (dir) {
                inline else => |d| {
                    disarm_endpoint(.{ .dir = d, .num = ep_num });
                    // drop an abandoned buffer
                    var status: @TypeOf(USB.BUFF_STATUS.read()) = .{};
                    @field(status, std.fmt.comptimePrint("EP{d}_{s}", .{
                        @backingInt(ep_num),
                        switch (d) {
                            .in => "IN",
                            .out => "OUT",
                        },
                    })) = 1;
                    rp2xxx.hw.clear_alias(&USB.BUFF_STATUS).write(status);
                },
            }
        }

        const callbacks: cdc.Callbacks = .{
            .queue_packet = send_packet,
            .queue_receive = arm,
            .get_buffer = received,
            .disarm_endpoint = disarm,
        };
    };
}

const ConsoleDriver = cdc.CDC_Driver(SetupProcessor, .{
    .max_packet_size = max_packet_size,
    .callbacks = CdcEndpoints(.ep2, console_in_buffer, console_out_buffer).callbacks,
});

pub const CartDriver = cdc.CDC_Driver(SetupProcessor, .{
    .max_packet_size = max_packet_size,
    .callbacks = CdcEndpoints(.ep4, cart_in_buffer, cart_out_buffer).callbacks,
});

var setup_processor: SetupProcessor = undefined;
var msc_driver: MSC_Driver = undefined;
var console: cdc.Buffered(ConsoleDriver, 1024, 256) = undefined;
var cart_driver: CartDriver = undefined;

/// True while `poll` runs, `send` and `receive` must not re-enter it
var in_poll = false;

/// Initialize the USB device
/// Sets up the USB in device mode with mass storage and two CDC serial ports
/// Returns error if initialization fails
pub fn init() !void {
    build_serial_string();

    log.info("Resetting USBCTRL", .{});
    rp2xxx.resets.reset(.only(.usbctrl));

    log.info("Clearing DPRAM", .{});
    clear_dpram();

    // Mux the controller to the onboard usb phy
    USB.USB_MUXING.write(.{
        .TO_PHY = 1,
        .SOFTCON = 1,
    });

    // Force VBUS detect so the device thinks its plugged to a host
    USB.USB_PWR.write(.{
        .VBUS_DETECT = 1,
        .VBUS_DETECT_OVERRIDE_EN = 1,
    });

    // Enable  the usb control in device mode
    USB.MAIN_CTRL.write(.{
        .PHY_ISO = 0,
        .CONTROLLER_EN = 1,
        .HOST_NDEVICE = 0,
    });

    USB.SIE_CTRL.write(.{
        .EP0_INT_1BUF = 1,
        .PULLDOWN_EN = 0,
    });

    USB.INTE.write(.{
        .BUS_RESET = 1,
        .SETUP_REQ = 1,
        .BUFF_STATUS = 1,
        .TRANS_COMPLETE = 1,
    });

    msc_driver.init(null);
    console.init();
    cart_driver.init();
    var descriptors = usb_descriptors.descriptors;
    descriptors.runtime_strings = &runtime_strings;
    setup_processor = .init(.{
        .descriptors = descriptors,
        .handlers = .{
            .interface = &.{
                .{ .num = msc_interface_num, .ctx = &msc_driver, .handler = MSC_Driver.setup_handler },
                .{ .num = usb_descriptors.console_interface, .ctx = &console.port, .handler = ConsoleDriver.setup_handler },
                .{ .num = usb_descriptors.cart_interface, .ctx = &cart_driver, .handler = CartDriver.setup_handler },
            },
        },
    });

    setup_endpoints();
    console.reset();
    cart_driver.reset();

    connect();
    msc_driver.in_ready();

    log.info("Finished init", .{});
    log_state();
}

fn set_address(addr: u7) void {
    log.info("set_address: {}", .{addr});
    USB.ADDR_ENDP.write(.{ .ADDRESS = addr });
}

fn stall(ep: types.Endpoint) void {
    log.info("stall: {}", .{ep});
    const buf_ctrl = buffer_control(ep);

    if (ep.num == .ep0) {
        // The controller only honors STALL on EP0 while EP_STALL_ARM is set,
        // and clears EP_STALL_ARM when the next SETUP packet arrives, as the
        // USB spec requires. The buffer is left unavailable, so after that
        // SETUP packet the endpoint NAKs until it is armed again.
        rp2xxx.hw.set_alias(&USB.EP_STALL_ARM).write(switch (ep.dir) {
            .in => .{ .EP0_IN = 1 },
            .out => .{ .EP0_OUT = 1 },
        });
        buf_ctrl.write(.{ .STALL = 1 });
        return;
    }

    disarm_endpoint(ep);
    buf_ctrl.modify(.{ .STALL = 1 });
}

fn clear_endpoint_halt(ep: types.Endpoint) void {
    switch (ep.num) {
        .ep1 => msc_driver.reset(),
        .ep2 => console.port.clear_halt(ep.dir),
        .ep4 => cart_driver.clear_halt(ep.dir),
        else => {},
    }
}

/// Aborts the transfer armed on `ep` so its buffer can be written again
fn abort_endpoint(ep: Endpoint) void {
    switch (ep.num) {
        inline .ep1, .ep2, .ep3, .ep4, .ep5 => |num| switch (ep.dir) {
            inline .in, .out => |dir| {
                const field = comptime std.fmt.comptimePrint("EP{d}_{s}", .{
                    @backingInt(num),
                    switch (dir) {
                        .in => "IN",
                        .out => "OUT",
                    },
                });

                var abort: @TypeOf(USB.EP_ABORT.read()) = .{};
                @field(abort, field) = 1;
                USB.EP_ABORT.write(abort);
                while (@field(USB.EP_ABORT_DONE.read(), field) == 0) {}

                var done: @TypeOf(USB.EP_ABORT_DONE.read()) = .{};
                @field(done, field) = 1;
                rp2xxx.hw.clear_alias(&USB.EP_ABORT_DONE).write(done);
                USB.EP_ABORT.write(.{});
            },
        },
        else => @panic("abort_endpoint: unsupported endpoint"),
    }
}

fn disarm_endpoint(ep: Endpoint) void {
    assert(ep.num != .ep0, .{});
    const buf_ctrl = buffer_control(ep);

    if (buf_ctrl.read().AVAILABLE_0 == 1) {
        abort_endpoint(ep);
    }

    buf_ctrl.write(.{ .STALL = 0 });
}

fn msc_disarm_endpoints() void {
    const in_ctrl = buffer_control(.{ .dir = .in, .num = .ep1 });
    const out_ctrl = buffer_control(.{ .dir = .out, .num = .ep1 });
    log.debug("disarm_msc_endpoints: in.available={} out.available={}", .{
        in_ctrl.read().AVAILABLE_0,
        out_ctrl.read().AVAILABLE_0,
    });

    disarm_endpoint(.{ .dir = .in, .num = .ep1 });
    disarm_endpoint(.{ .dir = .out, .num = .ep1 });

    // drop abandoned buffers
    rp2xxx.hw.clear_alias(&USB.BUFF_STATUS).write(.{ .EP1_IN = 1, .EP1_OUT = 1 });
}

/// The buffer control register needs a few cycles between writing the packet
/// fields and setting AVAILABLE
inline fn buffer_control_delay() void {
    asm volatile (
        \\ nop
        \\ nop
        \\ nop
    );
}

/// Queues one IN packet on a non-control endpoint
fn queue_in_packet(ep_num: Endpoint.Num, buffer_offset: u16, data: []const u8, pid: endpoint.PacketIdentifier) void {
    const buf_ctrl = buffer_control(.{ .dir = .in, .num = ep_num });
    assert(buf_ctrl.read().AVAILABLE_0 == 0, .{});
    assert(data.len <= max_packet_size, .{});

    const dest: [*]u8 = @ptrFromInt(dpram_addr + buffer_offset);
    @memcpy(dest[0..data.len], data);

    buf_ctrl.write(.{
        .LENGTH_0 = @intCast(data.len),
        .PID_0 = @backingInt(pid),
        .FULL_0 = 1,
        .LAST_0 = 1,
    });

    buffer_control_delay();

    buf_ctrl.modify(.{
        .AVAILABLE_0 = 1,
    });
}

/// Arms a non-control OUT endpoint to receive one packet
fn queue_out_packet(ep_num: Endpoint.Num, pid: endpoint.PacketIdentifier) void {
    const buf_ctrl = buffer_control(.{ .dir = .out, .num = ep_num });

    buf_ctrl.write(.{
        .LENGTH_0 = max_packet_size,
        .PID_0 = @backingInt(pid),
        .FULL_0 = 0,
        .LAST_0 = 1,
    });

    buffer_control_delay();

    buf_ctrl.modify(.{
        .AVAILABLE_0 = 1,
    });
}

/// Payload of the packet that a non-control OUT endpoint last received
fn received_packet(ep_num: Endpoint.Num, buffer_offset: u16) []const u8 {
    const buf_ctrl = buffer_control(.{ .dir = .out, .num = ep_num });
    const ptr: [*]const u8 = @ptrFromInt(dpram_addr + buffer_offset);
    return ptr[0..buf_ctrl.read().LENGTH_0];
}

fn queue_packet(data: []const u8, pid: setup.PID) void {
    const buf_ctrl = buffer_control(.{ .dir = .in, .num = .ep0 });
    //assert(buf_ctrl.read().AVAILABLE_0 == 0, .{});
    assert(data.len <= 64, .{});

    log.debug("queue_packet: len={} pid={}", .{ data.len, pid });
    const dest: [*]u8 = @ptrFromInt(dpram_addr + ep0_buffer);
    @memcpy(dest[0..data.len], data);

    buf_ctrl.write(.{
        .LENGTH_0 = @intCast(data.len),
        .PID_0 = @backingInt(pid),
        .FULL_0 = 1,
        .LAST_0 = 1,
    });

    buffer_control_delay();

    buf_ctrl.modify(.{
        .AVAILABLE_0 = 1,
    });
}

fn get_buffer() []const u8 {
    const buf_ctrl = buffer_control(.{ .dir = .out, .num = .ep0 });
    const ptr: [*]const u8 = @ptrFromInt(dpram_addr + ep0_buffer);
    return ptr[0..buf_ctrl.read().LENGTH_0];
}

fn queue_receive() void {
    const buf_ctrl = buffer_control(.{ .dir = .out, .num = .ep0 });

    // Already armed. Rewriting the buffer control register now could race
    // with a packet arriving.
    const current = buf_ctrl.read();
    if (current.AVAILABLE_0 == 1 and current.STALL == 0) return;
    // A packet arrived that `poll` has not handled yet, arming would lose it
    if (USB.BUFF_STATUS.read().EP0_OUT == 1) return;

    log.debug("queue_receive", .{});

    // Accept a full packet: either the zero length status stage of a control
    // IN transfer, or the single packet data stage of a control OUT request.
    // Both are DATA1.
    buf_ctrl.write(.{
        .LENGTH_0 = max_packet_size,
        .PID_0 = 1,
        .FULL_0 = 0,
        .LAST_0 = 1,
    });

    buffer_control_delay();

    buf_ctrl.modify(.{
        .AVAILABLE_0 = 1,
    });
}

fn msc_queue_packet(data: []const u8, pid: endpoint.PacketIdentifier) void {
    log.debug("queue_msc_packet: len={} pid={}", .{ data.len, pid });
    queue_in_packet(.ep1, msc_in_buffer, data, pid);
}

fn msc_get_buffer() []const u8 {
    return received_packet(.ep1, msc_out_buffer);
}

fn msc_queue_receive(pid: endpoint.PacketIdentifier) void {
    log.debug("queue_msc_receive: pid={}", .{pid});
    queue_out_packet(.ep1, pid);
}

fn configure_endpoint(ep: Endpoint, ep_type: EndpointType, buffer_offset: u16) void {
    endpoint_control(ep).write(.{
        .BUFFER_ADDRESS = buffer_offset,
        .ENDPOINT_TYPE = ep_type,
        .INTERRUPT_PER_BUFF = 1,
        .DOUBLE_BUFFERED = 0,
        .ENABLE = 1,
    });
}

fn setup_endpoints() void {
    // EP1 IN and OUT: mass storage
    configure_endpoint(.{ .num = .ep1, .dir = .in }, .bulk, msc_in_buffer);
    configure_endpoint(.{ .num = .ep1, .dir = .out }, .bulk, msc_out_buffer);
    msc_queue_receive(.DATA0);

    // EP2 IN and OUT: console data, the CDC driver arms the OUT side in reset
    configure_endpoint(.{ .num = .ep2, .dir = .in }, .bulk, console_in_buffer);
    configure_endpoint(.{ .num = .ep2, .dir = .out }, .bulk, console_out_buffer);

    // EP3 IN: console notifications. Enabled so the controller answers the
    // host's polls with NAK, but never armed: there is nothing to notify.
    configure_endpoint(.{ .num = .ep3, .dir = .in }, .interrupt, console_notification_buffer);

    // EP4 and EP5: the same for the cart serial port
    configure_endpoint(.{ .num = .ep4, .dir = .in }, .bulk, cart_in_buffer);
    configure_endpoint(.{ .num = .ep4, .dir = .out }, .bulk, cart_out_buffer);
    configure_endpoint(.{ .num = .ep5, .dir = .in }, .interrupt, cart_notification_buffer);
}

pub fn poll() void {
    if (in_poll) return;
    in_poll = true;
    defer in_poll = false;

    const interrupts = USB.INTS.read();

    if (interrupts.BUS_RESET == 1) {
        log.debug("BUS_RESET", .{});
        USB.ADDR_ENDP.write(.{ .ADDRESS = 0 });
        host_configured = false;

        msc_driver.reset();
        console.reset();
        cart_driver.reset();

        // TODO: use clear alias?
        USB.SIE_STATUS.write(.{ .BUS_RESET = 1 });
    }

    if (interrupts.BUFF_STATUS == 1) {
        const buff_status = USB.BUFF_STATUS.read();

        inline for (@typeInfo(@TypeOf(buff_status)).@"struct".field_names) |field_name| {
            if (@field(buff_status, field_name) == 1)
                log.debug("BUFF_STATUS: {s}", .{field_name});
        }

        const clear = rp2xxx.hw.clear_alias(&USB.BUFF_STATUS);
        if (buff_status.EP0_IN == 1) {
            setup_processor.ep0_in_ready();
            clear.write(.{ .EP0_IN = 1 });
        }

        if (buff_status.EP0_OUT == 1) {
            // Cleared first: the handler may arm the endpoint again, and
            // queue_receive treats a set bit as a packet still to handle
            clear.write(.{ .EP0_OUT = 1 });
            setup_processor.ep0_out_ready();
        }

        if (buff_status.EP1_IN == 1) {
            msc_driver.in_ready();
            clear.write(.{ .EP1_IN = 1 });
        }

        if (buff_status.EP1_OUT == 1) {
            msc_driver.out_ready();
            clear.write(.{ .EP1_OUT = 1 });
        }

        if (buff_status.EP2_IN == 1) {
            console.port.in_ready();
            clear.write(.{ .EP2_IN = 1 });
        }

        if (buff_status.EP2_OUT == 1) {
            console.port.out_ready();
            clear.write(.{ .EP2_OUT = 1 });
        }

        if (buff_status.EP4_IN == 1) {
            cart_driver.in_ready();
            clear.write(.{ .EP4_IN = 1 });
        }

        if (buff_status.EP4_OUT == 1) {
            cart_driver.out_ready();
            clear.write(.{ .EP4_OUT = 1 });
        }
    }

    if (interrupts.SETUP_REQ == 1) {
        log.debug("SETUP_REQ", .{});
        USB.SIE_STATUS.write(.{ .SETUP_REC = 1 });

        const pkt: *volatile types.SetupPacket = @ptrCast(@alignCast(&USB_DPRAM.SETUP_PACKET_LOW));
        setup_processor.submit_setup_request(pkt.*);
    }

    // Without start of frame packets the host is asleep or the cable is gone
    // (VBUS detection is forced on, so unplugging looks like a suspend): treat
    // both serial ports as closed so writers do not wait for a reader
    const suspended = !bus_active();
    if (host_configured and !suspended and !host_bus_active) host_generation +%= 1;
    host_bus_active = !suspended;
    console.port.bus_suspended = suspended;
    cart_driver.bus_suspended = suspended;

    setup_processor.poll();
    msc_driver.poll();
    console.poll();
    cart_driver.poll();
}

/// The frame number of the last start of frame packet, and when it changed
var last_frame: u11 = 0;
var last_frame_ms: u64 = 0;
var frame_seen = false;

/// True while the host sends a start of frame packet every millisecond. The
/// frame number is watched rather than SIE_STATUS.SUSPENDED, a sticky flag.
/// Until the frame number first changes the bus counts as active, so if it
/// never did the ports would behave as before rather than stay closed.
fn bus_active() bool {
    const frame = USB.SOF_RD.read().COUNT;
    const now = timer.millis();
    if (frame != last_frame) {
        last_frame = frame;
        last_frame_ms = now;
        frame_seen = true;
    }
    return !frame_seen or now - last_frame_ms < 20;
}

/// Sends console output to the host. Output waits in a buffer until a terminal
/// opens the port. While a terminal is connected this waits up to 100 ms for
/// room, then drops the rest. Returns true if every byte was queued.
pub fn send(data: []const u8) bool {
    // The USB peripheral belongs to core 0
    if (SIO.CPUID.raw != 0) return false;

    var rest = data[console.write(data)..];
    const deadline = timer.millis() + 100;
    while (rest.len > 0) {
        if (!console.connected() or in_poll or timer.millis() > deadline) return false;
        poll();
        rest = rest[console.write(rest)..];
    }
    return true;
}

/// Receives console input from the host. Waits up to `timeout_ms` for the
/// first byte. Returns the number of bytes written to `buffer`.
pub fn receive(buffer: []u8, timeout_ms: u32) usize {
    const deadline = timer.millis() + timeout_ms;
    while (true) {
        const n = console.read(buffer);
        if (n > 0 or in_poll or timer.millis() >= deadline) return n;
        poll();
    }
}

/// The cart serial port, for system/cart_serial.zig. Only use it from the
/// kernel main loop, never from inside `poll`.
pub fn cart_port() *CartDriver {
    return &cart_driver;
}

/// The RP2350 chip id as 16 uppercase hex digits, also the USB serial number
pub fn chip_id_string() []const u8 {
    return &chip_id_hex;
}

fn build_serial_string() void {
    _ = std.fmt.bufPrint(&chip_id_hex, "{X:0>16}", .{rom.chip_id()}) catch unreachable;
    serial_string[0] = serial_string.len;
    serial_string[1] = @backingInt(descriptor.Type.string);
    for (chip_id_hex, 0..) |c, i| {
        // UTF-16LE
        serial_string[2 + 2 * i] = c;
        serial_string[3 + 2 * i] = 0;
    }
}

fn log_state() void {
    log.debug("SIE_CTRL: {}", .{USB.SIE_CTRL.read()});
    log.debug("SIE_STATUS: {}", .{USB.SIE_STATUS.read()});
}

fn connect() void {
    log.info("Connect", .{});
    USB.SIE_CTRL.modify(.{
        .PULLUP_EN = 1,
    });
}

/// Disconnect the USB device from the host
/// This disables the pull-up resistor to signal disconnection
/// Call this before system reset to properly close the USB connection
pub fn disconnect() void {
    // Disable the pull-up resistor to disconnect from host
    // On RP235X, this is done via SIE_CTRL.PULLUP_EN
    USB.SIE_CTRL.modify(.{ .PULLUP_EN = 0 });
}

test {
    _ = @import("usb/setup.zig");
    _ = @import("usb/endpoint.zig");
    _ = @import("usb/cdc.zig");
    _ = @import("usb/descriptors.zig");
    _ = @import("usb/setup_test.zig");
}
