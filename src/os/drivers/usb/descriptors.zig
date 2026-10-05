//! USB descriptors of the badge, a composite device with three functions:
//!
//! | Interfaces | Function                                  | Endpoints                         |
//! |------------|-------------------------------------------|-----------------------------------|
//! | 0          | Mass storage, the cart drive              | EP1 IN/OUT bulk                   |
//! | 1-2        | CDC ACM "SYCL Badge Console" (IAD)        | EP3 IN interrupt, EP2 IN/OUT bulk |
//! | 3-4        | CDC ACM "SYCL Badge Cart Serial" (IAD)    | EP5 IN interrupt, EP4 IN/OUT bulk |
//!
//! The device class is Miscellaneous/Common/IAD, so hosts bind their CDC ACM
//! driver (cdc_acm, usbser, AppleUSBCDC) to each association on their own.
//! See fork/CART_SERIAL.md.
const std = @import("std");
const microzig = @import("microzig");
const descriptor = microzig.core.usb.descriptor;
const types = microzig.core.usb.types;

const setup = @import("setup.zig");
const cdc = @import("cdc.zig");

pub const max_packet_size = 64;

// Interface numbers, class requests carry them in wIndex
pub const msc_interface = 0;
pub const console_interface = 1;
pub const cart_interface = 3;
pub const num_interfaces = 5;

/// Length of the serial number: the chip id in hex
pub const serial_len = 16;

pub const Strings = struct {
    serial: u8,
};

pub const strings: Strings = table.strings;
pub const descriptors: setup.Descriptors = table.descriptors;

const table = blk: {
    var builder: setup.StringDescriptorBuilder(&.{.english}) = .init();

    const manufacturer = builder.add_single("Zig Embedded Group");
    const product = builder.add_single("SYCL Badge V2");
    // Placeholder, usb.zig serves the chip id at run time
    const serial = builder.add_single(&@as([serial_len]u8, @splat('0')));
    const config_name = builder.add_single("default");
    const msc_name = builder.add_single("SYCL Badge Cart Storage");
    const console_name = builder.add_single("SYCL Badge Console");
    const cart_name = builder.add_single("SYCL Badge Cart Serial");

    const device = descriptor.Device{
        .bcd_usb = .v2_00,
        // Composite device with interface association descriptors
        .device_triple = .{ .class = .Miscellaneous, .subclass = 0x02, .protocol = 0x01 },
        .max_packet_size0 = max_packet_size,
        .vendor = .from(1234),
        .product = .from(1234),
        // Badge V2
        .bcd_device = .from(2, 0),
        .manufacturer_s = manufacturer,
        .product_s = product,
        .serial_s = serial,
        // rarely ever more than one
        .num_configurations = 1,
    };

    const const_builder = builder.finish();

    // Interface 0: mass storage for carts
    const msc_interface_desc = descriptor.Interface{
        .interface_number = msc_interface,
        .alternate_setting = 0,
        .num_endpoints = 2,
        .interface_triple = .from(.MassStorage, .SCSI, .BulkOnly),
        .interface_s = msc_name,
    };
    const msc_in_ep: descriptor.Endpoint = .bulk(.{ .dir = .in, .num = .ep1 }, max_packet_size);
    const msc_out_ep: descriptor.Endpoint = .bulk(.{ .dir = .out, .num = .ep1 }, max_packet_size);

    // Interfaces 1 and 2: the kernel console
    const console: cdc.FunctionDescriptors = .init(.{
        .first_interface = console_interface,
        .name = console_name,
        .notification_ep = .ep3,
        .data_ep = .ep2,
        .max_packet_size = max_packet_size,
    });

    // Interfaces 3 and 4: the running cart's serial port
    const cart: cdc.FunctionDescriptors = .init(.{
        .first_interface = cart_interface,
        .name = cart_name,
        .notification_ep = .ep5,
        .data_ep = .ep4,
        .max_packet_size = max_packet_size,
    });

    const function_descriptors = std.mem.asBytes(&msc_interface_desc) ++
        std.mem.asBytes(&msc_in_ep) ++
        std.mem.asBytes(&msc_out_ep) ++
        std.mem.asBytes(&console) ++
        std.mem.asBytes(&cart);

    const config = descriptor.Configuration{
        .total_length = .from(@sizeOf(descriptor.Configuration) + function_descriptors.len),
        .num_interfaces = num_interfaces,
        .configuration_value = 1,
        .configuration_s = config_name,
        .attributes = .{ .self_powered = false },
        .max_current = .from_ma(350),
    };

    const config_payload = std.mem.asBytes(&config) ++ function_descriptors;
    break :blk .{
        .strings = Strings{ .serial = serial },
        .descriptors = setup.Descriptors{
            .device = &device,
            .string = const_builder.to_descriptor(),
            .configurations = &.{config_payload},
        },
    };
};

const testing = std.testing;

