//! BC3 (DXT5): RGB plus a separate alpha channel in 16 bytes per 4x4 block.

const std = @import("std");
const assert = std.debug.assert;
const stb_dxt = @import("stb_dxt.zig");
const bc1 = @import("bc1.zig");
const bc4 = @import("bc4.zig");
const image = @import("image.zig");

pub const block_bytes = 16;
pub const Quality = stb_dxt.Quality;

/// Encodes 16 RGBA pixels: a BC4 alpha block followed by a BC1 colour block.
pub fn encodeBlock(pixels: *const [16][4]u8, quality: Quality) [block_bytes]u8 {
    var alpha: [16]u8 = undefined;
    for (pixels, &alpha) |p, *a| a.* = p[3];
    return stb_dxt.encodeAlphaBlock(&alpha) ++ stb_dxt.encodeColorBlock(pixels, quality);
}

pub fn decodeBlock(block: *const [block_bytes]u8) [16][4]u8 {
    const alpha = bc4.decodeBlock(block[0..8]);
    var out = bc1.decodeColorBlock(block[8..16], .four_color);
    for (&out, alpha) |*p, a| p[3] = a;
    return out;
}

/// Encodes an RGBA image into `dst`, which must hold
/// `image.encodedLen(block_bytes, width, height)` bytes.
pub fn encodeImage(src: image.Image(u8), dst: []u8, quality: Quality) void {
    src.check();
    assert(src.channels == 4);
    const Ctx = struct { src: image.Image(u8), quality: Quality };
    image.encodeBlocks(block_bytes, src.width, src.height, dst, Ctx{ .src = src, .quality = quality }, struct {
        fn f(ctx: Ctx, bx: u32, by: u32) [block_bytes]u8 {
            return encodeBlock(&ctx.src.block(4, bx, by), ctx.quality);
        }
    }.f);
}

pub fn decodeImage(src: []const u8, dst: image.ImageMut(u8)) void {
    dst.check();
    assert(dst.channels == 4);
    image.decodeBlocks(block_bytes, dst.width, dst.height, src, dst, struct {
        fn f(out: image.ImageMut(u8), block: *const [block_bytes]u8, bx: u32, by: u32) void {
            out.putBlock(4, bx, by, &decodeBlock(block));
        }
    }.f);
}
