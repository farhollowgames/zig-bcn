//! BC1, BC3, BC4 and BC5 block encoders.
//!
//! Translated to Zig from stb_dxt.h v1.12 (nothings/stb, commit 2c980bb),
//! originally by Fabian "ryg" Giesen and ported to C by Sean Barrett, used
//! here under its MIT licence (see NOTICE). The translation keeps every
//! arithmetic step, including the float steps and their order, so that it
//! produces the same bytes as the C; test/differential.zig checks that.

const std = @import("std");
const assert = std.debug.assert;

pub const Quality = enum(u1) {
    normal,
    /// Two refinement steps instead of one; about 30 to 40 percent slower.
    high,
};

/// How the encoder expects decoders to interpolate the two middle colours.
pub const Rounding = enum(u1) {
    /// Truncating, as the S3TC and DX10 specifications define it; AMD, S3
    /// and the DX10 reference rasterizer decode this way.
    spec,
    /// With a rounding bias, closer to ideal interpolation; NVIDIA and Intel
    /// GPUs of about 2010 and the DX9 reference decode closer to this. This is
    /// stb_dxt's STB_DXT_USE_ROUNDING_BIAS.
    biased,
};

pub const Settings = struct {
    quality: Quality = .normal,
    rounding: Rounding = .spec,
};

/// Encodes the RGB of 16 pixels (row-major) as a 4-colour BC1 colour block,
/// as stb_compress_dxt_block does without alpha. Alpha is not stored, but
/// stb compares whole pixels to detect a constant block, so a varying alpha
/// can change the result; stb asks for a constant alpha.
pub fn encodeColorBlock(pixels: *const [16][4]u8, settings: Settings) [8]u8 {
    return compressColorBlock(pixels, settings);
}

/// Encodes 16 RGBA pixels as a BC3 block, as stb_compress_dxt_block does
/// with alpha: the alpha block, then the colour block of the pixels made
/// opaque.
pub fn encodeAlphaColorBlock(pixels: *const [16][4]u8, settings: Settings) [16]u8 {
    var alpha: [16]u8 = undefined;
    for (pixels, &alpha) |p, *a| a.* = p[3];
    // The copy is opaque because the constant-block test compares alpha too.
    var opaque_pixels = pixels.*;
    for (&opaque_pixels) |*p| p[3] = 255;
    return compressAlphaBlock(&alpha) ++ compressColorBlock(&opaque_pixels, settings);
}

/// Encodes 16 single-channel values as a BC4 block (also the alpha half of
/// BC3 and each half of BC5).
pub fn encodeAlphaBlock(values: *const [16]u8) [8]u8 {
    return compressAlphaBlock(values);
}

