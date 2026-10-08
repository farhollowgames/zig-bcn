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

basis_universal v2_50, `encoder/basisu_bc7e_scalar.{h,cpp}`. Ported to
`src/bc7e.zig` with the original's function shapes (reachable as
`bc7.bc7e_api`); `src/bc7.zig` is the public API over it. Tests are in
`test/bc7_test.zig`, all differential unless noted, and compare every block
byte, used-LUT flag and returned error.

| original | zig-bcn | test |
| --- | --- | --- |
| `bc7e_compress_block_init()` | none needed: the single-colour tables are built at compile time | the tables equal a translation of the original's brute force build (unit test in `src/bc7e.zig`); every table entry the encoder reads is exercised by the solid, near-solid and mean-colour paths of the differential tests |
| `bc7e_compress_block_params_init(p, perceptual)` (base) | `Params.initDefaults(perceptual)` | the structs compare equal byte for byte, both metrics; 3,000 crafted blocks encoded with it, both metrics |
| `..._init_ultrafast`, `_veryfast`, `_fast`, `_basic`, `_slow`, `_veryslow`, `_slowest` | `Params.init(level, perceptual)` with `Level.ultrafast` … `.slowest` | byte-equal structs for all 7 × 2; 14 images and 3,000 crafted blocks at all 7 × 2 |
| `bc7e_compress_block_params` layout | `Params` (`extern struct`, 124 bytes, same field order) | size and bytes compared with the original's |
| `bc7e_compress_blocks(n, blocks, pixels, params, pUsed_lut = null)` | `bc7.encodeBlock(pixels, params)`; `bc7.encodeImage` for images | 14 images, crafted blocks, all settings; `encodeImage` output equals the original's batch on the same blocks |
| `pUsed_lut` | `bc7.encodeBlockReportingLut(...).used_lut`, or `bc7e_api.compressBlock(..., &flag)` | the flag compared for every block of every encoder test |
| batch state: one `color_cell_compressor_params` shared across the blocks of a call | each block starts from fresh state | the original encodes whole batches (an image, 3,000 or 2,688 blocks) and the port block by block; identical output shows no state carries over |
| `bc7e_compress_block_single_mode(block, pixels, params, mode, partition, rotation, index_selector)` | `bc7.encodeBlockSingleMode(pixels, params, .{ .mode, .partition, .rotation, .index_selector })` returning block and error; `bc7e_api.compressBlockSingleMode` with the original's argument types | blocks and returned errors: every mode 0–7 with `partition = -1`; every forced partition of modes 0, 1, 2, 3 and 7 on 12 blocks and one per block on the rest; rotations 0–3 for modes 4 and 5; both index selectors; 5 settings |
| … `rotation` 4–7 and `index_selector` 2–3 (masked to 2 and 1 bits by the original, but a non-zero rotation still selects the linear metric) | the same masking in `bc7e_api.compressBlockSingleMode` | all 8 rotations × 4 selectors for modes 4 and 5, 260 blocks, both metrics |
| … `partition` out of range or given for modes 4–6 | asserted, as in the original | contract violation in both: the original asserts, then clamps in release builds |
| `m_perceptual` | `perceptual` | every test runs both values |
| `m_weights` | `weights` | the perceptual presets (128, 64, 16, 256) and a custom set (3, 2, 1, 5), which also takes the weighted branch of the partition estimate |
| `m_uber_level` 0–4 | `uber_level` | 0 (fast, slow), 1 (basic and a variant), 2 (veryslow), 3 (variant), 4 (slowest) |
| `m_refinement_passes` | `refinement_passes` | 0, 1 and 2 |
| `m_pbit_search` | `pbit_search` | off (most presets, a slowest variant) and on (slow and slower, a fast variant) |
| `m_mode6_only` | `mode6_only` | ultrafast and a slowest variant, on opaque and alpha blocks |
| `m_use_luts` | `use_luts` | false at basic, slow and slowest, and in single-mode |
| `m_mode4_rotation_mask`, `m_mode5_rotation_mask` | same names | 15, 5 (ultrafast), 1, 2, 4 and 8 |
| `m_mode4_index_mask` | same | 3, 1 and 2 |
| `m_uber1_mask` | same | 7, 1, 2 and 4 |
| `m_max_partitions_mode[0..7]` | `max_partitions_mode` | 16/64 (defaults), 32 (basic, linear), 1 (a variant, which takes the single-partition early return); entries 4–6 are never read for partitioned search, as in the original |
| `m_opaque_settings.m_max_mode13/0/2_partitions_to_try` | same | 1, 2 and 4 (presets), 3, 16 and 64 (variants: the sorted list, and the try-everything early return) |
| `m_opaque_settings.m_use_mode[0..6]` | `use_mode` | the presets' combinations, mode 3 alone, without modes 1, 4 and 6, and none at all |
| `m_alpha_settings.m_max_mode7_partitions_to_try` | same | 1, 2, 4 and 64 |
| `m_alpha_settings.m_mode67_error_weight_mul` | same | 1s and (2, 3, 1, 4) |
| `m_alpha_settings.m_use_mode4/5/6/7` | same | each off in a variant; none at all |
| `m_alpha_settings.m_use_mode4_rotation`, `_mode5_rotation` | same | on, and both off |
| `m_unused1`, `m_unused2`, `m_unused3` | kept as padding fields | no effect in the original |
| `BC7E_NON_DETERMINISTIC` | the value 0 | hard-coded `#define … (0)` in the original, not settable without editing the source; with 1 it would stop the partition estimate early. The port implements the shipped value |
| `BC7E_MAX_PARTITIONS*`, `BC7E_BLOCK_SIZE`, `BC7E_2SUBSET_CHECKERBOARD_PARTITION_INDEX`, `BC7E_MAX_UBER_LEVEL` | same constants | fixed in the original |
| `NDEBUG` asserts | Zig asserts on the same conditions | the reference runs with the original's asserts on under `zig build coverage` |
| `HERE()` debug macro | not ported | unused in the original |

Added in zig-bcn, beyond bc7e: a BC7 decoder (all 8 modes, rotations, index
selector, p-bits; the reserved mode decodes to transparent black), checked
byte for byte against texcomp's on 80,000 random blocks covering every mode,
12,000 encoded blocks and 14 encoded images; and `encodeImage` and
`decodeImage` for whole images.

One behaviour of the original depends on its C++ standard library: it calls
`sqrt` and `floor` unqualified on floats, which resolve to the float
overloads under libc++ and MSVC but to the double ones under libstdc++,
where `1.0f / sqrt(x)` then rounds differently and blocks change. The port
follows the float overloads, which the source comment names as intended
(see `doc/coverage.md`).

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
| the block encoders `tc_encode_bc6h_block_uf16`, `_sf16` (internal) | `bc6h.encodeBlock(pixels, format)` | differential: 20,000 fuzz blocks and 868 blocks from coverage-guided fuzzing and targeted search, both formats, all three kernels |
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

zig-bcn additions, beyond texcomp: `bc6h.Quality.high`
(`encodeBlockQuality`, `encodeImageQuality`), zig-bcn's own encoder in
`src/bc6h_high.zig`, which fixes the behaviour above without changing
`.fast`. It has no original to match, so `test/bc6h_high_test.zig` proves
it differently: every block it writes decodes, in texcomp's decoder and
zig-bcn's, to exactly the error it reported; that error is never above
`.fast`'s; every flat colour of both formats is stored exactly; every
mode's fields pack and decode back; its float-to-half conversion is IEEE
round to nearest even on all 2^32 floats; and it improves on `.fast` by
set factors on flat, sky and gradient images.
