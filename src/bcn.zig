//! BC1–BC7 and BC6H texture compression in pure Zig.
//!
//! Each format has `encodeBlock` and `decodeBlock` for one 4x4 block, and
//! `encodeImage` and `decodeImage` for a whole image into a caller-provided
//! buffer. Nothing allocates.

pub const image = @import("image.zig");
pub const Image = image.Image;
pub const ImageMut = image.ImageMut;
pub const encodedLen = image.encodedLen;
pub const BlockRows = image.BlockRows;

/// Every format behind one interface, and encoding on several threads.
pub const encoding = @import("encoding.zig");
pub const Encoding = encoding.Encoding;
pub const Source = encoding.Source;
pub const Destination = encoding.Destination;
pub const encodeImage = encoding.encodeImage;
pub const encodeImageRows = encoding.encodeImageRows;
pub const encodeImageParallel = encoding.encodeImageParallel;
pub const decodeImage = encoding.decodeImage;
pub const decodeImageRows = encoding.decodeImageRows;

pub const bc1 = @import("bc1.zig");
pub const bc3 = @import("bc3.zig");
pub const bc4 = @import("bc4.zig");
pub const bc5 = @import("bc5.zig");
pub const bc7 = @import("bc7.zig");
pub const bc6h = @import("bc6h.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