const omatch5 = [256][2]u8{
    .{ 0, 0 }, .{ 0, 0 }, .{ 0, 1 }, .{ 0, 1 }, .{ 1, 0 }, .{ 1, 0 }, .{ 1, 0 }, .{ 1, 1 },
    .{ 1, 1 }, .{ 1, 1 }, .{ 1, 2 }, .{ 0, 4 }, .{ 2, 1 }, .{ 2, 1 }, .{ 2, 1 }, .{ 2, 2 },
    .{ 2, 2 }, .{ 2, 2 }, .{ 2, 3 }, .{ 1, 5 }, .{ 3, 2 }, .{ 3, 2 }, .{ 4, 0 }, .{ 3, 3 },
    .{ 3, 3 }, .{ 3, 3 }, .{ 3, 4 }, .{ 3, 4 }, .{ 3, 4 }, .{ 3, 5 }, .{ 4, 3 }, .{ 4, 3 },
    .{ 5, 2 }, .{ 4, 4 }, .{ 4, 4 }, .{ 4, 5 }, .{ 4, 5 }, .{ 5, 4 }, .{ 5, 4 }, .{ 5, 4 },
    .{ 6, 3 }, .{ 5, 5 }, .{ 5, 5 }, .{ 5, 6 }, .{ 4, 8 }, .{ 6, 5 }, .{ 6, 5 }, .{ 6, 5 },
    .{ 6, 6 }, .{ 6, 6 }, .{ 6, 6 }, .{ 6, 7 }, .{ 5, 9 }, .{ 7, 6 }, .{ 7, 6 }, .{ 8, 4 },
    .{ 7, 7 }, .{ 7, 7 }, .{ 7, 7 }, .{ 7, 8 }, .{ 7, 8 }, .{ 7, 8 }, .{ 7, 9 }, .{ 8, 7 },
    .{ 8, 7 }, .{ 9, 6 }, .{ 8, 8 }, .{ 8, 8 }, .{ 8, 9 }, .{ 8, 9 }, .{ 9, 8 }, .{ 9, 8 },
    .{ 9, 8 }, .{ 10, 7 }, .{ 9, 9 }, .{ 9, 9 }, .{ 9, 10 }, .{ 8, 12 }, .{ 10, 9 }, .{ 10, 9 },
    .{ 10, 9 }, .{ 10, 10 }, .{ 10, 10 }, .{ 10, 10 }, .{ 10, 11 }, .{ 9, 13 }, .{ 11, 10 }, .{ 11, 10 },
    .{ 12, 8 }, .{ 11, 11 }, .{ 11, 11 }, .{ 11, 11 }, .{ 11, 12 }, .{ 11, 12 }, .{ 11, 12 }, .{ 11, 13 },
    .{ 12, 11 }, .{ 12, 11 }, .{ 13, 10 }, .{ 12, 12 }, .{ 12, 12 }, .{ 12, 13 }, .{ 12, 13 }, .{ 13, 12 },
    .{ 13, 12 }, .{ 13, 12 }, .{ 14, 11 }, .{ 13, 13 }, .{ 13, 13 }, .{ 13, 14 }, .{ 12, 16 }, .{ 14, 13 },
    .{ 14, 13 }, .{ 14, 13 }, .{ 14, 14 }, .{ 14, 14 }, .{ 14, 14 }, .{ 14, 15 }, .{ 13, 17 }, .{ 15, 14 },
    .{ 15, 14 }, .{ 16, 12 }, .{ 15, 15 }, .{ 15, 15 }, .{ 15, 15 }, .{ 15, 16 }, .{ 15, 16 }, .{ 15, 16 },
    .{ 15, 17 }, .{ 16, 15 }, .{ 16, 15 }, .{ 17, 14 }, .{ 16, 16 }, .{ 16, 16 }, .{ 16, 17 }, .{ 16, 17 },
    .{ 17, 16 }, .{ 17, 16 }, .{ 17, 16 }, .{ 18, 15 }, .{ 17, 17 }, .{ 17, 17 }, .{ 17, 18 }, .{ 16, 20 },
    .{ 18, 17 }, .{ 18, 17 }, .{ 18, 17 }, .{ 18, 18 }, .{ 18, 18 }, .{ 18, 18 }, .{ 18, 19 }, .{ 17, 21 },
    .{ 19, 18 }, .{ 19, 18 }, .{ 20, 16 }, .{ 19, 19 }, .{ 19, 19 }, .{ 19, 19 }, .{ 19, 20 }, .{ 19, 20 },
    .{ 19, 20 }, .{ 19, 21 }, .{ 20, 19 }, .{ 20, 19 }, .{ 21, 18 }, .{ 20, 20 }, .{ 20, 20 }, .{ 20, 21 },
    .{ 20, 21 }, .{ 21, 20 }, .{ 21, 20 }, .{ 21, 20 }, .{ 22, 19 }, .{ 21, 21 }, .{ 21, 21 }, .{ 21, 22 },
    .{ 20, 24 }, .{ 22, 21 }, .{ 22, 21 }, .{ 22, 21 }, .{ 22, 22 }, .{ 22, 22 }, .{ 22, 22 }, .{ 22, 23 },
    .{ 21, 25 }, .{ 23, 22 }, .{ 23, 22 }, .{ 24, 20 }, .{ 23, 23 }, .{ 23, 23 }, .{ 23, 23 }, .{ 23, 24 },
    .{ 23, 24 }, .{ 23, 24 }, .{ 23, 25 }, .{ 24, 23 }, .{ 24, 23 }, .{ 25, 22 }, .{ 24, 24 }, .{ 24, 24 },
    .{ 24, 25 }, .{ 24, 25 }, .{ 25, 24 }, .{ 25, 24 }, .{ 25, 24 }, .{ 26, 23 }, .{ 25, 25 }, .{ 25, 25 },
    .{ 25, 26 }, .{ 24, 28 }, .{ 26, 25 }, .{ 26, 25 }, .{ 26, 25 }, .{ 26, 26 }, .{ 26, 26 }, .{ 26, 26 },
    .{ 26, 27 }, .{ 25, 29 }, .{ 27, 26 }, .{ 27, 26 }, .{ 28, 24 }, .{ 27, 27 }, .{ 27, 27 }, .{ 27, 27 },
    .{ 27, 28 }, .{ 27, 28 }, .{ 27, 28 }, .{ 27, 29 }, .{ 28, 27 }, .{ 28, 27 }, .{ 29, 26 }, .{ 28, 28 },
    .{ 28, 28 }, .{ 28, 29 }, .{ 28, 29 }, .{ 29, 28 }, .{ 29, 28 }, .{ 29, 28 }, .{ 30, 27 }, .{ 29, 29 },
    .{ 29, 29 }, .{ 29, 30 }, .{ 29, 30 }, .{ 30, 29 }, .{ 30, 29 }, .{ 30, 29 }, .{ 30, 30 }, .{ 30, 30 },
    .{ 30, 30 }, .{ 30, 31 }, .{ 30, 31 }, .{ 31, 30 }, .{ 31, 30 }, .{ 31, 30 }, .{ 31, 31 }, .{ 31, 31 },
};

