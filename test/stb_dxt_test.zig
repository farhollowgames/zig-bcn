//! BC1, BC3, BC4 and BC5 against stb_dxt (encoders) and texcomp (decoders).

const std = @import("std");
const bcn = @import("bcn");
const images = @import("images.zig");
const common = @import("common.zig");

extern fn stb_compress_dxt_block(dest: [*]u8, src: [*]const u8, alpha: c_int, mode: c_int) void;
extern fn stb_compress_bc4_block(dest: [*]u8, src: [*]const u8) void;
extern fn stb_compress_bc5_block(dest: [*]u8, src: [*]const u8) void;
extern fn stb_compress_dxt_block_bias(dest: [*]u8, src: [*]const u8, alpha: c_int, mode: c_int) void;
extern fn stb_compress_bc4_block_bias(dest: [*]u8, src: [*]const u8) void;
extern fn stb_compress_bc5_block_bias(dest: [*]u8, src: [*]const u8) void;
extern fn tc_decode_bc1_color_block(in: [*]const u8, dxt1: c_int, px: *[16][4]u8) void;
extern fn tc_decode_bc4_block(in: [*]const u8, v: *[16]u8) void;

const all_settings = [_]bcn.bc1.Settings{
    .{ .quality = .normal, .rounding = .spec },
    .{ .quality = .high, .rounding = .spec },
    .{ .quality = .normal, .rounding = .biased },
    .{ .quality = .high, .rounding = .biased },
};

fn settingsName(comptime format: []const u8, s: bcn.bc1.Settings) []const u8 {
    return switch (s.rounding) {
        .spec => if (s.quality == .normal) format ++ " normal" else format ++ " high",
        .biased => if (s.quality == .normal) format ++ " normal biased" else format ++ " high biased",
    };
}

/// stb_dxt's mode flags; mode 1 (dither) is deprecated and does nothing, but
/// passing it checks that.
fn stbModes(q: bcn.bc1.Quality) [2]c_int {
    return switch (q) {
        .normal => .{ 0, 1 },
        .high => .{ 2, 3 },
    };
}

fn stbDxt(dest: [*]u8, src: [*]const u8, alpha: c_int, mode: c_int, rounding: bcn.bc1.Rounding) void {
    switch (rounding) {
        .spec => stb_compress_dxt_block(dest, src, alpha, mode),
        .biased => stb_compress_dxt_block_bias(dest, src, alpha, mode),
    }
}

test "bc1 and bc3 encode like stb_dxt" {
    var zig_bc1: [bcn.encodedLen(8, images.width, images.height)]u8 = undefined;
    var zig_bc3: [bcn.encodedLen(16, images.width, images.height)]u8 = undefined;
    for (0..images.ldr_names.len) |index| {
        const img = images.ldr(index);
        const view = common.ldrView(&img);
        for (all_settings) |settings| {
            var m1: common.Mismatches = .{ .label = img.name };
            var m3: common.Mismatches = .{ .label = img.name };
            bcn.bc1.encodeImage(view, &zig_bc1, settings);
            bcn.bc3.encodeImage(view, &zig_bc3, settings);
            for (0..common.blocks_high) |by| for (0..common.blocks_wide) |bx| {
                const bi = by * common.blocks_wide + bx;
                var px = view.block(4, @intCast(bx), @intCast(by));

                for (stbModes(settings.quality)) |mode| {
                    var want3: [16]u8 = undefined;
                    stbDxt(&want3, @ptrCast(&px), 1, mode, settings.rounding);
                    m3.check(settingsName("bc3", settings), @intCast(bx), @intCast(by), px, &want3, zig_bc3[bi * 16 ..][0..16]);
                }

                // stb_dxt wants a constant alpha for BC1; the port forces it opaque.
                for (&px) |*p| p[3] = 255;
                for (stbModes(settings.quality)) |mode| {
                    var want1: [8]u8 = undefined;
                    stbDxt(&want1, @ptrCast(&px), 0, mode, settings.rounding);
                    m1.check(settingsName("bc1", settings), @intCast(bx), @intCast(by), px, &want1, zig_bc1[bi * 8 ..][0..8]);
                }
            };
            try m1.finish();
            try m3.finish();
        }
    }
}

