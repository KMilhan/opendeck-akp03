const std = @import("std");

pub const SetImageEvent = struct {
    device: []const u8,
    controller: ?[]const u8 = null,
    position: ?u8 = null,
    image: ?[]const u8 = null,
};

pub const SetBrightnessEvent = struct {
    device: []const u8,
    brightness: u8,
};

pub const GlobalEventHandler = struct {
    plugin_ready: ?*const fn (*OutboundEventManager) anyerror!void = null,
    set_image: ?*const fn (SetImageEvent, *OutboundEventManager) anyerror!void = null,
    set_brightness: ?*const fn (SetBrightnessEvent, *OutboundEventManager) anyerror!void = null,
};

pub const ActionEventHandler = struct {
    key_down: ?*const fn () anyerror!void = null,
    key_up: ?*const fn () anyerror!void = null,
    dial_down: ?*const fn () anyerror!void = null,
    dial_up: ?*const fn () anyerror!void = null,
    dial_rotate: ?*const fn () anyerror!void = null,
};

pub var OUTBOUND_EVENT_MANAGER: ?*OutboundEventManager = null;

const RegisterEvent = struct {
    event: []const u8,
    uuid: []const u8,
};

const PressPayload = struct {
    device: []const u8,
    position: u8,
};

const TicksPayload = struct {
    device: []const u8,
    position: u8,
    ticks: i16,
};

const DeviceInfo = struct {
    id: []const u8,
    name: []const u8,
    rows: u8,
    columns: u8,
    encoders: u8,
    @"type": u8,
};

fn send_payload_event(self: *OutboundEventManager, event_name: []const u8, payload: anytype) !void {
    const PayloadEvent = struct {
        event: []const u8,
        payload: @TypeOf(payload),
    };

    const json_bytes = try std.json.Stringify.valueAlloc(self.allocator, PayloadEvent{ .event = event_name, .payload = payload }, .{});
    defer self.allocator.free(json_bytes);
    try self.ws.writeText(json_bytes);
}

pub const OutboundEventManager = struct {
    allocator: std.mem.Allocator,
    ws: WebSocketClient,

    pub fn register(self: *OutboundEventManager, event: []const u8, uuid: []const u8) !void {
        const json_bytes = try std.json.Stringify.valueAlloc(self.allocator, RegisterEvent{ .event = event, .uuid = uuid }, .{});
        defer self.allocator.free(json_bytes);
        try self.ws.writeText(json_bytes);
    }

    pub fn register_device(
        self: *OutboundEventManager,
        id: []const u8,
        name: []const u8,
        rows: u8,
        columns: u8,
        encoders: u8,
        device_type: u8,
    ) !void {
        try send_payload_event(self, "registerDevice", DeviceInfo{
            .id = id,
            .name = name,
            .rows = rows,
            .columns = columns,
            .encoders = encoders,
            .@"type" = device_type,
        });
    }

    pub fn deregister_device(self: *OutboundEventManager, id: []const u8) !void {
        try send_payload_event(self, "deregisterDevice", id);
    }

    pub fn key_down(self: *OutboundEventManager, device: []const u8, position: u8) !void {
        try send_payload_event(self, "keyDown", PressPayload{ .device = device, .position = position });
    }

    pub fn key_up(self: *OutboundEventManager, device: []const u8, position: u8) !void {
        try send_payload_event(self, "keyUp", PressPayload{ .device = device, .position = position });
    }

    pub fn encoder_down(self: *OutboundEventManager, device: []const u8, position: u8) !void {
        try send_payload_event(self, "encoderDown", PressPayload{ .device = device, .position = position });
    }

    pub fn encoder_up(self: *OutboundEventManager, device: []const u8, position: u8) !void {
        try send_payload_event(self, "encoderUp", PressPayload{ .device = device, .position = position });
    }

    pub fn encoder_change(self: *OutboundEventManager, device: []const u8, position: u8, ticks: i16) !void {
        try send_payload_event(self, "encoderChange", TicksPayload{ .device = device, .position = position, .ticks = ticks });
    }
};

const CliArgs = struct {
    args: []const [:0]u8,
    port: u16,
    uuid: []const u8,
    event: []const u8,

    pub fn deinit(self: *CliArgs, allocator: std.mem.Allocator) void {
        std.process.argsFree(allocator, self.args);
    }
};

