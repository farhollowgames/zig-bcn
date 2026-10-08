//! BC7 against bc7e scalar (encoder) and texcomp (decoder): blocks, used-LUT
//! flags, single-mode errors and decoded pixels, all byte for byte.

const std = @import("std");
const bcn = @import("bcn");
const images = @import("images.zig");
const common = @import("common.zig");

const bc7 = bcn.bc7;
const Params = bc7.Params;

extern fn ref_bc7e_init() void;
extern fn ref_bc7e_params_size() c_uint;
extern fn ref_bc7e_params_init(level: c_uint, perceptual: c_int, out: *anyopaque) void;
extern fn ref_bc7e_compress_blocks(num_blocks: c_uint, blocks: [*]u64, pixels: [*]const u32, params: *const anyopaque, used_lut: ?[*]u8) void;
extern fn ref_bc7e_compress_block_single_mode(block: *[2]u64, pixels: [*]const u32, params: *const anyopaque, mode: c_uint, partition: c_int, rotation: c_uint, index_selector: c_uint) u64;
extern fn tc_bc7_decompress_rgba8(bc7_data: [*]const u8, width: u32, height: u32, stride: usize, out_rgba: [*]u8, out_size: usize) c_int;

const levels = std.enums.values(bc7.Level);

fn refParams(level: bc7.Level, perceptual: bool) Params {
    var p: Params = undefined;
    ref_bc7e_params_init(@intFromEnum(level), @intFromBool(perceptual), &p);
    return p;
}

test "bc7 params initialize like bc7e" {
    try std.testing.expectEqual(@as(c_uint, @sizeOf(Params)), ref_bc7e_params_size());
    for (levels) |level| for ([_]bool{ false, true }) |perceptual| {
        const want = refParams(level, perceptual);
        const got = Params.init(level, perceptual);
        try std.testing.expectEqualSlices(u8, std.mem.asBytes(&want), std.mem.asBytes(&got));
    };
}

/// Encodes `blocks` with both encoders and compares blocks and LUT flags.
fn compareBlocks(label: []const u8, what: []const u8, blocks: []const [16][4]u8, params: *const Params, m: *common.Mismatches) void {
    var want: [4096][2]u64 = undefined;
    var want_lut: [4096]u8 = undefined;
    std.debug.assert(blocks.len <= want.len);
    var words: [4096][16]u32 = undefined;
    for (blocks, 0..) |b, i| words[i] = @bitCast(b);
    ref_bc7e_compress_blocks(@intCast(blocks.len), @ptrCast(&want), @ptrCast(&words), params, &want_lut);
    _ = label;
    for (blocks, 0..) |*px, i| {
        const got = bc7.encodeBlockReportingLut(px, params);
        m.check(what, @intCast(i), 0, px.*, std.mem.asBytes(&want[i]), &got.block);
        m.check("used_lut", @intCast(i), 0, px.*, want_lut[i .. i + 1], &[1]u8{@intFromBool(got.used_lut)});
    }
}

fn imageBlocks(img: *const images.Ldr, out: *[common.blocks_wide * common.blocks_high][16][4]u8) void {
    const view = common.ldrView(img);
    for (0..common.blocks_high) |by| for (0..common.blocks_wide) |bx| {
        out[by * common.blocks_wide + bx] = view.block(4, @intCast(bx), @intCast(by));
    };
}

const level_names = [_][]const u8{ "ultrafast", "veryfast", "fast", "basic", "slow", "veryslow", "slowest" };

test "bc7 encodes the image set like bc7e at every level" {
    ref_bc7e_init();
    var blocks: [common.blocks_wide * common.blocks_high][16][4]u8 = undefined;
    var encoded: [bcn.encodedLen(16, images.width, images.height)]u8 = undefined;
    for (0..images.ldr_names.len) |index| {
        const img = images.ldr(index);
        imageBlocks(&img, &blocks);
        var m: common.Mismatches = .{ .label = img.name };
        for (levels) |level| for ([_]bool{ false, true }) |perceptual| {
            const params = Params.init(level, perceptual);
            compareBlocks(img.name, level_names[@intFromEnum(level)], &blocks, &params, &m);

            // The image path must give the same blocks as the block path.
            bc7.encodeImage(common.ldrView(&img), &encoded, &params);
            var want: [blocks.len][2]u64 = undefined;
            var words: [blocks.len][16]u32 = undefined;
            for (blocks, 0..) |b, i| words[i] = @bitCast(b);
            ref_bc7e_compress_blocks(blocks.len, @ptrCast(&want), @ptrCast(&words), &params, null);
            m.check("encodeImage", 0, 0, @as(u8, 0), std.mem.sliceAsBytes(&want), &encoded);
        };
        try m.finish();
    }
}

