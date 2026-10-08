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

## texcomp BC6H

In progress on the `bc6h` branch.
