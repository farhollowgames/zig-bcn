# BC6H quality and speed

zig-bcn's BC6H encoder is texcomp's, translated byte for byte. Before
Loomwork relies on it, this measures what texcomp's choices cost against a
reference encoder: Microsoft's DirectXTex, whose BC6H codec descends from the
D3DX reference implementation.

Measured 7 October 2026 on an AMD Ryzen 9 9950X3D, one thread, clang 23 `-O2`
for the C and C++, Zig 0.17.0 `ReleaseFast` for the port.

## Method

- **Encoders.** texcomp at commit 644148d (zig-bcn's output is identical), in
  its default AVX2 build and with its selector search forced to scalar code
  (the path zig-bcn translates; same bytes). DirectXTex at commit 1acf4eb,
  `D3DXEncodeBC6HU` and `D3DXEncodeBC6HS` with `BC_FLAGS_NONE`, per 4x4
  block with the same edge clamping.
- **Images.** `asakusa.exr` from the TinyEXR repository (660 x 440, a real
  HDR photograph), and the 8 synthetic HDR images of the differential tests
  (61 x 47 each, `test/images.zig`).
- **Decoding.** Both streams are decoded by texcomp's decoder (zig-bcn's is
  identical). The tool also decodes every stream with DirectXTex's decoder:
  the two agree on every block.
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
| unsigned | zig-bcn | same bytes | | 12.2 |
| unsigned | DirectXTex | 0.0127 | 45.40 | 0.02 |
| signed | texcomp (AVX2) | 0.0165 | 43.40 | 6.9 |
| signed | texcomp scalar | same bytes | | 3.1 |
| signed | zig-bcn | same bytes | | 3.5 |
| signed | DirectXTex | 0.0128 | 45.35 | 0.02 |

The synthetic images, unsigned (signed is within a few tenths of a dB,
except as noted):

| image | texcomp mPSNR | DirectXTex mPSNR | what it shows |
| --- | --- | --- | --- |
| hdr_flat_ranges | 41.25 | 99.00 | flat blocks: DirectXTex stores them exactly with the high-precision one-region modes; texcomp keeps 10-bit endpoints |
| hdr_log_gradient | 38.45 | 42.46 | smooth gradients over many stops |
| hdr_sun | 59.57 | 75.85 (signed 52.30 vs 68.58) | flat sky and a flat disc |
| hdr_two_regions | 55.48 | 55.93 | two values per block |
| hdr_small | 36.99 | 46.66 | values near 2^-14; texcomp flushes everything below it to zero |
| hdr_log_noise, hdr_signed, hdr_specials | 6 to 11 | 6 to 10 | random values over many stops per block: beyond any BC6H encoding, both fail alike |

Which modes each encoder chose on asakusa.exr (block counts, unsigned):
texcomp 18,134 blocks in mode 10 and 16 in mode 9; DirectXTex spreads over
every mode, mostly 5 (4,767), 6 (5,432), 11 (3,007), 0 (1,423) and 12
(1,028).

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

## Verdict

Good enough for most game assets, and very fast. On a real HDR photograph
texcomp is 1.5 dB mPSNR (0.003 log2 RMSE) behind the reference while being
about 600 times faster in the scalar path zig-bcn translates (12 against
0.02 Mpixel/s; 1,500 times with texcomp's AVX2 build). That suits baking
every HDR texture on every change.

It falls short where precision matters most: flat or very smooth HDR
regions (skies, light discs, emissive surfaces, gradients) lose 4 to 16 dB
against DirectXTex, and values below 2^-14 vanish. For hero skyboxes and
lightmaps a better encoder will be wanted later. Options, for the author:
fix texcomp's mode handling in the port (which ends byte parity with
upstream texcomp), or port a stronger encoder; DirectXTex itself is MIT but
far too slow to bake with.

## Reproducing

```sh
tools/bc6h-quality/build.sh /tmp/bc6h-quality        # fetches DirectXTex, DirectXMath, DirectX-Headers, TinyEXR
zig run --dep images -Mroot=tools/bc6h-quality/dump_images.zig -Mimages=test/images.zig -- /tmp/bc6h-quality
/tmp/bc6h-quality/quality --dump /tmp/bc6h-quality /tmp/bc6h-quality/tinyexr/asakusa.exr /tmp/bc6h-quality/hdr_*.rgbf
zig run -O ReleaseFast --dep bcn -Mroot=tools/bc6h-quality/speed.zig -Mbcn=src/bcn.zig -- /tmp/bc6h-quality/asakusa.rgbf
```

`build.sh` needs clang, clang++, git and curl. DirectXMath needs a `sal.h`
on Linux; the script fetches the MIT-licensed one .NET publishes, as vcpkg
does.
