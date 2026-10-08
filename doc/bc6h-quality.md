# BC6H quality and speed

zig-bcn has two BC6H encoders. `Quality.fast` is texcomp's, translated byte
for byte. `Quality.high` is zig-bcn's own (`src/bc6h_high.zig`), written
after this comparison showed where texcomp falls short. Both are measured
here against a reference encoder: Microsoft's DirectXTex, whose BC6H codec
descends from the D3DX reference implementation.

Measured 7 October 2026 (texcomp, DirectXTex) and 8 October 2026
(`.high`) on an AMD Ryzen 9 9950X3D, one thread, clang 23 `-O2` for the C
and C++, Zig 0.17.0 `ReleaseFast` for zig-bcn.

## Method

- **Encoders.** texcomp at commit 644148d (zig-bcn's `.fast` output is
  identical), in its default AVX2 build and with its selector search forced
  to scalar code (the path zig-bcn translates; same bytes). DirectXTex at
  commit 1acf4eb, `D3DXEncodeBC6HU` and `D3DXEncodeBC6HS` with
  `BC_FLAGS_NONE`, per 4x4 block with the same edge clamping. zig-bcn
  `.high`, whose streams `speed.zig` writes for the tool to read.
- **Images.** `asakusa.exr` from the TinyEXR repository (660 x 440, a real
  HDR photograph), and the 8 synthetic HDR images of the differential tests
  (61 x 47 each, `test/images.zig`).
- **Decoding.** Every stream is decoded by texcomp's decoder (zig-bcn's is
  identical). The tool also decodes every stream with DirectXTex's decoder:
  the two agree on every block of every stream, `.high`'s included.
- **Metrics.** Against what the format can store (unsigned clamps negatives
  and NaN to 0; both clamp magnitudes to 65504): the RMSE of
  sign(x) log2(1 + |x|) over all channels, and multi-exposure PSNR (mPSNR):
  the magnitude tone mapped at exposures of -6 to +6 stops to 8-bit gamma 2.2,
  the error averaged over all exposures. Higher mPSNR is better.

## Results

asakusa.exr, the representative case:

| format | encoder | log2 RMSE | mPSNR dB | Mpixel/s |
| --- | --- | --- | --- | --- |
| unsigned | texcomp (AVX2) | 0.0154 | 43.86 | 33.4 |
| unsigned | texcomp scalar | same bytes | | 12.1 |
| unsigned | zig-bcn `.fast` | same bytes | | 12.1 |
| unsigned | DirectXTex | 0.0127 | 45.40 | 0.02 |
| unsigned | **zig-bcn `.high`** | **0.0119** | **46.01** | **0.54** |
| signed | texcomp (AVX2) | 0.0165 | 43.40 | 6.9 |
| signed | texcomp scalar | same bytes | | 3.1 |
| signed | zig-bcn `.fast` | same bytes | | 3.5 |
| signed | DirectXTex | 0.0128 | 45.35 | 0.02 |
| signed | **zig-bcn `.high`** | **0.0120** | **45.94** | **0.49** |

The synthetic images, mPSNR in dB, unsigned (signed in brackets where it
differs by more than a few tenths):

| image | texcomp (`.fast`) | DirectXTex | `.high` | what it shows |
| --- | --- | --- | --- | --- |
| hdr_flat_ranges | 41.25 | 99.00 | 99.00 | flat blocks: DirectXTex and `.high` store them exactly with the 16-bit one-region mode; texcomp keeps 10-bit endpoints |
| hdr_log_gradient | 38.45 | 42.46 | 43.69 | smooth gradients over many stops |
| hdr_sun | 59.57 (52.30) | 75.85 (68.58) | 75.85 (68.58) | flat sky and a flat disc |
| hdr_two_regions | 55.48 (52.95) | 55.93 (54.08) | 55.90 (54.10) | two values per block |
| hdr_small | 36.99 | 46.66 | 47.25 | values near 2^-14; texcomp flushes everything below it to zero |
| hdr_log_noise | 10.43 | 10.26 (9.21) | 11.64 | random values over many stops per block: beyond any BC6H encoding |
| hdr_signed | 10.01 (6.07) | 10.14 (6.15) | 11.32 (6.91) | as above, with random signs |
| hdr_specials | 11.41 (7.32) | 8.50 (7.14) | 13.40 (10.55) | as above, with infinities and NaN |

`.high` matches or beats DirectXTex on every image, within 0.03 dB where it
is behind, and runs 25 to 50 times faster.