/// Blocks shaped to reach paths images rarely do: solid and nearly solid
/// colours, one odd pixel, flat channels, two and three colour partitions,
/// binary and smooth alpha, a single varying channel (rotations), extremes.
fn craftedBlock(rng: *images.Rng, kind: u32) [16][4]u8 {
    var px: [16][4]u8 = undefined;
    const base = [4]u8{ rng.byte(), rng.byte(), rng.byte(), if (rng.below(2) == 0) 255 else rng.byte() };
    switch (kind) {
        0 => px = @splat(base), // solid
        1 => { // solid but one pixel off by one in one channel
            px = @splat(base);
            const i = rng.below(16);
            const c = rng.below(4);
            px[i][c] = if (px[i][c] == 255) 254 else px[i][c] + 1;
        },
        2 => { // gray ramp with constant alpha
            const step = rng.below(4) + 1;
            for (&px, 0..) |*p, i| {
                const v: u8 = @truncate(base[0] +% @as(u8, @intCast(i)) *% @as(u8, @intCast(step)));
                p.* = .{ v, v, v, base[3] };
            }
        },
        3, 4 => { // two or three colours on a partition pattern
            var palette: [3][4]u8 = undefined;
            for (&palette) |*c| c.* = .{ rng.byte(), rng.byte(), rng.byte(), if (rng.below(3) == 0) rng.byte() else 255 };
            const part = rng.below(64);
            const table = if (kind == 3) &bcn.bc7.partition2_table else &bcn.bc7.partition3_table;
            for (&px, 0..) |*p, i| p.* = palette[table[part * 16 + i]];
        },
        5 => { // binary alpha over noise
            for (&px) |*p| p.* = .{ rng.byte(), rng.byte(), rng.byte(), if (rng.below(2) == 0) 0 else 255 };
        },
        6 => { // one channel varies, the others are flat
            const ch = rng.below(4);
            for (&px) |*p| {
                p.* = base;
                p[ch] = rng.byte();
            }
        },
        7 => { // low contrast: within one or two steps
            for (&px) |*p| {
                for (0..4) |c| p[c] = base[c] -| @as(u8, @intCast(rng.below(3)));
            }
        },
        8 => { // extremes
            for (&px) |*p| for (p) |*v| {
                v.* = switch (rng.below(3)) {
                    0 => 0,
                    1 => 255,
                    else => rng.byte(),
                };
            };
        },
        9 => { // smooth gradient with smooth alpha
            const d = [4]i32{ @as(i32, rng.byte()) - 128, @as(i32, rng.byte()) - 128, @as(i32, rng.byte()) - 128, @as(i32, rng.byte()) - 128 };
            for (&px, 0..) |*p, i| {
                const t: i32 = @intCast(i);
                for (0..4) |c| p[c] = @intCast(std.math.clamp(@as(i32, base[c]) + @divTrunc(d[c] * t, 16), 0, 255));
            }
        },
        10 => { // alpha only varies, colour solid
            for (&px) |*p| p.* = .{ base[0], base[1], base[2], rng.byte() };
        },
        11 => { // two alpha levels, colour noise in a narrow range
            const a0 = rng.byte();
            const a1 = rng.byte();
            for (&px) |*p| p.* = .{ base[0] +| @as(u8, @intCast(rng.below(8))), base[1], base[2] -| @as(u8, @intCast(rng.below(8))), if (rng.below(2) == 0) a0 else a1 };
        },
        else => { // noise
            for (&px) |*p| p.* = .{ rng.byte(), rng.byte(), rng.byte(), rng.byte() };
        },
    }
    return px;
}

