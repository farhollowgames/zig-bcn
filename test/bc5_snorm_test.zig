//! BC4 and BC5 SNORM decoding against texcomp's signed decoders: signed
//! values from its block decoder, and bytes from its image decoder, byte for
//! byte.

const std = @import("std");
const bcn = @import("bcn");
const images = @import("images.zig");
const common = @import("common.zig");

const TcBc5Options = extern struct { snorm: c_int };

extern fn tc_decode_bc4_block_snorm(in: [*]const u8, v: *[16]i8) void;
extern fn tc_bc5_decompress_rgba8(
    bc5: [*]const u8,
    width: u32,
    height: u32,
    snorm: c_int,
    stride: usize,
    out: [*]u8,
    out_size: usize,
) c_int;
extern fn tc_bc5_compress_rgba8(
    rgba: [*]const u8,
    width: u32,
    height: u32,
    stride: usize,
    opt: *const TcBc5Options,
    out: [*]u8,
    out_size: usize,
) c_int;

const signed: c_int = 1;

/// The index bits of a BC4 half whose pixel i takes palette entry i % 8, or
/// 7 - i % 8 when `reversed`.
fn cyclingIndices(reversed: bool) [6]u8 {
    var bits: u48 = 0;
    for (0..16) |i| {
        const entry: u48 = @intCast(if (reversed) 7 - i % 8 else i % 8);
        bits |= entry << @intCast(3 * i);
    }
    var bytes: [6]u8 = undefined;
    std.mem.writeInt(u48, &bytes, bits, .little);
    return bytes;
}

/// texcomp's block decoder on both halves, as red and green pairs.
fn tcDecodeBlock(block: *const [16]u8) [16][2]i8 {
    var r: [16]i8 = undefined;
    var g: [16]i8 = undefined;
    tc_decode_bc4_block_snorm(block[0..8], &r);
    tc_decode_bc4_block_snorm(block[8..16], &g);
    var pairs: [16][2]i8 = undefined;
    for (&pairs, r, g) |*p, red, green| p.* = .{ red, green };
    return pairs;
}

/// Checks one block through both block decoders and both image decoders.
fn checkBlock(m: *common.Mismatches, i: u32, block: *const [16]u8) void {
    const want = tcDecodeBlock(block);
    const got = bcn.bc5.decodeBlockSnorm(block);
    m.check("block", i, 0, block.*, std.mem.asBytes(&want), std.mem.asBytes(&got));
    var want_red: [16]i8 = undefined;
    for (&want_red, want) |*r, p| r.* = p[0];
    const got_red = bcn.bc4.decodeBlockSnorm(block[0..8]);
    m.check("bc4 block", i, 0, block.*, std.mem.asBytes(&want_red), std.mem.asBytes(&got_red));

    var want_rgba: [16][4]u8 = undefined;
    const rc = tc_bc5_decompress_rgba8(block, 4, 4, signed, 16, @ptrCast(&want_rgba), 64);
    std.debug.assert(rc == 0);
    // texcomp writes blue 0 and alpha 255; the port writes red and green only.
    var got_rgba: [16][4]u8 = @splat(.{ 0, 0, 0, 255 });
    bcn.bc5.decodeImageSnorm(block, .init(std.mem.asBytes(&got_rgba), 4, 4, 4));
    m.check("image", i, 0, block.*, std.mem.asBytes(&want_rgba), std.mem.asBytes(&got_rgba));
}

test "bc5 snorm decodes every endpoint pair like texcomp, -128 included" {
    // Each block meets every entry of its palette, red with its endpoints in
    // one order and green in the other.
    var m: common.Mismatches = .{ .label = "bc5 snorm endpoint pairs" };
    const forward = cyclingIndices(false);
    const reversed = cyclingIndices(true);
    for (0..256) |e0| for (0..256) |e1| {
        const a: u8 = @intCast(e0);
        const b: u8 = @intCast(e1);
        const block: [16]u8 = [2]u8{ a, b } ++ forward ++ [2]u8{ b, a } ++ reversed;
        checkBlock(&m, @intCast(e0 * 256 + e1), &block);
    };
    try m.finish();
}

