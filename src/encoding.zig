//! One entry point for every format, for tools that pick the format at run
//! time, such as a bake step driven by import settings, and for encoding an
//! image on several threads.

const std = @import("std");
const assert = std.debug.assert;
const image = @import("image.zig");
const bc1 = @import("bc1.zig");
const bc3 = @import("bc3.zig");
const bc4 = @import("bc4.zig");
const bc5 = @import("bc5.zig");
const bc6h = @import("bc6h.zig");
const bc7 = @import("bc7.zig");

pub const Bc6h = struct {
    format: bc6h.Format = .unsigned,
    /// `.fast` is texcomp's encoder byte for byte; `.high` is zig-bcn's own
    /// search, for skies, environment maps and other smooth HDR.
    quality: bc6h.Quality = .fast,
};

/// A format with its encoder settings.
pub const Encoding = union(enum) {
    bc1: bc1.Settings,
    bc3: bc3.Settings,
    bc4,
    bc5,
    bc6h: Bc6h,
    bc7: bc7.Params,

    pub fn blockBytes(encoding: *const Encoding) u32 {
        return switch (encoding.*) {
            .bc1 => bc1.block_bytes,
            .bc3 => bc3.block_bytes,
            .bc4 => bc4.block_bytes,
            .bc5 => bc5.block_bytes,
            .bc6h => bc6h.block_bytes,
            .bc7 => bc7.block_bytes,
        };
    }

    pub fn encodedLen(encoding: *const Encoding, width: u32, height: u32) usize {
        return image.encodedLen(encoding.blockBytes(), width, height);
    }

    /// The pixels each format reads: floats for BC6H, bytes for the rest.
    pub fn sourceKind(encoding: *const Encoding) std.meta.Tag(Source) {
        return switch (encoding.*) {
            .bc6h => .float32,
            else => .unorm8,
        };
    }

    /// The VkFormat of the encoded blocks, or null when the format has no
    /// sRGB variant (BC4, BC5, BC6H) and `srgb` asks for one. BC1 blocks are
    /// opaque, so they are the RGB variant.
    pub fn vulkanFormat(encoding: *const Encoding, srgb: bool) ?u32 {
        const linear_and_srgb: [2]?u32 = switch (encoding.*) {
            .bc1 => .{ 131, 132 }, // VK_FORMAT_BC1_RGB_UNORM_BLOCK, _SRGB_BLOCK
            .bc3 => .{ 137, 138 }, // VK_FORMAT_BC3_UNORM_BLOCK, _SRGB_BLOCK
            .bc4 => .{ 139, null }, // VK_FORMAT_BC4_UNORM_BLOCK
            .bc5 => .{ 141, null }, // VK_FORMAT_BC5_UNORM_BLOCK
            .bc6h => |o| switch (o.format) {
                .unsigned => .{ 143, null }, // VK_FORMAT_BC6H_UFLOAT_BLOCK
                .signed => .{ 144, null }, // VK_FORMAT_BC6H_SFLOAT_BLOCK
            },
            .bc7 => .{ 145, 146 }, // VK_FORMAT_BC7_UNORM_BLOCK, _SRGB_BLOCK
        };
        return linear_and_srgb[@intFromBool(srgb)];
    }

    /// The DXGI_FORMAT of the encoded blocks, as `vulkanFormat`.
    pub fn dxgiFormat(encoding: *const Encoding, srgb: bool) ?u32 {
        const linear_and_srgb: [2]?u32 = switch (encoding.*) {
            .bc1 => .{ 71, 72 }, // DXGI_FORMAT_BC1_UNORM, _UNORM_SRGB
            .bc3 => .{ 77, 78 }, // DXGI_FORMAT_BC3_UNORM, _UNORM_SRGB
            .bc4 => .{ 80, null }, // DXGI_FORMAT_BC4_UNORM
            .bc5 => .{ 83, null }, // DXGI_FORMAT_BC5_UNORM
            .bc6h => |o| switch (o.format) {
                .unsigned => .{ 95, null }, // DXGI_FORMAT_BC6H_UF16
                .signed => .{ 96, null }, // DXGI_FORMAT_BC6H_SF16
            },
            .bc7 => .{ 98, 99 }, // DXGI_FORMAT_BC7_UNORM, _UNORM_SRGB
        };
        return linear_and_srgb[@intFromBool(srgb)];
    }
};

/// The pixels to encode.
pub const Source = union(enum) {
    unorm8: image.Image(u8),
    float32: image.Image(f32),

    pub fn height(source: Source) u32 {
        return switch (source) {
            inline else => |s| s.height,
        };
    }

    pub fn width(source: Source) u32 {
        return switch (source) {
            inline else => |s| s.width,
        };
    }
};

