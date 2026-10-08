//! The high-quality BC6H encoder (`bc6h.Quality.high`). It is zig-bcn's
//! own, so there is no original to match byte for byte; these tests prove
//! instead that every block it writes decodes, in texcomp's decoder and
//! zig-bcn's, to exactly the error it reports, that the error is never
//! worse than texcomp's block, and that it keeps what texcomp loses.

const std = @import("std");
const bcn = @import("bcn");
const images = @import("images.zig");
const common = @import("common.zig");
const bc6h_test = @import("bc6h_test.zig");

const high = bcn.bc6h.high;
const Format = bcn.bc6h.Format;
const formats = [_]Format{ .unsigned, .signed };
const encoded_len = bcn.encodedLen(16, images.width, images.height);

extern fn tc_bc6h_decode_block_half(blk: *const [16]u8, is_signed: c_int, out: *[16][3]u16) void;

/// Prints measured errors, for setting the bounds below; off so test
/// output stays quiet.
const print_stats = false;

/// Encodes `px` at both qualities and checks the high block against both
/// decoders, its reported error and the fast block.
fn checkBlock(px: *const [16][3]f32, format: Format) !void {
    const enc = high.encodeBlock(px, format);
    const t = high.targets(px, format);

    const ours = bcn.bc6h.decodeBlock(&enc.block, format);
    var theirs: [16][3]u16 = undefined;
    tc_bc6h_decode_block_half(&enc.block, @intFromBool(format == .signed), &theirs);
    try std.testing.expectEqual(ours, theirs);
    try std.testing.expectEqual(enc.err, high.decodedError(&ours, &t, format));

    const fast = bcn.bc6h.encodeBlock(px, format);
    const fast_err = high.decodedError(&bcn.bc6h.decodeBlock(&fast, format), &t, format);
    try std.testing.expect(enc.err <= fast_err);

    // Same input, same bytes.
    try std.testing.expectEqual(enc.block, high.encodeBlock(px, format).block);
}

test "bc6h high blocks decode to their reported error and never lose to fast, on the image set" {
    for (0..images.hdr_names.len) |index| {
        const img = images.hdr(index);
        const v = bc6h_test.view(&img);
        for (formats) |format| {
            for (0..common.blocks_high) |by| for (0..common.blocks_wide) |bx| {
                const px = v.block(3, @intCast(bx), @intCast(by));
                checkBlock(&px, format) catch |err| {
                    std.debug.print("{s} {t}: block ({d}, {d})\n", .{ img.name, format, bx, by });
                    return err;
                };
            };
        }
    }
}

test "bc6h high blocks decode to their reported error and never lose to fast, on fuzz blocks and the corpus" {
    var rng: images.Rng = .{ .state = 0xb6 };
    for (0..4000) |i| {
        const px = bc6h_test.fuzzBlock(&rng);
        for (formats) |format| checkBlock(&px, format) catch |err| {
            std.debug.print("fuzz block {d} {t}: {any}\n", .{ i, format, px });
            return err;
        };
    }
    var at: usize = 0;
    var n: u32 = 0;
    while (bc6h_test.corpusBlock(&at)) |px| : (n += 1) {
        for (formats) |format| checkBlock(&px, format) catch |err| {
            std.debug.print("corpus block {d} {t}: {any}\n", .{ n, format, px });
            return err;
        };
    }
}

test "bc6h high stores every flat colour exactly" {
    for (formats) |format| {
        for (0..0x10000) |code| {
            const h: u16 = @intCast(code);
            if (h & 0x7fff > 0x7bff) continue; // infinities and NaN
            if (format == .unsigned and h & 0x8000 != 0) continue;
            const px: [16][3]f32 = @splat(@splat(bcn.bc6h.halfToF32(h)));
            const enc = high.encodeBlock(&px, format);
            try std.testing.expectEqual(@as(u64, 0), enc.err);
            const want = high.halfValue(h, format);
            for (bcn.bc6h.decodeBlock(&enc.block, format)) |p| {
                for (p) |got| try std.testing.expectEqual(want, high.halfValue(got, format));
            }
        }
    }
}

test "bc6h high packs every mode's fields the way the decoder reads them" {
    var rng: images.Rng = .{ .state = 0xfe1d };
    for (0..14) |m| {
        const mode = bcn.bc6h.modes[m];
        for (0..2000) |_| {
            var fields: high.Fields = .{ .mode = @intCast(m) };
            if (mode.regions == 2) fields.partition = @intCast(rng.below(32));
            const count: usize = @as(usize, mode.regions) * 2;
            for (0..count) |e| for (0..3) |c| {
                const bits: u5 = if (e == 0 or !mode.transformed) mode.base_bits else mode.delta_bits[c];
                fields.stored[e][c] = @intCast(rng.next() & ((@as(u64, 1) << bits) - 1));
            };
            const index_count: u32 = if (mode.regions == 1) 16 else 8;
            for (&fields.indices, 0..) |*index, i| {
                const limit = if (high.isAnchor(mode.regions, fields.partition, i)) index_count / 2 else index_count;
                index.* = @intCast(rng.below(limit));
            }
            const block = high.pack(&fields);
            for (formats) |format| {
                try std.testing.expectEqual(high.decodeFields(&fields, format), bcn.bc6h.decodeBlock(&block, format));
            }
        }
    }
}

