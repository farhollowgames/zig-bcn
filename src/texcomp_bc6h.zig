//! BC6H block encoder, unsigned (BC6H_UF16) and signed (BC6H_SF16).
//!
//! Translated to Zig from TinyEXR tools/texcomp/src/texcomp_bc6h.c (commit
//! 644148d), Copyright 2014-2026 Syoyo Fujita and TinyEXR authors, licensed
//! under the Apache License 2.0 (see NOTICE). As in the original, the
//! two-region partition table and block bit layouts mirror bcdec.h (Sergii
//! Kudlai, MIT). The translation keeps every arithmetic step, so it produces
//! the same bytes as the C; test/bc6h_test.zig checks that against the C
//! under both its SIMD and its scalar dispatch.
//!
//! Only the scalar selector search is translated: the original's SSE4.1, AVX2
//! and NEON kernels are documented, and tested here, to be bit-identical to it.
//! The C repeats one partition search and refinement in each of its ten
//! two-region encoders with different constants; here that search is
//! `twoRegion`, configured per mode, while each mode keeps its own packing.
//! The C's separate 10-bit quantizers are the N-bit ones at N = 10, with the
//! same arithmetic, so only the N-bit ones are kept.
//!
//! Quirks of the original are kept on purpose, since the output must match:
//! some packers write values that their decode does not read back as the
//! encoder assumed (see doc/bc6h-quality.md); the encoder still only keeps a
//! mode when its own error estimate improves.

const std = @import("std");
const assert = std.debug.assert;
const maxInt = std.math.maxInt;

pub const Pixels = [16][3]f32;
pub const Block = [16]u8;

const weights4 = [16]u32{ 0, 4, 9, 13, 17, 21, 26, 30, 34, 38, 43, 47, 51, 55, 60, 64 };
const weights3 = [8]u32{ 0, 9, 18, 27, 37, 46, 55, 64 };

/// The error above which the slower modes are tried: a per-channel RMS of
/// about 256 in the 0..31743 magnitude range.
const err_try_more: u64 = 48 * 256 * 256;
/// The C's `(uint64_t)-1`: the mode cannot encode the block.
const err_none: u64 = maxInt(u64);

/// IEEE binary32 to binary16 bits, rounding half up in magnitude; NaN keeps a
/// quiet payload bit, and overflow becomes infinity.
pub fn floatToHalfBits(fv: f32) u16 {
    const u: u32 = @bitCast(fv);
    const sign: u32 = (u >> 16) & 0x8000;
    var exp: u32 = (u >> 23) & 0xff;
    var mant: u32 = u & 0x7fffff;
    if (exp == 255) return @intCast(sign | 0x7c00 | @as(u32, if (mant != 0) 0x0200 else 0));
    if (exp > 142) return @intCast(sign | 0x7c00);
    if (exp < 113) {
        if (exp < 103) return @intCast(sign);
        var m = mant | 0x800000;
        m >>= @intCast(125 - exp);
        m = (m + 0x1000) >> 13;
        assert(m <= 0x400);
        return @intCast(sign | m);
    }
    exp = exp - 112;
    mant = (mant + 0x1000) >> 13;
    if (mant & 0x400 != 0) {
        mant = 0;
        exp += 1;
    }
    if (exp >= 31) return @intCast(sign | 0x7c00);
    return @intCast(sign | (exp << 10) | (mant & 0x3ff));
}

// --- Quantization -----------------------------------------------------------

/// Unsigned half to an N-bit endpoint value. Negative and NaN inputs are 0,
/// and magnitudes clamp to the largest finite half.
fn quantUf16N(f: f32, bits: u32) u32 {
    if (!(f > 0.0)) return 0;
    const h = floatToHalfBits(f);
    var mag: u32 = h & 0x7fff;
    if (mag > 0x7bff) mag = 0x7bff;
    const max: u32 = (@as(u32, 1) << @intCast(bits)) - 1;
    // 0x7bff * 0xffff stays below 2^32, so this never wraps.
    return (mag * max + 15871) / 31743;
}

fn quantUf16(f: f32) u32 {
    return quantUf16N(f, 10);
}

/// The magnitude an N-bit unsigned endpoint decodes to, in the decoder's
/// 0..31743 domain.
fn unquantNToMag(q: u32, bits: u32) u32 {
    var unq: u32 = undefined;
    if (q == 0) {
        unq = 0;
    } else if (q >= (@as(u32, 1) << @intCast(bits)) - 1) {
        unq = 0xffff;
    } else {
        unq = ((q << 16) + 0x8000) >> @intCast(bits);
    }
    return (unq * 31) >> 6;
}

fn unquantUf16ToMag(q: u32) u32 {
    return unquantNToMag(q, 10);
}

/// Signed half to an N-bit signed endpoint value (sign and magnitude, the
/// magnitude limited to 2^(N-1) - 1).
fn quantSf16N(f: f32, bits: u32) i32 {
    const maxq: i32 = @intCast((@as(u32, 1) << @intCast(bits - 1)) - 1);
    if (f == 0.0) return 0;
    const h = floatToHalfBits(f);
    var mag: u32 = h & 0x7fff;
    if (mag > 0x7bff) mag = 0x7bff;
    var q: i32 = @intCast((mag * @as(u32, @intCast(maxq)) + 15871) / 31743);
    if (q > maxq) q = maxq;
    return if (h & 0x8000 != 0) -q else q;
}

fn quantSf16(f: f32) i32 {
    return quantSf16N(f, 10);
}

/// The signed magnitude an N-bit signed endpoint decodes to.
fn unquantNToSmag(q_in: i32, bits: u32) i32 {
    const maxq: i32 = @intCast((@as(u32, 1) << @intCast(bits - 1)) - 1);
    var q = q_in;
    var negative = false;
    if (q < 0) {
        negative = true;
        q = -q;
    }
    var unq: i32 = undefined;
    if (q == 0) {
        unq = 0;
    } else if (q >= maxq) {
        unq = 0x7fff;
    } else {
        unq = @intCast(((@as(u32, @intCast(q)) << 15) + 0x4000) >> @intCast(bits - 1));
    }
    if (negative) unq = -unq;
    return if (unq < 0) -(((-unq) * 31) >> 5) else (unq * 31) >> 5;
}

fn unquantSf16ToSmag(q: i32) i32 {
    return unquantNToSmag(q, 10);
}

fn err3Mag(a: [3]u32, r: u32, g: u32, b: u32) u32 {
    const dr = @as(i64, a[0]) - r;
    const dg = @as(i64, a[1]) - g;
    const db = @as(i64, a[2]) - b;
    // The C sums these squares in int32, which overflows when all three
    // differences pass about 26754 (undefined behaviour in C). Compiled, the
    // sum wraps and the cast to uint32_t restores it exactly, because the
    // true sum (at most 3 * 31743^2) always fits in 32 bits; the SIMD kernels
    // compute it unsigned. This is that true sum.
    const e = dr * dr + dg * dg + db * db;
    assert(e >= 0 and e <= maxInt(u32));
    return @intCast(e);
}

