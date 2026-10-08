//! BC7 block encoder.
//!
//! Translated to Zig from basis_universal encoder/basisu_bc7e_scalar.cpp
//! (tag v2_50), Richard Geldreich's bc7e.ispc as de-vectorized to scalar C++,
//! Copyright 2018-2026 Binomial LLC, used under the Apache License 2.0 (see
//! NOTICE). The translation keeps every arithmetic step, including the float
//! steps and their order, the C's tie-breaking and its float-to-int casts, so
//! that it produces the same bytes as the C++; test/bc7_test.zig checks that.
//! Function and variable names follow the C++ so the two can be read side by
//! side. Not ported: bc7e_compress_block_single_mode (a testing API) and the
//! "used the lookup tables" hint.

const std = @import("std");
const assert = std.debug.assert;

/// Speed and quality presets, fastest first. Each matches a
/// bc7e_compress_block_params_init_* function of the original.
pub const Level = enum(u8) {
    ultrafast,
    veryfast,
    fast,
    basic,
    slow,
    veryslow,
    slowest,
};

/// Encoder settings, laid out exactly as bc7e_compress_block_params so a test
/// can compare them byte for byte. Start from `init` and adjust fields.
pub const Params = extern struct {
    max_partitions_mode: [8]u32,
    /// Per-channel error weights (R, G, B, A).
    weights: [4]u32,
    uber_level: u32,
    refinement_passes: u32,
    mode4_rotation_mask: u32,
    mode4_index_mask: u32,
    mode5_rotation_mask: u32,
    uber1_mask: u32,
    /// Measures error in a luma and chroma space instead of RGB.
    perceptual: bool,
    pbit_search: bool,
    mode6_only: bool,
    /// Allows the precomputed single-colour endpoint tables. Turning them off
    /// avoids extreme endpoints that decode badly under lossy recompression
    /// of the indices.
    use_luts: bool,
    opaque_settings: OpaqueSettings,
    alpha_settings: AlphaSettings,

    pub const OpaqueSettings = extern struct {
        max_mode13_partitions_to_try: u32,
        max_mode0_partitions_to_try: u32,
        max_mode2_partitions_to_try: u32,
        use_mode: [7]bool,
        unused1: bool = false,
    };

    pub const AlphaSettings = extern struct {
        max_mode7_partitions_to_try: u32,
        mode67_error_weight_mul: [4]u32,
        use_mode4: bool,
        use_mode5: bool,
        use_mode6: bool,
        use_mode7: bool,
        use_mode4_rotation: bool,
        use_mode5_rotation: bool,
        unused2: bool = false,
        unused3: bool = false,
    };

    comptime {
        assert(@sizeOf(Params) == 124);
    }

    pub fn init(level: Level, perceptual: bool) Params {
        var p = initBase(perceptual);
        switch (level) {
            .slowest => {
                p.opaque_settings.max_mode13_partitions_to_try = 4;
                p.opaque_settings.max_mode0_partitions_to_try = 4;
                p.opaque_settings.max_mode2_partitions_to_try = 4;
                p.alpha_settings.max_mode7_partitions_to_try = 4;
                p.pbit_search = true;
                p.uber_level = 4;
            },
            .veryslow => {
                p.opaque_settings.max_mode13_partitions_to_try = 2;
                p.opaque_settings.max_mode0_partitions_to_try = 2;
                p.opaque_settings.max_mode2_partitions_to_try = 2;
                p.alpha_settings.max_mode7_partitions_to_try = 2;
                p.pbit_search = true;
                p.uber_level = 2;
            },
            .slow => {
                p.alpha_settings.max_mode7_partitions_to_try = 2;
                p.pbit_search = true;
                p.uber_level = 0;
            },
            .basic => {
                if (perceptual) {
                    p.opaque_settings.use_mode[0] = false;
                    p.opaque_settings.use_mode[2] = false;
                    p.opaque_settings.use_mode[3] = false;
                    p.opaque_settings.use_mode[4] = false;
                    p.opaque_settings.use_mode[5] = false;
                } else {
                    p.max_partitions_mode[1] = 32;
                    p.max_partitions_mode[2] = 32;
                    p.max_partitions_mode[3] = 32;
                    p.max_partitions_mode[7] = 32;
                    p.opaque_settings.use_mode[2] = false;
                }
                p.pbit_search = false;
                p.uber_level = 1;
            },
            .fast => {
                if (perceptual) {
                    p.opaque_settings.use_mode[0] = false;
                    p.opaque_settings.use_mode[2] = false;
                    p.opaque_settings.use_mode[3] = false;
                    p.opaque_settings.use_mode[4] = false;
                    p.opaque_settings.use_mode[5] = false;
                    p.alpha_settings.use_mode5 = false;
                    p.opaque_settings.max_mode13_partitions_to_try = 1;
                } else {
                    p.opaque_settings.use_mode[0] = false;
                    p.opaque_settings.use_mode[2] = false;
                    p.opaque_settings.use_mode[4] = false;
                    p.opaque_settings.use_mode[5] = false;
                    p.alpha_settings.use_mode5 = false;
                    p.opaque_settings.max_mode13_partitions_to_try = 2;
                }
                p.pbit_search = false;
                p.uber_level = 0;
            },
            .veryfast => {
                if (perceptual) {
                    p.opaque_settings.use_mode[0] = false;
                    p.opaque_settings.use_mode[2] = false;
                    p.opaque_settings.use_mode[3] = false;
                    p.opaque_settings.use_mode[4] = false;
                    p.opaque_settings.use_mode[5] = false;
                } else {
                    p.opaque_settings.use_mode[2] = false;
                    p.opaque_settings.use_mode[4] = false;
                    p.opaque_settings.use_mode[5] = false;
                }
                p.alpha_settings.use_mode5 = false;
                p.pbit_search = false;
                p.uber_level = 0;
            },
            .ultrafast => {
                p.mode6_only = true;
                p.alpha_settings.use_mode4 = true;
                p.alpha_settings.use_mode5 = true;
                p.alpha_settings.use_mode7 = false;
                p.mode4_rotation_mask = 1 + 4;
                p.mode4_index_mask = 3;
                p.mode5_rotation_mask = 1;
                p.pbit_search = false;
                p.uber_level = 0;
            },
        }
        p.check();
        return p;
    }

    fn initBase(perceptual: bool) Params {
        return .{
            .max_partitions_mode = .{ max_partitions0, max_partitions1, max_partitions2, max_partitions3, 0, 0, 0, max_partitions7 },
            .use_luts = true,
            .perceptual = perceptual,
            .weights = if (perceptual) .{ 128, 64, 16, 256 } else .{ 1, 1, 1, 1 },
            .pbit_search = false,
            .mode6_only = false,
            .refinement_passes = 1,
            .mode4_rotation_mask = 0xF,
            .mode4_index_mask = 3,
            .mode5_rotation_mask = 0xF,
            .uber1_mask = 7,
            .opaque_settings = .{
                .use_mode = @splat(true),
                .max_mode13_partitions_to_try = 1,
                .max_mode0_partitions_to_try = 1,
                .max_mode2_partitions_to_try = 1,
            },
            .alpha_settings = .{
                .use_mode4 = true,
                .use_mode5 = true,
                .use_mode6 = true,
                .use_mode7 = true,
                .use_mode4_rotation = true,
                .use_mode5_rotation = true,
                .max_mode7_partitions_to_try = 1,
                .mode67_error_weight_mul = .{ 1, 1, 1, 1 },
            },
            .uber_level = 0,
        };
    }

    /// The original asserts these; a zero mask would skip every candidate.
    pub fn check(p: *const Params) void {
        assert(p.mode4_rotation_mask != 0);
        assert(p.mode4_index_mask != 0);
        assert(p.mode5_rotation_mask != 0);
        assert(p.uber1_mask != 0);
        assert(p.uber_level <= max_uber_level);
    }
};

