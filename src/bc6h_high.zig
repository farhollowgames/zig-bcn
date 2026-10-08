//! BC6H block encoder tuned for quality: zig-bcn's own, not a translation.
//!
//! texcomp's encoder (`texcomp_bc6h.zig`) settles for its first mode on most
//! blocks and judges the others with the wrong palette. This one searches
//! every mode: the four one-region modes, and the ten two-region modes on
//! the partitions a quick estimate ranks best. Each candidate is scored by
//! the error of exactly what a decoder will produce, computed with the
//! decoder's own `unquantize` and `finish`, and packed through the
//! decoder's own mode tables, so what the search measures is what decodes.
//! texcomp's block is always a candidate too, so a block is never worse
//! than `.fast` under that error.
//!
//! The error is integer and exact: the sum over pixels and channels of the
//! squared difference between decoded and target half-float codes, read as
//! integers (sign and magnitude for signed). Half codes are close to
//! logarithmic, so this weighs relative error, which suits HDR. Endpoint
//! fitting uses f64, which Zig never contracts or reorders, so the output
//! is the same on every target.

const std = @import("std");
const assert = std.debug.assert;
const bc6h = @import("bc6h.zig");
const texcomp_bc6h = @import("texcomp_bc6h.zig");

const Format = bc6h.Format;
const block_bytes = bc6h.block_bytes;

/// Two-region partitions, ranked by a quick estimate, that get the full
/// search over every two-region mode.
pub const partitions_searched = 3;
/// Least-squares refits of the endpoints from the chosen indices, per mode.
const refine_passes = 2;
/// A first evaluation more than this many times the best error so far is
/// not refined.
pub const refit_ratio_max = 2;

/// The largest finite half, 65504: inputs beyond it clamp to it.
const half_max = 0x7bff;

const weights1 = [16]i32{ 0, 4, 9, 13, 17, 21, 26, 30, 34, 38, 43, 47, 51, 55, 60, 64 };
const weights2 = [8]i32{ 0, 9, 18, 27, 37, 46, 55, 64 };

/// The code that selects each mode, the inverse of `bc6h.modeOf`.
const mode_codes = [14]u5{ 0x00, 0x01, 0x02, 0x06, 0x0a, 0x0e, 0x12, 0x16, 0x1a, 0x1e, 0x03, 0x07, 0x0b, 0x0f };

/// IEEE binary32 to binary16 bits, rounded to nearest with ties to even:
/// subnormals kept, overflow to infinity, NaN kept quiet. Integer-only, so
/// it is the same on every target.
pub fn floatToHalfRne(x: f32) u16 {
    const u: u32 = @bitCast(x);
    const sign: u16 = @intCast((u >> 16) & 0x8000);
    const exp: u32 = (u >> 23) & 0xff;
    const man: u32 = u & 0x7fffff;
    if (exp == 0xff) {
        if (man == 0) return sign | 0x7c00;
        return sign | 0x7e00 | @as(u16, @intCast(man >> 13));
    }
    if (exp >= 113) {
        // A normal half, or overflow.
        if (exp > 142) return sign | 0x7c00;
        var h: u32 = ((exp - 112) << 10) | (man >> 13);
        const rest = man & 0x1fff;
        // A carry out of the mantissa raises the exponent, up to infinity.
        if (rest > 0x1000 or (rest == 0x1000 and h & 1 == 1)) h += 1;
        assert(h <= 0x7c00);
        return sign | @as(u16, @intCast(h));
    }
    // Below 2^-25 rounds to zero; float subnormals are far below it.
    if (exp < 102) return sign;
    // A half subnormal, in units of 2^-24.
    const m = man | 0x800000;
    const shift: u5 = @intCast(126 - exp);
    assert(shift >= 14 and shift <= 24);
    var h: u32 = m >> shift;
    const rest = m & ((@as(u32, 1) << shift) - 1);
    const halfway = @as(u32, 1) << (shift - 1);
    if (rest > halfway or (rest == halfway and h & 1 == 1)) h += 1;
    assert(h <= 0x400);
    return sign | @as(u16, @intCast(h));
}

