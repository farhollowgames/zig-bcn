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
zig build coverage   # the same tests, instrumented; fails if coverage drops
```

`zig build coverage` needs `clang`, `clang++`, `llvm-profdata` and `llvm-cov`
from one LLVM release on the `PATH` (it was set up with LLVM 23). It prints a
per-file summary and writes to `zig-out/coverage/`: `report.txt`,
`functions.txt` (per function) and `show/` (per-line counts; uncovered lines
have a count of 0 and missed branch directions show `: 0]`).

## Status

| original | translated code covered | byte-identical on |
| --- | --- | --- |
| `stb_dxt.h` (BC1, BC3, BC4, BC5), both rounding builds | every function, line and branch | 14 images × 4 settings × 2 stb modes, 200,000 crafted blocks × 4 settings, varying alpha included |
| texcomp BC1, BC3, BC4, BC5 decoders | every line and branch of the block decoders; the image decoders as declared below | 20,000 random blocks; random streams at five sizes with a wide stride |
| `basisu_bc7e_scalar.cpp` (BC7) | every line and branch except assert failure branches, helpers the original never calls, and paths ruled out by their enclosing conditions, all declared below | 14 images × 7 levels × 2 metrics; 3,000 crafted blocks × 14 presets, the 2 base inits and 46 setting variants; the image set × 46 variants; single-mode on 390 crafted blocks × 5 settings, every mode, rotation, index selector and forced partition |
| texcomp BC7 decoder | every line and branch except as declared below | 80,000 random blocks in every mode and the reserved one; 12,000 encoded blocks; 14 encoded images at 61 × 47 |

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