/// Added to denominators that are zero for flat blocks or channels: the
/// original SIMD code let them divide to infinity and clamped later, which in
/// scalar code can turn a NaN into an out-of-range index.
const denom_bias: f32 = 0.0000125;

const checkerboard_partition_index_2subset = 34;
const block_size = 16;
const max_partitions0 = 16;
const max_partitions1 = 64;
const max_partitions2 = 64;
const max_partitions3 = 64;
const max_partitions7 = 64;
const max_uber_level = 4;

const ColorQuadI = [4]i32;
const Vec4F = [4]f32;

// The C++ min, max and clamp templates: `a < b ? a : b` returns the second
// operand on NaN, unlike @min and @max, and clamp is min(max(v, lo), hi) so a
// NaN clamps to lo.
fn minF(a: f32, b: f32) f32 {
    return if (a < b) a else b;
}

fn maxF(a: f32, b: f32) f32 {
    return if (a > b) a else b;
}

fn clampF(v: f32, lo: f32, hi: f32) f32 {
    return minF(maxF(v, lo), hi);
}

fn saturate(v: f32) f32 {
    return clampF(v, 0, 1.0);
}

fn clampI(v: i32, lo: i32, hi: i32) i32 {
    return @min(@max(v, lo), hi);
}

fn square(s: f32) f32 {
    return s * s;
}

fn iabs32(v: i32) i32 {
    assert(v != std.math.minInt(i32));
    return if (v < 0) -v else v;
}

