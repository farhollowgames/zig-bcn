//! BC7 (BPTC): RGBA in 16 bytes per 4x4 block, eight modes.

const std = @import("std");
const assert = std.debug.assert;
const bc7e = @import("bc7e.zig");
const image = @import("image.zig");

pub const block_bytes = 16;
pub const Level = bc7e.Level;
pub const Params = bc7e.Params;
/// The encoder with the original's function shapes, for callers porting code
/// written against bc7e.
pub const bc7e_api = bc7e;

/// Encodes 16 RGBA pixels (row-major).
pub fn encodeBlock(pixels: *const [16][4]u8, params: *const Params) [block_bytes]u8 {
    return bc7e.compressBlock(pixels, params, null);
}

pub const Encoded = struct {
    block: [block_bytes]u8,
    /// Whether the winning encoding used the single-colour tables, whose
    /// extreme endpoints are fragile under lossy recompression of the indices.
    used_lut: bool,
};

pub fn encodeBlockReportingLut(pixels: *const [16][4]u8, params: *const Params) Encoded {
    var used_lut = false;
    const block = bc7e.compressBlock(pixels, params, &used_lut);
    return .{ .block = block, .used_lut = used_lut };
}

pub const SingleMode = struct {
    mode: u3,
    /// Forces a partition for modes 0, 1, 2, 3 and 7 (0 to 15 for mode 0, 0
    /// to 63 otherwise); null searches.
    partition: ?u6 = null,
    /// Channel swapped with alpha for modes 4 and 5: 0 none, 1 red, 2 green,
    /// 3 blue. Non-zero forces the linear error metric.
    rotation: u2 = 0,
    /// Mode 4: 1 gives colour the 3-bit indices and alpha the 2-bit ones.
    index_selector: u1 = 0,
};

/// Encodes in one mode only, for tools and tests. Returns the block and the
/// encoder's error measure for it.
pub fn encodeBlockSingleMode(pixels: *const [16][4]u8, params: *const Params, single: SingleMode) struct { block: [block_bytes]u8, err: u64 } {
    var block: [block_bytes]u8 = undefined;
    const partition: i32 = if (single.partition) |p| p else -1;
    const err = bc7e.compressBlockSingleMode(&block, pixels, params, single.mode, partition, single.rotation, single.index_selector);
    return .{ .block = block, .err = err };
}

/// Encodes an RGB (3 channels, opaque) or RGBA image into `dst`, which must
/// hold `image.encodedLen(block_bytes, width, height)` bytes.
pub fn encodeImage(src: image.Image(u8), dst: []u8, params: *const Params) void {
    encodeImageRows(src, dst, params, image.BlockRows.all(src.height));
}

/// `encodeImage` for the block rows `rows` only; see `image.BlockRows`.
pub fn encodeImageRows(src: image.Image(u8), dst: []u8, params: *const Params, rows: image.BlockRows) void {
    src.check();
    assert(src.channels >= 3);
    params.check();
    const Ctx = struct { src: image.Image(u8), params: *const Params };
    image.encodeBlocks(block_bytes, src.width, src.height, dst, rows, Ctx{ .src = src, .params = params }, struct {
        fn f(ctx: Ctx, bx: u32, by: u32) [block_bytes]u8 {
            var px: [16][4]u8 = undefined;
            if (ctx.src.channels == 3) {
                for (ctx.src.block(3, bx, by), &px) |rgb, *p| p.* = .{ rgb[0], rgb[1], rgb[2], 255 };
            } else {
                px = ctx.src.block(4, bx, by);
            }
            return encodeBlock(&px, ctx.params);
        }
    }.f);
}

/// Decodes into an RGBA image of the same size the data was encoded from.
pub fn decodeImage(src: []const u8, dst: image.ImageMut(u8)) void {
    decodeImageRows(src, dst, image.BlockRows.all(dst.height));
}

/// `decodeImage` for the block rows `rows` only; see `image.BlockRows`.
pub fn decodeImageRows(src: []const u8, dst: image.ImageMut(u8), rows: image.BlockRows) void {
    dst.check();
    assert(dst.channels == 4);
    image.decodeBlocks(block_bytes, dst.width, dst.height, src, rows, dst, struct {
        fn f(out: image.ImageMut(u8), block: *const [block_bytes]u8, bx: u32, by: u32) void {
            out.putBlock(4, bx, by, &decodeBlock(block));
        }
    }.f);
}