/// The half code a decoder should reproduce for `x`, as an integer: rounded
/// to nearest, clamped to the largest finite half, NaN as 0, and negatives
/// as 0 for unsigned.
pub fn target(x: f32, format: Format) i32 {
    const h = floatToHalfRne(x);
    const mag: i32 = h & 0x7fff;
    if (mag > 0x7c00) return 0;
    const m = @min(mag, half_max);
    if (h & 0x8000 == 0) return m;
    return switch (format) {
        .unsigned => 0,
        .signed => -m,
    };
}

/// A decoded half code as an integer, on the same scale as `target`.
pub fn halfValue(h: u16, format: Format) i32 {
    const mag: i32 = h & 0x7fff;
    return switch (format) {
        .unsigned => @as(i32, h),
        .signed => if (h & 0x8000 != 0) -mag else mag,
    };
}

pub const Targets = [16][3]i32;

pub fn targets(pixels: *const [16][3]f32, format: Format) Targets {
    var t: Targets = undefined;
    for (pixels, &t) |p, *q| {
        for (p, q) |x, *v| v.* = target(x, format);
    }
    return t;
}

/// The error of decoded texels against `t`.
pub fn decodedError(decoded: *const [16][3]u16, t: *const Targets, format: Format) u64 {
    var err: u64 = 0;
    for (decoded, t) |d, want| {
        for (d, want) |h, w| {
            const diff: i64 = @as(i64, halfValue(h, format)) - w;
            err += @intCast(diff * diff);
        }
    }
    return err;
}

// --- Fields and packing -----------------------------------------------------

/// Everything a block stores: mode, partition, the endpoint fields as
/// written (base, deltas or direct values, as the mode keeps them) and the
/// indices.
pub const Fields = struct {
    mode: u4,
    partition: u5 = 0,
    stored: [4][3]u32 = @splat(@splat(0)),
    indices: [16]u8 = @splat(0),
};

fn mask(bits: u5) u32 {
    assert(bits >= 1 and bits <= 16);
    return (@as(u32, 1) << bits) - 1;
}

pub fn isAnchor(regions: u2, partition: u5, i: usize) bool {
    return i == 0 or (regions == 2 and i == texcomp_bc6h.part2_anchor[partition]);
}

/// Packs `fields` with the decoder's mode tables.
pub fn pack(fields: *const Fields) [block_bytes]u8 {
    const mode = bc6h.modes[fields.mode];
    var bits: u128 = 0;
    var pos: u8 = 0;
    const put = struct {
        fn f(b: *u128, p: *u8, v: u32, count: u5) void {
            assert(count >= 1 and count <= 16 and v <= mask(count));
            assert(@as(u32, p.*) + count <= 128);
            b.* |= @as(u128, v) << @intCast(p.*);
            p.* += count;
        }
    }.f;

    const code = mode_codes[fields.mode];
    if (fields.mode < 2) put(&bits, &pos, code, 2) else put(&bits, &pos, code, 5);
    for (mode.runs) |r| {
        var v = (fields.stored[r.ep][r.ch] >> r.shift) & mask(r.count);
        // The inverse of the decoder's reversal is the same reversal.
        if (r.reversed) v = @as(u32, @bitReverse(@as(u16, @intCast(v)))) >> @intCast(16 - @as(u6, r.count));
        put(&bits, &pos, v, r.count);
    }
    if (mode.regions == 2) put(&bits, &pos, fields.partition, 5);
    const index_bits: u5 = if (mode.regions == 1) 4 else 3;
    for (fields.indices, 0..) |index, i| {
        const anchor = isAnchor(mode.regions, fields.partition, i);
        put(&bits, &pos, index, if (anchor) index_bits - 1 else index_bits);
    }
    assert(pos == 128);
    var out: [block_bytes]u8 = undefined;
    std.mem.writeInt(u128, &out, bits, .little);
    return out;
}

