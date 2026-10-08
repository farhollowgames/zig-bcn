//! BC6H against texcomp: the encoder under texcomp's SIMD and scalar
//! dispatch, the decoder on encoder output and random blocks, and the round
//! trip error on the HDR image set.

const std = @import("std");
const bcn = @import("bcn");
const images = @import("images.zig");
const common = @import("common.zig");

const TcOptions = extern struct { signed_float: c_int, reserved: c_int };

/// Prints which modes win and how many blocks each mode can encode, for
/// studying the encoder; off so test output stays quiet.
const print_stats = false;

extern fn tc_bc6h_compress_rgb32f(rgb: [*]const f32, width: u32, height: u32, stride_bytes: usize, opt: ?*const TcOptions, out: [*]u8, out_size: usize) c_int;
extern fn tc_bc6h_decompress_rgb16f(bc6h: [*]const u8, width: u32, height: u32, is_signed: c_int, stride_bytes: usize, out_rgb: [*]u16, out_size: usize) c_int;
extern fn tc_bc6h_decode_block_half(blk: *const [16]u8, is_signed: c_int, out: *[16][3]u16) void;
extern fn tc_backend_force_mask(mask: u32) void;
extern fn tc_backend_name() [*:0]const u8;
extern fn tc_bc6h_options_init(opt: ?*TcOptions) void;
extern fn tc_bc6h_decompress_rgbaf(bc6h: [*]const u8, width: u32, height: u32, is_signed: c_int, stride_bytes: usize, out_rgba: [*]f32, out_size: usize) c_int;

const formats = [_]bcn.bc6h.Format{ .unsigned, .signed };
const encoded_len = bcn.encodedLen(16, images.width, images.height);

fn view(img: *const images.Hdr) bcn.Image(f32) {
    const floats: []const f32 = @as([*]const f32, @ptrCast(&img.pixels))[0 .. images.pixel_count * 3];
    return bcn.Image(f32).init(floats, images.width, images.height, 3);
}

fn referenceEncode(img: *const images.Hdr, index: usize, format: bcn.bc6h.Format, out: *[encoded_len]u8) !void {
    var opt: TcOptions = undefined;
    tc_bc6h_options_init(&opt);
    tc_bc6h_options_init(null); // a no-op, for coverage of the original
    opt.signed_float = @intFromBool(format == .signed);
    // texcomp treats no options as unsigned; pass none for half the images.
    const opt_ptr: ?*const TcOptions = if (format == .unsigned and index % 2 == 0) null else &opt;
    const rc = tc_bc6h_compress_rgb32f(@ptrCast(&img.pixels), images.width, images.height, images.width * 3 * @sizeOf(f32), opt_ptr, out, out.len);
    try std.testing.expectEqual(@as(c_int, 0), rc);
}

/// The mode a block was encoded in, from its code bits; 14 for reserved.
fn modeOf(block: *const [16]u8) usize {
    const b0 = block[0];
    if (b0 & 3 == 0) return 0;
    if (b0 & 3 == 1) return 1;
    return switch (b0 & 0x1f) {
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
        else => 14,
    };
}

test "bc6h encodes like texcomp under SIMD and scalar dispatch" {
    // texcomp picks its selector kernel from a global; restore it after.
    defer tc_backend_force_mask(0xffffffff);
    var want: [encoded_len]u8 = undefined;
    var got: [encoded_len]u8 = undefined;
    const dispatches = [_]struct { mask: u32, label: []const u8 }{
        .{ .mask = 0xffffffff, .label = "default" },
        .{ .mask = 0, .label = "scalar" },
        .{ .mask = 1 | 2, .label = "sse4.1" }, // SSE2 and SSE4.1, not AVX2
    };
    var mode_counts: [2][15]u32 = @splat(@splat(0));
    for (dispatches) |d| {
        tc_backend_force_mask(d.mask);
        for (0..images.hdr_names.len) |index| {
            const img = images.hdr(index);
            for (formats, 0..) |format, fi| {
                try referenceEncode(&img, index, format, &want);
                bcn.bc6h.encodeImage(view(&img), &got, format);
                var m: common.Mismatches = .{ .label = img.name };
                const what = if (format == .signed) "sf16" else "uf16";
                for (0..common.blocks_high) |by| for (0..common.blocks_wide) |bx| {
                    const bi = by * common.blocks_wide + bx;
                    const block = view(&img).block(3, @intCast(bx), @intCast(by));
                    m.check(what, @intCast(bx), @intCast(by), block, want[bi * 16 ..][0..16], got[bi * 16 ..][0..16]);
                    if (d.mask == 0) mode_counts[fi][modeOf(want[bi * 16 ..][0..16])] += 1;
                };
                if (m.count > 0) std.debug.print("dispatch {s} ({s})\n", .{ d.label, tc_backend_name() });
                try m.finish();
            }
        }
    }
    if (print_stats) std.debug.print("\nbc6h modes chosen (uf16): {any}\nbc6h modes chosen (sf16): {any}\n", .{ mode_counts[0], mode_counts[1] });
}