/// Decodes to floats from 0 to 1 (`decodeBlockF32`), into an RGBA image, or
/// an RGB one that leaves alpha out, of the same size the data was encoded
/// from.
pub fn decodeImageF32(src: []const u8, dst: image.ImageMut(f32)) void {
    decodeImageF32Rows(src, dst, image.BlockRows.all(dst.height));
}

/// `decodeImageF32` for the block rows `rows` only; see `image.BlockRows`.
pub fn decodeImageF32Rows(
    src: []const u8,
    dst: image.ImageMut(f32),
    rows: image.BlockRows,
) void {
    dst.check();
    assert(dst.channels == 3 or dst.channels == 4);
    image.decodeBlocks(block_bytes, dst.width, dst.height, src, rows, dst, struct {
        fn f(out: image.ImageMut(f32), block: *const [block_bytes]u8, bx: u32, by: u32) void {
            const rgba = decodeBlockF32(block);
            if (out.channels == 4) {
                out.putBlock(4, bx, by, &rgba);
            } else {
                var rgb: [16][3]f32 = undefined;
                for (rgba, &rgb) |p, *q| q.* = p[0..3].*;
                out.putBlock(3, bx, by, &rgb);
            }
        }
    }.f);
}

const ModeInfo = struct {
    subsets: u8,
    partition_bits: u8,
    rotation_bits: u8,
    index_selection_bits: u8,
    color_bits: u8,
    alpha_bits: u8,
    /// One p-bit per endpoint.
    endpoint_pbits: bool,
    /// One p-bit per subset, shared by its two endpoints.
    shared_pbits: bool,
    index_bits: u8,
    index2_bits: u8,
};

const modes = [8]ModeInfo{
    .{ .subsets = 3, .partition_bits = 4, .rotation_bits = 0, .index_selection_bits = 0, .color_bits = 4, .alpha_bits = 0, .endpoint_pbits = true, .shared_pbits = false, .index_bits = 3, .index2_bits = 0 },
    .{ .subsets = 2, .partition_bits = 6, .rotation_bits = 0, .index_selection_bits = 0, .color_bits = 6, .alpha_bits = 0, .endpoint_pbits = false, .shared_pbits = true, .index_bits = 3, .index2_bits = 0 },
    .{ .subsets = 3, .partition_bits = 6, .rotation_bits = 0, .index_selection_bits = 0, .color_bits = 5, .alpha_bits = 0, .endpoint_pbits = false, .shared_pbits = false, .index_bits = 2, .index2_bits = 0 },
    .{ .subsets = 2, .partition_bits = 6, .rotation_bits = 0, .index_selection_bits = 0, .color_bits = 7, .alpha_bits = 0, .endpoint_pbits = true, .shared_pbits = false, .index_bits = 2, .index2_bits = 0 },
    .{ .subsets = 1, .partition_bits = 0, .rotation_bits = 2, .index_selection_bits = 1, .color_bits = 5, .alpha_bits = 6, .endpoint_pbits = false, .shared_pbits = false, .index_bits = 2, .index2_bits = 3 },
    .{ .subsets = 1, .partition_bits = 0, .rotation_bits = 2, .index_selection_bits = 0, .color_bits = 7, .alpha_bits = 8, .endpoint_pbits = false, .shared_pbits = false, .index_bits = 2, .index2_bits = 2 },
    .{ .subsets = 1, .partition_bits = 0, .rotation_bits = 0, .index_selection_bits = 0, .color_bits = 7, .alpha_bits = 7, .endpoint_pbits = true, .shared_pbits = false, .index_bits = 4, .index2_bits = 0 },
    .{ .subsets = 2, .partition_bits = 6, .rotation_bits = 0, .index_selection_bits = 0, .color_bits = 5, .alpha_bits = 5, .endpoint_pbits = true, .shared_pbits = false, .index_bits = 2, .index2_bits = 0 },
};