/// The endpoint values a decoder reconstructs from `fields`, before
/// unquantization, as in `bc6h.decodeBlock`.
fn endpointValues(fields: *const Fields, format: Format) [4][3]i32 {
    const mode = bc6h.modes[fields.mode];
    const n = mode.base_bits;
    var ep: [4][3]i32 = @splat(@splat(0));
    const count: usize = @as(usize, mode.regions) * 2;
    for (0..3) |c| {
        ep[0][c] = @intCast(fields.stored[0][c]);
        if (format == .signed) ep[0][c] = bc6h.signExtend(ep[0][c], n);
        for (1..count) |e| {
            ep[e][c] = @intCast(fields.stored[e][c]);
            if (mode.transformed or format == .signed) ep[e][c] = bc6h.signExtend(ep[e][c], mode.delta_bits[c]);
            if (mode.transformed) {
                ep[e][c] = (ep[e][c] + ep[0][c]) & @as(i32, @intCast(mask(n)));
                if (format == .signed) ep[e][c] = bc6h.signExtend(ep[e][c], n);
            }
        }
    }
    return ep;
}

/// What a decoder produces for `fields`, computed as the search does.
pub fn decodeFields(fields: *const Fields, format: Format) [16][3]u16 {
    const mode = bc6h.modes[fields.mode];
    const values = endpointValues(fields, format);
    var unq: [4][3]i32 = undefined;
    for (values, &unq) |v, *u| {
        for (v, u) |x, *y| y.* = bc6h.unquantize(x, mode.base_bits, format);
    }
    var out: [16][3]u16 = undefined;
    const part = texcomp_bc6h.partition(fields.partition);
    for (&out, 0..) |*px, i| {
        const region: usize = if (mode.regions == 1) 0 else part[i];
        const w = if (mode.regions == 1) weights1[fields.indices[i]] else weights2[fields.indices[i]];
        for (px, 0..) |*h, c| h.* = interpolate(unq[region * 2][c], unq[region * 2 + 1][c], w, format);
    }
    return out;
}

fn interpolate(a: i32, b: i32, w: i32, format: Format) u16 {
    assert(w >= 0 and w <= 64);
    // An arithmetic shift, as the decoder does, so negative values round
    // toward minus infinity.
    return bc6h.finish((a * (64 - w) + b * w + 32) >> 6, format);
}

// --- Endpoint fitting in the interpolation domain ----------------------------

const Vec = [3]f64;

/// The interpolation-domain value that finishes to half code `t`.
fn toDomain(t: i32, format: Format) f64 {
    const tf: f64 = @floatFromInt(t);
    return switch (format) {
        .unsigned => tf * 64.0 / 31.0,
        .signed => tf * 32.0 / 31.0,
    };
}

fn domainMin(format: Format) f64 {
    return switch (format) {
        .unsigned => 0,
        .signed => -32767,
    };
}

fn domainMax(format: Format) f64 {
    return switch (format) {
        .unsigned => 65535,
        .signed => 32767,
    };
}

fn clampVec(v: Vec, format: Format) Vec {
    var out: Vec = undefined;
    for (v, &out) |x, *y| y.* = std.math.clamp(x, domainMin(format), domainMax(format));
    return out;
}

const Line = struct { a: Vec, b: Vec };

/// The region's members, in pixel order.
const Members = struct {
    pixel: [16]u8 = undefined,
    count: u8 = 0,

    fn slice(self: *const Members) []const u8 {
        return self.pixel[0..self.count];
    }
};