fn err3Smag(a: [3]i32, r: i32, g: i32, b: i32) u32 {
    const dr = @as(i64, a[0]) - r;
    const dg = @as(i64, a[1]) - g;
    const db = @as(i64, a[2]) - b;
    const e: u64 = @intCast(dr * dr + dg * dg + db * db);
    return if (e > maxInt(u32)) maxInt(u32) else @intCast(e);
}

/// Clamps to N-bit two's complement and returns its low N bits.
fn packSignedN(v_in: i32, bits: u32) u32 {
    const half: i32 = @intCast(@as(u32, 1) << @intCast(bits - 1));
    var v = v_in;
    if (v < -half) v = -half;
    if (v > half - 1) v = half - 1;
    return @as(u32, @bitCast(v)) & ((@as(u32, 1) << @intCast(bits)) - 1);
}

fn packSigned10(q: i32) u32 {
    return packSignedN(q, 10);
}

/// Clamps a delta to 5-bit two's complement. The C also uses it for 6-bit
/// delta fields, where it limits the range to the 5-bit one.
fn packDelta5(d_in: i32) u32 {
    var d = d_in;
    if (d < -16) d = -16;
    if (d > 15) d = 15;
    return @as(u32, @bitCast(d)) & 31;
}

/// Rounded division, away from zero on halves; `den` is positive.
fn rdiv(num: i64, den: i64) i64 {
    assert(den > 0);
    const half = @divTrunc(den, 2);
    return if (num >= 0) @divTrunc(num + half, den) else -@divTrunc(-num + half, den);
}

// --- Bit packing --------------------------------------------------------------

/// Writes fields least significant bit first, as tc_set_bits does.
const BitWriter = struct {
    out: *Block,
    pos: u32 = 0,

    fn init(out: *Block) BitWriter {
        out.* = @splat(0);
        return .{ .out = out };
    }

    /// Appends the low `count` bits of `value`.
    fn put(self: *BitWriter, value: u32, count: u32) void {
        assert(count >= 1 and count <= 16);
        var v = value;
        var n = count;
        while (n != 0) {
            const k = @min(8 - (self.pos & 7), n);
            assert(self.pos < 128);
            const mask = (@as(u32, 1) << @intCast(k)) - 1;
            self.out[self.pos >> 3] |= @intCast((v & mask) << @intCast(self.pos & 7));
            v >>= @intCast(k);
            self.pos += k;
            n -= k;
        }
    }

    /// Bit `n` of `v`'s two's complement form.
    fn bit(v: i32, n: u5) u32 {
        return (@as(u32, @bitCast(v)) >> n) & 1;
    }

    /// The low bits of `v`'s two's complement form under `mask`.
    fn low(v: i32, mask: u32) u32 {
        return @as(u32, @bitCast(v)) & mask;
    }

    /// The indices, with one bit fewer for each region's anchor texel.
    fn indices(self: *BitWriter, sel: *const [16]u8, anchor: u32, bits: u32) void {
        for (sel, 0..) |s, i| {
            const n: u32 = if (i == 0 or i == anchor) bits - 1 else bits;
            self.put(s, n);
        }
        assert(self.pos == 128);
    }
};

// --- One-region selector search and refinement ------------------------------

fn Int(comptime signed: bool) type {
    return if (signed) i32 else u32;
}

fn Target(comptime signed: bool) type {
    return [16][3]Int(signed);
}

/// The interpolated 16-entry palette, in the decoder's magnitude domain.
fn pal16(comptime signed: bool, lo: *const [3]Int(signed), hi: *const [3]Int(signed)) [16][3]Int(signed) {
    var pal: [16][3]Int(signed) = undefined;
    for (0..16) |s| {
        const w = weights4[s];
        for (0..3) |c| {
            if (signed) {
                const qv: i32 = @intCast((@as(i64, 64 - w) * lo[c] + @as(i64, w) * hi[c] + 32) >> 6);
                pal[s][c] = unquantSf16ToSmag(qv);
            } else {
                pal[s][c] = unquantUf16ToMag(((64 - w) * lo[c] + w * hi[c] + 32) >> 6);
            }
        }
    }
    return pal;
}

/// Picks each texel's nearest palette entry (the first on ties) and returns
/// the total error.
fn chooseSelectors(comptime signed: bool, target: *const Target(signed), lo: *const [3]Int(signed), hi: *const [3]Int(signed), sel: *[16]u8) u64 {
    const pal = pal16(signed, lo, hi);
    var err: u64 = 0;
    for (target, sel) |t, *out| {
        var best: u32 = 0;
        var best_err: u32 = maxInt(u32);
        for (pal, 0..) |p, s| {
            const e = if (signed) err3Smag(t, p[0], p[1], p[2]) else err3Mag(t, p[0], p[1], p[2]);
            if (e < best_err) {
                best_err = e;
                best = @intCast(s);
            }
        }
        out.* = @intCast(best);
        err += best_err;
    }
    return err;
}

/// Least squares refit of a one-region block's endpoints to the current
/// selectors (2x2 normal equations per channel in the quantized domain),
/// kept while the error drops, for up to three rounds. Endpoints clamp to the
/// 10-bit range whatever the mode's precision, as in the C.
fn refine(comptime signed: bool, q: *const Target(signed), target: *const Target(signed), lo: *[3]Int(signed), hi: *[3]Int(signed), sel: *[16]u8) u64 {
    const clamp_lo: i64 = if (signed) -511 else 0;
    const clamp_hi: i64 = if (signed) 511 else 1023;
    var best = chooseSelectors(signed, target, lo, hi, sel);
    for (0..3) |_| {
        var nlo: [3]Int(signed) = undefined;
        var nhi: [3]Int(signed) = undefined;
        var nsel: [16]u8 = undefined;
        for (0..3) |c| {
            var saa: i64 = 0;
            var sab: i64 = 0;
            var sbb: i64 = 0;
            var sap: i64 = 0;
            var sbp: i64 = 0;
            for (0..16) |i| {
                const b: i64 = weights4[sel[i]];
                const a = 64 - b;
                const p: i64 = q[i][c];
                saa += a * a;
                sab += a * b;
                sbb += b * b;
                sap += a * p;
                sbp += b * p;
            }
            const det = saa * sbb - sab * sab;
            if (det <= 0) {
                nlo[c] = lo[c];
                nhi[c] = hi[c];
                continue;
            }
            const l = std.math.clamp(rdiv((sap * sbb - sbp * sab) * 64, det), clamp_lo, clamp_hi);
            const h = std.math.clamp(rdiv((sbp * saa - sap * sab) * 64, det), clamp_lo, clamp_hi);
            nlo[c] = @intCast(l);
            nhi[c] = @intCast(h);
        }
        const e = chooseSelectors(signed, target, &nlo, &nhi, &nsel);
        if (e < best) {
            best = e;
            lo.* = nlo;
            hi.* = nhi;
            sel.* = nsel;
        } else {
            break;
        }
    }
    return best;
}

fn OneRegion(comptime signed: bool) type {
    return struct {
        q: Target(signed),
        target: Target(signed),
        lo: [3]Int(signed),
        hi: [3]Int(signed),
        sel: [16]u8,
        /// The refined error, before the anchor swap (which keeps it).
        err: u64,
    };
}