const omatch6 = [256][2]u8{
    .{ 0, 0 }, .{ 0, 1 }, .{ 1, 0 }, .{ 1, 1 }, .{ 1, 1 }, .{ 1, 2 }, .{ 2, 1 }, .{ 2, 2 },
    .{ 2, 2 }, .{ 2, 3 }, .{ 3, 2 }, .{ 3, 3 }, .{ 3, 3 }, .{ 3, 4 }, .{ 4, 3 }, .{ 4, 4 },
    .{ 4, 4 }, .{ 4, 5 }, .{ 5, 4 }, .{ 5, 5 }, .{ 5, 5 }, .{ 5, 6 }, .{ 6, 5 }, .{ 6, 6 },
    .{ 6, 6 }, .{ 6, 7 }, .{ 7, 6 }, .{ 7, 7 }, .{ 7, 7 }, .{ 7, 8 }, .{ 8, 7 }, .{ 8, 8 },
    .{ 8, 8 }, .{ 8, 9 }, .{ 9, 8 }, .{ 9, 9 }, .{ 9, 9 }, .{ 9, 10 }, .{ 10, 9 }, .{ 10, 10 },
    .{ 10, 10 }, .{ 10, 11 }, .{ 11, 10 }, .{ 8, 16 }, .{ 11, 11 }, .{ 11, 12 }, .{ 12, 11 }, .{ 9, 17 },
    .{ 12, 12 }, .{ 12, 13 }, .{ 13, 12 }, .{ 11, 16 }, .{ 13, 13 }, .{ 13, 14 }, .{ 14, 13 }, .{ 12, 17 },
    .{ 14, 14 }, .{ 14, 15 }, .{ 15, 14 }, .{ 14, 16 }, .{ 15, 15 }, .{ 15, 16 }, .{ 16, 14 }, .{ 16, 15 },
    .{ 17, 14 }, .{ 16, 16 }, .{ 16, 17 }, .{ 17, 16 }, .{ 18, 15 }, .{ 17, 17 }, .{ 17, 18 }, .{ 18, 17 },
    .{ 20, 14 }, .{ 18, 18 }, .{ 18, 19 }, .{ 19, 18 }, .{ 21, 15 }, .{ 19, 19 }, .{ 19, 20 }, .{ 20, 19 },
    .{ 20, 20 }, .{ 20, 20 }, .{ 20, 21 }, .{ 21, 20 }, .{ 21, 21 }, .{ 21, 21 }, .{ 21, 22 }, .{ 22, 21 },
    .{ 22, 22 }, .{ 22, 22 }, .{ 22, 23 }, .{ 23, 22 }, .{ 23, 23 }, .{ 23, 23 }, .{ 23, 24 }, .{ 24, 23 },
    .{ 24, 24 }, .{ 24, 24 }, .{ 24, 25 }, .{ 25, 24 }, .{ 25, 25 }, .{ 25, 25 }, .{ 25, 26 }, .{ 26, 25 },
    .{ 26, 26 }, .{ 26, 26 }, .{ 26, 27 }, .{ 27, 26 }, .{ 24, 32 }, .{ 27, 27 }, .{ 27, 28 }, .{ 28, 27 },
    .{ 25, 33 }, .{ 28, 28 }, .{ 28, 29 }, .{ 29, 28 }, .{ 27, 32 }, .{ 29, 29 }, .{ 29, 30 }, .{ 30, 29 },
    .{ 28, 33 }, .{ 30, 30 }, .{ 30, 31 }, .{ 31, 30 }, .{ 30, 32 }, .{ 31, 31 }, .{ 31, 32 }, .{ 32, 30 },
    .{ 32, 31 }, .{ 33, 30 }, .{ 32, 32 }, .{ 32, 33 }, .{ 33, 32 }, .{ 34, 31 }, .{ 33, 33 }, .{ 33, 34 },
    .{ 34, 33 }, .{ 36, 30 }, .{ 34, 34 }, .{ 34, 35 }, .{ 35, 34 }, .{ 37, 31 }, .{ 35, 35 }, .{ 35, 36 },
    .{ 36, 35 }, .{ 36, 36 }, .{ 36, 36 }, .{ 36, 37 }, .{ 37, 36 }, .{ 37, 37 }, .{ 37, 37 }, .{ 37, 38 },
    .{ 38, 37 }, .{ 38, 38 }, .{ 38, 38 }, .{ 38, 39 }, .{ 39, 38 }, .{ 39, 39 }, .{ 39, 39 }, .{ 39, 40 },
    .{ 40, 39 }, .{ 40, 40 }, .{ 40, 40 }, .{ 40, 41 }, .{ 41, 40 }, .{ 41, 41 }, .{ 41, 41 }, .{ 41, 42 },
    .{ 42, 41 }, .{ 42, 42 }, .{ 42, 42 }, .{ 42, 43 }, .{ 43, 42 }, .{ 40, 48 }, .{ 43, 43 }, .{ 43, 44 },
    .{ 44, 43 }, .{ 41, 49 }, .{ 44, 44 }, .{ 44, 45 }, .{ 45, 44 }, .{ 43, 48 }, .{ 45, 45 }, .{ 45, 46 },
    .{ 46, 45 }, .{ 44, 49 }, .{ 46, 46 }, .{ 46, 47 }, .{ 47, 46 }, .{ 46, 48 }, .{ 47, 47 }, .{ 47, 48 },
    .{ 48, 46 }, .{ 48, 47 }, .{ 49, 46 }, .{ 48, 48 }, .{ 48, 49 }, .{ 49, 48 }, .{ 50, 47 }, .{ 49, 49 },
    .{ 49, 50 }, .{ 50, 49 }, .{ 52, 46 }, .{ 50, 50 }, .{ 50, 51 }, .{ 51, 50 }, .{ 53, 47 }, .{ 51, 51 },
    .{ 51, 52 }, .{ 52, 51 }, .{ 52, 52 }, .{ 52, 52 }, .{ 52, 53 }, .{ 53, 52 }, .{ 53, 53 }, .{ 53, 53 },
    .{ 53, 54 }, .{ 54, 53 }, .{ 54, 54 }, .{ 54, 54 }, .{ 54, 55 }, .{ 55, 54 }, .{ 55, 55 }, .{ 55, 55 },
    .{ 55, 56 }, .{ 56, 55 }, .{ 56, 56 }, .{ 56, 56 }, .{ 56, 57 }, .{ 57, 56 }, .{ 57, 57 }, .{ 57, 57 },
    .{ 57, 58 }, .{ 58, 57 }, .{ 58, 58 }, .{ 58, 58 }, .{ 58, 59 }, .{ 59, 58 }, .{ 59, 59 }, .{ 59, 59 },
    .{ 59, 60 }, .{ 60, 59 }, .{ 60, 60 }, .{ 60, 60 }, .{ 60, 61 }, .{ 61, 60 }, .{ 61, 61 }, .{ 61, 61 },
    .{ 61, 62 }, .{ 62, 61 }, .{ 62, 62 }, .{ 62, 62 }, .{ 62, 63 }, .{ 63, 62 }, .{ 63, 63 }, .{ 63, 63 },
};