/// The C++ `(int)` cast of a float as x86 performs it (cvttss2si): truncate,
/// and give INT_MIN for NaN or anything out of range. The original reaches
/// out-of-range values in its least-squares paths when the system is nearly
/// singular, so this cannot be a plain @intFromFloat.
fn ftoi(x: f32) i32 {
    if (x >= -2147483648.0 and x < 2147483648.0) return @intFromFloat(x);
    return std.math.minInt(i32);
}

/// The C++ `(int64_t)` cast of a float, as x86 performs it.
fn ftoi64(x: f32) i64 {
    if (x >= -9223372036854775808.0 and x < 9223372036854775808.0) return @intFromFloat(x);
    return std.math.minInt(i64);
}

fn f32FromInt(v: anytype) f32 {
    return @floatFromInt(v);
}

fn vec4FFromColor(c: ColorQuadI) Vec4F {
    return .{ f32FromInt(c[0]), f32FromInt(c[1]), f32FromInt(c[2]), f32FromInt(c[3]) };
}

fn vec4FAdd(a: Vec4F, b: Vec4F) Vec4F {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2], a[3] + b[3] };
}

fn vec4FSub(a: Vec4F, b: Vec4F) Vec4F {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2], a[3] - b[3] };
}

fn vec4FDot(a: Vec4F, b: Vec4F) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3];
}

fn vec4FMul(a: Vec4F, s: f32) Vec4F {
    return .{ a[0] * s, a[1] * s, a[2] * s, a[3] * s };
}

fn vec4FSaturate(a: Vec4F) Vec4F {
    return .{ saturate(a[0]), saturate(a[1]), saturate(a[2]), saturate(a[3]) };
}

fn vec4FNormalizeInPlace(v: *Vec4F) void {
    var s = v[0] * v[0] + v[1] * v[1] + v[2] * v[2] + v[3] * v[3];
    if (s != 0.0) {
        s = 1.0 / @sqrt(s);
        v[0] *= s;
        v[1] *= s;
        v[2] *= s;
        v[3] *= s;
    }
}

pub const weights2 = [4]u32{ 0, 21, 43, 64 };
pub const weights3 = [8]u32{ 0, 9, 18, 27, 37, 46, 55, 64 };
pub const weights4 = [16]u32{ 0, 4, 9, 13, 17, 21, 26, 30, 34, 38, 43, 47, 51, 55, 60, 64 };

// For each weight w of the tables above: w * w, (1 - w) * w, (1 - w) * (1 - w)
// and w, as the least squares fit needs them. Rounded to six decimals in the
// original, so they are copied rather than computed.
const weights2x = [_][4]f32{
    .{ 0.000000, 0.000000, 1.000000, 0.000000 },
    .{ 0.107666, 0.220459, 0.451416, 0.328125 },
    .{ 0.451416, 0.220459, 0.107666, 0.671875 },
    .{ 1.000000, 0.000000, 0.000000, 1.000000 },
};

const weights3x = [_][4]f32{
    .{ 0.000000, 0.000000, 1.000000, 0.000000 },
    .{ 0.019775, 0.120850, 0.738525, 0.140625 },
    .{ 0.079102, 0.202148, 0.516602, 0.281250 },
    .{ 0.177979, 0.243896, 0.334229, 0.421875 },
    .{ 0.334229, 0.243896, 0.177979, 0.578125 },
    .{ 0.516602, 0.202148, 0.079102, 0.718750 },
    .{ 0.738525, 0.120850, 0.019775, 0.859375 },
    .{ 1.000000, 0.000000, 0.000000, 1.000000 },
};

const weights4x = [_][4]f32{
    .{ 0.000000, 0.000000, 1.000000, 0.000000 },
    .{ 0.003906, 0.058594, 0.878906, 0.062500 },
    .{ 0.019775, 0.120850, 0.738525, 0.140625 },
    .{ 0.041260, 0.161865, 0.635010, 0.203125 },
    .{ 0.070557, 0.195068, 0.539307, 0.265625 },
    .{ 0.107666, 0.220459, 0.451416, 0.328125 },
    .{ 0.165039, 0.241211, 0.352539, 0.406250 },
    .{ 0.219727, 0.249023, 0.282227, 0.468750 },
    .{ 0.282227, 0.249023, 0.219727, 0.531250 },
    .{ 0.352539, 0.241211, 0.165039, 0.593750 },
    .{ 0.451416, 0.220459, 0.107666, 0.671875 },
    .{ 0.539307, 0.195068, 0.070557, 0.734375 },
    .{ 0.635010, 0.161865, 0.041260, 0.796875 },
    .{ 0.738525, 0.120850, 0.019775, 0.859375 },
    .{ 0.878906, 0.058594, 0.003906, 0.937500 },
    .{ 1.000000, 0.000000, 0.000000, 1.000000 },
};