const crafted_kinds = 13;

fn craftedBlocks(comptime n: usize, seed: u64) [n][16][4]u8 {
    var rng: images.Rng = .{ .state = seed };
    var out: [n][16][4]u8 = undefined;
    for (&out, 0..) |*b, i| b.* = craftedBlock(&rng, @intCast(i % crafted_kinds));
    return out;
}

const Variant = struct { name: []const u8, params: Params };

/// Settings beyond the presets, so every switch of Params is exercised.
fn variants(perceptual: bool) [23]Variant {
    var v: [23]Variant = undefined;
    var n: usize = 0;
    const add = struct {
        fn f(list: *[23]Variant, count: *usize, name: []const u8, p: Params) void {
            list[count.*] = .{ .name = name, .params = p };
            count.* += 1;
        }
    }.f;

    for ([_]bc7.Level{ .basic, .slow, .slowest }) |level| {
        var p = Params.init(level, perceptual);
        p.use_luts = false;
        add(&v, &n, "no luts", p);
    }
    {
        var p = Params.init(.slowest, perceptual);
        p.mode6_only = true;
        add(&v, &n, "mode6 only, slowest", p);
        p = Params.init(.slowest, perceptual);
        p.pbit_search = false;
        add(&v, &n, "slowest without pbit search", p);
        p = Params.init(.fast, perceptual);
        p.pbit_search = true;
        add(&v, &n, "fast with pbit search", p);
    }
    for ([_]u32{ 2, 4, 8 }) |mask| {
        var p = Params.init(.slow, perceptual);
        p.mode4_rotation_mask = mask;
        p.mode5_rotation_mask = mask;
        p.mode4_index_mask = if (mask == 2) 2 else 1;
        add(&v, &n, "rotation and index masks", p);
    }
    for ([_]u32{ 1, 2, 4 }) |mask| {
        var p = Params.init(.slowest, perceptual);
        p.uber1_mask = mask;
        add(&v, &n, "uber1 mask", p);
    }
    for ([_]u32{ 1, 3 }) |uber| {
        var p = Params.init(.veryslow, perceptual);
        p.uber_level = uber;
        add(&v, &n, "uber level", p);
    }
    for ([_]u32{ 0, 2 }) |passes| {
        var p = Params.init(.slow, perceptual);
        p.refinement_passes = passes;
        add(&v, &n, "refinement passes", p);
    }
    {
        var p = Params.init(.slow, perceptual);
        p.weights = .{ 3, 2, 1, 5 };
        p.alpha_settings.mode67_error_weight_mul = .{ 2, 3, 1, 4 };
        add(&v, &n, "custom weights", p);

        p = Params.init(.slowest, perceptual);
        p.opaque_settings.max_mode13_partitions_to_try = 64;
        p.opaque_settings.max_mode0_partitions_to_try = 16;
        p.opaque_settings.max_mode2_partitions_to_try = 3;
        p.alpha_settings.max_mode7_partitions_to_try = 64;
        add(&v, &n, "all partitions", p);

        p = Params.init(.slow, perceptual);
        p.max_partitions_mode = .{ 1, 1, 1, 1, 0, 0, 0, 1 };
        p.opaque_settings.max_mode13_partitions_to_try = 3;
        add(&v, &n, "one partition", p);

        p = Params.init(.slow, perceptual);
        p.alpha_settings.use_mode4_rotation = false;
        p.alpha_settings.use_mode5_rotation = false;
        add(&v, &n, "no alpha rotations", p);

        p = Params.init(.slow, perceptual);
        p.alpha_settings.use_mode4 = false;
        p.alpha_settings.use_mode6 = false;
        p.opaque_settings.use_mode[6] = false;
        p.opaque_settings.use_mode[1] = false;
        add(&v, &n, "without modes 1, 4 and 6", p);

        p = Params.init(.slow, perceptual);
        p.alpha_settings.use_mode5 = false;
        p.alpha_settings.use_mode7 = false;
        p.opaque_settings.use_mode = .{ false, false, false, true, false, false, false };
        add(&v, &n, "mode 3 only, alpha 4 and 6", p);

        p = Params.init(.basic, perceptual);
        p.opaque_settings.use_mode = @splat(false);
        p.alpha_settings = .{ .max_mode7_partitions_to_try = 1, .mode67_error_weight_mul = .{ 1, 1, 1, 1 }, .use_mode4 = false, .use_mode5 = false, .use_mode6 = false, .use_mode7 = false, .use_mode4_rotation = false, .use_mode5_rotation = false };
        add(&v, &n, "no modes", p);
    }
    std.debug.assert(n == v.len);
    return v;
}

