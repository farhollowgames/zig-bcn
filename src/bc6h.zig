//! BC6H: RGB half floats in 16 bytes per 4x4 block, unsigned (BC6H_UF16) or
//! signed (BC6H_SF16).

const std = @import("std");
const assert = std.debug.assert;
const texcomp_bc6h = @import("texcomp_bc6h.zig");
const bc6h_high = @import("bc6h_high.zig");
const image = @import("image.zig");

pub const block_bytes = 16;

/// The translated encoder's internals, for the differential tests; not a
/// stable interface.
pub const texcomp = texcomp_bc6h;

pub const Format = enum {
    /// BC6H_UF16: non-negative values; negatives and NaN encode as 0.
    unsigned,
    /// BC6H_SF16.
    signed,
};

/// IEEE binary32 to binary16 bits as the encoder rounds them: half up in
/// magnitude, NaN kept quiet, overflow to infinity, and every value below
/// 2^-14 (the half subnormal range) flushed to signed zero.
pub const floatToHalfBits = texcomp_bc6h.floatToHalfBits;

/// Encodes 16 RGB texels (row-major). Values beyond the largest half
/// (65504) clamp to it.
pub fn encodeBlock(pixels: *const [16][3]f32, format: Format) [block_bytes]u8 {
    return switch (format) {
        .unsigned => texcomp_bc6h.encodeBlockUf16(pixels),
        .signed => texcomp_bc6h.encodeBlockSf16(pixels),
    };
}

/// Encodes the first three channels of `src` into `dst`, which must hold
/// `image.encodedLen(block_bytes, width, height)` bytes.
pub fn encodeImage(src: image.Image(f32), dst: []u8, format: Format) void {
    encodeImageRows(src, dst, format, image.BlockRows.all(src.height));
}

/// `encodeImage` for the block rows `rows` only; see `image.BlockRows`.
pub fn encodeImageRows(src: image.Image(f32), dst: []u8, format: Format, rows: image.BlockRows) void {
    src.check();
    assert(src.channels >= 3);
    const Ctx = struct { src: image.Image(f32), format: Format };
    image.encodeBlocks(block_bytes, src.width, src.height, dst, rows, Ctx{ .src = src, .format = format }, struct {
        fn f(ctx: Ctx, bx: u32, by: u32) [block_bytes]u8 {
            return encodeBlock(&ctx.src.block(3, bx, by), ctx.format);
        }
    }.f);
}

pub const Quality = enum {
    /// texcomp's encoder, byte for byte (`encodeBlock`): very fast, weaker
    /// on flat and smooth HDR, and flushes values below 2^-14 to zero.
    fast,
    /// zig-bcn's own search over every mode, scored by the exact decoded
    /// error (`bc6h_high.zig`); never worse than `fast` on that error.
    high,
};

/// Encodes 16 RGB texels at the chosen quality; `.fast` is `encodeBlock`.
pub fn encodeBlockQuality(pixels: *const [16][3]f32, format: Format, quality: Quality) [block_bytes]u8 {
    return switch (quality) {
        .fast => encodeBlock(pixels, format),
        .high => bc6h_high.encodeBlock(pixels, format).block,
    };
}

/// `encodeImage` at the chosen quality.
pub fn encodeImageQuality(src: image.Image(f32), dst: []u8, format: Format, quality: Quality) void {
    encodeImageQualityRows(src, dst, format, quality, image.BlockRows.all(src.height));
}

/// `encodeImageQuality` for the block rows `rows` only; see `image.BlockRows`.
pub fn encodeImageQualityRows(src: image.Image(f32), dst: []u8, format: Format, quality: Quality, rows: image.BlockRows) void {
    src.check();
    assert(src.channels >= 3);
    const Ctx = struct { src: image.Image(f32), format: Format, quality: Quality };
    image.encodeBlocks(block_bytes, src.width, src.height, dst, rows, Ctx{ .src = src, .format = format, .quality = quality }, struct {
        fn f(ctx: Ctx, bx: u32, by: u32) [block_bytes]u8 {
            return encodeBlockQuality(&ctx.src.block(3, bx, by), ctx.format, ctx.quality);
        }
    }.f);
}