const BitReader = struct {
    bits: u128,
    used: u32 = 0,

    fn read(self: *BitReader, n: u32) u32 {
        assert(n <= 8 and self.used + n <= 128);
        const v: u32 = @intCast(self.bits & ((@as(u128, 1) << @intCast(n)) - 1));
        self.bits >>= @intCast(n);
        self.used += n;
        return v;
    }

    /// Reads 16 indices of `bits` each, one bit fewer at each of `anchors`
    /// (16 for none), as one lane per pixel.
    fn indices(self: *BitReader, bits: u32, anchors: [3]u32) @Vector(16, u32) {
        const Lanes = @Vector(16, u32);
        const zeros: Lanes = @splat(0);
        const ones: Lanes = @splat(1);
        const lane = std.simd.iota(u32, 16);
        var start = lane * @as(Lanes, @splat(bits));
        var width: Lanes = @splat(bits);
        var total = 16 * bits;
        for (anchors) |anchor| {
            const at: Lanes = @splat(anchor);
            start -= @select(u32, lane > at, ones, zeros);
            width -= @select(u32, lane == at, ones, zeros);
            if (anchor < 16) total -= 1;
        }
        assert(total <= 64 and self.used + total <= 128);
        const one_bit: @Vector(16, u64) = @splat(1);
        const field: @Vector(16, u64) = @splat(@truncate(self.bits));
        const mask = (one_bit << @intCast(width)) - one_bit;
        const index = (field >> @intCast(start)) & mask;
        self.bits >>= @intCast(total);
        self.used += total;
        return @intCast(index);
    }
};

/// Each lane's weight from `table`.
fn weights(table: []const u32, index: @Vector(16, u32)) @Vector(16, u32) {
    const at: [16]u32 = index;
    var out: [16]u32 = undefined;
    for (&out, at) |*w, i| w.* = table[i];
    return out;
}

fn weightTable(bits: u32) []const u32 {
    return switch (bits) {
        2 => &bc7e.weights2,
        3 => &bc7e.weights3,
        4 => &bc7e.weights4,
        else => unreachable,
    };
}

/// Expands a `bits`-wide value to 8 bits by replicating its top bits.
fn expand(v: u32, bits: u32) u32 {
    assert(bits >= 4 and bits <= 8 and v < (@as(u32, 1) << @intCast(bits)));
    const shifted = v << @intCast(8 - bits);
    return shifted | (shifted >> @intCast(bits));
}

// The index reader counts each anchor once, so a block's anchors must be
// different pixels; the first is always pixel 0.
comptime {
    for (bc7e.anchor_second_subset) |a| assert(a != 0 and a < 16);
    for (bc7e.anchor_third_subset_1, bc7e.anchor_third_subset_2) |a, b| {
        assert(a != 0 and b != 0 and a != b and a < 16 and b < 16);
    }
}

/// Decodes to RGBA. A block with no mode bit set in its first byte is
/// reserved and decodes to transparent black, as the D3D11 spec requires.
pub fn decodeBlock(block: *const [block_bytes]u8) [16][4]u8 {
    return decodeBlockAs(u8, block);
}

/// Decodes to RGBA floats, each byte `decodeBlock` gives divided by 255.
pub fn decodeBlockF32(block: *const [block_bytes]u8) [16][4]f32 {
    return decodeBlockAs(f32, block);
}

fn decodeBlockAs(comptime T: type, block: *const [block_bytes]u8) [16][4]T {
    if (block[0] == 0) return @splat(.{ 0, 0, 0, 0 });
    // One decoder per mode, so each reads its fields in straight lines.
    return switch (@ctz(block[0])) {
        inline 0...modes.len - 1 => |mode| decodeMode(T, mode, block),
        else => unreachable,
    };
}