test "bc6h decodes like texcomp" {
    var m: common.Mismatches = .{ .label = "bc6h decode" };
    // Every encoder output, both formats.
    var encoded: [encoded_len]u8 = undefined;
    var want: [images.pixel_count][3]u16 = undefined;
    var got: [images.pixel_count][3]u16 = undefined;
    for (0..images.hdr_names.len) |index| {
        const img = images.hdr(index);
        for (formats) |format| {
            const is_signed = @intFromBool(format == .signed);
            bcn.bc6h.encodeImage(view(&img), &encoded, format);
            try std.testing.expectEqual(@as(c_int, 0), tc_bc6h_decompress_rgb16f(&encoded, images.width, images.height, is_signed, images.width * 3 * 2, @ptrCast(&want), @sizeOf(@TypeOf(want))));
            bcn.bc6h.decodeImage(&encoded, bcn.ImageMut(u16).init(@as([*]u16, @ptrCast(&got))[0 .. images.pixel_count * 3], images.width, images.height, 3), format);
            m.check(img.name, 0, @intCast(index), format, std.mem.asBytes(&want), std.mem.asBytes(&got));

            // The float decoders, RGBA with alpha 1 and RGB.
            var want_f: [images.pixel_count][4]f32 = undefined;
            var got_f: [images.pixel_count][4]f32 = undefined;
            try std.testing.expectEqual(@as(c_int, 0), tc_bc6h_decompress_rgbaf(&encoded, images.width, images.height, is_signed, images.width * 16, @ptrCast(&want_f), @sizeOf(@TypeOf(want_f))));
            bcn.bc6h.decodeImageF32(&encoded, bcn.ImageMut(f32).init(@as([*]f32, @ptrCast(&got_f))[0 .. images.pixel_count * 4], images.width, images.height, 4), format);
            m.check(img.name, 1, @intCast(index), format, std.mem.asBytes(&want_f), std.mem.asBytes(&got_f));
            var got_rgb: [images.pixel_count][3]f32 = undefined;
            bcn.bc6h.decodeImageF32(&encoded, bcn.ImageMut(f32).init(@as([*]f32, @ptrCast(&got_rgb))[0 .. images.pixel_count * 3], images.width, images.height, 3), format);
            for (want_f, got_rgb) |w, g| try std.testing.expectEqual(@as([3]u32, @bitCast(w[0..3].*)), @as([3]u32, @bitCast(g)));
        }
    }
    // Random blocks reach every mode, reserved ones included.
    var rng: images.Rng = .{ .state = 0x6c6 };
    for (0..200_000) |i| {
        var block: [16]u8 = undefined;
        for (&block) |*b| b.* = rng.byte();
        for (formats) |format| {
            var want_block: [16][3]u16 = undefined;
            tc_bc6h_decode_block_half(&block, @intFromBool(format == .signed), &want_block);
            const got_block = bcn.bc6h.decodeBlock(&block, format);
            m.check("random", @intCast(i), 0, block, std.mem.asBytes(&want_block), std.mem.asBytes(&got_block));
        }
    }
    try m.finish();
}

test "bc6h round-trips the HDR set within the format error" {
    var encoded: [encoded_len]u8 = undefined;
    var decoded: [images.pixel_count][3]u16 = undefined;
    for (0..images.hdr_names.len) |index| {
        const img = images.hdr(index);
        for (formats, 0..) |format, fi| {
            bcn.bc6h.encodeImage(view(&img), &encoded, format);
            bcn.bc6h.decodeImage(&encoded, bcn.ImageMut(u16).init(@as([*]u16, @ptrCast(&decoded))[0 .. images.pixel_count * 3], images.width, images.height, 3), format);
            const err = logRmse(&img, &decoded, format);
            const bound = if (fi == 0) uf16_rmse_max[index] else sf16_rmse_max[index];
            if (err > bound) {
                std.debug.print("{s} {t}: log rmse {d:.4} over {d:.4}\n", .{ img.name, format, err, bound });
                return error.RoundTrip;
            }
        }
    }
}

