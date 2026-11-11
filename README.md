# zig-bcn

BC1–BC7 and BC6H texture compression in pure Zig.

zig-bcn encodes and decodes the block-compressed texture formats that every
desktop GPU samples directly. Its encoders are translations of three proven
open-source encoders, and tests show that they produce **the same bytes as
[the originals](#licence-and-credits)**. It has no dependencies beyond Zig's standard library, links
no libc or libc++, and never allocates: you pass the output buffer.

| format | for | encoder | settings |
| --- | --- | --- | --- |
| BC1 | opaque RGB, 4 bits per pixel | stb_dxt | quality `normal` or `high`; rounding `spec` or `biased` |
| BC3 | RGB plus alpha, 8 bpp | stb_dxt | as BC1 |
| BC4 | one channel (masks, roughness), 4 bpp | stb_dxt | none |
| BC5 | two channels (tangent-space normals), 8 bpp | stb_dxt | none |
| BC7 | high-quality RGB or RGBA, 8 bpp | bc7e (basis_universal's scalar port) | seven levels from `ultrafast` to `slowest`, perceptual or linear error, and every bc7e parameter |
| BC6H | HDR RGB half floats, unsigned or signed, 8 bpp | texcomp (TinyEXR), and zig-bcn's own high-quality search | `unsigned` or `signed`; quality `fast` (texcomp) or `high` |

Every format also has a decoder, written for zig-bcn and checked byte for
byte against texcomp's decoders. BC4 and BC5 also decode signed (SNORM)
blocks, and BC7 also decodes to floats.

This port was written by Claude (Anthropic's AI model) for Farhollow Games.
How the code was verified can be found
[below](#how-the-tests-prove-equivalence).

Requires Zig 0.17.0.

## Use

Add the package:

```sh
zig fetch --save git+https://github.com/farhollowgames/zig-bcn#v0.2.0
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

Format specifics:

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
  same) or `.high`, zig-bcn's own encoder, for shipped assets (see Quality
  and speed); through `bcn.Encoding`, `.{ .bc6h = .{ .quality = .high } }`.
  `decodeImage` writes half-float bits (`u16`),
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

The encoders keep their originals' quality, and encoding in bands scales
with the cores (BC7 `basic` on a 1024 x 1024 image: 1.05 s on one thread,
62 ms on 32). On one core, every encoder and decoder runs about as fast
as its original or faster, except the BC7 encoder, at about four fifths of
bc7e's speed (see [Benchmark](#benchmark)).

texcomp's BC6H (`Quality.fast`) is fast, and close to Microsoft's
DirectXTex on photographs (43.9 against 45.4 dB mPSNR), but weaker on flat
and smooth HDR content such as skies and light sources, and it flushes
values below 2^-14 to zero.

`Quality.high` is zig-bcn's own BC6H encoder, not a translation: a search
over every mode, scored by the exact error of what decodes. It beats
DirectXTex on that photograph (46.0 dB) and matches or beats it on every
test image, flat and smooth HDR included, at about 0.5 megapixels a second
on one core, 25 times DirectXTex's speed. With no original to match, its
tests prove instead that every block decodes, in texcomp's decoder and
zig-bcn's, to exactly the error the encoder reported, and that it is never
worse than `.fast`. See [`doc/bc6h-quality.md`](doc/bc6h-quality.md).

## Benchmark

`zig build bench` times every encoder against its original and every decoder
against texcomp's, on one thread, on every block of the test image set
(2,688 RGBA and 1,536 HDR blocks), and checks that both write the same
bytes. The BC6H `simd` rows run texcomp with its AVX2 selector kernels, the
other BC6H rows with its scalar search. zig-bcn is built ReleaseFast and the
originals at `-O3`, both for the CPU they run on, the originals with the
flags their exact output needs (`-ffp-contract=off -fno-fast-math`, and
`-fwrapv` for texcomp). Each sample lasts at least 25 ms of the thread's CPU
time, after two warm-ups, and the two sides' samples alternate. A row gives
the median of 11 samples, the best of three rounds, in megapixels a second;
range is (slowest − fastest) / median.

```sh
zig build bench -- --rounds 3
```

AMD Ryzen 9 9950X3D, Linux 7.3, Zig 0.17.0 (`x86_64` `znver5`). The
numbers were taken while other builds ran on the machine, so absolute
speeds move by up to a fifth between runs; the ratios, from alternating
samples, move less. The `bc5 decode snorm` and `bc7 decode f32` rows were
taken later, on the same machine under load: each is the run with the
median ratio of three runs of
`zig build bench -- --filter decode --rounds 3`.

| feature | zig-bcn Mpix/s | range | original Mpix/s | range | zig-bcn / original |
| --- | ---: | ---: | ---: | ---: | ---: |
| bc1 encode normal | 166.07 | 5.9% | 144.53 | 1.5% | 1.15 |
| bc1 encode high | 147.65 | 18.6% | 127.76 | 2.8% | 1.16 |
| bc1 encode normal biased | 167.19 | 1.3% | 138.29 | 0.8% | 1.21 |
| bc3 encode normal | 121.79 | 4.8% | 111.69 | 2.6% | 1.09 |
| bc3 encode high | 110.34 | 6.5% | 99.65 | 3.2% | 1.11 |
| bc4 encode | 487.49 | 3.3% | 481.56 | 6.9% | 1.01 |
| bc5 encode | 232.63 | 1.4% | 242.49 | 3.8% | 0.96 |
| bc7 encode ultrafast | 8.39 | 0.9% | 10.41 | 1.3% | 0.81 |
| bc7 encode veryfast | 2.56 | 1.0% | 3.15 | 2.0% | 0.81 |
| bc7 encode fast | 2.57 | 4.4% | 3.17 | 3.0% | 0.81 |
| bc7 encode basic | 1.67 | 4.0% | 2.11 | 2.8% | 0.79 |
| bc7 encode basic linear | 0.97 | 1.1% | 1.15 | 0.7% | 0.85 |
| bc7 encode slow | 1.28 | 4.1% | 1.58 | 5.6% | 0.81 |
| bc7 encode veryslow | 0.35 | 3.2% | 0.42 | 1.6% | 0.82 |
| bc7 encode slowest | 0.27 | 0.7% | 0.32 | 1.2% | 0.84 |
| bc6h encode unsigned | 4.92 | 0.6% | 3.16 | 0.8% | 1.56 |
| bc6h encode signed | 3.38 | 2.1% | 2.90 | 2.9% | 1.17 |
| bc6h encode unsigned, texcomp simd | 4.86 | 1.4% | 3.08 | 2.6% | 1.58 |
| bc6h encode signed, texcomp simd | 3.26 | 3.6% | 2.69 | 3.2% | 1.21 |
| bc6h encode high unsigned | 0.66 | 0.3% | no original | | |
| bc6h encode high signed | 0.61 | 0.6% | no original | | |
| bc1 decode | 1825.88 | 1.1% | 1319.43 | 2.1% | 1.38 |
| bc3 decode | 1354.28 | 1.5% | 794.29 | 1.7% | 1.71 |
| bc4 decode | 6710.07 | 1.9% | 2602.34 | 2.1% | 2.58 |
| bc5 decode | 1245.02 | 6.2% | 972.02 | 2.8% | 1.28 |
| bc5 decode snorm | 821.96 | 1.0% | 600.58 | 0.9% | 1.37 |
| bc7 decode | 525.35 | 7.3% | 240.33 | 1.9% | 2.19 |
| bc7 decode f32 | 634.27 | 3.1% | 237.17 | 1.8% | 2.67 |
| bc6h decode unsigned | 740.69 | 3.7% | 297.71 | 0.9% | 2.49 |
| bc6h decode signed | 643.87 | 4.6% | 219.48 | 5.5% | 2.93 |

- **BC7 encoding is slower than bc7e,** at about four fifths of its speed.
  The time is spread over the translated search rather than one loop: its
  perceptual palette search, run on vectors, keeps every byte but gains
  nothing measurable.
- **BC6H** runs its selector search and partition boxes on vectors of the
  block's 16 texels, with the same integer arithmetic as texcomp's SIMD
  kernels. texcomp's own AVX2 kernels make no difference here: built for
  this CPU, its scalar search is vectorized by the compiler too.
- **The decoders** decode a block's 16 pixels at once, in vector lanes.
  texcomp's BC5 decoder writes blue and alpha as well; zig-bcn's writes
  red and green only. Its SNORM decoder turns signed values into bytes
  with integer lanes, which give exactly texcomp's float steps. texcomp's
  BC7 float decoder decodes the image to bytes in a buffer it allocates
  for each call, then converts them; zig-bcn converts each block's lanes.
- **The exactness flags** cost the originals little: built with fused
  multiply-add and without `-fwrapv`, they write different bytes, and only
  BC1 gets measurably faster (about a tenth).

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
