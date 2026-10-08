//! The fixed image set for the differential tests: procedural and seeded, so
//! it needs no files and every run sees the same pixels. Each image targets
//! cases encoders get wrong: flat colour, gradients, alpha edges, noise,
//! normal maps, few-colour blocks for BC7 partitions, and extreme or
//! near-degenerate values. Sizes are not multiples of 4 so edge blocks are
//! covered.

const std = @import("std");
const assert = std.debug.assert;

pub const width = 61;
pub const height = 47;
pub const pixel_count = width * height;

/// SplitMix64: a fixed generator, so the set never depends on std's PRNG.
pub const Rng = struct {
    state: u64,

    pub fn next(self: *Rng) u64 {
        self.state +%= 0x9e3779b97f4a7c15;
        var z = self.state;
        z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
        z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
        return z ^ (z >> 31);
    }

    pub fn below(self: *Rng, n: u32) u32 {
        assert(n > 0);
        return @intCast(self.next() % n);
    }

    pub fn byte(self: *Rng) u8 {
        return @truncate(self.next());
    }

    /// A float in [0, 1).
    pub fn unit(self: *Rng) f32 {
        return @as(f32, @floatFromInt(self.next() >> 40)) / @as(f32, 1 << 24);
    }
};

pub const Ldr = struct {
    name: []const u8,
    pixels: [pixel_count][4]u8,
};

pub const ldr_names = [_][]const u8{
    "flat_blocks",  "gradients",    "alpha_edges", "punch_alpha",
    "noise",        "smooth_noise", "normal_map",  "two_colors",
    "three_colors", "low_contrast", "extremes",    "gray_ramp",
    "soft_alpha",   "hue_stripes",
};