// Bounds per HDR image (in hdr_names order) on the RMSE of
// sign(x) * log2(1 + |x|), measured on the first port with about 10 percent
// headroom. The noise, signed and specials images are far above the rest:
// random values spanning many stops per block are beyond any BC6H mode.
const uf16_rmse_max = [_]f64{ 0.0084, 0.07, 3.2, 0.0075, 2.25, 4.37, 0.001, 0.0148 };
const sf16_rmse_max = [_]f64{ 0.014, 0.071, 3.24, 0.0069, 3.85, 7.41, 0.001, 0.0212 };

/// What the format can store for `x`: unsigned clamps negatives (and NaN)
/// to zero, both clamp magnitudes to the largest half.
fn representable(x: f32, format: bcn.bc6h.Format) f64 {
    if (std.math.isNan(x)) return 0;
    const lo: f32 = if (format == .unsigned) 0 else -65504;
    return std.math.clamp(x, lo, 65504);
}

fn logRmse(img: *const images.Hdr, decoded: *const [images.pixel_count][3]u16, format: bcn.bc6h.Format) f64 {
    var sum: f64 = 0;
    var n: f64 = 0;
    for (img.pixels, decoded) |p, d| for (0..3) |c| {
        const want = representable(p[c], format);
        const got: f64 = bcn.bc6h.halfToF32(d[c]);
        const lw = std.math.copysign(std.math.log2(1 + @abs(want)), want);
        const lg = std.math.copysign(std.math.log2(1 + @abs(got)), got);
        sum += (lw - lg) * (lw - lg);
        n += 1;
    };
    return @sqrt(sum / n);
}

extern fn ref_bc6h_mode(is_signed: c_int, mode: c_int, pix: *const [16][3]f32, out: *[16]u8, err: *u64) c_int;
extern fn ref_bc6h_block(is_signed: c_int, pix: *const [16][3]f32, out: *[16]u8) void;

/// Fuzz blocks built in the half-float magnitude domain the encoder
/// quantizes in, so their spreads land on either side of every mode's
/// delta limits; with sign flips, specials and plain noise mixed in.
pub fn fuzzBlock(rng: *images.Rng) [16][3]f32 {
    const scales = [_]u32{ 0, 1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384 };
    var px: [16][3]f32 = undefined;
    const family = rng.below(6);
    const part = bcn.bc6h.texcomp.partition(rng.below(32));
    const base: i32 = @intCast(rng.below(0x7c00));
    var center: [2][3]i32 = undefined;
    var width: [2][3]i32 = undefined;
    const spread = scales[rng.below(scales.len)];
    for (0..2) |r| for (0..3) |c| {
        const s: i32 = @intCast(if (family == 1) scales[rng.below(scales.len)] else spread);
        center[r][c] = base + if (r == 1) @as(i32, @intCast(rng.below(@intCast(2 * s + 1)))) - s else 0;
        const ws: i32 = @intCast(scales[rng.below(8)]);
        width[r][c] = @as(i32, @intCast(rng.below(@intCast(2 * ws + 1)))) - ws;
    };
    const noise: i32 = @intCast(scales[rng.below(6)]);
    const sign_mode = rng.below(4);
    for (&px, 0..) |*p, i| {
        const r = if (family == 3) 0 else part[i];
        const t: i32 = @intCast(rng.below(65));
        for (0..3) |c| {
            var mag = center[r][c] + @divTrunc(width[r][c] * t, 64);
            if (noise > 0) mag += @as(i32, @intCast(rng.below(@intCast(2 * noise + 1)))) - noise;
            mag = std.math.clamp(mag, 0, 0x7bff);
            var v = bcn.bc6h.halfToF32(@intCast(mag));
            switch (sign_mode) {
                0 => {},
                1 => if (rng.below(2) == 0) {
                    v = -v;
                },
                2 => if (r == 1) {
                    v = -v;
                },
                else => if (c == 1) {
                    v = -v;
                },
            }
            p[c] = v;
        }
    }
    switch (family) {
        4 => { // specials sprinkled in
            const specials = [_]f32{ std.math.inf(f32), -std.math.inf(f32), std.math.nan(f32), -0.0, 1e30, -1e30, 65504, 65520, 1e-30 };
            for (0..1 + rng.below(4)) |_| px[rng.below(16)][rng.below(3)] = specials[rng.below(specials.len)];
        },
        5 => for (&px) |*p| for (p) |*v| { // plain log noise, either sign
            v.* = std.math.exp2(-20.0 + 36.0 * rng.unit()) * @as(f32, if (rng.below(3) == 0) -1 else 1);
        },
        else => {},
    }
    return px;
}

