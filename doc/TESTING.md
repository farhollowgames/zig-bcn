# Testing

The sections up to "In this repository" are the same in every Farhollow
Games port of a C or C++ library to Zig. The last section says how this
repository applies them.

## Oracle tests

The original is pinned to one upstream commit and kept in `reference/` (or
fetched as a lazy dependency), byte for byte as upstream has it. It is built
only for the tests and the benchmark, and is never part of the package.

An oracle test runs the original and the port on the same inputs and
compares the results. Where the original is exact, the test compares every
output byte and every returned value, not a summary such as a hash or one
field of the result. The inputs are:

- the original's own test data and demo assets, where it has them;
- hand-made edge cases: empty input, one element, the largest size, and
  degenerate cases;
- seeded random inputs (see Fuzzing).

`STATUS.md` lists every public function, option and mode of the original,
and names the tests that check each one. Code coverage is not the measure:
a feature counts as checked when a test compares it, not when a line is
reached.

## What "the same output" means

- Bytes and integers are equal.
- Floats are compared by their bit patterns, so `-0.0` differs from `0.0`,
  and a NaN matches only a NaN with the same bits.
- Where the original's output depends on how it is compiled (fused
  multiply-add, fast-math, signed overflow), the reference is built with
  flags that fix one result, and the port computes that result. The last
  section names the flags.
- Where a port deliberately computes differently from the original, a
  written design gives the units, scales, overflow bounds and tolerances.
  The port is then checked against an exact port within those tolerances,
  and against itself exactly.

## Fuzzing

Each fuzz test draws its inputs from a seeded generator and runs at least
1,000 cases. The seeds are recorded in the tests, so every run checks the
same inputs. A failure prints its seed, and the configuration where there is
one, so that it can be repeated. Where a repository has the option,
`zig build test -Dfuzz-seed=N` changes every fuzz test's seed, to explore
other inputs.

## Malformed input

Decoders and parsers are given truncated, corrupted and random bytes, and
must give the original's result: the same output, the same error, or the
same rejection. Where the port asserts a condition that the original
reports as an error code, or that the original does not check, `STATUS.md`
says so. Where a repository has contract tests, a program breaks one
contract per run, and the test expects the abort and its message in the safe
build modes.

## Determinism

The same inputs give the same output on every run. Where the library splits
work over threads, the tests compare the output on 1, 2 and more threads
with the output of one.

## Build modes

`zig build test` runs the tests in ReleaseSafe unless
`-Dtest-optimize=<mode>` says otherwise. ReleaseSafe keeps every assert and
integer overflow check on and runs the slow cases in reasonable time. The
last section says which modes have been run.

## Review

After a port passes its oracle tests, a separate AI agent profiles it
against the original and tunes the hot paths; each change is kept only if
the oracle tests still pass and the benchmark shows a gain. Another AI agent
then tries to break the claims: features left untested, comparisons that
check too little, fuzzing too narrow, benchmarks that favour the port,
undefined behaviour, integer overflow, and references that can outlive what
they point to. Each confirmed finding is fixed with a test that failed
before the fix. No person has yet reviewed the code or the tests.

## In this repository

### The originals

`reference/` holds stb_dxt v1.12 (`2c980bb`), basis_universal's
`basisu_bc7e_scalar` at `v2_50` (`9bebe16`) and texcomp from TinyEXR at
`644148d`, copied unmodified (see [`reference/README.md`](../reference/README.md)),
with small C ABI shims in `reference/shim/`. `zig build test` builds them
with Zig's clang, C as `-std=c11` and C++ as `-std=c++17`, with
`-ffp-contract=off -fno-fast-math` so float steps round as written, as
Zig's do. The C is also built with `-fwrapv`: texcomp's BC6H error sums
overflow `int32`, which is undefined in C, and optimizers that use that
change which blocks win, so without it the original's own output depends
on the compiler. The port computes the wrapped result.

The encoders are checked against their originals, and zig-bcn's decoders,
which are its own, against texcomp's decoders.

### Tests and counts

`zig build test` runs 60 tests: 14 unit tests in `src/` and 46 tests in
`test/`, through `test/differential.zig`. Most of the tests in `test/` are
oracle tests; the others check round trips within the format's error, the
format-independent API against the format functions, and the properties of
`bc6h.Quality.high`. [`doc/parity.md`](parity.md) names the test for every
function, option and build switch of each original.

The inputs are generated by `test/images.zig`: 14 RGBA images (flat cells,
gradients, hard and soft alpha, noise, normal maps, two and three colours,
low contrast, extremes, a grey ramp, hue stripes) and 8 HDR images (a ladder
of magnitudes, log gradients and noise, a sun, signed values, infinities and
NaN, small values, two regions), each 61 x 47 pixels, so edge blocks are
partial: 2,688 RGBA and 1,536 HDR blocks. On top of those:

