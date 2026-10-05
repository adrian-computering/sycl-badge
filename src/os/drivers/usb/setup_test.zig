//! Host tests for the setup request processor (setup.zig) against a model of
//! the RP2350's EP0, driven the way usb.zig drives it: buffer events first,
//! then a SETUP packet, then `poll`, all in one pass.
const std = @import("std");
const microzig = @import("microzig");
const types = microzig.core.usb.types;
const testing = std.testing;

const setup = @import("setup.zig");
const descriptors = @import("descriptors.zig");

/// EP0 as the controller sees it
const Ep0 = struct {
    out_armed: bool = false,
    out_stalled: bool = false,
    in_stalled: bool = false,
    /// A packet arrived that `poll` has not handled yet (BUFF_STATUS)
    out_pending: bool = false,
    out_data: [64]u8 = undefined,
    out_len: usize = 0,
    /// The IN packet waiting for the host, null when none is queued
    in_packet: ?struct { data: [64]u8, len: usize, pid: setup.PID } = null,
    setup_pending: ?types.SetupPacket = null,
    arm_count: usize = 0,
};

var ep0: Ep0 = .{};

const callbacks = struct {
    fn queue_packet(data: []const u8, pid: setup.PID) void {
        var pkt: @FieldType(Ep0, "in_packet") = .{ .data = undefined, .len = data.len, .pid = pid };
        @memcpy(pkt.?.data[0..data.len], data);
        ep0.in_packet = pkt;
        ep0.in_stalled = false;
    }

    // Same rules as usb.zig's queue_receive
    fn queue_receive() void {
        if (ep0.out_armed and !ep0.out_stalled) return;
        if (ep0.out_pending) return;
        ep0.out_armed = true;
        ep0.out_stalled = false;
        ep0.arm_count += 1;
    }

    fn get_buffer() []const u8 {
        return ep0.out_data[0..ep0.out_len];
    }

    fn set_address(_: u7) void {}

    fn clear_endpoint_halt(_: types.Endpoint) void {}

    fn stall(ep: types.Endpoint) void {
        switch (ep.dir) {
            .in => {
                ep0.in_stalled = true;
                ep0.in_packet = null;
            },
            .out => {
                ep0.out_stalled = true;
                ep0.out_armed = false;
            },
        }
    }
};

const Processor = setup.RequestPacketProcessor(.{
    .max_packet_size = 64,
    .max_transfer_size = 64,
    .callbacks = .{
        .queue_packet = callbacks.queue_packet,
        .queue_receive = callbacks.queue_receive,
        .set_address = callbacks.set_address,
        .get_buffer = callbacks.get_buffer,
        .clear_endpoint_halt = callbacks.clear_endpoint_halt,
        .stall = callbacks.stall,
    },
});

var line_coding: ?[7]u8 = null;

fn class_handler(proc: *Processor, _: ?*anyopaque, pkt: *const types.SetupPacket) void {
    switch (pkt.request) {
        0x20 => proc.queue_out_xfer(pkt.length.native(), .{ .ctx = null, .handler = set_line_coding }),
        0x22 => proc.queue_in_xfer("", 0),
        else => proc.stall_ep0(),
    }
}

fn set_line_coding(_: ?*anyopaque, payload: []const u8) void {
    line_coding = payload[0..7].*;
}

fn new_processor() Processor {
    ep0 = .{};
    line_coding = null;
    var desc = descriptors.descriptors;
    desc.runtime_strings = &.{.{ .index = descriptors.strings.serial, .payload = &.{ 6, 3, 'A', 0, 'B', 0 } }};
    return .init(.{
        .descriptors = desc,
        .handlers = .{ .interface = &.{.{ .num = 1, .ctx = null, .handler = class_handler }} },
    });
}

/// One pass of usb.zig's poll
fn device_poll(proc: *Processor) void {
    if (ep0.out_pending) {
        ep0.out_pending = false;
        proc.ep0_out_ready();
    }
    if (ep0.setup_pending) |pkt| {
        ep0.setup_pending = null;
        // A SETUP packet clears EP0 stalls
        ep0.in_stalled = false;
        if (ep0.out_stalled) {
            ep0.out_stalled = false;
            ep0.out_armed = false;
        }
        proc.submit_setup_request(pkt);
    }
    proc.poll();
}

fn host_setup(pkt: types.SetupPacket) void {
    ep0.setup_pending = pkt;
}

/// The host sends an OUT packet, error.Nak if EP0 OUT is not armed
fn host_out(data: []const u8) error{ Nak, Stall }!void {
    if (ep0.out_stalled) return error.Stall;
    if (!ep0.out_armed) return error.Nak;
    ep0.out_armed = false;
    @memcpy(ep0.out_data[0..data.len], data);
    ep0.out_len = data.len;
    ep0.out_pending = true;
}

/// The host reads the IN packet, error.Nak if none is queued
fn host_in(proc: *Processor) error{ Nak, Stall }!@FieldType(Ep0, "in_packet") {
    if (ep0.in_stalled) return error.Stall;
    const pkt = ep0.in_packet orelse return error.Nak;
    ep0.in_packet = null;
    proc.ep0_in_ready();
    return pkt;
}

fn packet(request_type: u8, request: u8, value: u16, index: u16, length: u16) types.SetupPacket {
    return @bitCast(@as(u64, request_type) | @as(u64, request) << 8 | @as(u64, value) << 16 | @as(u64, index) << 32 | @as(u64, length) << 48);
}

const set_line_coding_pkt = packet(0x21, 0x20, 0, 1, 7);
const line_coding_data = [7]u8{ 0x80, 0x25, 0, 0, 0, 0, 8 };

