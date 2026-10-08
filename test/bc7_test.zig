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