const midpoints5 = [32]f32{
    0.015686, 0.047059, 0.078431, 0.111765, 0.145098, 0.176471, 0.207843, 0.241176,
    0.274510, 0.305882, 0.337255, 0.370588, 0.403922, 0.435294, 0.466667, 0.5,
    0.533333, 0.564706, 0.596078, 0.629412, 0.662745, 0.694118, 0.725490, 0.758824,
    0.792157, 0.823529, 0.854902, 0.888235, 0.921569, 0.952941, 0.984314, 1.0,
};

const midpoints6 = [64]f32{
    0.007843, 0.023529, 0.039216, 0.054902, 0.070588, 0.086275, 0.101961, 0.117647,
    0.133333, 0.149020, 0.164706, 0.180392, 0.196078, 0.211765, 0.227451, 0.245098,
    0.262745, 0.278431, 0.294118, 0.309804, 0.325490, 0.341176, 0.356863, 0.372549,
    0.388235, 0.403922, 0.419608, 0.435294, 0.450980, 0.466667, 0.482353, 0.500000,
    0.517647, 0.533333, 0.549020, 0.564706, 0.580392, 0.596078, 0.611765, 0.627451,
    0.643137, 0.658824, 0.674510, 0.690196, 0.705882, 0.721569, 0.737255, 0.754902,
    0.772549, 0.788235, 0.803922, 0.819608, 0.835294, 0.850980, 0.866667, 0.882353,
    0.898039, 0.913725, 0.929412, 0.945098, 0.960784, 0.976471, 0.992157, 1.0,
};

