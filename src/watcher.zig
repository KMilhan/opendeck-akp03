const std = @import("std");
const mappings = @import("mappings.zig");
const device = @import("device.zig");
const opendeck = @import("opendeck.zig");
const mirajazz = @import("mirajazz");

pub const DeviceEntry = struct {
    id: []const u8,
    device: *device.Device,
    cancel: *std.atomic.Value(bool),
    refcount: std.atomic.Value(u32),
    closing: std.atomic.Value(bool),
};

var registry_inited: bool = false;
var registry_allocator: std.mem.Allocator = undefined;
var registry_mutex = std.Thread.Mutex{};
var registry: std.StringHashMap(*DeviceEntry) = undefined;

pub fn init_registry(allocator: std.mem.Allocator) void {
    if (registry_inited) return;
    registry_allocator = allocator;
    registry = std.StringHashMap(*DeviceEntry).init(allocator);
    registry_inited = true;
}

pub fn with_device(id: []const u8, ctx: ?*const anyopaque, func: fn (*DeviceEntry, ?*const anyopaque) anyerror!void) !bool {
    var entry: *DeviceEntry = undefined;
    registry_mutex.lock();
    if (registry.get(id)) |found| {
        if (found.closing.load(.acquire)) {
            registry_mutex.unlock();
            return false;
        }
        _ = found.refcount.fetchAdd(1, .acq_rel);
        entry = found;
        registry_mutex.unlock();
    } else {
        registry_mutex.unlock();
        return false;
    }

    defer _ = entry.refcount.fetchSub(1, .acq_rel);
    try func(entry, ctx);
    return true;
}

pub fn mark_disconnected(id: []const u8) void {
    registry_mutex.lock();
    defer registry_mutex.unlock();
    if (registry.get(id)) |entry| {
        entry.cancel.store(true, .release);
    }
}

pub const WatcherError = error{ NotImplemented, MissingSerial, OutOfMemory };

pub const CandidateDevice = mappings.CandidateDevice;

const MirajazzQueries = blk: {
    var out: [mappings.QUERIES.len]mirajazz.device.DeviceQuery = undefined;
    for (mappings.QUERIES, 0..) |q, idx| {
        out[idx] = .{
            .usage_page = q.usage_page,
            .usage_id = q.usage_id,
            .vendor_id = q.vendor_id,
            .product_id = q.product_id,
        };
    }
    break :blk out;
};

pub fn device_id(allocator: std.mem.Allocator, dev: mappings.HidDeviceInfo) WatcherError![]u8 {
    const serial = dev.serial_number orelse return WatcherError.MissingSerial;

    if (dev.vendor_id == mappings.MIRABOX_VID and dev.product_id == mappings.N3_PID) {
        return try std.fmt.allocPrint(allocator, "{s}-6603-{s}", .{ mappings.DEVICE_NAMESPACE, serial });
    }

    return try std.fmt.allocPrint(allocator, "{s}-{s}", .{ mappings.DEVICE_NAMESPACE, serial });
}

pub fn device_info_to_candidate(allocator: std.mem.Allocator, dev: mappings.HidDeviceInfo) WatcherError!?CandidateDevice {
    const id = device_id(allocator, dev) catch return null;
    const kind = mappings.kind_from_vid_pid(dev.vendor_id, dev.product_id) orelse return null;
    const cloned = dev.clone(allocator) catch return WatcherError.NotImplemented;
    return CandidateDevice{ .id = id, .dev = cloned, .kind = kind };
}

pub fn watcher_task() WatcherError!void {
    const allocator = std.heap.page_allocator;
    init_registry(allocator);
    const outbound = opendeck.OUTBOUND_EVENT_MANAGER orelse return WatcherError.NotImplemented;

    var known = std.StringHashMap(void).init(allocator);
    defer known.deinit();

    while (true) {
        const devices = mirajazz.device.listDevices(allocator, &MirajazzQueries) catch return WatcherError.NotImplemented;
        defer {
            for (devices) |dev| dev.deinit(allocator);
            allocator.free(devices);
        }

        var current = std.StringHashMap(void).init(allocator);
        for (devices) |dev| {
            const mapped = mirajazzToMapping(allocator, dev) catch continue;
            defer {
                if (mapped.serial_number) |s| allocator.free(s);
                if (mapped.path) |p| allocator.free(p);
            }

            const cand_opt = device_info_to_candidate(allocator, mapped) catch continue;
            const cand = cand_opt orelse continue;
            _ = current.put(cand.id, {}) catch {};
            if (!known.contains(cand.id)) {
                _ = known.put(cand.id, {}) catch {};
                _ = std.Thread.spawn(.{}, device_task, .{ cand }) catch {};
            }
        }

        var it = known.iterator();
        while (it.next()) |entry| {
            if (!current.contains(entry.key_ptr.*)) {
                mark_disconnected(entry.key_ptr.*);
                _ = outbound.deregister_device(entry.key_ptr.*) catch {};
                _ = known.remove(entry.key_ptr.*);
            }
        }

        current.deinit();
        std.Thread.sleep(1 * std.time.ns_per_s);
    }
}

