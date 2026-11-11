# Port status

Every public function, option, mode and build switch of the pinned
originals, with its state:

- **not started**: nothing in zig-bcn yet;
- **ported**: translated, with no test against the original;
- **oracle-tested**: the original runs on the same inputs in `zig build test`
  and every output byte and returned value matches;
- **benchmarked**: oracle-tested, and timed against the original by
  `zig build bench` (see `doc/BENCHMARKS.md`);
- **reviewed**: through the performance pass, the skeptic and the fixes,
  and released. Every row not left out is reviewed; the state after "reviewed"
  is the furthest its tests and the benchmark go.

The pinned originals are vendored in `reference/` (see
`reference/README.md`): stb_dxt v1.12 (`2c980bb`), basis_universal `v2_50`
(`9bebe16`) for bc7e, and TinyEXR `644148d` for texcomp. `doc/parity.md`
says which test compares each item and on what inputs.

## stb_dxt.h (BC1, BC3, BC4, BC5)

| original | zig-bcn | state |
| --- | --- | --- |
| `stb_compress_dxt_block(dest, src, alpha = 0, mode)` | `bc1.encodeBlock`, `bc1.encodeImage` | reviewed, benchmarked |
| `stb_compress_dxt_block(dest, src, alpha = 1, mode)` | `bc3.encodeBlock`, `bc3.encodeImage` | reviewed, benchmarked |
| `stb_compress_bc4_block` | `bc4.encodeBlock`, `bc4.encodeImage` | reviewed, benchmarked |
| `stb_compress_bc5_block` | `bc5.encodeBlock`, `bc5.encodeImage` | reviewed, benchmarked |
| mode `STB_DXT_NORMAL`, `STB_DXT_HIGHQUAL` | `Settings.quality` `.normal`, `.high` | reviewed, benchmarked |
| mode `STB_DXT_DITHER` (deprecated: "does nothing") | no option | reviewed, oracle-tested: modes 1 and 3 give the bytes of 0 and 2 |
| `STB_DXT_USE_ROUNDING_BIAS` | `Settings.rounding = .biased` | reviewed, benchmarked |
| `STB_DXT_GENERATE_TABLES` | `generateOMatch` | reviewed, oracle-tested: regenerates both tables |
| `STB_DXT_STATIC`, `STBD_FABS`, `STB_DXT_IMPLEMENTATION` | left out: C linkage and libm configuration | |

## basisu_bc7e_scalar (BC7)

| original | zig-bcn | state |
| --- | --- | --- |
| `bc7e_compress_block_init` | none needed: tables built at compile time | reviewed, oracle-tested through the encoder: the differential tests reach every entry it reads; a unit test checks the tables against a translation of the original's build |
| `bc7e_compress_block_params_init` (base settings) | `Params.initDefaults` | reviewed, oracle-tested |
| `..._init_ultrafast` to `..._init_slowest` (7 levels) | `Params.init(level, perceptual)` | reviewed, benchmarked (all 7, perceptual; `basic` linear too) |
| `bc7e_compress_block_params` and every field | `Params` (`extern struct`, same layout) | reviewed, oracle-tested: every field on more than one value |
| `bc7e_compress_blocks(n, blocks, pixels, params, used_lut)` | `bc7.encodeBlock`, `bc7.encodeImage` | reviewed, benchmarked |
| `pUsed_lut` | `bc7.encodeBlockReportingLut` | reviewed, oracle-tested |
| `bc7e_compress_block_single_mode` | `bc7.encodeBlockSingleMode` | reviewed, oracle-tested: blocks and errors, every mode, partition, rotation and index selector |
| `BC7E_NON_DETERMINISTIC` | left out: hard-coded to 0 in the original; the port is that value | |
| `HERE()` debug macro | left out: unused in the original | |
| `BC7E_*` constants | same constants | reviewed, ported |

## texcomp (BC6H, and the decoders zig-bcn is checked against)

zig-bcn ports texcomp's BC6H encoder and decoder. texcomp's other codecs
are not ported: stb_dxt and bc7e are the BC1 to BC5 and BC7 encoders, and
texcomp's BC1, BC3, BC4, BC5 and BC7 decoders are the oracle for zig-bcn's
own decoders.