test "bc5 snorm decodes random and edge blocks like texcomp" {
    var rng = common.rng(0x5b5);
    var m: common.Mismatches = .{ .label = "bc5 snorm random" };
    // -128 (which also means -1), -127, -1, 0, 1 and 127.
    const edges = [_]u8{ 0x80, 0x81, 0xff, 0x00, 0x01, 0x7f };
    for (0..50_000) |i| {
        var block: [16]u8 = undefined;
        for (&block) |*b| b.* = rng.byte();
        switch (i % 4) {
            0 => for ([_]usize{ 0, 1, 8, 9 }) |at| {
                block[at] = edges[rng.below(edges.len)];
            },
            1 => {
                // Equal endpoints take the 6-entry palette.
                block[1] = block[0];
                block[9] = block[8];
            },
            else => {},
        }
        checkBlock(&m, @intCast(i), &block);
    }
    try m.finish();
}

test "bc5 snorm decodes texcomp's snorm encoding of the image set like texcomp" {
    const options: TcBc5Options = .{ .snorm = 1 };
    const len = comptime bcn.encodedLen(16, images.width, images.height);
    var encoded: [len]u8 = undefined;
    var want: [images.pixel_count][4]u8 = undefined;
    var got: [images.pixel_count][4]u8 = undefined;
    var m: common.Mismatches = .{ .label = "bc5 snorm image set" };
    for (0..images.ldr_names.len) |index| {
        const img = images.ldr(index);
        const pixels: []const u8 = std.mem.sliceAsBytes(&img.pixels);
        const stride = images.width * 4;
        const w = images.width;
        const h = images.height;
        const encode_rc = tc_bc5_compress_rgba8(pixels.ptr, w, h, stride, &options, &encoded, len);
        try std.testing.expectEqual(@as(c_int, 0), encode_rc);
        const want_bytes: []u8 = std.mem.sliceAsBytes(&want);
        const out = want_bytes.ptr;
        const rc = tc_bc5_decompress_rgba8(&encoded, w, h, signed, stride, out, want_bytes.len);
        try std.testing.expectEqual(@as(c_int, 0), rc);
        @memset(&got, .{ 0, 0, 0, 255 });
        bcn.bc5.decodeImageSnorm(&encoded, .init(std.mem.sliceAsBytes(&got), w, h, 4));
        m.check(img.name, 0, 0, @as(u8, 0), want_bytes, std.mem.sliceAsBytes(&got));
    }
    try m.finish();
}

test "bc5 snorm image decode matches texcomp in windows of a larger image, 2 to 4 channels" {
    // width, height, then the window's corner in the image
    const windows = [_][4]u32{
        .{ 1, 1, 0, 0 },                        .{ 3, 5, 7, 2 },    .{ 5, 2, 50, 40 },
        .{ 13, 7, 9, 31 },                      .{ 2, 17, 59, 30 }, .{ 8, 12, 4, 4 },
        .{ images.width, images.height, 0, 0 },
    };
    var rng = common.rng(0x5b6);
    var data: [bcn.encodedLen(16, images.width, images.height)]u8 = undefined;
    var packed_rgba: [images.pixel_count][4]u8 = undefined;
    var want: [images.pixel_count * 4]u8 = undefined;
    var got: [want.len]u8 = undefined;
    for (windows) |window| for (2..5) |channels| {
        const w = window[0];
        const h = window[1];
        const stride = images.width * @as(u32, @intCast(channels));
        const at = window[3] * stride + window[2] * channels;
        // Random blocks; both images start from the same random bytes, which
        // the decoders must leave alone outside channels 0 and 1 of the window.
        for (&data) |*b| b.* = rng.byte();
        for (&want, &got) |*a, *b| {
            a.* = rng.byte();
            b.* = a.*;
        }
        const packed_bytes = std.mem.sliceAsBytes(packed_rgba[0 .. w * h]);
        const rc = tc_bc5_decompress_rgba8(&data, w, h, signed, w * 4, packed_bytes.ptr, w * h * 4);
        try std.testing.expectEqual(@as(c_int, 0), rc);
        for (0..h) |y| for (0..w) |x| {
            want[at + y * stride + x * channels ..][0..2].* = packed_rgba[y * w + x][0..2].*;
        };
        bcn.bc5.decodeImageSnorm(&data, .{
            .pixels = got[at..],
            .width = w,
            .height = h,
            .stride = stride,
            .channels = @intCast(channels),
        });
        try std.testing.expectEqualSlices(u8, &want, &got);
    };
}