/// The endpoints at the extremes of the members' principal axis, found by
/// power iteration on their covariance.
fn fitLine(u: *const [16]Vec, members: []const u8, format: Format) Line {
    assert(members.len >= 1 and members.len <= 16);
    var mean: Vec = @splat(0);
    var lo: Vec = u[members[0]];
    var hi: Vec = u[members[0]];
    for (members) |i| {
        for (0..3) |c| {
            mean[c] += u[i][c];
            lo[c] = @min(lo[c], u[i][c]);
            hi[c] = @max(hi[c], u[i][c]);
        }
    }
    const n: f64 = @floatFromInt(members.len);
    for (&mean) |*m| m.* /= n;

    var cov: [3][3]f64 = @splat(@splat(0));
    for (members) |i| {
        const d: Vec = .{ u[i][0] - mean[0], u[i][1] - mean[1], u[i][2] - mean[2] };
        for (0..3) |r| for (0..3) |c| {
            cov[r][c] += d[r] * d[c];
        };
    }

    // The bounding box diagonal starts the iteration; with no spread at all
    // the line is a point.
    var axis: Vec = .{ hi[0] - lo[0], hi[1] - lo[1], hi[2] - lo[2] };
    if (axis[0] == 0 and axis[1] == 0 and axis[2] == 0) return .{ .a = mean, .b = mean };
    for (0..8) |_| {
        var next: Vec = undefined;
        for (0..3) |r| next[r] = cov[r][0] * axis[0] + cov[r][1] * axis[1] + cov[r][2] * axis[2];
        const scale = @max(@abs(next[0]), @max(@abs(next[1]), @abs(next[2])));
        if (scale == 0) break;
        for (&next) |*x| x.* /= scale;
        axis = next;
    }
    const len = @sqrt(axis[0] * axis[0] + axis[1] * axis[1] + axis[2] * axis[2]);
    assert(len > 0);
    for (&axis) |*x| x.* /= len;

    var t_min: f64 = std.math.inf(f64);
    var t_max: f64 = -std.math.inf(f64);
    for (members) |i| {
        const t = (u[i][0] - mean[0]) * axis[0] + (u[i][1] - mean[1]) * axis[1] + (u[i][2] - mean[2]) * axis[2];
        t_min = @min(t_min, t);
        t_max = @max(t_max, t);
    }
    var a: Vec = undefined;
    var b: Vec = undefined;
    for (0..3) |c| {
        a[c] = mean[c] + axis[c] * t_min;
        b[c] = mean[c] + axis[c] * t_max;
    }
    return .{ .a = clampVec(a, format), .b = clampVec(b, format) };
}

fn lerpVec(a: Vec, b: Vec, alpha: f64) Vec {
    return .{ a[0] + (b[0] - a[0]) * alpha, a[1] + (b[1] - a[1]) * alpha, a[2] + (b[2] - a[2]) * alpha };
}

fn distSq(a: Vec, b: Vec) f64 {
    const d0 = a[0] - b[0];
    const d1 = a[1] - b[1];
    const d2 = a[2] - b[2];
    return d0 * d0 + d1 * d1 + d2 * d2;
}

/// The nearest weight for each member against the continuous line, and the
/// squared error it leaves.
fn assignContinuous(u: *const [16]Vec, members: []const u8, line: Line, weights: []const i32, alpha_out: ?*[16]f64) f64 {
    var err: f64 = 0;
    for (members) |i| {
        var best = std.math.inf(f64);
        var best_alpha: f64 = 0;
        for (weights) |w| {
            const alpha = @as(f64, @floatFromInt(w)) / 64.0;
            const d = distSq(lerpVec(line.a, line.b, alpha), u[i]);
            if (d < best) {
                best = d;
                best_alpha = alpha;
            }
        }
        err += best;
        if (alpha_out) |out| out[i] = best_alpha;
    }
    return err;
}