test "bc6h every mode encoder matches texcomp on fuzz blocks" {
    var rng: images.Rng = .{ .state = 0xbc6f };
    var m: common.Mismatches = .{ .label = "bc6h fuzz" };
    var wins: [2][15]u32 = @splat(@splat(0));
    var tried: [2][15]u32 = @splat(@splat(0));
    const count = 20_000;
    for (0..count) |n| {
        const px = fuzzBlock(&rng);
        for (formats, 0..) |format, fi| {
            const signed = format == .signed;
            for (0..14) |mode_usize| {
                const mode: u4 = @intCast(mode_usize);
                var want: [16]u8 = undefined;
                var got: [16]u8 = undefined;
                var want_err: u64 = undefined;
                const have = ref_bc6h_mode(@intFromBool(signed), mode, &px, &want, &want_err) != 0;
                const got_err = bcn.bc6h.texcomp.encodeMode(signed, mode, &px, &got);
                if (have != (got_err != null)) return error.ModeSetDiffers;
                const ge = got_err orelse continue;
                const label = if (signed) "sf16 mode" else "uf16 mode";
                m.check(label, mode, @intCast(n), px, std.mem.asBytes(&want_err), std.mem.asBytes(&ge));
                if (want_err != bcn.bc6h.texcomp.err_unencodable) {
                    tried[fi][mode] += 1;
                    m.check(label, mode, @intCast(n), px, &want, &got);
                }
            }
            var want: [16]u8 = undefined;
            ref_bc6h_block(@intFromBool(signed), &px, &want);
            const got = bcn.bc6h.encodeBlock(&px, format);
            m.check(if (signed) "sf16 block" else "uf16 block", 0, @intCast(n), px, &want, &got);
            wins[fi][modeOf(&want)] += 1;
        }
    }
    if (print_stats) std.debug.print("\nfuzz encodable (uf16): {any}\nfuzz encodable (sf16): {any}\nfuzz wins (uf16): {any}\nfuzz wins (sf16): {any}\n", .{ tried[0], tried[1], wins[0], wins[1] });
    try m.finish();
}

extern fn tc_float_to_half_bits(f: f32) u16;
extern fn tc_bc6h_compressed_size(width: u32, height: u32) usize;

test "bc6h float to half matches texcomp on all 2^32 floats" {
    const slices = 64;
    const Worker = struct {
        fn run(slice: u32, mismatches: *std.atomic.Value(u32)) void {
            const span: u64 = (1 << 32) / slices;
            var bits: u64 = slice * span;
            while (bits < (slice + 1) * span) : (bits += 1) {
                const f: f32 = @bitCast(@as(u32, @intCast(bits)));
                if (tc_float_to_half_bits(f) != bcn.bc6h.floatToHalfBits(f)) {
                    if (mismatches.fetchAdd(1, .monotonic) < common.max_reported)
                        std.debug.print("float to half differs at 0x{x:0>8}\n", .{bits});
                }
            }
        }
    };
    var mismatches: std.atomic.Value(u32) = .init(0);
    var threads: [slices]std.Thread = undefined;
    for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, Worker.run, .{ @as(u32, @intCast(i)), &mismatches });
    for (threads) |t| t.join();
    try std.testing.expectEqual(@as(u32, 0), mismatches.load(.monotonic));
}

test "bc6h compressed size matches texcomp" {
    for (1..70) |w| for (1..70) |h| {
        try std.testing.expectEqual(tc_bc6h_compressed_size(@intCast(w), @intCast(h)), bcn.encodedLen(16, @intCast(w), @intCast(h)));
    };
    // texcomp answers 0 for an empty image; zig-bcn asserts sizes are positive.
    try std.testing.expectEqual(@as(usize, 0), tc_bc6h_compressed_size(0, 5));
}