/// GET_DESCRIPTOR(device) and its status stage, which leaves EP0 OUT armed
fn enumerate_a_bit(proc: *Processor) !void {
    host_setup(packet(0x80, 6, 0x0100, 0, 18));
    device_poll(proc);
    const dev = try host_in(proc);
    try testing.expectEqual(18, dev.?.len);
    try testing.expectEqual(.data1, dev.?.pid);
    device_poll(proc);
    try host_out(""); // status stage
    device_poll(proc);
    try testing.expect(ep0.out_armed);
}

test "SET_LINE_CODING with the data stage in the same pass as the SETUP packet" {
    var proc = new_processor();
    try enumerate_a_bit(&proc);

    host_setup(set_line_coding_pkt);
    try host_out(&line_coding_data);
    device_poll(&proc);
    try testing.expectEqual(line_coding_data, line_coding.?);

    device_poll(&proc);
    const status = try host_in(&proc);
    try testing.expectEqual(0, status.?.len);
    try testing.expectEqual(.data1, status.?.pid);
    device_poll(&proc);
    try testing.expect(ep0.out_armed);
}

test "SET_LINE_CODING with the data stage in a later pass" {
    var proc = new_processor();
    try enumerate_a_bit(&proc);

    host_setup(set_line_coding_pkt);
    device_poll(&proc);
    try testing.expectEqual(null, line_coding);
    try host_out(&line_coding_data);
    device_poll(&proc);
    try testing.expectEqual(line_coding_data, line_coding.?);
    device_poll(&proc);
    try testing.expectEqual(0, (try host_in(&proc)).?.len);
}

test "SET_LINE_CODING right after a stalled request arms EP0 OUT itself" {
    var proc = new_processor();
    try enumerate_a_bit(&proc);

    // DEVICE_QUALIFIER is stalled: full speed only
    host_setup(packet(0x80, 6, 0x0600, 0, 10));
    device_poll(&proc);
    try testing.expectError(error.Stall, host_in(&proc));

    host_setup(set_line_coding_pkt);
    device_poll(&proc);
    try host_out(&line_coding_data);
    device_poll(&proc);
    try testing.expectEqual(line_coding_data, line_coding.?);
}

test "a data stage the request did not take is dropped, not handed to the next request" {
    var proc = new_processor();
    try enumerate_a_bit(&proc);

    // An unsupported class OUT request whose data arrived with the SETUP packet
    host_setup(packet(0x21, 0x00, 0, 1, 4));
    try host_out("junk");
    device_poll(&proc);
    try testing.expectError(error.Stall, host_in(&proc));

    host_setup(set_line_coding_pkt);
    device_poll(&proc);
    try host_out(&line_coding_data);
    device_poll(&proc);
    try testing.expectEqual(line_coding_data, line_coding.?);
}

test "requests without a handler and oversized data stages are stalled" {
    var proc = new_processor();
    try enumerate_a_bit(&proc);

    // Class request to an interface without a handler (a CDC data interface)
    host_setup(packet(0x21, 0x22, 1, 2, 0));
    device_poll(&proc);
    try testing.expectError(error.Stall, host_in(&proc));

    // SET_LINE_CODING longer than the processor's buffer
    host_setup(packet(0x21, 0x20, 0, 1, 200));
    device_poll(&proc);
    try testing.expectError(error.Stall, host_out(&line_coding_data));
    try testing.expectError(error.Stall, host_in(&proc));

    // Still works afterwards
    host_setup(packet(0x21, 0x22, 1, 1, 0));
    device_poll(&proc);
    try testing.expectEqual(0, (try host_in(&proc)).?.len);
}

test "string descriptors: language list, run time strings, unknown index" {
    var proc = new_processor();
    try enumerate_a_bit(&proc);

    // String 0 is asked for with language 0
    host_setup(packet(0x80, 6, 0x0300, 0, 255));
    device_poll(&proc);
    const langs = (try host_in(&proc)).?;
    try testing.expectEqualSlices(u8, &.{ 4, 3, 0x09, 0x04 }, langs.data[0..langs.len]);
    device_poll(&proc);
    try host_out("");
    device_poll(&proc);

    // The serial number comes from the run time table
    host_setup(packet(0x80, 6, 0x0300 | @as(u16, descriptors.strings.serial), 0x0409, 255));
    device_poll(&proc);
    const serial = (try host_in(&proc)).?;
    try testing.expectEqualSlices(u8, &.{ 6, 3, 'A', 0, 'B', 0 }, serial.data[0..serial.len]);
    device_poll(&proc);
    try host_out("");
    device_poll(&proc);

    host_setup(packet(0x80, 6, 0x03C8, 0x0409, 255));
    device_poll(&proc);
    try testing.expectError(error.Stall, host_in(&proc));
}

test "the configuration descriptor goes out in 64 byte packets ending short" {
    var proc = new_processor();
    try enumerate_a_bit(&proc);

    const config = descriptors.descriptors.configurations[0];
    host_setup(packet(0x80, 6, 0x0200, 0, 0xFFFF));
    device_poll(&proc);
    var received: std.ArrayList(u8) = .empty;
    defer received.deinit(testing.allocator);
    var pid: setup.PID = .data1;
    while (true) {
        const pkt = (try host_in(&proc)).?;
        try testing.expectEqual(pid, pkt.pid);
        pid = if (pid == .data1) .data0 else .data1;
        try received.appendSlice(testing.allocator, pkt.data[0..pkt.len]);
        device_poll(&proc);
        if (pkt.len < 64) break;
    }
    try testing.expectEqualSlices(u8, config, received.items);
}
