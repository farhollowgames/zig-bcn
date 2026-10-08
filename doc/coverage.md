# Coverage and equivalence

`doc/parity.md` lists every feature of the originals and the test that
compares it. This file covers the supporting check: that those tests reach
every line and branch of the translated code.

zig-bcn's encoders are translations, so the question a test has to answer is
whether the Zig produces the same bytes as the original for every input the
original handles. Two checks answer it together:

1. **Byte-for-byte equality.** `zig build test` builds the original C and C++
   from `reference/` and runs both on the same inputs: the fixed image set
   in `test/images.zig` at every quality setting, plus crafted blocks for
   paths images rarely reach. Every output byte must match: encoded blocks,
   returned errors, flags and decoded pixels.
2. **Coverage of the original.** `zig build coverage` rebuilds the reference
   with clang's source-based coverage, runs the same tests and checks that
   every line and branch of the translated code was reached
   (`tools/coverage-required.txt`). A path the tests reach produces identical
   bytes in both, so full coverage means every path of the original has been
   compared with its translation.

Anything the tests cannot reach is declared in `tools/coverage-required.txt`
with its exact count of missed lines and branches, and explained below. The
counts must match exactly, so a new gap or a newly covered line fails the
check until the rule is updated.

## Running it

```sh
zig build test       # byte-for-byte differential tests
zig build coverage   # the same tests, instrumented; fails if coverage differs from the rules
```

`zig build coverage` needs `clang`, `clang++`, `llvm-profdata` and `llvm-cov`
from one LLVM release on the `PATH` (it was set up with LLVM 23). It prints a
per-file summary and writes to `zig-out/coverage/`: `report.txt`,
`functions.txt` (per function) and `show/` (per-line counts; uncovered lines
have a count of 0 and missed branch directions show `: 0]`).

## Recorded run

The originals are pinned (see `reference/README.md`) and do not change, so
this is a one-time proof, kept out of CI. Run it again after changing the
tests or moving to a new version of an original.

Run on 8 October 2026 with LLVM 23.1.1 on x86-64 Linux, at the merge of
the BC7 and BC6H ports (`47380c7`, with formatting only after it):

```
Filename                            Functions  Missed  Executed   Lines  Missed   Cover  Branches  Missed   Cover
stb/stb_dxt.h                              16       0   100.00%     318       0 100.00%        98       0 100.00%
bc7e/basisu_bc7e_scalar.cpp                86      10    88.37%    3592     112  96.88%      1314     119  90.94%
texcomp/src/texcomp_bc6h.c                 54       0   100.00%    3024      33  98.91%      2044     118  94.23%
texcomp/src/texcomp_bc6h_decode.c          11       0   100.00%     529       3  99.43%       154      14  90.91%
coverage: every required function is covered as declared
```

