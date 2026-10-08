# Feature parity with the originals

zig-bcn aims to do everything its originals do, with identical output. This
file lists every public function, option and build-time switch of each
original, what corresponds to it in zig-bcn, and the test that shows they
give the same bytes. The tests are in `test/` and run with `zig build test`;
a "differential" test runs the original C or C++ from `reference/` on the
same input and requires identical output.

`doc/coverage.md` adds a second check: that these tests reach every line
and branch of the translated code.

## stb_dxt.h v1.12 (BC1, BC3, BC4, BC5)

| original | zig-bcn | test |
| --- | --- | --- |
| `stb_compress_dxt_block(dest, src, alpha = 0, mode)` | `bc1.encodeBlock(pixels, settings)` | differential: 14 images and 200,000 crafted blocks, including varying alpha, all settings (`test/stb_dxt_test.zig`) |
| `stb_compress_dxt_block(dest, src, alpha = 1, mode)` | `bc3.encodeBlock(pixels, settings)` | differential: the same images and crafted blocks |
| `mode`: `STB_DXT_NORMAL`, `STB_DXT_HIGHQUAL` | `Settings.quality`: `.normal`, `.high` | differential, both values |
| `mode`: `STB_DXT_DITHER` (deprecated in v1.11: "does nothing") | no option, since it has no effect | differential: modes 1 and 3 give the same bytes as 0 and 2 |
| `stb_compress_bc4_block` | `bc4.encodeBlock` | differential: every channel of every image, crafted blocks |
| `stb_compress_bc5_block` | `bc5.encodeBlock` | differential: both channel pairs of every image, crafted blocks |
| `#define STB_DXT_USE_ROUNDING_BIAS` | `Settings.rounding = .biased` | differential against a second reference build with the define |
| `#define STB_DXT_GENERATE_TABLES` (table generator program) | `generateOMatch` in `src/stb_dxt.zig` | regenerates both single-colour tables and compares them with the embedded ones |
| `STB_DXT_STATIC`, `STBD_FABS`, `STB_DXT_IMPLEMENTATION` | not applicable: C linkage and libm configuration | |

Added in zig-bcn, beyond stb_dxt: whole-image `encodeImage` for each format
(edge blocks repeat the last row and column), and decoders for BC1, BC3, BC4
and BC5 (block and image), checked byte for byte against texcomp's decoders
on random blocks and streams.

## basisu_bc7e_scalar (BC7)

In progress on the `bc7` branch.

## texcomp BC6H (TinyEXR `tools/texcomp`, commit 644148d)

The BC6H encoder of `texcomp_bc6h.c` and the decoder of
`texcomp_bc6h_decode.c`. The reference builds texcomp with `-fwrapv`: its
selector error sums overflow `int32` (undefined behaviour in C), and
optimizers that exploit it change which blocks win, so without it the
original's own output depends on the compiler (doc/coverage.md, BC6H).

| original | zig-bcn | test (`test/bc6h_test.zig`) |
| --- | --- | --- |
| `tc_bc6h_compress_rgb32f(rgb, w, h, stride_bytes, opt, out, size)` | `bc6h.encodeImage(src, dst, format)` | differential: 8 HDR images, both formats, under texcomp's AVX2, SSE4.1 and scalar selector kernels; a 13×9 window read with a wider stride |
| `tc_bc6h_options.signed_float` | `Format`: `.unsigned` (BC6H_UF16), `.signed` (BC6H_SF16) | differential, both values, and `opt = NULL` (unsigned) |
| `tc_bc6h_options.reserved` | none: texcomp never reads it | |
| `tc_bc6h_options_init` | none needed: `Format` is a plain argument | the reference calls it, with an options struct and with `NULL` |
| `tc_bc6h_compressed_size` | `encodedLen(16, w, h)` | differential for every size from 1×1 to 69×69. texcomp returns 0 for a zero width or height; zig-bcn asserts sizes are positive |
| `tc_float_to_half_bits` (public in texcomp) | `bc6h.floatToHalfBits` | differential on all 2^32 float bit patterns |
| the block encoders `tc_encode_bc6h_block_uf16`, `_sf16` (internal) | `bc6h.encodeBlock(pixels, format)` | differential: 20,000 fuzz blocks and 847 coverage-guided fuzzing blocks, both formats, all three kernels |
| every mode encoder (internal): modes 0, 1, 2–4, 5, 6–8, 9, 10, 12, 13 unsigned; 0, 1, 2–4, 5, 6–8, 9, 12, 13 signed | `bc6h.texcomp.encodeMode(signed, mode, pixels, out)` | differential on the same blocks, called directly, so every mode's block and its error estimate are compared whether or not it wins |
| `tc_bc6h_decompress_rgb16f(blocks, w, h, is_signed, stride_bytes, out, size)` | `bc6h.decodeImage(src, dst, format)` (half bits) | differential on every encoded image, 200,000 random blocks of both formats (all 14 modes and the reserved codes), and padded rows |
| `tc_bc6h_decompress_rgbaf` (float RGBA, alpha 1) | `bc6h.decodeImageF32(src, dst, format)` with 4 channels (3 gives RGB) | differential, f32 bits compared, on every encoded image and padded rows |
| `tc_bc6h_decode_block_half` (internal) | `bc6h.decodeBlock(block, format)` | differential on the random blocks |
| the SSE4.1, AVX2 and NEON selector kernels | not translated: they are bit-identical to the scalar search, which is | the differential tests run the original under all three x86 kernels against one port |
| `tc_dds_bc6h_size`, `tc_dds_write_bc6h_memory` (texcomp.c) | none: they write a DDS container around the blocks, outside a codec's scope; Loomwork's bake tool writes its own containers | |
| argument errors (`TC_ERROR_INVALID_ARGUMENT` for null pointers, zero sizes, short strides or buffers) | asserted instead: slices carry their lengths | |

Behaviour kept from the original, because the output must match:
`tc_float_to_half_bits` flushes every value below 2^-14 to signed zero (its
subnormal branch shifts twice); and several mode packers write fields their
decode does not read as the search assumed, so those blocks decode worse than
the encoder's estimate (mode 0, signed modes 6–8 and signed mode 12 most of
the time). doc/bc6h-quality.md measures what that costs.
