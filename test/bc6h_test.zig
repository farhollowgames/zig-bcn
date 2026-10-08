//! BC6H against texcomp: the encoder under texcomp's SIMD and scalar
//! dispatch, the decoder on encoder output and random blocks, and the round
//! trip error on the HDR image set.

const std = @import("std");
const bcn = @import("bcn");
const images = @import("images.zig");
const common = @import("common.zig");

const TcOptions = extern struct { signed_float: c_int, reserved: c_int };

extern fn tc_bc6h_compress_rgb32f(rgb: [*]const f32, width: u32, height: u32, stride_bytes: usize, opt: *const TcOptions, out: [*]u8, out_size: usize) c_int;
extern fn tc_bc6h_decompress_rgb16f(bc6h: [*]const u8, width: u32, height: u32, is_signed: c_int, stride_bytes: usize, out_rgb: [*]u16, out_size: usize) c_int;
extern fn tc_bc6h_decode_block_half(blk: *const [16]u8, is_signed: c_int, out: *[16][3]u16) void;
extern fn tc_backend_force_mask(mask: u32) void;
extern fn tc_backend_name() [*:0]const u8;

const formats = [_]bcn.bc6h.Format{ .unsigned, .signed };
const encoded_len = bcn.encodedLen(16, images.width, images.height);

fn view(img: *const images.Hdr) bcn.Image(f32) {
    const floats: []const f32 = @as([*]const f32, @ptrCast(&img.pixels))[0 .. images.pixel_count * 3];
    return bcn.Image(f32).init(floats, images.width, images.height, 3);
}

fn referenceEncode(img: *const images.Hdr, format: bcn.bc6h.Format, out: *[encoded_len]u8) !void {
    const opt: TcOptions = .{ .signed_float = @intFromBool(format == .signed), .reserved = 0 };
    const rc = tc_bc6h_compress_rgb32f(@ptrCast(&img.pixels), images.width, images.height, images.width * 3 * @sizeOf(f32), &opt, out, out.len);
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
    };
    var mode_counts: [2][15]u32 = @splat(@splat(0));
    for (dispatches) |d| {
        tc_backend_force_mask(d.mask);
        for (0..images.hdr_names.len) |index| {
            const img = images.hdr(index);
            for (formats, 0..) |format, fi| {
                try referenceEncode(&img, format, &want);
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
    std.debug.print("\nbc6h modes chosen (uf16): {any}\nbc6h modes chosen (sf16): {any}\n", .{ mode_counts[0], mode_counts[1] });
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
            std.debug.print("BC6H RMSE {s} {t} {d:.4}\n", .{ img.name, format, err });
            if (err > bound) {
                std.debug.print("{s} {t}: log rmse {d:.4} over {d:.4}\n", .{ img.name, format, err, bound });
                return error.RoundTrip;
            }
        }
    }
}

// Bounds per HDR image (in hdr_names order) on the RMSE of
// sign(x) * log2(1 + |x|), measured on the first port with about 10 percent
// headroom.
const uf16_rmse_max = [_]f64{ 1, 1, 1, 1, 1, 1, 1, 1 };
const sf16_rmse_max = [_]f64{ 1, 1, 1, 1, 1, 1, 1, 1 };

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