The files not shown (texcomp's BC1, BC3, BC5 and BC7 sources) also hold
encoders zig-bcn does not port; only their decoders are required, as
declared below. bc7e's ten unexecuted functions are helpers the original
never calls.

The same day, the reference was also built with
`-fsanitize=float-cast-overflow,undefined -fsanitize-trap=all`, so any
undefined behaviour would stop the run: every differential test passed.
The tests therefore never reach the out-of-range float-to-int casts bc7e
could perform in principle, and texcomp's int32 overflow is defined by
`-fwrapv` (see BC6H below).

## Status

| original | translated code covered | byte-identical on |
| --- | --- | --- |
| `stb_dxt.h` (BC1, BC3, BC4, BC5), both rounding builds | every function, line and branch | 14 images × 4 settings × 2 stb modes, 200,000 crafted blocks × 4 settings, varying alpha included |
| texcomp BC1, BC3, BC4, BC5 decoders | every line and branch of the block decoders; the image decoders as declared below | 20,000 random blocks; random streams at five sizes with a wide stride |
| `basisu_bc7e_scalar.cpp` (BC7) | every line and branch except assert failure branches, helpers the original never calls, and paths ruled out by their enclosing conditions, all declared below | 14 images × 7 levels × 2 metrics; 3,000 crafted blocks × 14 presets, the 2 base inits and 46 setting variants; the image set × 46 variants; single-mode on 390 crafted blocks × 5 settings, every mode, rotation, index selector and forced partition |
| texcomp BC7 decoder | every line and branch except as declared below | 80,000 random blocks in every mode and the reserved one; 12,000 encoded blocks; 14 encoded images at 61 × 47 |
| texcomp BC6H encoder (`texcomp_bc6h.c`), including its SSE4.1 and AVX2 selector kernels | every function; 98.9% of lines and 94.2% of branches, the rest declared below | 8 HDR images × 2 formats × 3 kernels (AVX2, SSE4.1, scalar); every mode encoder called directly, block and error estimate, on 20,000 fuzz blocks and 868 coverage-guided fuzzing blocks × 3 kernels; all 2^32 floats through `tc_float_to_half_bits` |
| texcomp BC6H decoder (`texcomp_bc6h_decode.c`) | every function; 99.4% of lines and 90.9% of branches, the rest declared below | every encoded image, half and float output; 200,000 random blocks per format, all 14 modes and the reserved codes; padded rows |

## Declared gaps

### texcomp image decoders

- `tc_bc1_decompress_rgba8`, `tc_bc3_decompress_rgba8`: 1 line and 6
  branches each are the argument checks (null pointers, zero size, short
  stride or buffer), which return an error. The Zig decoders take slices and
  assert these conditions instead, so there is no error path to compare.
- `tc_bc5_decompress_rgba8`: the same argument checks (1 line, 6 branches),
  plus the BC5 SNORM path (8 lines, 3 branches). stb_dxt encodes BC4 and BC5
  as UNORM only, and zig-bcn offers what it ports.

### BC7: basisu_bc7e_scalar.cpp

Each rule in `tools/coverage-required.txt` names the function with its
exact count. What the counts are made of:

- **Assert failure branches.** With assertions on, each `assert` is a branch
  whose failing side aborts. The port asserts the same conditions; no valid
  input reaches them in either. This is all of what `safe_cast_uint16`,
  `float_to_uint8`, `scale_color`, both `color_cell_compression_est`
  functions, `estimate_partition_list`, `handle_alpha_block_mode4` and
  `_mode5`, `encode_bc7_block` and `set_block_bits` miss, and part of the
  others.
- **`bc7e_compress_blocks`** (5 lines): the uninitialized-codec path, which
  zeroes the output when `bc7e_compress_block_init` was not called. The
  port builds the tables at compile time and has no init to forget; the
  tests initialize the original first. The branches are its mask asserts.
- **`bc7e_compress_block_single_mode`** (2 lines): the clamps of a forced
  partition for a mode without partitions, or past the mode's count. Both
  sit behind asserts on the same conditions: calling so breaks the
  function's contract, and the port asserts the same.
- **`handle_block_solid`, `handle_opaque_block_mode6`** (1 branch each):
  the null check of the used-LUT pointer. Their only caller,
  `bc7e_compress_blocks`, always passes one.
- **`evaluate_solution`** (66 lines): the 8-index loop with alpha. Only
  modes 6 (16 indices) and 7 (4 indices) evaluate with alpha; mode 4's
  3-bit indices evaluate colour alone.
- **`estimate_partition`** (7 lines): the mode 6 and 7 weight scaling and
  the mode 7 estimate. Mode 7 always goes through `estimate_partition_list`.
- **`handle_opaque_block`, `handle_alpha_block`** (2 lines and 1 line): the
  early `break` of the refinement pass that re-encodes the winning partition
  of modes 1, 3 and 7. That partition's error is the current best, and the
  refined encoding of each subset is never worse than the unrefined one it
  starts from (refinement keeps only improvements), so the running sum
  cannot exceed the best.
- **`fixDegenerateEndpoints`** (5 lines): in `if (min > iscale / 2) { if
  (min > 0) ... else ... }` the inner else needs `min <= 0`; and in the
  other arm, `max < iscale` always holds because `max == min <= iscale / 2`.
  The mode 4 arm's two missed branches follow the same way.
- **`color_cell_compression`**: `sel > 0` in the uber pass is always true
  when reached (a zero selector is also the minimum and takes the first
  arm), and `uber_level >= 2` is re-tested inside a block that requires it.
- **`handle_alpha_block_mode5`**: the least squares fit of alpha always
  returns the high endpoint first, because the selectors are assigned in
  alpha order, so the swap is always taken.
- **`encode_bc7_block`**: for modes 4 and 5, which have one subset, every
  pixel is in subset 0.
- **Helpers never called**: `clampu`, `saturate255`, `minimumub`,
  `minimumu64`, `maximumub`, `maximumi`, `swapub`, `square(int)`,
  `component_min_rgb`, `component_max_rgb`, and the template instances
  only they use. The original marks most `[[maybe_unused]]`; they are not
  ported.

### BC7: texcomp decoder

- `tc_bc7_decompress_rgba8`: the argument checks (1 line, 6 branches), as
  for the other texcomp image decoders.
- `tc_bc7_dec_rb`: the branch for reads of 32 bits or more; BC7 fields are
  at most 8 bits.

### BC7: the reference under libstdc++

bc7e calls `sqrt` and `floor` unqualified on floats, meaning the float
overloads, which libc++ (the reference build) and MSVC declare in the
global namespace. libstdc++'s `<cmath>` does not, so built with a GCC-style
standard library the original computes `1.0f / sqrt(x)` in double and
produces different blocks. The coverage build uses the system's libstdc++,
so it force-includes `<math.h>` for the C++ files, which brings the float
overloads in and makes it compute as the reference build does. The port
follows the float overloads, as the source comment says is intended.

### BC6H: texcomp_bc6h.c

The reference compiles `texcomp_bc6h.c` through
`reference/shim/texcomp_bc6h_modes.c`, which includes it unchanged and
exports its static mode encoders, so the tests compare every mode's block and
error estimate, not only the winner's. Hence the `texcomp_bc6h_modes.c:`
prefix of the static functions in the rules.

**Signed overflow.** `tc_bc6h_err3_mag` sums three squared differences of
up to 31,743 in `int32`, which overflows (undefined behaviour; UBSan reports
it at line 108). Zig's clang 22 at `-O2`, and clang 23 with `-march=native`,
exploit it and pick different blocks for such inputs; plain `-O2`, `-O0`
and the AVX2 kernel do not. The reference is built with `-fwrapv`, under
which every build agrees, and the port computes that result: the wrapped
sum is the exact one, which always fits in 32 bits.

**Search.** Beyond the image set and seeded fuzz blocks, the corpus comes
from libFuzzer runs on the original (32 workers for 10 minutes, then 8 for
15 on the rarer modes, both with value profiles), minimized to blocks that
each add coverage, plus blocks found by a hill-climbing search on the port
(1,500 restarts per target mode) and by construction (tetrahedra of colours
per region, which make unsigned mode 0 win). What none of these reach:

- **Argument checks** of `tc_bc6h_compress_rgb32f` (1 line, 7 branches):
  null pointers, zero sizes, short strides or buffers. The port takes slices
  and asserts these instead.
- **Clamps the arithmetic rules out.** `tc_bc6h_quant_sf16` and
  `tc_bc6h_quant_sf16_n` clamp `q` to `maxq`, but
  `(mag * maxq + 15871) / 31743` with `mag <= 31743` is at most `maxq`.
  `tc_bc6h_pack_signed10` and `tc_bc6h_pack_signed_n` clamp to their field,
  and every caller passes an endpoint the quantizer or the refinement clamp
  already keeps inside it.
- **`!have[0] || !have[1]`** in every two-region search (2 branches each):
  all 32 partitions have texels in both regions.
- **Delta checks decided by comparison order** (2 branches in each
  candidate check): `d1 = hi0 - lo0` is never negative, and
  `d3 = hi1 - lo0 >= d2 = lo1 - lo0`, so `d3 < -limit` implies
  `d2 < -limit`, which is tested first.
- **`best_p < 0` in mode 9** (both formats): mode 9 has no fit check, so a
  partition always wins.
- **Switches without a default** (`mode_key`, 1 branch each) and the closing
  brace after a case's `break` (3 lines each in `tc_bc6h_mode234_uf16` and
  `tc_bc6h_mode678_uf16`): dead by construction.
