const std = @import("std");
const mappings = @import("mappings.zig");

const c = @cImport({
    @cInclude("turbojpeg.h");
});

pub const ImageError = error{
    InvalidDataUrl,
    InvalidMime,
    DecodeFailed,
    EncodeFailed,
    InvalidImage,
    OutOfMemory,
};

const DataUrlPrefix = "data:image/jpeg;base64,";

pub fn decode_data_url(allocator: std.mem.Allocator, data_url: []const u8) ![]u8 {
    if (!std.mem.startsWith(u8, data_url, DataUrlPrefix)) return ImageError.InvalidMime;
    const b64 = data_url[DataUrlPrefix.len..];

    const decoder = std.base64.standard.Decoder;
    const out_len = try decoder.calcSizeForSlice(b64);
    const out = try allocator.alloc(u8, out_len);
    errdefer allocator.free(out);
    try decoder.decode(out, b64);
    return out;
}

pub fn process_jpeg(allocator: std.mem.Allocator, format: mappings.ImageFormat, jpeg_bytes: []const u8) ![]u8 {
    var width: c_int = 0;
    var height: c_int = 0;
    var subsamp: c_int = 0;
    var colorspace: c_int = 0;

    const dec = c.tjInitDecompress() orelse return ImageError.DecodeFailed;
    defer _ = c.tjDestroy(dec);

    if (c.tjDecompressHeader3(dec, jpeg_bytes.ptr, @intCast(jpeg_bytes.len), &width, &height, &subsamp, &colorspace) != 0) {
        return ImageError.DecodeFailed;
    }

    const src_w: usize = @intCast(width);
    const src_h: usize = @intCast(height);
    if (src_w == 0 or src_h == 0) return ImageError.InvalidImage;

    const src_stride: usize = src_w * 3;
    const src_buf = try allocator.alloc(u8, src_stride * src_h);
    defer allocator.free(src_buf);

    if (c.tjDecompress2(
        dec,
        jpeg_bytes.ptr,
        @intCast(jpeg_bytes.len),
        src_buf.ptr,
        @intCast(src_w),
        @intCast(src_stride),
        @intCast(src_h),
        c.TJPF_RGB,
        c.TJFLAG_FASTDCT,
    ) != 0) {
        return ImageError.DecodeFailed;
    }

    const resized = try resize_nearest(allocator, src_buf, src_w, src_h, format.size.w, format.size.h);
    errdefer allocator.free(resized);

    const rotated = try apply_rotation(allocator, resized, format.size.w, format.size.h, format.rotation);
    if (rotated.ptr != resized.ptr) allocator.free(resized);
    errdefer allocator.free(rotated);

    const mirrored = try apply_mirror(allocator, rotated, format.size.w, format.size.h, format.mirror);
    if (mirrored.ptr != rotated.ptr) allocator.free(rotated);
    errdefer allocator.free(mirrored);

    const quality: c_int = 90;
    const dst_stride: usize = format.size.w * 3;

    const enc = c.tjInitCompress() orelse return ImageError.EncodeFailed;
    defer _ = c.tjDestroy(enc);

    var out_buf: [*c]u8 = null;
    var out_size: c_ulong = 0;
    if (c.tjCompress2(
        enc,
        mirrored.ptr,
        @intCast(format.size.w),
        @intCast(dst_stride),
        @intCast(format.size.h),
        c.TJPF_RGB,
        &out_buf,
        &out_size,
        c.TJSAMP_444,
        quality,
        c.TJFLAG_FASTDCT,
    ) != 0) {
        return ImageError.EncodeFailed;
    }
    defer c.tjFree(out_buf);

    const out = try allocator.alloc(u8, out_size);
    std.mem.copyForwards(u8, out, @as([*]u8, @ptrCast(out_buf))[0..out_size]);
    allocator.free(mirrored);
    return out;
}

fn resize_nearest(
    allocator: std.mem.Allocator,
    src: []const u8,
    src_w: usize,
    src_h: usize,
    dst_w: usize,
    dst_h: usize,
) ![]u8 {
    const dst = try allocator.alloc(u8, dst_w * dst_h * 3);

    var y: usize = 0;
    while (y < dst_h) : (y += 1) {
        const src_y = y * src_h / dst_h;
        var x: usize = 0;
        while (x < dst_w) : (x += 1) {
            const src_x = x * src_w / dst_w;
            const src_idx = (src_y * src_w + src_x) * 3;
            const dst_idx = (y * dst_w + x) * 3;
            dst[dst_idx] = src[src_idx];
            dst[dst_idx + 1] = src[src_idx + 1];
            dst[dst_idx + 2] = src[src_idx + 2];
        }
    }

    return dst;
}

