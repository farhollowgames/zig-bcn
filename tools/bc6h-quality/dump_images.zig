//! Writes the differential tests' HDR images as .rgbf files ("RGBF", u32
//! width, u32 height, then RGB f32 rows) for quality.cpp.
//!   zig run -Mroot=tools/bc6h-quality/dump_images.zig -Mimages=test/images.zig --dep images -- <dir>
//! (the --dep flag goes before -Mroot).

const std = @import("std");
const images = @import("images");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const dir = args[1];
    for (0..images.hdr_names.len) |i| {
        const img = images.hdr(i);
        const path = try std.fmt.allocPrint(init.arena.allocator(), "{s}/{s}.rgbf", .{ dir, img.name });
        var header: [12]u8 = undefined;
        @memcpy(header[0..4], "RGBF");
        std.mem.writeInt(u32, header[4..8], images.width, .little);
        std.mem.writeInt(u32, header[8..12], images.height, .little);
        const file = try std.Io.Dir.cwd().createFile(init.io, path, .{});
        defer file.close(init.io);
        try file.writeStreamingAll(init.io, &header);
        try file.writeStreamingAll(init.io, std.mem.sliceAsBytes(&img.pixels));
    }
}