/// The high-quality encoder's internals, for tests and tools; not a stable
/// interface.
pub const high = bc6h_high;

/// Decodes into the first three channels of `dst` as half-float bits.
pub fn decodeImage(src: []const u8, dst: image.ImageMut(u16), format: Format) void {
    decodeImageRows(src, dst, format, image.BlockRows.all(dst.height));
}

/// `decodeImage` for the block rows `rows` only; see `image.BlockRows`.
pub fn decodeImageRows(src: []const u8, dst: image.ImageMut(u16), format: Format, rows: image.BlockRows) void {
    dst.check();
    assert(dst.channels >= 3);
    const Ctx = struct { dst: image.ImageMut(u16), format: Format };
    image.decodeBlocks(block_bytes, dst.width, dst.height, src, rows, Ctx{ .dst = dst, .format = format }, struct {
        fn f(ctx: Ctx, block: *const [block_bytes]u8, bx: u32, by: u32) void {
            ctx.dst.putBlock(3, bx, by, &decodeBlock(block, ctx.format));
        }
    }.f);
}

/// Decodes into float RGB or RGBA (`dst.channels` 3 or 4; BC6H has no
/// alpha, so a fourth channel is 1).
pub fn decodeImageF32(src: []const u8, dst: image.ImageMut(f32), format: Format) void {
    decodeImageF32Rows(src, dst, format, image.BlockRows.all(dst.height));
}

/// `decodeImageF32` for the block rows `rows` only; see `image.BlockRows`.
pub fn decodeImageF32Rows(src: []const u8, dst: image.ImageMut(f32), format: Format, rows: image.BlockRows) void {
    dst.check();
    assert(dst.channels == 3 or dst.channels == 4);
    const Ctx = struct { dst: image.ImageMut(f32), format: Format };
    image.decodeBlocks(block_bytes, dst.width, dst.height, src, rows, Ctx{ .dst = dst, .format = format }, struct {
        fn f(ctx: Ctx, block: *const [block_bytes]u8, bx: u32, by: u32) void {
            const halves = decodeBlock(block, ctx.format);
            var px: [16][4]f32 = undefined;
            for (halves, &px) |h, *p| p.* = .{ halfToF32(h[0]), halfToF32(h[1]), halfToF32(h[2]), 1.0 };
            if (ctx.dst.channels == 4) {
                ctx.dst.putBlock(4, bx, by, &px);
            } else {
                var rgb: [16][3]f32 = undefined;
                for (px, &rgb) |p, *q| q.* = p[0..3].*;
                ctx.dst.putBlock(3, bx, by, &rgb);
            }
        }
    }.f);
}

/// The value of half-float bits, exactly, keeping NaN payloads as they are
/// (a hardware conversion may quiet them).
pub fn halfToF32(bits: u16) f32 {
    const sign: u32 = @as(u32, bits & 0x8000) << 16;
    const exp: u32 = (bits >> 10) & 0x1f;
    var man: u32 = bits & 0x3ff;
    var out: u32 = undefined;
    if (exp == 0) {
        if (man == 0) {
            out = sign;
        } else {
            // A subnormal half is a normal float: shift the leading one up
            // to the implicit bit.
            var e: u32 = 127 - 15 + 1;
            while (man & 0x400 == 0) {
                man <<= 1;
                e -= 1;
            }
            out = sign | (e << 23) | ((man & 0x3ff) << 13);
        }
    } else if (exp == 31) {
        out = sign | 0x7f800000 | (man << 13);
    } else {
        out = sign | ((exp + 127 - 15) << 23) | (man << 13);
    }
    return @bitCast(out);
}

test "half to float is exact" {
    for (0..0x10000) |i| {
        const h: u16 = @intCast(i);
        const want: f32 = @as(f16, @bitCast(h));
        const got = halfToF32(h);
        if (std.math.isNan(want)) {
            try std.testing.expect(std.math.isNan(got));
        } else {
            try std.testing.expectEqual(@as(u32, @bitCast(want)), @as(u32, @bitCast(got)));
        }
    }
}

// --- Decoding -------------------------------------------------------------------

