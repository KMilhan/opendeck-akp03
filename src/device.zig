const std = @import("std");
const mappings = @import("mappings.zig");
const inputs = @import("inputs.zig");
const mirajazz = @import("mirajazz");

pub const DeviceError = mirajazz.errors.Error;

pub const DeviceStateUpdate = union(enum) {
    ButtonDown: u8,
    ButtonUp: u8,
    EncoderDown: u8,
    EncoderUp: u8,
    EncoderTwist: struct { encoder: u8, delta: i8 },
};

pub const DeviceStateReader = struct {
    allocator: std.mem.Allocator,
    inner: *mirajazz.state.DeviceStateReader,

    pub fn deinit(self: *DeviceStateReader) void {
        self.inner.deinit();
        self.allocator.destroy(self.inner);
    }

    pub fn read(self: *DeviceStateReader, allocator: std.mem.Allocator) DeviceError![]DeviceStateUpdate {
        const inner_updates = try self.inner.read(100);
        defer self.inner.allocator.free(inner_updates);

        var out = std.ArrayList(DeviceStateUpdate).empty;
        errdefer out.deinit(allocator);

        for (inner_updates) |update| {
            switch (update) {
                .ButtonDown => |key| try out.append(allocator, .{ .ButtonDown = key }),
                .ButtonUp => |key| try out.append(allocator, .{ .ButtonUp = key }),
                .EncoderDown => |enc| try out.append(allocator, .{ .EncoderDown = enc }),
                .EncoderUp => |enc| try out.append(allocator, .{ .EncoderUp = enc }),
                .EncoderTwist => |tw| try out.append(allocator, .{ .EncoderTwist = .{ .encoder = tw.index, .delta = tw.delta } }),
            }
        }

        return out.toOwnedSlice(allocator);
    }
};

pub const Device = struct {
    inner: mirajazz.device.Device,
    vid: u16,
    pid: u16,
    serial_number: []const u8,

    pub fn connect(
        allocator: std.mem.Allocator,
        dev: mappings.HidDeviceInfo,
        protocol_version: usize,
        key_count: usize,
        encoder_count: usize,
    ) DeviceError!Device {
        const path = dev.path orelse return mirajazz.errors.MirajazzError.InvalidDeviceError;
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);

        var info = mirajazz.types.HidDeviceInfo{
            .path = path_z,
            .vendor_id = dev.vendor_id,
            .product_id = dev.product_id,
            .serial_number = dev.serial_number,
            .usage_page = dev.usage_page,
            .usage = dev.usage_id,
            .interface_number = 0,
        };

        const inner = try mirajazz.device.Device.connect(
            allocator,
            &info,
            protocol_version,
            key_count,
            encoder_count,
        );

        return .{
            .inner = inner,
            .vid = inner.vid,
            .pid = inner.pid,
            .serial_number = inner.serialNumber(),
        };
    }

    pub fn deinit(self: *Device) void {
        self.inner.deinit();
    }

    pub fn set_brightness(self: *Device, percent: u8) DeviceError!void {
        try self.inner.setBrightness(percent);
    }

    pub fn clear_all_button_images(self: *Device) DeviceError!void {
        try self.inner.clearAllButtonImages();
    }

    pub fn clear_button_image(self: *Device, key: u8) DeviceError!void {
        try self.inner.clearButtonImage(key);
    }

    pub fn set_button_image(self: *Device, key: u8, _: mappings.ImageFormat, image_data: []const u8) DeviceError!void {
        try self.inner.writeImage(key, image_data);
    }

    pub fn flush(self: *Device) DeviceError!void {
        try self.inner.flush();
    }

    pub fn shutdown(self: *Device) DeviceError!void {
        try self.inner.shutdown();
    }

    pub fn get_reader(self: *Device, allocator: std.mem.Allocator) DeviceError!DeviceStateReader {
        const reader = try self.inner.getReader(&inputs.process_input);
        return .{ .allocator = allocator, .inner = reader };
    }
};