test "bc4 and bc5 encode like stb_dxt" {
    var zig_bc4: [bcn.encodedLen(8, images.width, images.height)]u8 = undefined;
    var zig_bc5: [bcn.encodedLen(16, images.width, images.height)]u8 = undefined;
    for (0..images.ldr_names.len) |index| {
        const img = images.ldr(index);
        const full = common.ldrView(&img);
        var m: common.Mismatches = .{ .label = img.name };
        // Every channel as BC4 and both channel pairs as BC5, by rotating
        // channel `ch` to the front.
        for (0..4) |ch| {
            var rotated: [images.pixel_count][4]u8 = undefined;
            for (&rotated, img.pixels) |*r, p| r.* = .{ p[ch], p[(ch + 1) % 4], p[(ch + 2) % 4], p[(ch + 3) % 4] };
            const view = bcn.Image(u8).init(std.mem.sliceAsBytes(&rotated), images.width, images.height, 4);
            bcn.bc4.encodeImage(view, &zig_bc4);
            if (ch % 2 == 0) bcn.bc5.encodeImage(view, &zig_bc5);
            for (0..common.blocks_high) |by| for (0..common.blocks_wide) |bx| {
                const bi = by * common.blocks_wide + bx;
                const px = full.block(4, @intCast(bx), @intCast(by));
                var r: [16]u8 = undefined;
                for (px, &r) |p, *v| v.* = p[ch];
                var want4: [8]u8 = undefined;
                stb_compress_bc4_block(&want4, &r);
                var want4_bias: [8]u8 = undefined;
                stb_compress_bc4_block_bias(&want4_bias, &r);
                m.check("bc4 biased build", @intCast(bx), @intCast(by), r, &want4_bias, &want4);
                m.check(([_][]const u8{ "bc4 r", "bc4 g", "bc4 b", "bc4 a" })[ch], @intCast(bx), @intCast(by), r, &want4, zig_bc4[bi * 8 ..][0..8]);
                if (ch % 2 == 0) {
                    var rg: [16][2]u8 = undefined;
                    for (px, &rg) |p, *v| v.* = .{ p[ch], p[ch + 1] };
                    var want5: [16]u8 = undefined;
                    stb_compress_bc5_block(&want5, @ptrCast(&rg));
                    var want5_bias: [16]u8 = undefined;
                    stb_compress_bc5_block_bias(&want5_bias, @ptrCast(&rg));
                    m.check("bc5 biased build", @intCast(bx), @intCast(by), rg, &want5_bias, &want5);
                    m.check("bc5", @intCast(bx), @intCast(by), rg, &want5, zig_bc5[bi * 16 ..][0..16]);
                }
            };
        }
        try m.finish();
    }
}

test "bc1, bc3 and bc4 decode like texcomp" {
    var rng: images.Rng = .{ .state = 42 };
    var m: common.Mismatches = .{ .label = "decode" };
    for (0..20000) |i| {
        // Random bytes reach every mode, including BC1's 3-colour mode.
        var block: [8]u8 = undefined;
        for (&block) |*b| b.* = rng.byte();
        if (i % 4 == 0) block[2..4].* = block[0..2].*;

        var want: [16][4]u8 = undefined;
        tc_decode_bc1_color_block(&block, 1, &want);
        m.check("bc1", @intCast(i), 0, block, std.mem.asBytes(&want), std.mem.asBytes(&bcn.bc1.decodeBlock(&block)));

        tc_decode_bc1_color_block(&block, 0, &want);
        const bc3_block = block ++ block;
        const got3 = bcn.bc3.decodeBlock(&bc3_block);
        var want_alpha: [16]u8 = undefined;
        tc_decode_bc4_block(&block, &want_alpha);
        for (&want, want_alpha) |*p, a| p[3] = a;
        m.check("bc3", @intCast(i), 0, block, std.mem.asBytes(&want), std.mem.asBytes(&got3));

        m.check("bc4", @intCast(i), 0, block, &want_alpha, &bcn.bc4.decodeBlock(&block));
    }
    try m.finish();
}

test "decoders round-trip the image set within the format error" {
    var encoded: [bcn.encodedLen(16, images.width, images.height)]u8 = undefined;
    var decoded: [images.pixel_count][4]u8 = undefined;
    for (0..images.ldr_names.len) |index| {
        const img = images.ldr(index);
        const view = common.ldrView(&img);
        const out = bcn.ImageMut(u8).init(std.mem.sliceAsBytes(&decoded), images.width, images.height, 4);

        bcn.bc3.encodeImage(view, &encoded, .{ .quality = .high });
        bcn.bc3.decodeImage(&encoded, out);
        try expectRmse(img.name, "bc3", &img.pixels, &decoded, 4, bc3_rmse_max[index]);

        bcn.bc5.encodeImage(view, &encoded);
        bcn.bc5.decodeImage(&encoded, out);
        try expectRmse(img.name, "bc5", &img.pixels, &decoded, 2, bc5_rmse_max[index]);
    }
}