/// How the luma extremes are compared. The C's main signed encoder compares
/// luma as signed; its 12- and 16-bit signed modes cast it to unsigned, which
/// sorts negative luma above positive.
const LumaOrder = enum { signed, unsigned };

/// The shared start of every one-region encoder: quantize to `q_bits`, take
/// the better of the bounding box and the luma extremes as endpoints, refine,
/// then swap the endpoints if the anchor texel's index has its top bit set
/// (the anchor is stored with one bit fewer).
fn oneRegion(comptime signed: bool, pix: *const Pixels, q_bits: u32, luma_order: LumaOrder) OneRegion(signed) {
    const T = Int(signed);
    var r: OneRegion(signed) = undefined;
    // The C starts these at the type's extremes or the mode's; either way they
    // end as the extremes of q, since q stays inside the mode's range.
    var lo: [3]T = @splat(maxInt(T));
    var hi: [3]T = @splat(std.math.minInt(T));
    var min_i: usize = 0;
    var max_i: usize = 0;
    var min_l_s: i32 = maxInt(i32);
    var max_l_s: i32 = std.math.minInt(i32);
    var min_l_u: u32 = maxInt(u32);
    var max_l_u: u32 = 0;
    for (0..16) |i| {
        for (0..3) |c| {
            if (signed) {
                r.q[i][c] = quantSf16N(pix[i][c], q_bits);
                r.target[i][c] = unquantSf16ToSmag(quantSf16(pix[i][c]));
            } else {
                r.q[i][c] = quantUf16N(pix[i][c], q_bits);
                r.target[i][c] = unquantUf16ToMag(quantUf16(pix[i][c]));
            }
            if (r.q[i][c] < lo[c]) lo[c] = r.q[i][c];
            if (r.q[i][c] > hi[c]) hi[c] = r.q[i][c];
        }
        const t = r.target[i];
        if (!signed) {
            const l: u32 = t[0] * 38 + t[1] * 76 + t[2] * 14;
            if (l < min_l_u) {
                min_l_u = l;
                min_i = i;
            }
            if (l >= max_l_u) {
                max_l_u = l;
                max_i = i;
            }
        } else {
            const l: i32 = t[0] * 38 + t[1] * 76 + t[2] * 14;
            switch (luma_order) {
                .signed => {
                    if (l < min_l_s) {
                        min_l_s = l;
                        min_i = i;
                    }
                    if (l >= max_l_s) {
                        max_l_s = l;
                        max_i = i;
                    }
                },
                .unsigned => {
                    const lu: u32 = @bitCast(l);
                    if (lu < min_l_u) {
                        min_l_u = lu;
                        min_i = i;
                    }
                    if (lu >= max_l_u) {
                        max_l_u = lu;
                        max_i = i;
                    }
                },
            }
        }
    }
    const luma_lo = r.q[min_i];
    const luma_hi = r.q[max_i];
    var luma_sel: [16]u8 = undefined;
    var box_sel: [16]u8 = undefined;
    const luma_err = chooseSelectors(signed, &r.target, &luma_lo, &luma_hi, &luma_sel);
    const box_err = chooseSelectors(signed, &r.target, &lo, &hi, &box_sel);
    if (luma_err < box_err) {
        lo = luma_lo;
        hi = luma_hi;
        r.sel = luma_sel;
    } else {
        r.sel = box_sel;
    }
    r.err = refine(signed, &r.q, &r.target, &lo, &hi, &r.sel);
    if (r.sel[0] & 8 != 0) {
        std.mem.swap([3]T, &lo, &hi);
        for (&r.sel) |*s| s.* = 15 - s.*;
    }
    r.lo = lo;
    r.hi = hi;
    return r;
}

// --- Two-region search ----------------------------------------------------------

/// The 32 two-region partitions (bcdec's corrected table).
const part2 = [32][16]u8{
    .{ 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1 }, .{ 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 },
    .{ 0, 1, 1, 1, 0, 1, 1, 1, 0, 1, 1, 1, 0, 1, 1, 1 }, .{ 0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 1, 1, 1 },
    .{ 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 1, 1 }, .{ 0, 0, 1, 1, 0, 1, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1 },
    .{ 0, 0, 0, 1, 0, 0, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1 }, .{ 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 1, 1, 0, 1, 1, 1 },
    .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 1, 1 }, .{ 0, 0, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 },
    .{ 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 1, 1, 1, 1, 1, 1 }, .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 1, 1 },
    .{ 0, 0, 0, 1, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 }, .{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1 },
    .{ 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 }, .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1 },
    .{ 0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 1, 0, 1, 1, 1, 1 }, .{ 0, 1, 1, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 1, 0 }, .{ 0, 1, 1, 1, 0, 0, 1, 1, 0, 0, 0, 1, 0, 0, 0, 0 },
    .{ 0, 0, 1, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0 }, .{ 0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 0, 1, 1, 1, 0 },
    .{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 0 }, .{ 0, 1, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 0, 1 },
    .{ 0, 0, 1, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0 }, .{ 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 0 },
    .{ 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0 }, .{ 0, 0, 1, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1, 1, 0, 0 },
    .{ 0, 0, 0, 1, 0, 1, 1, 1, 1, 1, 1, 0, 1, 0, 0, 0 }, .{ 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0 },
    .{ 0, 1, 1, 1, 0, 0, 0, 1, 1, 0, 0, 0, 1, 1, 1, 0 }, .{ 0, 0, 1, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 1, 0, 0 },
};

/// The second region's anchor texel for each partition.
pub const part2_anchor = [32]u8{
    15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
    15, 2,  8,  2,  2,  8,  8,  15, 2,  8,  2,  2,  8,  8,  2,  2,
};

pub fn partition(p: u32) *const [16]u8 {
    return &part2[p];
}

/// How a palette entry's magnitude is computed from interpolated endpoints:
/// as 10-bit values (mode 0's selectors, which the C reuses for every
/// delta mode whatever its precision) or as 6-bit values (mode 9's).
const PaletteBits = enum { ten, six };

const TwoRegionConfig = struct {
    signed: bool,
    /// Endpoint precision of the quantized values the search fits.
    q_bits: u32,
    /// Delta widths per channel; null when endpoints are stored directly
    /// (mode 9) and need no fit check.
    delta_bits: ?[3]u32,
    palette: PaletteBits,
    /// The refinement's endpoint clamp.
    clamp_lo: i64,
    clamp_hi: i64,
};

fn TwoRegion(comptime signed: bool) type {
    return struct {
        ep: [4][3]Int(signed),
        sel: [16]u8,
        partition: u32,
        anchor: u32,
        err: u64,
    };
}

