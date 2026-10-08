//! BC5: two 8-bit channels in 16 bytes per 4x4 block (tangent-space normals).

const std = @import("std");
const assert = std.debug.assert;
const bc4 = @import("bc4.zig");
const image = @import("image.zig");

pub const block_bytes = 16;

/// Encodes 16 two-channel pixels; each channel is an independent BC4 block.
pub fn encodeBlock(pixels: *const [16][2]u8) [block_bytes]u8 {
    var r: [16]u8 = undefined;
    var g: [16]u8 = undefined;
    for (pixels, &r, &g) |p, *rv, *gv| {
        rv.* = p[0];
        gv.* = p[1];
    }
    return bc4.encodeBlock(&r) ++ bc4.encodeBlock(&g);
}

pub fn decodeBlock(block: *const [block_bytes]u8) [16][2]u8 {
    const r = bc4.decodeBlock(block[0..8]);
    const g = bc4.decodeBlock(block[8..16]);
    var out: [16][2]u8 = undefined;
    for (&out, r, g) |*p, rv, gv| p.* = .{ rv, gv };
    return out;
}

/// Encodes channels 0 and 1 of `src` into `dst`, which must hold
/// `image.encodedLen(block_bytes, width, height)` bytes.
pub fn encodeImage(src: image.Image(u8), dst: []u8) void {
    encodeImageRows(src, dst, image.BlockRows.all(src.height));
}

/// `encodeImage` for the block rows `rows` only; see `image.BlockRows`.
pub fn encodeImageRows(src: image.Image(u8), dst: []u8, rows: image.BlockRows) void {
    src.check();
    assert(src.channels >= 2);
    image.encodeBlocks(block_bytes, src.width, src.height, dst, rows, src, struct {
        fn f(s: image.Image(u8), bx: u32, by: u32) [block_bytes]u8 {
            return encodeBlock(&s.block(2, bx, by));
        }
    }.f);
}

/// Decodes into channels 0 and 1 of `dst`; other channels are left untouched.
pub fn decodeImage(src: []const u8, dst: image.ImageMut(u8)) void {
    decodeImageRows(src, dst, image.BlockRows.all(dst.height));
}

/// `decodeImage` for the block rows `rows` only; see `image.BlockRows`.
pub fn decodeImageRows(src: []const u8, dst: image.ImageMut(u8), rows: image.BlockRows) void {
    dst.check();
    assert(dst.channels >= 2);
    image.decodeBlocks(block_bytes, dst.width, dst.height, src, rows, dst, struct {
        fn f(out: image.ImageMut(u8), block: *const [block_bytes]u8, bx: u32, by: u32) void {
            out.putBlock(2, bx, by, &decodeBlock(block));
        }
    }.f);
}