pub fn ldr(index: usize) Ldr {
    var img: Ldr = .{ .name = ldr_names[index], .pixels = undefined };
    var rng: Rng = .{ .state = 0x6263_6e00 + index };
    const px = &img.pixels;
    switch (index) {
        0 => { // flat_blocks: every 4x4 cell one colour, often opaque
            for (0..height) |y| for (0..width) |x| {
                var cell: Rng = .{ .state = (y / 4) * 1000 + (x / 4) };
                var c: [4]u8 = .{ cell.byte(), cell.byte(), cell.byte(), cell.byte() };
                if (cell.below(3) != 0) c[3] = 255;
                if (cell.below(5) == 0) c = .{ 0, 0, 0, 255 };
                if (cell.below(5) == 0) c = .{ 255, 255, 255, 255 };
                px[y * width + x] = c;
            };
        },
        1 => { // gradients: horizontal, vertical and diagonal, alpha too
            for (0..height) |y| for (0..width) |x| {
                px[y * width + x] = .{
                    @intCast(x * 255 / (width - 1)),
                    @intCast(y * 255 / (height - 1)),
                    @intCast((x + y) * 255 / (width + height - 2)),
                    @intCast(255 - (x * 128 / width)),
                };
            };
        },
        2 => { // alpha_edges: colour noise with hard 0/255 alpha shapes
            for (0..height) |y| for (0..width) |x| {
                const dx = @as(i32, @intCast(x)) - 30;
                const dy = @as(i32, @intCast(y)) - 23;
                const inside = dx * dx + dy * dy < 18 * 18;
                const a: u8 = if (inside != ((x / 7) % 2 == 0)) 255 else 0;
                px[y * width + x] = .{ rng.byte(), 128, rng.byte() / 2, a };
            };
        },
        3 => { // punch_alpha: smooth colour with binary alpha
            for (0..height) |y| for (0..width) |x| {
                px[y * width + x] = .{ @intCast(x * 4), @intCast(y * 5), 90, if (rng.below(4) == 0) 0 else 255 };
            };
        },
        4 => { // noise: uniform random RGBA
            for (px) |*p| p.* = .{ rng.byte(), rng.byte(), rng.byte(), rng.byte() };
        },
        5 => { // smooth_noise: bilinear value noise, photo-like, opaque
            var lattice: [8][8][3]u8 = undefined;
            for (&lattice) |*row| for (row) |*c| {
                c.* = .{ rng.byte(), rng.byte(), rng.byte() };
            };
            for (0..height) |y| for (0..width) |x| {
                const fx = x * 7 * 256 / width;
                const fy = y * 7 * 256 / height;
                const ix = fx / 256;
                const iy = fy / 256;
                const tx = fx % 256;
                const ty = fy % 256;
                var c: [4]u8 = .{ 0, 0, 0, 255 };
                for (0..3) |ch| {
                    const a = @as(u32, lattice[iy][ix][ch]) * (256 - tx) + @as(u32, lattice[iy][ix + 1][ch]) * tx;
                    const b = @as(u32, lattice[iy + 1][ix][ch]) * (256 - tx) + @as(u32, lattice[iy + 1][ix + 1][ch]) * tx;
                    c[ch] = @intCast((a * (256 - ty) + b * ty) >> 16);
                }
                px[y * width + x] = c;
            };
        },
        6 => { // normal_map: normals of a bumpy height field, xyz in rgb
            for (0..height) |y| for (0..width) |x| {
                const fx: f32 = @floatFromInt(x);
                const fy: f32 = @floatFromInt(y);
                const nx = 0.6 * @sin(fx * 0.37) * @cos(fy * 0.21);
                const ny = 0.6 * @cos(fx * 0.13 + 1.0) * @sin(fy * 0.41);
                const nz = @sqrt(@max(0.0, 1.0 - nx * nx - ny * ny));
                px[y * width + x] = .{ toUnorm(nx), toUnorm(ny), toUnorm(nz), 255 };
            };
        },
        7, 8 => { // two_colors, three_colors: random palettes per block
            const colors: u32 = if (index == 7) 2 else 3;
            for (0..height) |y| for (0..width) |x| {
                var cell: Rng = .{ .state = index * 7777 + (y / 4) * 100 + (x / 4) };
                var palette: [3][4]u8 = undefined;
                for (&palette) |*c| c.* = .{ cell.byte(), cell.byte(), cell.byte(), if (cell.below(2) == 0) 255 else cell.byte() };
                const split = cell.below(4);
                const k: u32 = switch (split) {
                    0 => @intFromBool(x % 4 >= 2),
                    1 => @intFromBool(y % 4 >= 2),
                    2 => @intFromBool(x % 4 + y % 4 >= 3),
                    else => rng.below(colors),
                };
                px[y * width + x] = palette[@min(k + (if (colors == 3 and (y % 4) == 3) @as(u32, 1) else 0), colors - 1)];
            };
        },
        9 => { // low_contrast: values within a few steps, near-degenerate endpoints
            for (px) |*p| {
                const base: u8 = 100;
                p.* = .{ base + rng.byte() % 3, base + rng.byte() % 2, base + rng.byte() % 4, 254 + rng.byte() % 2 };
            }
        },
        10 => { // extremes: channels at 0 or 255
            for (px) |*p| p.* = .{ ext(&rng), ext(&rng), ext(&rng), ext(&rng) };
        },
        11 => { // gray_ramp: equal channels, opaque
            for (0..height) |y| for (0..width) |x| {
                const v: u8 = @intCast((x * 3 + y * 2) % 256);
                px[y * width + x] = .{ v, v, v, 255 };
            };
        },
        12 => { // soft_alpha: smooth colour with smooth alpha
            for (0..height) |y| for (0..width) |x| {
                px[y * width + x] = .{ @intCast(255 - x * 4), 60, @intCast(y * 5), @intCast((x * 2 + y * 3) % 256) };
            };
        },
        13 => { // hue_stripes: saturated colours with sharp borders
            const hues = [_][3]u8{ .{ 255, 0, 0 }, .{ 0, 255, 0 }, .{ 0, 0, 255 }, .{ 255, 255, 0 }, .{ 0, 255, 255 }, .{ 255, 0, 255 } };
            for (0..height) |y| for (0..width) |x| {
                const h = hues[((x + y / 2) / 3) % hues.len];
                px[y * width + x] = .{ h[0], h[1], h[2], 255 };
            };
        },
        else => unreachable,
    }
    return img;
}

fn toUnorm(v: f32) u8 {
    return @intFromFloat(@round((v * 0.5 + 0.5) * 255.0));
}

fn ext(rng: *Rng) u8 {
    return switch (rng.below(4)) {
        0 => 0,
        1 => 255,
        2 => 1,
        else => 254,
    };
}

