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
  median. The time ratio is the original's throughput divided by zig-bcn's:
  below 1, zig-bcn takes less time.
- **Three runs**: the command below ran three times. Each row is from the
  run with the median time ratio, and the last column is the range of the
  three runs' time ratios, (largest - smallest) / median.

```sh
zig build bench -- --rounds 3
zig build bench -- --filter decode --rounds 3   # one group of rows
```

## Machine

AMD Ryzen 9 9950X3D, Linux 7.3, Zig 0.17.0 (`x86_64` `znver5`), at
commit `3ee9b14`, on 11 November 2026. The one-minute load average was
2.3 to 3.0 during the runs, on 32 hardware threads.

## Results

| feature | zig-bcn Mpix/s | range | original Mpix/s | range | throughput, zig-bcn / original | time, zig-bcn / original | time ratio, range of 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| bc1 encode normal | 167.63 | 4.1% | 146.16 | 1.1% | 1.15 | 0.87 | 1.0% |
| bc1 encode high | 148.37 | 2.5% | 126.99 | 1.9% | 1.17 | 0.86 | 0.9% |
| bc1 encode normal biased | 166.78 | 3.0% | 138.26 | 1.6% | 1.21 | 0.83 | 1.2% |
| bc3 encode normal | 121.77 | 3.3% | 110.62 | 1.4% | 1.10 | 0.91 | 0.6% |
| bc3 encode high | 112.42 | 3.5% | 99.68 | 1.5% | 1.13 | 0.89 | 1.1% |
| bc4 encode | 491.77 | 1.0% | 490.04 | 0.9% | 1.00 | 1.00 | 0.1% |
| bc5 encode | 237.37 | 0.8% | 243.28 | 2.8% | 0.98 | 1.02 | 2.9% |
| bc7 encode ultrafast | 8.45 | 0.7% | 10.63 | 1.0% | 0.79 | 1.26 | 1.2% |
| bc7 encode veryfast | 2.50 | 1.2% | 3.22 | 0.5% | 0.78 | 1.29 | 5.2% |
| bc7 encode fast | 2.50 | 1.1% | 3.22 | 0.7% | 0.78 | 1.29 | 5.1% |
| bc7 encode basic | 1.65 | 0.4% | 2.14 | 0.5% | 0.77 | 1.30 | 3.5% |
| bc7 encode basic linear | 0.98 | 0.8% | 1.16 | 0.5% | 0.84 | 1.18 | 1.9% |
| bc7 encode slow | 1.30 | 0.5% | 1.62 | 0.5% | 0.80 | 1.25 | 3.2% |
| bc7 encode veryslow | 0.35 | 0.8% | 0.42 | 0.5% | 0.83 | 1.20 | 2.9% |
| bc7 encode slowest | 0.27 | 0.5% | 0.32 | 0.5% | 0.84 | 1.19 | 0.0% |
| bc6h encode unsigned | 5.01 | 0.4% | 3.16 | 0.5% | 1.59 | 0.63 | 0.3% |
| bc6h encode signed | 3.39 | 0.6% | 2.92 | 0.2% | 1.16 | 0.86 | 4.1% |
| bc6h encode unsigned, texcomp simd | 5.00 | 0.3% | 3.13 | 0.3% | 1.60 | 0.63 | 1.1% |
| bc6h encode signed, texcomp simd | 3.41 | 0.7% | 2.80 | 0.5% | 1.22 | 0.82 | 1.4% |
| bc6h encode high unsigned | 0.69 | 0.4% | no original | | | | |
| bc6h encode high signed | 0.65 | 2.6% | no original | | | | |
| bc1 decode | 1953.87 | 0.5% | 1418.34 | 1.6% | 1.38 | 0.73 | 0.8% |
| bc3 decode | 1439.16 | 0.6% | 842.27 | 3.0% | 1.71 | 0.59 | 0.5% |
| bc4 decode | 7430.58 | 0.6% | 2736.27 | 0.6% | 2.72 | 0.37 | 0.4% |
| bc5 decode | 1283.27 | 0.4% | 1017.45 | 0.7% | 1.26 | 0.79 | 1.6% |
| bc5 decode snorm | 839.96 | 0.4% | 608.22 | 0.4% | 1.38 | 0.72 | 1.0% |
| bc7 decode | 551.94 | 0.5% | 249.38 | 0.5% | 2.21 | 0.45 | 1.5% |
| bc7 decode f32 | 638.40 | 0.5% | 241.11 | 0.4% | 2.65 | 0.38 | 1.5% |
| bc6h decode unsigned | 784.79 | 0.3% | 311.51 | 0.3% | 2.52 | 0.40 | 3.5% |
| bc6h decode signed | 689.48 | 0.4% | 231.70 | 0.6% | 2.98 | 0.34 | 2.4% |

## Notes and known biases

- **BC7 encoding is slower than bc7e,** at about four fifths of its speed
  (time ratio 1.18 to 1.30). The time is spread over the translated search
  rather than one loop: its perceptual palette search, run on vectors,
  keeps every byte but gains nothing measurable.
- **BC5 encoding** measured 0.98 of stb_dxt's throughput (time ratio
  1.02). No reason has been identified; the BC4 encoder it is built from
  measured 1.00.
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
- **CPU time, not wall time.** This leaves out the time other processes
  hold the core; memory and cache contention from them still reach both
  sides.
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
