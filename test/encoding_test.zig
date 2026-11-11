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
    .{ .bc6h = .{ .format = .unsigned, .quality = .high } },
    .{ .bc6h = .{ .format = .signed, .quality = .high } },
};

const max_len = bcn.encodedLen(16, images.width, images.height);

/// The format's own encodeImage, called directly.
fn direct(encoding: *const bcn.Encoding, src: bcn.Source, dst: []u8) void {
    switch (encoding.*) {
        .bc1 => |s| bcn.bc1.encodeImage(src.unorm8, dst, s),
        .bc3 => |s| bcn.bc3.encodeImage(src.unorm8, dst, s),
        .bc4 => bcn.bc4.encodeImage(src.unorm8, dst),
        .bc5 => bcn.bc5.encodeImage(src.unorm8, dst),
        .bc6h => |o| switch (o.quality) {
            .fast => bcn.bc6h.encodeImage(src.float32, dst, o.format),
            .high => bcn.bc6h.encodeImageQuality(src.float32, dst, o.format, .high),
        },
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
    var rng = common.rng(11);
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
    var rng = common.rng(12);
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

test "parallel encoding gives the same bytes on 1, 2 and 8 threads" {
    // No worker threads runs every task on the caller.
    const limits = [_]std.Io.Limit{ .nothing, .limited(1), .limited(7) };
    const encodings = [_]bcn.Encoding{
        .{ .bc1 = .{ .quality = .high } },
        .bc5,
        .{ .bc7 = bcn.bc7.Params.init(.basic, true) },
    };
    const hdr = [_]bcn.Encoding{
        .{ .bc6h = .{ .format = .signed } },
        .{ .bc6h = .{ .format = .unsigned, .quality = .high } },
    };
    var want: [max_len]u8 = undefined;
    var got: [max_len]u8 = undefined;
    for (limits) |limit| {
        var threaded: std.Io.Threaded = .init(std.testing.allocator, .{ .async_limit = limit });
        defer threaded.deinit();
        const io = threaded.io();
        for ([_]usize{ 4, 7, 10 }) |index| {
            const img = images.ldr(index);
            const src: bcn.Source = .{ .unorm8 = common.ldrView(&img) };
            for (&encodings) |*e| {
                const len = e.encodedLen(images.width, images.height);
                direct(e, src, want[0..len]);
                @memset(got[0..len], 0xaa);
                try bcn.encodeImageParallel(io, e, src, got[0..len], 1);
                try std.testing.expectEqualSlices(u8, want[0..len], got[0..len]);
            }
        }
        for ([_]usize{ 2, 5 }) |index| {
            const img = images.hdr(index);
            const floats: []const f32 = std.mem.bytesAsSlice(f32, std.mem.sliceAsBytes(&img.pixels));
            const src: bcn.Source = .{ .float32 = bcn.Image(f32).init(floats, images.width, images.height, 3) };
            for (&hdr) |*e| {
                direct(e, src, &want);
                @memset(&got, 0xaa);
                try bcn.encodeImageParallel(io, e, src, &got, 1);
                try std.testing.expectEqualSlices(u8, &want, &got);
            }
        }
    }
}

test "decoding in row bands gives the image decoded whole" {
    var rng = common.rng(13);
    errdefer std.debug.print("-Dfuzz-seed=0x{x}\n", .{common.fuzz_seed});
    var blocks: [max_len]u8 = undefined;
    for (&blocks) |*b| b.* = rng.byte();
    const total = bcn.image.blocksHigh(images.height);
    var want: [images.pixel_count * 4]f32 = undefined;
    var got: [images.pixel_count * 4]f32 = undefined;
    const all = ldr_encodings ++ hdr_encodings;
    for (&all) |*e| {
        for (0..3) |round| {
            // Bytes the decoders leave alone must match too.
            const fill: u8 = @intCast(round * 0x55);
            @memset(std.mem.sliceAsBytes(&want), fill);
            @memset(std.mem.sliceAsBytes(&got), fill);
            const whole = destination(e, &want, round);
            const banded = destination(e, &got, round);
            bcn.decodeImage(e, &blocks, whole);
            var cuts: [3]u32 = undefined;
            for (&cuts) |*c| c.* = rng.below(total + 1);
            std.mem.sortUnstable(u32, &cuts, {}, std.sort.asc(u32));
            const bounds: [5]u32 = .{ 0, cuts[0], cuts[1], cuts[2], total };
            var band: usize = bounds.len - 1;
            while (band > 0) {
                band -= 1;
                if (bounds[band + 1] == bounds[band]) continue;
                const rows: bcn.BlockRows = .{
                    .first = bounds[band],
                    .count = bounds[band + 1] - bounds[band],
                };
                bcn.decodeImageRows(e, &blocks, banded, rows);
            }
            try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&want), std.mem.sliceAsBytes(&got));
        }
    }
}

