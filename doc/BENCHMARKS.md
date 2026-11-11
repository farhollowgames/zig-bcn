# Benchmarks

These are measurements on one machine, under the conditions below. They
are not a verdict on either side.

## Method

`zig build bench` times every encoder against its original and every
decoder against texcomp's, on one thread, on every block of the test image
set (2,688 RGBA and 1,536 HDR blocks, see [`TESTING.md`](TESTING.md)), and
checks that both sides write the same bytes. The BC6H `simd` rows run
texcomp with its AVX2 selector kernels, the other BC6H rows with its scalar
search.

- **zig-bcn**: ReleaseFast, for the CPU it runs on.
- **The originals**: Zig's clang at `-O3`, for the same CPU, C as
  `-std=c11` and C++ as `-std=c++17 -fno-exceptions -fno-rtti
  -fno-threadsafe-statics`, with the flags their exact output needs:
  `-ffp-contract=off -fno-fast-math`, and `-fwrapv` for the C.
- **Samples**: each lasts at least 25 ms of the benchmark thread's CPU
  time, after two warm-ups, and the two sides' samples alternate. Every
  pass's output is kept behind a compiler barrier, so no pass can be
  removed, and the two sides' outputs are compared.
- **Reported**: the median of 11 samples in megapixels a second, the best
  median of three rounds for each side; range is (slowest - fastest) /
  median. The time
  ratio is the original's throughput divided by zig-bcn's: below 1, zig-bcn
  takes less time.

```sh
zig build bench -- --rounds 3
zig build bench -- --filter decode --rounds 3   # one group of rows
```

## Machine

AMD Ryzen 9 9950X3D, Linux 7.3, Zig 0.17.0 (`x86_64` `znver5`).

**The machine was busy.** The numbers were taken while other builds ran,
so absolute speeds move by up to a fifth between runs; the ratios, from
alternating samples, move less. The `bc5 decode snorm` and `bc7 decode f32`
rows were taken later, on the same machine under load: each is the run
with the median ratio of three runs of
`zig build bench -- --filter decode --rounds 3`.

## Results