fn parse_args(allocator: std.mem.Allocator) !CliArgs {
    const args = try std.process.argsAlloc(allocator);
    errdefer std.process.argsFree(allocator, args);

    var port: ?u16 = null;
    var uuid: ?[]const u8 = null;
    var event: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = std.mem.sliceTo(args[i], 0);
        if (std.ascii.eqlIgnoreCase(arg, "-port")) {
            if (i + 1 >= args.len) return error.MissingArgument;
            port = try std.fmt.parseInt(u16, std.mem.sliceTo(args[i + 1], 0), 10);
            i += 1;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(arg, "-pluginuuid")) {
            if (i + 1 >= args.len) return error.MissingArgument;
            uuid = std.mem.sliceTo(args[i + 1], 0);
            i += 1;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(arg, "-registerevent")) {
            if (i + 1 >= args.len) return error.MissingArgument;
            event = std.mem.sliceTo(args[i + 1], 0);
            i += 1;
            continue;
        }
    }

    return CliArgs{
        .args = args,
        .port = port orelse return error.MissingArgument,
        .uuid = uuid orelse return error.MissingArgument,
        .event = event orelse return error.MissingArgument,
    };
}

const InboundEvent = union(enum) {
    SetImage: SetImageEvent,
    SetBrightness: SetBrightnessEvent,
    Unknown,
};

const OwnedInboundEvent = struct {
    arena: std.heap.ArenaAllocator,
    event: InboundEvent,

    pub fn deinit(self: *OwnedInboundEvent) void {
        self.arena.deinit();
    }
};

fn parse_inbound_event(allocator: std.mem.Allocator, text: []const u8) !OwnedInboundEvent {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), text, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return OwnedInboundEvent{ .arena = arena, .event = InboundEvent.Unknown };
    const obj = root.object;

    const event_val = obj.get("event") orelse return OwnedInboundEvent{ .arena = arena, .event = InboundEvent.Unknown };
    if (event_val != .string) return OwnedInboundEvent{ .arena = arena, .event = InboundEvent.Unknown };
    const event_name = event_val.string;

    if (std.mem.eql(u8, event_name, "setImage")) {
        const device_val = obj.get("device") orelse return error.InvalidJson;
        if (device_val != .string) return error.InvalidJson;

        const controller = switch (obj.get("controller") orelse .null) {
            .string => |s| s,
            .null => null,
            else => null,
        };

        const position = switch (obj.get("position") orelse .null) {
            .integer => |v| try int_to_u8(v),
            .null => null,
            else => null,
        };

        const image = switch (obj.get("image") orelse .null) {
            .string => |s| s,
            .null => null,
            else => null,
        };

        return OwnedInboundEvent{ .arena = arena, .event = InboundEvent{ .SetImage = .{
            .device = device_val.string,
            .controller = controller,
            .position = position,
            .image = image,
        } } };
    }

    if (std.mem.eql(u8, event_name, "setBrightness")) {
        const device_val = obj.get("device") orelse return error.InvalidJson;
        if (device_val != .string) return error.InvalidJson;
        const brightness_val = obj.get("brightness") orelse return error.InvalidJson;
        if (brightness_val != .integer) return error.InvalidJson;
        const brightness = try int_to_u8(brightness_val.integer);
        return OwnedInboundEvent{ .arena = arena, .event = InboundEvent{ .SetBrightness = .{ .device = device_val.string, .brightness = brightness } } };
    }

    return OwnedInboundEvent{ .arena = arena, .event = InboundEvent.Unknown };
}

pub fn init_plugin(global: GlobalEventHandler, action: ActionEventHandler) !void {
    _ = action;
    const allocator = std.heap.page_allocator;

    var args = try parse_args(allocator);
    defer args.deinit(allocator);

    const ws = try WebSocketClient.connect(allocator, "localhost", args.port);
    var outbound_ptr = try allocator.create(OutboundEventManager);
    outbound_ptr.* = OutboundEventManager{ .allocator = allocator, .ws = ws };
    OUTBOUND_EVENT_MANAGER = outbound_ptr;

    try outbound_ptr.register(args.event, args.uuid);

    if (global.plugin_ready) |cb| {
        try cb(outbound_ptr);
    }

    while (true) {
        const msg = try outbound_ptr.ws.readMessage();
        defer allocator.free(msg.data);

        switch (msg.opcode) {
            .text => {
                var decoded = try parse_inbound_event(allocator, msg.data);
                defer decoded.deinit();
                switch (decoded.event) {
                    .SetImage => |ev| if (global.set_image) |cb| try cb(ev, outbound_ptr),
                    .SetBrightness => |ev| if (global.set_brightness) |cb| try cb(ev, outbound_ptr),
                    else => {},
                }
            },
            .ping => try outbound_ptr.ws.writePong(msg.data),
            .close => break,
            else => {},
        }
    }
}

