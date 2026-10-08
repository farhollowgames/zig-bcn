# Coverage and equivalence

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
| `stb_dxt.h` (BC1, BC3, BC4, BC5), both rounding builds | every function, line and branch | 14 images × 4 settings × 2 stb modes, 200,000 crafted blocks × 4 settings |
| texcomp BC1, BC3, BC4, BC5 decoders | every line and branch of the block decoders; the image decoders as declared below | 20,000 random blocks; random streams at five sizes with a wide stride |

## Declared gaps

### texcomp image decoders

- `tc_bc1_decompress_rgba8`, `tc_bc3_decompress_rgba8`: 1 line and 6
  branches each are the argument checks (null pointers, zero size, short
  stride or buffer), which return an error. The Zig decoders take slices and
  assert these conditions instead, so there is no error path to compare.
- `tc_bc5_decompress_rgba8`: the same argument checks (1 line, 6 branches),
  plus the BC5 SNORM path (8 lines, 3 branches). stb_dxt encodes BC4 and BC5
  as UNORM only, and zig-bcn offers what it ports.