test "bc6h high float to half is IEEE round to nearest even on all 2^32 floats" {
    var bits: u32 = 0;
    while (true) : (bits += 1) {
        const x: f32 = @bitCast(bits);
        const got = high.floatToHalfRne(x);
        if (std.math.isNan(x)) {
            try std.testing.expect(got & 0x7c00 == 0x7c00 and got & 0x3ff != 0);
        } else {
            const want: u16 = @bitCast(@as(f16, @floatCast(x)));
            if (want != got) {
                std.debug.print("float to half differs at 0x{x:0>8}: want 0x{x:0>4}, got 0x{x:0>4}\n", .{ bits, want, got });
                return error.Mismatch;
            }
        }
        if (bits == std.math.maxInt(u32)) break;
    }
}

test "bc6h high improves on fast over the image set and stays within its bounds" {
    var encoded: [encoded_len]u8 = undefined;
    var decoded: [images.pixel_count][3]u16 = undefined;
    for (0..images.hdr_names.len) |index| {
        const img = images.hdr(index);
        for (formats, 0..) |format, fi| {
            const out = bcn.ImageMut(u16).init(@as([*]u16, @ptrCast(&decoded))[0 .. images.pixel_count * 3], images.width, images.height, 3);
            bcn.bc6h.encodeImageQuality(bc6h_test.view(&img), &encoded, format, .fast);
            bcn.bc6h.decodeImage(&encoded, out, format);
            const fast_err = bc6h_test.logRmse(&img, &decoded, format);
            bcn.bc6h.encodeImageQuality(bc6h_test.view(&img), &encoded, format, .high);
            bcn.bc6h.decodeImage(&encoded, out, format);
            const high_err = bc6h_test.logRmse(&img, &decoded, format);
            if (print_stats) std.debug.print("{s} {t}: log rmse fast {d:.5} high {d:.5}\n", .{ img.name, format, fast_err, high_err });
            if (high_err * improvement_min[index] > fast_err) {
                std.debug.print("{s} {t}: high {d:.5} is not {d}x better than fast {d:.5}\n", .{ img.name, format, high_err, improvement_min[index], fast_err });
                return error.NoImprovement;
            }
            const bound = if (fi == 0) uf16_rmse_max[index] else sf16_rmse_max[index];
            if (high_err > bound) {
                std.debug.print("{s} {t}: log rmse {d:.5} over {d:.5}\n", .{ img.name, format, high_err, bound });
                return error.RoundTrip;
            }
        }
    }
}

// Bounds per HDR image (in hdr_names order) on the RMSE of
// sign(x) * log2(1 + |x|), measured on the first version with about 10
// percent headroom. Compare test/bc6h_test.zig's bounds for `.fast`.
const uf16_rmse_max = [_]f64{ 0.00003, 0.0395, 2.78, 0.0024, 1.97, 3.29, 0.000035, 0.0135 };
const sf16_rmse_max = [_]f64{ 0.00003, 0.0395, 2.78, 0.003, 3.69, 5.45, 0.000045, 0.0172 };

/// How much smaller `.high`'s error must be than `.fast`'s on the images it
/// was written for: flat ranges, the sun disc on a flat sky, and smooth
/// gradients. 1 elsewhere: never worse.
const improvement_min = [_]f64{ 100, 1.6, 1, 2, 1, 1, 1, 1 };

comptime {
    std.debug.assert(uf16_rmse_max.len == images.hdr_names.len and sf16_rmse_max.len == images.hdr_names.len);
    std.debug.assert(improvement_min.len == images.hdr_names.len);
}

test "bc6h high keeps the half subnormal range, which fast flushes to zero" {
    for (formats) |format| {
        // A gradient over the subnormals, 2^-24 to 2^-14, as dark HDR has.
        var px: [16][3]f32 = undefined;
        for (&px, 0..) |*p, i| {
            const v = std.math.ldexp(@as(f32, @floatFromInt(i * 60 + 3)), -24);
            p.* = .{ v, v * 0.5, if (format == .signed) -v else v };
        }
        const t = high.targets(&px, format);
        const enc = high.encodeBlock(&px, format);
        const fast = bcn.bc6h.encodeBlock(&px, format);
        const fast_err = high.decodedError(&bcn.bc6h.decodeBlock(&fast, format), &t, format);
        if (print_stats) std.debug.print("subnormal {t}: high {d} fast {d}\n", .{ format, enc.err, fast_err });
        try std.testing.expect(enc.err * 100 < fast_err);
        // Nothing is flushed: a few codes of error may round the very
        // smallest texels to zero, but none of 16 codes or more.
        for (bcn.bc6h.decodeBlock(&enc.block, format), t) |p, want| {
            for (p, want) |h, w| {
                if (@abs(w) >= 16) try std.testing.expect(h & 0x7fff != 0);
            }
        }
    }
}