test "bc6h encodes and decodes padded rows like texcomp" {
    // A 13x9 window of the gradient image, read with its full row stride,
    // and decoded into rows padded by 5 texels.
    const img = images.hdr(1);
    const w = 13;
    const h = 9;
    const floats: []const f32 = @as([*]const f32, @ptrCast(&img.pixels))[0 .. images.pixel_count * 3];
    const src: bcn.Image(f32) = .{ .pixels = floats, .width = w, .height = h, .stride = images.width * 3, .channels = 3 };
    for (formats) |format| {
        var want: [bcn.encodedLen(16, w, h)]u8 = undefined;
        var got: [want.len]u8 = undefined;
        var opt: TcOptions = .{ .signed_float = @intFromBool(format == .signed), .reserved = 0 };
        try std.testing.expectEqual(@as(c_int, 0), tc_bc6h_compress_rgb32f(floats.ptr, w, h, images.width * 3 * 4, &opt, &want, want.len));
        bcn.bc6h.encodeImage(src, &got, format);
        try std.testing.expectEqualSlices(u8, &want, &got);

        const row = (w + 5) * 3;
        var want_h: [row * h]u16 = @splat(0);
        var got_h: [row * h]u16 = @splat(0);
        try std.testing.expectEqual(@as(c_int, 0), tc_bc6h_decompress_rgb16f(&want, w, h, opt.signed_float, row * 2, &want_h, want_h.len * 2));
        bcn.bc6h.decodeImage(&got, .{ .pixels = &got_h, .width = w, .height = h, .stride = row, .channels = 3 }, format);
        try std.testing.expectEqualSlices(u16, &want_h, &got_h);

        const row_f = (w + 5) * 4;
        var want_f: [row_f * h]f32 = @splat(0);
        var got_f: [row_f * h]f32 = @splat(0);
        try std.testing.expectEqual(@as(c_int, 0), tc_bc6h_decompress_rgbaf(&want, w, h, opt.signed_float, row_f * 4, &want_f, want_f.len * 4));
        bcn.bc6h.decodeImageF32(&got, .{ .pixels = &got_f, .width = w, .height = h, .stride = row_f, .channels = 4 }, format);
        try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&want_f), std.mem.sliceAsBytes(&got_f));
    }
}

/// Blocks found by coverage-guided fuzzing (libFuzzer) of texcomp's BC6H
/// encoder, minimized to those that each reach a new edge. Each record is a
/// kind byte, then 48 half-float bit patterns (kind 0) or 48 f32 bit patterns
/// (kind 1), RGB row-major, little-endian.
const corpus = @embedFile("bc6h_corpus.bin");

fn corpusBlock(at: *usize) ?[16][3]f32 {
    if (at.* >= corpus.len) return null;
    var px: [16][3]f32 = undefined;
    const kind = corpus[at.*];
    at.* += 1;
    for (0..48) |i| {
        px[i / 3][i % 3] = switch (kind) {
            0 => bcn.bc6h.halfToF32(std.mem.readInt(u16, corpus[at.* + 2 * i ..][0..2], .little)),
            1 => @bitCast(std.mem.readInt(u32, corpus[at.* + 4 * i ..][0..4], .little)),
            else => unreachable,
        };
    }
    at.* += if (kind == 0) 96 else 192;
    return px;
}

test "bc6h every mode encoder matches texcomp on the fuzzing corpus" {
    defer tc_backend_force_mask(0xffffffff);
    var m: common.Mismatches = .{ .label = "bc6h corpus" };
    for ([_]u32{ 0xffffffff, 0, 1 | 2 }) |mask| {
        tc_backend_force_mask(mask);
        var at: usize = 0;
        var n: u32 = 0;
        while (corpusBlock(&at)) |px| : (n += 1) {
            for (formats) |format| {
                const signed = format == .signed;
                var want: [16]u8 = undefined;
                ref_bc6h_block(@intFromBool(signed), &px, &want);
                m.check(if (signed) "sf16 block" else "uf16 block", 0, n, px, &want, &bcn.bc6h.encodeBlock(&px, format));
                for (0..14) |mode_usize| {
                    const mode: u4 = @intCast(mode_usize);
                    var got: [16]u8 = undefined;
                    var want_err: u64 = undefined;
                    const have = ref_bc6h_mode(@intFromBool(signed), mode, &px, &want, &want_err) != 0;
                    const got_err = bcn.bc6h.texcomp.encodeMode(signed, mode, &px, &got);
                    if (have != (got_err != null)) return error.ModeSetDiffers;
                    const ge = got_err orelse continue;
                    m.check("mode error", mode, n, px, std.mem.asBytes(&want_err), std.mem.asBytes(&ge));
                    if (want_err != bcn.bc6h.texcomp.err_unencodable) m.check("mode block", mode, n, px, &want, &got);
                }
            }
        }
    }
    try m.finish();
}