| feature | compared with | inputs |
| --- | --- | --- |
| BC1, BC3, BC4, BC5 encoders | stb_dxt, and a second build with `STB_DXT_USE_ROUNDING_BIAS` | the image set at every setting; 200,000 crafted blocks (seed `0x5eed`), varying alpha included |
| BC7 encoder | bc7e | the image set at all 7 levels, perceptual and linear, and 23 setting variants that reach every field of `Params`; 3,000 crafted blocks at every level and setting; single-mode encoding in every mode, partition, rotation and index selector, errors included |
| BC6H encoder | texcomp under its AVX2, SSE4.1 and scalar kernels | the HDR set, both formats; 20,000 fuzz blocks (seed `0xbc6f`) and a corpus of 868 blocks from coverage-guided fuzzing and targeted search (`test/bc6h_corpus.bin`), with every mode encoder called directly, so each mode's block and error estimate are compared whether or not it wins |
| `floatToHalfBits` | texcomp's `tc_float_to_half_bits` | all 2^32 float bit patterns |
| BC1, BC3, BC4 decoders | texcomp | random blocks and streams, encoded images, clipping and a wide stride |
| BC5 SNORM decoders | texcomp | every pair of endpoint bytes, -128 included; 50,000 random and edge blocks (seed `0x5b5`); texcomp's SNORM encoding of the image set; windows of a larger image with 2, 3 and 4 channels |
| BC7 decoder | texcomp | 80,000 random blocks covering every mode (seed `99`), 12,000 encoded blocks, the encoded image set, clipping and a wide stride |
| BC7 float decoder | texcomp, float bits | 40,000 random blocks in every mode and the reserved one (seed `0xbc7f`), every first byte, encoded blocks and images, windows of RGB and RGBA |
| BC6H decoder, half bits and floats | texcomp | every encoded image, 200,000 random blocks of both formats (seed `0x6c6`), every window size from 1 x 1 to 9 x 9, strips and padded rows |
| `bc6h.Quality.high` | no original | every block decodes, in texcomp's decoder and zig-bcn's, to exactly the error the encoder reported, and never above `.fast`'s, on the HDR set, 4,000 fuzz blocks (seed `0xb6`) and the corpus; every flat colour is stored exactly; every mode's fields pack and decode back; its float-to-half conversion is IEEE round to nearest even on all 2^32 floats |
| `bcn.Encoding`, row bands, threads | the format functions | the same bytes in bands and on threads; windows of a larger image like a packed copy; fewer channels like the same pixels in RGBA |

Float outputs (`decodeImageF32`, `decodeBlockF32`) are compared as bytes,
so as bit patterns; the HDR set puts infinities and NaN through the BC6H
encoder and decoders.

### Fuzzing

Each random input comes from a generator whose recorded seed is in the
test. `zig build test -Dfuzz-seed=N` XORs `N` into every recorded seed; 0,
the default, gives the recorded inputs. A failing comparison prints the
first five differing blocks with their inputs, and the `-Dfuzz-seed` value
of the run.

### Malformed input

The decoders are given random blocks, which reach the reserved BC6H mode
codes and the reserved BC7 mode, and every BC7 first byte; their output
must equal texcomp's (the reserved BC7 mode decodes to transparent black).
Argument errors are asserted, not returned (see
[`STATUS.md`](../STATUS.md#left-out-for-the-author-to-approve)): a short
buffer or stride panics in Debug and ReleaseSafe and is undefined in
ReleaseFast. zig-bcn has no contract tests for those asserts.

### Determinism

`bcn.encodeImageParallel` gives the same bytes on 1, 2 and 8 threads, and
the same as encoding the image whole; decoding in row bands, and one block
row per task on 1, 2 and 8 threads, gives the image decoded whole, for
every decoder.

### Coverage and undefined behaviour

[`doc/coverage.md`](coverage.md) records a run of the oracle tests, on
8 October 2026, against the originals built with source-based coverage:
the tests reached every function of stb_dxt and of texcomp's BC6H, and
every line and branch of stb_dxt; the unreached lines and branches are
listed with their reasons. The same day, the originals were also built
with `-fsanitize=float-cast-overflow,undefined -fsanitize-trap=all`, and
every oracle test passed. The run is not part of CI; `zig build coverage`
repeats it (needs clang and llvm-cov). Coverage of the originals shows how
far the inputs reach; it is not what the tests are measured by.

### Build modes

The tests run in ReleaseSafe by default, as CI does (`ubuntu-latest`,
x86-64, Zig 0.17.0); `-Dtest-optimize` selects another mode. The originals
are always built with optimization on.

### State

`STATUS.md` marks each item as oracle-tested or benchmarked. None is marked
reviewed yet: that state is set at a release, after the review above.