/// Where to decode to: bytes for BC1 to BC5 and BC7; half-float bits or
/// floats for BC6H.
pub const Destination = union(enum) {
    unorm8: image.ImageMut(u8),
    half: image.ImageMut(u16),
    float32: image.ImageMut(f32),

    pub fn height(destination: Destination) u32 {
        return switch (destination) {
            inline else => |d| d.height,
        };
    }
};

/// Encodes all of `src` into `dst`, which must hold
/// `encoding.encodedLen(width, height)` bytes.
pub fn encodeImage(encoding: *const Encoding, src: Source, dst: []u8) void {
    encodeImageRows(encoding, src, dst, image.BlockRows.all(src.height()));
}

/// Encodes the block rows `rows` of `src` into their place in `dst`.
pub fn encodeImageRows(encoding: *const Encoding, src: Source, dst: []u8, rows: image.BlockRows) void {
    assert(std.meta.activeTag(src) == encoding.sourceKind());
    assert(dst.len >= encoding.encodedLen(src.width(), src.height()));
    switch (encoding.*) {
        .bc1 => |settings| bc1.encodeImageRows(src.unorm8, dst, settings, rows),
        .bc3 => |settings| bc3.encodeImageRows(src.unorm8, dst, settings, rows),
        .bc4 => bc4.encodeImageRows(src.unorm8, dst, rows),
        .bc5 => bc5.encodeImageRows(src.unorm8, dst, rows),
        .bc6h => |o| bc6h.encodeImageQualityRows(src.float32, dst, o.format, o.quality, rows),
        .bc7 => |*params| bc7.encodeImageRows(src.unorm8, dst, params, rows),
    }
}

/// Encodes `src` with up to one task per band of `band_rows` block rows,
/// run by `io` (std.Io.Threaded runs them on a thread pool). The bytes are
/// the same as `encodeImage`'s whatever the band size or thread count, since
/// every block is encoded on its own.
pub fn encodeImageParallel(io: std.Io, encoding: *const Encoding, src: Source, dst: []u8, band_rows: u32) std.Io.Cancelable!void {
    assert(band_rows > 0);
    assert(dst.len >= encoding.encodedLen(src.width(), src.height()));
    const total = image.blocksHigh(src.height());
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    var first: u32 = 0;
    while (first < total) : (first += band_rows) {
        const rows: image.BlockRows = .{ .first = first, .count = @min(band_rows, total - first) };
        group.async(io, encodeImageRows, .{ encoding, src, dst, rows });
    }
    try group.await(io);
}

/// Decodes all of `src`, encoded with `encoding`, into `dst`, which has the
/// size of the encoded image. BC4 writes channel 0 and BC5 channels 0 and 1,
/// leaving the others as they were.
pub fn decodeImage(encoding: *const Encoding, src: []const u8, dst: Destination) void {
    decodeImageRows(encoding, src, dst, image.BlockRows.all(dst.height()));
}

/// Decodes the block rows `rows` of `src` into `dst`.
pub fn decodeImageRows(encoding: *const Encoding, src: []const u8, dst: Destination, rows: image.BlockRows) void {
    switch (encoding.*) {
        .bc1 => bc1.decodeImageRows(src, dst.unorm8, rows),
        .bc3 => bc3.decodeImageRows(src, dst.unorm8, rows),
        .bc4 => bc4.decodeImageRows(src, dst.unorm8, rows),
        .bc5 => bc5.decodeImageRows(src, dst.unorm8, rows),
        .bc6h => |o| switch (dst) {
            .half => |d| bc6h.decodeImageRows(src, d, o.format, rows),
            .float32 => |d| bc6h.decodeImageF32Rows(src, d, o.format, rows),
            .unorm8 => unreachable, // BC6H decodes to half floats or floats
        },
        .bc7 => bc7.decodeImageRows(src, dst.unorm8, rows),
    }
}

test "format numbers" {
    const bc7_srgb: Encoding = .{ .bc7 = bc7.Params.init(.basic, true) };
    try std.testing.expectEqual(@as(?u32, 146), bc7_srgb.vulkanFormat(true));
    try std.testing.expectEqual(@as(?u32, 98), bc7_srgb.dxgiFormat(false));
    const normals: Encoding = .bc5;
    try std.testing.expectEqual(@as(?u32, null), normals.vulkanFormat(true));
    const hdr: Encoding = .{ .bc6h = .{ .format = .signed } };
    try std.testing.expectEqual(@as(?u32, 144), hdr.vulkanFormat(false));
    try std.testing.expectEqual(@as(u32, 16), hdr.blockBytes());
}