/// Least-squares endpoints for the members given each one's weight; null
/// when the weights cannot separate two endpoints.
fn solveLine(u: *const [16]Vec, members: []const u8, alpha: *const [16]f64, format: Format) ?Line {
    var a00: f64 = 0;
    var a01: f64 = 0;
    var a11: f64 = 0;
    var r0: Vec = @splat(0);
    var r1: Vec = @splat(0);
    for (members) |i| {
        const w = alpha[i];
        const v = 1.0 - w;
        a00 += v * v;
        a01 += v * w;
        a11 += w * w;
        for (0..3) |c| {
            r0[c] += v * u[i][c];
            r1[c] += w * u[i][c];
        }
    }
    const det = a00 * a11 - a01 * a01;
    if (det < 1e-9) return null;
    var a: Vec = undefined;
    var b: Vec = undefined;
    for (0..3) |c| {
        a[c] = (a11 * r0[c] - a01 * r1[c]) / det;
        b[c] = (a00 * r1[c] - a01 * r0[c]) / det;
    }
    return .{ .a = clampVec(a, format), .b = clampVec(b, format) };
}

/// The line, refined once by least squares against its own nearest weights.
fn fitRegion(u: *const [16]Vec, members: []const u8, weights: []const i32, format: Format) Line {
    const line = fitLine(u, members, format);
    var alpha: [16]f64 = undefined;
    _ = assignContinuous(u, members, line, weights, &alpha);
    return solveLine(u, members, &alpha, format) orelse line;
}

// --- Quantization -------------------------------------------------------------

fn valueMin(bits: u5, format: Format) i32 {
    return switch (format) {
        .unsigned => 0,
        // The most negative code is avoided: at 16 bits it would finish
        // to minus infinity.
        .signed => -((@as(i32, 1) << (bits - 1)) - 1),
    };
}

fn valueMax(bits: u5, format: Format) i32 {
    return switch (format) {
        .unsigned => @intCast(mask(bits)),
        .signed => (@as(i32, 1) << (bits - 1)) - 1,
    };
}

/// The `bits`-wide endpoint value whose unquantized value is nearest `x`.
fn quantize(x: f64, bits: u5, format: Format) i32 {
    // Unquantization is close to scaling by 2^16 / 2^bits (2^15 / 2^(bits-1)
    // signed), so the estimate is within a step or two; the search settles it.
    const scale: f64 = switch (format) {
        .unsigned => @as(f64, @floatFromInt(@as(u32, 1) << bits)) / 65536.0,
        .signed => @as(f64, @floatFromInt(@as(u32, 1) << (bits - 1))) / 32768.0,
    };
    const estimate: i32 = @intFromFloat(@round(std.math.clamp(x, -70000, 70000) * scale));
    const lo = valueMin(bits, format);
    const hi = valueMax(bits, format);
    var best: i32 = std.math.clamp(estimate, lo, hi);
    var best_dist = @abs(@as(f64, @floatFromInt(bc6h.unquantize(best, bits, format))) - x);
    var q = @max(lo, estimate - 2);
    while (q <= @min(hi, estimate + 2)) : (q += 1) {
        const d = @abs(@as(f64, @floatFromInt(bc6h.unquantize(q, bits, format))) - x);
        if (d < best_dist) {
            best = q;
            best_dist = d;
        }
    }
    assert(best >= lo and best <= hi);
    return best;
}

/// Wraps `v` to a `bits`-wide two's complement value, as the decoder's
/// masked delta sum does.
fn wrap(v: i32, bits: u5) i32 {
    return bc6h.signExtend(v & @as(i32, @intCast(mask(bits))), bits);
}