// Walks a configuration descriptor the way a host does, checking the
// structure that hosts rely on to bind drivers.
test "configuration descriptor" {
    const bytes = descriptors.configurations[0];
    const Type = descriptor.Type;

    // Configuration header
    try testing.expectEqual(9, bytes[0]);
    try testing.expectEqual(@backingInt(Type.configuration), bytes[1]);
    try testing.expectEqual(bytes.len, std.mem.readInt(u16, bytes[2..4], .little));
    try testing.expectEqual(num_interfaces, bytes[4]);

    var interfaces_seen: usize = 0;
    var endpoints_seen: std.ArrayList(u8) = .empty;
    defer endpoints_seen.deinit(testing.allocator);
    var associations: usize = 0;
    var functional: usize = 0;
    // Interface number and endpoint count of the interface being walked
    var current_interface: ?u8 = null;
    var endpoints_left: usize = 0;
    // Interfaces an association still has to cover
    var association_next: u8 = 0;
    var association_left: usize = 0;

    var offset: usize = bytes[0];
    while (offset < bytes.len) {
        const len = bytes[offset];
        try testing.expect(len >= 2);
        try testing.expect(offset + len <= bytes.len);
        const desc = bytes[offset .. offset + len];
        const desc_type: Type = @fromBackingInt(desc[1]);
        switch (desc_type) {
            .interface_association => {
                try testing.expectEqual(8, len);
                // The previous association is complete
                try testing.expectEqual(0, association_left);
                try testing.expectEqual(0, endpoints_left);
                // It starts at the next interface and covers the CDC pair
                try testing.expectEqual(interfaces_seen, desc[2]);
                try testing.expectEqual(2, desc[3]);
                try testing.expectEqual(0x02, desc[4]); // CDC
                try testing.expectEqual(0x02, desc[5]); // ACM
                try testing.expect(desc[7] != 0); // named
                association_next = desc[2];
                association_left = desc[3];
                associations += 1;
            },
            .interface => {
                try testing.expectEqual(9, len);
                try testing.expectEqual(0, endpoints_left);
                // Numbered 0, 1, 2, ... in order
                try testing.expectEqual(interfaces_seen, desc[2]);
                try testing.expectEqual(0, desc[3]); // alternate setting
                if (association_left > 0) {
                    try testing.expectEqual(association_next, desc[2]);
                    association_next += 1;
                    association_left -= 1;
                }
                current_interface = desc[2];
                endpoints_left = desc[4];
                interfaces_seen += 1;
            },
            .endpoint => {
                try testing.expectEqual(7, len);
                try testing.expect(endpoints_left > 0);
                endpoints_left -= 1;
                // Endpoint addresses are unique and not EP0
                try testing.expect(desc[2] & 0x0F != 0);
                try testing.expect(std.mem.indexOfScalar(u8, endpoints_seen.items, desc[2]) == null);
                try endpoints_seen.append(testing.allocator, desc[2]);
                try testing.expect(std.mem.readInt(u16, desc[4..6], .little) <= max_packet_size);
            },
            .cs_interface => {
                // CDC functional descriptors belong to a communications interface
                try testing.expect(current_interface == console_interface or current_interface == cart_interface);
                functional += 1;
            },
            else => return error.UnexpectedDescriptor,
        }
        offset += len;
    }

    try testing.expectEqual(bytes.len, offset);
    try testing.expectEqual(num_interfaces, interfaces_seen);
    try testing.expectEqual(0, endpoints_left);
    try testing.expectEqual(0, association_left);
    try testing.expectEqual(2, associations);
    // Header, call management, ACM and union for each CDC function
    try testing.expectEqual(8, functional);
    // MSC 2, console 3, cart 3
    try testing.expectEqual(8, endpoints_seen.items.len);
}

test "CDC functional descriptors point at their own interfaces" {
    const bytes = descriptors.configurations[0];
    for ([_]u8{ console_interface, cart_interface }) |comm| {
        // Find the communications interface, then its functional descriptors
        var offset: usize = bytes[0];
        while (offset < bytes.len) : (offset += bytes[offset]) {
            if (bytes[offset + 1] == @backingInt(descriptor.Type.interface) and bytes[offset + 2] == comm) break;
        } else return error.InterfaceNotFound;

        try testing.expectEqual(0x02, bytes[offset + 5]); // CDC
        try testing.expectEqual(0x02, bytes[offset + 6]); // ACM
        offset += bytes[offset];

        var seen: usize = 0;
        while (bytes[offset + 1] == @backingInt(descriptor.Type.cs_interface)) : (offset += bytes[offset]) {
            const desc = bytes[offset..];
            switch (desc[2]) {
                0x00 => {}, // header
                0x01 => try testing.expectEqual(comm + 1, desc[4]), // call management: data interface
                0x02 => try testing.expect(desc[3] & 0x02 != 0), // ACM: line coding requests
                0x06 => { // union
                    try testing.expectEqual(comm, desc[3]);
                    try testing.expectEqual(comm + 1, desc[4]);
                },
                else => return error.UnexpectedFunctionalDescriptor,
            }
            seen += 1;
        }
        try testing.expectEqual(4, seen);
    }
}

test "device descriptor and strings" {
    const dev = std.mem.asBytes(descriptors.device);
    try testing.expectEqual(18, dev.len);
    // Miscellaneous / Common class / Interface association
    try testing.expectEqual(0xEF, dev[4]);
    try testing.expectEqual(0x02, dev[5]);
    try testing.expectEqual(0x01, dev[6]);
    try testing.expectEqual(strings.serial, dev[16]);

    // The serial number placeholder has room for the chip id
    const serial = descriptors.string.lookup(.english, strings.serial).?;
    try testing.expectEqual(2 + 2 * serial_len, serial.payload.len);

    // String 0 lists the languages whatever language the host asks for
    const langs = descriptors.string.lookup(@fromBackingInt(0), 0).?;
    try testing.expectEqualSlices(u8, &.{ 4, 3, 0x09, 0x04 }, langs.payload);

    // Out of range indices are rejected rather than read past the table
    try testing.expectEqual(null, descriptors.string.lookup(.english, 200));
}