fn twoRegionSelectors(comptime cfg: TwoRegionConfig, target: *const Target(cfg.signed), part: *const [16]u8, ep: *const [4][3]Int(cfg.signed), sel: *[16]u8) u64 {
    const T = Int(cfg.signed);
    var pal: [2][8][3]T = undefined;
    for (0..2) |r| for (0..8) |s| for (0..3) |c| {
        const w = weights3[s];
        if (cfg.signed) {
            const qv = (@as(i32, @intCast(64 - w)) * ep[r * 2][c] + @as(i32, @intCast(w)) * ep[r * 2 + 1][c] + 32) >> 6;
            pal[r][s][c] = switch (cfg.palette) {
                .ten => unquantSf16ToSmag(qv),
                .six => unquantNToSmag(qv, 6),
            };
        } else {
            const qv = ((64 - w) * ep[r * 2][c] + w * ep[r * 2 + 1][c] + 32) >> 6;
            pal[r][s][c] = switch (cfg.palette) {
                .ten => unquantUf16ToMag(qv),
                .six => unquantNToMag(qv, 6),
            };
        }
    };
    var err: u64 = 0;
    for (0..16) |i| {
        const reg = part[i];
        var best: u32 = 0;
        var berr: u32 = maxInt(u32);
        for (0..8) |s| {
            const p = pal[reg][s];
            const e = if (cfg.signed) err3Smag(target[i], p[0], p[1], p[2]) else err3Mag(target[i], p[0], p[1], p[2]);
            if (e < berr) {
                berr = e;
                best = @intCast(s);
            }
        }
        sel[i] = @intCast(best);
        err += berr;
    }
    return err;
}

/// Whether every endpoint's delta from endpoint 0 fits its channel's width.
fn deltasFit(comptime T: type, delta_bits: [3]u32, ep0: [3]T, others: [3][3]T) bool {
    for (0..3) |c| {
        const limit: i32 = @as(i32, 1) << @intCast(delta_bits[c] - 1);
        for (others) |e| {
            const d = @as(i32, @intCast(e[c])) - @as(i32, @intCast(ep0[c]));
            if (d < -limit or d > limit - 1) return false;
        }
    }
    return true;
}

/// The two-region search shared by modes 0 to 9: rank all 32 partitions by
/// the squared spread of each region's bounding box, fully evaluate the best
/// five that fit the mode's deltas, refine the winner's endpoints by least
/// squares per region for up to two rounds, and swap endpoints so each
/// region's anchor index has its top bit clear. Null when no partition fits.
fn twoRegion(comptime cfg: TwoRegionConfig, pix: *const Pixels) ?TwoRegion(cfg.signed) {
    const signed = cfg.signed;
    const T = Int(signed);
    const top_k = 5;

    var q: Target(signed) = undefined;
    var target: Target(signed) = undefined;
    for (0..16) |i| for (0..3) |c| {
        if (signed) {
            q[i][c] = quantSf16N(pix[i][c], cfg.q_bits);
            target[i][c] = unquantSf16ToSmag(quantSf16(pix[i][c]));
        } else {
            q[i][c] = quantUf16N(pix[i][c], cfg.q_bits);
            target[i][c] = unquantUf16ToMag(quantUf16(pix[i][c]));
        }
    };

    const Box = struct {
        lo: [2][3]T,
        hi: [2][3]T,
        have: [2]bool,

        // The C starts these at the mode's range limits; with q inside that
        // range, the type's extremes give the same boxes.
        fn of(qq: *const Target(signed), part: *const [16]u8) @This() {
            var box: @This() = .{ .lo = @splat(@splat(maxInt(T))), .hi = @splat(@splat(std.math.minInt(T))), .have = .{ false, false } };
            for (0..16) |i| {
                const reg = part[i];
                for (0..3) |c| {
                    if (qq[i][c] < box.lo[reg][c]) box.lo[reg][c] = qq[i][c];
                    if (qq[i][c] > box.hi[reg][c]) box.hi[reg][c] = qq[i][c];
                }
                box.have[reg] = true;
            }
            return box;
        }
    };

    var cand: [top_k]u32 = undefined;
    var cscore: [top_k]u64 = undefined;
    var ncand: u32 = 0;
    for (0..32) |p_usize| {
        const p: u32 = @intCast(p_usize);
        const box = Box.of(&q, &part2[p]);
        if (!box.have[0] or !box.have[1]) continue;
        var score: u64 = 0;
        for (0..3) |c| {
            const e0: u64 = @intCast(@as(i64, box.hi[0][c]) - box.lo[0][c]);
            const e1: u64 = @intCast(@as(i64, box.hi[1][c]) - box.lo[1][c]);
            score += e0 * e0 + e1 * e1;
        }
        if (ncand < top_k) {
            cand[ncand] = p;
            cscore[ncand] = score;
            ncand += 1;
        } else {
            var worst: u32 = 0;
            for (1..top_k) |k| {
                if (cscore[k] > cscore[worst]) worst = @intCast(k);
            }
            if (score < cscore[worst]) {
                cand[worst] = p;
                cscore[worst] = score;
            }
        }
    }

    var best: TwoRegion(signed) = undefined;
    best.err = err_none;
    var found = false;
    for (cand[0..ncand]) |p| {
        const box = Box.of(&q, &part2[p]);
        if (cfg.delta_bits) |bits| {
            if (!deltasFit(T, bits, box.lo[0], .{ box.hi[0], box.lo[1], box.hi[1] })) continue;
        }
        const ep = [4][3]T{ box.lo[0], box.hi[0], box.lo[1], box.hi[1] };
        var sel: [16]u8 = undefined;
        const err = twoRegionSelectors(cfg, &target, &part2[p], &ep, &sel);
        if (err < best.err) {
            best.err = err;
            best.partition = p;
            best.ep = ep;
            best.sel = sel;
            found = true;
        }
    }
    if (!found) return null;

    const part = &part2[best.partition];
    for (0..2) |_| {
        var nep: [4][3]T = undefined;
        var nsel: [16]u8 = undefined;
        for (0..2) |rr| for (0..3) |c| {
            var saa: i64 = 0;
            var sab: i64 = 0;
            var sbb: i64 = 0;
            var sap: i64 = 0;
            var sbp: i64 = 0;
            for (0..16) |i| {
                if (part[i] != rr) continue;
                const bb: i64 = weights3[best.sel[i]];
                const a = 64 - bb;
                const pp: i64 = q[i][c];
                saa += a * a;
                sab += a * bb;
                sbb += bb * bb;
                sap += a * pp;
                sbp += bb * pp;
            }
            const det = saa * sbb - sab * sab;
            if (det <= 0) {
                nep[rr * 2][c] = best.ep[rr * 2][c];
                nep[rr * 2 + 1][c] = best.ep[rr * 2 + 1][c];
                continue;
            }
            const l = std.math.clamp(rdiv((sap * sbb - sbp * sab) * 64, det), cfg.clamp_lo, cfg.clamp_hi);
            const h = std.math.clamp(rdiv((sbp * saa - sap * sab) * 64, det), cfg.clamp_lo, cfg.clamp_hi);
            nep[rr * 2][c] = @intCast(l);
            nep[rr * 2 + 1][c] = @intCast(h);
        };
        if (cfg.delta_bits) |bits| {
            if (!deltasFit(T, bits, nep[0], .{ nep[1], nep[2], nep[3] })) break;
        }
        const e = twoRegionSelectors(cfg, &target, part, &nep, &nsel);
        if (e < best.err) {
            best.err = e;
            best.ep = nep;
            best.sel = nsel;
        } else {
            break;
        }
    }

    best.anchor = part2_anchor[best.partition];
    for (0..2) |r| {
        const at: u32 = if (r == 0) 0 else best.anchor;
        if (best.sel[at] & 4 != 0) {
            std.mem.swap([3]T, &best.ep[r * 2], &best.ep[r * 2 + 1]);
            for (0..16) |i| {
                if (part[i] == r) best.sel[i] = 7 - best.sel[i];
            }
        }
    }
    return best;
}

