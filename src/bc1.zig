//! BC1 (DXT1): opaque RGB in 8 bytes per 4x4 block.

const std = @import("std");
const assert = std.debug.assert;
const stb_dxt = @import("stb_dxt.zig");
const image = @import("image.zig");

pub const block_bytes = 8;
pub const Quality = stb_dxt.Quality;

/// Encodes 16 RGBA pixels (row-major); alpha is ignored and the block always
/// decodes opaque.
pub fn encodeBlock(pixels: *const [16][4]u8, quality: Quality) [block_bytes]u8 {
    return stb_dxt.encodeColorBlock(pixels, quality);
}

/// Decodes to RGBA. A block whose first endpoint is not greater than the
/// second is in 3-colour mode, where index 3 is transparent black.
pub fn decodeBlock(block: *const [block_bytes]u8) [16][4]u8 {
    return decodeColorBlock(block, .bc1);
}

/// BC1 alone has the 3-colour mode; the colour half of BC2 and BC3 is always
/// 4-colour.
pub const ColorMode = enum { bc1, four_color };

pub fn decodeColorBlock(block: *const [8]u8, mode: ColorMode) [16][4]u8 {
    const c0 = std.mem.readInt(u16, block[0..2], .little);
    const c1 = std.mem.readInt(u16, block[2..4], .little);
    const bits = std.mem.readInt(u32, block[4..8], .little);
    const p0 = unpack565(c0);
    const p1 = unpack565(c1);
    const three = mode == .bc1 and c0 <= c1;

    var palette: [4][4]u8 = undefined;
    for (0..3) |c| {
        const a: u32 = p0[c];
        const b: u32 = p1[c];
        palette[0][c] = p0[c];
        palette[1][c] = p1[c];
        if (three) {
            palette[2][c] = @intCast((a + b) / 2);
            palette[3][c] = 0;
        } else {
            // Rounded to nearest, within the D3D tolerance for BC1.
            palette[2][c] = @intCast((2 * a + b + 1) / 3);
            palette[3][c] = @intCast((a + 2 * b + 1) / 3);
        }
    }
    palette[0][3] = 255;
    palette[1][3] = 255;
    palette[2][3] = 255;
    palette[3][3] = if (three) 0 else 255;

    var out: [16][4]u8 = undefined;
    for (&out, 0..) |*p, i| p.* = palette[(bits >> @intCast(2 * i)) & 3];
    return out;
}

fn unpack565(c: u16) [3]u8 {
    const r: u8 = @intCast((c >> 11) & 0x1f);
    const g: u8 = @intCast((c >> 5) & 0x3f);
    const b: u8 = @intCast(c & 0x1f);
    // Bit replication maps 0 to 0 and the maximum to 255.
    return .{ (r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2) };
}

/// Encodes an image of at least 3 channels (RGB or RGBA) into `dst`, which
/// must hold `image.encodedLen(block_bytes, width, height)` bytes.
pub fn encodeImage(src: image.Image(u8), dst: []u8, quality: Quality) void {
    src.check();
    assert(src.channels >= 3);
    const Ctx = struct { src: image.Image(u8), quality: Quality };
    image.encodeBlocks(block_bytes, src.width, src.height, dst, Ctx{ .src = src, .quality = quality }, struct {
        fn f(ctx: Ctx, bx: u32, by: u32) [block_bytes]u8 {
            var px: [16][4]u8 = undefined;
            if (ctx.src.channels == 3) {
                for (ctx.src.block(3, bx, by), &px) |rgb, *p| p.* = .{ rgb[0], rgb[1], rgb[2], 255 };
            } else {
                px = ctx.src.block(4, bx, by);
            }
            return encodeBlock(&px, ctx.quality);
        }
    }.f);
}

/// Decodes into an RGBA image of the same size the data was encoded from.
pub fn decodeImage(src: []const u8, dst: image.ImageMut(u8)) void {
    dst.check();
    assert(dst.channels == 4);
    image.decodeBlocks(block_bytes, dst.width, dst.height, src, dst, struct {
        fn f(out: image.ImageMut(u8), block: *const [block_bytes]u8, bx: u32, by: u32) void {
            out.putBlock(4, bx, by, &decodeBlock(block));
        }
    }.f);
}

test "a solid block round-trips within 565 precision" {
    const px: [16][4]u8 = @splat(.{ 200, 100, 50, 255 });
    const decoded = decodeBlock(&encodeBlock(&px, .normal));
    for (decoded) |p| {
        try std.testing.expect(@abs(@as(i32, p[0]) - 200) <= 4);
        try std.testing.expect(@abs(@as(i32, p[1]) - 100) <= 2);
        try std.testing.expect(@abs(@as(i32, p[2]) - 50) <= 4);
        try std.testing.expectEqual(@as(u8, 255), p[3]);
    }
}
