# Reference sources (test-only)

The original encoders, built only by `zig build test` as the oracle for the
differential tests. Nothing here is part of the `bcn` package (see the
`paths` in `build.zig.zon`). Files are copied unmodified.

| directory | source | version | licence |
| --- | --- | --- | --- |
| `stb/` | `stb_dxt.h` from [nothings/stb](https://github.com/nothings/stb) | v1.12, commit `2c980bb` | MIT or public domain (end of file) |
| `bc7e/` | `encoder/basisu_bc7e_scalar.{cpp,h}` from [BinomialLLC/basis_universal](https://github.com/BinomialLLC/basis_universal) | tag `v2_50` (`9bebe16`) | Apache 2.0 (`bc7e/LICENSE`) |
| `texcomp/` | `tools/texcomp/{include,src}` from [syoyo/tinyexr](https://github.com/syoyo/tinyexr): the BC1, BC3, BC5, BC6H and BC7 sources and the common core | commit `644148d` | Apache 2.0 (`texcomp/LICENSE`, `texcomp/NOTICE.md`) |
| `shim/` | small C ABI wrappers and link stubs written for the tests | | Apache 2.0, as the repository |

texcomp's BC1, BC3, BC5 and BC7 files are here for their decoders, which
check the Zig decoders; their encoders are not used.