test "bc7 encodes crafted blocks like bc7e at every level and setting" {
    ref_bc7e_init();
    const blocks = craftedBlocks(3000, 7);
    var m: common.Mismatches = .{ .label = "crafted" };
    for (levels) |level| for ([_]bool{ false, true }) |perceptual| {
        const params = Params.init(level, perceptual);
        compareBlocks("crafted", level_names[@intFromEnum(level)], &blocks, &params, &m);
    };
    for ([_]bool{ false, true }) |perceptual| {
        for (variants(perceptual)) |variant| compareBlocks("crafted", variant.name, &blocks, &variant.params, &m);
    }
    try m.finish();
}

test "bc7 encodes the image set like bc7e with every setting variant" {
    ref_bc7e_init();
    var all: [images.ldr_names.len * common.blocks_wide * common.blocks_high][16][4]u8 = undefined;
    const per_image = common.blocks_wide * common.blocks_high;
    for (0..images.ldr_names.len) |index| {
        const img = images.ldr(index);
        imageBlocks(&img, all[index * per_image ..][0..per_image]);
    }
    var m: common.Mismatches = .{ .label = "image set" };
    for ([_]bool{ false, true }) |perceptual| {
        for (variants(perceptual)) |variant| compareBlocks("image set", variant.name, &all, &variant.params, &m);
    }
    try m.finish();
}

fn compareSingleMode(px: *const [16][4]u8, params: *const Params, single: bc7.SingleMode, m: *common.Mismatches) void {
    var want: [2]u64 = undefined;
    var words: [16]u32 = @bitCast(px.*);
    const partition: c_int = if (single.partition) |p| p else -1;
    const want_err = ref_bc7e_compress_block_single_mode(&want, &words, params, single.mode, partition, single.rotation, single.index_selector);
    const got = bc7.encodeBlockSingleMode(px, params, single);
    m.check("single mode block", single.mode, @intCast(partition + 1), px.*, std.mem.asBytes(&want), &got.block);
    m.check("single mode error", single.mode, @intCast(partition + 1), px.*, std.mem.asBytes(&want_err), std.mem.asBytes(&got.err));
}

test "bc7 single-mode encoding matches bc7e, errors included" {
    ref_bc7e_init();
    const blocks = craftedBlocks(390, 11);
    var m: common.Mismatches = .{ .label = "single mode" };
    const settings = [_]Params{
        Params.init(.slowest, false), Params.init(.slowest, true),
        Params.init(.basic, false),   Params.init(.ultrafast, true),
        blk: {
            var p = Params.init(.slow, false);
            p.use_luts = false;
            break :blk p;
        },
    };
    for (settings) |params| {
        for (&blocks, 0..) |*px, i| {
            for (0..8) |mode| compareSingleMode(px, &params, .{ .mode = @intCast(mode) }, m: {
                break :m &m;
            });
            for (0..4) |rotation| {
                compareSingleMode(px, &params, .{ .mode = 4, .rotation = @intCast(rotation), .index_selector = @intCast(i & 1) }, &m);
                compareSingleMode(px, &params, .{ .mode = 5, .rotation = @intCast(rotation) }, &m);
            }
            // Every forced partition on a few blocks, one on the rest.
            const partitioned = [_]u3{ 0, 1, 2, 3, 7 };
            for (partitioned) |mode| {
                const count: u32 = if (mode == 0) 16 else 64;
                if (i < 12) {
                    for (0..count) |p| compareSingleMode(px, &params, .{ .mode = mode, .partition = @intCast(p) }, &m);
                } else {
                    compareSingleMode(px, &params, .{ .mode = mode, .partition = @intCast(i % count) }, &m);
                }
            }
        }
    }
    try m.finish();
}