fn mul8Bit(a: i32, b: i32) i32 {
    const t = a * b + 128;
    return (t + (t >> 8)) >> 8;
}

fn from16Bit(v: u16) [3]u8 {
    const rv: u32 = (v & 0xf800) >> 11;
    const gv: u32 = (v & 0x07e0) >> 5;
    const bv: u32 = (v & 0x001f) >> 0;
    // Expands to 8 bits by bit replication.
    return .{
        @intCast((rv * 33) >> 2),
        @intCast((gv * 65) >> 4),
        @intCast((bv * 33) >> 2),
    };
}

fn as16Bit(r: i32, g: i32, b: i32) u16 {
    assert(r >= 0 and r <= 255 and g >= 0 and g <= 255 and b >= 0 and b <= 255);
    return @intCast((mul8Bit(r, 31) << 11) + (mul8Bit(g, 63) << 5) + mul8Bit(b, 31));
}

/// The point a third of the way from a to b, as `rounding` decodes it.
fn lerp13(a: i32, b: i32, rounding: Rounding) i32 {
    assert(a >= 0 and a <= 255 and b >= 0 and b <= 255);
    return switch (rounding) {
        .spec => @divTrunc(2 * a + b, 3),
        .biased => a + mul8Bit(b - a, 0x55),
    };
}

fn lerp13Rgb(p1: [3]u8, p2: [3]u8, rounding: Rounding) [3]u8 {
    var out: [3]u8 = undefined;
    for (0..3) |c| out[c] = @intCast(lerp13(p1[c], p2[c], rounding));
    return out;
}

/// The four palette colours of a 4-colour block, as stb orders them.
fn evalColors(c0: u16, c1: u16, rounding: Rounding) [4][3]u8 {
    const a = from16Bit(c0);
    const b = from16Bit(c1);
    return .{ a, b, lerp13Rgb(a, b, rounding), lerp13Rgb(b, a, rounding) };
}

fn matchColorsBlock(block: *const [16][4]u8, color: *const [4][3]u8) u32 {
    const dirr = @as(i32, color[0][0]) - color[1][0];
    const dirg = @as(i32, color[0][1]) - color[1][1];
    const dirb = @as(i32, color[0][2]) - color[1][2];

    var dots: [16]i32 = undefined;
    for (block, &dots) |p, *d| d.* = @as(i32, p[0]) * dirr + @as(i32, p[1]) * dirg + @as(i32, p[2]) * dirb;

    var stops: [4]i32 = undefined;
    for (color, &stops) |c, *s| s.* = @as(i32, c[0]) * dirr + @as(i32, c[1]) * dirg + @as(i32, c[2]) * dirb;

    // Projects each pixel onto the line through the endpoints and picks the
    // nearest stop along it. The 1D approximation is not always the
    // euclidean optimum, but it is very close and much faster
    // (cbloomrants.blogspot.com/2008/12/12-08-08-dxtc-summary.html).
    const c0_point = stops[1] + stops[3];
    const half_point = stops[3] + stops[2];
    const c3_point = stops[2] + stops[0];

    var mask: u32 = 0;
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        const dot = dots[i] * 2;
        mask <<= 2;
        if (dot < half_point) {
            mask |= if (dot < c0_point) 1 else 3;
        } else {
            mask |= if (dot < c3_point) 2 else 0;
        }
    }
    return mask;
}