const WebSocketMessage = struct {
    opcode: Opcode,
    data: []u8,
};

const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
};

const WebSocketClient = struct {
    allocator: std.mem.Allocator,
    stream: std.net.Stream,

    pub fn connect(allocator: std.mem.Allocator, host: []const u8, port: u16) !WebSocketClient {
        var stream = try std.net.tcpConnectToHost(allocator, host, port);

        var key_raw: [16]u8 = undefined;
        std.crypto.random.bytes(&key_raw);
        var key_b64_buf: [32]u8 = undefined;
        const key_b64 = std.base64.standard.Encoder.encode(&key_b64_buf, &key_raw);

        var req_buf = std.ArrayList(u8).empty;
        defer req_buf.deinit(allocator);
        try req_buf.writer(allocator).print(
            "GET / HTTP/1.1\r\nHost: {s}:{d}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n\r\n",
            .{ host, port, key_b64 },
        );
        try stream.writeAll(req_buf.items);

        const headers = try read_headers(allocator, stream);
        defer allocator.free(headers);

        var lines = std.mem.splitSequence(u8, headers, "\r\n");
        const status_line = lines.next() orelse return error.HandshakeFailed;
        if (std.mem.indexOf(u8, status_line, "101") == null) return error.HandshakeFailed;

        var accept_header: ?[]const u8 = null;
        while (lines.next()) |line| {
            if (line.len == 0) break;
            const colon_index = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const name = std.mem.trim(u8, line[0..colon_index], " \t");
            const value = std.mem.trim(u8, line[colon_index + 1 ..], " \t");
            if (std.ascii.eqlIgnoreCase(name, "sec-websocket-accept")) {
                accept_header = value;
            }
        }

        const accept = accept_header orelse return error.HandshakeFailed;
        var accept_buf: [64]u8 = undefined;
        const expected = compute_accept(&accept_buf, key_b64);
        if (!std.mem.eql(u8, accept, expected)) return error.HandshakeFailed;

        return WebSocketClient{ .allocator = allocator, .stream = stream };
    }

    pub fn writeText(self: *WebSocketClient, data: []const u8) !void {
        try self.writeFrame(.text, data);
    }

    pub fn writePong(self: *WebSocketClient, data: []const u8) !void {
        try self.writeFrame(.pong, data);
    }

    fn writeFrame(self: *WebSocketClient, opcode: Opcode, data: []const u8) !void {
        var header: [14]u8 = undefined;
        var header_len: usize = 0;

        header[0] = 0x80 | @as(u8, @intFromEnum(opcode));

        if (data.len <= 125) {
            header[1] = 0x80 | @as(u8, @intCast(data.len));
            header_len = 2;
        } else if (data.len <= 0xFFFF) {
            header[1] = 0x80 | 126;
            header[2] = @as(u8, @intCast((data.len >> 8) & 0xFF));
            header[3] = @as(u8, @intCast(data.len & 0xFF));
            header_len = 4;
        } else {
            return error.UnsupportedFrame;
        }

        var mask_key: [4]u8 = undefined;
        std.crypto.random.bytes(&mask_key);
        std.mem.copyForwards(u8, header[header_len .. header_len + 4], &mask_key);
        header_len += 4;

        var masked = try self.allocator.alloc(u8, data.len);
        defer self.allocator.free(masked);
        for (data, 0..) |b, i| {
            masked[i] = b ^ mask_key[i % 4];
        }

        try self.stream.writeAll(header[0..header_len]);
        try self.stream.writeAll(masked);
    }

    pub fn readMessage(self: *WebSocketClient) !WebSocketMessage {
        var header: [2]u8 = undefined;
        try read_exact(self.stream, &header);

        const fin = (header[0] & 0x80) != 0;
        const opcode = @as(Opcode, @enumFromInt(header[0] & 0x0F));
        const masked = (header[1] & 0x80) != 0;
        var length: usize = header[1] & 0x7F;

        if (length == 126) {
            var ext: [2]u8 = undefined;
            try read_exact(self.stream, &ext);
            length = (@as(usize, ext[0]) << 8) | ext[1];
        } else if (length == 127) {
            return error.UnsupportedFrame;
        }

        var mask_key: [4]u8 = .{ 0, 0, 0, 0 };
        if (masked) {
            try read_exact(self.stream, &mask_key);
        }

        const payload = try self.allocator.alloc(u8, length);
        try read_exact(self.stream, payload);
        if (masked) {
            for (payload, 0..) |*b, i| {
                b.* ^= mask_key[i % 4];
            }
        }

        if (!fin and opcode == .text) return error.UnsupportedFrame;
        return WebSocketMessage{ .opcode = opcode, .data = payload };
    }
};