/// One run of bits in a mode's header: `count` bits into endpoint `ep`
/// (0 to 3) of channel `ch`, starting at bit `shift`. Runs marked `reversed`
/// hold their bits in reverse order.
pub const Run = struct { ep: u2, ch: u2, shift: u5, count: u5, reversed: bool = false };

pub const Mode = struct {
    /// Endpoint precision, then delta precision per channel.
    base_bits: u5,
    delta_bits: [3]u5,
    regions: u2,
    /// Whether endpoints after the first are stored as deltas from it.
    transformed: bool,
    runs: []const Run,
};

fn run(ep: u2, ch: u2, shift: u5, count: u5) Run {
    return .{ .ep = ep, .ch = ch, .shift = shift, .count = count };
}

fn runReversed(ep: u2, ch: u2, shift: u5, count: u5) Run {
    return .{ .ep = ep, .ch = ch, .shift = shift, .count = count, .reversed = true };
}

const R = 0;
const G = 1;
const B = 2;

/// Header layouts after the mode code, in bit order, from the BC6H format
/// definition. Indexed by mode number; the code each mode is read from is in
/// `modeOf`. Public for the high-quality encoder, which packs through them.
pub const modes = [14]Mode{
    // 0: 10-bit base, 5-bit deltas.
    .{ .base_bits = 10, .delta_bits = .{ 5, 5, 5 }, .regions = 2, .transformed = true, .runs = &.{
        run(2, G, 4, 1), run(2, B, 4, 1), run(3, B, 4, 1), run(0, R, 0, 10), run(0, G, 0, 10), run(0, B, 0, 10),
        run(1, R, 0, 5), run(3, G, 4, 1), run(2, G, 0, 4), run(1, G, 0, 5),  run(3, B, 0, 1),  run(3, G, 0, 4),
        run(1, B, 0, 5), run(3, B, 1, 1), run(2, B, 0, 4), run(2, R, 0, 5),  run(3, B, 2, 1),  run(3, R, 0, 5),
        run(3, B, 3, 1),
    } },
    // 1: 7-bit base, 6-bit deltas.
    .{ .base_bits = 7, .delta_bits = .{ 6, 6, 6 }, .regions = 2, .transformed = true, .runs = &.{
        run(2, G, 5, 1), run(3, G, 4, 1), run(3, G, 5, 1), run(0, R, 0, 7), run(3, B, 0, 1), run(3, B, 1, 1),
        run(2, B, 4, 1), run(0, G, 0, 7), run(2, B, 5, 1), run(3, B, 2, 1), run(2, G, 4, 1), run(0, B, 0, 7),
        run(3, B, 3, 1), run(3, B, 5, 1), run(3, B, 4, 1), run(1, R, 0, 6), run(2, G, 0, 4), run(1, G, 0, 6),
        run(3, G, 0, 4), run(1, B, 0, 6), run(2, B, 0, 4), run(2, R, 0, 6), run(3, R, 0, 6),
    } },
    // 2: 11-bit base, deltas 5/4/4.
    .{ .base_bits = 11, .delta_bits = .{ 5, 4, 4 }, .regions = 2, .transformed = true, .runs = &.{
        run(0, R, 0, 10), run(0, G, 0, 10), run(0, B, 0, 10), run(1, R, 0, 5), run(0, R, 10, 1), run(2, G, 0, 4),
        run(1, G, 0, 4),  run(0, G, 10, 1), run(3, B, 0, 1),  run(3, G, 0, 4), run(1, B, 0, 4),  run(0, B, 10, 1),
        run(3, B, 1, 1),  run(2, B, 0, 4),  run(2, R, 0, 5),  run(3, B, 2, 1), run(3, R, 0, 5),  run(3, B, 3, 1),
    } },
    // 3: 11-bit base, deltas 4/5/4.
    .{ .base_bits = 11, .delta_bits = .{ 4, 5, 4 }, .regions = 2, .transformed = true, .runs = &.{
        run(0, R, 0, 10), run(0, G, 0, 10), run(0, B, 0, 10), run(1, R, 0, 4), run(0, R, 10, 1), run(3, G, 4, 1),
        run(2, G, 0, 4),  run(1, G, 0, 5),  run(0, G, 10, 1), run(3, G, 0, 4), run(1, B, 0, 4),  run(0, B, 10, 1),
        run(3, B, 1, 1),  run(2, B, 0, 4),  run(2, R, 0, 4),  run(3, B, 0, 1), run(3, B, 2, 1),  run(3, R, 0, 4),
        run(2, G, 4, 1),  run(3, B, 3, 1),
    } },
    // 4: 11-bit base, deltas 4/4/5.
    .{ .base_bits = 11, .delta_bits = .{ 4, 4, 5 }, .regions = 2, .transformed = true, .runs = &.{
        run(0, R, 0, 10), run(0, G, 0, 10), run(0, B, 0, 10), run(1, R, 0, 4), run(0, R, 10, 1), run(2, B, 4, 1),
        run(2, G, 0, 4),  run(1, G, 0, 4),  run(0, G, 10, 1), run(3, B, 0, 1), run(3, G, 0, 4),  run(1, B, 0, 5),
        run(0, B, 10, 1), run(2, B, 0, 4),  run(2, R, 0, 4),  run(3, B, 1, 1), run(3, B, 2, 1),  run(3, R, 0, 4),
        run(3, B, 4, 1),  run(3, B, 3, 1),
    } },
    // 5: 9-bit base, 5-bit deltas.
    .{ .base_bits = 9, .delta_bits = .{ 5, 5, 5 }, .regions = 2, .transformed = true, .runs = &.{
        run(0, R, 0, 9), run(2, B, 4, 1), run(0, G, 0, 9), run(2, G, 4, 1), run(0, B, 0, 9), run(3, B, 4, 1),
        run(1, R, 0, 5), run(3, G, 4, 1), run(2, G, 0, 4), run(1, G, 0, 5), run(3, B, 0, 1), run(3, G, 0, 4),
        run(1, B, 0, 5), run(3, B, 1, 1), run(2, B, 0, 4), run(2, R, 0, 5), run(3, B, 2, 1), run(3, R, 0, 5),
        run(3, B, 3, 1),
    } },
    // 6: 8-bit base, deltas 6/5/5.
    .{ .base_bits = 8, .delta_bits = .{ 6, 5, 5 }, .regions = 2, .transformed = true, .runs = &.{
        run(0, R, 0, 8), run(3, G, 4, 1), run(2, B, 4, 1), run(0, G, 0, 8), run(3, B, 2, 1), run(2, G, 4, 1),
        run(0, B, 0, 8), run(3, B, 3, 1), run(3, B, 4, 1), run(1, R, 0, 6), run(2, G, 0, 4), run(1, G, 0, 5),
        run(3, B, 0, 1), run(3, G, 0, 4), run(1, B, 0, 5), run(3, B, 1, 1), run(2, B, 0, 4), run(2, R, 0, 6),
        run(3, R, 0, 6),
    } },
    // 7: 8-bit base, deltas 5/6/5.
    .{ .base_bits = 8, .delta_bits = .{ 5, 6, 5 }, .regions = 2, .transformed = true, .runs = &.{
        run(0, R, 0, 8), run(3, B, 0, 1), run(2, B, 4, 1), run(0, G, 0, 8), run(2, G, 5, 1), run(2, G, 4, 1),
        run(0, B, 0, 8), run(3, G, 5, 1), run(3, B, 4, 1), run(1, R, 0, 5), run(3, G, 4, 1), run(2, G, 0, 4),
        run(1, G, 0, 6), run(3, G, 0, 4), run(1, B, 0, 5), run(3, B, 1, 1), run(2, B, 0, 4), run(2, R, 0, 5),
        run(3, B, 2, 1), run(3, R, 0, 5), run(3, B, 3, 1),
    } },
    // 8: 8-bit base, deltas 5/5/6.
    .{ .base_bits = 8, .delta_bits = .{ 5, 5, 6 }, .regions = 2, .transformed = true, .runs = &.{
        run(0, R, 0, 8), run(3, B, 1, 1), run(2, B, 4, 1), run(0, G, 0, 8), run(2, B, 5, 1), run(2, G, 4, 1),
        run(0, B, 0, 8), run(3, B, 5, 1), run(3, B, 4, 1), run(1, R, 0, 5), run(3, G, 4, 1), run(2, G, 0, 4),
        run(1, G, 0, 5), run(3, B, 0, 1), run(3, G, 0, 4), run(1, B, 0, 6), run(2, B, 0, 4), run(2, R, 0, 5),
        run(3, B, 2, 1), run(3, R, 0, 5), run(3, B, 3, 1),
    } },
    // 9: four 6-bit endpoints, stored directly.
    .{ .base_bits = 6, .delta_bits = .{ 6, 6, 6 }, .regions = 2, .transformed = false, .runs = &.{
        run(0, R, 0, 6), run(3, G, 4, 1), run(3, B, 0, 1), run(3, B, 1, 1), run(2, B, 4, 1), run(0, G, 0, 6),
        run(2, G, 5, 1), run(2, B, 5, 1), run(3, B, 2, 1), run(2, G, 4, 1), run(0, B, 0, 6), run(3, G, 5, 1),
        run(3, B, 3, 1), run(3, B, 5, 1), run(3, B, 4, 1), run(1, R, 0, 6), run(2, G, 0, 4), run(1, G, 0, 6),
        run(3, G, 0, 4), run(1, B, 0, 6), run(2, B, 0, 4), run(2, R, 0, 6), run(3, R, 0, 6),
    } },
    // 10: two 10-bit endpoints, stored directly.
    .{ .base_bits = 10, .delta_bits = .{ 10, 10, 10 }, .regions = 1, .transformed = false, .runs = &.{
        run(0, R, 0, 10), run(0, G, 0, 10), run(0, B, 0, 10), run(1, R, 0, 10), run(1, G, 0, 10), run(1, B, 0, 10),
    } },
    // 11: 11-bit base, 9-bit delta.
    .{ .base_bits = 11, .delta_bits = .{ 9, 9, 9 }, .regions = 1, .transformed = true, .runs = &.{
        run(0, R, 0, 10), run(0, G, 0, 10), run(0, B, 0, 10), run(1, R, 0, 9), run(0, R, 10, 1), run(1, G, 0, 9),
        run(0, G, 10, 1), run(1, B, 0, 9),  run(0, B, 10, 1),
    } },
    // 12: 12-bit base, 8-bit delta.
    .{ .base_bits = 12, .delta_bits = .{ 8, 8, 8 }, .regions = 1, .transformed = true, .runs = &.{
        run(0, R, 0, 10), run(0, G, 0, 10),         run(0, B, 0, 10), run(1, R, 0, 8),          runReversed(0, R, 10, 2),
        run(1, G, 0, 8),  runReversed(0, G, 10, 2), run(1, B, 0, 8),  runReversed(0, B, 10, 2),
    } },
    // 13: 16-bit base, 4-bit delta.
    .{ .base_bits = 16, .delta_bits = .{ 4, 4, 4 }, .regions = 1, .transformed = true, .runs = &.{
        run(0, R, 0, 10), run(0, G, 0, 10),         run(0, B, 0, 10), run(1, R, 0, 4),          runReversed(0, R, 10, 6),
        run(1, G, 0, 4),  runReversed(0, G, 10, 6), run(1, B, 0, 4),  runReversed(0, B, 10, 6),
    } },
};