/// A destination for `e` over `storage`: bytes, half floats or floats for
/// BC6H by `round`, with a few channel counts.
fn destination(e: *const bcn.Encoding, storage: *[images.pixel_count * 4]f32, round: usize) bcn.Destination {
    const w = images.width;
    const h = images.height;
    const bytes = std.mem.sliceAsBytes(storage);
    return switch (e.*) {
        .bc6h => switch (round % 3) {
            0 => .{ .half = bcn.ImageMut(u16).init(std.mem.bytesAsSlice(u16, bytes), w, h, 3) },
            1 => .{ .float32 = bcn.ImageMut(f32).init(storage, w, h, 3) },
            else => .{ .float32 = bcn.ImageMut(f32).init(storage, w, h, 4) },
        },
        .bc4 => .{ .unorm8 = bcn.ImageMut(u8).init(bytes, w, h, @intCast(1 + round)) },
        .bc5 => .{ .unorm8 = bcn.ImageMut(u8).init(bytes, w, h, @intCast(2 + round % 2)) },
        else => .{ .unorm8 = bcn.ImageMut(u8).init(bytes, w, h, 4) },
    };
}

test "encoders read images of fewer channels like the same pixels in RGBA" {
    var one: [images.pixel_count]u8 = undefined;
    var two: [images.pixel_count][2]u8 = undefined;
    var three: [images.pixel_count][3]u8 = undefined;
    var opaque_rgba: [images.pixel_count][4]u8 = undefined;
    var want: [max_len]u8 = undefined;
    var got: [max_len]u8 = undefined;
    const w = images.width;
    const h = images.height;
    for (0..images.ldr_names.len) |index| {
        const img = images.ldr(index);
        for (img.pixels, &one, &two, &three, &opaque_rgba) |p, *a, *b, *c, *d| {
            a.* = p[0];
            b.* = p[0..2].*;
            c.* = p[0..3].*;
            d.* = .{ p[0], p[1], p[2], 255 };
        }
        const rgba = common.ldrView(&img);

        // BC4 reads channel 0 and BC5 channels 0 and 1, whatever follows.
        bcn.bc4.encodeImage(rgba, want[0 .. max_len / 2]);
        bcn.bc4.encodeImage(bcn.Image(u8).init(&one, w, h, 1), got[0 .. max_len / 2]);
        try std.testing.expectEqualSlices(u8, want[0 .. max_len / 2], got[0 .. max_len / 2]);
        bcn.bc4.encodeImage(bcn.Image(u8).init(std.mem.sliceAsBytes(&two), w, h, 2), got[0 .. max_len / 2]);
        try std.testing.expectEqualSlices(u8, want[0 .. max_len / 2], got[0 .. max_len / 2]);
        bcn.bc5.encodeImage(rgba, &want);
        bcn.bc5.encodeImage(bcn.Image(u8).init(std.mem.sliceAsBytes(&two), w, h, 2), &got);
        try std.testing.expectEqualSlices(u8, &want, &got);
        bcn.bc5.encodeImage(bcn.Image(u8).init(std.mem.sliceAsBytes(&three), w, h, 3), &got);
        try std.testing.expectEqualSlices(u8, &want, &got);

        // BC7 encodes RGB as opaque RGBA.
        const rgb = bcn.Image(u8).init(std.mem.sliceAsBytes(&three), w, h, 3);
        const opaque_view = bcn.Image(u8).init(std.mem.sliceAsBytes(&opaque_rgba), w, h, 4);
        for ([_]bcn.bc7.Params{ bcn.bc7.Params.init(.ultrafast, true), bcn.bc7.Params.init(.basic, false) }) |params| {
            bcn.bc7.encodeImage(opaque_view, &want, &params);
            bcn.bc7.encodeImage(rgb, &got, &params);
            try std.testing.expectEqualSlices(u8, &want, &got);
        }
    }

    // BC6H reads the first three channels of RGBA floats.
    var rgba_f: [images.pixel_count][4]f32 = undefined;
    var rng = common.rng(14);
    for (0..images.hdr_names.len) |index| {
        const img = images.hdr(index);
        for (img.pixels, &rgba_f) |p, *q| q.* = .{ p[0], p[1], p[2], @floatFromInt(rng.byte()) };
        const floats: []const f32 = std.mem.bytesAsSlice(f32, std.mem.sliceAsBytes(&img.pixels));
        const rgb = bcn.Image(f32).init(floats, w, h, 3);
        const rgba = bcn.Image(f32).init(std.mem.bytesAsSlice(f32, std.mem.sliceAsBytes(&rgba_f)), w, h, 4);
        for ([_]bcn.bc6h.Format{ .unsigned, .signed }) |format| {
            for ([_]bcn.bc6h.Quality{ .fast, .high }) |quality| {
                bcn.bc6h.encodeImageQuality(rgb, &want, format, quality);
                bcn.bc6h.encodeImageQuality(rgba, &got, format, quality);
                try std.testing.expectEqualSlices(u8, &want, &got);
            }
        }
    }
}
