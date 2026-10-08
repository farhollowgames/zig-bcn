# zig-bcn

BC1–BC7 and BC6H texture compression in pure Zig.

zig-bcn encodes and decodes the block-compressed texture formats that every
desktop GPU samples directly. Its encoders are translations of three proven
open-source encoders, and tests show that they produce **the same bytes as
the originals**. It has no dependencies beyond Zig's standard library, links
no libc or libc++, and never allocates: you pass the output buffer.

| format | for | encoder | settings |
| --- | --- | --- | --- |
| BC1 | opaque RGB, 4 bits per pixel | stb_dxt | quality `normal` or `high`; rounding `spec` or `biased` |
| BC3 | RGB plus alpha, 8 bpp | stb_dxt | as BC1 |
| BC4 | one channel (masks, roughness), 4 bpp | stb_dxt | none |
| BC5 | two channels (tangent-space normals), 8 bpp | stb_dxt | none |
| BC7 | high-quality RGB or RGBA, 8 bpp | bc7e (basis_universal's scalar port) | seven levels from `ultrafast` to `slowest`, perceptual or linear error, and every bc7e parameter |
| BC6H | HDR RGB half floats, unsigned or signed, 8 bpp | texcomp (TinyEXR) | `unsigned` or `signed` |

Every format also has a decoder, written for zig-bcn and checked byte for
byte against texcomp's decoders.

Requires Zig 0.17.0.

## Use

Add the package:

```sh
zig fetch --save git+https://github.com/farhollowgames/zig-bcn#v0.1.0
```

and import its module in `build.zig`:

```zig
const bcn = b.dependency("bcn", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("bcn", bcn.module("bcn"));
```

Encode an RGBA8 image to BC7 and decode it again:

```zig
const std = @import("std");
const bcn = @import("bcn");

pub fn roundTrip(gpa: std.mem.Allocator, rgba: []const u8, width: u32, height: u32) ![]u8 {
    const src = bcn.Image(u8).init(rgba, width, height, 4);

    const blocks = try gpa.alloc(u8, bcn.encodedLen(bcn.bc7.block_bytes, width, height));
    defer gpa.free(blocks);
    const params = bcn.bc7.Params.init(.basic, true); // perceptual: for colour, not normals
    bcn.bc7.encodeImage(src, blocks, &params);

    const decoded = try gpa.alloc(u8, rgba.len);
    bcn.bc7.decodeImage(blocks, bcn.ImageMut(u8).init(decoded, width, height, 4));
    return decoded;
}
```

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

Format specifics:

- **BC1 and BC3** take `Settings{ .quality, .rounding }`. `rounding = .biased`
  aims at decoders that interpolate with a rounding bias (NVIDIA and Intel
  GPUs of about 2010); the default follows the specification.
  `bc1.encodeImage` ignores alpha; `bc1.encodeBlock` behaves exactly as
  stb_dxt, which wants a constant alpha in the block.
- **BC4 and BC5** encode channel 0, or channels 0 and 1, of an image with
  any number of channels.
- **BC7** takes `Params`, an `extern struct` with bc7e's exact layout:
  `Params.init(level, perceptual)` gives bc7e's presets, and any field can be
  changed after. `encodeBlockReportingLut` also returns bc7e's flag for
  blocks that used its single-colour tables, and `encodeBlockSingleMode`
  encodes in one chosen mode, partition, rotation and index selector,
  returning the error measure too.
- **BC6H** takes `f32` RGB (3 or more channels) and `Format.unsigned` or
  `.signed`. `decodeImage` writes half-float bits (`u16`),
  `decodeImageF32` floats; `floatToHalfBits` and `halfToF32` convert.

## How the tests prove equivalence

`zig build test` builds the original C and C++ from `reference/` (test-only
code, never part of the package) and runs them on the same inputs as the
Zig. Every output must be identical: encoded blocks, error measures, flags
and decoded pixels. The inputs are a fixed, procedurally generated image
set (flat colour, gradients, hard and soft alpha, noise, normal maps,
few-colour blocks, extremes, and HDR ranges with infinities and NaN) at
every setting, plus hundreds of thousands of crafted and fuzzed blocks
aimed at paths images rarely reach.

- [`doc/parity.md`](doc/parity.md) maps every public function, option and
  build switch of each original to its Zig counterpart and the test that
  compares them.
- [`doc/coverage.md`](doc/coverage.md) records a coverage run of the
  originals under those tests: every function of stb_dxt and texcomp's
  BC6H, and every line and branch of stb_dxt. The few unreached lines and
  branches are declared with their reasons, and a build with undefined
  behaviour trapping passed as well. Rerun it with `zig build coverage`
  (needs clang and llvm-cov).
- Both sides are built with fused multiply-add off, so float steps round as
  written. texcomp's BC6H error sums overflow `int32`; the reference is
  built with `-fwrapv`, and the port computes that wrapped result, which
  stays the same across compilers.

## Quality and speed

The encoders keep their originals' quality and speed. The BC7 port runs at
1.0 to 1.25 times the scalar C++'s time per block. The BC6H port runs at
the speed of texcomp's scalar C (texcomp's AVX2 build is about 2.7 times
faster).

texcomp's BC6H is fast, about 12 megapixels a second on one core, and close
to Microsoft's DirectXTex on photographs (43.9 against 45.4 dB mPSNR). It is
weaker on flat and smooth HDR content such as skies and light sources, and
it flushes values below 2^-14 to zero. See
[`doc/bc6h-quality.md`](doc/bc6h-quality.md).

## Licence and credits

Apache License 2.0 ([`LICENSE`](LICENSE)); see [`NOTICE`](NOTICE).

- BC1, BC3, BC4 and BC5: translated from
  [stb_dxt](https://github.com/nothings/stb) by Fabian Giesen and Sean
  Barrett (MIT or public domain).
- BC7: translated from bc7e's scalar port in
  [basis_universal](https://github.com/BinomialLLC/basis_universal) by
  Binomial LLC (Apache 2.0).
- BC6H: translated from texcomp in
  [TinyEXR](https://github.com/syoyo/tinyexr) by Syoyo Fujita and the
  TinyEXR authors (Apache 2.0), which mirrors tables from Sergii Kudlai's
  [bcdec](https://github.com/iOrange/bcdec) (MIT).

Made by Farhollow Games for the Loomwork Engine.