/// The mode read from the 5-bit code (or 2-bit, for modes 0 and 1); null
/// for the reserved codes.
pub fn modeOf(code: u5) ?u4 {
    if (code & 3 == 0) return 0;
    if (code & 3 == 1) return 1;
    return switch (code) {
        0x02 => 2,
        0x06 => 3,
        0x0a => 4,
        0x0e => 5,
        0x12 => 6,
        0x16 => 7,
        0x1a => 8,
        0x1e => 9,
        0x03 => 10,
        0x07 => 11,
        0x0b => 12,
        0x0f => 13,
        else => null,
    };
}

const BitReader = struct {
    bits: u128,

    fn take(self: *BitReader, count: u5) u32 {
        assert(count >= 1 and count <= 16);
        const v: u32 = @intCast(self.bits & ((@as(u128, 1) << count) - 1));
        self.bits >>= count;
        return v;
    }
};

pub fn signExtend(v: i32, bits: u5) i32 {
    assert(bits >= 1 and bits <= 16);
    const shift: u5 = @intCast(32 - @as(u6, bits));
    return (v << shift) >> shift;
}

/// An endpoint value expanded to the 16-bit interpolation domain.
pub fn unquantize(v: i32, bits: u5, format: Format) i32 {
    switch (format) {
        .unsigned => {
            if (bits >= 15) return v;
            if (v == 0) return 0;
            if (v == (@as(i32, 1) << bits) - 1) return 0xffff;
            return ((v << 16) + 0x8000) >> bits;
        },
        .signed => {
            if (bits >= 16) return v;
            const mag = @abs(v);
            var unq: i32 = undefined;
            if (mag == 0) {
                unq = 0;
            } else if (mag >= (@as(u32, 1) << (bits - 1)) - 1) {
                unq = 0x7fff;
            } else {
                unq = @intCast(((mag << 15) + 0x4000) >> (bits - 1));
            }
            return if (v < 0) -unq else unq;
        },
    }
}

