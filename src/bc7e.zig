//! BC7 block encoder.
//!
//! Translated to Zig from basis_universal encoder/basisu_bc7e_scalar.cpp
//! (tag v2_50), Richard Geldreich's bc7e.ispc as de-vectorized to scalar C++,
//! Copyright 2018-2026 Binomial LLC, used under the Apache License 2.0 (see
//! NOTICE). The translation keeps every arithmetic step, including the float
//! steps and their order, the C's tie-breaking and its float-to-int casts, so
//! that it produces the same bytes as the C++; test/bc7_test.zig checks that.
//! Function and variable names follow the C++ so the two can be read side by
//! side.

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
        var p = initDefaults(perceptual);
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

    /// The base settings every level starts from
    /// (bc7e_compress_block_params_init): all modes, one partition each,
    /// no p-bit search and no uber search.
    pub fn initDefaults(perceptual: bool) Params {
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
    15, 2,  8,  2,  2,  8,  8,  15, 2,  8,  2,  2,  8,  8,  2,  2,
    15, 15, 6,  8,  2,  8,  15, 15, 2,  8,  2,  2,  2,  15, 15, 6,
    6,  2,  6,  8,  15, 15, 2,  2,  15, 15, 15, 15, 15, 2,  2,  15,
};

pub const anchor_third_subset_1 = [_]u8{
    3, 3,  15, 15, 8, 3,  15, 15, 8,  8,  6,  6,  6,  5,  3,  3,
    3, 3,  8,  15, 3, 3,  6,  10, 5,  8,  8,  6,  8,  5,  15, 15,
    8, 15, 3,  5,  6, 10, 8,  15, 15, 3,  15, 5,  15, 15, 15, 15,
    3, 15, 5,  5,  5, 8,  5,  10, 5,  10, 8,  13, 15, 12, 3,  3,
};

