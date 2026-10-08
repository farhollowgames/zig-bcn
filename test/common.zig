//! Helpers shared by the differential tests.

const std = @import("std");
const bcn = @import("bcn");
const images = @import("images.zig");

pub const max_reported = 5;

/// Counts differing blocks and prints the first few with their inputs.
pub const Mismatches = struct {
    label: []const u8,
    count: u32 = 0,

    pub fn check(self: *Mismatches, what: []const u8, bx: u32, by: u32, input: anytype, want: []const u8, got: []const u8) void {
        if (std.mem.eql(u8, want, got)) return;
        self.count += 1;
        if (self.count > max_reported) return;
        std.debug.print("\n{s} {s}: block ({d}, {d}) differs\n  reference {x}\n  zig       {x}\n  input     {any}\n", .{ self.label, what, bx, by, want, got, input });
    }

    pub fn finish(self: Mismatches) !void {
        if (self.count == 0) return;
        std.debug.print("{s}: {d} blocks differ\n", .{ self.label, self.count });
        return error.Mismatch;
    }
};

pub fn ldrView(img: *const images.Ldr) bcn.Image(u8) {
    const bytes: []const u8 = std.mem.sliceAsBytes(&img.pixels);
    return bcn.Image(u8).init(bytes, images.width, images.height, 4);
}

pub const blocks_wide = bcn.image.blocksWide(images.width);
pub const blocks_high = bcn.image.blocksHigh(images.height);