/// Scales an interpolated value to half-float bits: by 31/64 for unsigned,
/// 31/32 of the magnitude for signed.
pub fn finish(v: i32, format: Format) u16 {
    switch (format) {
        .unsigned => {
            assert(v >= 0 and v <= 0xffff);
            return @intCast((v * 31) >> 6);
        },
        .signed => {
            const mag: u32 = (@abs(v) * 31) >> 5;
            assert(mag <= 0x7fff);
            // A negative value that scales to zero decodes as +0.
            return @intCast(mag | @as(u32, if (v < 0 and mag != 0) 0x8000 else 0));
        },
    }
}

/// Decodes one block to 16 RGB texels of half-float bits. Reserved modes
/// decode to zero.
pub fn decodeBlock(block: *const [block_bytes]u8, format: Format) [16][3]u16 {
    var reader: BitReader = .{ .bits = std.mem.readInt(u128, block, .little) };
    var code: u5 = @intCast(reader.take(2));
    if (code > 1) code |= @intCast(reader.take(3) << 2);
    const mode_index = modeOf(code) orelse return @splat(@splat(0));
    // One decoder per mode and format, so each reads its header in straight
    // lines.
    return switch (format) {
        inline else => |f| switch (mode_index) {
            inline 0...modes.len - 1 => |m| decodeMode(f, m, &reader),
            else => unreachable,
        },
    };
}

