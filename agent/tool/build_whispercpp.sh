#!/usr/bin/env bash
# Builds the whisper.cpp shim for one OS and CPU architecture.
#
# Usage: agent/tool/build_whispercpp.sh <whisper.cpp-source> [output-dir]
#            [architecture: x64|arm64] [macos-deployment-target]
#
# The daemon loads the result through dart:ffi (see stt_native_platform.dart and
# whispercpp_bindings.dart). The output directory holds the whisper/ggml
# libraries beside the shim, and **every** shipped library records a
# self-relative search path, so the folder is relocatable. On Linux that means
# an `$ORIGIN` RUNPATH on each member and not only on the shim: glibc resolves a
# library's DT_NEEDED through that library's own RUNPATH, so a shim-only rpath
# still leaves `libwhisper.so.1`'s `libggml*.so.0` unfound outside the build
# tree. macOS reaches the same place through `@rpath` install names, which dyld
# resolves against the whole load chain.
#
# The architecture is explicit because the output directory is
# architecture-qualified (`native/macos-arm64`, `native/macos-x64`, …): building
# the other slice on this host would publish a runtime the loader must reject.
# A real Intel build therefore comes from an Intel host (`macos-15-intel`), not
# from a cross-architecture flag on Apple Silicon. The deployment target keeps
# the dylibs loadable on the oldest macOS the shipped Client supports instead of
# inheriting the build runner's newer SDK default.
#
# The build is **portable, never native**. ggml defaults to `GGML_NATIVE=ON`,
# which compiles `-march=native`, so the shipped libraries require whatever the
# build runner's CPU happens to have. v1.0.22 shipped exactly that: the arm64
# runtime was built on a runner with SVE2/i8mm/BF16 and trapped with SIGILL
# (`ILL_ILLOPC`, inside `ggml_cpu_init`) on an Ampere Neoverse-N1 whose Armv8.2-A
# cores have neither. `GGML_NATIVE=OFF` makes ggml use its portable baseline and
# its runtime feature detection instead. On Linux arm64 the baseline is pinned
# explicitly to `armv8.2-a+dotprod+fp16` — the widest floor the release host
# proves, and the one that keeps the Q8 dot-product kernels — because a
# non-native build otherwise inherits the compiler's default, which is not a
# contract. `docs/technical/native_stt_runtime_platforms.md` owns the per-target
# table of instruction sets this script now requires.
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

# The portable baseline every configure below uses. `GGML_NATIVE=OFF` is what
# makes ggml's own runtime feature detection decide at load time instead of the
# build runner's toolchain deciding at compile time.
ggml_native=OFF
# An explicit arm64 floor rather than the compiler's default: the shipped Linux
# arm64 runtime must run on the oldest arm64 host the release proves (Ampere
# Neoverse-N1: Armv8.2-A with dotprod and fp16, no SVE/SVE2, no i8mm, no bf16),
# and it must keep the dot-product kernels, which is where Q8 decoding spends
# its time. macOS arm64 needs no pin: every machine that runs it is Apple
# Silicon, whose baseline already includes these extensions.
ggml_arm_arch=""
if [ "$os" = linux ] && [ "$arch" = arm64 ]; then
  ggml_arm_arch=armv8.2-a+dotprod+fp16
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
  echo "build_plan_ggml_native=$ggml_native"
  echo "build_plan_ggml_arm_arch=$ggml_arm_arch"
  exit 0
fi

cd "$src"
metal=${GGML_METAL:-OFF}
if [ "$os" = linux ]; then metal=OFF; fi

if [ "$os" = macos ]; then
  # The same stale-tree rule as the Linux branch below, for the same reason and
  # one more: Apple Silicon is not one CPU. M2 and newer implement i8mm and
  # BF16 that M1 does not, so a macOS tree configured `GGML_NATIVE=ON` on a
  # newer host produces dylibs that trap on the oldest supported Mac.
  if [ -f build/CMakeCache.txt ] &&
     ! grep -qF "GGML_NATIVE:BOOL=$ggml_native" build/CMakeCache.txt; then
    rm -rf build
  fi
  cmake -B build -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=ON \
    -DGGML_NATIVE="$ggml_native" \
    -DGGML_METAL="$metal" \
    -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_BUILD_EXAMPLES=OFF \
    -DCMAKE_OSX_ARCHITECTURES="$cmake_arch" \
    ${deploy_target:+-DCMAKE_OSX_DEPLOYMENT_TARGET="$deploy_target"} >/dev/null
else
  # A restored CI cache, or a developer's earlier build, can leave a CMake tree
  # whose link flags or CPU baseline predate this script's contract. CMake
  # reconfigures, but the Makefile generator only compares timestamps, so the
  # stale libraries would be reused unchanged: the tree then ships either a
  # runtime that cannot find its own siblings or one compiled `-march=native`
  # for whatever CPU produced it. The builder therefore discards a tree that
  # does not record both contracts, exactly as the Windows builder discards one
  # configured for another platform: no workflow cache key can guarantee a
  # developer's tree.
  if [ -f build/CMakeCache.txt ] &&
     { ! grep -qF 'CMAKE_INSTALL_RPATH:STRING=$ORIGIN' build/CMakeCache.txt ||
       ! grep -qF 'CMAKE_BUILD_WITH_INSTALL_RPATH:BOOL=ON' build/CMakeCache.txt ||
       ! grep -qF "GGML_NATIVE:BOOL=$ggml_native" build/CMakeCache.txt; }; then
    rm -rf build
  fi
  # `CMAKE_BUILD_WITH_INSTALL_RPATH=ON` makes the build-tree libraries carry the
  # install rpath, which is what the staged copy ships. Without it CMake writes
  # the absolute build directory into every library, and that path never exists
  # on a user's machine.
  cmake -B build -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=ON \
    -DGGML_NATIVE="$ggml_native" \
    ${ggml_arm_arch:+-DGGML_CPU_ARM_ARCH="$ggml_arm_arch"} \
    -DGGML_METAL="$metal" \
    -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_BUILD_EXAMPLES=OFF \
    -DCMAKE_INSTALL_RPATH='$ORIGIN' \
    -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON >/dev/null
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
