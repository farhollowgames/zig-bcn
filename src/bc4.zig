//! BC4: one 8-bit channel in 8 bytes per 4x4 block (masks, roughness).

const std = @import("std");
const assert = std.debug.assert;
const stb_dxt = @import("stb_dxt.zig");
const image = @import("image.zig");

pub const block_bytes = 8;

pub fn encodeBlock(values: *const [16]u8) [block_bytes]u8 {
    return stb_dxt.encodeAlphaBlock(values);
}

/// Decodes 16 values, each in its own lane.
pub fn decodeBlock(block: *const [block_bytes]u8) [16]u8 {
    const v0: Lanes = @splat(block[0]);
    const v1: Lanes = @splat(block[1]);
    const bits: @Vector(16, u64) = @splat(std.mem.readInt(u48, block[2..8], .little));
    const shifts = std.simd.iota(u6, 16) * @as(@Vector(16, u6), @splat(3));
    const index: Lanes = @intCast((bits >> shifts) & @as(@Vector(16, u64), @splat(7)));
    return if (block[0] > block[1]) entries(7, index, v0, v1) else entries(5, index, v0, v1);
}

const Lanes = @Vector(16, u32);

/// Palette entries: v0, v1, then `n - 1` values between them, each
/// ((n - w) * v0 + w * v1 + n / 2) / n for v1's weight w. The 6-entry
/// palette (n = 5) ends with 0 and 255.
fn entries(comptime n: u32, index: Lanes, v0: Lanes, v1: Lanes) [16]u8 {
    const one: Lanes = @splat(1);
    const top: Lanes = @splat(n);
    // Entry 1 is v1 at full weight; entry k > 1 gives v1 the weight k - 1.
    const w = @min(@select(u32, index == one, top, index -| one), top);
    var value = ((top - w) * v0 + w * v1 + @as(Lanes, @splat(n / 2))) / top;
    if (n == 5) {
        value = @select(u32, index == @as(Lanes, @splat(6)), @as(Lanes, @splat(0)), value);
        value = @select(u32, index == @as(Lanes, @splat(7)), @as(Lanes, @splat(255)), value);
    }
    return @as(@Vector(16, u8), @intCast(value));
}

/// Encodes channel 0 of `src` into `dst`, which must hold
/// `image.encodedLen(block_bytes, width, height)` bytes.
pub fn encodeImage(src: image.Image(u8), dst: []u8) void {
    encodeImageRows(src, dst, image.BlockRows.all(src.height));
}

/// `encodeImage` for the block rows `rows` only; see `image.BlockRows`.
pub fn encodeImageRows(src: image.Image(u8), dst: []u8, rows: image.BlockRows) void {
    src.check();
    image.encodeBlocks(block_bytes, src.width, src.height, dst, rows, src, struct {
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
    decodeImageRows(src, dst, image.BlockRows.all(dst.height));
}

/// `decodeImage` for the block rows `rows` only; see `image.BlockRows`.
pub fn decodeImageRows(src: []const u8, dst: image.ImageMut(u8), rows: image.BlockRows) void {
    dst.check();
    image.decodeBlocks(block_bytes, dst.width, dst.height, src, rows, dst, struct {
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