/// Stores quantized endpoints `q` (of `count` endpoints) in `fields`, and
/// replaces them by what the decoder will reconstruct. A transformed mode
/// keeps endpoints after the first as deltas from it: when they do not all
/// fit, the base moves to where they do if it can, and deltas still out of
/// range are clamped.
fn store(fields: *Fields, q: *[4][3]i32, count: usize, format: Format) void {
    const mode = bc6h.modes[fields.mode];
    const n = mode.base_bits;
    for (0..3) |c| {
        if (!mode.transformed) {
            for (0..count) |e| fields.stored[e][c] = @as(u32, @bitCast(q[e][c])) & mask(n);
            continue;
        }
        const d = mode.delta_bits[c];
        const d_min = -(@as(i32, 1) << (d - 1));
        const d_max = (@as(i32, 1) << (d - 1)) - 1;
        var lo: i32 = std.math.minInt(i32);
        var hi: i32 = std.math.maxInt(i32);
        for (1..count) |e| {
            lo = @max(lo, q[e][c] - d_max);
            hi = @min(hi, q[e][c] - d_min);
        }
        if (lo <= hi) q[0][c] = std.math.clamp(std.math.clamp(q[0][c], lo, hi), valueMin(n, format), valueMax(n, format));
        const base = q[0][c];
        fields.stored[0][c] = @as(u32, @bitCast(base)) & mask(n);
        for (1..count) |e| {
            const delta = std.math.clamp(wrap(q[e][c] - base, n), d_min, d_max);
            fields.stored[e][c] = @as(u32, @bitCast(delta)) & mask(d);
            const sum = (base + delta) & @as(i32, @intCast(mask(n)));
            q[e][c] = if (format == .signed) bc6h.signExtend(sum, n) else sum;
        }
    }
}

// --- Search ---------------------------------------------------------------------

pub const Encoded = struct {
    block: [block_bytes]u8,
    /// The exact error of the decoded block against the targets.
    err: u64,
};

const Candidate = struct {
    fields: Fields,
    err: u64,
};

const Setup = struct {
    t: *const Targets,
    u: *const [16]Vec,
    format: Format,
};

/// Quantizes `lines` (one per region) for mode `mode_index`, stores them,
/// picks each pixel's best index against the exact palette and returns the
/// candidate with its exact error.
fn evaluate(setup: Setup, mode_index: u4, partition: u5, lines: []const Line) Candidate {
    const mode = bc6h.modes[mode_index];
    const regions: usize = mode.regions;
    assert(lines.len == regions);
    const part = texcomp_bc6h.partition(partition);
    var fields: Fields = .{ .mode = mode_index, .partition = if (regions == 2) partition else 0 };

    var q: [4][3]i32 = @splat(@splat(0));
    for (lines, 0..) |line, r| {
        for (0..3) |c| {
            q[r * 2][c] = quantize(line.a[c], mode.base_bits, setup.format);
            q[r * 2 + 1][c] = quantize(line.b[c], mode.base_bits, setup.format);
        }
    }
    store(&fields, &q, regions * 2, setup.format);

    var unq: [4][3]i32 = undefined;
    for (0..regions * 2) |e| {
        for (0..3) |c| unq[e][c] = bc6h.unquantize(q[e][c], mode.base_bits, setup.format);
    }
    const weights: []const i32 = if (regions == 1) &weights1 else &weights2;
    var palette: [2][16][3]i32 = undefined;
    for (0..regions) |r| {
        for (weights, 0..) |w, k| {
            for (0..3) |c| palette[r][k][c] = halfValue(interpolate(unq[r * 2][c], unq[r * 2 + 1][c], w, setup.format), setup.format);
        }
    }

    var err: u64 = 0;
    for (0..16) |i| {
        const r: usize = if (regions == 1) 0 else part[i];
        // An anchor's index drops its top bit, so it must be in the lower half.
        const limit = if (isAnchor(mode.regions, partition, i)) weights.len / 2 else weights.len;
        var best: u64 = std.math.maxInt(u64);
        var best_k: usize = 0;
        for (0..limit) |k| {
            var e: u64 = 0;
            for (0..3) |c| {
                const diff: i64 = @as(i64, palette[r][k][c]) - setup.t[i][c];
                e += @intCast(diff * diff);
            }
            if (e < best) {
                best = e;
                best_k = k;
            }
        }
        fields.indices[i] = @intCast(best_k);
        err += best;
    }
    return .{ .fields = fields, .err = err };
}

