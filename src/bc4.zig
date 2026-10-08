//! BC4: one 8-bit channel in 8 bytes per 4x4 block (masks, roughness).

const std = @import("std");
const assert = std.debug.assert;
const stb_dxt = @import("stb_dxt.zig");
const image = @import("image.zig");

pub const block_bytes = 8;

pub fn encodeBlock(values: *const [16]u8) [block_bytes]u8 {
    return stb_dxt.encodeAlphaBlock(values);
}

pub fn decodeBlock(block: *const [block_bytes]u8) [16]u8 {
    const v0: u32 = block[0];
    const v1: u32 = block[1];
    var palette: [8]u8 = undefined;
    palette[0] = block[0];
    palette[1] = block[1];
    if (v0 > v1) {
        for (1..7) |i_usize| {
            const i: u32 = @intCast(i_usize);
            palette[i + 1] = @intCast(((7 - i) * v0 + i * v1 + 3) / 7);
        }
    } else {
        for (1..5) |i_usize| {
            const i: u32 = @intCast(i_usize);
            palette[i + 1] = @intCast(((5 - i) * v0 + i * v1 + 2) / 5);
        }
        palette[6] = 0;
        palette[7] = 255;
    }

    const bits = std.mem.readInt(u48, block[2..8], .little);
    var out: [16]u8 = undefined;
    for (&out, 0..) |*v, i| v.* = palette[@intCast((bits >> @intCast(3 * i)) & 7)];
    return out;
}

/// Encodes channel 0 of `src` into `dst`, which must hold
/// `image.encodedLen(block_bytes, width, height)` bytes.
pub fn encodeImage(src: image.Image(u8), dst: []u8) void {
    src.check();
    image.encodeBlocks(block_bytes, src.width, src.height, dst, src, struct {
        fn f(s: image.Image(u8), bx: u32, by: u32) [block_bytes]u8 {
            const b = s.block(1, bx, by);
            var values: [16]u8 = undefined;
            for (b, &values) |p, *v| v.* = p[0];
            return encodeBlock(&values);
        }
    }.f);
}

/// Decodes into channel 0 of `dst`; other channels are left untouched.
pub fn decodeImage(src: []const u8, dst: image.ImageMut(u8)) void {
    dst.check();
    image.decodeBlocks(block_bytes, dst.width, dst.height, src, dst, struct {
        fn f(out: image.ImageMut(u8), block: *const [block_bytes]u8, bx: u32, by: u32) void {
            const values = decodeBlock(block);
            var px: [16][1]u8 = undefined;
            for (values, &px) |v, *p| p.* = .{v};
            out.putBlock(1, bx, by, &px);
        }
    }.f);
}

test "a ramp round-trips within one step" {
    var values: [16]u8 = undefined;
    for (&values, 0..) |*v, i| v.* = @intCast(i * 17);
    const decoded = decodeBlock(&encodeBlock(&values));
    for (values, decoded) |want, got| try std.testing.expect(@abs(@as(i32, want) - got) <= 255 / 14 + 1);
}