pub fn device_task(candidate: CandidateDevice) WatcherError!void {
    const allocator = std.heap.page_allocator;
    init_registry(allocator);

    var dev_ptr = try allocator.create(device.Device);
    errdefer allocator.destroy(dev_ptr);
    dev_ptr.* = device.Device.connect(allocator, candidate.dev, mappings.kind_protocol_version(candidate.kind), mappings.KEY_COUNT, mappings.ENCODER_COUNT) catch {
        allocator.destroy(dev_ptr);
        free_candidate_with_id(candidate);
        return WatcherError.NotImplemented;
    };

    const cancel = try allocator.create(std.atomic.Value(bool));
    cancel.* = std.atomic.Value(bool).init(false);
    errdefer allocator.destroy(cancel);

    const entry = try allocator.create(DeviceEntry);
    entry.* = DeviceEntry{
        .id = candidate.id,
        .device = dev_ptr,
        .cancel = cancel,
        .refcount = std.atomic.Value(u32).init(0),
        .closing = std.atomic.Value(bool).init(false),
    };
    errdefer allocator.destroy(entry);
    errdefer free_candidate_with_id(candidate);

    {
        registry_mutex.lock();
        defer registry_mutex.unlock();
        try registry.put(candidate.id, entry);
    }

    const outbound = opendeck.OUTBOUND_EVENT_MANAGER orelse return WatcherError.NotImplemented;
    _ = dev_ptr.set_brightness(50) catch {};
    _ = dev_ptr.clear_all_button_images() catch {};
    _ = dev_ptr.flush() catch {};

    _ = outbound.register_device(
        candidate.id,
        mappings.kind_human_name(candidate.kind),
        @intCast(mappings.ROW_COUNT),
        @intCast(mappings.COL_COUNT),
        @intCast(mappings.ENCODER_COUNT),
        0,
    ) catch {};

    var reader = dev_ptr.get_reader(allocator) catch return WatcherError.NotImplemented;
    defer reader.deinit();

    while (!cancel.load(.acquire)) {
        const updates = reader.read(allocator) catch {
            cancel.store(true, .release);
            break;
        };
        defer allocator.free(updates);

        if (updates.len == 0) {
            std.Thread.sleep(5 * std.time.ns_per_ms);
            continue;
        }

        for (updates) |update| {
            switch (update) {
                .ButtonDown => |key| _ = outbound.key_down(candidate.id, key) catch {},
                .ButtonUp => |key| _ = outbound.key_up(candidate.id, key) catch {},
                .EncoderDown => |enc| _ = outbound.encoder_down(candidate.id, enc) catch {},
                .EncoderUp => |enc| _ = outbound.encoder_up(candidate.id, enc) catch {},
                .EncoderTwist => |tw| _ = outbound.encoder_change(candidate.id, tw.encoder, tw.delta) catch {},
            }
        }
    }

    _ = dev_ptr.shutdown() catch {};
    _ = outbound.deregister_device(candidate.id) catch {};

    remove_entry(candidate.id);
    free_candidate(candidate);
}

fn remove_entry(id: []const u8) void {
    var entry: *DeviceEntry = undefined;
    registry_mutex.lock();
    const removed = registry.fetchRemove(id) orelse {
        registry_mutex.unlock();
        return;
    };
    entry = removed.value;
    entry.closing.store(true, .release);
    registry_mutex.unlock();

    while (entry.refcount.load(.acquire) != 0) {
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }

    registry_allocator.free(removed.key);
    entry.device.deinit();
    registry_allocator.destroy(entry.device);
    registry_allocator.destroy(entry.cancel);
    registry_allocator.destroy(entry);
}

fn free_candidate(candidate: CandidateDevice) void {
    candidate.dev.deinit(registry_allocator);
}

fn free_candidate_with_id(candidate: CandidateDevice) void {
    registry_allocator.free(candidate.id);
    free_candidate(candidate);
}

fn mirajazzToMapping(allocator: std.mem.Allocator, dev: mirajazz.types.HidDeviceInfo) WatcherError!mappings.HidDeviceInfo {
    const path = std.mem.sliceTo(dev.path, 0);
    const path_copy = allocator.dupe(u8, path) catch return WatcherError.OutOfMemory;
    const serial_copy = if (dev.serial_number) |serial|
        allocator.dupe(u8, serial) catch return WatcherError.OutOfMemory
    else
        null;

    return .{
        .vendor_id = dev.vendor_id,
        .product_id = dev.product_id,
        .usage_page = dev.usage_page,
        .usage_id = dev.usage,
        .serial_number = serial_copy,
        .path = path_copy,
    };
}