pub const partition2 = [_]u8{
    0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1,
    0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1,
    0, 1, 1, 1, 0, 1, 1, 1, 0, 1, 1, 1, 0, 1, 1, 1,
    0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 1, 1, 1,
    0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 1, 1,
    0, 0, 1, 1, 0, 1, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1,
    0, 0, 0, 1, 0, 0, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1,
    0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 1, 1, 0, 1, 1, 1,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 1, 1,
    0, 0, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 1, 1, 1, 1, 1, 1,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 1, 1,
    0, 0, 0, 1, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1,
    0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1,
    0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 1, 0, 1, 1, 1, 1,
    0, 1, 1, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 1, 0,
    0, 1, 1, 1, 0, 0, 1, 1, 0, 0, 0, 1, 0, 0, 0, 0,
    0, 0, 1, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 0, 1, 1, 1, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 0,
    0, 1, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 0, 1,
    0, 0, 1, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0,
    0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 0,
    0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0,
    0, 0, 1, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1, 1, 0, 0,
    0, 0, 0, 1, 0, 1, 1, 1, 1, 1, 1, 0, 1, 0, 0, 0,
    0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0,
    0, 1, 1, 1, 0, 0, 0, 1, 1, 0, 0, 0, 1, 1, 1, 0,
    0, 0, 1, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 1, 0, 0,
    0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1,
    0, 0, 0, 0, 1, 1, 1, 1, 0, 0, 0, 0, 1, 1, 1, 1,
    0, 1, 0, 1, 1, 0, 1, 0, 0, 1, 0, 1, 1, 0, 1, 0,
    0, 0, 1, 1, 0, 0, 1, 1, 1, 1, 0, 0, 1, 1, 0, 0,
    0, 0, 1, 1, 1, 1, 0, 0, 0, 0, 1, 1, 1, 1, 0, 0,
    0, 1, 0, 1, 0, 1, 0, 1, 1, 0, 1, 0, 1, 0, 1, 0,
    0, 1, 1, 0, 1, 0, 0, 1, 0, 1, 1, 0, 1, 0, 0, 1,
    0, 1, 0, 1, 1, 0, 1, 0, 1, 0, 1, 0, 0, 1, 0, 1,
    0, 1, 1, 1, 0, 0, 1, 1, 1, 1, 0, 0, 1, 1, 1, 0,
    0, 0, 0, 1, 0, 0, 1, 1, 1, 1, 0, 0, 1, 0, 0, 0,
    0, 0, 1, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 1, 0, 0,
    0, 0, 1, 1, 1, 0, 1, 1, 1, 1, 0, 1, 1, 1, 0, 0,
    0, 1, 1, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0, 1, 1, 0,
    0, 0, 1, 1, 1, 1, 0, 0, 1, 1, 0, 0, 0, 0, 1, 1,
    0, 1, 1, 0, 0, 1, 1, 0, 1, 0, 0, 1, 1, 0, 0, 1,
    0, 0, 0, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 0, 0, 0,
    0, 1, 0, 0, 1, 1, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0,
    0, 0, 1, 0, 0, 1, 1, 1, 0, 0, 1, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 1, 0, 0, 1, 1, 1, 0, 0, 1, 0,
    0, 0, 0, 0, 0, 1, 0, 0, 1, 1, 1, 0, 0, 1, 0, 0,
    0, 1, 1, 0, 1, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 1,
    0, 0, 1, 1, 0, 1, 1, 0, 1, 1, 0, 0, 1, 0, 0, 1,
    0, 1, 1, 0, 0, 0, 1, 1, 1, 0, 0, 1, 1, 1, 0, 0,
    0, 0, 1, 1, 1, 0, 0, 1, 1, 1, 0, 0, 0, 1, 1, 0,
    0, 1, 1, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 0, 0, 1,
    0, 1, 1, 0, 0, 0, 1, 1, 0, 0, 1, 1, 1, 0, 0, 1,
    0, 1, 1, 1, 1, 1, 1, 0, 1, 0, 0, 0, 0, 0, 0, 1,
    0, 0, 0, 1, 1, 0, 0, 0, 1, 1, 1, 0, 0, 1, 1, 1,
    0, 0, 0, 0, 1, 1, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1,
    0, 0, 1, 1, 0, 0, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0,
    0, 0, 1, 0, 0, 0, 1, 0, 1, 1, 1, 0, 1, 1, 1, 0,
    0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 1, 1, 0, 1, 1, 1,
};