const Endpoints = struct { max16: u16, min16: u16 };

/// Picks endpoints from the block's extremes along its principal axis, found
/// by power iteration on the colour covariance.
fn optimizeColorsBlock(block: *const [16][4]u8) Endpoints {
    const iter_power_count = 4;

    var mu: [3]i32 = undefined;
    var min: [3]i32 = undefined;
    var max: [3]i32 = undefined;
    for (0..3) |ch| {
        var muv: i32 = block[0][ch];
        var minv: i32 = block[0][ch];
        var maxv: i32 = block[0][ch];
        for (block[1..]) |p| {
            const v: i32 = p[ch];
            muv += v;
            if (v < minv) {
                minv = v;
            } else if (v > maxv) {
                maxv = v;
            }
        }
        mu[ch] = (muv + 8) >> 4;
        min[ch] = minv;
        max[ch] = maxv;
    }

    var cov: [6]i32 = @splat(0);
    for (block) |p| {
        const r = @as(i32, p[0]) - mu[0];
        const g = @as(i32, p[1]) - mu[1];
        const b = @as(i32, p[2]) - mu[2];
        cov[0] += r * r;
        cov[1] += r * g;
        cov[2] += r * b;
        cov[3] += g * g;
        cov[4] += g * b;
        cov[5] += b * b;
    }

    var covf: [6]f32 = undefined;
    for (cov, &covf) |c, *f| f.* = @as(f32, @floatFromInt(c)) / 255.0;

    var vfr: f32 = @floatFromInt(max[0] - min[0]);
    var vfg: f32 = @floatFromInt(max[1] - min[1]);
    var vfb: f32 = @floatFromInt(max[2] - min[2]);
    for (0..iter_power_count) |_| {
        const r = vfr * covf[0] + vfg * covf[1] + vfb * covf[2];
        const g = vfr * covf[1] + vfg * covf[3] + vfb * covf[4];
        const b = vfr * covf[2] + vfg * covf[4] + vfb * covf[5];
        vfr = r;
        vfg = g;
        vfb = b;
    }

    // stb widens to double here; the products below round as doubles.
    var magn: f64 = @abs(@as(f64, vfr));
    if (@abs(@as(f64, vfg)) > magn) magn = @abs(@as(f64, vfg));
    if (@abs(@as(f64, vfb)) > magn) magn = @abs(@as(f64, vfb));

    var v_r: i32 = undefined;
    var v_g: i32 = undefined;
    var v_b: i32 = undefined;
    if (magn < 4.0) {
        // Too little spread to trust the axis; fall back to luma (JPEG YCbCr
        // coefficients times 1000).
        v_r = 299;
        v_g = 587;
        v_b = 114;
    } else {
        magn = 512.0 / magn;
        v_r = @intFromFloat(@as(f64, vfr) * magn);
        v_g = @intFromFloat(@as(f64, vfg) * magn);
        v_b = @intFromFloat(@as(f64, vfb) * magn);
    }
    assert(@abs(v_r) <= 1000 and @abs(v_g) <= 1000 and @abs(v_b) <= 1000);

    var min_index: usize = 0;
    var max_index: usize = 0;
    var mind = @as(i32, block[0][0]) * v_r + @as(i32, block[0][1]) * v_g + @as(i32, block[0][2]) * v_b;
    var maxd = mind;
    for (block[1..], 1..) |p, i| {
        const dot = @as(i32, p[0]) * v_r + @as(i32, p[1]) * v_g + @as(i32, p[2]) * v_b;
        if (dot < mind) {
            mind = dot;
            min_index = i;
        }
        if (dot > maxd) {
            maxd = dot;
            max_index = i;
        }
    }

    const maxp = block[max_index];
    const minp = block[min_index];
    return .{
        .max16 = as16Bit(maxp[0], maxp[1], maxp[2]),
        .min16 = as16Bit(minp[0], minp[1], minp[2]),
    };
}

fn quantize5(x_in: f32) u16 {
    const x: f32 = if (x_in < 0) 0 else if (x_in > 1) 1 else x_in;
    var q: u16 = @intFromFloat(x * 31);
    q += @intFromBool(x > midpoints5[q]);
    assert(q <= 31);
    return q;
}

