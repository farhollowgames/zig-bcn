# zig-bcn

Tracks stb_dxt 1.12, bc7e from basis_universal v2_50 and texcomp from TinyEXR
`644148d` · Zig 0.17 · [status](STATUS.md)

## What it is

A Zig port of three block-compression (BCn) texture encoders: stb_dxt for
BC1, BC3, BC4 and BC5, the scalar bc7e from basis_universal for BC7, and
texcomp from TinyEXR for BC6H. It adds a decoder for every format and a
second BC6H encoder of its own. The originals and their authors are listed
under [Licence and references](#licence-and-references).

This port is not affiliated with or reviewed by the original authors. Its
code was written with AI assistance for Farhollow Games, and is only machine
verified. See [the tests](doc/TESTING.md) and [parity with the original](doc/parity.md).

## Features

| format | for | encoder | settings |
| --- | --- | --- | --- |
| BC1 | opaque RGB, 4 bits per pixel | stb_dxt | quality `normal` or `high`; rounding `spec` or `biased` |
| BC3 | RGB plus alpha, 8 bpp | stb_dxt | as BC1 |
| BC4 | one channel (masks, roughness), 4 bpp | stb_dxt | none |
| BC5 | two channels (tangent-space normals), 8 bpp | stb_dxt | none |
| BC7 | RGB or RGBA, 8 bpp | bc7e | seven levels from `ultrafast` to `slowest`, perceptual or linear error, and every bc7e parameter |
| BC6H | HDR RGB half floats, unsigned or signed, 8 bpp | texcomp, or zig-bcn's own search | `unsigned` or `signed`; quality `fast` (texcomp) or `high` |

- A decoder for every format. BC4 and BC5 also decode signed (SNORM)
  blocks, BC7 also decodes to floats, and BC6H to half bits or floats.
- Image views with a row stride and 1 to 4 channels, so a view can cover
  part of a larger image.
- `bcn.Encoding`: every format and its settings behind one interface, with
  the Vulkan and DXGI format numbers, and encoding in bands of block rows on
  several threads through `std.Io`.
- Pure Zig, with no libc or libc++. Nothing allocates: the caller passes the
  output buffer.

## Install

```sh
zig fetch --save git+https://github.com/farhollowgames/zig-bcn#v0.3.0
```

`v0.3.0` is the latest release.

In `build.zig`:

```zig
const bcn = b.dependency("bcn", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("bcn", bcn.module("bcn"));
```

## Use

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

[`doc/API.md`](doc/API.md) describes the API of each format and of
`bcn.Encoding`.

## Differences from the original

The reasons are in [`doc/parity.md`](doc/parity.md) and
[`STATUS.md`](STATUS.md#bc5-snorm-and-bc7-float-decoders-differences-from-texcomp).

*Additions*:

- Decoders for every format, written for zig-bcn and compared with texcomp's.
- `bc6h.Quality.high`, a BC6H encoder of zig-bcn's own ([`doc/bc6h-quality.md`](doc/bc6h-quality.md)).
- `encodeImage` for every format; stb_dxt encodes single blocks, and bc7e arrays of blocks.
- `bcn.Encoding`, row bands and parallel encoding.
- `bc5.decodeBlockSnorm` and `bc7.decodeBlockF32`; texcomp has these only for BC4 or for whole images.

*Changes to expect*:

- Argument errors are asserted, not returned: a short buffer or stride panics in Debug and ReleaseSafe and is undefined in ReleaseFast.
- `bc7.decodeImageF32` allocates nothing and has no out-of-memory error; texcomp allocates for each call.
- Strides count elements (floats for `decodeImageF32`), not bytes, and are asserted against the buffer.
- The BC5 decoders write red and green only; texcomp also writes blue 0 and alpha 255.
- SNORM -128 is handled as texcomp does: an endpoint of -128 decodes as -127, and the entries between take it as -128.
- stb_dxt's mode flags and `STB_DXT_USE_ROUNDING_BIAS` are `Settings` fields; `STB_DXT_DITHER`, which does nothing in 1.12, has no option.
- bc7e's tables are built at compile time, so there is no `bc7e_compress_block_init`.
- texcomp's options struct is a `Format` argument; a zero width or height is asserted, where texcomp returns size 0.

## Not included

The parts of the originals that are left out, each with its reason, are listed in
[`STATUS.md`](STATUS.md#left-out-approved).

## Testing and benchmarks

`zig build test` runs 61 tests: 15 unit tests and 46 tests that build the
originals from `reference/`. Most of the 46 run the original and the port
on the same inputs and compare every output byte, error measure and flag;
`bc6h.Quality.high`, which has no original, is checked against what its
blocks decode to.

Port time against original time, one thread:

| feature | port vs original |
| --- | ---: |
| BC1 encode, normal | 13% faster |
| BC7 encode, basic | 30% slower |
| BC6H encode, unsigned | 37% faster |
| BC7 decode | 55% faster |
| BC6H decode, unsigned | 60% faster |

AMD Ryzen 9 9950X3D, Linux 7.3, Zig 0.17.0, at commit `3ee9b14`, with a
load average of 2.3 to 3.0 on 32 hardware threads; the median of three
runs.

- [`doc/TESTING.md`](doc/TESTING.md): how the tests compare the port with
  the originals, and what this repository's tests cover.
- [`doc/BENCHMARKS.md`](doc/BENCHMARKS.md): ratios and full tables: every row, the flags on both
  sides, the run counts and the command.

## Licence and references

zig-bcn is licensed under the Apache License 2.0 ([`LICENSE`](LICENSE)),
Copyright 2026 Farhollow Games. [`NOTICE`](NOTICE) holds the originals'
copyright notices and licence texts, copied as they are:

- **stb_dxt** 1.12, by Fabian "ryg" Giesen, ported to C by Sean Barrett, in
  [stb](https://github.com/nothings/stb). MIT or public domain; used under
  the MIT License. Copyright (c) 2017 Sean Barrett.
- **bc7e**, by Richard Geldreich, as ported to scalar C++ in
  [basis_universal](https://github.com/BinomialLLC/basis_universal) by
  Binomial LLC. Apache License 2.0. Copyright (C) 2018-2020 Binomial LLC;
  Copyright 2019-2026 Binomial LLC.
- **texcomp**, in [TinyEXR](https://github.com/syoyo/tinyexr) by Syoyo
  Fujita and the TinyEXR authors. Apache License 2.0. Copyright 2014-2026
  Syoyo Fujita and TinyEXR authors. Its BC6H partition table and block
  layout mirror [bcdec](https://github.com/iOrange/bcdec) by Sergii Kudlai
  (MIT or the Unlicense), Copyright (c) 2022 Sergii Kudlai.
- The formats are specified in the Khronos
  [Data Format Specification](https://registry.khronos.org/DataFormat/specs/1.3/dataformat.1.3.html)
  (S3TC, RGTC and BPTC).

Made by Farhollow Games for the Loomwork Engine.
