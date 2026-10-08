//! BC1, BC3, BC4 and BC5 against stb_dxt (encoders) and texcomp (decoders).

const std = @import("std");
const bcn = @import("bcn");
const images = @import("images.zig");
const common = @import("common.zig");

extern fn stb_compress_dxt_block(dest: [*]u8, src: [*]const u8, alpha: c_int, mode: c_int) void;
extern fn stb_compress_bc4_block(dest: [*]u8, src: [*]const u8) void;
extern fn stb_compress_bc5_block(dest: [*]u8, src: [*]const u8) void;
extern fn tc_decode_bc1_color_block(in: [*]const u8, dxt1: c_int, px: *[16][4]u8) void;
extern fn tc_decode_bc4_block(in: [*]const u8, v: *[16]u8) void;

const qualities = [_]bcn.bc1.Quality{ .normal, .high };

fn stbMode(q: bcn.bc1.Quality) c_int {
    return switch (q) {
        .normal => 0,
        .high => 2,
    };
}

test "bc1 and bc3 encode like stb_dxt" {
    var zig_bc1: [bcn.encodedLen(8, images.width, images.height)]u8 = undefined;
    var zig_bc3: [bcn.encodedLen(16, images.width, images.height)]u8 = undefined;
    for (0..images.ldr_names.len) |index| {
        const img = images.ldr(index);
        const view = common.ldrView(&img);
        for (qualities) |q| {
            var m1: common.Mismatches = .{ .label = img.name };
            var m3: common.Mismatches = .{ .label = img.name };
            bcn.bc1.encodeImage(view, &zig_bc1, q);
            bcn.bc3.encodeImage(view, &zig_bc3, q);
            for (0..common.blocks_high) |by| for (0..common.blocks_wide) |bx| {
                const bi = by * common.blocks_wide + bx;
                var px = view.block(4, @intCast(bx), @intCast(by));

                var want3: [16]u8 = undefined;
                stb_compress_dxt_block(&want3, @ptrCast(&px), 1, stbMode(q));
                m3.check(if (q == .normal) "bc3 normal" else "bc3 high", @intCast(bx), @intCast(by), px, &want3, zig_bc3[bi * 16 ..][0..16]);

                // stb_dxt wants a constant alpha for BC1; the port forces it opaque.
                for (&px) |*p| p[3] = 255;
                var want1: [8]u8 = undefined;
                stb_compress_dxt_block(&want1, @ptrCast(&px), 0, stbMode(q));
                m1.check(if (q == .normal) "bc1 normal" else "bc1 high", @intCast(bx), @intCast(by), px, &want1, zig_bc1[bi * 8 ..][0..8]);
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
                m.check(([_][]const u8{ "bc4 r", "bc4 g", "bc4 b", "bc4 a" })[ch], @intCast(bx), @intCast(by), r, &want4, zig_bc4[bi * 8 ..][0..8]);
                if (ch % 2 == 0) {
                    var rg: [16][2]u8 = undefined;
                    for (px, &rg) |p, *v| v.* = .{ p[ch], p[ch + 1] };
                    var want5: [16]u8 = undefined;
                    stb_compress_bc5_block(&want5, @ptrCast(&rg));
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

        bcn.bc3.encodeImage(view, &encoded, .high);
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