| feature | zig-bcn Mpix/s | range | original Mpix/s | range | throughput, zig-bcn / original | time, zig-bcn / original |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| bc1 encode normal | 166.07 | 5.9% | 144.53 | 1.5% | 1.15 | 0.87 |
| bc1 encode high | 147.65 | 18.6% | 127.76 | 2.8% | 1.16 | 0.87 |
| bc1 encode normal biased | 167.19 | 1.3% | 138.29 | 0.8% | 1.21 | 0.83 |
| bc3 encode normal | 121.79 | 4.8% | 111.69 | 2.6% | 1.09 | 0.92 |
| bc3 encode high | 110.34 | 6.5% | 99.65 | 3.2% | 1.11 | 0.90 |
| bc4 encode | 487.49 | 3.3% | 481.56 | 6.9% | 1.01 | 0.99 |
| bc5 encode | 232.63 | 1.4% | 242.49 | 3.8% | 0.96 | 1.04 |
| bc7 encode ultrafast | 8.39 | 0.9% | 10.41 | 1.3% | 0.81 | 1.24 |
| bc7 encode veryfast | 2.56 | 1.0% | 3.15 | 2.0% | 0.81 | 1.23 |
| bc7 encode fast | 2.57 | 4.4% | 3.17 | 3.0% | 0.81 | 1.23 |
| bc7 encode basic | 1.67 | 4.0% | 2.11 | 2.8% | 0.79 | 1.26 |
| bc7 encode basic linear | 0.97 | 1.1% | 1.15 | 0.7% | 0.85 | 1.19 |
| bc7 encode slow | 1.28 | 4.1% | 1.58 | 5.6% | 0.81 | 1.23 |
| bc7 encode veryslow | 0.35 | 3.2% | 0.42 | 1.6% | 0.82 | 1.20 |
| bc7 encode slowest | 0.27 | 0.7% | 0.32 | 1.2% | 0.84 | 1.19 |
| bc6h encode unsigned | 4.92 | 0.6% | 3.16 | 0.8% | 1.56 | 0.64 |
| bc6h encode signed | 3.38 | 2.1% | 2.90 | 2.9% | 1.17 | 0.86 |
| bc6h encode unsigned, texcomp simd | 4.86 | 1.4% | 3.08 | 2.6% | 1.58 | 0.63 |
| bc6h encode signed, texcomp simd | 3.26 | 3.6% | 2.69 | 3.2% | 1.21 | 0.83 |
| bc6h encode high unsigned | 0.66 | 0.3% | no original | | | |
| bc6h encode high signed | 0.61 | 0.6% | no original | | | |
| bc1 decode | 1825.88 | 1.1% | 1319.43 | 2.1% | 1.38 | 0.72 |
| bc3 decode | 1354.28 | 1.5% | 794.29 | 1.7% | 1.71 | 0.59 |
| bc4 decode | 6710.07 | 1.9% | 2602.34 | 2.1% | 2.58 | 0.39 |
| bc5 decode | 1245.02 | 6.2% | 972.02 | 2.8% | 1.28 | 0.78 |
| bc5 decode snorm | 821.96 | 1.0% | 600.58 | 0.9% | 1.37 | 0.73 |
| bc7 decode | 525.35 | 7.3% | 240.33 | 1.9% | 2.19 | 0.46 |
| bc7 decode f32 | 634.27 | 3.1% | 237.17 | 1.8% | 2.67 | 0.37 |
| bc6h decode unsigned | 740.69 | 3.7% | 297.71 | 0.9% | 2.49 | 0.40 |
| bc6h decode signed | 643.87 | 4.6% | 219.48 | 5.5% | 2.93 | 0.34 |

## Notes and known biases

- **BC7 encoding is slower than bc7e,** at about four fifths of its speed
  (time ratio 1.19 to 1.26). The time is spread over the translated search
  rather than one loop: its perceptual palette search, run on vectors,
  keeps every byte but gains nothing measurable.
- **BC5 encoding** measured 0.96 of stb_dxt's throughput (time ratio
  1.04). No reason has been identified; the BC4 encoder it is built from
  measured 1.01.
- **BC6H** runs its selector search and partition boxes on vectors of the
  block's 16 texels, with the same integer arithmetic as texcomp's SIMD
  kernels. texcomp's own AVX2 kernels make no difference here: built for
  this CPU, its scalar search is vectorized by the compiler too.
- **The decoders** decode a block's 16 pixels at once, in vector lanes.
  The comparisons are not of identical work in two cases. texcomp's BC5
  decoders write blue and alpha as well; zig-bcn's write red and green
  only. texcomp's BC7 float decoder decodes the image to bytes in a buffer
  it allocates for each call, then converts them; zig-bcn converts each
  block's lanes. zig-bcn's SNORM decoder turns signed values into bytes
  with integer lanes, which give exactly texcomp's float steps.
- **CPU time, not wall time.** On a busy machine this leaves out the time
  other processes hold the core, which is why the busy runs are usable;
  memory and cache contention from those processes still reach both sides.
- **The exactness flags** cost the originals little: built with fused
  multiply-add and without `-fwrapv`, they write different bytes, and only
  BC1 gets measurably faster (about a tenth). The rows above use the exact
  build, since only then do both sides do the same work.
- **`bc6h encode high`** has no original. [`bc6h-quality.md`](bc6h-quality.md)
  compares its quality and speed with texcomp and with Microsoft's
  DirectXTex on HDR photographs and the test images, on the same machine.

## Threads

Encoding in bands of block rows scales with the cores: BC7 `basic` on a
1024 x 1024 image took 1.05 s on one thread and 62 ms on 32. This figure
does not come from `zig build bench`, which runs on one thread.