/// Endpoints as i32, the form the packers take for both formats.
fn epI32(comptime signed: bool, ep: [4][3]Int(signed)) [4][3]i32 {
    var out: [4][3]i32 = undefined;
    for (0..4) |e| for (0..3) |c| {
        out[e][c] = @intCast(ep[e][c]);
    };
    return out;
}

// --- Two-region modes ---------------------------------------------------------

fn mode0(comptime signed: bool, pix: *const Pixels, out: *Block) u64 {
    const r = twoRegion(.{
        .signed = signed,
        .q_bits = 10,
        .delta_bits = .{ 5, 5, 5 },
        .palette = .ten,
        .clamp_lo = if (signed) -512 else 0,
        .clamp_hi = if (signed) 511 else 1023,
    }, pix) orelse return err_none;
    const e = epI32(signed, r.ep);
    const bit = BitWriter.bit;
    const low = BitWriter.low;
    var w = BitWriter.init(out);
    w.pos = 2; // mode 0's code is 00
    w.put(bit(e[2][1], 4), 1);
    w.put(bit(e[2][2], 4), 1);
    w.put(bit(e[3][2], 4), 1);
    for (0..3) |c| w.put(if (signed) packSigned10(e[0][c]) else @intCast(e[0][c]), 10);
    w.put(packDelta5(e[1][0] - e[0][0]), 5);
    w.put(bit(e[3][1], 4), 1);
    w.put(low(e[2][1], 0xf), 4);
    w.put(packDelta5(e[1][1] - e[0][1]), 5);
    w.put(low(e[3][2], 1), 1);
    w.put(low(e[3][1], 0xf), 4);
    w.put(packDelta5(e[1][2] - e[0][2]), 5);
    w.put(bit(e[3][2], 1), 1);
    w.put(low(e[2][2], 0xf), 4);
    w.put(packDelta5(e[2][0] - e[0][0]), 5);
    w.put(bit(e[3][2], 2), 1);
    w.put(packDelta5(e[3][0] - e[0][0]), 5);
    w.put(bit(e[3][2], 3), 1);
    w.put(r.partition, 5);
    w.indices(&r.sel, r.anchor, 3);
    return r.err;
}

fn mode1(comptime signed: bool, pix: *const Pixels, out: *Block) u64 {
    const r = twoRegion(.{
        .signed = signed,
        .q_bits = 7,
        .delta_bits = .{ 6, 6, 6 },
        .palette = .ten,
        .clamp_lo = if (signed) -64 else 0,
        .clamp_hi = if (signed) 63 else 127,
    }, pix) orelse return err_none;
    const e = epI32(signed, r.ep);
    const bit = BitWriter.bit;
    const low = BitWriter.low;
    const base = struct {
        fn f(v: i32) u32 {
            return if (signed) packSignedN(v, 7) else @intCast(v);
        }
    }.f;
    var w = BitWriter.init(out);
    w.put(1, 2);
    w.put(bit(e[2][1], 5), 1);
    w.put(bit(e[3][1], 4), 1);
    w.put(bit(e[3][1], 5), 1);
    w.put(base(e[0][0]), 7);
    w.put(low(e[3][2], 1), 1);
    w.put(bit(e[3][2], 1), 1);
    w.put(bit(e[2][2], 4), 1);
    w.put(base(e[0][1]), 7);
    w.put(bit(e[2][2], 5), 1);
    w.put(bit(e[3][2], 2), 1);
    w.put(bit(e[2][1], 4), 1);
    w.put(base(e[0][2]), 7);
    w.put(bit(e[3][2], 3), 1);
    w.put(bit(e[3][2], 5), 1);
    w.put(bit(e[3][2], 4), 1);
    w.put(packDelta5(e[1][0] - e[0][0]), 6);
    w.put(low(e[2][1], 0xf), 4);
    w.put(packDelta5(e[1][1] - e[0][1]), 6);
    w.put(low(e[3][1], 0xf), 4);
    w.put(packDelta5(e[1][2] - e[0][2]), 6);
    w.put(low(e[2][2], 0xf), 4);
    w.put(packDelta5(e[2][0] - e[0][0]), 6);
    w.put(packDelta5(e[3][0] - e[0][0]), 6);
    w.put(r.partition, 5);
    w.indices(&r.sel, r.anchor, 3);
    return r.err;
}

/// Modes 2, 3 and 4: an 11-bit base and deltas of 5 bits in one channel and
/// 4 in the others. The layout is the same for both formats.
fn mode234(comptime signed: bool, pix: *const Pixels, comptime mode: u32, out: *Block) u64 {
    const delta_bits: [3]u32 = switch (mode) {
        2 => .{ 5, 4, 4 },
        3 => .{ 4, 5, 4 },
        4 => .{ 4, 4, 5 },
        else => unreachable,
    };
    const r = twoRegion(.{
        .signed = signed,
        .q_bits = 11,
        .delta_bits = delta_bits,
        .palette = .ten,
        .clamp_lo = if (signed) -1024 else 0,
        .clamp_hi = if (signed) 1023 else 2047,
    }, pix) orelse return err_none;
    const e = epI32(signed, r.ep);
    const bit = BitWriter.bit;
    const low = BitWriter.low;
    var w = BitWriter.init(out);
    w.put(switch (mode) {
        2 => 0x02,
        3 => 0x06,
        4 => 0x0a,
        else => unreachable,
    }, 5);
    w.put(low(e[0][0], 1023), 10);
    w.put(low(e[0][1], 1023), 10);
    w.put(low(e[0][2], 1023), 10);
    const dr1 = e[1][0] - e[0][0];
    const dg1 = e[1][1] - e[0][1];
    const db1 = e[1][2] - e[0][2];
    const dr2 = e[2][0] - e[0][0];
    const dr3 = e[3][0] - e[0][0];
    switch (mode) {
        2 => {
            w.put(packDelta5(dr1), 5);
            w.put(bit(e[0][0], 10), 1);
            w.put(low(e[2][1], 0xf), 4);
            w.put(packDelta5(dg1), 4);
            w.put(bit(e[0][1], 10), 1);
            w.put(low(e[3][2], 1), 1);
            w.put(low(e[3][1], 0xf), 4);
            w.put(packDelta5(db1), 4);
            w.put(bit(e[0][2], 10), 1);
            w.put(bit(e[3][2], 1), 1);
            w.put(low(e[2][2], 0xf), 4);
            w.put(packDelta5(dr2), 5);
            w.put(bit(e[3][2], 2), 1);
            w.put(packDelta5(dr3), 5);
            w.put(bit(e[3][2], 3), 1);
        },
        3 => {
            w.put(packDelta5(dr1), 4);
            w.put(bit(e[0][0], 10), 1);
            w.put(bit(e[3][1], 4), 1);
            w.put(low(e[2][1], 0xf), 4);
            w.put(packDelta5(dg1), 5);
            w.put(bit(e[0][1], 10), 1);
            w.put(low(e[3][1], 0xf), 4);
            w.put(packDelta5(db1), 4);
            w.put(bit(e[0][2], 10), 1);
            w.put(bit(e[3][2], 1), 1);
            w.put(low(e[2][2], 0xf), 4);
            w.put(packDelta5(dr2), 4);
            w.put(low(e[3][2], 1), 1);
            w.put(bit(e[3][2], 2), 1);
            w.put(packDelta5(dr3), 4);
            w.put(bit(e[2][1], 4), 1);
            w.put(bit(e[3][2], 3), 1);
        },
        4 => {
            w.put(packDelta5(dr1), 4);
            w.put(bit(e[0][0], 10), 1);
            w.put(bit(e[2][2], 4), 1);
            w.put(low(e[2][1], 0xf), 4);
            w.put(packDelta5(dg1), 4);
            w.put(bit(e[0][1], 10), 1);
            w.put(low(e[3][2], 1), 1);
            w.put(low(e[3][1], 0xf), 4);
            w.put(packDelta5(db1), 5);
            w.put(bit(e[0][2], 10), 1);
            w.put(low(e[2][2], 0xf), 4);
            w.put(packDelta5(dr2), 4);
            w.put(bit(e[3][2], 1), 1);
            w.put(bit(e[3][2], 2), 1);
            w.put(packDelta5(dr3), 4);
            w.put(bit(e[3][2], 4), 1);
            w.put(bit(e[3][2], 3), 1);
        },
        else => unreachable,
    }
    w.put(r.partition, 5);
    w.indices(&r.sel, r.anchor, 3);
    return r.err;
}

