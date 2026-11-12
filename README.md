# zig-bcn

Ported from stb_dxt 1.12 (`2c980bb`), bc7e from basis_universal v2_50
(`9bebe16`) and texcomp from TinyEXR (`644148d`) · Zig 0.17.0 · [status](STATUS.md)

This port is not affiliated with or reviewed by the original authors. Its
code was written with AI assistance for Farhollow Games, and is only machine
verified. See [the tests](doc/TESTING.md) and [parity with the original](doc/parity.md).

## What it is

A Zig port of three block-compression (BCn) texture encoders: stb_dxt for
BC1, BC3, BC4 and BC5, the scalar bc7e from basis_universal for BC7, and
texcomp from TinyEXR for BC6H. It adds a decoder for every format and a
second BC6H encoder of its own. It is pure Zig, with no dependencies beyond
the standard library, and links no libc or libc++. The originals are listed
under [References](#references).

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
- Nothing allocates: the caller passes the output buffer.

## Install

```sh
zig fetch --save git+https://github.com/farhollowgames/zig-bcn#v0.3.0
```

`v0.3.0` is the latest release. The package needs Zig 0.17.0.

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

Each format has its namespace (`bcn.bc1`, `bcn.bc3`, `bcn.bc4`, `bcn.bc5`,
`bcn.bc7`, `bcn.bc6h`). [`doc/API.md`](doc/API.md) describes the API of each
format and of `bcn.Encoding`, and [`STATUS.md`](STATUS.md) maps every
function and option of the originals to its counterpart.

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

## Left out

The parts of the originals that are left out, each with its reason, are
listed in [`STATUS.md`](STATUS.md#left-out-approved). In short:

- C linkage and configuration macros (`STB_DXT_STATIC`, `STBD_FABS`,
  `STB_DXT_IMPLEMENTATION`), `BC7E_NON_DETERMINISTIC` (0 in the original,
  and so in the port) and the unused `HERE()` debug macro.
- texcomp's kernel dispatch (`tc_backend_*`): zig-bcn has one search.
- texcomp's DDS writers, and its encoders for other formats than the ones
  chosen (its BC1, BC3, BC5 and BC7 encoders, ETC2, EAC, ASTC and the
  rest).
- texcomp's `TC_ERROR_INVALID_ARGUMENT`: zig-bcn asserts instead, since
  slices carry their lengths.

## Tests

`zig build test` runs 61 tests: 15 unit tests and 46 tests that build the
originals from `reference/`. Most of the 46 run the original and the port
on the same inputs and compare every output byte, error measure and flag;
`bc6h.Quality.high`, which has no original, is checked against what its
blocks decode to.

- [`doc/TESTING.md`](doc/TESTING.md): how the tests compare the port with
  the originals, and what this repository's tests cover.
- [`doc/parity.md`](doc/parity.md): which test checks each feature of the
  originals, and on what inputs.

## Speed

Port time against original time, one thread, over every block of the test
image set:

| feature | time, port / original | port vs original |
| --- | ---: | ---: |
| BC1 encode, normal | 0.87 | 13% faster |
| BC7 encode, basic | 1.30 | 30% slower |
| BC6H encode, unsigned | 0.63 | 37% faster |
| BC7 decode | 0.45 | 55% faster |
| BC6H decode, unsigned | 0.40 | 60% faster |

The BC7 encoder is slower than bc7e at every level, by 18% to 30%.

AMD Ryzen 9 9950X3D, one thread, Linux 7.3, Zig 0.17.0 ReleaseFast against
Zig's clang `-O3`, at commit `3ee9b14`; each row is from the run with the
median time ratio of three; a load average of 2.3 to 3.0 on 32 hardware
threads.

- [`doc/BENCHMARKS.md`](doc/BENCHMARKS.md): every row, the flags on both
  sides, the run counts and the command.

## Licence

Apache License 2.0 ([`LICENSE`](LICENSE)), the licence of bc7e and texcomp;
stb_dxt, offered as MIT or public domain, is used under the MIT License.
zig-bcn is an altered version of the originals: the code is rewritten in
Zig, with its own interface. [`NOTICE`](NOTICE) holds "Copyright 2026
Farhollow Games" and the originals' copyright notices and licence texts,
copied as they are.

## References

- **stb_dxt** 1.12 (`2c980bb`), by Fabian "ryg" Giesen, ported to C by Sean
  Barrett, in [stb](https://github.com/nothings/stb). MIT or public domain.
  Copyright (c) 2017 Sean Barrett.
- **bc7e**, by Richard Geldreich, as ported to scalar C++ in
  [basis_universal](https://github.com/BinomialLLC/basis_universal) by
  Binomial LLC, tag `v2_50` (`9bebe16`). Apache License 2.0. Copyright (C)
  2018-2020 Binomial LLC; Copyright 2019-2026 Binomial LLC.
- **texcomp**, in [TinyEXR](https://github.com/syoyo/tinyexr) by Syoyo
  Fujita and the TinyEXR authors, commit `644148d`. Apache License 2.0.
  Copyright 2014-2026 Syoyo Fujita and TinyEXR authors. Its BC6H partition
  table and block layout mirror [bcdec](https://github.com/iOrange/bcdec) by
  Sergii Kudlai (MIT or the Unlicense), Copyright (c) 2022 Sergii Kudlai.
- The three originals are copied into `reference/` for the tests and the
  benchmark only.
- The formats are specified in the Khronos
  [Data Format Specification](https://registry.khronos.org/DataFormat/specs/1.3/dataformat.1.3.html)
  (S3TC, RGTC and BPTC).

Made by Farhollow Games for the Loomwork Engine.
