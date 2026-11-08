#!/usr/bin/env bash
# Builds the whisper.cpp shim for one OS and CPU architecture.
#
# Usage: agent/tool/build_whispercpp.sh <whisper.cpp-source> [output-dir]
#            [architecture: x64|arm64] [macos-deployment-target]
#
# The daemon loads the result through dart:ffi (see stt_native_platform.dart and
# whispercpp_bindings.dart). The output directory holds the whisper/ggml
# libraries beside the shim, and the shim finds them through a self-relative
# rpath, so the folder is relocatable.
#
# The architecture is explicit because the output directory is
# architecture-qualified (`native/macos-arm64`, `native/macos-x64`, …): building
# the other slice on this host would publish a runtime the loader must reject.
# A real Intel build therefore comes from an Intel host (`macos-15-intel`), not
# from a cross-architecture flag on Apple Silicon. The deployment target keeps
# the dylibs loadable on the oldest macOS the shipped Client supports instead of
# inheriting the build runner's newer SDK default.
#
# Windows uses tool/build_whispercpp.ps1 instead (MSVC + CMake).
set -euo pipefail

src=${1:?usage: build_whispercpp.sh <whisper.cpp-source> [output-dir] [arch] [deployment-target]}

case "$(uname -s)" in
  Darwin) os=macos; shim=libsanad_whisper.dylib ;;
  Linux) os=linux; shim=libsanad_whisper.so ;;
  *) echo "Unsupported host: $(uname -s)" >&2; exit 1 ;;
esac

case "$(uname -m)" in
  x86_64|amd64|x64) host_arch=x64 ;;
  arm64|aarch64) host_arch=arm64 ;;
  *) echo "Unsupported host CPU: $(uname -m)" >&2; exit 1 ;;
esac

arch=${3:-$host_arch}
deploy_target=${4:-}
out=${2:-native/$os-$arch}
here=$(cd "$(dirname "$0")/.." && pwd)

if [ "$arch" != "$host_arch" ]; then
  echo "Refusing to build $arch on a $host_arch host: the artifact would not" >&2
  echo "run on the machines its directory name claims. Build that slice on a" >&2
  echo "$arch runner instead (the release matrix uses macos-26 for arm64 and" >&2
  echo "macos-15-intel for x64)." >&2
  exit 1
fi

# The tag-style architecture is the script's own contract; the CMake spelling
# is derived here and nowhere else, so a caller that passes `x86_64` fails the
# check above or the mapping below instead of silently building.
if [ "$os" = macos ]; then
  case "$arch" in
    x64) cmake_arch=x86_64 ;;
    arm64) cmake_arch=arm64 ;;
    *) echo "Unsupported macOS architecture: $arch" >&2; exit 1 ;;
  esac
fi

# Plan-only mode prints the resolved build inputs and writes nothing. It exists
# so the argument contract between `ensure_native_stt` and this script stays
# testable on a host that cannot build the requested slice.
if [ "${SANAD_BUILD_PLAN_ONLY:-0}" = "1" ]; then
  plan_metal=${GGML_METAL:-OFF}
  if [ "$os" = linux ]; then plan_metal=OFF; fi
  echo "build_plan_os=$os"
  echo "build_plan_arch=$arch"
  echo "build_plan_cmake_arch=${cmake_arch:-}"
  echo "build_plan_deploy_target=$deploy_target"
  echo "build_plan_metal=$plan_metal"
  echo "build_plan_out=$out"
  exit 0
fi

cd "$src"
metal=${GGML_METAL:-OFF}
if [ "$os" = linux ]; then metal=OFF; fi

if [ "$os" = macos ]; then
  cmake -B build -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=ON \
    -DGGML_METAL="$metal" \
    -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_BUILD_EXAMPLES=OFF \
    -DCMAKE_OSX_ARCHITECTURES="$cmake_arch" \
    ${deploy_target:+-DCMAKE_OSX_DEPLOYMENT_TARGET="$deploy_target"} >/dev/null
else
  cmake -B build -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=ON \
    -DGGML_METAL="$metal" \
    -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_BUILD_EXAMPLES=OFF >/dev/null
fi
cmake --build build -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu)" >/dev/null

mkdir -p "$here/$out"

if [ "$os" = macos ]; then
  min_flag=""
  if [ -n "$deploy_target" ]; then min_flag="-mmacosx-version-min=$deploy_target"; fi
  clang -dynamiclib -O2 -fPIC -arch "$cmake_arch" $min_flag \
    -I "$src/include" -I "$src/ggml/include" \
    "$here/native/whispercpp/sanad_whisper.c" \
    -L "$src/build/bin" \
    -lwhisper -lggml -lggml-base -lggml-cpu \
    -Wl,-rpath,@loader_path \
    -o "$here/$out/$shim"
  libs="libwhisper.1.dylib libggml.0.dylib libggml-base.0.dylib libggml-cpu.0.dylib libggml-blas.0.dylib"
  if [ "$metal" = ON ]; then libs="$libs libggml-metal.0.dylib"; fi
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

echo "built: $here/$out/$shim ($os-$arch${deploy_target:+, macOS $deploy_target})"
