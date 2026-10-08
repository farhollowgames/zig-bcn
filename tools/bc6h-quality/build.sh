#!/bin/sh
# Builds quality.cpp against texcomp (reference/texcomp) and DirectXTex,
# fetched into a work directory; the comparison is not part of `zig build test`.
#   tools/bc6h-quality/build.sh <work-dir>
# then: <work-dir>/quality [--dump <dir>] <image.exr|image.rgbf>...
set -eu
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
work=$1
mkdir -p "$work"
cd "$work"
fetch() { [ -d "$2" ] || git clone -q --depth 1 "https://github.com/$1/$2.git"; }
fetch microsoft DirectXTex
fetch microsoft DirectXMath
fetch microsoft DirectX-Headers
fetch syoyo tinyexr
mkdir -p sal
# DirectXMath needs the SAL annotation header, which Linux lacks; vcpkg uses
# this MIT-licensed one from .NET.
[ -f sal/sal.h ] || curl -sSfL https://raw.githubusercontent.com/dotnet/runtime/main/src/coreclr/pal/inc/rt/sal.h -o sal/sal.h
tc="$repo/reference/texcomp"
flags="-O2 -ffp-contract=off -fwrapv"
for f in texcomp texcomp_bc6h texcomp_bc6h_decode texcomp_bc7 texcomp_bc1 texcomp_bc3 texcomp_bc5; do
    clang $flags -std=c11 -I"$tc/include" -I"$tc/src" -c "$tc/src/$f.c" -o "$f.o"
done
clang $flags -std=c11 -I"$tc/include" -c "$repo/reference/shim/texcomp_stubs.c" -o texcomp_stubs.o
clang $flags -c tinyexr/deps/miniz/miniz.c -o miniz.o
inc="-IDirectXTex/DirectXTex -IDirectXMath/Inc -IDirectX-Headers/include -IDirectX-Headers/include/wsl/stubs -IDirectX-Headers/include/directx -Isal -Itinyexr -Itinyexr/deps/miniz -I$tc/include"
for f in BC6HBC7 BC; do
    clang++ $flags -std=c++17 $inc -c "DirectXTex/DirectXTex/$f.cpp" -o "$f.o"
done
printf '#define TINYEXR_IMPLEMENTATION\n#include "tinyexr.h"\n' > tinyexr_impl.cpp
clang++ $flags -std=c++17 $inc -c tinyexr_impl.cpp -o tinyexr_impl.o
clang++ $flags -std=c++17 $inc -c "$here/quality.cpp" -o quality.o
clang++ -o quality quality.o BC6HBC7.o BC.o tinyexr_impl.o miniz.o texcomp*.o -lm
echo "built $work/quality"
