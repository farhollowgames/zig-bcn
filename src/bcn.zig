//! BC1–BC7 and BC6H texture compression in pure Zig.
//!
//! Each format has `encodeBlock` and `decodeBlock` for one 4x4 block, and
//! `encodeImage` and `decodeImage` for a whole image into a caller-provided
//! buffer. Nothing allocates.

pub const image = @import("image.zig");
pub const Image = image.Image;
pub const ImageMut = image.ImageMut;
pub const encodedLen = image.encodedLen;

pub const bc1 = @import("bc1.zig");
pub const bc3 = @import("bc3.zig");
pub const bc4 = @import("bc4.zig");
pub const bc5 = @import("bc5.zig");
pub const bc7 = @import("bc7.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