fn decodeMode(comptime T: type, comptime mode: u32, block: *const [block_bytes]u8) [16][4]T {
    var r: BitReader = .{ .bits = std.mem.readInt(u128, block, .little) };
    _ = r.read(mode + 1);
    const info = modes[mode];

    const partition = r.read(info.partition_bits);
    const rotation = r.read(info.rotation_bits);
    const index_selection = r.read(info.index_selection_bits);

    const num_endpoints = info.subsets * 2;
    var endpoints: [6][4]u32 = @splat(@splat(0));
    for (0..3) |c| {
        for (endpoints[0..num_endpoints]) |*e| e[c] = r.read(info.color_bits);
    }
    if (info.alpha_bits > 0) {
        for (endpoints[0..num_endpoints]) |*e| e[3] = r.read(info.alpha_bits);
    }

    var color_bits: u32 = info.color_bits;
    var alpha_bits: u32 = info.alpha_bits;
    if (info.endpoint_pbits or info.shared_pbits) {
        var pbits: [6]u32 = undefined;
        if (info.endpoint_pbits) {
            for (pbits[0..num_endpoints]) |*p| p.* = r.read(1);
        } else {
            for (0..info.subsets) |s| {
                const p = r.read(1);
                pbits[s * 2] = p;
                pbits[s * 2 + 1] = p;
            }
        }
        for (endpoints[0..num_endpoints], pbits[0..num_endpoints]) |*e, p| {
            for (e) |*v| v.* = (v.* << 1) | p;
        }
        color_bits += 1;
        if (alpha_bits > 0) alpha_bits += 1;
    }
    for (endpoints[0..num_endpoints]) |*e| {
        for (e[0..3]) |*v| v.* = expand(v.*, color_bits);
        e[3] = if (alpha_bits > 0) expand(e[3], alpha_bits) else 255;
    }

    // The subset of each pixel, and each subset's anchor: its first pixel,
    // whose index is stored one bit short with the top bit implied zero.
    var subset_of: [16]u8 = @splat(0);
    var anchors = [3]u32{ 0, 16, 16 };
    switch (info.subsets) {
        2 => {
            subset_of = bc7e.partition2[partition * 16 ..][0..16].*;
            anchors[1] = bc7e.anchor_second_subset[partition];
        },
        3 => {
            subset_of = bc7e.partition3[partition * 16 ..][0..16].*;
            anchors[1] = bc7e.anchor_third_subset_1[partition];
            anchors[2] = bc7e.anchor_third_subset_2[partition];
        },
        else => assert(info.subsets == 1),
    }

    const index = r.indices(info.index_bits, anchors);
    var color_weights = weights(weightTable(info.index_bits), index);
    var alpha_weights = color_weights;
    if (info.index2_bits > 0) {
        const index2 = r.indices(info.index2_bits, .{ 0, 16, 16 });
        alpha_weights = weights(weightTable(info.index2_bits), index2);
        if (index_selection == 1) std.mem.swap(@Vector(16, u32), &color_weights, &alpha_weights);
    }
    assert(r.used == 128);

    // All 16 pixels at once, one lane each.
    const Lanes = @Vector(16, u32);
    const subset: @Vector(16, u8) = subset_of;
    var channels: [4]Lanes = undefined;
    for (&channels, 0..) |*channel, c| {
        var lo: Lanes = @splat(endpoints[0][c]);
        var hi: Lanes = @splat(endpoints[1][c]);
        for (1..info.subsets) |s| {
            const in_subset = subset == @as(@Vector(16, u8), @splat(@intCast(s)));
            lo = @select(u32, in_subset, @as(Lanes, @splat(endpoints[s * 2][c])), lo);
            hi = @select(u32, in_subset, @as(Lanes, @splat(endpoints[s * 2 + 1][c])), hi);
        }
        const w = if (c < 3) color_weights else alpha_weights;
        const sum = lo * (@as(Lanes, @splat(64)) - w) + hi * w + @as(Lanes, @splat(32));
        channel.* = sum >> @splat(6);
    }
    if (rotation != 0) std.mem.swap(Lanes, &channels[3], &channels[rotation - 1]);
    var planes: [4][16]T = undefined;
    for (&planes, channels) |*plane, channel| plane.* = switch (T) {
        u8 => @as(@Vector(16, u8), @intCast(channel)),
        f32 => @as(@Vector(16, f32), @floatFromInt(channel)) / @as(@Vector(16, f32), @splat(255)),
        else => comptime unreachable,
    };
    var out: [16][4]T = undefined;
    for (&out, planes[0], planes[1], planes[2], planes[3]) |*p, red, green, blue, alpha| {
        p.* = .{ red, green, blue, alpha };
    }
    return out;
}

test "a solid block encodes exactly and decodes back" {
    const px: [16][4]u8 = @splat(.{ 12, 200, 99, 130 });
    const params = Params.init(.basic, false);
    const decoded = decodeBlock(&encodeBlock(&px, &params));
    for (decoded) |p| try std.testing.expectEqual(px[0], p);
}

test "the reserved mode decodes to transparent black" {
    const zero: [16]u8 = @splat(0);
    for (decodeBlock(&zero)) |p| try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, p);
}

/// The BC7 partition patterns (subset of each pixel, 64 patterns of 16),
/// for tools and tests.
pub const partition2_table = bc7e.partition2;
pub const partition3_table = bc7e.partition3;