fn quantize6(x_in: f32) u16 {
    const x: f32 = if (x_in < 0) 0 else if (x_in > 1) 1 else x_in;
    var q: u16 = @intFromFloat(x * 63);
    q += @intFromBool(x > midpoints6[q]);
    assert(q <= 63);
    return q;
}

fn singleColor(r: usize, g: usize, b: usize) Endpoints {
    return .{
        .max16 = (@as(u16, omatch5[r][0]) << 11) | (@as(u16, omatch6[g][0]) << 5) | omatch5[b][0],
        .min16 = (@as(u16, omatch5[r][1]) << 11) | (@as(u16, omatch6[g][1]) << 5) | omatch5[b][1],
    };
}

/// Refits the endpoints to the current indices by least squares (normal
/// equations solved with Cramer's rule). Returns whether they changed.
fn refineBlock(block: *const [16][4]u8, endpoints: *Endpoints, mask: u32) bool {
    const w1_tab = [4]i32{ 3, 0, 2, 1 };
    // The weight products of the least squares system for each index, packed
    // into one integer so a single add accumulates all three sums.
    const prods = [4]i32{ 0x090000, 0x000900, 0x040102, 0x010402 };

    const old = endpoints.*;
    var new: Endpoints = undefined;

    if ((mask ^ (mask << 2)) < 4) {
        // Every pixel has the same index, so the system is singular; use the
        // optimal single-colour match for the average colour instead.
        var r: i32 = 8;
        var g: i32 = 8;
        var b: i32 = 8;
        for (block) |p| {
            r += p[0];
            g += p[1];
            b += p[2];
        }
        new = singleColor(@intCast(r >> 4), @intCast(g >> 4), @intCast(b >> 4));
    } else {
        var akku: i32 = 0;
        var at1 = [3]i32{ 0, 0, 0 };
        var at2 = [3]i32{ 0, 0, 0 };
        var cm = mask;
        for (block) |p| {
            const step = cm & 3;
            cm >>= 2;
            const w1 = w1_tab[step];
            akku += prods[step];
            for (0..3) |c| {
                at1[c] += w1 * p[c];
                at2[c] += p[c];
            }
        }
        for (0..3) |c| at2[c] = 3 * at2[c] - at1[c];

        const xx = akku >> 16;
        const yy = (akku >> 8) & 0xff;
        const xy = (akku >> 0) & 0xff;
        // Mixed indices make the determinant positive (Cauchy-Schwarz).
        assert(xx * yy - xy * xy > 0);

        const f: f32 = 3.0 / 255.0 / @as(f32, @floatFromInt(xx * yy - xy * xy));
        const solve = struct {
            fn hi(a1: i32, a2: i32, y: i32, x: i32, ff: f32) f32 {
                return @as(f32, @floatFromInt(a1 * y - a2 * x)) * ff;
            }
        }.hi;

        new.max16 = quantize5(solve(at1[0], at2[0], yy, xy, f)) << 11;
        new.max16 |= quantize6(solve(at1[1], at2[1], yy, xy, f)) << 5;
        new.max16 |= quantize5(solve(at1[2], at2[2], yy, xy, f)) << 0;

        new.min16 = quantize5(solve(at2[0], at1[0], xx, xy, f)) << 11;
        new.min16 |= quantize6(solve(at2[1], at1[1], xx, xy, f)) << 5;
        new.min16 |= quantize5(solve(at2[2], at1[2], xx, xy, f)) << 0;
    }

    endpoints.* = new;
    return old.min16 != new.min16 or old.max16 != new.max16;
}

fn compressColorBlock(block: *const [16][4]u8, settings: Settings) [8]u8 {
    const refine_count: u32 = switch (settings.quality) {
        .normal => 1,
        .high => 2,
    };

    var mask: u32 = undefined;
    var ep: Endpoints = undefined;

    const constant = for (block[1..]) |p| {
        if (!std.mem.eql(u8, &p, &block[0])) break false;
    } else true;

    if (constant) {
        mask = 0xaaaaaaaa;
        ep = singleColor(block[0][0], block[0][1], block[0][2]);
    } else {
        // Principal axis first, then least squares refinement.
        ep = optimizeColorsBlock(block);
        if (ep.max16 != ep.min16) {
            const color = evalColors(ep.max16, ep.min16, settings.rounding);
            mask = matchColorsBlock(block, &color);
        } else {
            mask = 0;
        }

        for (0..refine_count) |_| {
            const last_mask = mask;
            if (refineBlock(block, &ep, mask)) {
                if (ep.max16 != ep.min16) {
                    const color = evalColors(ep.max16, ep.min16, settings.rounding);
                    mask = matchColorsBlock(block, &color);
                } else {
                    mask = 0;
                    break;
                }
            }
            if (mask == last_mask) break;
        }
    }

    // max16 must come first so the block decodes in 4-colour mode.
    if (ep.max16 < ep.min16) {
        std.mem.swap(u16, &ep.max16, &ep.min16);
        mask ^= 0x55555555;
    }
    assert(ep.max16 >= ep.min16);

    var dest: [8]u8 = undefined;
    std.mem.writeInt(u16, dest[0..2], ep.max16, .little);
    std.mem.writeInt(u16, dest[2..4], ep.min16, .little);
    std.mem.writeInt(u32, dest[4..8], mask, .little);
    return dest;
}