fn tcDecode(block: *const [16]u8) [16][4]u8 {
    var out: [16][4]u8 = undefined;
    const r = tc_bc7_decompress_rgba8(block, 4, 4, 16, @ptrCast(&out), @sizeOf(@TypeOf(out)));
    std.debug.assert(r == 0);
    return out;
}

test "bc7 decodes like texcomp" {
    ref_bc7e_init();
    var m: common.Mismatches = .{ .label = "bc7 decode" };
    var rng: images.Rng = .{ .state = 99 };
    // Random blocks in every mode, and reserved ones.
    for (0..80000) |i| {
        var block: [16]u8 = undefined;
        for (&block) |*b| b.* = rng.byte();
        const mode: u3 = @intCast(i % 8);
        if (i % 97 == 0) {
            block[0] = 0;
        } else {
            const low_bits: u8 = @truncate((@as(u16, 2) << mode) - 1);
            block[0] = (block[0] & ~low_bits) | (@as(u8, 1) << mode);
        }
        m.check("random", @intCast(i), mode, block, std.mem.asBytes(&tcDecode(&block)), std.mem.asBytes(&bc7.decodeBlock(&block)));
    }
    // Encoder output.
    const blocks = craftedBlocks(2000, 5);
    for ([_]bc7.Level{ .ultrafast, .basic, .slowest }) |level| for ([_]bool{ false, true }) |perceptual| {
        const params = Params.init(level, perceptual);
        for (&blocks, 0..) |*px, i| {
            const block = bc7.encodeBlock(px, &params);
            m.check("encoded", @intCast(i), 0, block, std.mem.asBytes(&tcDecode(&block)), std.mem.asBytes(&bc7.decodeBlock(&block)));
        }
    };
    try m.finish();
}

// Root mean square error bounds per image (in ldr_names order) at the basic
// level, measured on the first port with about 10 percent headroom.
const bc7_rmse_max = [_]f64{ 0.1, 1.6, 13.7, 2.4, 46, 3.4, 2.5, 0.4, 11.8, 0.55, 82, 0.4, 1.35, 1.4 };

test "bc7 image decode matches texcomp and round-trips within the format error" {
    ref_bc7e_init();
    var encoded: [bcn.encodedLen(16, images.width, images.height)]u8 = undefined;
    var decoded: [images.pixel_count][4]u8 = undefined;
    var want: [images.pixel_count][4]u8 = undefined;
    var m: common.Mismatches = .{ .label = "bc7 image decode" };
    for (0..images.ldr_names.len) |index| {
        const img = images.ldr(index);
        const params = Params.init(.basic, false);
        bc7.encodeImage(common.ldrView(&img), &encoded, &params);
        bc7.decodeImage(&encoded, bcn.ImageMut(u8).init(std.mem.sliceAsBytes(&decoded), images.width, images.height, 4));
        const r = tc_bc7_decompress_rgba8(&encoded, images.width, images.height, images.width * 4, @ptrCast(&want), @sizeOf(@TypeOf(want)));
        std.debug.assert(r == 0);
        m.check(img.name, 0, 0, @as(u8, 0), std.mem.sliceAsBytes(&want), std.mem.sliceAsBytes(&decoded));

        var sum: f64 = 0;
        for (img.pixels, decoded) |w, g| for (0..4) |c| {
            const d = @as(f64, @floatFromInt(w[c])) - @as(f64, @floatFromInt(g[c]));
            sum += d * d;
        };
        const rmse = @sqrt(sum / @as(f64, @floatFromInt(images.pixel_count * 4)));
        if (rmse > bc7_rmse_max[index]) {
            std.debug.print("{s} bc7: rmse {d:.3} over {d:.2}\n", .{ img.name, rmse, bc7_rmse_max[index] });
            return error.RoundTrip;
        }
    }
    try m.finish();
}

comptime {
    std.debug.assert(bc7_rmse_max.len == images.ldr_names.len);
}