Which modes each encoder chose on asakusa.exr (block counts, unsigned):
texcomp 18,134 blocks in mode 10 and 16 in mode 9; DirectXTex spreads over
every mode, mostly 5 (4,767), 6 (5,432), 11 (3,007), 0 (1,423) and 12
(1,028); `.high` likewise, mostly 5 (4,804), 11 (4,419), 6 (4,109), 0
(1,514) and 12 (1,435).

Full per-image tables come from the tool (below).

## Why texcomp falls short

texcomp tries one-region mode 10 (two 10-bit endpoints) first and only looks
at other modes when its error is above a threshold. Then:

- It never emits mode 11 (11-bit base, 9-bit delta), the mode DirectXTex
  uses most for smooth blocks.
- Modes 1 to 8, 12 and 13 judge their candidate endpoints with mode 10's
  10-bit palette whatever their own precision, so their error estimates are
  off by large factors and they rarely win; unsigned modes 2 to 4 provably
  never do (doc/coverage.md, BC6H).
- Some packers write fields the decoder does not read back as the search
  assumed. Decoding each mode's output and comparing with the encoder's own
  error estimate on 200,000 fuzz blocks, the decoded error exceeds 1.25 times
  the estimate in 91 percent of mode 0 blocks (both formats), 76 percent of
  signed mode 6 to 8 blocks, 50 percent of signed mode 12 blocks and 13
  percent of mode 1 blocks, against 3 percent for modes 9 and 10. These
  modes win rarely (never on asakusa.exr), but when they do the block
  decodes worse than texcomp believed.
- `tc_float_to_half_bits` flushes every value below 2^-14 to zero, so the
  half subnormal range is lost.
- Its selector error sums overflow int32 for blocks with very large errors;
  the result depends on the compiler unless built with `-fwrapv`
  (doc/coverage.md, BC6H). zig-bcn computes the wrapped, that is exact, sum.

## What `.high` does differently

`src/bc6h_high.zig` searches the four one-region modes and all ten
two-region modes on the three partitions a quick fit ranks best. Each mode
fits its endpoints in the interpolation domain, quantizes them to that
mode's precision, keeps transformed modes' deltas in range, and refits by
least squares from the indices it chose. Every candidate is scored by the
exact error of what a decoder will produce, with the decoder's own
arithmetic, so no mode is misjudged, and texcomp's block is always a
candidate, so `.high` is never worse than `.fast` under that error. Flat
blocks take the 16-bit one-region mode, which stores any half exactly, and
targets come from an IEEE round-to-nearest conversion that keeps
subnormals. The tests (`test/bc6h_high_test.zig`) check that every block
decodes, in texcomp's decoder and zig-bcn's, to exactly the error the
encoder reported.

## Verdict

Use `.high` for shipped assets: skies, environment maps, probes and
lightmaps. It is better than DirectXTex on a real photograph (46.0 against
45.4 dB) and on every synthetic case that matters, and fast enough to bake
with: a 2048 x 2048 HDR texture takes about 8 seconds on one core, and
blocks are independent, so it divides by the number of cores.

Use `.fast` for editor previews and hot reload, where 12 Mpixel/s matters
more than 2 dB: it is texcomp's encoder byte for byte, good on photographs
(43.9 dB) but weak on flat and smooth regions, and it flushes values below
2^-14 to zero.

## Reproducing

```sh
tools/bc6h-quality/build.sh /tmp/bc6h-quality        # fetches DirectXTex, DirectXMath, DirectX-Headers, TinyEXR
zig run --dep images -Mroot=tools/bc6h-quality/dump_images.zig -Mimages=test/images.zig -- /tmp/bc6h-quality
/tmp/bc6h-quality/quality --dump /tmp/bc6h-quality /tmp/bc6h-quality/tinyexr/asakusa.exr   # writes asakusa.rgbf
zig run -O ReleaseFast --dep bcn -Mroot=tools/bc6h-quality/speed.zig -Mbcn=src/bcn.zig -- /tmp/bc6h-quality/*.rgbf
/tmp/bc6h-quality/quality --high /tmp/bc6h-quality /tmp/bc6h-quality/*.rgbf
```

`speed.zig` prints both qualities' speed and writes the `.high` streams
that `quality --high` reads. `build.sh` needs clang, clang++, git and curl.
DirectXMath needs a `sal.h` on Linux; the script fetches the MIT-licensed
one .NET publishes, as vcpkg does.