fn decodeMode(comptime format: Format, comptime mode_index: u4, reader: *BitReader) [16][3]u16 {
    const mode = modes[mode_index];

    // endpoint[ep][ch], as read.
    var ep: [4][3]i32 = @splat(@splat(0));
    inline for (mode.runs) |r| {
        var v = reader.take(r.count);
        if (r.reversed) v = @as(u32, @bitReverse(@as(u16, @intCast(v)))) >> (16 - r.count);
        ep[r.ep][r.ch] |= @intCast(v << r.shift);
    }
    const partition_index: u32 = if (mode.regions == 2) reader.take(5) else 0;
    const endpoints: usize = @as(usize, mode.regions) * 2;

    for (0..3) |c| {
        if (format == .signed) ep[0][c] = signExtend(ep[0][c], mode.base_bits);
        for (1..endpoints) |e| {
            if (mode.transformed or format == .signed) {
                ep[e][c] = signExtend(ep[e][c], mode.delta_bits[c]);
            }
            if (mode.transformed) {
                const mask = (@as(i32, 1) << mode.base_bits) - 1;
                ep[e][c] = (ep[e][c] + ep[0][c]) & mask;
                if (format == .signed) ep[e][c] = signExtend(ep[e][c], mode.base_bits);
            }
        }
        for (0..endpoints) |e| ep[e][c] = unquantize(ep[e][c], mode.base_bits, format);
    }

    // The indices fill the rest of the block, `index_bits` per texel and one
    // fewer for each region's anchor texel; all 16 texels are decoded at
    // once, one lane each.
    const weights: []const u32 = if (mode.regions == 1)
        &.{ 0, 4, 9, 13, 17, 21, 26, 30, 34, 38, 43, 47, 51, 55, 60, 64 }
    else
        &.{ 0, 9, 18, 27, 37, 46, 55, 64 };
    const index_bits: u32 = if (mode.regions == 1) 4 else 3;
    comptime {
        var header_bits: u32 = if (mode_index < 2) 2 else 5;
        for (mode.runs) |r| header_bits += r.count;
        if (mode.regions == 2) header_bits += 5;
        assert(header_bits + 16 * index_bits - mode.regions == 128);
    }
    const indices: u64 = @intCast(reader.bits);
    // One past the texels for one region, so no lane matches.
    const anchor: u32 = if (mode.regions == 1) 16 else texcomp_bc6h.part2_anchor[partition_index];
    const lane = std.simd.iota(u32, 16);
    const zeros: @Vector(16, u32) = @splat(0);
    const ones: @Vector(16, u32) = @splat(1);
    const anchors: @Vector(16, u32) = @splat(anchor);
    const start = lane * @as(@Vector(16, u32), @splat(index_bits)) -
        @select(u32, lane > zeros, ones, zeros) - @select(u32, lane > anchors, ones, zeros);
    const width = @as(@Vector(16, u32), @splat(index_bits)) -
        @select(u32, lane == zeros, ones, zeros) - @select(u32, lane == anchors, ones, zeros);
    const one_bit: @Vector(16, u64) = @splat(1);
    const index_mask = (one_bit << @intCast(width)) - one_bit;
    const index = @as(@Vector(16, u64), @splat(indices)) >> @intCast(start) & index_mask;
    const index_array: [16]u64 = index;
    var w_array: [16]i32 = undefined;
    for (&w_array, index_array) |*wi, ii| wi.* = @intCast(weights[@intCast(ii)]);
    const w: @Vector(16, i32) = w_array;

    const Lanes = @Vector(16, i32);
    const part: @Vector(16, u8) = texcomp_bc6h.partition(partition_index).*;
    const second: @Vector(16, bool) = if (mode.regions == 1)
        @splat(false)
    else
        part != @as(@Vector(16, u8), @splat(0));
    var channels: [3]@Vector(16, u16) = undefined;
    for (0..3) |c| {
        const a = @select(i32, second, @as(Lanes, @splat(ep[2][c])), @as(Lanes, @splat(ep[0][c])));
        const b = @select(i32, second, @as(Lanes, @splat(ep[3][c])), @as(Lanes, @splat(ep[1][c])));
        const sum = a * (@as(Lanes, @splat(64)) - w) + b * w + @as(Lanes, @splat(32));
        channels[c] = finishLanes(format, sum >> @splat(6));
    }
    const planes: [3][16]u16 = .{ channels[0], channels[1], channels[2] };
    var out: [16][3]u16 = undefined;
    for (&out, planes[0], planes[1], planes[2]) |*texel, r, g, b| texel.* = .{ r, g, b };
    return out;
}