fn read_headers(allocator: std.mem.Allocator, stream: std.net.Stream) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    var window: [4]u8 = .{ 0, 0, 0, 0 };
    while (true) {
        var byte: [1]u8 = undefined;
        const n = try stream.read(&byte);
        if (n == 0) return error.HandshakeFailed;
        try buf.append(allocator, byte[0]);
        window[0] = window[1];
        window[1] = window[2];
        window[2] = window[3];
        window[3] = byte[0];
        if (std.mem.eql(u8, &window, "\r\n\r\n")) break;
    }
    return buf.toOwnedSlice(allocator);
}

fn compute_accept(out: []u8, key: []const u8) []const u8 {
    const guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    var sha1 = std.crypto.hash.Sha1.init(.{});
    sha1.update(key);
    sha1.update(guid);
    var digest: [20]u8 = undefined;
    sha1.final(&digest);
    return std.base64.standard.Encoder.encode(out, &digest);
}

fn read_exact(stream: std.net.Stream, buf: []u8) !void {
    var filled: usize = 0;
    while (filled < buf.len) {
        const n = try stream.read(buf[filled..]);
        if (n == 0) return error.EndOfStream;
        filled += n;
    }
}

fn int_to_u8(value: i64) !u8 {
    if (value < 0 or value > 255) return error.InvalidJson;
    return @intCast(value);
}

test "encode registerDevice payload" {
    const gpa = std.heap.page_allocator;
    const ws = WebSocketClient{ .allocator = gpa, .stream = undefined };
    const mgr = OutboundEventManager{ .allocator = gpa, .ws = ws };

    const payload = DeviceInfo{
        .id = "id",
        .name = "name",
        .rows = 3,
        .columns = 3,
        .encoders = 3,
        .@"type" = 0,
    };

    const PayloadEvent = struct {
        event: []const u8,
        payload: DeviceInfo,
    };

    const json_bytes = try std.json.Stringify.valueAlloc(gpa, PayloadEvent{ .event = "registerDevice", .payload = payload }, .{});
    defer gpa.free(json_bytes);

    try std.testing.expect(std.mem.eql(u8, json_bytes, "{\"event\":\"registerDevice\",\"payload\":{\"id\":\"id\",\"name\":\"name\",\"rows\":3,\"columns\":3,\"encoders\":3,\"type\":0}}"));
    _ = mgr;
}

test "decode setImage and setBrightness" {
    const allocator = std.heap.page_allocator;

    const set_image = "{\"event\":\"setImage\",\"device\":\"dev\",\"controller\":\"Keypad\",\"position\":2,\"image\":\"data\"}";
    var ev1 = try parse_inbound_event(allocator, set_image);
    defer ev1.deinit();
    switch (ev1.event) {
        .SetImage => |ev| {
            try std.testing.expect(std.mem.eql(u8, ev.device, "dev"));
            try std.testing.expect(ev.position.? == 2);
            try std.testing.expect(std.mem.eql(u8, ev.image.?, "data"));
        },
        else => return error.UnexpectedResult,
    }

    const set_brightness = "{\"event\":\"setBrightness\",\"device\":\"dev\",\"brightness\":42}";
    var ev2 = try parse_inbound_event(allocator, set_brightness);
    defer ev2.deinit();
    switch (ev2.event) {
        .SetBrightness => |ev| try std.testing.expect(ev.brightness == 42),
        else => return error.UnexpectedResult,
    }
}