pub const partition3 = [_]u8{
    0, 0, 1, 1, 0, 0, 1, 1, 0, 2, 2, 1, 2, 2, 2, 2,
    0, 0, 0, 1, 0, 0, 1, 1, 2, 2, 1, 1, 2, 2, 2, 1,
    0, 0, 0, 0, 2, 0, 0, 1, 2, 2, 1, 1, 2, 2, 1, 1,
    0, 2, 2, 2, 0, 0, 2, 2, 0, 0, 1, 1, 0, 1, 1, 1,
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 1, 1, 2, 2,
    0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 2, 2, 0, 0, 2, 2,
    0, 0, 2, 2, 0, 0, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1,
    0, 0, 1, 1, 0, 0, 1, 1, 2, 2, 1, 1, 2, 2, 1, 1,
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
    0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2,
    0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2,
    0, 0, 1, 2, 0, 0, 1, 2, 0, 0, 1, 2, 0, 0, 1, 2,
    0, 1, 1, 2, 0, 1, 1, 2, 0, 1, 1, 2, 0, 1, 1, 2,
    0, 1, 2, 2, 0, 1, 2, 2, 0, 1, 2, 2, 0, 1, 2, 2,
    0, 0, 1, 1, 0, 1, 1, 2, 1, 1, 2, 2, 1, 2, 2, 2,
    0, 0, 1, 1, 2, 0, 0, 1, 2, 2, 0, 0, 2, 2, 2, 0,
    0, 0, 0, 1, 0, 0, 1, 1, 0, 1, 1, 2, 1, 1, 2, 2,
    0, 1, 1, 1, 0, 0, 1, 1, 2, 0, 0, 1, 2, 2, 0, 0,
    0, 0, 0, 0, 1, 1, 2, 2, 1, 1, 2, 2, 1, 1, 2, 2,
    0, 0, 2, 2, 0, 0, 2, 2, 0, 0, 2, 2, 1, 1, 1, 1,
    0, 1, 1, 1, 0, 1, 1, 1, 0, 2, 2, 2, 0, 2, 2, 2,
    0, 0, 0, 1, 0, 0, 0, 1, 2, 2, 2, 1, 2, 2, 2, 1,
    0, 0, 0, 0, 0, 0, 1, 1, 0, 1, 2, 2, 0, 1, 2, 2,
    0, 0, 0, 0, 1, 1, 0, 0, 2, 2, 1, 0, 2, 2, 1, 0,
    0, 1, 2, 2, 0, 1, 2, 2, 0, 0, 1, 1, 0, 0, 0, 0,
    0, 0, 1, 2, 0, 0, 1, 2, 1, 1, 2, 2, 2, 2, 2, 2,
    0, 1, 1, 0, 1, 2, 2, 1, 1, 2, 2, 1, 0, 1, 1, 0,
    0, 0, 0, 0, 0, 1, 1, 0, 1, 2, 2, 1, 1, 2, 2, 1,
    0, 0, 2, 2, 1, 1, 0, 2, 1, 1, 0, 2, 0, 0, 2, 2,
    0, 1, 1, 0, 0, 1, 1, 0, 2, 0, 0, 2, 2, 2, 2, 2,
    0, 0, 1, 1, 0, 1, 2, 2, 0, 1, 2, 2, 0, 0, 1, 1,
    0, 0, 0, 0, 2, 0, 0, 0, 2, 2, 1, 1, 2, 2, 2, 1,
    0, 0, 0, 0, 0, 0, 0, 2, 1, 1, 2, 2, 1, 2, 2, 2,
    0, 2, 2, 2, 0, 0, 2, 2, 0, 0, 1, 2, 0, 0, 1, 1,
    0, 0, 1, 1, 0, 0, 1, 2, 0, 0, 2, 2, 0, 2, 2, 2,
    0, 1, 2, 0, 0, 1, 2, 0, 0, 1, 2, 0, 0, 1, 2, 0,
    0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 0, 0, 0, 0,
    0, 1, 2, 0, 1, 2, 0, 1, 2, 0, 1, 2, 0, 1, 2, 0,
    0, 1, 2, 0, 2, 0, 1, 2, 1, 2, 0, 1, 0, 1, 2, 0,
    0, 0, 1, 1, 2, 2, 0, 0, 1, 1, 2, 2, 0, 0, 1, 1,
    0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 0, 0, 0, 0, 1, 1,
    0, 1, 0, 1, 0, 1, 0, 1, 2, 2, 2, 2, 2, 2, 2, 2,
    0, 0, 0, 0, 0, 0, 0, 0, 2, 1, 2, 1, 2, 1, 2, 1,
    0, 0, 2, 2, 1, 1, 2, 2, 0, 0, 2, 2, 1, 1, 2, 2,
    0, 0, 2, 2, 0, 0, 1, 1, 0, 0, 2, 2, 0, 0, 1, 1,
    0, 2, 2, 0, 1, 2, 2, 1, 0, 2, 2, 0, 1, 2, 2, 1,
    0, 1, 0, 1, 2, 2, 2, 2, 2, 2, 2, 2, 0, 1, 0, 1,
    0, 0, 0, 0, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1,
    0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 2, 2, 2, 2,
    0, 2, 2, 2, 0, 1, 1, 1, 0, 2, 2, 2, 0, 1, 1, 1,
    0, 0, 0, 2, 1, 1, 1, 2, 0, 0, 0, 2, 1, 1, 1, 2,
    0, 0, 0, 0, 2, 1, 1, 2, 2, 1, 1, 2, 2, 1, 1, 2,
    0, 2, 2, 2, 0, 1, 1, 1, 0, 1, 1, 1, 0, 2, 2, 2,
    0, 0, 0, 2, 1, 1, 1, 2, 1, 1, 1, 2, 0, 0, 0, 2,
    0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 2, 2, 2, 2,
    0, 0, 0, 0, 0, 0, 0, 0, 2, 1, 1, 2, 2, 1, 1, 2,
    0, 1, 1, 0, 0, 1, 1, 0, 2, 2, 2, 2, 2, 2, 2, 2,
    0, 0, 2, 2, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 2, 2,
    0, 0, 2, 2, 1, 1, 2, 2, 1, 1, 2, 2, 0, 0, 2, 2,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 1, 1, 2,
    0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 1,
    0, 2, 2, 2, 1, 2, 2, 2, 0, 2, 2, 2, 1, 2, 2, 2,
    0, 1, 0, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    0, 1, 1, 1, 2, 0, 1, 1, 2, 2, 0, 1, 2, 2, 2, 0,
};

