#!/usr/bin/env bash
# Builds the whisper.cpp shim for the host desktop platform (macOS or Linux).
#
# Usage: agent/tool/build_whispercpp.sh <whisper.cpp-source> [output-dir]
#
# The daemon loads the result through dart:ffi (see whispercpp_bindings.dart).
# The output directory holds the whisper/ggml libraries beside the shim, and the
# shim finds them through a self-relative rpath, so the folder is relocatable.
#
# Windows uses tool/build_whispercpp.ps1 instead (MSVC + CMake).
set -euo pipefail

src=${1:?usage: build_whispercpp.sh <whisper.cpp-source> [output-dir]}

case "$(uname -s)" in
  Darwin) os=macos; shim=libsanad_whisper.dylib; whisper=runtime ;;
  Linux) os=linux; shim=libsanad_whisper.so; whisper=runtime ;;
  *) echo "Unsupported host: $(uname -s)" >&2; exit 1 ;;
esac
out=${2:-native/$os}
here=$(cd "$(dirname "$0")/.." && pwd)

cd "$src"
metal=${GGML_METAL:-OFF}
if [ "$os" = linux ]; then metal=OFF; fi
cmake -B build -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=ON \
  -DGGML_METAL="$metal" \
  -DWHISPER_BUILD_TESTS=OFF \
  -DWHISPER_BUILD_EXAMPLES=OFF >/dev/null
cmake --build build -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu)" >/dev/null

mkdir -p "$here/$out"

if [ "$os" = macos ]; then
  clang -dynamiclib -O2 -fPIC \
    -I "$src/include" -I "$src/ggml/include" \
    "$here/native/whispercpp/sanad_whisper.c" \
    -L "$src/build/bin" \
    -lwhisper -lggml -lggml-base -lggml-cpu \
    -Wl,-rpath,@loader_path \
    -o "$here/$out/$shim"
  libs="libwhisper.1.dylib libggml.0.dylib libggml-base.0.dylib libggml-cpu.0.dylib libggml-blas.0.dylib libggml-metal.0.dylib"
else
  cc -shared -fPIC -O2 \
    -I "$src/include" -I "$src/ggml/include" \
    "$here/native/whispercpp/sanad_whisper.c" \
    -L "$src/build/bin" \
    -lwhisper -lggml -lggml-base -lggml-cpu \
    -Wl,-rpath,'$ORIGIN' \
    -o "$here/$out/$shim"
  libs="libwhisper.so.1 libggml.so.0 libggml-base.so.0 libggml-cpu.so.0 libggml-blas.so.0"
fi

# Ship only the canonical names the dylibs reference through their rpath. The
# build tree also has version-suffixed duplicates and unversioned aliases;
# copying those tripled the folder for no runtime benefit.
for lib in $libs; do
  if [ -f "$src/build/bin/$lib" ]; then
    cp -f "$src/build/bin/$lib" "$here/$out/$lib"
  fi
done

echo "built: $here/$out/$shim"
