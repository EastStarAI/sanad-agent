#!/usr/bin/env bash
# Builds libsanad_whisper.dylib for macOS arm64 from a local whisper.cpp tree.
#
# Usage: agent/tool/build_whispercpp.sh <whisper.cpp-source> [output-dir]
#
# The daemon loads the result through dart:ffi (see whispercpp_bindings.dart).
# The output directory must contain libwhisper/libggml*.dylib next to the shim;
# the shim finds them through @loader_path, so the folder is relocatable.
set -euo pipefail

src=${1:?usage: build_whispercpp.sh <whisper.cpp-source> [output-dir]}
out=${2:-native/macos}
here=$(cd "$(dirname "$0")/.." && pwd)

cd "$src"
cmake -B build -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=ON \
  -DGGML_METAL="${GGML_METAL:-OFF}" \
  -DWHISPER_BUILD_TESTS=OFF \
  -DWHISPER_BUILD_EXAMPLES=OFF >/dev/null
cmake --build build -j"$(sysctl -n hw.ncpu)" >/dev/null

mkdir -p "$here/$out"

clang -dynamiclib -O2 -fPIC \
  -I "$src/include" -I "$src/ggml/include" \
  "$here/native/whispercpp/sanad_whisper.c" \
  -L "$src/build/bin" \
  -lwhisper -lggml -lggml-base -lggml-cpu \
  -Wl,-rpath,@loader_path \
  -o "$here/$out/libsanad_whisper.dylib"

# Ship the whisper.cpp libraries beside the shim (they are ~2 MB together).
for lib in "$src"/build/bin/libwhisper.*.dylib "$src"/build/bin/libggml*.dylib; do
  base=$(basename "$lib")
  # Drop the version suffix so @rpath/libggml.0.dylib resolves to a stable name.
  case "$base" in
    *.dylib) cp -f "$lib" "$here/$out/$base" ;;
  esac
done

echo "built: $here/$out/libsanad_whisper.dylib"