/// `finish` on every lane.
fn finishLanes(comptime format: Format, v: @Vector(16, i32)) @Vector(16, u16) {
    switch (format) {
        .unsigned => return @intCast((v * @as(@Vector(16, i32), @splat(31))) >> @splat(6)),
        .signed => {
            const Unsigned = @Vector(16, u32);
            const zeros: Unsigned = @splat(0);
            const mag = (@abs(v) * @as(Unsigned, @splat(31))) >> @splat(5);
            // A negative value that scales to zero decodes as +0.
            const below_zero = v < @as(@Vector(16, i32), @splat(0));
            const none: @Vector(16, bool) = @splat(false);
            const negative = @select(bool, below_zero, mag != zeros, none);
            return @intCast(mag | @select(u32, negative, @as(Unsigned, @splat(0x8000)), zeros));
        },
    }
}

test "a flat block round-trips within half precision" {
    const px: [16][3]f32 = @splat(.{ 1.0, 0.5, 4.0 });
    for ([_]Format{ .unsigned, .signed }) |format| {
        const decoded = decodeBlock(&encodeBlock(&px, format), format);
        for (decoded) |p| {
            for (p, px[0]) |h, want| {
                const got = halfToF32(h);
                // Signed endpoints keep one bit fewer of magnitude.
                const tolerance: f32 = if (format == .signed) 0.02 else 0.01;
                try std.testing.expect(@abs(got - want) <= want * tolerance);
            }
        }
    }
}