fn mode5(comptime signed: bool, pix: *const Pixels, out: *Block) u64 {
    const r = twoRegion(.{
        .signed = signed,
        .q_bits = 9,
        .delta_bits = .{ 5, 5, 5 },
        .palette = .ten,
        .clamp_lo = if (signed) -256 else 0,
        .clamp_hi = if (signed) 255 else 511,
    }, pix) orelse return err_none;
    const e = epI32(signed, r.ep);
    const bit = BitWriter.bit;
    const low = BitWriter.low;
    const base = struct {
        fn f(v: i32) u32 {
            return if (signed) packSignedN(v, 9) else @intCast(v);
        }
    }.f;
    var w = BitWriter.init(out);
    w.put(0x0e, 5);
    w.put(base(e[0][0]), 9);
    w.put(bit(e[2][2], 4), 1);
    w.put(base(e[0][1]), 9);
    w.put(bit(e[2][1], 4), 1);
    w.put(base(e[0][2]), 9);
    w.put(bit(e[3][2], 4), 1);
    w.put(packDelta5(e[1][0] - e[0][0]), 5);
    w.put(bit(e[3][1], 4), 1);
    w.put(low(e[2][1], 0xf), 4);
    w.put(packDelta5(e[1][1] - e[0][1]), 5);
    w.put(low(e[3][2], 1), 1);
    w.put(low(e[3][1], 0xf), 4);
    w.put(packDelta5(e[1][2] - e[0][2]), 5);
    w.put(bit(e[3][2], 1), 1);
    w.put(low(e[2][2], 0xf), 4);
    w.put(packDelta5(e[2][0] - e[0][0]), 5);
    w.put(bit(e[3][2], 2), 1);
    w.put(packDelta5(e[3][0] - e[0][0]), 5);
    w.put(bit(e[3][2], 3), 1);
    w.put(r.partition, 5);
    w.indices(&r.sel, r.anchor, 3);
    return r.err;
}

fn mode678Config(comptime signed: bool, comptime mode: u32) TwoRegionConfig {
    return .{
        .signed = signed,
        .q_bits = 8,
        .delta_bits = switch (mode) {
            6 => .{ 6, 5, 5 },
            7 => .{ 5, 6, 5 },
            8 => .{ 5, 5, 6 },
            else => unreachable,
        },
        .palette = .ten,
        .clamp_lo = if (signed) -128 else 0,
        .clamp_hi = if (signed) 127 else 255,
    };
}

fn modeCode678(comptime mode: u32) u32 {
    return switch (mode) {
        6 => 0x12,
        7 => 0x16,
        8 => 0x1a,
        else => unreachable,
    };
}

/// Modes 6, 7 and 8, unsigned: an 8-bit base and deltas of 6 bits in one
/// channel and 5 in the others.
fn mode678Uf16(pix: *const Pixels, comptime mode: u32, out: *Block) u64 {
    const r = twoRegion(mode678Config(false, mode), pix) orelse return err_none;
    const e = epI32(false, r.ep);
    const bit = BitWriter.bit;
    const low = BitWriter.low;
    var w = BitWriter.init(out);
    w.put(modeCode678(mode), 5);
    const dr1 = e[1][0] - e[0][0];
    const dg1 = e[1][1] - e[0][1];
    const db1 = e[1][2] - e[0][2];
    const dr2 = e[2][0] - e[0][0];
    const dr3 = e[3][0] - e[0][0];
    switch (mode) {
        6 => {
            w.put(@intCast(e[0][0]), 8);
            w.put(bit(e[3][1], 4), 1);
            w.put(bit(e[2][2], 4), 1);
            w.put(@intCast(e[0][1]), 8);
            w.put(bit(e[3][2], 2), 1);
            w.put(bit(e[2][1], 4), 1);
            w.put(@intCast(e[0][2]), 8);
            w.put(bit(e[3][2], 3), 1);
            w.put(bit(e[3][2], 4), 1);
            w.put(packDelta5(dr1), 6);
            w.put(low(e[2][1], 0xf), 4);
            w.put(packDelta5(dg1), 5);
            w.put(low(e[3][2], 1), 1);
            w.put(low(e[3][1], 0xf), 4);
            w.put(packDelta5(db1), 5);
            w.put(bit(e[3][2], 1), 1);
            w.put(low(e[2][2], 0xf), 4);
            w.put(packDelta5(dr2), 6);
            w.put(packDelta5(dr3), 6);
        },
        7 => {
            w.put(@intCast(e[0][0]), 8);
            w.put(low(e[3][2], 1), 1);
            w.put(bit(e[2][2], 4), 1);
            w.put(@intCast(e[0][1]), 8);
            w.put(bit(e[2][1], 5), 1);
            w.put(bit(e[2][1], 4), 1);
            w.put(@intCast(e[0][2]), 8);
            w.put(bit(e[3][1], 5), 1);
            w.put(bit(e[3][2], 4), 1);
            w.put(packDelta5(dr1), 5);
            w.put(bit(e[3][1], 4), 1);
            w.put(low(e[2][1], 0xf), 4);
            w.put(packDelta5(dg1), 6);
            w.put(low(e[3][1], 0xf), 4);
            w.put(packDelta5(db1), 5);
            w.put(bit(e[3][2], 1), 1);
            w.put(low(e[2][2], 0xf), 4);
            w.put(packDelta5(dr2), 5);
            w.put(bit(e[3][2], 2), 1);
            w.put(packDelta5(dr3), 5);
            w.put(bit(e[3][2], 3), 1);
        },
        8 => {
            w.put(@intCast(e[0][0]), 8);
            w.put(bit(e[3][2], 1), 1);
            w.put(bit(e[2][2], 4), 1);
            w.put(@intCast(e[0][1]), 8);
            w.put(bit(e[2][2], 5), 1);
            w.put(bit(e[2][1], 4), 1);
            w.put(@intCast(e[0][2]), 8);
            w.put(bit(e[3][2], 5), 1);
            w.put(bit(e[3][2], 4), 1);
            w.put(packDelta5(dr1), 5);
            w.put(bit(e[3][1], 4), 1);
            w.put(low(e[2][1], 0xf), 4);
            w.put(packDelta5(dg1), 5);
            w.put(low(e[3][2], 1), 1);
            w.put(low(e[3][1], 0xf), 4);
            w.put(packDelta5(db1), 6);
            w.put(low(e[2][2], 0xf), 4);
            w.put(packDelta5(dr2), 5);
            w.put(bit(e[3][2], 2), 1);
            w.put(packDelta5(dr3), 5);
            w.put(bit(e[3][2], 3), 1);
        },
        else => unreachable,
    }
    w.put(r.partition, 5);
    w.indices(&r.sel, r.anchor, 3);
    return r.err;
}

