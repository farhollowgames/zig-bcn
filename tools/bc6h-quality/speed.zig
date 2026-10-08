//! Encode speed of zig-bcn's BC6H on .rgbf images (see dump_images.zig and
//! quality.cpp --dump), single thread, best of three runs.
//!   zig run -O ReleaseFast --dep bcn -Mroot=tools/bc6h-quality/speed.zig -Mbcn=src/bcn.zig -- <image.rgbf>...

const std = @import("std");
const bcn = @import("bcn");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    for (args[1..]) |path| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, arena, .unlimited);
        if (!std.mem.eql(u8, bytes[0..4], "RGBF")) return error.NotRgbf;
        const width = std.mem.readInt(u32, bytes[4..8], .little);
        const height = std.mem.readInt(u32, bytes[8..12], .little);
        const floats = try arena.alloc(f32, @as(usize, width) * height * 3);
        @memcpy(std.mem.sliceAsBytes(floats), bytes[12..][0 .. floats.len * 4]);
        const src = bcn.Image(f32).init(floats, width, height, 3);
        const dst = try arena.alloc(u8, bcn.encodedLen(16, width, height));
        for ([_]bcn.bc6h.Format{ .unsigned, .signed }) |format| {
            var best_ns: u64 = std.math.maxInt(u64);
            for (0..3) |_| {
                const t0 = std.Io.Clock.awake.now(init.io);
                bcn.bc6h.encodeImage(src, dst, format);
                const ns: u64 = @intCast(t0.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds);
                best_ns = @min(best_ns, ns);
            }
            const mpix = @as(f64, @floatFromInt(@as(u64, width) * height)) / (@as(f64, @floatFromInt(best_ns)) / 1e9) / 1e6;
            std.debug.print("{s} {t}: {d:.2} Mpixel/s\n", .{ path, format, mpix });
        }
    }
}
