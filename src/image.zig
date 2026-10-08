//! Image views and the 4x4 block walk shared by every format.

const std = @import("std");
const assert = std.debug.assert;

/// A read-only view of an image whose pixels hold `channels` values of type
/// `T` each. `stride` counts elements of `T` between the starts of rows, so a
/// view can cover part of a larger image.
pub fn Image(comptime T: type) type {
    return struct {
        pixels: []const T,
        width: u32,
        height: u32,
        stride: u32,
        channels: u8,

        const Self = @This();

        /// A view of tightly packed rows.
        pub fn init(pixels: []const T, width: u32, height: u32, channels: u8) Self {
            const self: Self = .{ .pixels = pixels, .width = width, .height = height, .stride = width * channels, .channels = channels };
            self.check();
            return self;
        }

        pub fn check(self: Self) void {
            assert(self.width > 0 and self.height > 0);
            assert(self.channels >= 1 and self.channels <= 4);
            assert(self.stride >= self.width * self.channels);
            assert(self.pixels.len >= @as(usize, self.height - 1) * self.stride + @as(usize, self.width) * self.channels);
        }

        /// The first `n` channels of the 4x4 block at block coordinates
        /// (bx, by), in row-major order. Pixels past the right or bottom edge
        /// repeat the last column or row.
        pub fn block(self: Self, comptime n: u8, bx: u32, by: u32) [16][n]T {
            assert(n <= self.channels);
            assert(bx * 4 < self.width and by * 4 < self.height);
            var out: [16][n]T = undefined;
            for (0..4) |yy| {
                const y = @min(by * 4 + @as(u32, @intCast(yy)), self.height - 1);
                for (0..4) |xx| {
                    const x = @min(bx * 4 + @as(u32, @intCast(xx)), self.width - 1);
                    const at = @as(usize, y) * self.stride + @as(usize, x) * self.channels;
                    out[yy * 4 + xx] = self.pixels[at..][0..n].*;
                }
            }
            return out;
        }
    };
}

/// A writable view; see `Image`.
pub fn ImageMut(comptime T: type) type {
    return struct {
        pixels: []T,
        width: u32,
        height: u32,
        stride: u32,
        channels: u8,

        const Self = @This();

        pub fn init(pixels: []T, width: u32, height: u32, channels: u8) Self {
            const self: Self = .{ .pixels = pixels, .width = width, .height = height, .stride = width * channels, .channels = channels };
            self.check();
            return self;
        }

        pub fn check(self: Self) void {
            assert(self.width > 0 and self.height > 0);
            assert(self.channels >= 1 and self.channels <= 4);
            assert(self.stride >= self.width * self.channels);
            assert(self.pixels.len >= @as(usize, self.height - 1) * self.stride + @as(usize, self.width) * self.channels);
        }

        /// Writes the first `n` channels of a decoded block, clipped to the
        /// image; other channels are left as they were.
        pub fn putBlock(self: Self, comptime n: u8, bx: u32, by: u32, values: *const [16][n]T) void {
            assert(n <= self.channels);
            assert(bx * 4 < self.width and by * 4 < self.height);
            for (0..4) |yy| {
                const y = by * 4 + @as(u32, @intCast(yy));
                if (y >= self.height) break;
                for (0..4) |xx| {
                    const x = bx * 4 + @as(u32, @intCast(xx));
                    if (x >= self.width) break;
                    const at = @as(usize, y) * self.stride + @as(usize, x) * self.channels;
                    self.pixels[at..][0..n].* = values[yy * 4 + xx];
                }
            }
        }
    };
}

pub fn blocksWide(width: u32) u32 {
    assert(width > 0);
    return (width + 3) / 4;
}

pub fn blocksHigh(height: u32) u32 {
    return blocksWide(height);
}

/// Bytes of compressed data for a `width` by `height` image whose blocks
/// take `block_bytes` each.
pub fn encodedLen(block_bytes: u32, width: u32, height: u32) usize {
    assert(block_bytes == 8 or block_bytes == 16);
    return @as(usize, blocksWide(width)) * blocksHigh(height) * block_bytes;
}

/// Encodes every block of `src` into `dst` in row-major block order with
/// `encode(context, bx, by) [block_bytes]u8`.
pub fn encodeBlocks(
    comptime block_bytes: u32,
    width: u32,
    height: u32,
    dst: []u8,
    context: anytype,
    comptime encode: fn (@TypeOf(context), u32, u32) [block_bytes]u8,
) void {
    const len = encodedLen(block_bytes, width, height);
    assert(dst.len >= len);
    var at: usize = 0;
    for (0..blocksHigh(height)) |by| {
        for (0..blocksWide(width)) |bx| {
            dst[at..][0..block_bytes].* = encode(context, @intCast(bx), @intCast(by));
            at += block_bytes;
        }
    }
    assert(at == len);
}

/// Decodes every block of `src` with `decode(context, block, bx, by)`.
pub fn decodeBlocks(
    comptime block_bytes: u32,
    width: u32,
    height: u32,
    src: []const u8,
    context: anytype,
    comptime decode: fn (@TypeOf(context), *const [block_bytes]u8, u32, u32) void,
) void {
    const len = encodedLen(block_bytes, width, height);
    assert(src.len >= len);
    var at: usize = 0;
    for (0..blocksHigh(height)) |by| {
        for (0..blocksWide(width)) |bx| {
            decode(context, src[at..][0..block_bytes], @intCast(bx), @intCast(by));
            at += block_bytes;
        }
    }
    assert(at == len);
}

test "blocks round up and clamp at the edges" {
    try std.testing.expectEqual(@as(u32, 1), blocksWide(1));
    try std.testing.expectEqual(@as(u32, 1), blocksWide(4));
    try std.testing.expectEqual(@as(u32, 2), blocksWide(5));
    try std.testing.expectEqual(@as(usize, 2 * 3 * 16), encodedLen(16, 5, 9));

    const pixels = [_]u8{ 1, 2, 3, 4, 5, 6 }; // 3x2, one channel
    const img = Image(u8).init(&pixels, 3, 2, 1);
    const b = img.block(1, 0, 0);
    try std.testing.expectEqual([1]u8{3}, b[3]); // x clamps to 2
    try std.testing.expectEqual([1]u8{6}, b[15]); // x and y clamp
}