/// Modes 6, 7 and 8, signed. The C writes each base's low 8 bits after two
/// stray high bits and only the first region's deltas, so these blocks do
/// not decode as the search assumed (see doc/bc6h-quality.md).
fn mode678Sf16(pix: *const Pixels, comptime mode: u32, out: *Block) u64 {
    const cfg = comptime mode678Config(true, mode);
    const r = twoRegion(cfg, pix) orelse return err_none;
    const e = r.ep;
    var w = BitWriter.init(out);
    w.put(modeCode678(mode), 5);
    for (0..3) |c| {
        const lo8 = @as(u32, @bitCast(e[0][c])) & 255;
        const hi2 = (@as(u32, @bitCast(e[0][c])) >> 8) & 3;
        w.put((hi2 >> 1) & 1, 1);
        w.put(hi2 & 1, 1);
        w.put(lo8, 8);
    }
    for (0..3) |c| w.put(packDelta5(e[1][c] - e[0][c]), cfg.delta_bits.?[c]);
    w.put(r.partition, 5);
    // The block is short of its 128 bits: the indices end early.
    for (r.sel, 0..) |s, i| w.put(s, if (i == 0 or i == r.anchor) 2 else 3);
    assert(w.pos < 128);
    return r.err;
}

/// Mode 9: two regions with all four 6-bit endpoints stored directly.
fn mode9(comptime signed: bool, pix: *const Pixels, out: *Block) u64 {
    const r = twoRegion(.{
        .signed = signed,
        .q_bits = 6,
        .delta_bits = null,
        .palette = .six,
        .clamp_lo = if (signed) -32 else 0,
        .clamp_hi = if (signed) 31 else 63,
    }, pix) orelse return err_none;
    const e = epI32(signed, r.ep);
    var rgb: [3][4]u32 = undefined;
    for (0..3) |c| for (0..4) |k| {
        rgb[c][k] = @as(u32, @bitCast(e[k][c])) & 63;
    };
    const R = rgb[0];
    const G = rgb[1];
    const B = rgb[2];
    var w = BitWriter.init(out);
    w.put(30, 5);
    w.put(R[0], 6);
    w.put((G[3] >> 4) & 1, 1);
    w.put(B[3] & 1, 1);
    w.put((B[3] >> 1) & 1, 1);
    w.put((B[2] >> 4) & 1, 1);
    w.put(G[0], 6);
    w.put((G[2] >> 5) & 1, 1);
    w.put((B[2] >> 5) & 1, 1);
    w.put((B[3] >> 2) & 1, 1);
    w.put((G[2] >> 4) & 1, 1);
    w.put(B[0], 6);
    w.put((G[3] >> 5) & 1, 1);
    w.put((B[3] >> 3) & 1, 1);
    w.put((B[3] >> 5) & 1, 1);
    w.put((B[3] >> 4) & 1, 1);
    w.put(R[1], 6);
    w.put(G[2] & 0xf, 4);
    w.put(G[1], 6);
    w.put(G[3] & 0xf, 4);
    w.put(B[1], 6);
    w.put(B[2] & 0xf, 4);
    w.put(R[2], 6);
    w.put(R[3], 6);
    w.put(r.partition, 5);
    w.indices(&r.sel, r.anchor, 3);
    return r.err;
}

// --- One-region modes ---------------------------------------------------------

/// Mode 10 (code 00011): two 10-bit endpoints stored directly.
fn packMode10(comptime signed: bool, r: *const OneRegion(signed), out: *Block) void {
    var w = BitWriter.init(out);
    w.put(0x03, 5);
    for ([2][3]Int(signed){ r.lo, r.hi }) |ep| {
        for (ep) |v| w.put(if (signed) packSigned10(v) else v, 10);
    }
    w.indices(&r.sel, 0, 4);
}

fn mode10Uf16(pix: *const Pixels, out: *Block) u64 {
    var r = oneRegion(false, pix, 10, .unsigned);
    packMode10(false, &r, out);
    return chooseSelectors(false, &r.target, &r.lo, &r.hi, &r.sel);
}

/// Mode 12: a 12-bit base (high two bits stored reversed) and 8-bit deltas.
fn mode12Uf16(pix: *const Pixels, out: *Block) u64 {
    out.* = @splat(0);
    var r = oneRegion(false, pix, 12, .unsigned);
    var d: [3]i32 = undefined;
    for (0..3) |c| d[c] = @as(i32, @intCast(r.hi[c])) - @as(i32, @intCast(r.lo[c]));
    for (d) |dc| if (dc < -128 or dc > 127) return err_none;
    var w = BitWriter.init(out);
    w.put(0x0b, 5);
    for (r.lo) |v| w.put(v & 1023, 10);
    for (0..3) |c| {
        const hi2 = (r.lo[c] >> 10) & 3;
        w.put(@as(u32, @bitCast(d[c])) & 0xff, 8);
        w.put(((hi2 & 1) << 1) | ((hi2 >> 1) & 1), 2);
    }
    w.indices(&r.sel, 0, 4);
    return chooseSelectors(false, &r.target, &r.lo, &r.hi, &r.sel);
}

/// Mode 13: a 16-bit base (high six bits stored reversed) and 4-bit deltas.
fn mode13Uf16(pix: *const Pixels, out: *Block) u64 {
    out.* = @splat(0);
    var r = oneRegion(false, pix, 16, .unsigned);
    var d: [3]i32 = undefined;
    for (0..3) |c| d[c] = @as(i32, @intCast(r.hi[c])) - @as(i32, @intCast(r.lo[c]));
    for (d) |dc| if (dc < -8 or dc > 7) return err_none;
    var w = BitWriter.init(out);
    w.put(0x0f, 5);
    for (r.lo) |v| w.put(v & 1023, 10);
    for (0..3) |c| {
        const hi6 = (r.lo[c] >> 10) & 63;
        w.put(@as(u32, @bitCast(d[c])) & 0xf, 4);
        w.put(@bitReverse(@as(u6, @intCast(hi6))), 6);
    }
    w.indices(&r.sel, 0, 4);
    return chooseSelectors(false, &r.target, &r.lo, &r.hi, &r.sel);
}