| original | zig-bcn | state |
| --- | --- | --- |
| `tc_bc6h_compress_rgb32f` | `bc6h.encodeImage` | reviewed, benchmarked (as its block encoder) |
| block encoders `tc_encode_bc6h_block_uf16`, `_sf16` | `bc6h.encodeBlock` | reviewed, benchmarked |
| every mode encoder, both formats | `bc6h.texcomp.encodeMode` | reviewed, oracle-tested: blocks and error estimates |
| `tc_bc6h_options.signed_float`, `opt = NULL` | `Format` | reviewed, benchmarked (both formats) |
| `tc_bc6h_options_init` | none needed: `Format` is an argument | reviewed, oracle-tested |
| `tc_bc6h_compressed_size` | `encodedLen(16, w, h)` | reviewed, oracle-tested, 1x1 to 69x69 |
| `tc_float_to_half_bits` | `bc6h.floatToHalfBits` | reviewed, oracle-tested on all 2^32 floats |
| `tc_bc6h_decompress_rgb16f` | `bc6h.decodeImage` | reviewed, benchmarked |
| `tc_bc6h_decompress_rgbaf` | `bc6h.decodeImageF32` | reviewed, oracle-tested |
| `tc_bc6h_decode_block_half` | `bc6h.decodeBlock` | reviewed, benchmarked |
| SSE4.1, AVX2 and NEON selector kernels | the scalar search, run on vectors | reviewed, oracle-tested: the original under every x86 kernel |
| `tc_backend_*` (kernel dispatch) | left out: zig-bcn has one search | |
| `tc_bc6h_options.reserved` | left out: texcomp never reads it | |
| `tc_dds_bc6h_size`, `tc_dds_write_bc6h_memory` | left out: DDS containers are outside a codec | |
| `tc_bc1_decompress_rgba8`, `tc_bc3_decompress_rgba8` | `bc1.decodeImage`, `bc3.decodeImage` (zig-bcn's own) | reviewed, benchmarked |
| `tc_decode_bc4_block` | `bc4.decodeBlock` (zig-bcn's own) | reviewed, benchmarked |
| `tc_bc5_decompress_rgba8`, unsigned | `bc5.decodeImage` (zig-bcn's own; writes R and G only) | reviewed, benchmarked |
| `tc_decode_bc4_block_snorm` | `bc4.decodeBlockSnorm`, and `bc5.decodeBlockSnorm` for both halves (zig-bcn's own) | reviewed, oracle-tested: every endpoint pair, -128 included, and 50,000 random and edge blocks; timed through `bc5.decodeImageSnorm` |
| `tc_bc5_decompress_rgba8`, signed (`snorm = 1`) | `bc5.decodeImageSnorm` (zig-bcn's own; writes R and G only) | reviewed, benchmarked |
| `tc_bc7_decompress_rgba8` | `bc7.decodeImage` (zig-bcn's own) | reviewed, benchmarked |
| `tc_bc7_decompress_rgbaf` | `bc7.decodeImageF32`, `bc7.decodeBlockF32` (zig-bcn's own; RGBA, or RGB with 3 channels) | reviewed, benchmarked |
| texcomp's BC1, BC3, BC5 and BC7 encoders, ETC2, EAC, ASTC, the `uni` format and transcoders, and the other DDS writers | left out: other encoders or formats than the ones chosen | |

## zig-bcn's own

| feature | state |
| --- | --- |
| `bc6h.Quality.high` encoder (`src/bc6h_high.zig`) | reviewed, benchmarked; no original, so its tests check what it decodes to (`test/bc6h_high_test.zig`) |
| `bcn.Encoding`: one call, row bands, threads | reviewed, tested: the format functions' bytes, in bands, on 1, 2 and 8 threads |

## Left out (approved)

- Every row above marked "left out", with its reason.
- Argument errors: texcomp returns `TC_ERROR_INVALID_ARGUMENT` for null
  pointers, zero sizes and short strides or buffers; zig-bcn asserts
  instead, since slices carry their lengths. A caller passing a short
  buffer gets a panic in Debug and ReleaseSafe and undefined behaviour in
  ReleaseFast, not an error.
- The originals are vendored in `reference/`, not fetched as a lazy
  dependency in `build.zig.zon`.

## BC5 SNORM and BC7 float decoders: differences from texcomp

Approved by the author. Every byte and float these decoders write equals
texcomp's, except where this list says otherwise.

Output:

- `bc5.decodeImageSnorm` writes red and green only. texcomp's
  `tc_bc5_decompress_rgba8` also writes blue 0 and alpha 255, which
  zig-bcn's unsigned BC5 decoder leaves out too.
- `bc5.decodeImageSnorm` takes images of 2, 3 or 4 channels, and
  `bc7.decodeImageF32` RGB images (3 channels) as well as RGBA, dropping
  alpha. texcomp writes RGBA only.
- `bc4.decodeBlockSnorm` and `bc5.decodeBlockSnorm` give signed values;
  only the image decoder converts them to bytes. texcomp has a signed BC4
  block decoder but no BC5 one: `bc5.decodeBlockSnorm` gives what
  `tc_decode_bc4_block_snorm` gives for each half.
- `bc7.decodeBlockF32` has no texcomp counterpart: texcomp converts to
  floats only for whole images. It gives `tc_bc7_decompress_rgbaf`'s floats
  for a 4 x 4 image.
- `bcn.Encoding` has no BC5 SNORM variant, since zig-bcn has no SNORM
  encoder (stb_dxt has none; texcomp's is one of the encoders left out).

Arguments and errors:

- `tc_bc7_decompress_rgbaf` allocates a byte image for each call and
  returns `TC_ERROR_OUT_OF_MEMORY` when that fails. `bc7.decodeImageF32`
  allocates nothing and has no such error.
- `tc_bc7_decompress_rgbaf` takes its row stride in bytes and checks
  neither the stride nor the buffer against it, only that the buffer holds
  `width * height` packed RGBA floats. A stride under a row overlaps the
  rows, and one that is not a multiple of 4 stores misaligned floats.
  zig-bcn's stride counts floats, so it is always aligned, and the
  decoder asserts that rows do not overlap and that the buffer holds the
  last row.
- The other argument checks are asserted, as for every decoder (above).

Source:

- texcomp converts a signed value to a byte in `f32` (`tc_snorm8_to_unorm8`);
  zig-bcn computes (s + 127) * 255 / 254 rounded half up in integer lanes.
  The bytes are the same for all 255 values, which the tests reach; the
  original's three clamps never act, since its caller has already clamped
  the value to -127 to 127, and are not ported.
- texcomp decodes the whole BC7 image to bytes, then divides each by 255.
  zig-bcn divides each block's lanes as it decodes them, with the same
  `f32` division, so the floats are the same bits.