// Root mean square error bounds per image (in ldr_names order), measured on
// the first port with about 10 percent headroom: a broken decoder or a
// quality regression lands far outside them. Noise and random extremes are
// high because BC1 cannot represent them.
const bc3_rmse_max = [_]f64{ 1, 3.5, 21, 3, 48, 7.5, 7, 2.2, 23, 1.5, 83, 2, 3, 25 };
const bc5_rmse_max = [_]f64{ 0.5, 1, 7, 1, 9.5, 2.6, 2.5, 0.5, 3.8, 0.5, 1, 1, 1, 0.5 };

fn expectRmse(name: []const u8, what: []const u8, want: *const [images.pixel_count][4]u8, got: *const [images.pixel_count][4]u8, channels: usize, bound: f64) !void {
    var sum: f64 = 0;
    for (want, got) |w, g| for (0..channels) |c| {
        const d = @as(f64, @floatFromInt(w[c])) - @as(f64, @floatFromInt(g[c]));
        sum += d * d;
    };
    const rmse = @sqrt(sum / @as(f64, @floatFromInt(images.pixel_count * channels)));
    if (rmse > bound) {
        std.debug.print("{s} {s}: rmse {d:.2} over {d:.2}\n", .{ name, what, rmse, bound });
        return error.RoundTrip;
    }
}
comptime { std.debug.assert(bc3_rmse_max.len == images.ldr_names.len and bc5_rmse_max.len == images.ldr_names.len); }

test "bc1 encodes an RGB image like the same pixels made opaque RGBA" {
    var rgb: [images.pixel_count][3]u8 = undefined;
    var rgba_bc1: [bcn.encodedLen(8, images.width, images.height)]u8 = undefined;
    var rgb_bc1: [bcn.encodedLen(8, images.width, images.height)]u8 = undefined;
    for (0..images.ldr_names.len) |index| {
        const img = images.ldr(index);
        for (&rgb, img.pixels) |*d, p| d.* = p[0..3].*;
        const rgb_view = bcn.Image(u8).init(std.mem.sliceAsBytes(&rgb), images.width, images.height, 3);
        for (all_settings) |settings| {
            bcn.bc1.encodeImage(common.ldrView(&img), &rgba_bc1, settings);
            bcn.bc1.encodeImage(rgb_view, &rgb_bc1, settings);
            try std.testing.expectEqualSlices(u8, &rgba_bc1, &rgb_bc1);
        }
    }
}

extern fn tc_bc1_decompress_rgba8(bc1: [*]const u8, width: u32, height: u32, stride: usize, out: [*]u8, out_size: usize) c_int;
extern fn tc_bc3_decompress_rgba8(bc3: [*]const u8, width: u32, height: u32, stride: usize, out: [*]u8, out_size: usize) c_int;
extern fn tc_bc5_decompress_rgba8(bc5: [*]const u8, width: u32, height: u32, snorm: c_int, stride: usize, out: [*]u8, out_size: usize) c_int;