pub const anchor_third_subset_2 = [_]u8{
    15, 8, 8,  3,  15, 15, 3,  8,  15, 15, 15, 15, 15, 15, 15, 8,
    15, 8, 15, 3,  15, 8,  15, 8,  3,  15, 6,  10, 15, 15, 10, 8,
    15, 3, 15, 10, 10, 8,  9,  10, 6,  15, 8,  15, 3,  6,  6,  8,
    15, 3, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 3,  15, 15, 8,
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

// Least squares fit of the two endpoints to the given selectors, by the
// normal equations
// (http://www.cs.cornell.edu/~bindel/class/cs3220-s12/notes/lec10.pdf),
// expanded by hand as in the original. Channels first..first+count of xl and
// xh are written; the original's rgba, rgb and a variants are the three
// channel ranges.
fn computeLeastSquaresEndpoints(
    comptime first: usize,
    comptime count: usize,
    n: u32,
    selectors: []const i32,
    selector_weightsx: []const [4]f32,
    xl: *Vec4F,
    xh: *Vec4F,
    colors: []const ColorQuadI,
) void {
    assert(n <= 16 and selectors.len >= n and colors.len >= n);
    var z00: f32 = 0.0;
    var z10: f32 = 0.0;
    var z11: f32 = 0.0;
    var q00: [4]f32 = @splat(0.0);
    var t: [4]f32 = @splat(0.0);
    for (0..n) |i| {
        const sel: u32 = @intCast(selectors[i]);
        z00 += selector_weightsx[sel][0];
        z10 += selector_weightsx[sel][1];
        z11 += selector_weightsx[sel][2];
        const w = selector_weightsx[sel][3];
        inline for (first..first + count) |c| {
            q00[c] += w * f32FromInt(colors[i][c]);
            t[c] += f32FromInt(colors[i][c]);
        }
    }

    var q10: [4]f32 = undefined;
    inline for (first..first + count) |c| q10[c] = t[c] - q00[c];

    const z01 = z10;

    var det = z00 * z11 - z01 * z10;
    if (det != 0.0) det = 1.0 / det;

    const iz00 = z11 * det;
    const iz01 = -z01 * det;
    const iz10 = -z10 * det;
    const iz11 = z00 * det;

    inline for (first..first + count) |c| {
        xl[c] = iz00 * q00[c] + iz01 * q10[c];
        xh[c] = iz10 * q00[c] + iz11 * q10[c];
    }
}

fn computeLeastSquaresEndpointsRgba(n: u32, selectors: []const i32, w: []const [4]f32, xl: *Vec4F, xh: *Vec4F, colors: []const ColorQuadI) void {
    computeLeastSquaresEndpoints(0, 4, n, selectors, w, xl, xh, colors);
}

fn computeLeastSquaresEndpointsRgb(n: u32, selectors: []const i32, w: []const [4]f32, xl: *Vec4F, xh: *Vec4F, colors: []const ColorQuadI) void {
    computeLeastSquaresEndpoints(0, 3, n, selectors, w, xl, xh, colors);
}

fn computeLeastSquaresEndpointsA(n: u32, selectors: []const i32, w: []const [4]f32, xl: *f32, xh: *f32, colors: []const ColorQuadI) void {
    var l: Vec4F = @splat(0);
    var h: Vec4F = @splat(0);
    computeLeastSquaresEndpoints(3, 1, n, selectors, w, &l, &h, colors);
    xl.* = l[3];
    xh.* = h[3];
}

const ColorCellCompressorParams = struct {
    num_selector_weights: u32 = 0,
    selector_weights: []const u32 = &.{},
    selector_weightsx: []const [4]f32 = &.{},
    comp_bits: u32 = 0,
    weights: [4]u32 = .{ 1, 1, 1, 1 },
    has_alpha: bool = false,
    has_pbits: bool = false,
    endpoints_share_pbit: bool = false,
    perceptual: bool = false,

    fn setSelectorWeights(p: *ColorCellCompressorParams, comptime bits: u32) void {
        switch (bits) {
            2 => {
                p.selector_weights = &weights2;
                p.selector_weightsx = &weights2x;
            },
            3 => {
                p.selector_weights = &weights3;
                p.selector_weightsx = &weights3x;
            },
            4 => {
                p.selector_weights = &weights4;
                p.selector_weightsx = &weights4x;
            },
            else => unreachable,
        }
        p.num_selector_weights = 1 << bits;
    }
};

const ColorCellCompressorResults = struct {
    best_overall_err: u64 = 0,
    low_endpoint: ColorQuadI = @splat(0),
    high_endpoint: ColorQuadI = @splat(0),
    pbits: [2]u32 = .{ 0, 0 },
    selectors: *[16]i32,
    selectors_temp: *[16]i32,
    /// Whether this subset's result came from the single-colour tables (the
    /// solid path or the mean colour candidate): their endpoints sit at
    /// extremes that only one weight reaches, a hint that the subset is
    /// fragile under lossy recompression of the indices.
    used_lut: bool = false,
};

fn scaleColor(c: ColorQuadI, params: *const ColorCellCompressorParams) ColorQuadI {
    const n: u32 = params.comp_bits + @intFromBool(params.has_pbits);
    assert(n >= 4 and n <= 8);
    var results: ColorQuadI = undefined;
    for (0..4) |i| {
        var v: u32 = @as(u32, @intCast(c[i])) << @intCast(8 - n);
        v |= v >> @intCast(n);
        assert(v <= 255);
        results[i] = @intCast(v);
    }
    return results;
}

// Chroma weights of the perceptual error, from the Rec. 709 luma coefficients.
const pr_weight: f32 = (@as(f32, 0.5) / (@as(f32, 1.0) - @as(f32, 0.2126))) * (@as(f32, 0.5) / (@as(f32, 1.0) - @as(f32, 0.2126)));
const pb_weight: f32 = (@as(f32, 0.5) / (@as(f32, 1.0) - @as(f32, 0.0722))) * (@as(f32, 0.5) / (@as(f32, 1.0) - @as(f32, 0.0722)));

fn computeColorDistanceRgb(e1: ColorQuadI, e2: ColorQuadI, perceptual: bool, weights: [4]u32) u64 {
    if (perceptual) {
        const l1 = f32FromInt(e1[0]) * 0.2126 + f32FromInt(e1[1]) * 0.7152 + f32FromInt(e1[2]) * 0.0722;
        const cr1 = f32FromInt(e1[0]) - l1;
        const cb1 = f32FromInt(e1[2]) - l1;

        const l2 = f32FromInt(e2[0]) * 0.2126 + f32FromInt(e2[1]) * 0.7152 + f32FromInt(e2[2]) * 0.0722;
        const cr2 = f32FromInt(e2[0]) - l2;
        const cb2 = f32FromInt(e2[2]) - l2;

        const dl = l1 - l2;
        const dcr = cr1 - cr2;
        const dcb = cb1 - cb2;

        return @bitCast(ftoi64(f32FromInt(weights[0]) * (dl * dl) + f32FromInt(weights[1]) * pr_weight * (dcr * dcr) + f32FromInt(weights[2]) * pb_weight * (dcb * dcb)));
    } else {
        const dr = f32FromInt(e1[0]) - f32FromInt(e2[0]);
        const dg = f32FromInt(e1[1]) - f32FromInt(e2[1]);
        const db = f32FromInt(e1[2]) - f32FromInt(e2[2]);

        return @bitCast(ftoi64(f32FromInt(weights[0]) * dr * dr + f32FromInt(weights[1]) * dg * dg + f32FromInt(weights[2]) * db * db));
    }
}

fn computeColorDistanceRgba(e1: ColorQuadI, e2: ColorQuadI, perceptual: bool, weights: [4]u32) u64 {
    const da = f32FromInt(e1[3]) - f32FromInt(e2[3]);
    const a_err = f32FromInt(weights[3]) * (da * da);

    if (perceptual) {
        const l1 = f32FromInt(e1[0]) * 0.2126 + f32FromInt(e1[1]) * 0.7152 + f32FromInt(e1[2]) * 0.0722;
        const cr1 = f32FromInt(e1[0]) - l1;
        const cb1 = f32FromInt(e1[2]) - l1;

        const l2 = f32FromInt(e2[0]) * 0.2126 + f32FromInt(e2[1]) * 0.7152 + f32FromInt(e2[2]) * 0.0722;
        const cr2 = f32FromInt(e2[0]) - l2;
        const cb2 = f32FromInt(e2[2]) - l2;

        const dl = l1 - l2;
        const dcr = cr1 - cr2;
        const dcb = cb1 - cb2;

        return @bitCast(ftoi64(f32FromInt(weights[0]) * (dl * dl) + f32FromInt(weights[1]) * pr_weight * (dcr * dcr) + f32FromInt(weights[2]) * pb_weight * (dcb * dcb) + a_err));
    } else {
        const dr = f32FromInt(e1[0]) - f32FromInt(e2[0]);
        const dg = f32FromInt(e1[1]) - f32FromInt(e2[1]);
        const db = f32FromInt(e1[2]) - f32FromInt(e2[2]);

        return @bitCast(ftoi64(f32FromInt(weights[0]) * dr * dr + f32FromInt(weights[1]) * dg * dg + f32FromInt(weights[2]) * db * db + a_err));
    }
}

fn totalColorDistance(comptime rgba: bool, p: ColorQuadI, params: *const ColorCellCompressorParams, num_pixels: u32, pixels: []const ColorQuadI) u64 {
    var total_err: u64 = 0;
    for (pixels[0..num_pixels]) |px| {
        const d = if (rgba)
            computeColorDistanceRgba(p, px, params.perceptual, params.weights)
        else
            computeColorDistanceRgb(p, px, params.perceptual, params.weights);
        total_err +%= d;
    }
    return total_err;
}

fn packMode1ToOneColor(params: *const ColorCellCompressorParams, results: *ColorCellCompressorResults, r: u32, g: u32, b: u32, selectors: *[16]i32, num_pixels: u32, pixels: []const ColorQuadI) u64 {
    var best_err: u32 = std.math.maxInt(u32);
    var best_p: u32 = 0;
    for (0..2) |p| {
        const err: u32 = @as(u32, tables.mode1[r][p].err) + tables.mode1[g][p].err + tables.mode1[b][p].err;
        if (err < best_err) {
            best_err = err;
            best_p = @intCast(p);
        }
    }

    const er = tables.mode1[r][best_p];
    const eg = tables.mode1[g][best_p];
    const eb = tables.mode1[b][best_p];

    results.low_endpoint = .{ er.lo, eg.lo, eb.lo, 0 };
    results.high_endpoint = .{ er.hi, eg.hi, eb.hi, 0 };
    results.pbits = .{ best_p, 0 };

    for (selectors[0..num_pixels]) |*s| s.* = mode_1_optimal_index;

    var p: ColorQuadI = undefined;
    for (0..3) |i| {
        var low: u32 = ((@as(u32, @intCast(results.low_endpoint[i])) << 1) | results.pbits[0]) << 1;
        low |= (low >> 7);
        var high: u32 = ((@as(u32, @intCast(results.high_endpoint[i])) << 1) | results.pbits[0]) << 1;
        high |= (high >> 7);
        p[i] = @intCast((low * (64 - weights3[mode_1_optimal_index]) + high * weights3[mode_1_optimal_index] + 32) >> 6);
    }
    p[3] = 255;

    const total_err = totalColorDistance(false, p, params, num_pixels, pixels);
    results.best_overall_err = total_err;
    return total_err;
}

fn packMode24ToOneColor(params: *const ColorCellCompressorParams, results: *ColorCellCompressorResults, r: u32, g: u32, b: u32, selectors: *[16]i32, num_pixels: u32, pixels: []const ColorQuadI) u64 {
    const three_bit = params.num_selector_weights == 8;
    const table = if (three_bit) &tables.mode4_3 else &tables.mode4_2;
    const er = table[r];
    const eg = table[g];
    const eb = table[b];

    results.low_endpoint = .{ @intCast(er & 0xFF), @intCast(eg & 0xFF), @intCast(eb & 0xFF), 0 };
    results.high_endpoint = .{ @intCast(er >> 8), @intCast(eg >> 8), @intCast(eb >> 8), 0 };

    for (selectors[0..num_pixels]) |*s| s.* = if (three_bit) mode_4_optimal_index3 else mode_4_optimal_index2;

    var p: ColorQuadI = undefined;
    for (0..3) |i| {
        var low: u32 = @as(u32, @intCast(results.low_endpoint[i])) << 3;
        low |= (low >> 5);
        var high: u32 = @as(u32, @intCast(results.high_endpoint[i])) << 3;
        high |= (high >> 5);
        if (three_bit) {
            p[i] = @intCast((low * (64 - weights3[mode_4_optimal_index3]) + high * weights3[mode_4_optimal_index3] + 32) >> 6);
        } else {
            p[i] = @intCast((low * (64 - weights2[mode_4_optimal_index2]) + high * weights2[mode_4_optimal_index2] + 32) >> 6);
        }
    }
    p[3] = 255;

    const total_err = totalColorDistance(false, p, params, num_pixels, pixels);
    results.best_overall_err = total_err;
    return total_err;
}

fn packMode0ToOneColor(params: *const ColorCellCompressorParams, results: *ColorCellCompressorResults, r: u32, g: u32, b: u32, selectors: *[16]i32, num_pixels: u32, pixels: []const ColorQuadI) u64 {
    var best_err: u32 = std.math.maxInt(u32);
    var best_p: u32 = 0;
    for (0..4) |p| {
        const err: u32 = @as(u32, tables.mode0[r][p >> 1][p & 1].err) + tables.mode0[g][p >> 1][p & 1].err + tables.mode0[b][p >> 1][p & 1].err;
        if (err < best_err) {
            best_err = err;
            best_p = @intCast(p);
        }
    }

    const er = tables.mode0[r][best_p >> 1][best_p & 1];
    const eg = tables.mode0[g][best_p >> 1][best_p & 1];
    const eb = tables.mode0[b][best_p >> 1][best_p & 1];

    results.low_endpoint = .{ er.lo, eg.lo, eb.lo, 0 };
    results.high_endpoint = .{ er.hi, eg.hi, eb.hi, 0 };
    results.pbits = .{ best_p & 1, best_p >> 1 };

    for (selectors[0..num_pixels]) |*s| s.* = mode_0_optimal_index;

    var p: ColorQuadI = undefined;
    for (0..3) |i| {
        var low: u32 = ((@as(u32, @intCast(results.low_endpoint[i])) << 1) | results.pbits[0]) << 3;
        low |= (low >> 5);
        var high: u32 = ((@as(u32, @intCast(results.high_endpoint[i])) << 1) | results.pbits[1]) << 3;
        high |= (high >> 5);
        p[i] = @intCast((low * (64 - weights3[mode_0_optimal_index]) + high * weights3[mode_0_optimal_index] + 32) >> 6);
    }
    p[3] = 255;

    const total_err = totalColorDistance(false, p, params, num_pixels, pixels);
    results.best_overall_err = total_err;
    return total_err;
}

/// Modes 6 and 7 share this shape; they differ in table and index.
fn packMode67ToOneColor(comptime mode: u32, params: *const ColorCellCompressorParams, results: *ColorCellCompressorResults, r: u32, g: u32, b: u32, a: u32, selectors: *[16]i32, num_pixels: u32, pixels: []const ColorQuadI) u64 {
    const table = if (mode == 6) &tables.mode6 else &tables.mode7;
    const optimal_index = if (mode == 6) mode_6_optimal_index else mode_7_optimal_index;
    const w = if (mode == 6) weights4[optimal_index] else weights2[optimal_index];

    var best_err: u32 = std.math.maxInt(u32);
    var best_p: u32 = 0;
    for (0..4) |p| {
        const hi_p = p >> 1;
        const lo_p = p & 1;
        const err: u32 = @as(u32, table[r][hi_p][lo_p].err) + table[g][hi_p][lo_p].err + table[b][hi_p][lo_p].err + table[a][hi_p][lo_p].err;
        if (err < best_err) {
            best_err = err;
            best_p = @intCast(p);
        }
    }

    const best_hi_p = best_p >> 1;
    const best_lo_p = best_p & 1;

    const er = table[r][best_hi_p][best_lo_p];
    const eg = table[g][best_hi_p][best_lo_p];
    const eb = table[b][best_hi_p][best_lo_p];
    const ea = table[a][best_hi_p][best_lo_p];

    results.low_endpoint = .{ er.lo, eg.lo, eb.lo, ea.lo };
    results.high_endpoint = .{ er.hi, eg.hi, eb.hi, ea.hi };
    results.pbits = .{ best_lo_p, best_hi_p };

    for (selectors[0..num_pixels]) |*s| s.* = optimal_index;

    var p: ColorQuadI = undefined;
    for (0..4) |i| {
        const low: u32 = (@as(u32, @intCast(results.low_endpoint[i])) << 1) | results.pbits[0];
        const high: u32 = (@as(u32, @intCast(results.high_endpoint[i])) << 1) | results.pbits[1];
        p[i] = @intCast((low * (64 - w) + high * w + 32) >> 6);
    }

    const total_err = totalColorDistance(true, p, params, num_pixels, pixels);
    results.best_overall_err = total_err;
    return total_err;
}

/// The weighted error terms of one palette entry against one pixel, in the
/// original's association order.
fn err3(wr: f32, wg: f32, wb: f32, dr: f32, dg: f32, db: f32) f32 {
    return wr * dr * dr + wg * dg * dg + wb * db * db;
}

fn err4(wr: f32, wg: f32, wb: f32, wa: f32, dr: f32, dg: f32, db: f32, da: f32) f32 {
    return wr * dr * dr + wg * dg * dg + wb * db * db + wa * da * da;
}

fn evaluateSolution(
    low: *const ColorQuadI,
    high: *const ColorQuadI,
    pbits: *const [2]u32,
    params: *const ColorCellCompressorParams,
    results: *ColorCellCompressorResults,
    num_pixels: u32,
    pixels: []const ColorQuadI,
) u64 {
    var quant_min_color = low.*;
    var quant_max_color = high.*;

    if (params.has_pbits) {
        var min_pbit: u32 = undefined;
        var max_pbit: u32 = undefined;
        if (params.endpoints_share_pbit) {
            min_pbit = pbits[0];
            max_pbit = pbits[0];
        } else {
            min_pbit = pbits[0];
            max_pbit = pbits[1];
        }
        for (0..4) |c| {
            quant_min_color[c] = (low[c] << 1) | @as(i32, @intCast(min_pbit));
            quant_max_color[c] = (high[c] << 1) | @as(i32, @intCast(max_pbit));
        }
    }

    const actual_min_color = scaleColor(quant_min_color, params);
    const actual_max_color = scaleColor(quant_max_color, params);

    const n = params.num_selector_weights;
    assert(n == 4 or n == 8 or n == 16);
    const nc: u32 = if (params.has_alpha) 4 else 3;

    var total_errf: f32 = 0;

    const wr = f32FromInt(params.weights[0]);
    var wg = f32FromInt(params.weights[1]);
    var wb = f32FromInt(params.weights[2]);
    const wa = f32FromInt(params.weights[3]);

    // Entries 1..n-2 get only nc channels; the alpha of those is read only
    // when nc is 4.
    var weighted_colors: [16][4]f32 = undefined;
    weighted_colors[0] = vec4FFromColor(actual_min_color);
    weighted_colors[n - 1] = vec4FFromColor(actual_max_color);

    for (1..n - 1) |i| {
        for (0..nc) |j| {
            const sw = f32FromInt(params.selector_weights[i]);
            weighted_colors[i][j] = @floor((weighted_colors[0][j] * (64.0 - sw) + weighted_colors[n - 1][j] * sw + 32) * (1.0 / 64.0));
        }
    }

    const temp = results.selectors_temp;

    if (!params.perceptual) {
        if (!params.has_alpha) {
            if (n == 16) {
                var lr = f32FromInt(actual_min_color[0]);
                var lg = f32FromInt(actual_min_color[1]);
                var lb = f32FromInt(actual_min_color[2]);

                const dr = f32FromInt(actual_max_color[0]) - lr;
                const dg = f32FromInt(actual_max_color[1]) - lg;
                const db = f32FromInt(actual_max_color[2]) - lb;

                const f = f32FromInt(n) / (dr * dr + dg * dg + db * db + denom_bias);

                lr *= -dr;
                lg *= -dg;
                lb *= -db;

                for (0..num_pixels) |i| {
                    const c = pixels[i];
                    const r = f32FromInt(c[0]);
                    const g = f32FromInt(c[1]);
                    const b = f32FromInt(c[2]);

                    var best_sel = @floor(((r * dr + lr) + (g * dg + lg) + (b * db + lb)) * f + 0.5);
                    best_sel = clampF(best_sel, 1, f32FromInt(n - 1));

                    const best_sel0 = best_sel - 1;

                    const w0 = weighted_colors[@intCast(ftoi(best_sel0))];
                    const err0 = err3(wr, wg, wb, w0[0] - r, w0[1] - g, w0[2] - b);

                    const w1 = weighted_colors[@intCast(ftoi(best_sel))];
                    const err1 = err3(wr, wg, wb, w1[0] - r, w1[1] - g, w1[2] - b);

                    const min_err = minF(err0, err1);
                    total_errf += min_err;
                    temp[i] = ftoi(if (min_err == err0) best_sel0 else best_sel);
                }
            } else if (n == 8) {
                for (0..num_pixels) |i| {
                    const pr = f32FromInt(pixels[i][0]);
                    const pg = f32FromInt(pixels[i][1]);
                    const pb = f32FromInt(pixels[i][2]);

                    var e: [8]f32 = undefined;
                    for (0..8) |k| e[k] = err3(wr, wg, wb, weighted_colors[k][0] - pr, weighted_colors[k][1] - pg, weighted_colors[k][2] - pb);

                    var best_err = minF(minF(minF(e[0], e[1]), e[2]), e[3]);
                    var best_sel: i32 = if (best_err == e[1]) 1 else 0;
                    if (best_err == e[2]) best_sel = 2;
                    if (best_err == e[3]) best_sel = 3;

                    best_err = minF(best_err, minF(minF(minF(e[4], e[5]), e[6]), e[7]));
                    if (best_err == e[4]) best_sel = 4;
                    if (best_err == e[5]) best_sel = 5;
                    if (best_err == e[6]) best_sel = 6;
                    if (best_err == e[7]) best_sel = 7;

                    total_errf += best_err;
                    temp[i] = best_sel;
                }
            } else {
                for (0..num_pixels) |i| {
                    const pr = f32FromInt(pixels[i][0]);
                    const pg = f32FromInt(pixels[i][1]);
                    const pb = f32FromInt(pixels[i][2]);

                    var e: [4]f32 = undefined;
                    for (0..4) |k| e[k] = err3(wr, wg, wb, weighted_colors[k][0] - pr, weighted_colors[k][1] - pg, weighted_colors[k][2] - pb);

                    const best_err = minF(minF(minF(e[0], e[1]), e[2]), e[3]);
                    var best_sel: i32 = if (best_err == e[1]) 1 else 0;
                    if (best_err == e[2]) best_sel = 2;
                    if (best_err == e[3]) best_sel = 3;

                    total_errf += best_err;
                    temp[i] = best_sel;
                }
            }
        } else {
            // alpha
            if (n == 16) {
                var lr = f32FromInt(actual_min_color[0]);
                var lg = f32FromInt(actual_min_color[1]);
                var lb = f32FromInt(actual_min_color[2]);
                var la = f32FromInt(actual_min_color[3]);

                const dr = f32FromInt(actual_max_color[0]) - lr;
                const dg = f32FromInt(actual_max_color[1]) - lg;
                const db = f32FromInt(actual_max_color[2]) - lb;
                const da = f32FromInt(actual_max_color[3]) - la;

                const f = f32FromInt(n) / (dr * dr + dg * dg + db * db + da * da + denom_bias);

                lr *= -dr;
                lg *= -dg;
                lb *= -db;
                la *= -da;

                for (0..num_pixels) |i| {
                    const c = pixels[i];
                    const r = f32FromInt(c[0]);
                    const g = f32FromInt(c[1]);
                    const b = f32FromInt(c[2]);
                    const a = f32FromInt(c[3]);

                    var best_sel = @floor(((r * dr + lr) + (g * dg + lg) + (b * db + lb) + (a * da + la)) * f + 0.5);
                    best_sel = clampF(best_sel, 1, f32FromInt(n - 1));

                    const best_sel0 = best_sel - 1;

                    const w0 = weighted_colors[@intCast(ftoi(best_sel0))];
                    const err0 = err4(wr, wg, wb, wa, w0[0] - r, w0[1] - g, w0[2] - b, w0[3] - a);

                    const w1 = weighted_colors[@intCast(ftoi(best_sel))];
                    const err1 = err4(wr, wg, wb, wa, w1[0] - r, w1[1] - g, w1[2] - b, w1[3] - a);

                    const min_err = minF(err0, err1);
                    total_errf += min_err;
                    temp[i] = ftoi(if (min_err == err0) best_sel0 else best_sel);
                }
            } else if (n == 8) {
                for (0..num_pixels) |i| {
                    const pr = f32FromInt(pixels[i][0]);
                    const pg = f32FromInt(pixels[i][1]);
                    const pb = f32FromInt(pixels[i][2]);
                    const pa = f32FromInt(pixels[i][3]);

                    var e: [8]f32 = undefined;
                    for (0..8) |k| e[k] = err4(wr, wg, wb, wa, weighted_colors[k][0] - pr, weighted_colors[k][1] - pg, weighted_colors[k][2] - pb, weighted_colors[k][3] - pa);

                    var best_err = minF(minF(minF(e[0], e[1]), e[2]), e[3]);
                    var best_sel: i32 = if (best_err == e[1]) 1 else 0;
                    if (best_err == e[2]) best_sel = 2;
                    if (best_err == e[3]) best_sel = 3;

                    best_err = minF(best_err, minF(minF(minF(e[4], e[5]), e[6]), e[7]));
                    if (best_err == e[4]) best_sel = 4;
                    if (best_err == e[5]) best_sel = 5;
                    if (best_err == e[6]) best_sel = 6;
                    if (best_err == e[7]) best_sel = 7;

                    total_errf += best_err;
                    temp[i] = best_sel;
                }
            } else {
                for (0..num_pixels) |i| {
                    const pr = f32FromInt(pixels[i][0]);
                    const pg = f32FromInt(pixels[i][1]);
                    const pb = f32FromInt(pixels[i][2]);
                    const pa = f32FromInt(pixels[i][3]);

                    var e: [4]f32 = undefined;
                    for (0..4) |k| e[k] = err4(wr, wg, wb, wa, weighted_colors[k][0] - pr, weighted_colors[k][1] - pg, weighted_colors[k][2] - pb, weighted_colors[k][3] - pa);

                    const best_err = minF(minF(minF(e[0], e[1]), e[2]), e[3]);
                    var best_sel: i32 = if (best_err == e[1]) 1 else 0;
                    if (best_err == e[2]) best_sel = 2;
                    if (best_err == e[3]) best_sel = 3;

                    total_errf += best_err;
                    temp[i] = best_sel;
                }
            }
        }
    } else {
        wg *= pr_weight;
        wb *= pb_weight;

        var weighted_colors_y: [16]f32 = undefined;
        var weighted_colors_cr: [16]f32 = undefined;
        var weighted_colors_cb: [16]f32 = undefined;

        for (0..n) |i| {
            const r = weighted_colors[i][0];
            const g = weighted_colors[i][1];
            const b = weighted_colors[i][2];
            const y = r * 0.2126 + g * 0.7152 + b * 0.0722;
            weighted_colors_y[i] = y;
            weighted_colors_cr[i] = r - y;
            weighted_colors_cb[i] = b - y;
        }

        // Two copies of the loop, as in the original, so the alpha test is
        // not in the inner loop.
        inline for (.{ false, true }) |has_alpha| {
            if (params.has_alpha == has_alpha) {
                for (0..num_pixels) |i| {
                    const r = f32FromInt(pixels[i][0]);
                    const g = f32FromInt(pixels[i][1]);
                    const b = f32FromInt(pixels[i][2]);
                    const a = f32FromInt(pixels[i][3]);

                    const y = r * 0.2126 + g * 0.7152 + b * 0.0722;
                    const cr = r - y;
                    const cb = b - y;

                    var best_err: f32 = 1e+10;
                    var best_sel: i32 = 0;

                    for (0..n) |j| {
                        const dl = y - weighted_colors_y[j];
                        const dcr = cr - weighted_colors_cr[j];
                        const dcb = cb - weighted_colors_cb[j];
                        const err = if (has_alpha)
                            err4(wr, wg, wb, wa, dl, dcr, dcb, a - weighted_colors[j][3])
                        else
                            err3(wr, wg, wb, dl, dcr, dcb);
                        if (err < best_err) {
                            best_err = err;
                            best_sel = @intCast(j);
                        }
                    }

                    total_errf += best_err;
                    temp[i] = best_sel;
                }
            }
        }
    }

    const total_err: u64 = @bitCast(ftoi64(total_errf));

    if (total_err < results.best_overall_err) {
        results.best_overall_err = total_err;
        results.low_endpoint = low.*;
        results.high_endpoint = high.*;
        results.pbits = pbits.*;
        @memcpy(results.selectors[0..num_pixels], temp[0..num_pixels]);
    }

    return total_err;
}

/// When a channel's fitted endpoints quantize to the same value although
/// they differ, every pixel would land on one colour; nudging one endpoint
/// apart keeps the freedom (grayscale ramps show it).
fn fixDegenerateEndpoints(mode: u32, trial_min_color: *ColorQuadI, trial_max_color: *ColorQuadI, xl: *const Vec4F, xh: *const Vec4F, iscale: u32) void {
    if (mode != 1 and mode != 4) return;
    const half: i32 = @intCast(iscale >> 1);
    const top: i32 = @intCast(iscale);
    for (0..3) |i| {
        if (trial_min_color[i] != trial_max_color[i]) continue;
        if (!(@abs(xl[i] - xh[i]) > 0.0)) continue;

        if (trial_min_color[i] > half) {
            if (trial_min_color[i] > 0) {
                trial_min_color[i] -= 1;
            } else if (trial_max_color[i] < top) {
                trial_max_color[i] += 1;
            }
        } else {
            if (trial_max_color[i] < top) {
                trial_max_color[i] += 1;
            } else if (trial_min_color[i] > 0) {
                trial_min_color[i] -= 1;
            }
        }

        if (mode == 4) {
            if (trial_min_color[i] > half) {
                if (trial_max_color[i] < top) {
                    trial_max_color[i] += 1;
                } else if (trial_min_color[i] > 0) {
                    trial_min_color[i] -= 1;
                }
            } else {
                if (trial_min_color[i] > 0) {
                    trial_min_color[i] -= 1;
                } else if (trial_max_color[i] < top) {
                    trial_max_color[i] += 1;
                }
            }
        }
    }
}

/// Quantizes an endpoint with a forced p-bit p: the nearest code whose low
/// bit is p, as a code including the p-bit.
fn quantizeWithPbit(x: f32, scalep: f32, p: i32, iscalep: i32) i32 {
    const v = ftoi((x * scalep - f32FromInt(p)) / 2.0 + 0.5) * 2 + p;
    return clampI(v, p, iscalep - 1 + p);
}

fn findOptimalSolution(
    mode: u32,
    in_xl: *const Vec4F,
    in_xh: *const Vec4F,
    params: *const ColorCellCompressorParams,
    results: *ColorCellCompressorResults,
    pbit_search: bool,
    num_pixels: u32,
    pixels: []const ColorQuadI,
) u64 {
    const xl = vec4FSaturate(in_xl.*);
    const xh = vec4FSaturate(in_xh.*);

    if (params.has_pbits) {
        const iscalep: i32 = (@as(i32, 1) << @intCast(params.comp_bits + 1)) - 1;
        const scalep = f32FromInt(iscalep);

        if (pbit_search) {
            // Compensated rounding and a search over the p-bits.
            var lo: [2]ColorQuadI = undefined;
            var hi: [2]ColorQuadI = undefined;

            for (0..2) |p_usize| {
                const p: i32 = @intCast(p_usize);
                for (0..4) |c| {
                    lo[p_usize][c] = quantizeWithPbit(xl[c], scalep, p, iscalep) >> 1;
                    hi[p_usize][c] = quantizeWithPbit(xh[c], scalep, p, iscalep) >> 1;
                }
            }

            fixDegenerateEndpoints(mode, &lo[0], &hi[0], &xl, &xh, @intCast(iscalep >> 1));
            fixDegenerateEndpoints(mode, &lo[1], &hi[1], &xl, &xh, @intCast(iscalep >> 1));

            if (!params.endpoints_share_pbit) {
                _ = evaluateSolution(&lo[0], &hi[0], &.{ 0, 0 }, params, results, num_pixels, pixels);
                _ = evaluateSolution(&lo[0], &hi[1], &.{ 0, 1 }, params, results, num_pixels, pixels);
                _ = evaluateSolution(&lo[1], &hi[0], &.{ 1, 0 }, params, results, num_pixels, pixels);
                _ = evaluateSolution(&lo[1], &hi[1], &.{ 1, 1 }, params, results, num_pixels, pixels);
            } else {
                _ = evaluateSolution(&lo[0], &hi[0], &.{ 0, 0 }, params, results, num_pixels, pixels);
                _ = evaluateSolution(&lo[1], &hi[1], &.{ 1, 1 }, params, results, num_pixels, pixels);
            }
        } else {
            // Compensated rounding: pick each endpoint's p-bit by its own error.
            const total_comps: usize = if (params.has_alpha) 4 else 3;

            var best_pbits: [2]u32 = .{ 0, 0 };
            var best_min_color: ColorQuadI = @splat(0);
            var best_max_color: ColorQuadI = @splat(0);

            if (!params.endpoints_share_pbit) {
                var best_err0: f32 = 1e+9;
                var best_err1: f32 = 1e+9;

                for (0..2) |p_usize| {
                    const p: i32 = @intCast(p_usize);
                    var x_min_color: ColorQuadI = undefined;
                    var x_max_color: ColorQuadI = undefined;
                    for (0..4) |c| {
                        x_min_color[c] = quantizeWithPbit(xl[c], scalep, p, iscalep);
                        x_max_color[c] = quantizeWithPbit(xh[c], scalep, p, iscalep);
                    }

                    const scaled_low = scaleColor(x_min_color, params);
                    const scaled_high = scaleColor(x_max_color, params);

                    var err0: f32 = 0;
                    var err1: f32 = 0;
                    for (0..total_comps) |i| {
                        err0 += square(f32FromInt(scaled_low[i]) - xl[i] * 255.0);
                        err1 += square(f32FromInt(scaled_high[i]) - xh[i] * 255.0);
                    }

                    if (err0 < best_err0) {
                        best_err0 = err0;
                        best_pbits[0] = @intCast(p);
                        for (0..4) |c| best_min_color[c] = x_min_color[c] >> 1;
                    }
                    if (err1 < best_err1) {
                        best_err1 = err1;
                        best_pbits[1] = @intCast(p);
                        for (0..4) |c| best_max_color[c] = x_max_color[c] >> 1;
                    }
                }
            } else {
                // Endpoints share p-bits.
                var best_err: f32 = 1e+9;

                for (0..2) |p_usize| {
                    const p: i32 = @intCast(p_usize);
                    var x_min_color: ColorQuadI = undefined;
                    var x_max_color: ColorQuadI = undefined;
                    for (0..4) |c| {
                        x_min_color[c] = quantizeWithPbit(xl[c], scalep, p, iscalep);
                        x_max_color[c] = quantizeWithPbit(xh[c], scalep, p, iscalep);
                    }

                    const scaled_low = scaleColor(x_min_color, params);
                    const scaled_high = scaleColor(x_max_color, params);

                    var err: f32 = 0;
                    for (0..total_comps) |i| {
                        err += square((f32FromInt(scaled_low[i]) / 255.0) - xl[i]) + square((f32FromInt(scaled_high[i]) / 255.0) - xh[i]);
                    }

                    if (err < best_err) {
                        best_err = err;
                        best_pbits = .{ @intCast(p), @intCast(p) };
                        for (0..4) |c| {
                            best_min_color[c] = x_min_color[c] >> 1;
                            best_max_color[c] = x_max_color[c] >> 1;
                        }
                    }
                }
            }

            fixDegenerateEndpoints(mode, &best_min_color, &best_max_color, &xl, &xh, @intCast(iscalep >> 1));

            if (results.best_overall_err == std.math.maxInt(u64) or
                !std.mem.eql(i32, &best_min_color, &results.low_endpoint) or
                !std.mem.eql(i32, &best_max_color, &results.high_endpoint) or
                best_pbits[0] != results.pbits[0] or best_pbits[1] != results.pbits[1])
            {
                _ = evaluateSolution(&best_min_color, &best_max_color, &best_pbits, params, results, num_pixels, pixels);
            }
        }
    } else {
        const iscale: i32 = (@as(i32, 1) << @intCast(params.comp_bits)) - 1;
        const scale = f32FromInt(iscale);

        var trial_min_color: ColorQuadI = undefined;
        var trial_max_color: ColorQuadI = undefined;
        for (0..4) |c| {
            trial_min_color[c] = clampI(ftoi(xl[c] * scale + 0.5), 0, 255);
            trial_max_color[c] = clampI(ftoi(xh[c] * scale + 0.5), 0, 255);
        }

        fixDegenerateEndpoints(mode, &trial_min_color, &trial_max_color, &xl, &xh, @intCast(iscale));

        if (results.best_overall_err == std.math.maxInt(u64) or
            !std.mem.eql(i32, &trial_min_color, &results.low_endpoint) or
            !std.mem.eql(i32, &trial_max_color, &results.high_endpoint))
        {
            _ = evaluateSolution(&trial_min_color, &trial_max_color, &.{ 0, 0 }, params, results, num_pixels, pixels);
        }
    }

    return results.best_overall_err;
}

fn leastSquaresThenOptimize(
    mode: u32,
    params: *const ColorCellCompressorParams,
    results: *ColorCellCompressorResults,
    pbit_search: bool,
    num_pixels: u32,
    pixels: []const ColorQuadI,
    selectors: []const i32,
) u64 {
    var xl: Vec4F = @splat(0.0);
    var xh: Vec4F = @splat(0.0);
    if (params.has_alpha) {
        computeLeastSquaresEndpointsRgba(num_pixels, selectors, params.selector_weightsx, &xl, &xh, pixels);
    } else {
        computeLeastSquaresEndpointsRgb(num_pixels, selectors, params.selector_weightsx, &xl, &xh, pixels);
        xl[3] = 255.0;
        xh[3] = 255.0;
    }
    xl = vec4FMul(xl, 1.0 / 255.0);
    xh = vec4FMul(xh, 1.0 / 255.0);
    return findOptimalSolution(mode, &xl, &xh, params, results, pbit_search, num_pixels, pixels);
}

/// Encodes one subset: an initial fit along the principal axis, least
/// squares refinement, the "uber" selector perturbations, and the
/// single-colour tables for the mean colour.
// Note: in mode 6, has_alpha is only true for transparent blocks.
fn colorCellCompression(
    mode: u32,
    params: *const ColorCellCompressorParams,
    results: *ColorCellCompressorResults,
    comp_params: *const Params,
    num_pixels: u32,
    pixels: []const ColorQuadI,
    refinement: bool,
) u64 {
    assert(num_pixels >= 1 and num_pixels <= 16);
    results.best_overall_err = std.math.maxInt(u64);
    results.used_lut = false;

    if (mode != 6 and mode != 7) assert(!params.has_alpha);

    const lut_mode = (mode <= 2) or (mode == 4) or (mode >= 6);
    if (lut_mode) {
        const cr: u32 = @intCast(pixels[0][0]);
        const cg: u32 = @intCast(pixels[0][1]);
        const cb: u32 = @intCast(pixels[0][2]);
        const ca: u32 = @intCast(pixels[0][3]);

        var all_same = true;
        for (pixels[1..num_pixels]) |px| {
            if (!std.mem.eql(i32, &px, &pixels[0])) {
                all_same = false;
                break;
            }
        }

        if (all_same and comp_params.use_luts) {
            results.used_lut = true;
            return switch (mode) {
                0 => packMode0ToOneColor(params, results, cr, cg, cb, results.selectors, num_pixels, pixels),
                1 => packMode1ToOneColor(params, results, cr, cg, cb, results.selectors, num_pixels, pixels),
                6 => packMode67ToOneColor(6, params, results, cr, cg, cb, ca, results.selectors, num_pixels, pixels),
                7 => packMode67ToOneColor(7, params, results, cr, cg, cb, ca, results.selectors, num_pixels, pixels),
                else => packMode24ToOneColor(params, results, cr, cg, cb, results.selectors, num_pixels, pixels),
            };
        }
    }

    var mean_color: Vec4F = @splat(0.0);
    for (pixels[0..num_pixels]) |px| mean_color = vec4FAdd(mean_color, vec4FFromColor(px));

    const mean_color_scaled = vec4FMul(mean_color, 1.0 / f32FromInt(num_pixels));

    mean_color = vec4FMul(mean_color, 1.0 / (f32FromInt(num_pixels) * 255.0));
    mean_color = vec4FSaturate(mean_color);

    var axis: Vec4F = undefined;
    if (params.has_alpha) {
        var v: Vec4F = @splat(0.0);
        for (pixels[0..num_pixels], 0..) |px, i| {
            const color = vec4FSub(vec4FFromColor(px), mean_color_scaled);

            const a = vec4FMul(color, color[0]);
            const b = vec4FMul(color, color[1]);
            const c = vec4FMul(color, color[2]);
            const d = vec4FMul(color, color[3]);

            var n = if (i != 0) v else color;
            vec4FNormalizeInPlace(&n);

            v[0] += vec4FDot(a, n);
            v[1] += vec4FDot(b, n);
            v[2] += vec4FDot(c, n);
            v[3] += vec4FDot(d, n);
        }
        axis = v;
        vec4FNormalizeInPlace(&axis);
    } else {
        var cov: [6]f32 = @splat(0);
        for (pixels[0..num_pixels]) |px| {
            const r = f32FromInt(px[0]) - mean_color_scaled[0];
            const g = f32FromInt(px[1]) - mean_color_scaled[1];
            const b = f32FromInt(px[2]) - mean_color_scaled[2];
            cov[0] += r * r;
            cov[1] += r * g;
            cov[2] += r * b;
            cov[3] += g * g;
            cov[4] += g * b;
            cov[5] += b * b;
        }

        // A fixed start vector is more stable than the bounding box diagonal.
        var vfr: f32 = 0.9;
        var vfg: f32 = 1.0;
        var vfb: f32 = 0.7;

        for (0..3) |_| {
            var r = vfr * cov[0] + vfg * cov[1] + vfb * cov[2];
            var g = vfr * cov[1] + vfg * cov[3] + vfb * cov[4];
            var b = vfr * cov[2] + vfg * cov[4] + vfb * cov[5];

            var m = maxF(maxF(@abs(r), @abs(g)), @abs(b));
            if (m > 1e-10) {
                m = 1.0 / m;
                r *= m;
                g *= m;
                b *= m;
            }

            vfr = r;
            vfg = g;
            vfb = b;
        }

        var len = vfr * vfr + vfg * vfg + vfb * vfb;
        if (len < 1e-10) {
            axis = @splat(0.0);
        } else {
            len = 1.0 / @sqrt(len);
            vfr *= len;
            vfg *= len;
            vfb *= len;
            axis = .{ vfr, vfg, vfb, 0 };
        }
    }

    if (vec4FDot(axis, axis) < 0.5) {
        if (params.perceptual) {
            axis = .{ 0.213, 0.715, 0.072, if (params.has_alpha) 0.715 else 0 };
        } else {
            axis = .{ 1.0, 1.0, 1.0, if (params.has_alpha) 1.0 else 0 };
        }
        vec4FNormalizeInPlace(&axis);
    }

    var l: f32 = 1e+9;
    var h: f32 = -1e+9;
    for (pixels[0..num_pixels]) |px| {
        const q = vec4FSub(vec4FFromColor(px), mean_color_scaled);
        const d = vec4FDot(q, axis);
        l = minF(l, d);
        h = maxF(h, d);
    }

    l *= (1.0 / 255.0);
    h *= (1.0 / 255.0);

    const b0 = vec4FMul(axis, l);
    const b1 = vec4FMul(axis, h);
    const c0 = vec4FAdd(mean_color, b0);
    const c1 = vec4FAdd(mean_color, b1);
    var min_color = vec4FSaturate(c0);
    var max_color = vec4FSaturate(c1);

    const white_vec: Vec4F = @splat(1.0);
    if (vec4FDot(min_color, white_vec) > vec4FDot(max_color, white_vec)) {
        std.mem.swap(Vec4F, &min_color, &max_color);
    }

    if (findOptimalSolution(mode, &min_color, &max_color, params, results, comp_params.pbit_search, num_pixels, pixels) == 0)
        return 0;

    if (!refinement) return results.best_overall_err;

    for (0..comp_params.refinement_passes) |_| {
        if (leastSquaresThenOptimize(mode, params, results, comp_params.pbit_search, num_pixels, pixels, results.selectors) == 0)
            return 0;
    }

    if (comp_params.uber_level > 0) {
        var selectors_temp: [16]i32 = undefined;
        var selectors_temp1: [16]i32 = undefined;
        @memcpy(selectors_temp[0..num_pixels], results.selectors[0..num_pixels]);

        const max_selector: i32 = @as(i32, @intCast(params.num_selector_weights)) - 1;

        var min_sel: u32 = 16;
        var max_sel: u32 = 0;
        for (selectors_temp[0..num_pixels]) |s| {
            const sel: u32 = @intCast(s);
            min_sel = @min(min_sel, sel);
            max_sel = @max(max_sel, sel);
        }

        if (comp_params.uber1_mask & 1 != 0) {
            for (0..num_pixels) |i| {
                var sel: u32 = @intCast(selectors_temp[i]);
                if (sel == min_sel and sel < params.num_selector_weights - 1) sel += 1;
                selectors_temp1[i] = @intCast(sel);
            }
            if (leastSquaresThenOptimize(mode, params, results, comp_params.pbit_search, num_pixels, pixels, &selectors_temp1) == 0)
                return 0;
        }

        if (comp_params.uber1_mask & 2 != 0) {
            for (0..num_pixels) |i| {
                var sel: u32 = @intCast(selectors_temp[i]);
                if (sel == max_sel and sel > 0) sel -= 1;
                selectors_temp1[i] = @intCast(sel);
            }
            if (leastSquaresThenOptimize(mode, params, results, comp_params.pbit_search, num_pixels, pixels, &selectors_temp1) == 0)
                return 0;
        }

        if (comp_params.uber1_mask & 4 != 0) {
            for (0..num_pixels) |i| {
                var sel: u32 = @intCast(selectors_temp[i]);
                if (sel == min_sel and sel < params.num_selector_weights - 1) {
                    sel += 1;
                } else if (sel == max_sel and sel > 0) {
                    sel -= 1;
                }
                selectors_temp1[i] = @intCast(sel);
            }
            if (leastSquaresThenOptimize(mode, params, results, comp_params.pbit_search, num_pixels, pixels, &selectors_temp1) == 0)
                return 0;
        }

        const uber_err_thresh: u32 = (num_pixels * 56) >> 4;
        if (comp_params.uber_level >= 2 and results.best_overall_err > uber_err_thresh) {
            const q: i32 = if (comp_params.uber_level >= 4) @as(i32, @intCast(comp_params.uber_level)) - 2 else 1;
            var ly: i32 = -q;
            while (ly <= 1) : (ly += 1) {
                var hy: i32 = max_selector - 1;
                while (hy <= max_selector + q) : (hy += 1) {
                    if (ly == 0 and hy == max_selector) continue;

                    for (0..num_pixels) |i| {
                        selectors_temp1[i] = ftoi(clampF(@floor(f32FromInt(max_selector) * (f32FromInt(selectors_temp[i]) - f32FromInt(ly)) / (f32FromInt(hy) - f32FromInt(ly)) + 0.5), 0, f32FromInt(max_selector)));
                    }

                    if (leastSquaresThenOptimize(mode, params, results, comp_params.pbit_search and (comp_params.uber_level >= 2), num_pixels, pixels, &selectors_temp1) == 0)
                        return 0;
                }
            }
        }
    }

    if (lut_mode and comp_params.use_luts) {
        var avg_results: ColorCellCompressorResults = .{
            .best_overall_err = results.best_overall_err,
            .selectors = results.selectors,
            .selectors_temp = results.selectors_temp,
        };

        const r: u32 = @bitCast(ftoi(0.5 + mean_color[0] * 255.0));
        const g: u32 = @bitCast(ftoi(0.5 + mean_color[1] * 255.0));
        const b: u32 = @bitCast(ftoi(0.5 + mean_color[2] * 255.0));
        const a: u32 = @bitCast(ftoi(0.5 + mean_color[3] * 255.0));
        assert(r <= 255 and g <= 255 and b <= 255 and a <= 255);

        const temp = results.selectors_temp;
        const avg_err = switch (mode) {
            0 => packMode0ToOneColor(params, &avg_results, r, g, b, temp, num_pixels, pixels),
            1 => packMode1ToOneColor(params, &avg_results, r, g, b, temp, num_pixels, pixels),
            6 => packMode67ToOneColor(6, params, &avg_results, r, g, b, a, temp, num_pixels, pixels),
            7 => packMode67ToOneColor(7, params, &avg_results, r, g, b, a, temp, num_pixels, pixels),
            else => packMode24ToOneColor(params, &avg_results, r, g, b, temp, num_pixels, pixels),
        };

        if (avg_err < results.best_overall_err) {
            results.best_overall_err = avg_err;
            results.low_endpoint = avg_results.low_endpoint;
            results.high_endpoint = avg_results.high_endpoint;
            results.pbits = avg_results.pbits;
            @memcpy(results.selectors[0..num_pixels], temp[0..num_pixels]);
            results.used_lut = true;
        }
    }

    return results.best_overall_err;
}

/// A cheap error estimate for one subset: project onto the bounding box
/// diagonal and quantize to the mode's index count. Used to rank partitions.
fn colorCellCompressionEst(mode: u32, params: *const ColorCellCompressorParams, num_pixels: u32, pixels: []const ColorQuadI) u64 {
    assert(params.num_selector_weights == 4 or params.num_selector_weights == 8);

    var lr: f32 = 255;
    var lg: f32 = 255;
    var lb: f32 = 255;
    var hr: f32 = 0;
    var hg: f32 = 0;
    var hb: f32 = 0;
    for (pixels[0..num_pixels]) |c| {
        const r = f32FromInt(c[0]);
        const g = f32FromInt(c[1]);
        const b = f32FromInt(c[2]);
        lr = minF(lr, r);
        lg = minF(lg, g);
        lb = minF(lb, b);
        hr = maxF(hr, r);
        hg = maxF(hg, g);
        hb = maxF(hb, b);
    }

    const n: u32 = @as(u32, 1) << @intCast(color_index_bitcount[mode]);

    const sr = lr;
    const sg = lg;
    const sb = lb;

    const dir = hr - lr;
    const dig = hg - lg;
    const dib = hb - lb;

    const far = dir;
    const fag = dig;
    const fab = dib;

    const low = far * sr + fag * sg + fab * sb;
    const high = far * hr + fag * hg + fab * hb;

    const scale = (f32FromInt(n) - 1) / ((high - low) + denom_bias);
    const inv_n = 1.0 / (f32FromInt(n) - 1);

    var total_errf: f32 = 0;

    // Perceptual weighting is approximated here: under 0.05 dB of luma PSNR
    // across a large corpus, for half the time.
    const weighted = params.weights[0] != 1 or params.weights[1] != 1 or params.weights[2] != 1;
    const wr = f32FromInt(params.weights[0]);
    const wg = f32FromInt(params.weights[1]);
    const wb = f32FromInt(params.weights[2]);

    for (pixels[0..num_pixels]) |c| {
        const d = far * f32FromInt(c[0]) + fag * f32FromInt(c[1]) + fab * f32FromInt(c[2]);

        const s = clampF(@floor((d - low) * scale + 0.5) * inv_n, 0.0, 1.0);

        const itr = sr + dir * s;
        const itg = sg + dig * s;
        const itb = sb + dib * s;

        const dr = itr - f32FromInt(c[0]);
        const dg = itg - f32FromInt(c[1]);
        const db = itb - f32FromInt(c[2]);

        if (weighted) {
            total_errf += wr * dr * dr + wg * dg * dg + wb * db * db;
        } else {
            total_errf += dr * dr + dg * dg + db * db;
        }
    }

    return @bitCast(ftoi64(total_errf));
}

fn colorCellCompressionEstMode7(mode: u32, params: *const ColorCellCompressorParams, num_pixels: u32, pixels: []const ColorQuadI) u64 {
    assert(mode == 7 and params.num_selector_weights == 4);

    var lo: [4]f32 = @splat(255);
    var hi: [4]f32 = @splat(0);
    for (pixels[0..num_pixels]) |c| {
        for (0..4) |k| {
            const v = f32FromInt(c[k]);
            lo[k] = minF(lo[k], v);
            hi[k] = maxF(hi[k], v);
        }
    }

    const n: u32 = 4;

    const sr = lo[0];
    const sg = lo[1];
    const sb = lo[2];
    const sa = lo[3];

    const dir = hi[0] - lo[0];
    const dig = hi[1] - lo[1];
    const dib = hi[2] - lo[2];
    const dia = hi[3] - lo[3];

    const far = dir;
    const fag = dig;
    const fab = dib;
    const faa = dia;

    const low = far * sr + fag * sg + fab * sb + faa * sa;
    const high = far * hi[0] + fag * hi[1] + fab * hi[2] + faa * hi[3];

    const scale = (f32FromInt(n) - 1) / ((high - low) + denom_bias);
    const inv_n = 1.0 / (f32FromInt(n) - 1);

    var total_errf: f32 = 0;

    const weighted = !params.perceptual and (params.weights[0] != 1 or params.weights[1] != 1 or params.weights[2] != 1 or params.weights[3] != 1);
    const wr = f32FromInt(params.weights[0]);
    const wg = f32FromInt(params.weights[1]);
    const wb = f32FromInt(params.weights[2]);
    const wa = f32FromInt(params.weights[3]);

    for (pixels[0..num_pixels]) |c| {
        const d = far * f32FromInt(c[0]) + fag * f32FromInt(c[1]) + fab * f32FromInt(c[2]) + faa * f32FromInt(c[3]);

        const s = clampF(@floor((d - low) * scale + 0.5) * inv_n, 0.0, 1.0);

        const itr = sr + dir * s;
        const itg = sg + dig * s;
        const itb = sb + dib * s;
        const ita = sa + dia * s;

        const dr = itr - f32FromInt(c[0]);
        const dg = itg - f32FromInt(c[1]);
        const db = itb - f32FromInt(c[2]);
        const da = ita - f32FromInt(c[3]);

        if (weighted) {
            total_errf += wr * dr * dr + wg * dg * dg + wb * db * db + wa * da * da;
        } else {
            total_errf += dr * dr + dg * dg + db * db + da * da;
        }
    }

    return @bitCast(ftoi64(total_errf));
}

fn estimateParams(mode: u32, comp_params: *const Params) ColorCellCompressorParams {
    var params: ColorCellCompressorParams = .{};
    if (color_index_bitcount[mode] == 2) {
        params.selector_weights = &weights2;
    } else {
        params.selector_weights = &weights3;
    }
    params.num_selector_weights = @as(u32, 1) << @intCast(color_index_bitcount[mode]);
    params.weights = comp_params.weights;
    if (mode >= 6) {
        for (0..4) |i| params.weights[i] *%= comp_params.alpha_settings.mode67_error_weight_mul[i];
    }
    params.perceptual = comp_params.perceptual;
    return params;
}

const SubsetSplit = struct {
    colors: [3][16]ColorQuadI = undefined,
    total: [3]u32 = .{ 0, 0, 0 },
    pixel_index: [3][16]u32 = undefined,

    fn init(partition: []const u8, pixels: *const [16]ColorQuadI) SubsetSplit {
        var s: SubsetSplit = .{};
        for (0..16) |index| {
            const p = partition[index];
            assert(p < 3);
            s.colors[p][s.total[p]] = pixels[index];
            s.pixel_index[p][s.total[p]] = @intCast(index);
            s.total[p] += 1;
        }
        assert(s.total[0] + s.total[1] + s.total[2] == 16);
        return s;
    }
};

fn partitionPattern(total_subsets: u32, partition: u32) []const u8 {
    return if (total_subsets == 3) partition3[partition * 16 ..][0..16] else partition2[partition * 16 ..][0..16];
}

fn estimatePartitionError(mode: u32, params: *const ColorCellCompressorParams, total_subsets: u32, partition: u32, pixels: *const [16]ColorQuadI) u64 {
    const split = SubsetSplit.init(partitionPattern(total_subsets, partition), pixels);
    var total_subset_err: u64 = 0;
    for (0..total_subsets) |subset| {
        const err = if (mode == 7)
            colorCellCompressionEstMode7(mode, params, split.total[subset], &split.colors[subset])
        else
            colorCellCompressionEst(mode, params, split.total[subset], &split.colors[subset]);
        total_subset_err +%= err;
    }
    return total_subset_err;
}

fn estimatePartition(mode: u32, pixels: *const [16]ColorQuadI, comp_params: *const Params) u32 {
    const total_subsets = num_subsets[mode];
    const total_partitions = @min(comp_params.max_partitions_mode[mode], @as(u32, 1) << @intCast(partition_bits[mode]));

    if (total_partitions <= 1) return 0;

    var best_err: u64 = std.math.maxInt(u64);
    var best_partition: u32 = 0;

    const params = estimateParams(mode, comp_params);

    for (0..total_partitions) |partition_usize| {
        const partition: u32 = @intCast(partition_usize);
        const total_subset_err = estimatePartitionError(mode, &params, total_subsets, partition, pixels);

        if (total_subset_err < best_err) {
            best_err = total_subset_err;
            best_partition = partition;
            if (best_err == 0) break;
        }

        // Partitions past the checkerboard rarely win for two subsets.
        if (total_subsets == 2) {
            if (partition == checkerboard_partition_index_2subset and best_partition != checkerboard_partition_index_2subset) break;
        }
    }

    return best_partition;
}

const Solution = struct {
    index: u32,
    err: u64,
};

fn estimatePartitionList(mode: u32, pixels: *const [16]ColorQuadI, comp_params: *const Params, solutions: []Solution, max_solutions_in: i32) u32 {
    const orig_max_solutions = max_solutions_in;
    var max_solutions = max_solutions_in;

    const total_subsets = num_subsets[mode];
    const total_partitions = @min(comp_params.max_partitions_mode[mode], @as(u32, 1) << @intCast(partition_bits[mode]));

    if (total_partitions <= 1) {
        solutions[0] = .{ .index = 0, .err = 0 };
        return 1;
    } else if (max_solutions >= @as(i32, @intCast(total_partitions))) {
        for (0..total_partitions) |i| solutions[i] = .{ .index = @intCast(i), .err = i };
        return total_partitions;
    }

    const high_frequency_sorted_partition_threshold = 4;
    if (total_subsets == 2) {
        if (max_solutions < high_frequency_sorted_partition_threshold) max_solutions = high_frequency_sorted_partition_threshold;
    }
    assert(max_solutions >= 1 and max_solutions <= @as(i32, @intCast(solutions.len)));

    const params = estimateParams(mode, comp_params);

    var num_solutions: i32 = 0;

    for (0..total_partitions) |partition_usize| {
        const partition: u32 = @intCast(partition_usize);
        const total_subset_err = estimatePartitionError(mode, &params, total_subsets, partition, pixels);

        // Insertion into the sorted list, dropping the last when full.
        var i: i32 = 0;
        while (i < num_solutions) : (i += 1) {
            if (total_subset_err < solutions[@intCast(i)].err) break;
        }

        if (i < num_solutions) {
            var solutions_to_move = (max_solutions - 1) - i;
            const num_elements_at_i = num_solutions - i;
            if (solutions_to_move > num_elements_at_i) solutions_to_move = num_elements_at_i;

            assert((i + 1) + solutions_to_move <= max_solutions);
            assert(i + solutions_to_move <= num_solutions);

            var j: i32 = solutions_to_move - 1;
            while (j >= 0) : (j -= 1) {
                solutions[@intCast(i + j + 1)] = solutions[@intCast(i + j)];
            }
        }

        if (num_solutions < max_solutions) num_solutions += 1;

        if (i < num_solutions) {
            solutions[@intCast(i)] = .{ .index = partition, .err = total_subset_err };
        }
    }

    return @intCast(@min(num_solutions, orig_max_solutions));
}

fn setBlockBits(bytes: *[16]u8, val_in: u32, num_bits_in: u32, cur_ofs: *u32) void {
    assert(num_bits_in < 32);
    assert(val_in < (@as(u32, 1) << @intCast(num_bits_in)));
    var val = val_in;
    var num_bits = num_bits_in;
    while (num_bits != 0) {
        const n = @min(8 - (cur_ofs.* & 7), num_bits);
        bytes[cur_ofs.* >> 3] |= @truncate(val << @intCast(cur_ofs.* & 7));
        val >>= @intCast(n);
        num_bits -= n;
        cur_ofs.* += n;
    }
    assert(cur_ofs.* <= 128);
}

const Bc7OptimizationResults = struct {
    mode: u32 = 0,
    partition: u32 = 0,
    selectors: [16]i32 = @splat(0),
    alpha_selectors: [16]i32 = @splat(0),
    low: [3]ColorQuadI = @splat(@splat(0)),
    high: [3]ColorQuadI = @splat(@splat(0)),
    pbits: [3][2]u32 = @splat(.{ 0, 0 }),
    rotation: u32 = 0,
    index_selector: u32 = 0,
    /// True if the winning encoding used the single-colour tables on any
    /// subset.
    used_lut: bool = false,
};

fn encodeBc7Block(block: *[16]u8, results: *const Bc7OptimizationResults) void {
    const best_mode = results.mode;
    assert(best_mode <= 7);

    const total_subsets = num_subsets[best_mode];
    const total_partitions: u32 = @as(u32, 1) << @intCast(partition_bits[best_mode]);

    const partition: []const u8 = switch (total_subsets) {
        1 => &partition1,
        2 => partition2[results.partition * 16 ..][0..16],
        else => partition3[results.partition * 16 ..][0..16],
    };

    var color_selectors = results.selectors;
    var alpha_selectors = results.alpha_selectors;
    var low = results.low;
    var high = results.high;
    var pbits = results.pbits;

    var anchor = [3]i32{ -1, -1, -1 };

    // The first index of each subset (its anchor) is stored with one bit
    // fewer, so its top bit must be clear: invert the subset where it is not.
    for (0..total_subsets) |k| {
        var anchor_index: u32 = 0;
        if (k != 0) {
            if (total_subsets == 3 and k == 1) {
                anchor_index = anchor_third_subset_1[results.partition];
            } else if (total_subsets == 3 and k == 2) {
                anchor_index = anchor_third_subset_2[results.partition];
            } else {
                anchor_index = anchor_second_subset[results.partition];
            }
        }
        anchor[k] = @intCast(anchor_index);

        const color_index_bits = getColorIndexSize(best_mode, results.index_selector);
        const num_color_indices: i32 = @as(i32, 1) << @intCast(color_index_bits);

        if (color_selectors[anchor_index] & (num_color_indices >> 1) != 0) {
            for (0..16) |i| {
                if (partition[i] == k) color_selectors[i] = (num_color_indices - 1) - color_selectors[i];
            }
            if (modeHasSeparateAlphaSelectors(best_mode)) {
                for (0..3) |q| std.mem.swap(i32, &low[k][q], &high[k][q]);
            } else {
                std.mem.swap(ColorQuadI, &low[k], &high[k]);
            }
            if (!mode_has_shared_p_bits[best_mode]) std.mem.swap(u32, &pbits[k][0], &pbits[k][1]);
        }

        if (modeHasSeparateAlphaSelectors(best_mode)) {
            const alpha_index_bits = getAlphaIndexSize(best_mode, results.index_selector);
            const num_alpha_indices: i32 = @as(i32, 1) << @intCast(alpha_index_bits);

            if (alpha_selectors[anchor_index] & (num_alpha_indices >> 1) != 0) {
                for (0..16) |i| {
                    if (partition[i] == k) alpha_selectors[i] = (num_alpha_indices - 1) - alpha_selectors[i];
                }
                std.mem.swap(i32, &low[k][3], &high[k][3]);
            }
        }
    }

    block.* = @splat(0);
    var cur_bit_ofs: u32 = 0;

    setBlockBits(block, @as(u32, 1) << @intCast(best_mode), best_mode + 1, &cur_bit_ofs);

    if (best_mode == 4 or best_mode == 5) setBlockBits(block, results.rotation, 2, &cur_bit_ofs);
    if (best_mode == 4) setBlockBits(block, results.index_selector, 1, &cur_bit_ofs);
    if (total_partitions > 1) setBlockBits(block, results.partition, if (total_partitions == 64) 6 else 4, &cur_bit_ofs);

    const total_comps: u32 = if (best_mode >= 4) 4 else 3;
    for (0..total_comps) |comp| {
        const bits = if (comp == 3) alpha_precision_table[best_mode] else color_precision_table[best_mode];
        for (0..total_subsets) |subset| {
            setBlockBits(block, @intCast(low[subset][comp]), bits, &cur_bit_ofs);
            setBlockBits(block, @intCast(high[subset][comp]), bits, &cur_bit_ofs);
        }
    }

    if (mode_has_p_bits[best_mode]) {
        for (0..total_subsets) |subset| {
            setBlockBits(block, pbits[subset][0], 1, &cur_bit_ofs);
            if (!mode_has_shared_p_bits[best_mode]) setBlockBits(block, pbits[subset][1], 1, &cur_bit_ofs);
        }
    }

    for (0..16) |idx_usize| {
        const idx: i32 = @intCast(idx_usize);
        var n = if (results.index_selector != 0) getAlphaIndexSize(best_mode, results.index_selector) else getColorIndexSize(best_mode, results.index_selector);
        if (idx == anchor[0] or idx == anchor[1] or idx == anchor[2]) n -= 1;
        const v = if (results.index_selector != 0) alpha_selectors[idx_usize] else color_selectors[idx_usize];
        setBlockBits(block, @intCast(v), n, &cur_bit_ofs);
    }

    if (modeHasSeparateAlphaSelectors(best_mode)) {
        for (0..16) |idx_usize| {
            const idx: i32 = @intCast(idx_usize);
            var n = if (results.index_selector != 0) getColorIndexSize(best_mode, results.index_selector) else getAlphaIndexSize(best_mode, results.index_selector);
            if (idx == anchor[0] or idx == anchor[1] or idx == anchor[2]) n -= 1;
            const v = if (results.index_selector != 0) color_selectors[idx_usize] else alpha_selectors[idx_usize];
            setBlockBits(block, @intCast(v), n, &cur_bit_ofs);
        }
    }

    assert(cur_bit_ofs == 128);
}

const partition1: [16]u8 = @splat(0);

/// Mode 6 packs into two 64-bit words directly.
fn encodeBc7BlockMode6(block: *[16]u8, results: *const Bc7OptimizationResults) void {
    var low: ColorQuadI = undefined;
    var high: ColorQuadI = undefined;
    var pbits: [2]u32 = undefined;

    var invert_selectors: u32 = 0;
    if (results.selectors[0] & 8 != 0) {
        invert_selectors = 15;
        low = results.high[0];
        high = results.low[0];
        pbits = .{ results.pbits[0][1], results.pbits[0][0] };
    } else {
        low = results.low[0];
        high = results.high[0];
        pbits = .{ results.pbits[0][0], results.pbits[0][1] };
    }

    var l: u64 = 1 << 6;
    const lc: [4]u64 = .{ @intCast(low[0]), @intCast(low[1]), @intCast(low[2]), @intCast(low[3]) };
    const hc: [4]u64 = .{ @intCast(high[0]), @intCast(high[1]), @intCast(high[2]), @intCast(high[3]) };
    l |= lc[0] << 7;
    l |= hc[0] << 14;
    l |= lc[1] << 21;
    l |= hc[1] << 28;
    l |= lc[2] << 35;
    l |= hc[2] << 42;
    l |= lc[3] << 49;
    l |= hc[3] << 56;
    l |= @as(u64, pbits[0]) << 63;

    var h: u64 = pbits[1];
    h |= @as(u64, invert_selectors ^ @as(u32, @intCast(results.selectors[0]))) << 1;
    for (1..16) |i| {
        h |= @as(u64, invert_selectors ^ @as(u32, @intCast(results.selectors[i]))) << @intCast(i * 4);
    }

    std.mem.writeInt(u64, block[0..8], l, .little);
    std.mem.writeInt(u64, block[8..16], h, .little);
}

/// Alpha levels for mode 4 and 5 searches: vals[0] and vals[last] are the
/// endpoints, the others interpolate.
fn alphaSelectorsAndError(pixels: *const [16]ColorQuadI, vals: []const i32, weight_a: u32, selectors_out: *[16]i32) u64 {
    var err_total: u64 = 0;
    for (0..16) |i| {
        const a = pixels[i][3];
        var s: i32 = 0;
        var be = iabs32(a - vals[0]);
        for (vals[1..], 1..) |v, k| {
            const e = iabs32(a - v);
            if (e < be) {
                be = e;
                s = @intCast(k);
            }
        }
        // u32 arithmetic in the original.
        err_total += @as(u32, @intCast(be * be)) *% weight_a;
        selectors_out[i] = s;
    }
    return err_total;
}

fn mode4AlphaVals(index_selector: u32, la: u32, ha: u32, vals: *[8]i32) []const i32 {
    if (index_selector == 0) {
        vals[0] = @intCast((la << 2) | (la >> 4));
        vals[7] = @intCast((ha << 2) | (ha >> 4));
        for (1..7) |i| vals[i] = (vals[0] * (64 - @as(i32, @intCast(weights3[i]))) + vals[7] * @as(i32, @intCast(weights3[i])) + 32) >> 6;
        return vals[0..8];
    } else {
        vals[0] = @intCast((la << 2) | (la >> 4));
        vals[3] = @intCast((ha << 2) | (ha >> 4));
        const w_s1 = 21;
        const w_s2 = 43;
        vals[1] = (vals[0] * (64 - w_s1) + vals[3] * w_s1 + 32) >> 6;
        vals[2] = (vals[0] * (64 - w_s2) + vals[3] * w_s2 + 32) >> 6;
        return vals[0..4];
    }
}

fn handleAlphaBlockMode4(pixels: *const [16]ColorQuadI, comp_params: *const Params, params: *ColorCellCompressorParams, lo_a: u32, hi_a: u32, opt_results4: *Bc7OptimizationResults, mode4_err: *u64) void {
    params.has_alpha = false;
    params.comp_bits = 5;
    params.has_pbits = false;
    params.endpoints_share_pbit = false;
    params.perceptual = comp_params.perceptual;

    for (0..2) |index_selector_usize| {
        const index_selector: u32 = @intCast(index_selector_usize);
        if (comp_params.mode4_index_mask & (@as(u32, 1) << @intCast(index_selector)) == 0) continue;

        if (index_selector != 0) params.setSelectorWeights(3) else params.setSelectorWeights(2);

        var selectors: [16]i32 = undefined;
        var selectors_temp: [16]i32 = undefined;
        var results: ColorCellCompressorResults = .{ .selectors = &selectors, .selectors_temp = &selectors_temp };

        var trial_err = colorCellCompression(4, params, &results, comp_params, 16, pixels, true);
        assert(trial_err == results.best_overall_err);

        var la: u32 = @intCast(@min(@as(i32, @intCast((lo_a + 2) >> 2)), 63));
        var ha: u32 = @intCast(@min(@as(i32, @intCast((hi_a + 2) >> 2)), 63));

        if (la == ha) {
            if (lo_a != hi_a) {
                if (ha != 63) {
                    ha += 1;
                } else if (la != 0) {
                    la -= 1;
                }
            }
        }

        var best_alpha_err: u64 = std.math.maxInt(u64);
        var best_la: u32 = 0;
        var best_ha: u32 = 0;
        var best_alpha_selectors: [16]i32 = @splat(0);

        for (0..2) |pass| {
            var vals_buf: [8]i32 = undefined;
            const vals = mode4AlphaVals(index_selector, la, ha, &vals_buf);

            var trial_alpha_selectors: [16]i32 = undefined;
            const trial_alpha_err = alphaSelectorsAndError(pixels, vals, params.weights[3], &trial_alpha_selectors);

            if (trial_alpha_err < best_alpha_err) {
                best_alpha_err = trial_alpha_err;
                best_la = la;
                best_ha = ha;
                best_alpha_selectors = trial_alpha_selectors;
            }

            if (pass == 0) {
                var xl: f32 = undefined;
                var xh: f32 = undefined;
                computeLeastSquaresEndpointsA(16, &trial_alpha_selectors, if (index_selector != 0) &weights2x else &weights3x, &xl, &xh, pixels);
                if (xl > xh) std.mem.swap(f32, &xl, &xh);
                la = @intCast(clampI(ftoi(@floor(xl * (63.0 / 255.0) + 0.5)), 0, 63));
                ha = @intCast(clampI(ftoi(@floor(xh * (63.0 / 255.0) + 0.5)), 0, 63));
            }
        }

        if (comp_params.uber_level > 0) {
            const d: i32 = @min(@as(i32, @intCast(comp_params.uber_level)), 3);
            var ld: i32 = -d;
            while (ld <= d) : (ld += 1) {
                var hd: i32 = -d;
                while (hd <= d) : (hd += 1) {
                    la = @intCast(clampI(@as(i32, @intCast(best_la)) + ld, 0, 63));
                    ha = @intCast(clampI(@as(i32, @intCast(best_ha)) + hd, 0, 63));

                    var vals_buf: [8]i32 = undefined;
                    const vals = mode4AlphaVals(index_selector, la, ha, &vals_buf);

                    var trial_alpha_selectors: [16]i32 = undefined;
                    const trial_alpha_err = alphaSelectorsAndError(pixels, vals, params.weights[3], &trial_alpha_selectors);

                    if (trial_alpha_err < best_alpha_err) {
                        best_alpha_err = trial_alpha_err;
                        best_la = la;
                        best_ha = ha;
                        best_alpha_selectors = trial_alpha_selectors;
                    }
                }
            }
        }

        trial_err +%= best_alpha_err;

        if (trial_err < mode4_err.*) {
            mode4_err.* = trial_err;

            opt_results4.mode = 4;
            opt_results4.index_selector = index_selector;
            opt_results4.rotation = 0;
            opt_results4.partition = 0;
            opt_results4.used_lut = results.used_lut;

            opt_results4.low[0] = results.low_endpoint;
            opt_results4.high[0] = results.high_endpoint;
            opt_results4.low[0][3] = @intCast(best_la);
            opt_results4.high[0][3] = @intCast(best_ha);

            opt_results4.selectors = selectors;
            opt_results4.alpha_selectors = best_alpha_selectors;
        }
    }
}

fn mode5AlphaVals(lo_a: u32, hi_a: u32) [4]i32 {
    var vals: [4]i32 = undefined;
    vals[0] = @intCast(lo_a);
    vals[3] = @intCast(hi_a);
    const w_s1 = 21;
    const w_s2 = 43;
    vals[1] = (vals[0] * (64 - w_s1) + vals[3] * w_s1 + 32) >> 6;
    vals[2] = (vals[0] * (64 - w_s2) + vals[3] * w_s2 + 32) >> 6;
    return vals;
}

fn handleAlphaBlockMode5(pixels: *const [16]ColorQuadI, comp_params: *const Params, params: *ColorCellCompressorParams, lo_a_in: u32, hi_a_in: u32, opt_results5: *Bc7OptimizationResults, mode5_err: *u64) void {
    var lo_a = lo_a_in;
    var hi_a = hi_a_in;

    params.setSelectorWeights(2);
    params.comp_bits = 7;
    params.has_alpha = false;
    params.has_pbits = false;
    params.endpoints_share_pbit = false;
    params.perceptual = comp_params.perceptual;

    var selectors_temp: [16]i32 = undefined;
    var results5: ColorCellCompressorResults = .{ .selectors = &opt_results5.selectors, .selectors_temp = &selectors_temp };

    mode5_err.* = colorCellCompression(5, params, &results5, comp_params, 16, pixels, true);
    assert(mode5_err.* == results5.best_overall_err);

    opt_results5.low[0] = results5.low_endpoint;
    opt_results5.high[0] = results5.high_endpoint;

    if (lo_a == hi_a) {
        opt_results5.low[0][3] = @intCast(lo_a);
        opt_results5.high[0][3] = @intCast(hi_a);
        opt_results5.alpha_selectors = @splat(0);
    } else {
        var mode5_alpha_err: u64 = std.math.maxInt(u64);

        for (0..2) |pass| {
            const vals = mode5AlphaVals(lo_a, hi_a);

            var trial_alpha_selectors: [16]i32 = undefined;
            const trial_alpha_err = alphaSelectorsAndError(pixels, &vals, params.weights[3], &trial_alpha_selectors);

            if (trial_alpha_err < mode5_alpha_err) {
                mode5_alpha_err = trial_alpha_err;
                opt_results5.low[0][3] = @intCast(lo_a);
                opt_results5.high[0][3] = @intCast(hi_a);
                opt_results5.alpha_selectors = trial_alpha_selectors;
            }

            if (pass == 0) {
                var xl: f32 = undefined;
                var xh: f32 = undefined;
                computeLeastSquaresEndpointsA(16, &trial_alpha_selectors, &weights2x, &xl, &xh, pixels);

                var new_lo_a: u32 = @intCast(clampI(ftoi(@floor(xl + 0.5)), 0, 255));
                var new_hi_a: u32 = @intCast(clampI(ftoi(@floor(xh + 0.5)), 0, 255));
                if (new_lo_a > new_hi_a) std.mem.swap(u32, &new_lo_a, &new_hi_a);

                if (new_lo_a == lo_a and new_hi_a == hi_a) break;

                lo_a = new_lo_a;
                hi_a = new_hi_a;
            }
        }

        if (comp_params.uber_level > 0) {
            const d: i32 = @min(@as(i32, @intCast(comp_params.uber_level)), 3);
            var ld: i32 = -d;
            while (ld <= d) : (ld += 1) {
                var hd: i32 = -d;
                while (hd <= d) : (hd += 1) {
                    lo_a = @intCast(clampI(opt_results5.low[0][3] + ld, 0, 255));
                    hi_a = @intCast(clampI(opt_results5.high[0][3] + hd, 0, 255));

                    const vals = mode5AlphaVals(lo_a, hi_a);

                    var trial_alpha_selectors: [16]i32 = undefined;
                    const trial_alpha_err = alphaSelectorsAndError(pixels, &vals, params.weights[3], &trial_alpha_selectors);

                    if (trial_alpha_err < mode5_alpha_err) {
                        mode5_alpha_err = trial_alpha_err;
                        opt_results5.low[0][3] = @intCast(lo_a);
                        opt_results5.high[0][3] = @intCast(hi_a);
                        opt_results5.alpha_selectors = trial_alpha_selectors;
                    }
                }
            }
        }

        mode5_err.* +%= mode5_alpha_err;
    }

    opt_results5.mode = 5;
    opt_results5.index_selector = 0;
    opt_results5.rotation = 0;
    opt_results5.partition = 0;
    opt_results5.used_lut = results5.used_lut;
}

/// Swaps alpha with channel rotation - 1, as dual-plane modes 4 and 5 can,
/// and returns the rotated alpha range.
fn rotatePixels(pixels: *const [16]ColorQuadI, rotation: u32, rot_pixels: *[16]ColorQuadI, lo_a: *u32, hi_a: *u32) void {
    assert(rotation >= 1 and rotation <= 3);
    lo_a.* = 255;
    hi_a.* = 0;
    for (0..16) |i| {
        var c = pixels[i];
        std.mem.swap(i32, &c[3], &c[rotation - 1]);
        rot_pixels[i] = c;
        lo_a.* = @min(lo_a.*, @as(u32, @intCast(c[3])));
        hi_a.* = @max(hi_a.*, @as(u32, @intCast(c[3])));
    }
}

/// Encodes the subsets of a partition in one mode and keeps the result if it
/// beats best_err. Shared by modes 0, 1, 2, 3 and 7.
fn tryPartition(
    mode: u32,
    total_subsets: u32,
    trial_partition: u32,
    params: *const ColorCellCompressorParams,
    comp_params: *const Params,
    pixels: *const [16]ColorQuadI,
    selectors_temp: *[16]i32,
    refinement: bool,
    best_err: *u64,
    opt_results: *Bc7OptimizationResults,
    set_mode: bool,
) void {
    assert(trial_partition < 64);
    const split = SubsetSplit.init(partitionPattern(total_subsets, trial_partition), pixels);

    var subset_selectors: [3][16]i32 = undefined;
    var subset_results: [3]ColorCellCompressorResults = undefined;

    var trial_err: u64 = 0;
    for (0..total_subsets) |subset| {
        subset_results[subset] = .{ .selectors = &subset_selectors[subset], .selectors_temp = selectors_temp };
        const err = colorCellCompression(mode, params, &subset_results[subset], comp_params, split.total[subset], &split.colors[subset], refinement);
        assert(err == subset_results[subset].best_overall_err);

        trial_err +%= err;
        if (trial_err > best_err.*) break;
    }

    if (trial_err < best_err.*) {
        best_err.* = trial_err;

        if (set_mode) {
            opt_results.mode = mode;
            opt_results.index_selector = 0;
            opt_results.rotation = 0;
            opt_results.partition = trial_partition;
        }

        for (0..total_subsets) |subset| {
            for (0..split.total[subset]) |i| {
                opt_results.selectors[split.pixel_index[subset][i]] = subset_selectors[subset][i];
            }
            opt_results.low[subset] = subset_results[subset].low_endpoint;
            opt_results.high[subset] = subset_results[subset].high_endpoint;
            // Mode 2 has no p-bits and mode 1 one per subset; the original
            // leaves the unused entries as they were.
            if (mode != 2) opt_results.pbits[subset][0] = subset_results[subset].pbits[0];
            if (mode != 1 and mode != 2) opt_results.pbits[subset][1] = subset_results[subset].pbits[1];
        }
        opt_results.used_lut = false;
        for (subset_results[0..total_subsets]) |r| opt_results.used_lut = opt_results.used_lut or r.used_lut;
    }
}

fn handleAlphaBlock(
    block: *[16]u8,
    pixels: *const [16]ColorQuadI,
    comp_params: *const Params,
    params: *ColorCellCompressorParams,
    lo_a: u32,
    hi_a: u32,
    forced_partition: i32,
    best_err_out: ?*u64,
    used_lut_out: ?*bool,
) void {
    params.perceptual = comp_params.perceptual;

    var opt_results: Bc7OptimizationResults = .{};
    var best_err: u64 = std.math.maxInt(u64);

    // Mode 4
    if (comp_params.alpha_settings.use_mode4) {
        var params4 = params.*;

        const num_rotations: u32 = if (comp_params.perceptual or !comp_params.alpha_settings.use_mode4_rotation) 1 else 4;
        for (0..num_rotations) |rotation_usize| {
            const rotation: u32 = @intCast(rotation_usize);
            if (comp_params.mode4_rotation_mask & (@as(u32, 1) << @intCast(rotation)) == 0) continue;

            params4.weights = params.weights;
            if (rotation != 0) std.mem.swap(u32, &params4.weights[rotation - 1], &params4.weights[3]);

            var rot_pixels: [16]ColorQuadI = undefined;
            var trial_pixels = pixels;
            var trial_lo_a = lo_a;
            var trial_hi_a = hi_a;
            if (rotation != 0) {
                rotatePixels(pixels, rotation, &rot_pixels, &trial_lo_a, &trial_hi_a);
                trial_pixels = &rot_pixels;
            }

            var trial_opt_results4: Bc7OptimizationResults = .{};
            var trial_mode4_err = best_err;

            handleAlphaBlockMode4(trial_pixels, comp_params, &params4, trial_lo_a, trial_hi_a, &trial_opt_results4, &trial_mode4_err);

            if (trial_mode4_err < best_err) {
                best_err = trial_mode4_err;

                opt_results.mode = 4;
                opt_results.index_selector = trial_opt_results4.index_selector;
                opt_results.rotation = rotation;
                opt_results.partition = 0;
                opt_results.used_lut = trial_opt_results4.used_lut;

                opt_results.low[0] = trial_opt_results4.low[0];
                opt_results.high[0] = trial_opt_results4.high[0];

                opt_results.selectors = trial_opt_results4.selectors;
                opt_results.alpha_selectors = trial_opt_results4.alpha_selectors;
            }
        }
    }

    // Mode 6
    if (comp_params.alpha_settings.use_mode6) {
        var params6 = params.*;
        for (0..4) |i| params6.weights[i] *%= comp_params.alpha_settings.mode67_error_weight_mul[i];

        params6.setSelectorWeights(4);
        params6.comp_bits = 7;
        params6.has_pbits = true;
        params6.endpoints_share_pbit = false;
        params6.has_alpha = true;

        var selectors: [16]i32 = undefined;
        var selectors_temp: [16]i32 = undefined;
        var results6: ColorCellCompressorResults = .{ .selectors = &selectors, .selectors_temp = &selectors_temp };

        const mode6_err = colorCellCompression(6, &params6, &results6, comp_params, 16, pixels, true);
        assert(mode6_err == results6.best_overall_err);

        if (mode6_err < best_err) {
            best_err = mode6_err;

            opt_results.mode = 6;
            opt_results.index_selector = 0;
            opt_results.rotation = 0;
            opt_results.partition = 0;

            opt_results.low[0] = results6.low_endpoint;
            opt_results.high[0] = results6.high_endpoint;

            opt_results.pbits[0] = results6.pbits;
            opt_results.used_lut = results6.used_lut;

            opt_results.selectors = selectors;
        }
    }

    // Mode 5
    if (comp_params.alpha_settings.use_mode5) {
        var params5 = params.*;

        const num_rotations: u32 = if (comp_params.perceptual or !comp_params.alpha_settings.use_mode5_rotation) 1 else 4;
        for (0..num_rotations) |rotation_usize| {
            const rotation: u32 = @intCast(rotation_usize);
            if (comp_params.mode5_rotation_mask & (@as(u32, 1) << @intCast(rotation)) == 0) continue;

            params5.weights = params.weights;
            if (rotation != 0) std.mem.swap(u32, &params5.weights[rotation - 1], &params5.weights[3]);

            var rot_pixels: [16]ColorQuadI = undefined;
            var trial_pixels = pixels;
            var trial_lo_a = lo_a;
            var trial_hi_a = hi_a;
            if (rotation != 0) {
                rotatePixels(pixels, rotation, &rot_pixels, &trial_lo_a, &trial_hi_a);
                trial_pixels = &rot_pixels;
            }

            var trial_opt_results5: Bc7OptimizationResults = .{};
            var trial_mode5_err: u64 = 0;

            handleAlphaBlockMode5(trial_pixels, comp_params, &params5, trial_lo_a, trial_hi_a, &trial_opt_results5, &trial_mode5_err);

            if (trial_mode5_err < best_err) {
                best_err = trial_mode5_err;
                opt_results = trial_opt_results5;
                opt_results.rotation = rotation;
            }
        }
    }

    // Mode 7
    if (comp_params.alpha_settings.use_mode7) {
        var solutions: [max_partitions7]Solution = undefined;
        var num_solutions: u32 = undefined;
        if (forced_partition >= 0) {
            solutions[0].index = @intCast(forced_partition);
            num_solutions = 1;
        } else {
            num_solutions = estimatePartitionList(7, pixels, comp_params, &solutions, @bitCast(comp_params.alpha_settings.max_mode7_partitions_to_try));
        }

        var params7 = params.*;
        for (0..4) |i| params7.weights[i] *%= comp_params.alpha_settings.mode67_error_weight_mul[i];

        params7.setSelectorWeights(2);
        params7.comp_bits = 5;
        params7.has_pbits = true;
        params7.endpoints_share_pbit = false;
        params7.has_alpha = true;

        var selectors_temp: [16]i32 = undefined;

        // With many candidate partitions the cheap pass skips refinement,
        // and only the winner is redone with it.
        for (solutions[0..num_solutions]) |solution| {
            tryPartition(7, 2, solution.index, &params7, comp_params, pixels, &selectors_temp, num_solutions <= 2, &best_err, &opt_results, true);
        }
        if (num_solutions > 2 and opt_results.mode == 7) {
            tryPartition(7, 2, opt_results.partition, &params7, comp_params, pixels, &selectors_temp, true, &best_err, &opt_results, false);
        }
    }

    if (best_err_out) |p| p.* = best_err;
    if (used_lut_out) |p| p.* = opt_results.used_lut;
    encodeBc7Block(block, &opt_results);
}

fn partitionSolutions(mode: u32, pixels: *const [16]ColorQuadI, comp_params: *const Params, forced_partition: i32, max_to_try: u32, solutions: []Solution) u32 {
    if (forced_partition >= 0) {
        solutions[0].index = @intCast(forced_partition);
        return 1;
    } else if (max_to_try == 1) {
        solutions[0].index = estimatePartition(mode, pixels, comp_params);
        return 1;
    } else {
        return estimatePartitionList(mode, pixels, comp_params, solutions, @bitCast(max_to_try));
    }
}

fn handleOpaqueBlock(
    block: *[16]u8,
    pixels: *const [16]ColorQuadI,
    comp_params: *const Params,
    params: *ColorCellCompressorParams,
    forced_partition: i32,
    best_err_out: ?*u64,
    used_lut_out: ?*bool,
) void {
    var selectors_temp: [16]i32 = undefined;
    var opt_results: Bc7OptimizationResults = .{};
    var best_err: u64 = std.math.maxInt(u64);

    // Mode 6
    if (comp_params.opaque_settings.use_mode[6]) {
        params.setSelectorWeights(4);
        params.comp_bits = 7;
        params.has_pbits = true;
        params.endpoints_share_pbit = false;
        params.perceptual = comp_params.perceptual;

        var results6: ColorCellCompressorResults = .{ .selectors = &opt_results.selectors, .selectors_temp = &selectors_temp };

        best_err = colorCellCompression(6, params, &results6, comp_params, 16, pixels, true);

        opt_results.mode = 6;
        opt_results.index_selector = 0;
        opt_results.rotation = 0;
        opt_results.partition = 0;
        opt_results.used_lut = results6.used_lut;

        opt_results.low[0] = results6.low_endpoint;
        opt_results.high[0] = results6.high_endpoint;

        opt_results.pbits[0] = results6.pbits;
    }

    var solutions2: [max_partitions3]Solution = undefined;
    var num_solutions2: u32 = 0;
    if (comp_params.opaque_settings.use_mode[1] or comp_params.opaque_settings.use_mode[3]) {
        num_solutions2 = partitionSolutions(1, pixels, comp_params, forced_partition, comp_params.opaque_settings.max_mode13_partitions_to_try, &solutions2);
    }

    // Mode 1
    if (comp_params.opaque_settings.use_mode[1]) {
        params.setSelectorWeights(3);
        params.comp_bits = 6;
        params.has_pbits = true;
        params.endpoints_share_pbit = true;
        params.perceptual = comp_params.perceptual;

        for (solutions2[0..num_solutions2]) |solution| {
            tryPartition(1, 2, solution.index, params, comp_params, pixels, &selectors_temp, num_solutions2 <= 2, &best_err, &opt_results, true);
        }
        if (num_solutions2 > 2 and opt_results.mode == 1) {
            tryPartition(1, 2, opt_results.partition, params, comp_params, pixels, &selectors_temp, true, &best_err, &opt_results, false);
        }
    }

    // Mode 0
    if (comp_params.opaque_settings.use_mode[0]) {
        var solutions3: [max_partitions0]Solution = undefined;
        const num_solutions3 = partitionSolutions(0, pixels, comp_params, forced_partition, comp_params.opaque_settings.max_mode0_partitions_to_try, &solutions3);

        params.setSelectorWeights(3);
        params.comp_bits = 4;
        params.has_pbits = true;
        params.endpoints_share_pbit = false;
        params.perceptual = comp_params.perceptual;

        for (solutions3[0..num_solutions3]) |solution| {
            tryPartition(0, 3, solution.index, params, comp_params, pixels, &selectors_temp, true, &best_err, &opt_results, true);
        }
    }

    // Mode 3
    if (comp_params.opaque_settings.use_mode[3]) {
        params.setSelectorWeights(2);
        params.comp_bits = 7;
        params.has_pbits = true;
        params.endpoints_share_pbit = false;
        params.perceptual = comp_params.perceptual;

        for (solutions2[0..num_solutions2]) |solution| {
            tryPartition(3, 2, solution.index, params, comp_params, pixels, &selectors_temp, num_solutions2 <= 2, &best_err, &opt_results, true);
        }
        if (num_solutions2 > 2 and opt_results.mode == 3) {
            tryPartition(3, 2, opt_results.partition, params, comp_params, pixels, &selectors_temp, true, &best_err, &opt_results, false);
        }
    }

    // Mode 5
    if (!comp_params.perceptual and comp_params.opaque_settings.use_mode[5]) {
        var params5 = params.*;

        for (0..4) |rotation_usize| {
            const rotation: u32 = @intCast(rotation_usize);
            if (comp_params.mode5_rotation_mask & (@as(u32, 1) << @intCast(rotation)) == 0) continue;

            params5.weights = params.weights;
            if (rotation != 0) std.mem.swap(u32, &params5.weights[rotation - 1], &params5.weights[3]);

            var rot_pixels: [16]ColorQuadI = undefined;
            var trial_pixels = pixels;
            var trial_lo_a: u32 = 255;
            var trial_hi_a: u32 = 255;
            if (rotation != 0) {
                rotatePixels(pixels, rotation, &rot_pixels, &trial_lo_a, &trial_hi_a);
                trial_pixels = &rot_pixels;
            }

            var trial_opt_results5: Bc7OptimizationResults = .{};
            var trial_mode5_err: u64 = 0;

            handleAlphaBlockMode5(trial_pixels, comp_params, &params5, trial_lo_a, trial_hi_a, &trial_opt_results5, &trial_mode5_err);

            if (trial_mode5_err < best_err) {
                best_err = trial_mode5_err;
                opt_results = trial_opt_results5;
                opt_results.rotation = rotation;
            }
        }
    }

    // Mode 2
    if (comp_params.opaque_settings.use_mode[2]) {
        var solutions3: [max_partitions2]Solution = undefined;
        const num_solutions3 = partitionSolutions(2, pixels, comp_params, forced_partition, comp_params.opaque_settings.max_mode2_partitions_to_try, &solutions3);

        params.setSelectorWeights(2);
        params.comp_bits = 5;
        params.has_pbits = false;
        params.endpoints_share_pbit = false;
        params.perceptual = comp_params.perceptual;

        for (solutions3[0..num_solutions3]) |solution| {
            tryPartition(2, 3, solution.index, params, comp_params, pixels, &selectors_temp, true, &best_err, &opt_results, true);
        }
    }

    // Mode 4
    if (!comp_params.perceptual and comp_params.opaque_settings.use_mode[4]) {
        var params4 = params.*;

        for (0..4) |rotation_usize| {
            const rotation: u32 = @intCast(rotation_usize);
            if (comp_params.mode4_rotation_mask & (@as(u32, 1) << @intCast(rotation)) == 0) continue;

            params4.weights = params.weights;
            if (rotation != 0) std.mem.swap(u32, &params4.weights[rotation - 1], &params4.weights[3]);

            var rot_pixels: [16]ColorQuadI = undefined;
            var trial_pixels = pixels;
            var trial_lo_a: u32 = 255;
            var trial_hi_a: u32 = 255;
            if (rotation != 0) {
                rotatePixels(pixels, rotation, &rot_pixels, &trial_lo_a, &trial_hi_a);
                trial_pixels = &rot_pixels;
            }

            var trial_opt_results4: Bc7OptimizationResults = .{};
            var trial_mode4_err = best_err;

            handleAlphaBlockMode4(trial_pixels, comp_params, &params4, trial_lo_a, trial_hi_a, &trial_opt_results4, &trial_mode4_err);

            if (trial_mode4_err < best_err) {
                best_err = trial_mode4_err;

                opt_results.mode = 4;
                opt_results.index_selector = trial_opt_results4.index_selector;
                opt_results.rotation = rotation;
                opt_results.partition = 0;
                opt_results.used_lut = trial_opt_results4.used_lut;

                opt_results.low[0] = trial_opt_results4.low[0];
                opt_results.high[0] = trial_opt_results4.high[0];

                opt_results.selectors = trial_opt_results4.selectors;
                opt_results.alpha_selectors = trial_opt_results4.alpha_selectors;
            }
        }
    }

    if (best_err_out) |p| p.* = best_err;
    if (used_lut_out) |p| p.* = opt_results.used_lut;
    encodeBc7Block(block, &opt_results);
}

/// Any solid colour encodes exactly in mode 5.
fn handleBlockSolid(block: *[16]u8, cr: u32, cg: u32, cb: u32, ca: u32) void {
    const er = tables.mode5[cr];
    const eg = tables.mode5[cg];
    const eb = tables.mode5[cb];

    var opt: Bc7OptimizationResults = .{};
    opt.mode = 5;
    opt.low[0] = .{ @intCast(er & 0xFF), @intCast(eg & 0xFF), @intCast(eb & 0xFF), @intCast(ca) };
    opt.high[0] = .{ @intCast(er >> 8), @intCast(eg >> 8), @intCast(eb >> 8), @intCast(ca) };
    opt.pbits[0] = .{ 0, 0 };
    opt.index_selector = 0;
    opt.rotation = 0;
    opt.partition = 0;
    opt.selectors = @splat(mode_5_optimal_index);
    opt.alpha_selectors = @splat(0);
    encodeBc7Block(block, &opt);
}

fn handleOpaqueBlockMode6(block: *[16]u8, pixels: *const [16]ColorQuadI, comp_params: *const Params, params: *ColorCellCompressorParams, used_lut_out: ?*bool) void {
    var selectors_temp: [16]i32 = undefined;
    var opt_results: Bc7OptimizationResults = .{};

    params.setSelectorWeights(4);
    params.comp_bits = 7;
    params.has_pbits = true;
    params.endpoints_share_pbit = false;
    params.perceptual = comp_params.perceptual;

    var results6: ColorCellCompressorResults = .{ .selectors = &opt_results.selectors, .selectors_temp = &selectors_temp };

    _ = colorCellCompression(6, params, &results6, comp_params, 16, pixels, true);

    opt_results.mode = 6;
    opt_results.index_selector = 0;
    opt_results.rotation = 0;
    opt_results.partition = 0;

    opt_results.low[0] = results6.low_endpoint;
    opt_results.high[0] = results6.high_endpoint;

    opt_results.pbits[0] = results6.pbits;

    if (used_lut_out) |p| p.* = results6.used_lut;
    encodeBc7BlockMode6(block, &opt_results);
}

/// Encodes 16 RGBA pixels (row-major) as a BC7 block. `used_lut`, when
/// given, is set if the winning encoding used the single-colour tables
/// (bc7e_compress_blocks' pUsed_lut).
pub fn compressBlock(pixels_rgba: *const [16][4]u8, comp_params: *const Params, used_lut: ?*bool) [16]u8 {
    comp_params.check();

    var params: ColorCellCompressorParams = .{};
    params.weights = comp_params.weights;

    var temp_pixels: [16]ColorQuadI = undefined;

    var lo_r: i32 = 255;
    var hi_r: i32 = 0;
    var lo_g: i32 = 255;
    var hi_g: i32 = 0;
    var lo_b: i32 = 255;
    var hi_b: i32 = 0;
    var lo_a: f32 = 255;
    var hi_a: f32 = 0;

    for (pixels_rgba, &temp_pixels) |c, *t| {
        const r: i32 = c[0];
        const g: i32 = c[1];
        const b: i32 = c[2];
        const a: i32 = c[3];
        t.* = .{ r, g, b, a };

        lo_r = @min(lo_r, r);
        hi_r = @max(hi_r, r);
        lo_g = @min(lo_g, g);
        hi_g = @max(hi_g, g);
        lo_b = @min(lo_b, b);
        hi_b = @max(hi_b, b);

        const fa = f32FromInt(a);
        lo_a = minF(lo_a, fa);
        hi_a = maxF(hi_a, fa);
    }

    const all_same = lo_r == hi_r and lo_g == hi_g and lo_b == hi_b and lo_a == hi_a;

    var block: [16]u8 = undefined;
    var block_used_lut = false;

    if (all_same) {
        handleBlockSolid(&block, @intCast(lo_r), @intCast(lo_g), @intCast(lo_b), @intFromFloat(lo_a));
        // Solid blocks always come from the mode 5 table.
        block_used_lut = true;
    } else {
        const has_alpha = lo_a < 255;
        if (has_alpha) {
            handleAlphaBlock(&block, &temp_pixels, comp_params, &params, @intFromFloat(lo_a), @intFromFloat(hi_a), -1, null, &block_used_lut);
        } else if (comp_params.mode6_only) {
            handleOpaqueBlockMode6(&block, &temp_pixels, comp_params, &params, &block_used_lut);
        } else {
            handleOpaqueBlock(&block, &temp_pixels, comp_params, &params, -1, null, &block_used_lut);
        }
    }

    if (used_lut) |p| p.* = block_used_lut;
    return block;
}

/// Encodes 16 RGBA pixels in one BC7 mode only and returns the encoding's
/// error (bc7e_compress_block_single_mode). `partition` forces a partition
/// for modes 0, 1, 2, 3 and 7, or is -1 to search; `rotation` (0 to 3)
/// applies to modes 4 and 5, and `index_selector` (0 or 1) to mode 4. A
/// non-zero rotation forces the linear error metric. Opaque modes 0 to 3
/// drop alpha.
pub fn compressBlockSingleMode(block: *[16]u8, pixels_rgba: *const [16][4]u8, comp_params: *const Params, mode: u32, partition: i32, rotation: u32, index_selector: u32) u64 {
    assert(mode <= 7);
    comp_params.check();

    var temp_pixels: [16]ColorQuadI = undefined;
    var lo_a: i32 = 255;
    var hi_a: i32 = 0;
    for (pixels_rgba, &temp_pixels) |c, *t| {
        t.* = .{ c[0], c[1], c[2], c[3] };
        lo_a = @min(lo_a, @as(i32, c[3]));
        hi_a = @max(hi_a, @as(i32, c[3]));
    }

    var ccparams: ColorCellCompressorParams = .{};
    ccparams.weights = comp_params.weights;

    // The caller's settings with every mode off except the requested one.
    var p = comp_params.*;
    p.opaque_settings.use_mode = @splat(false);
    p.alpha_settings.use_mode4 = false;
    p.alpha_settings.use_mode5 = false;
    p.alpha_settings.use_mode6 = false;
    p.alpha_settings.use_mode7 = false;
    p.mode6_only = false;

    var forced_partition = partition;
    if (forced_partition >= 0) {
        const num_partitions: i32 = @as(i32, 1) << @intCast(partition_bits[mode]);
        // The original asserts both, then clamps for release builds.
        assert(num_partitions > 1);
        assert(forced_partition < num_partitions);
        if (num_partitions <= 1) {
            forced_partition = -1;
        } else if (forced_partition >= num_partitions) {
            forced_partition = num_partitions - 1;
        }
    }

    var best_err: u64 = std.math.maxInt(u64);

    if (mode <= 3) {
        p.opaque_settings.use_mode[mode] = true;
        handleOpaqueBlock(block, &temp_pixels, &p, &ccparams, forced_partition, &best_err, null);
    } else if (mode == 4 or mode == 5) {
        // A non-zero rotation is only reachable under the linear metric.
        if (rotation != 0) p.perceptual = false;

        if (mode == 4) {
            p.alpha_settings.use_mode4 = true;
            p.alpha_settings.use_mode4_rotation = true;
            p.mode4_rotation_mask = @as(u32, 1) << @intCast(rotation & 3);
            p.mode4_index_mask = @as(u32, 1) << @intCast(index_selector & 1);
        } else {
            p.alpha_settings.use_mode5 = true;
            p.alpha_settings.use_mode5_rotation = true;
            p.mode5_rotation_mask = @as(u32, 1) << @intCast(rotation & 3);
        }
        handleAlphaBlock(block, &temp_pixels, &p, &ccparams, @intCast(lo_a), @intCast(hi_a), -1, &best_err, null);
    } else if (mode == 6) {
        p.alpha_settings.use_mode6 = true;
        handleAlphaBlock(block, &temp_pixels, &p, &ccparams, @intCast(lo_a), @intCast(hi_a), -1, &best_err, null);
    } else {
        p.alpha_settings.use_mode7 = true;
        handleAlphaBlock(block, &temp_pixels, &p, &ccparams, @intCast(lo_a), @intCast(hi_a), forced_partition, &best_err, null);
    }

    return best_err;
}