fn compressAlphaBlock(src: *const [16]u8) [8]u8 {
    var mn: i32 = src[0];
    var mx: i32 = src[0];
    for (src[1..]) |v| {
        if (v < mn) {
            mn = v;
        } else if (v > mx) {
            mx = v;
        }
    }

    var dest: [8]u8 = undefined;
    dest[0] = @intCast(mx);
    dest[1] = @intCast(mn);

    // Given these endpoints, the indices below are optimal
    // (fgiesen.wordpress.com/2009/12/15/dxt5-alpha-block-index-determination).
    const dist = mx - mn;
    assert(dist >= 0);
    const dist4 = dist * 4;
    const dist2 = dist * 2;
    var bias: i32 = if (dist < 8) dist - 1 else @divTrunc(dist, 2) + 2;
    bias -= mn * 7;

    var bits: u5 = 0;
    var mask: u32 = 0;
    var out: usize = 2;
    for (src) |v| {
        var a = @as(i32, v) * 7 + bias;

        // A linear lerp factor from 0 (the minimum) to 7 (the maximum),
        // found branch-free with masks.
        var t: i32 = if (a >= dist4) -1 else 0;
        var ind: i32 = t & 4;
        a -= dist4 & t;
        t = if (a >= dist2) -1 else 0;
        ind += t & 2;
        a -= dist2 & t;
        ind += @intFromBool(a >= dist);

        // Maps the linear factor onto BC4 index order, where 0 and 1 are the
        // endpoints.
        ind = -ind & 7;
        ind ^= @intFromBool(2 > ind);
        assert(ind >= 0 and ind <= 7);

        mask |= @as(u32, @intCast(ind)) << bits;
        bits += 3;
        if (bits >= 8) {
            dest[out] = @truncate(mask);
            out += 1;
            mask >>= 8;
            bits -= 8;
        }
    }
    assert(out == 8);
    return dest;
}

/// stb_dxt's STB_DXT_GENERATE_TABLES program: the optimal endpoint pair for
/// each 8-bit value of a single-colour block. The decode error counts 100
/// per step, plus 3 per step of endpoint distance, since DX10 lets hardware
/// interpolate up to 3 percent off.
fn generateOMatch(comptime size: u32, comptime dequant: i32) [256][2]u8 {
    @setEvalBranchQuota(10_000_000);
    var table: [256][2]u8 = undefined;
    for (&table, 0..) |*entry, j| {
        var best_mn: u32 = 0;
        var best_mx: u32 = 0;
        var best_err: i32 = 256 * 100;
        for (0..size) |mn| {
            for (0..size) |mx| {
                const mine = (@as(i32, @intCast(mn)) * dequant) >> 4;
                const maxe = (@as(i32, @intCast(mx)) * dequant) >> 4;
                var err: i32 = @intCast(@abs(lerp13(maxe, mine, .spec) - @as(i32, @intCast(j))) * 100);
                err += @intCast(@abs(maxe - mine) * 3);
                if (err < best_err) {
                    best_mn = @intCast(mn);
                    best_mx = @intCast(mx);
                    best_err = err;
                }
            }
        }
        entry.* = .{ @intCast(best_mx), @intCast(best_mn) };
    }
    return table;
}

test "the single-colour tables are what stb's generator produces" {
    // .4 fixed-point dequantization multipliers, as in the generator.
    try std.testing.expectEqual(omatch5, generateOMatch(32, 33 * 4));
    try std.testing.expectEqual(omatch6, generateOMatch(64, 65));
}
