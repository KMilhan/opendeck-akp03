const std = @import("std");
const opendeck = @import("opendeck.zig");
const mappings = @import("mappings.zig");
const watcher = @import("watcher.zig");
const image = @import("image.zig");

fn on_plugin_ready(_: *opendeck.OutboundEventManager) !void {
    watcher.init_registry(std.heap.page_allocator);
    _ = std.Thread.spawn(.{}, watcher.watcher_task, .{}) catch {};
}

fn on_set_brightness(event: opendeck.SetBrightnessEvent, _: *opendeck.OutboundEventManager) !void {
    _ = watcher.with_device(event.device, &event, on_set_brightness_entry) catch {};
}

fn on_set_image(event: opendeck.SetImageEvent, _: *opendeck.OutboundEventManager) !void {
    if (event.controller) |controller| {
        if (std.mem.eql(u8, controller, "Encoder")) return;
    }

    _ = watcher.with_device(event.device, &event, on_set_image_entry) catch {};
}

fn on_set_brightness_entry(entry: *watcher.DeviceEntry, ctx: ?*const anyopaque) anyerror!void {
    const event: *const opendeck.SetBrightnessEvent = @ptrCast(@alignCast(ctx.?));
    _ = entry.device.set_brightness(event.brightness) catch {};
}

fn on_set_image_entry(entry: *watcher.DeviceEntry, ctx: ?*const anyopaque) anyerror!void {
    const event: *const opendeck.SetImageEvent = @ptrCast(@alignCast(ctx.?));
    const allocator = std.heap.page_allocator;
    const dev = entry.device;

    if (event.position) |position| {
        const kind = mappings.kind_from_vid_pid(dev.vid, dev.pid) orelse return;

        if ((kind == .N3 or kind == .N3EN) and position >= 6) return;

        if (event.image) |img| {
            var fmt = mappings.kind_image_format(kind);
            if (dev.vid == mappings.MIRABOX_VID and dev.pid == mappings.N3_PID) {
                fmt.rotation = .Rot90;
            }

            const decoded = image.decode_data_url(allocator, img) catch return;
            defer allocator.free(decoded);
            const processed = image.process_jpeg(allocator, fmt, decoded) catch return;
            defer allocator.free(processed);

            _ = dev.set_button_image(position, fmt, processed) catch {};
            _ = dev.flush() catch {};
        } else {
            _ = dev.clear_button_image(position) catch {};
            _ = dev.flush() catch {};
        }
    } else if (event.image == null) {
        _ = dev.clear_all_button_images() catch {};
        _ = dev.flush() catch {};
    }
}

pub fn main() !void {
    const global = opendeck.GlobalEventHandler{
        .plugin_ready = on_plugin_ready,
        .set_image = on_set_image,
        .set_brightness = on_set_brightness,
    };

    const action = opendeck.ActionEventHandler{};
    try opendeck.init_plugin(global, action);
}