pub const anchor_second_subset = [_]u8{
    15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
    15, 2, 8, 2, 2, 8, 8, 15, 2, 8, 2, 2, 8, 8, 2, 2,
    15, 15, 6, 8, 2, 8, 15, 15, 2, 8, 2, 2, 2, 15, 15, 6,
    6, 2, 6, 8, 15, 15, 2, 2, 15, 15, 15, 15, 15, 2, 2, 15,
};

pub const anchor_third_subset_1 = [_]u8{
    3, 3, 15, 15, 8, 3, 15, 15, 8, 8, 6, 6, 6, 5, 3, 3,
    3, 3, 8, 15, 3, 3, 6, 10, 5, 8, 8, 6, 8, 5, 15, 15,
    8, 15, 3, 5, 6, 10, 8, 15, 15, 3, 15, 5, 15, 15, 15, 15,
    3, 15, 5, 5, 5, 8, 5, 10, 5, 10, 8, 13, 15, 12, 3, 3,
};

pub const anchor_third_subset_2 = [_]u8{
    15, 8, 8, 3, 15, 15, 3, 8, 15, 15, 15, 15, 15, 15, 15, 8,
    15, 8, 15, 3, 15, 8, 15, 8, 3, 15, 6, 10, 15, 15, 10, 8,
    15, 3, 15, 10, 10, 8, 9, 10, 6, 15, 8, 15, 3, 6, 6, 8,
    15, 3, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 3, 15, 15, 8,
};


const num_subsets = [8]u32{ 3, 2, 3, 2, 1, 1, 1, 2 };
const partition_bits = [8]u32{ 4, 6, 6, 6, 0, 0, 0, 6 };
const color_index_bitcount = [8]u32{ 3, 3, 2, 2, 2, 2, 4, 2 };
const alpha_index_bitcount = [8]u32{ 0, 0, 0, 0, 3, 2, 4, 2 };
const mode_has_p_bits = [8]bool{ true, true, false, true, false, false, true, true };
const mode_has_shared_p_bits = [8]bool{ false, true, false, false, false, false, false, false };
const color_precision_table = [8]u32{ 4, 6, 5, 7, 5, 7, 7, 5 };
const alpha_precision_table = [8]u32{ 0, 0, 0, 0, 6, 8, 7, 5 };

fn getColorIndexSize(mode: u32, index_selection_bit: u32) u32 {
    return color_index_bitcount[mode] + index_selection_bit;
}

fn getAlphaIndexSize(mode: u32, index_selection_bit: u32) u32 {
    return alpha_index_bitcount[mode] - index_selection_bit;
}

fn modeHasSeparateAlphaSelectors(mode: u32) bool {
    return mode == 4 or mode == 5;
}

// The selector each single-colour table targets.
const mode_1_optimal_index = 2;
const mode_7_optimal_index = 1;
const mode_6_optimal_index = 5;
const mode_4_optimal_index3 = 2;
const mode_4_optimal_index2 = 1;
const mode_5_optimal_index = 1;
const mode_0_optimal_index = 2;