fn apply_rotation(
    allocator: std.mem.Allocator,
    src: []const u8,
    width: usize,
    height: usize,
    rotation: mappings.ImageRotation,
) ![]u8 {
    if (rotation == .Rot0) return allocator.dupe(u8, src);

    const dst = try allocator.alloc(u8, width * height * 3);
    switch (rotation) {
        .Rot90 => {
            var y: usize = 0;
            while (y < height) : (y += 1) {
                var x: usize = 0;
                while (x < width) : (x += 1) {
                    const src_x = y;
                    const src_y = width - 1 - x;
                    const src_idx = (src_y * width + src_x) * 3;
                    const dst_idx = (y * width + x) * 3;
                    dst[dst_idx] = src[src_idx];
                    dst[dst_idx + 1] = src[src_idx + 1];
                    dst[dst_idx + 2] = src[src_idx + 2];
                }
            }
        },
        .Rot180 => {
            var y: usize = 0;
            while (y < height) : (y += 1) {
                var x: usize = 0;
                while (x < width) : (x += 1) {
                    const src_x = width - 1 - x;
                    const src_y = height - 1 - y;
                    const src_idx = (src_y * width + src_x) * 3;
                    const dst_idx = (y * width + x) * 3;
                    dst[dst_idx] = src[src_idx];
                    dst[dst_idx + 1] = src[src_idx + 1];
                    dst[dst_idx + 2] = src[src_idx + 2];
                }
            }
        },
        .Rot270 => {
            var y: usize = 0;
            while (y < height) : (y += 1) {
                var x: usize = 0;
                while (x < width) : (x += 1) {
                    const src_x = height - 1 - y;
                    const src_y = x;
                    const src_idx = (src_y * width + src_x) * 3;
                    const dst_idx = (y * width + x) * 3;
                    dst[dst_idx] = src[src_idx];
                    dst[dst_idx + 1] = src[src_idx + 1];
                    dst[dst_idx + 2] = src[src_idx + 2];
                }
            }
        },
        else => {},
    }

    return dst;
}

fn apply_mirror(
    allocator: std.mem.Allocator,
    src: []const u8,
    width: usize,
    height: usize,
    mirror: mappings.ImageMirroring,
) ![]u8 {
    if (mirror == .None) return allocator.dupe(u8, src);

    const dst = try allocator.alloc(u8, width * height * 3);
    var y: usize = 0;
    while (y < height) : (y += 1) {
        var x: usize = 0;
        while (x < width) : (x += 1) {
            var src_x = x;
            var src_y = y;
            if (mirror == .X or mirror == .Both) src_x = width - 1 - x;
            if (mirror == .Y or mirror == .Both) src_y = height - 1 - y;
            const src_idx = (src_y * width + src_x) * 3;
            const dst_idx = (y * width + x) * 3;
            dst[dst_idx] = src[src_idx];
            dst[dst_idx + 1] = src[src_idx + 1];
            dst[dst_idx + 2] = src[src_idx + 2];
        }
    }

    return dst;
}

test "decode data url prefix" {
    const allocator = std.testing.allocator;
    const encoder = std.base64.standard.Encoder;
    const b64_len = encoder.calcSize("hello".len);
    const b64 = try allocator.alloc(u8, b64_len);
    defer allocator.free(b64);
    _ = encoder.encode(b64, "hello");
    const data_url = try std.mem.concat(allocator, u8, &.{ DataUrlPrefix, b64 });
    defer allocator.free(data_url);

    const decoded = try decode_data_url(allocator, data_url);
    defer allocator.free(decoded);
    try std.testing.expect(std.mem.eql(u8, decoded, "hello"));
}

test "reject non-jpeg data url" {
    const allocator = std.testing.allocator;
    const bad = "data:image/png;base64,AA";
    try std.testing.expectError(ImageError.InvalidMime, decode_data_url(allocator, bad));
}