test "image decoders match texcomp, with clipping and a wide stride" {
    const sizes = [_][2]u32{ .{ 1, 1 }, .{ 3, 5 }, .{ 4, 4 }, .{ 13, 7 }, .{ images.width, images.height } };
    var rng: images.Rng = .{ .state = 7 };
    var data: [bcn.encodedLen(16, images.width, images.height)]u8 = undefined;
    var want: [images.pixel_count * 4 + 64 * images.height]u8 = undefined;
    var got: [images.pixel_count * 4 + 64 * images.height]u8 = undefined;
    for (sizes) |size| {
        const w = size[0];
        const h = size[1];
        const stride = w * 4 + 12;
        const len = (h - 1) * stride + w * 4;
        for (&data) |*b| b.* = rng.byte();
        // Starting both buffers from the same bytes shows the decoders leave
        // pixels outside the image, and the padding, alone.
        for (want[0..len], got[0..len]) |*a, *b| {
            a.* = rng.byte();
            b.* = a.*;
        }
        const out: bcn.ImageMut(u8) = .{ .pixels = got[0..len], .width = w, .height = h, .stride = stride, .channels = 4 };

        try std.testing.expectEqual(@as(c_int, 0), tc_bc1_decompress_rgba8(&data, w, h, stride, &want, len));
        bcn.bc1.decodeImage(&data, out);
        try std.testing.expectEqualSlices(u8, want[0..len], got[0..len]);

        try std.testing.expectEqual(@as(c_int, 0), tc_bc3_decompress_rgba8(&data, w, h, stride, &want, len));
        bcn.bc3.decodeImage(&data, out);
        try std.testing.expectEqualSlices(u8, want[0..len], got[0..len]);

        // texcomp writes B = 0 and A = 255 for BC5; the port writes only R and G.
        try std.testing.expectEqual(@as(c_int, 0), tc_bc5_decompress_rgba8(&data, w, h, 0, stride, &want, len));
        for (0..h) |y| for (0..w) |x| {
            const at = y * stride + x * 4;
            got[at + 2] = 0;
            got[at + 3] = 255;
        };
        bcn.bc5.decodeImage(&data, out);
        try std.testing.expectEqualSlices(u8, want[0..len], got[0..len]);

        // BC4 has no texcomp image decoder; compare with its block decoder.
        const one: bcn.ImageMut(u8) = .{ .pixels = got[0..len], .width = w, .height = h, .stride = stride, .channels = 4 };
        bcn.bc4.decodeImage(&data, one);
        for (0..h) |y| for (0..w) |x| {
            const block = data[((y / 4) * bcn.image.blocksWide(w) + x / 4) * 8 ..][0..8];
            var values: [16]u8 = undefined;
            tc_decode_bc4_block(block, &values);
            try std.testing.expectEqual(values[(y % 4) * 4 + x % 4], got[y * stride + x * 4]);
        };
    }
}

/// Random blocks from several distributions, for the paths whole images
/// rarely reach: near-constant blocks whose refinement collapses both
/// endpoints, two-value blocks, and extremes.
fn craftedBlock(rng: *images.Rng, kind: u32) [16][4]u8 {
    var px: [16][4]u8 = undefined;
    const base: [4]u8 = .{ rng.byte(), rng.byte(), rng.byte(), rng.byte() };
    for (&px) |*p| {
        for (p, base) |*c, b| c.* = switch (kind) {
            // within one or two steps of a base colour
            0 => b +| (rng.byte() % 3),
            // one of two nearby values
            1 => if (rng.below(2) == 0) b else b +| 1,
            // one of two arbitrary values per channel
            2 => if (rng.below(2) == 0) b else b ^ 0x80,
            // extremes
            3 => if (rng.below(2) == 0) 0 else 255,
            // anything
            else => rng.byte(),
        };
    }
    return px;
}

test "crafted blocks encode like stb_dxt" {
    var rng: images.Rng = .{ .state = 0x5eed };
    var m: common.Mismatches = .{ .label = "crafted" };
    for (0..200_000) |i| {
        var px = craftedBlock(&rng, @intCast(i % 5));
        for (all_settings) |settings| {
            var want3: [16]u8 = undefined;
            stbDxt(&want3, @ptrCast(&px), 1, stbModes(settings.quality)[0], settings.rounding);
            m.check(settingsName("bc3", settings), @intCast(i), 0, px, &want3, &bcn.bc3.encodeBlock(&px, settings));
        }
        var r: [16]u8 = undefined;
        var rg: [16][2]u8 = undefined;
        for (px, &r, &rg) |p, *v, *v2| {
            v.* = p[0];
            v2.* = .{ p[1], p[2] };
        }
        var want4: [8]u8 = undefined;
        stb_compress_bc4_block(&want4, &r);
        m.check("bc4", @intCast(i), 0, r, &want4, &bcn.bc4.encodeBlock(&r));
        var want5: [16]u8 = undefined;
        stb_compress_bc5_block(&want5, @ptrCast(&rg));
        m.check("bc5", @intCast(i), 0, rg, &want5, &bcn.bc5.encodeBlock(&rg));

        for (&px) |*p| p[3] = 255;
        for (all_settings) |settings| {
            var want1: [8]u8 = undefined;
            stbDxt(&want1, @ptrCast(&px), 0, stbModes(settings.quality)[0], settings.rounding);
            m.check(settingsName("bc1", settings), @intCast(i), 0, px, &want1, &bcn.bc1.encodeBlock(&px, settings));
        }
    }
    try m.finish();
}