- **Coverage-mapping artefacts** (1 line each in the four mode 12 and 13
  encoders and in `tc_bc6h_mode678_sf16`): the statement after a bare
  `{ ... }` block that contains an early `return` or a `switch` is counted 0,
  though the lines around it run thousands of times (in
  `tc_bc6h_mode12_uf16`, line 1941 counts 6.6k and line 1942 0).
- **Unsigned modes 2 to 4, refinement and anchor swap** (24 lines and 28
  of the 32 branches of `tc_bc6h_mode234_uf16`): the determinant is always
  zero. These modes judge 11-bit endpoints with the 10-bit palette, so every
  palette entry is about twice its target value (or saturated when the
  endpoint is at least 1023); and `tc_float_to_half_bits` flushes values
  below 2^-14, so a nonzero target is never small enough to break this.
  The nearest entry is then the smallest for every texel of a region: one
  selector, a zero determinant, endpoints unchanged, the fit check passing,
  the error equal (so the loop leaves in its first round), and index 0 at
  the anchor (so no swap).
- **Refinement clamps and fit failures not reached**: `l < 0` and `h < 0`
  in unsigned mode 0, three clamps and the `d1`/`d3` refit failures of
  unsigned mode 5, `h > maxv` in unsigned modes 6 to 8, and all four clamps of
  signed modes 2 to 4. For unsigned mode 0 the reason is the same flush:
  any nonzero endpoint is at least 33 steps above 0 while a region spans at
  most 31, so a fit reaching below 0 would have to extrapolate past the
  region's own spread. The others are not proven unreachable; none of the
  searches above found an input.