pub const EndpointErr = extern struct {
    err: u16,
    lo: u8,
    hi: u8,
};

/// Single-colour lookup tables: for each 8-bit value, the endpoint pair (and
/// p-bits) whose interpolation at the mode's optimal index lands nearest.
pub const Tables = struct {
    mode0: [256][2][2]EndpointErr, // [c][hp][lp]
    mode1: [256][2]EndpointErr, // [c][pbit]
    mode6: [256][2][2]EndpointErr, // [c][hp][lp]
    mode7: [256][2][2]EndpointErr, // [c][hp][lp]
    mode4_3: [256]u32, // lo | hi << 8
    mode4_2: [256]u32,
    mode5: [256]u32,
};

/// Built at compile time, so the encoder needs no init call.
pub const tables: Tables = blk: {
    @setEvalBranchQuota(100_000_000);
    break :blk buildTables();
};

/// Endpoint expansion for each table: the 8-bit value an endpoint code and
/// p-bit decode to.
fn expand(comptime table: enum { mode0, mode1, mode6, mode5, mode4, mode7 }, code: u32, pbit: u32) u32 {
    return switch (table) {
        .mode0 => blk: {
            const v = ((code << 1) | pbit) << 3;
            break :blk v | (v >> 5);
        },
        .mode1 => blk: {
            const v = ((code << 1) | pbit) << 1;
            break :blk v | (v >> 7);
        },
        .mode6 => (code << 1) | pbit,
        .mode5 => blk: {
            const v = code << 1;
            break :blk v | (v >> 7);
        },
        .mode4 => blk: {
            const v = code << 3;
            break :blk v | (v >> 5);
        },
        .mode7 => blk: {
            const v = ((code << 1) | pbit) << 2;
            break :blk v | (v >> 6);
        },
    };
}

/// For every target c, updates best[c] with the first (l, h) in the
/// original's scan order (l outer, h inner, replace only on a strictly
/// smaller error) that minimizes (k - c)^2, where k interpolates lows[l] and
/// highs[h] at weight w. The brute force scan is 16 million steps for mode 6,
/// too slow at compile time, so this finds the same pair from the fact that
/// k never decreases as h grows: within a row the earliest h at the smallest
/// distance is the first h reaching c - d, else the first reaching c + d.
fn searchBlock(lows: []const u32, highs: []const u32, w: u32, best: *[256]EndpointErr) void {
    for (lows, 0..) |low, l| {
        var first_h: [256]i16 = @splat(-1);
        var k_prev: u32 = 0;
        for (highs, 0..) |high, h| {
            const k = (low * (64 - w) + high * w + 32) >> 6;
            assert(k <= 255 and k >= k_prev);
            k_prev = k;
            if (first_h[k] < 0) first_h[k] = @intCast(h);
        }
        const k_min = (low * (64 - w) + highs[0] * w + 32) >> 6;
        const k_max = k_prev;
        for (0..256) |c_usize| {
            const c: u32 = @intCast(c_usize);
            var d: u32 = undefined;
            var h: i16 = undefined;
            if (c <= k_min) {
                d = k_min - c;
                h = first_h[k_min];
            } else if (c >= k_max) {
                d = c - k_max;
                h = first_h[k_max];
            } else {
                d = 0;
                while (true) : (d += 1) {
                    if (first_h[c - d] >= 0) {
                        h = first_h[c - d];
                        break;
                    }
                    if (first_h[c + d] >= 0) {
                        h = first_h[c + d];
                        break;
                    }
                }
            }
            assert(h >= 0);
            const err = d * d;
            if (err < best[c].err) {
                best[c] = .{ .err = @intCast(err), .lo = @intCast(l), .hi = @intCast(h) };
            }
        }
    }
}

fn codes(comptime n: u32, comptime table: anytype, pbit: u32) [n]u32 {
    var out: [n]u32 = undefined;
    for (&out, 0..) |*v, i| v.* = expand(table, @intCast(i), pbit);
    return out;
}

const fresh: [256]EndpointErr = @splat(.{ .err = std.math.maxInt(u16), .lo = 0, .hi = 0 });

fn packed16(e: EndpointErr) u32 {
    return @as(u32, e.lo) | (@as(u32, e.hi) << 8);
}