/// Mode 12, signed. Unlike the unsigned packer, the C does not reverse the
/// base's high bits here.
fn mode12Sf16(pix: *const Pixels, out: *Block) u64 {
    out.* = @splat(0);
    var r = oneRegion(true, pix, 12, .unsigned);
    var d: [3]i32 = undefined;
    for (0..3) |c| d[c] = r.hi[c] - r.lo[c];
    for (d) |dc| if (dc < -128 or dc > 127) return err_none;
    var w = BitWriter.init(out);
    w.put(0x0b, 5);
    var packed_base: [3]u32 = undefined;
    for (0..3) |c| packed_base[c] = packSignedN(r.lo[c], 12);
    for (packed_base) |p| w.put(p & 1023, 10);
    for (0..3) |c| {
        w.put(@as(u32, @bitCast(d[c])) & 0xff, 8);
        w.put((packed_base[c] >> 10) & 3, 2);
    }
    w.indices(&r.sel, 0, 4);
    return chooseSelectors(true, &r.target, &r.lo, &r.hi, &r.sel);
}

/// Mode 13, signed, again without the high-bit reversal.
fn mode13Sf16(pix: *const Pixels, out: *Block) u64 {
    out.* = @splat(0);
    var r = oneRegion(true, pix, 16, .unsigned);
    var d: [3]i32 = undefined;
    for (0..3) |c| d[c] = r.hi[c] - r.lo[c];
    for (d) |dc| if (dc < -8 or dc > 7) return err_none;
    var w = BitWriter.init(out);
    w.put(0x0f, 5);
    var packed_base: [3]u32 = undefined;
    for (0..3) |c| packed_base[c] = packSignedN(r.lo[c], 16);
    for (packed_base) |p| w.put(p & 1023, 10);
    for (0..3) |c| {
        w.put(@as(u32, @bitCast(d[c])) & 0xf, 4);
        w.put((packed_base[c] >> 10) & 63, 6);
    }
    w.indices(&r.sel, 0, 4);
    return chooseSelectors(true, &r.target, &r.lo, &r.hi, &r.sel);
}

// --- Block encoders -------------------------------------------------------------

/// Keeps `candidate` in `out` when its error beats `best_err`.
fn keepIfBetter(best_err: *u64, out: *Block, err: u64, candidate: *const Block) void {
    if (err < best_err.*) {
        best_err.* = err;
        out.* = candidate.*;
    }
}

/// Encodes 16 texels as an unsigned BC6H block: one-region mode 10 first,
/// then, while the error stays above `err_try_more`, the other modes in the
/// C's order.
pub fn encodeBlockUf16(pix: *const Pixels) Block {
    var out: Block = undefined;
    const r = oneRegion(false, pix, 10, .unsigned);
    packMode10(false, &r, &out);
    var best_err = r.err;
    var tmp: Block = undefined;

    if (best_err > err_try_more) keepIfBetter(&best_err, &out, mode9(false, pix, &tmp), &tmp);
    if (best_err > err_try_more) keepIfBetter(&best_err, &out, mode0(false, pix, &tmp), &tmp);
    if (best_err > err_try_more) keepIfBetter(&best_err, &out, mode1(false, pix, &tmp), &tmp);
    if (best_err > err_try_more) {
        keepIfBetter(&best_err, &out, mode234(false, pix, 2, &tmp), &tmp);
        if (best_err > err_try_more) keepIfBetter(&best_err, &out, mode234(false, pix, 3, &tmp), &tmp);
        if (best_err > err_try_more) keepIfBetter(&best_err, &out, mode234(false, pix, 4, &tmp), &tmp);
    }
    if (best_err > err_try_more) keepIfBetter(&best_err, &out, mode5(false, pix, &tmp), &tmp);
    if (best_err > err_try_more) keepIfBetter(&best_err, &out, mode10Uf16(pix, &tmp), &tmp);
    if (best_err > err_try_more) keepIfBetter(&best_err, &out, mode12Uf16(pix, &tmp), &tmp);
    if (best_err > err_try_more) keepIfBetter(&best_err, &out, mode13Uf16(pix, &tmp), &tmp);
    if (best_err > err_try_more) {
        keepIfBetter(&best_err, &out, mode678Uf16(pix, 6, &tmp), &tmp);
        if (best_err > err_try_more) keepIfBetter(&best_err, &out, mode678Uf16(pix, 7, &tmp), &tmp);
        if (best_err > err_try_more) keepIfBetter(&best_err, &out, mode678Uf16(pix, 8, &tmp), &tmp);
    }
    return out;
}

/// Encodes 16 texels as a signed BC6H block: mode 10, then always modes 12
/// and 13, then every two-region mode while the error stays above
/// `err_try_more`.
pub fn encodeBlockSf16(pix: *const Pixels) Block {
    var out: Block = undefined;
    const r = oneRegion(true, pix, 10, .signed);
    packMode10(true, &r, &out);
    var best_err = r.err;
    var tmp: Block = undefined;

    keepIfBetter(&best_err, &out, mode12Sf16(pix, &tmp), &tmp);
    keepIfBetter(&best_err, &out, mode13Sf16(pix, &tmp), &tmp);
    if (best_err > err_try_more) {
        keepIfBetter(&best_err, &out, mode9(true, pix, &tmp), &tmp);
        keepIfBetter(&best_err, &out, mode0(true, pix, &tmp), &tmp);
        keepIfBetter(&best_err, &out, mode1(true, pix, &tmp), &tmp);
        keepIfBetter(&best_err, &out, mode5(true, pix, &tmp), &tmp);
        inline for (.{ 2, 3, 4 }) |m| keepIfBetter(&best_err, &out, mode234(true, pix, m, &tmp), &tmp);
        inline for (.{ 6, 7, 8 }) |m| keepIfBetter(&best_err, &out, mode678Sf16(pix, m, &tmp), &tmp);
    }
    return out;
}

test "float to half matches known values" {
    try std.testing.expectEqual(@as(u16, 0x3c00), floatToHalfBits(1.0));
    try std.testing.expectEqual(@as(u16, 0xc000), floatToHalfBits(-2.0));
    try std.testing.expectEqual(@as(u16, 0x7bff), floatToHalfBits(65504.0));
    try std.testing.expectEqual(@as(u16, 0x7c00), floatToHalfBits(65520.0));
    try std.testing.expectEqual(@as(u16, 0x0400), floatToHalfBits(6.1035156e-5));
    // The subnormal path drops 2^-24, the smallest half, to zero.
    try std.testing.expectEqual(@as(u16, 0x0000), floatToHalfBits(5.9604645e-8));
    try std.testing.expectEqual(@as(u16, 0x7e00), floatToHalfBits(std.math.nan(f32)));
}