- **Modes that never improve on the chain where they are tried**
  (`tc_encode_bc6h_block_uf16`, 11 branches; `tc_encode_bc6h_block_sf16`,
  1):
  - Unsigned modes 2 to 4 (3 branches, plus the two re-checks of the
    threshold after them): if the deltas of mode 2 fit, every texel lies in a
    box at most 480 x 233 x 233 in the magnitude domain (modes 3 and 4
    permute it). No point of that box is further than 272 from its main
    diagonal, the line mode 10's bounding-box candidate uses, so mode 10's
    error is at most about 16 x 77,000 = 1.2M, under the 3.1M threshold, and
    the chain stops before mode 2.
  - The repeat of mode 10 (1 branch): `tc_bc6h_mode10_uf16` recomputes the
    first mode 10 encoding, whose error is the chain's starting best, so
    it is never strictly lower.
  - Unsigned modes 5, 12 and 13 (3 branches) and signed modes 2 to 4
    (1 branch): not found. Each is judged with a palette at the wrong scale
    (half, quarter or double the targets), which keeps its estimate above
    the errors it competes with; the searches found blocks where these modes
    can encode, but never better.
  - The re-checks after unsigned modes 6 and 7 win (2 branches): they need
    mode 6 or 7 to bring the error under the threshold. They win only on
    blocks far above it; the closest a targeted search came was 337,000 over.

### BC6H: texcomp_bc6h_decode.c

- **Argument checks** of `tc_bc6h_decompress_rgb16f` and
  `tc_bc6h_decompress_rgbaf` (1 line and 6 branches each), asserted by the
  port as for the other image decoders.
- **`tc_bc6h_rd`**: its 32-bit mask case; no field is wider than 16 bits.
- **`tc_bc6h_h2f`**: infinity and NaN (1 line, 1 branch). The block decoder's
  largest magnitude is 0x7bff, so it never produces them. The port's
  `halfToF32` handles them and is tested against Zig's own conversion on all
  65,536 halves.
