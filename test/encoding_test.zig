//! The format-independent API: it must give the bytes of each format's own
//! functions, in one call, in row bands, and on several threads.

const std = @import("std");
const bcn = @import("bcn");
const images = @import("images.zig");
const common = @import("common.zig");

const ldr_encodings = [_]bcn.Encoding{
    .{ .bc1 = .{} },
    .{ .bc1 = .{ .quality = .high, .rounding = .biased } },
    .{ .bc3 = .{ .quality = .high } },
    .bc4,
    .bc5,
    .{ .bc7 = bcn.bc7.Params.init(.ultrafast, true) },
    .{ .bc7 = bcn.bc7.Params.init(.basic, false) },
};

const hdr_encodings = [_]bcn.Encoding{
    .{ .bc6h = .{ .format = .unsigned } },
    .{ .bc6h = .{ .format = .signed } },
};

const max_len = bcn.encodedLen(16, images.width, images.height);

/// The format's own encodeImage, called directly.
fn direct(encoding: *const bcn.Encoding, src: bcn.Source, dst: []u8) void {
    switch (encoding.*) {
        .bc1 => |s| bcn.bc1.encodeImage(src.unorm8, dst, s),
        .bc3 => |s| bcn.bc3.encodeImage(src.unorm8, dst, s),
        .bc4 => bcn.bc4.encodeImage(src.unorm8, dst),
        .bc5 => bcn.bc5.encodeImage(src.unorm8, dst),
        .bc6h => |o| bcn.bc6h.encodeImage(src.float32, dst, o.format),
        .bc7 => |*p| bcn.bc7.encodeImage(src.unorm8, dst, p),
    }
}

fn expectSameEverywhere(encoding: *const bcn.Encoding, src: bcn.Source, rng: *images.Rng) !void {
    const len = encoding.encodedLen(src.width(), src.height());
    var want: [max_len]u8 = undefined;
    var got: [max_len]u8 = undefined;
    direct(encoding, src, want[0..len]);

    bcn.encodeImage(encoding, src, got[0..len]);
    try std.testing.expectEqualSlices(u8, want[0..len], got[0..len]);

    for ([_]u32{ 1, 3, 100 }) |band_rows| {
        @memset(got[0..len], 0xaa);
        try bcn.encodeImageParallel(std.testing.io, encoding, src, got[0..len], band_rows);
        try std.testing.expectEqualSlices(u8, want[0..len], got[0..len]);
    }

    // Random bands, encoded out of order, reassemble the same image.
    @memset(got[0..len], 0x55);
    const total = bcn.image.blocksHigh(src.height());
    var cuts: [4]u32 = undefined;
    for (&cuts) |*c| c.* = rng.below(total + 1);
    std.mem.sortUnstable(u32, &cuts, {}, std.sort.asc(u32));
    const bounds: [6]u32 = .{ 0, cuts[0], cuts[1], cuts[2], cuts[3], total };
    var band: usize = bounds.len - 1;
    while (band > 0) {
        band -= 1;
        if (bounds[band + 1] > bounds[band]) {
            bcn.encodeImageRows(encoding, src, got[0..len], .{ .first = bounds[band], .count = bounds[band + 1] - bounds[band] });
        }
    }
    try std.testing.expectEqualSlices(u8, want[0..len], got[0..len]);
}

test "the format-independent API matches each format, in bands and on threads" {
    var rng: images.Rng = .{ .state = 11 };
    for (0..images.ldr_names.len) |index| {
        const img = images.ldr(index);
        const src: bcn.Source = .{ .unorm8 = common.ldrView(&img) };
        for (&ldr_encodings) |*e| try expectSameEverywhere(e, src, &rng);
    }
    for (0..images.hdr_names.len) |index| {
        const img = images.hdr(index);
        const floats: []const f32 = std.mem.bytesAsSlice(f32, std.mem.sliceAsBytes(&img.pixels));
        const src: bcn.Source = .{ .float32 = bcn.Image(f32).init(floats, images.width, images.height, 3) };
        for (&hdr_encodings) |*e| try expectSameEverywhere(e, src, &rng);
    }
}

test "the format-independent decoders match each format's" {
    var rng: images.Rng = .{ .state = 12 };
    var blocks: [max_len]u8 = undefined;
    for (&blocks) |*b| b.* = rng.byte();
    var want: [images.pixel_count * 4]u8 = undefined;
    var got: [images.pixel_count * 4]u8 = undefined;
    for (&ldr_encodings) |*e| {
        @memset(&want, 0);
        @memset(&got, 0);
        const w = bcn.ImageMut(u8).init(&want, images.width, images.height, 4);
        switch (e.*) {
            .bc1 => bcn.bc1.decodeImage(&blocks, w),
            .bc3 => bcn.bc3.decodeImage(&blocks, w),
            .bc4 => bcn.bc4.decodeImage(&blocks, w),
            .bc5 => bcn.bc5.decodeImage(&blocks, w),
            .bc7 => bcn.bc7.decodeImage(&blocks, w),
            .bc6h => unreachable,
        }
        bcn.decodeImage(e, &blocks, .{ .unorm8 = bcn.ImageMut(u8).init(&got, images.width, images.height, 4) });
        try std.testing.expectEqualSlices(u8, &want, &got);
    }
    var want_half: [images.pixel_count * 3]u16 = undefined;
    var got_half: [images.pixel_count * 3]u16 = undefined;
    var want_f32: [images.pixel_count * 3]f32 = undefined;
    var got_f32: [images.pixel_count * 3]f32 = undefined;
    for (&hdr_encodings) |*e| {
        bcn.bc6h.decodeImage(&blocks, bcn.ImageMut(u16).init(&want_half, images.width, images.height, 3), e.bc6h.format);
        bcn.decodeImage(e, &blocks, .{ .half = bcn.ImageMut(u16).init(&got_half, images.width, images.height, 3) });
        try std.testing.expectEqualSlices(u16, &want_half, &got_half);
        bcn.bc6h.decodeImageF32(&blocks, bcn.ImageMut(f32).init(&want_f32, images.width, images.height, 3), e.bc6h.format);
        bcn.decodeImage(e, &blocks, .{ .float32 = bcn.ImageMut(f32).init(&got_f32, images.width, images.height, 3) });
        try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&want_f32), std.mem.sliceAsBytes(&got_f32));
    }
}
