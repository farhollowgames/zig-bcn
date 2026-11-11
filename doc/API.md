# API

The public API of zig-bcn, by format. The doc comments in `src/` give each
function's details. The README has a short example.

## Every format

Each format module (`bc1`, `bc3`, `bc4`, `bc5`, `bc6h`, `bc7`) has:

- `encodeBlock` and `decodeBlock` for one 4x4 block, pixels in row-major
  order;
- `encodeImage(src, dst, ...)` and `decodeImage(src, dst, ...)` for a whole
  image, blocks in row-major order. Images are views (`bcn.Image(T)`,
  `bcn.ImageMut(T)`) with a row stride and 1 to 4 channels, so a view can
  cover part of a larger image. Edge blocks of images whose sides are not
  multiples of 4 repeat the last row and column;
- `block_bytes`, with `bcn.encodedLen(block_bytes, width, height)` for the
  output size.

## Encoding

For tools that pick the format at run time, such as a bake step,
`bcn.Encoding` puts every format and its settings behind one interface,
with the Vulkan and DXGI format numbers of the result. It can split an
image into bands of block rows and encode them on several threads through
`std.Io`; the bytes are the same however the work is split:

```zig
const encoding: bcn.Encoding = .{ .bc7 = bcn.bc7.Params.init(.slow, true) };
const src: bcn.Source = .{ .unorm8 = bcn.Image(u8).init(rgba, width, height, 4) };
const blocks = try gpa.alloc(u8, encoding.encodedLen(width, height));
try bcn.encodeImageParallel(io, &encoding, src, blocks, 4); // 4 block rows per task
const vk_format = encoding.vulkanFormat(true).?; // VK_FORMAT_BC7_SRGB_BLOCK
```

`encodeImageRows` and each format's `encodeImageRows` and `decodeImageRows`
take a `bcn.BlockRows` band, for callers with their own job system.

## Format specifics

- **BC1 and BC3** take `Settings{ .quality, .rounding }`. `rounding = .biased`
  aims at decoders that interpolate with a rounding bias (NVIDIA and Intel
  GPUs of about 2010); the default follows the specification.
  `bc1.encodeImage` ignores alpha; `bc1.encodeBlock` behaves exactly as
  stb_dxt, which wants a constant alpha in the block.
- **BC4 and BC5** encode channel 0, or channels 0 and 1, of an image with
  any number of channels. `bc4.decodeBlockSnorm` and `bc5.decodeBlockSnorm`
  decode signed (BC4_SNORM, BC5_SNORM) blocks to `i8` from -127 to 127
  (an endpoint of -128 decodes as -127, as both mean -1, while the entries
  between take it as -128, as texcomp's do); `bc5.decodeImageSnorm` writes
  them as bytes in the normal-map convention, where a byte u stands for
  2u / 255 − 1, as texcomp does. zig-bcn has no SNORM encoder.
- **BC7** takes `Params`, an `extern struct` with bc7e's exact layout:
  `Params.init(level, perceptual)` gives bc7e's presets, and any field can be
  changed after. `encodeBlockReportingLut` also returns bc7e's flag for
  blocks that used its single-colour tables, and `encodeBlockSingleMode`
  encodes in one chosen mode, partition, rotation and index selector,
  returning the error measure too. `decodeImageF32` and `decodeBlockF32`
  decode to floats from 0 to 1 (each byte divided by 255), into RGBA, or
  RGB with 3 channels; through `bcn.decodeImage`, pass a `.float32`
  destination.
- **BC6H** takes `f32` RGB (3 or more channels) and `Format.unsigned` or
  `.signed`. `encodeBlock` and `encodeImage` are texcomp's encoder;
  `encodeBlockQuality` and `encodeImageQuality` take `Quality.fast` (the
  same) or `.high`, zig-bcn's own encoder, for shipped assets (see
  [`bc6h-quality.md`](bc6h-quality.md)); through `bcn.Encoding`, `.{ .bc6h = .{ .quality = .high } }`.
  `decodeImage` writes half-float bits (`u16`),
  `decodeImageF32` floats; `floatToHalfBits` and `halfToF32` convert.

## Choosing a BC6H quality

`Quality.fast` is texcomp's encoder, with its output. It is close to
DirectXTex on photographs, weaker on flat and smooth HDR content such as
skies and light sources, and it flushes values below 2^-14 to zero, as
texcomp does. `Quality.high` searches every mode and scores each candidate
by the exact error of what decodes, at a lower speed. The measurements are
in [`bc6h-quality.md`](bc6h-quality.md).