/// Orients each region's line so its anchor pixel lies nearer the first
/// endpoint: weights and rounding are symmetric, so this loses nothing and
/// leaves the anchor a lower-half index.
fn orient(setup: Setup, partition: u5, regions: usize, members: []const Members, lines: []Line) void {
    for (0..regions) |r| {
        const anchor: usize = if (r == 0) 0 else texcomp_bc6h.part2_anchor[partition];
        assert(members[r].count > 0);
        const line = lines[r];
        var dot: f64 = 0;
        var len: f64 = 0;
        for (0..3) |c| {
            const d = line.b[c] - line.a[c];
            dot += (setup.u[anchor][c] - line.a[c]) * d;
            len += d * d;
        }
        if (len > 0 and dot > 0.5 * len) lines[r] = .{ .a = line.b, .b = line.a };
    }
}

/// Searches one mode from starting lines: evaluate, refit the lines to the
/// chosen indices by least squares, repeat; returns the best seen.
fn searchMode(setup: Setup, mode_index: u4, partition: u5, members: []const Members, start: []const Line, best_err: u64) Candidate {
    const mode = bc6h.modes[mode_index];
    const regions: usize = mode.regions;
    const weights: []const i32 = if (regions == 1) &weights1 else &weights2;
    var lines: [2]Line = undefined;
    @memcpy(lines[0..regions], start[0..regions]);
    var best: ?Candidate = null;
    for (0..refine_passes + 1) |pass| {
        orient(setup, partition, regions, members, lines[0..regions]);
        const cand = evaluate(setup, mode_index, partition, lines[0..regions]);
        if (best == null or cand.err < best.?.err) best = cand;
        if (cand.err == 0 or pass == refine_passes) break;
        // Refits rarely recover a start this far behind the best block.
        if (cand.err / refit_ratio_max > best_err) break;
        var alpha: [16]f64 = undefined;
        for (0..16) |i| alpha[i] = @as(f64, @floatFromInt(weights[cand.fields.indices[i]])) / 64.0;
        for (0..regions) |r| {
            if (solveLine(setup.u, members[r].slice(), &alpha, setup.format)) |line| lines[r] = line;
        }
    }
    return best.?;
}

fn flatFields(t: [3]i32, format: Format) Fields {
    // Mode 13 keeps 16-bit endpoints, which unquantize to themselves, and
    // finishing is onto every half code, so one endpoint with all indices 0
    // reproduces any colour exactly.
    var fields: Fields = .{ .mode = 13 };
    for (0..3) |c| {
        const v = flatEndpoint(t[c], format);
        fields.stored[0][c] = @as(u32, @bitCast(v)) & 0xffff;
    }
    return fields;
}

/// The 16-bit endpoint value that finishes to half code `t`.
pub fn flatEndpoint(t: i32, format: Format) i32 {
    const mag: i32 = @intCast(@abs(t));
    const ratio: i32 = switch (format) {
        .unsigned => 64,
        .signed => 32,
    };
    // The smallest value whose scaled magnitude reaches `mag`.
    var v = @divFloor(mag * ratio + 30, 31);
    const shift: u5 = switch (format) {
        .unsigned => 6,
        .signed => 5,
    };
    while ((v * 31) >> shift > mag) v -= 1;
    while ((v * 31) >> shift < mag) v += 1;
    assert((v * 31) >> shift == mag);
    return if (t < 0) -v else v;
}

const Ranked = struct {
    err: f64,
    p: u5,

    fn lessThan(_: void, a: Ranked, b: Ranked) bool {
        return a.err < b.err or (a.err == b.err and a.p < b.p);
    }
};

