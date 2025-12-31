const std = @import("std");

pub const DeviceNamespace = "n3";

pub const MiraboxVid: u16 = 0x6603;
pub const N3Pid: u16 = 0x1002;

pub const UsagePage: u16 = 65440;
pub const UsageId: u16 = 1;

pub const DeviceQuery = struct {
    usage_page: u16,
    usage_id: u16,
    vid: u16,
    pid: u16,

    pub fn init(usage_page: u16, usage_id: u16, vid: u16, pid: u16) DeviceQuery {
        return .{
            .usage_page = usage_page,
            .usage_id = usage_id,
            .vid = vid,
            .pid = pid,
        };
    }
};

pub const MiraboxN3Query = DeviceQuery.init(UsagePage, UsageId, MiraboxVid, N3Pid);

pub const ImageMode = enum {
    jpeg,
};

pub const ImageRotation = enum {
    rot0,
    rot90,
};

pub const ImageMirroring = enum {
    none,
};

pub const ImageFormat = struct {
    mode: ImageMode,
    size: [2]u16,
    rotation: ImageRotation,
    mirror: ImageMirroring,
};

pub const Kind = enum {
    MiraboxN3,

    pub fn humanName(self: Kind) []const u8 {
        return switch (self) {
            .MiraboxN3 => "Mirabox N3 (0x6603)",
        };
    }

    pub fn protocolVersion(self: Kind) u8 {
        return switch (self) {
            .MiraboxN3 => 3,
        };
    }

    pub fn imageFormat(self: Kind) ImageFormat {
        return switch (self) {
            .MiraboxN3 => .{
                .mode = .jpeg,
                .size = .{ 60, 60 },
                .rotation = .rot90,
                .mirror = .none,
            },
        };
    }
};

pub const DeviceInfo = struct {
    vendor_id: u16,
    product_id: u16,
    serial_number: ?[]const u8,
};

pub fn deviceId(dev: DeviceInfo, allocator: std.mem.Allocator) ![]const u8 {
    const serial = dev.serial_number orelse return error.MissingSerial;

    if (dev.vendor_id == MiraboxVid and dev.product_id == N3Pid) {
        return std.fmt.allocPrint(allocator, "{s}-6603-{s}", .{ DeviceNamespace, serial });
    }

    return std.fmt.allocPrint(allocator, "{s}-{s}", .{ DeviceNamespace, serial });
}

pub const UdevUsbRule =
    "SUBSYSTEM==\"usb\", ATTRS{idVendor}==\"6603\", ATTRS{idProduct}==\"1002\", MODE=\"0660\", TAG+=\"uaccess\"";

pub const UdevHidrawRule =
    "KERNEL==\"hidraw*\", SUBSYSTEM==\"hidraw\", ATTRS{idVendor}==\"6603\", ATTRS{idProduct}==\"1002\", MODE=\"0660\", TAG+=\"uaccess\"";

pub const ManifestName = "Ajazz AKP03 / Mirabox N3";