fn buildTables() Tables {
    var t: Tables = undefined;

    // Mode 0: 444.1
    for (0..2) |hp| for (0..2) |lp| {
        var best = fresh;
        searchBlock(&codes(16, .mode0, @intCast(lp)), &codes(16, .mode0, @intCast(hp)), weights3[mode_0_optimal_index], &best);
        for (0..256) |c| t.mode0[c][hp][lp] = best[c];
    };

    // Mode 1: 666.1, one p-bit shared by both endpoints
    for (0..2) |lp| {
        var best = fresh;
        const v = codes(64, .mode1, @intCast(lp));
        searchBlock(&v, &v, weights3[mode_1_optimal_index], &best);
        for (0..256) |c| t.mode1[c][lp] = best[c];
    }

    // Mode 6: 777.1, 4-bit indices
    for (0..2) |hp| for (0..2) |lp| {
        var best = fresh;
        searchBlock(&codes(128, .mode6, @intCast(lp)), &codes(128, .mode6, @intCast(hp)), weights4[mode_6_optimal_index], &best);
        for (0..256) |c| t.mode6[c][hp][lp] = best[c];
    };

    // Mode 5: 777, 2-bit indices
    {
        var best = fresh;
        const v = codes(128, .mode5, 0);
        searchBlock(&v, &v, weights2[mode_5_optimal_index], &best);
        for (0..256) |c| t.mode5[c] = packed16(best[c]);
    }

    // Mode 4: 555, 3-bit and 2-bit indices
    {
        var best3 = fresh;
        var best2 = fresh;
        const v = codes(32, .mode4, 0);
        searchBlock(&v, &v, weights3[mode_4_optimal_index3], &best3);
        searchBlock(&v, &v, weights2[mode_4_optimal_index2], &best2);
        for (0..256) |c| {
            t.mode4_3[c] = packed16(best3[c]);
            t.mode4_2[c] = packed16(best2[c]);
        }
    }

    // Mode 7: 555.1, 2-bit indices. The original keeps one running best per
    // value across all four p-bit pairs instead of restarting it, so a later
    // entry can hold an earlier pair's endpoints; kept for identical output.
    {
        var best = fresh;
        for (0..2) |hp| for (0..2) |lp| {
            searchBlock(&codes(32, .mode7, @intCast(lp)), &codes(32, .mode7, @intCast(hp)), weights2[mode_7_optimal_index], &best);
            for (0..256) |c| t.mode7[c][hp][lp] = best[c];
        };
    }
    return t;
}

/// The original's brute force table build, for the test that checks the
/// search above against it.
fn buildTablesBruteForce() Tables {
    var t: Tables = undefined;
    const Scan = struct {
        fn run(best: *EndpointErr, c: u32, lows: []const u32, highs: []const u32, w: u32) void {
            for (lows, 0..) |low, l| for (highs, 0..) |high, h| {
                const k: i32 = @intCast((low * (64 - w) + high * w + 32) >> 6);
                const err: u32 = @intCast((k - @as(i32, @intCast(c))) * (k - @as(i32, @intCast(c))));
                if (err < best.err) best.* = .{ .err = @intCast(err), .lo = @intCast(l), .hi = @intCast(h) };
            };
        }
    };
    for (0..256) |c_usize| {
        const c: u32 = @intCast(c_usize);
        for (0..2) |hp| for (0..2) |lp| {
            var best = fresh[0];
            Scan.run(&best, c, &codes(16, .mode0, @intCast(lp)), &codes(16, .mode0, @intCast(hp)), weights3[mode_0_optimal_index]);
            t.mode0[c][hp][lp] = best;
            best = fresh[0];
            Scan.run(&best, c, &codes(128, .mode6, @intCast(lp)), &codes(128, .mode6, @intCast(hp)), weights4[mode_6_optimal_index]);
            t.mode6[c][hp][lp] = best;
        };
        for (0..2) |lp| {
            var best = fresh[0];
            Scan.run(&best, c, &codes(64, .mode1, @intCast(lp)), &codes(64, .mode1, @intCast(lp)), weights3[mode_1_optimal_index]);
            t.mode1[c][lp] = best;
        }
        var best = fresh[0];
        Scan.run(&best, c, &codes(128, .mode5, 0), &codes(128, .mode5, 0), weights2[mode_5_optimal_index]);
        t.mode5[c] = packed16(best);
        best = fresh[0];
        Scan.run(&best, c, &codes(32, .mode4, 0), &codes(32, .mode4, 0), weights3[mode_4_optimal_index3]);
        t.mode4_3[c] = packed16(best);
        best = fresh[0];
        Scan.run(&best, c, &codes(32, .mode4, 0), &codes(32, .mode4, 0), weights2[mode_4_optimal_index2]);
        t.mode4_2[c] = packed16(best);
        best = fresh[0];
        for (0..2) |hp| for (0..2) |lp| {
            Scan.run(&best, c, &codes(32, .mode7, @intCast(lp)), &codes(32, .mode7, @intCast(hp)), weights2[mode_7_optimal_index]);
            t.mode7[c][hp][lp] = best;
        };
    }
    return t;
}

test "compile-time tables match the original's brute force build" {
    const want = buildTablesBruteForce();
    try std.testing.expectEqualDeep(want, tables);
}