pub fn encodeBlock(pixels: *const [16][3]f32, format: Format) Encoded {
    const t = targets(pixels, format);

    const flat = for (t[1..]) |p| {
        if (!std.mem.eql(i32, &p, &t[0])) break false;
    } else true;
    if (flat) {
        const fields = flatFields(t[0], format);
        return .{ .block = pack(&fields), .err = 0 };
    }

    var u: [16]Vec = undefined;
    for (t, &u) |p, *v| {
        for (p, v) |x, *y| y.* = toDomain(x, format);
    }
    const setup: Setup = .{ .t = &t, .u = &u, .format = format };

    // texcomp's block competes too.
    const fast_block = bc6h.encodeBlock(pixels, format);
    var best_block = fast_block;
    var best_err = decodedError(&bc6h.decodeBlock(&fast_block, format), &t, format);
    var best_fields: ?Fields = null;

    // One region: all four modes from one fit.
    var all: Members = .{};
    for (0..16) |i| all.pixel[i] = @intCast(i);
    all.count = 16;
    const one = [1]Line{fitRegion(&u, all.slice(), &weights1, format)};
    for ([_]u4{ 10, 11, 12, 13 }) |m| {
        if (best_err == 0) break;
        const cand = searchMode(setup, m, 0, &.{all}, &one, best_err);
        if (cand.err < best_err) {
            best_err = cand.err;
            best_fields = cand.fields;
        }
    }

    // Two regions: rank partitions by a continuous fit, then search every
    // two-region mode on the best few.
    if (best_err > 0) {
        var ranked: [32]Ranked = undefined;
        var members: [32][2]Members = undefined;
        for (0..32) |p| {
            members[p] = .{ .{}, .{} };
            const part = texcomp_bc6h.partition(@intCast(p));
            for (0..16) |i| {
                const r = &members[p][part[i]];
                r.pixel[r.count] = @intCast(i);
                r.count += 1;
            }
            var e: f64 = 0;
            for (&members[p]) |*r| {
                const line = fitLine(&u, r.slice(), format);
                e += assignContinuous(&u, r.slice(), line, &weights2, null);
            }
            ranked[p] = .{ .err = e, .p = @intCast(p) };
        }
        std.sort.insertion(Ranked, &ranked, {}, Ranked.lessThan);

        for (ranked[0..partitions_searched]) |entry| {
            if (best_err == 0) break;
            const p = entry.p;
            const regions = &members[p];
            const lines = [2]Line{
                fitRegion(&u, regions[0].slice(), &weights2, format),
                fitRegion(&u, regions[1].slice(), &weights2, format),
            };
            for (0..10) |m| {
                const cand = searchMode(setup, @intCast(m), p, regions, &lines, best_err);
                if (cand.err < best_err) {
                    best_err = cand.err;
                    best_fields = cand.fields;
                }
            }
        }
    }

    if (best_fields) |f| best_block = pack(&f);
    return .{ .block = best_block, .err = best_err };
}

test "float to half rounds to nearest even like the hardware" {
    // Every float would take tens of seconds in Debug; the differential
    // test covers all of them, this one every exponent with mantissa edges.
    var exp: u32 = 0;
    while (exp < 256) : (exp += 1) {
        for ([_]u32{ 0, 1, 0xfff, 0x1000, 0x1001, 0x2000, 0x3000, 0x7fffff, 0x400000, 0x7fe000, 0x7ff000 }) |man| {
            for ([_]u32{ 0, 0x80000000 }) |sign| {
                const bits = sign | (exp << 23) | man;
                const x: f32 = @bitCast(bits);
                const want: u16 = @bitCast(@as(f16, @floatCast(x)));
                const got = floatToHalfRne(x);
                if (std.math.isNan(x)) {
                    try std.testing.expect(got & 0x7c00 == 0x7c00 and got & 0x3ff != 0);
                } else {
                    try std.testing.expectEqual(want, got);
                }
            }
        }
    }
}

test "every half code has a flat endpoint" {
    for ([_]Format{ .unsigned, .signed }) |format| {
        var t: i32 = if (format == .signed) -half_max else 0;
        while (t <= half_max) : (t += 1) {
            const v = flatEndpoint(t, format);
            try std.testing.expectEqual(t, halfValue(interpolate(v, v, 0, format), format));
        }
    }
}
