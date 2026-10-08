//! BC6H: RGB half floats in 16 bytes per 4x4 block, unsigned (BC6H_UF16) or
//! signed (BC6H_SF16).

const std = @import("std");
const assert = std.debug.assert;
const texcomp_bc6h = @import("texcomp_bc6h.zig");
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
    src.check();
    assert(src.channels >= 3);
    const Ctx = struct { src: image.Image(f32), format: Format };
    image.encodeBlocks(block_bytes, src.width, src.height, dst, Ctx{ .src = src, .format = format }, struct {
        fn f(ctx: Ctx, bx: u32, by: u32) [block_bytes]u8 {
            return encodeBlock(&ctx.src.block(3, bx, by), ctx.format);
        }
    }.f);
}

/// Decodes into the first three channels of `dst` as half-float bits.
pub fn decodeImage(src: []const u8, dst: image.ImageMut(u16), format: Format) void {
    dst.check();
    assert(dst.channels >= 3);
    const Ctx = struct { dst: image.ImageMut(u16), format: Format };
    image.decodeBlocks(block_bytes, dst.width, dst.height, src, Ctx{ .dst = dst, .format = format }, struct {
        fn f(ctx: Ctx, block: *const [block_bytes]u8, bx: u32, by: u32) void {
            ctx.dst.putBlock(3, bx, by, &decodeBlock(block, ctx.format));
        }
    }.f);
}

/// The value of half-float bits, exactly.
pub fn halfToF32(bits: u16) f32 {
    const h: f16 = @bitCast(bits);
    return h;
}

// --- Decoding -------------------------------------------------------------------

/// One run of bits in a mode's header: `count` bits into endpoint `ep`
/// (0 to 3) of channel `ch`, starting at bit `shift`. Runs marked `reversed`
/// hold their bits in reverse order.
const Run = struct { ep: u2, ch: u2, shift: u5, count: u5, reversed: bool = false };

const Mode = struct {
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
/// `mode_by_code`.
const modes = [14]Mode{
    // 0: 10-bit base, 5-bit deltas.
    .{ .base_bits = 10, .delta_bits = .{ 5, 5, 5 }, .regions = 2, .transformed = true, .runs = &.{
        run(2, G, 4, 1), run(2, B, 4, 1), run(3, B, 4, 1), run(0, R, 0, 10), run(0, G, 0, 10), run(0, B, 0, 10),
        run(1, R, 0, 5), run(3, G, 4, 1), run(2, G, 0, 4), run(1, G, 0, 5), run(3, B, 0, 1), run(3, G, 0, 4),
        run(1, B, 0, 5), run(3, B, 1, 1), run(2, B, 0, 4), run(2, R, 0, 5), run(3, B, 2, 1), run(3, R, 0, 5),
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
        run(0, R, 0, 10),         run(0, G, 0, 10), run(0, B, 0, 10),         run(1, R, 0, 8), runReversed(0, R, 10, 2),
        run(1, G, 0, 8),          runReversed(0, G, 10, 2), run(1, B, 0, 8), runReversed(0, B, 10, 2),
    } },
    // 13: 16-bit base, 4-bit delta.
    .{ .base_bits = 16, .delta_bits = .{ 4, 4, 4 }, .regions = 1, .transformed = true, .runs = &.{
        run(0, R, 0, 10),         run(0, G, 0, 10), run(0, B, 0, 10),         run(1, R, 0, 4), runReversed(0, R, 10, 6),
        run(1, G, 0, 4),          runReversed(0, G, 10, 6), run(1, B, 0, 4), runReversed(0, B, 10, 6),
    } },
};

/// The mode read from the 5-bit code (or 2-bit, for modes 0 and 1); null
/// for the reserved codes.
fn modeOf(code: u5) ?u4 {
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

fn signExtend(v: i32, bits: u5) i32 {
    assert(bits >= 1 and bits <= 16);
    const shift: u5 = @intCast(32 - @as(u6, bits));
    return (v << shift) >> shift;
}

/// An endpoint value expanded to the 16-bit interpolation domain.
fn unquantize(v: i32, bits: u5, format: Format) i32 {
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
fn finish(v: i32, format: Format) u16 {
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
    const mode = modes[mode_index];

    // endpoint[ep][ch], as read.
    var ep: [4][3]i32 = @splat(@splat(0));
    for (mode.runs) |r| {
        var v = reader.take(r.count);
        if (r.reversed) v = @as(u32, @bitReverse(@as(u16, @intCast(v)))) >> @intCast(16 - @as(u6, r.count));
        ep[r.ep][r.ch] |= @intCast(v << r.shift);
    }
    const partition_index: u32 = if (mode.regions == 2) reader.take(5) else 0;
    const endpoints: usize = @as(usize, mode.regions) * 2;

    for (0..3) |c| {
        if (format == .signed) ep[0][c] = signExtend(ep[0][c], mode.base_bits);
        for (1..endpoints) |e| {
            if (mode.transformed or format == .signed) ep[e][c] = signExtend(ep[e][c], mode.delta_bits[c]);
            if (mode.transformed) {
                const mask = (@as(i32, 1) << mode.base_bits) - 1;
                ep[e][c] = (ep[e][c] + ep[0][c]) & mask;
                if (format == .signed) ep[e][c] = signExtend(ep[e][c], mode.base_bits);
            }
        }
        for (0..endpoints) |e| ep[e][c] = unquantize(ep[e][c], mode.base_bits, format);
    }

    const weights: []const u32 = if (mode.regions == 1)
        &.{ 0, 4, 9, 13, 17, 21, 26, 30, 34, 38, 43, 47, 51, 55, 60, 64 }
    else
        &.{ 0, 9, 18, 27, 37, 46, 55, 64 };
    const index_bits: u5 = if (mode.regions == 1) 4 else 3;
    const part = texcomp_bc6h.partition(partition_index);
    const anchor = texcomp_bc6h.part2_anchor[partition_index];

    var out: [16][3]u16 = undefined;
    for (0..16) |i| {
        const region: usize = if (mode.regions == 1) 0 else part[i];
        const is_anchor = i == 0 or (mode.regions == 2 and i == anchor);
        const index = reader.take(if (is_anchor) index_bits - 1 else index_bits);
        const w: i32 = @intCast(weights[index]);
        for (0..3) |c| {
            const a = ep[region * 2][c];
            const b = ep[region * 2 + 1][c];
            out[i][c] = finish((a * (64 - w) + b * w + 32) >> 6, format);
        }
    }
    assert(reader.bits == 0);
    return out;
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