pub const Hdr = struct {
    name: []const u8,
    pixels: [pixel_count][3]f32,
};

pub const hdr_names = [_][]const u8{
    "hdr_flat_ranges", "hdr_log_gradient", "hdr_log_noise", "hdr_sun",
    "hdr_signed",      "hdr_specials",     "hdr_small",     "hdr_two_regions",
};

pub fn hdr(index: usize) Hdr {
    var img: Hdr = .{ .name = hdr_names[index], .pixels = undefined };
    var rng: Rng = .{ .state = 0x6263_6e68 + index };
    const px = &img.pixels;
    switch (index) {
        0 => { // hdr_flat_ranges: each cell one value from a ladder of magnitudes
            const ladder = [_]f32{ 0, 1e-7, 6e-5, 0.001, 0.18, 0.5, 1, 2.5, 16, 100, 1000, 30000, 65504, 70000 };
            for (0..height) |y| for (0..width) |x| {
                var cell: Rng = .{ .state = (y / 4) * 1000 + (x / 4) };
                px[y * width + x] = .{ ladder[cell.below(ladder.len)], ladder[cell.below(ladder.len)], ladder[cell.below(ladder.len)] };
            };
        },
        1 => { // hdr_log_gradient: smooth over many exponents
            for (0..height) |y| for (0..width) |x| {
                const t = @as(f32, @floatFromInt(x)) / width;
                const s = @as(f32, @floatFromInt(y)) / height;
                px[y * width + x] = .{ std.math.exp2(-10.0 + 24.0 * t), std.math.exp2(-4.0 + 8.0 * s), 0.25 + t * s };
            };
        },
        2 => { // hdr_log_noise: random values spanning 1e-4 to 1e4
            for (px) |*p| p.* = .{ logNoise(&rng), logNoise(&rng), logNoise(&rng) };
        },
        3 => { // hdr_sun: a bright disc on a dim sky, sharp edges
            for (0..height) |y| for (0..width) |x| {
                const dx = @as(f32, @floatFromInt(x)) - 40;
                const dy = @as(f32, @floatFromInt(y)) - 12;
                const sky: [3]f32 = .{ 0.2, 0.35, 0.9 };
                px[y * width + x] = if (dx * dx + dy * dy < 64) .{ 5000, 4500, 3000 } else sky;
            };
        },
        4 => { // hdr_signed: negative and positive values (unsigned clamps them)
            for (px) |*p| p.* = .{ signedNoise(&rng), signedNoise(&rng), signedNoise(&rng) };
        },
        5 => { // hdr_specials: infinities and NaN mixed with ordinary values
            const specials = [_]f32{ std.math.inf(f32), -std.math.inf(f32), std.math.nan(f32), 0, -0.0, 1, 65520, 1e30, -1e30 };
            for (px) |*p| p.* = .{ specials[rng.below(specials.len)], rng.unit(), specials[rng.below(specials.len)] };
        },
        6 => { // hdr_small: subnormal half range
            for (px) |*p| p.* = .{ rng.unit() * 6e-5, rng.unit() * 1e-6, rng.unit() * 1e-3 };
        },
        7 => { // hdr_two_regions: two very different values per block
            for (0..height) |y| for (0..width) |x| {
                var cell: Rng = .{ .state = 99 + (y / 4) * 100 + (x / 4) };
                const a: [3]f32 = .{ logNoise(&cell), logNoise(&cell), logNoise(&cell) };
                const b: [3]f32 = .{ logNoise(&cell), logNoise(&cell), logNoise(&cell) };
                const jitter = 1.0 + 0.05 * rng.unit();
                const c = if ((x % 4) + (y % 4) * cell.below(2) >= 2) a else b;
                px[y * width + x] = .{ c[0] * jitter, c[1] * jitter, c[2] };
            };
        },
        else => unreachable,
    }
    return img;
}

fn logNoise(rng: *Rng) f32 {
    return std.math.exp2(-13.0 + 26.0 * rng.unit());
}

fn signedNoise(rng: *Rng) f32 {
    const v = std.math.exp2(-8.0 + 18.0 * rng.unit());
    return if (rng.below(2) == 0) -v else v;
}
