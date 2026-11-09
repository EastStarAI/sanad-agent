---
title: "Native Dictation Runtime Platforms"
description: "Platform tag, directory layout, portable instruction-set baseline, verification rules, and release staging for the in-process whisper.cpp and sherpa-onnx dictation runtimes, including macOS Intel (x64) and the whisper-only Linux arm64 build."
---

# Native Dictation Runtime Platforms

The local dictation engine is native code loaded through `dart:ffi` inside the
agent daemon. Two runtimes share one packaged directory: the whisper.cpp shim
(`libsanad_whisper`) and, where the build includes it, the sherpa-onnx engine
(`libsherpa-onnx-c-api`). Their binaries are per-OS and
**per-CPU-architecture** build products, are not tracked in git, and must be
reproducible on the machine that will load them.

This page owns the platform matrix, where each build lives, what a verification
proves, and how a packaged Agent receives the runtime. It does not own the
dictation transport or model catalog; see
[Local Dictation](local_dictation.md) for those.

## Engine availability

The sherpa-onnx engine is a swappable local package
(`agent/packages/stt_sherpa`), because `package:sherpa_onnx` declares
`environment: flutter` and the Linux arm64 Agent is built with the standalone
Dart SDK. That lane selects `agent/packages/stt_sherpa_stub` through
`agent/tool/pubspec_overrides.no_sherpa.yaml`, so the Agent still builds and
still dictates — through whisper.cpp only.

| Build | Engines | Local modes | Streaming/VAD |
|---|---|---|---|
| macOS arm64/x64, Windows x64, Linux x64 | whisper.cpp + sherpa-onnx | batch + streaming | yes |
| Linux arm64 | whisper.cpp | batch only | no |

`SttEngineAvailability` in `agent/lib/infrastructure/stt/stt_types.dart` is the
single answer the daemon asks: model selection, the model rows, and readiness
all read it, and `agent/test/stt/engine_availability_test.dart` proves both
builds on one machine. A build without sherpa is not a degraded error state —
the Client already renders a stream that publishes finals only.

That build still has an English model: `whisper-small-en-ggml-q8` and
`whisper-medium-en-ggml-q8` are whisper.cpp batch entries. Before them every
`language: 'en'` row was a sherpa streaming export, so a whisper-only build could
not take English dictation at all — the engine decoded the clip with the Arabic
model's language and returned Arabic text.

## Platform matrix

One tag names everything: the directory under `agent/native/`, the
`checksums.json` artifact key, and the staged release directory.

| Tag | Directory | Shim | Required libraries | Backend |
|---|---|---|---|---|
| `macos-arm64` | `agent/native/macos-arm64/` | `libsanad_whisper.dylib` | shim, `libwhisper.1`, `libggml.0`, `libggml-base.0`, `libggml-cpu.0`, `libggml-blas.0`, `libggml-metal.0` | CPU + Metal |
| `macos-x64` | `agent/native/macos-x64/` | `libsanad_whisper.dylib` | shim, `libwhisper.1`, `libggml.0`, `libggml-base.0`, `libggml-cpu.0`, `libggml-blas.0` | CPU |
| `windows-x64` | `agent/native/windows-x64/` | `sanad_whisper.dll` | `whisper.dll`, `ggml.dll`, `ggml-base.dll`, `ggml-cpu.dll` | CPU |
| `windows-arm64` | `agent/native/windows-arm64/` | `sanad_whisper.dll` | same as above | CPU |
| `linux-x64` | `agent/native/linux-x64/` | `libsanad_whisper.so` | `libwhisper.so.1`, `libggml.so.0`, `libggml-base.so.0`, `libggml-cpu.so.0` | CPU |
| `linux-arm64` | `agent/native/linux-arm64/` | `libsanad_whisper.so` | same as above | CPU |

Apple Silicon keeps the Metal backend and its `use_gpu` default. Intel macOS
runs the CPU baseline: the Metal library is not built, not required, and not
verified, so a packaged Intel Agent has no GPU dependency. `use_gpu` remains
accepted on Intel; whisper.cpp simply has no GPU backend to bind.

`defaultSttUseGpu()` is the single owner of that default, and it answers from the
running ABI (`defaultSttUseGpuFor`, so the carve-out is testable from any host).
An absent `use_gpu` — whether the whole `config.yaml` is missing or only the key
is — resolves through it; a literal constructor default must never decide it.

## Portable instruction-set baseline

Every shipped runtime is built for the **declared floor of its target**, never
for the machine that produced it. ggml defaults to `GGML_NATIVE=ON`, which
compiles `-march=native` / `-mcpu=native`: ggml's feature questions then become
compile-time constants, so the kernels that run are the ones the build runner's
CPU can execute. v1.0.22 shipped exactly that. The arm64 runtime was compiled on
a runner with SVE2/i8mm/BF16 and the first install on an Ampere Neoverse-N1
(`fp asimd … asimddp`, no `sve`/`i8mm`/`bf16`) died with `SIGILL`
(`ILL_ILLOPC` at `ggml_cpu_init+0x238`) before any audio was read.

Both builders therefore configure `-DGGML_NATIVE=OFF`, and the stale-tree guards
discard a tree whose `CMakeCache.txt` does not record it. What each target then
requires is a contract, not an accident of the runner's toolchain:

| Tag | Producer | Configured baseline | Instruction sets the payload requires |
|---|---|---|---|
| `linux-arm64` | `ubuntu-24.04-arm` | `-DGGML_NATIVE=OFF -DGGML_CPU_ARM_ARCH=armv8.2-a+dotprod+fp16` | Armv8.2-A with NEON/ASIMD, `dotprod` and `fp16` vector arithmetic. **No** SVE/SVE2, I8MM or BF16 |
| `linux-x64` | `ubuntu-24.04` | `-DGGML_NATIVE=OFF`, ggml non-native defaults | SSE4.2, AVX, AVX2, FMA, F16C, BMI2. **No** AVX-512 |
| `macos-arm64` | `macos-26` | `-DGGML_NATIVE=OFF`, no `-march` | The Apple clang arm64 baseline: dotprod, FP16 vector arithmetic, FMA. **No** I8MM, SVE or BF16 |
| `macos-x64` | `macos-15-intel` | `-DGGML_NATIVE=OFF`, ggml non-native defaults | SSE4.2, AVX, AVX2, FMA, F16C, BMI2. **No** AVX-512 |
| `windows-x64` | `windows-2025` | `-DGGML_NATIVE=OFF`, MSVC `/arch:AVX2` | AVX2 (FMA/F16C are implied by that switch) |
| `windows-arm64` | *no producing lane* | native only — MSVC has no portable ggml mode on ARM | Whatever CPU built it; **not** a portable artifact |

Two consequences are recorded rather than hidden:

- **Owner note (support matrix).** ggml's non-native x64 default turns
  `GGML_AVX2`/`FMA`/`F16C`/`BMI2` **on** (`INS_ENB` is `ON` whenever
  `GGML_NATIVE=OFF` and the build is not cross-compiling), so every x64 payload —
  Linux, macOS and Windows — requires AVX2. AVX-512 stays off. A CPU without
  AVX2 (pre-2013 x64) cannot run local dictation on those targets. **Decided by
  the owner on 2026-11-09: the AVX2/FMA/F16C/BMI2 floor is kept because
  performance is the priority on x64, and lowering it is not planned.** Lowering
  it would be a one-line change (`-DGGML_AVX2=OFF`, then `-DGGML_AVX=OFF` and
  friends to match), but it trades dictation speed for pre-2013 hardware, so
  reviving it requires a new owner decision recorded here rather than a build
  detail.
- **`windows-arm64` is a declared row without a producer.** ggml aborts the
  configure when `GGML_NATIVE=OFF` is combined with MSVC on ARM ("use clang for
  `GGML_CPU_ARM_ARCH`"), so the Windows builder keeps native compilation for
  that architecture alone and no lane publishes it. Adding the lane requires a
  clang toolchain first; until then an arm64 Windows runtime must not be
  described as portable.

The Linux arm64 floor is pinned explicitly instead of inheriting the compiler's
default. A non-native build appends no `-march` when `GGML_CPU_ARM_ARCH` is
empty, so "portable" would then mean "whatever this `gcc` defaults to" — not a
contract, and it also drops the dot-product kernels that Q8 decoding spends its
time in. `armv8.2-a+dotprod+fp16` is the widest floor the release host proves.

### The engine subtree

The sherpa-onnx libraries live in a `sherpa/` subdirectory of the same tag
directory, because `package:sherpa_onnx` is handed **one directory** and appends
its own per-platform path to it. `SttNativeTarget.sherpaLibraries` owns that
list; the packaged layout is:

| Tag | Members under `native/<tag>/sherpa/` |
|---|---|
| `macos-arm64`, `macos-x64` | `sherpa_onnx_macos/sherpa-onnx.xcframework/macos-arm64_x86_64/libsherpa-onnx-c-api.dylib` (universal) |
| `windows-x64`, `windows-arm64` | `sherpa-onnx-c-api.dll`, `onnxruntime.dll` |
| `linux-x64` | `libsherpa-onnx-c-api.so`, `libonnxruntime.so` |
| `linux-arm64` | none — the build has no sherpa engine |

`DictationService.sherpaNativeDirectory` passes that directory to the engine, and
`agent/test/stt/sherpa_runtime_smoke_test.dart` loads the library from the
staged payload in release staging and in the pull-request lane, so a layout the
loader cannot read fails before publication. On Windows the runtime is preloaded
by path first: Windows resolves a DLL's imports from the process search path,
not from the DLL's own directory — the same rule the whisper shim follows. That
preload lives in `agent/packages/stt_sherpa/lib/src/sherpa_bindings.dart`, which
the worker calls, so the packaging smoke test and the daemon exercise one loader
instead of two.

A **source checkout** has no `native/<tag>/sherpa/` directory, and it needs none:
when the packaged copy is absent, `sherpaNativeDirectory` falls back to
`package:sherpa_onnx`'s own resolution (`sherpaNativeSourceDirectory()`, the same
directory release staging copies from) and passes that explicit path to the
worker. Passing `null` would leave the engine to resolve the library itself, and
on macOS that is `DynamicLibrary.process()` — valid only inside a Flutter host.
`ensure_native_stt --stage` therefore stays a packaging step, not a developer
prerequisite; readiness reports `sherpa_runtime_missing` only when neither source
yields the library.

The archive contract allows exactly this nesting and nothing else: members are
`native/<tag>/<library>` or `native/<tag>/sherpa/<loader-relative library>`, at
most six segments, library names only. The agent's own updater, the Client
bootstrap installer, `scripts/install.sh`, and `scripts/install.ps1` each enforce
it, and the macOS member is long enough that the archive writer uses the ustar
`prefix` field instead of truncating the path.

### Ownership

| Concern | Owner |
|---|---|
| Tag, directory, required files, Metal per architecture, deployment target | `agent/lib/infrastructure/stt/stt_native_platform.dart` |
| The engine's own directory and loader-relative libraries | `SttNativeTarget.sherpaNativeSubdirectory`, `SttNativeTarget.sherpaLibraries` |
| Which engines a build can run | `SttEngineAvailability` (`stt_types.dart`) over `package:sanad_stt_sherpa` |
| Discovery of the shim at runtime, readiness probe, `dart:ffi` entry points | `agent/lib/infrastructure/stt/whispercpp_bindings.dart` |
| Install, verify, stage, and archive | `agent/tool/ensure_native_stt.dart`, `stt_native_runtime.dart`, `stt_native_archive.dart` |
| Build from a whisper.cpp tree | `agent/tool/build_whispercpp.sh`, `agent/tool/build_whispercpp.ps1` |
| Which platform may dictate at all | `DictationService` platform gate (see the integration hook below) |

The mapping reads `Abi.current()`, never a substring of `Platform.version`. A
version string is not an architecture: it is a kernel/SDK description, so a
substring match both misfires and cannot express "this build is x64".

## Relocatable runtime: every member carries its own search path

A packaged runtime is a **folder**, not an installed library: `<home>/bin/native/<tag>/`
is never on the loader's search path, and the generated service unit sets no
`LD_LIBRARY_PATH` on purpose — the payload has to work as it was shipped. The
shim is therefore not the only member that needs a self-relative search path.

| Platform | What makes the folder relocatable |
|---|---|
| Linux | `DT_RUNPATH` = `$ORIGIN` on **every** shipped library |
| macOS | install names `@rpath/…`, resolved through the shim's `LC_RPATH @loader_path` |
| Windows | the loader preloads each sibling by absolute path before the shim opens |

The Linux rule is not cosmetic. glibc resolves a library's `DT_NEEDED` through
**that library's own** RUNPATH and does not inherit the search path of the image
that loaded it, so a shim-only `$ORIGIN` resolves `libwhisper.so.1` and then
fails on `libwhisper.so.1`'s own `libggml*.so.0`. dyld behaves differently — it
walks the whole load chain — which is why the macOS dylibs need no change: they
carry `@rpath` install names and find each other through the shim's
`@loader_path`.

v1.0.22 shipped exactly the broken shape. Only the shim was linked with
`-Wl,-rpath,'$ORIGIN'`; the whisper/ggml libraries were copied out of the cmake
build carrying the absolute build directory as their RUNPATH, and the first
arm64 install failed with
`libggml.so.0: cannot open shared object file: No such file or directory`.
`agent/tool/build_whispercpp.sh` therefore configures the Linux build with
`-DCMAKE_INSTALL_RPATH='$ORIGIN' -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON` — the
second flag is what puts the install value into the build-tree libraries the
staging step copies — and it discards a restored build tree whose cache does not
record that contract, because the Makefile generator compares timestamps only
and would otherwise reuse the stale libraries unchanged. The same guard also
requires `GGML_NATIVE:BOOL=OFF` (see
[Portable instruction-set baseline](#portable-instruction-set-baseline)), and the
CI and release whisper build-cache keys carry a version token for the same
reason: they are at `whisper-build-v4-…`, naming both contracts.

### What `--verify` proves about relocatability

Two separate checks, because each one alone can pass on a broken payload:

- `origin_runpath_missing:<file>` — every Linux library must record `$ORIGIN`
  (or a path list containing it). `--verify` also prints
  `native_stt_runpath_<file>=<paths>` per member as evidence.
- `native_stt_ldd_<file>=ok|not_found:<names>` — `checkLoaderResolution` asks the
  real loader, running `ldd` on every shipped library **from another working
  directory**, and fails when a shipped name is unresolved. A recorded `$ORIGIN`
  is necessary but not sufficient, and a hash plus an architecture check both
  pass on the broken shape; only the loader can answer.

The engine libraries under `sherpa/` are third-party prebuilt bytes that this
repository cannot relink, so a missing `$ORIGIN` there is a stated warning
(`origin_runpath_missing:<key>`), never a failure no change in this tree could
clear. Whether the packaged sherpa Linux payload loads the same way is a
follow-up, not a claim made here.

### What `--verify` proves about the instruction set

`native_stt_isa_<file>=ok|forbidden:<mnemonic>` — on Linux, `--verify`
disassembles every shipped library with `objdump -d` and fails when any
instruction is above the target's declared baseline: SVE/SVE2 (`z` vector and
`p` predicate operands, `ptrue`, `whilelt`, `whilelo`, …), I8MM
(`smmla`/`ummla`/`usmmla`/`usdot`/`sudot`) or BF16 (`bfdot`/`bfmmla`/`bfcvt*`) on
arm64, and AVX-512 (`%zmm` / `%k` mask registers, `{z}`, `{1toN}`) on x64.
Mnemonics alone would miss the case that actually faulted: SVE reaches a binary
as a `z`/`p` operand on an ordinary `fadd`/`ld1w`, so operand shapes are matched
too. `sdot`/`udot` are inside the arm64 baseline and stay allowed, or the guard
would reject the runtime this repository builds on purpose.

No other gate can see this. A hash, a machine-architecture header and `ldd` all
pass on a `-march=native` build, which is why v1.0.22 printed
`native_stt_ldd_*=ok` for five libraries that could not execute a single
instruction on the target host.

Where the check cannot apply it says so rather than passing quietly: a non-Linux
host prints `native_stt_isa=skipped`, and its payload is pinned by the builder
contract plus the real load smoke. A lane that declares itself the proof lane
(`SANAD_STT_REQUIRE_NATIVE=1`, set by every `native-stt` CI job and by the
release Agent job) turns a missing disassembler into `isa_guard_unavailable:objdump`
instead, so the guard cannot skip silently in CI; the lanes install `binutils`
when the image lacks it. `sherpa/` libraries are not disassembled: they are
third-party bytes this repository does not build.

## Directory layout and the bounded legacy alias

The daemon looks for the shim in this order (first existing, architecture-matching
file wins):

1. `$SANAD_WHISPER_LIBRARY` when set;
2. `<executable dir>/native/<tag>/`;
3. `<executable dir>/../native/<tag>/`;
4. `<working dir>/native/<tag>/`;
5. `<working dir>/agent/native/<tag>/`.

Apple Silicon additionally probes `<location>/native/macos/` after the qualified
directory. That alias exists because `agent/native/macos/` was only ever
populated by arm64 builds, so accepting it cannot select a foreign slice. Linux
and Windows have **no** legacy alias: their unqualified directory could hold
either architecture, and the architecture-qualified name is the whole point of
the change. A pre-existing `agent/native/linux` or `agent/native/windows`
directory is therefore ignored; run the installer once to rebuild into the
qualified directory.

Writes always target the qualified directory. Nothing publishes to a legacy
path. Publishing replaces `native/<tag>/` with a recoverable two-rename swap:
the previous directory is parked at `native/<tag>.old` between the two renames
and restored on failure. It is not an atomic directory exchange, so a momentary
absence of the qualified directory is never "runtime uninstalled", and no
consumer may treat it as one.

## Readiness semantics

`DictationService.readiness()` reports, for a selected whisper entry:

- `native_runtime_missing` — no architecture-matching shim was found;
- `native_runtime_preparing` — `native/.stt-preparing` (or a marker beside a
  candidate directory) is younger than 30 minutes, i.e. the installer is
  building or downloading;
- ready — an architecture-matching shim exists.

Existence alone is not readiness. A leftover arm64 dylib in `macos-x64/` would
otherwise be advertised as ready and fail inside the first session, so the probe
reads the file header and requires the running architecture. A non-binary or
header-less file in a library slot is rejected for the same reason.

**What readiness does not prove.** The probe reads a bounded header: it proves
*format and architecture*, nothing more. A file that kept an intact Mach-O/ELF/PE
header and was truncated afterwards is still reported ready and fails later
inside `DynamicLibrary.open`. Integrity (hashes, archive pins, signing) belongs
to `ensure_native_stt --verify` and to the load smoke under
`SANAD_STT_REQUIRE_NATIVE=1`; readiness is the cheap pre-flight, not the proof.

## Verification: two evidence classes

`fvm dart run tool/ensure_native_stt.dart --verify` never builds, downloads, or
mutates anything, and exits non-zero on any hard failure.

**Fresh build from the pinned whisper.cpp source tag** (`v1.9.5`) is proven by:

- every required library exists;
- every library's header reports the target architecture (Mach-O `cputype`, ELF
  `e_machine`, or PE `Machine`), so a cross-architecture artifact is rejected
  before publication;
- on Linux, every library records an `$ORIGIN` search path and the loader
  resolves every shipped member when it is asked from another working directory
  (see [Relocatable runtime](#relocatable-runtime-every-member-carries-its-own-search-path));
- on Linux, no library contains an instruction above the target's declared
  baseline (see [the instruction-set guard](#what---verify-proves-about-the-instruction-set));
- on macOS, the recorded minimum OS is not newer than the shipped Client floor
  (see below);
- the release/CI smoke test opens the shim in a real process of that
  architecture, which also resolves its whisper/ggml siblings through the
  self-relative rpath.

Its bytes are new, so pinned per-file hashes are advisory: a difference is a
warning naming the file, not a failure.

**Published binary download** is proven by the pinned `_archive` sha256 before
extraction, then by the pinned per-file hashes. A download with no pinned
archive hash fails closed, and so does a download whose entry has no per-file
pins: `requirePinnedHashes` turns a missing or malformed pin into a hard failure
(`pinned_hash_missing:<file>`), and a known-`unpinned` entry can never pass that
layer as pinned (`pin_state_unpinned:<tag>`).

### Pin states in `agent/native/checksums.json`

| `_status` | Meaning |
|---|---|
| absent | Per-file hashes are authoritative for the published artifact. |
| `locally-built` | Hashes came from one local build; no producing workflow exists yet. |
| `unpinned` | No per-file hashes are recorded; only presence, architecture, and deployment-target checks apply. |

`pinned` is reported only when the entry is authoritative **and** the bytes match
it; a locally built runtime that differs from a pinned artifact reports the
comparison warning and is never labelled `pinned`.

`--verify` prints the pin state and the unpinned file count, so `unpinned` is
never a silent pass. A **missing artifact key is a hard failure** for `--verify`
and `--stage`: a platform must declare its provenance before it can be staged.
Every platform in the matrix therefore has an entry, even when that entry only
says `unpinned`, and adding a target to the shared mapping without an entry
breaks the build lane for that target.

`macos-x64` is `unpinned` on purpose. Recording Intel hashes requires an
authorized producer run on `macos-15-intel`; inventing them would be worse than
stating that they are pending.

## macOS deployment target

macOS builds pass `-DCMAKE_OSX_DEPLOYMENT_TARGET=12.0` (and
`-mmacosx-version-min`) so the dylibs load on the oldest macOS the shipped Client
supports (`client/macos/Podfile`), instead of inheriting the newer build runner's
SDK default. A dylib built on a macOS 26 runner without that flag can require
macOS 26 and refuse to load on a user's machine.

Verification reads `LC_BUILD_VERSION` (platform `macOS`) or
`LC_VERSION_MIN_MACOSX` from the Mach-O and fails when the minimum is newer than
that floor. A load command that cannot be read inside the bounded window is
reported as `deployment_target_unknown` (a warning), never as "fine".

## Building

The installer owns the build invocation; CI and release never restate the
layout:

```bash
cd agent
WHISPER_CPP_SRC=/path/to/whisper.cpp fvm dart run tool/ensure_native_stt.dart
```

Resolution order: existing valid files → explicit archive download
(`--archive-url`, or `--base-url` with `--archive-name`) → build from
`--whisper-src` → build from a discovered (`../refrence_projects/whisper.cpp`,
`.whisper.cpp`, `~/whisper.cpp`) tree → actionable failure.

The download channel only ever addresses a **published** artifact. The release
publishes `sanad-agent-runtime-<release>-<platform>-<arch>.tar.gz`, which the
tool cannot infer from the whisper.cpp version, so it requests exactly one of:

```bash
# preferred: the published asset URL (the file name comes from the URL)
fvm dart run tool/ensure_native_stt.dart \
  --archive-url https://github.com/EastStarAI/sanad-agent/releases/download/v1.0.20/sanad-agent-runtime-1.0.20-macos-arm64.tar.gz
# or a base URL plus the exact published file name
fvm dart run tool/ensure_native_stt.dart \
  --base-url https://example.test/assets \
  --archive-name sanad-agent-runtime-1.0.20-macos-arm64.tar.gz
```

Both forms fail closed: without a pinned `_archive` hash in
`agent/native/checksums.json` nothing is downloaded, and the whisper-version
default name (`sanad-stt-<tag>-v<version>.tar.gz`) only matches an archive
produced locally. No form falls back to an unpinned or unsigned download.

The product download path is HTTPS-only: `http://`, `file://` and every other
scheme are refused before any request, both in `--archive-url` parsing and in
`sttArchiveRequest`. There is no development exemption in the product channel —
a local artifact is installed through `--stage`/a local build, and the installer
sandbox uses its own explicit `SANAD_INSTALL_ALLOW_TEST_URL=1` manifest seam,
which is test-only and never reachable from the tool.

The build scripts take an explicit **tag-style** architecture (`x64` / `arm64`)
and derive the CMake spelling themselves, refusing a cross-architecture build,
because the artifact would be published under a directory name it does not
satisfy:

```bash
cd agent
# ran on the matching runner (macos-26 for arm64, macos-15-intel for x64)
bash tool/build_whispercpp.sh <whisper.cpp> native/macos-x64 x64 12.0
```

The tool hands the script `target.cpuName` (`x64`, `arm64`) plus the macOS
deployment target, never the CMake spelling: `x86_64` in that slot failed the
script's own check and made an Intel build impossible. `--expect-target
<platform-arch>` makes the tool assert the tag it produced, so a matrix entry
cannot stage one architecture into another's payload.

A real Intel build therefore comes from Intel hardware. An
`-DCMAKE_OSX_ARCHITECTURES=x86_64` build on Apple Silicon is not evidence that
any Intel machine can load the runtime, and is not accepted as such.

## Packaging: staged runtime and archive

`ensure_native_stt` can stage the verified runtime in the layout a packaged Agent
expects, and write a reproducible archive with a derived hash:

```bash
cd agent
fvm dart run tool/ensure_native_stt.dart --verify
fvm dart run tool/ensure_native_stt.dart --verify --stage <stage-dir> --archive <stage-dir> \
  --archive-name sanad-agent-runtime-1.0.20-macos-arm64.tar.gz
```

The stage contains:

```text
<stage-dir>/native/<tag>/<required libraries>   # ships beside the executable
<stage-dir>/native/<tag>/sherpa/<engine libraries>   # engine, loader-relative
<stage-dir>/stt-runtime-<tag>.json              # tag, version, pin state, real sha256 per file
<stage-dir>/sanad-agent-runtime-<release>-<platform>-<arch>.tar.gz   # from --archive
```

Rules:

- The copy is an **allowlist of the required libraries**, never a directory
  copy. Model weights (`*.bin`, `ggml-model-*`), markers, logs, and build
  leftovers cannot travel with the Agent, and CI asserts both the staged
  directory and the archive hold nothing outside the library allowlist.
- The archive is a pure function of the library bytes *for a given Dart SDK*:
  sorted entries, mode `0644`, owner/group `0`, `SOURCE_DATE_EPOCH` timestamps
  (default `0`), gzip header with mtime `0` and OS `255`. Re-archiving the same
  libraries on the same host produces identical bytes (verified: 1 938 221 bytes,
  sha256 `0c029f68…` twice). Cross-platform byte-identity is **not** claimed:
  deflate output belongs to the SDK's zlib, and macOS inputs are signed while
  Linux/Windows inputs are not. The authoritative value is always the hash of the
  bytes a producer actually wrote, recorded in the manifest.
- `--archive-name` exists only so the archive can carry the release-versioned
  filename the release contract validator requires; the default name keeps the
  whisper.cpp version.
- The stage record carries only values derived from produced bytes; it embeds no
  timestamp, no host name, and no absolute path.
- Staging refuses an unverified runtime (missing library, foreign architecture,
  deployment target too new, missing manifest entry).
- The archive writer is deliberately small and tested. Replacing it with a
  `tar`-based writer was considered and deferred as a discretionary refactor:
  the measured benefit is zero and it would trade a tested format for shell
  portability questions.

### The real packaging path

The Agent artifact is a single executable on every platform, so a directory
cannot travel inside it. The runtime therefore ships in the two places that
actually reach a user. **Release publication is required; installation is not:**
a release that declares the archive must produce it, while a user whose download
or verification fails loses dictation only and keeps a working Agent (see
[Failure policy](#failure-policy-dictation-only)).

1. **Inside the per-platform Agent payload.** The `agent` matrix job in
   `.github/workflows/release.yml` builds, verifies, and stages the runtime into
   the same `dist/` that holds the executable, so the uploaded payload contains
   `dist/native/<tag>/…` beside `dist/sanad-agent-…`. A failing build fails the
   release; there is no standalone side job whose artifact the manifest ignores.
2. **As a declared release artifact.** `release/release-contract.json` declares
   one `agent-runtime` artifact per Agent platform and architecture that
   publishes one (`sanad-agent-runtime-<release>-<platform>-<architecture>.tar.gz`,
   `format: tar.gz`), so `linux-arm64` is a declared row alongside `linux-x64`,
   `macos-arm64`, `macos-x64`, and `windows-x64`. `generate-manifest` fails when a
   declared archive is missing, so the archive is part of the release candidate
   and its real sha256 and size land in the release manifest. `scripts/install.sh`
   and `scripts/install.ps1` select that entry, verify size and sha256, reject an
   archive whose layout is not `native/<tag>/` plus the bounded `sherpa/`
   subtree with library files only,
   and install it as `<home>/bin/native/<tag>/` — the first location the loader
   searches relative to the installed executable.

The runtime is a separate component (`agent-runtime`), so
`findArtifact(component: 'agent')`, the Client bootstrap installer, and every
existing release consumer keep their current single-file contract. A release
that predates the runtime entry installs the executable alone and says so.

**macOS signing.** The released Agent is signed with the hardened runtime, which
enables library validation: an unsigned dylib cannot be loaded by the notarized
binary even when it is present. The `agent` job therefore signs every staged
dylib with the same Developer ID identity as the Agent, verifies each signature,
and only then writes the archive. The `disable-library-validation` entitlement is
deliberately **not** added; that must stay an explicit decision, not a packaging
side effect. A local development Agent is not hardened, so locally built
libraries keep loading without a signature.

**What consumes the runtime.** `agent_runtime_bundle.dart` refreshes it during
Agent self-update, `verified_agent_bootstrap_installer.dart` installs it for a
Client-bootstrapped Agent, and `scripts/install.sh` / `scripts/install.ps1`
install it for shell installs. The updater refreshes the runtime **before** the
executable replacement on POSIX and stages it for the same elevated restart
transaction on Windows, so a new executable never sits next to a runtime from
another release. Publication of the archive happens only through the normal
reviewed release flow: no workflow uploads it outside a release.

### Failure policy (dictation-only)

A failure to download, verify, extract, or replace the `agent-runtime` archive
**never fails or blocks an Agent install or update**. It disables dictation and
nothing else. Trust strictness is unchanged: size, SHA-256, and the declared
platform trust policy are still verified before any byte is extracted, and an
unverified library is never extracted or loaded.

| Surface | On runtime failure |
|---|---|
| `scripts/install.sh` / `scripts/install.ps1` | Warn, continue the install, keep the verified Agent and any predecessor runtime. The predecessor is restored locally when the failure happened after it was moved aside. |
| Agent self-update (`agent_update_service.dart`) | Replace the executable and report `restart_required`; the outcome travels as `runtime_status` and a message suffix. There is no `runtime_failed` update status. |
| Client bootstrap (`verified_agent_bootstrap_installer.dart`) | `isSuccess` depends only on the verified Agent; the runtime outcome is reported as `runtimeFailureCause`. |
| `sanad-dev` launcher probe | A missing or unbuildable runtime only prints guidance and keeps the run going; dictation becomes available when the build finishes. |

The reason is machine-readable and durable. The failing component records one
code in `<exe dir>/native/.runtime-install-failed`
(`release/contract/lib/src/native_runtime_install.dart` owns the name and the
vocabulary: `runtime_download_failed`, `runtime_checksum_failed`,
`runtime_trust_failed`, `runtime_layout_rejected`, `runtime_replace_failed`,
`runtime_install_failed`). The daemon reads it only when the shim is absent and
reports `native_runtime_install_failed` as its dictation readiness reason; the
Client localizes that code and offers the same "Set up now" action. An unknown
or prose value is ignored rather than surfaced, and a release that publishes no
runtime clears the record so the reason stays `native_runtime_missing`.

**Retry path.** `prepareRuntime` is the one action: a source checkout starts
`tool/ensure_native_stt.dart`, and a released Agent re-fetches the verified
`agent-runtime` archive through `AgentUpdateService.refreshRuntime()` without
touching the executable or the version. While a retry is in flight readiness
reports `native_runtime_preparing`, and a successful install clears the record.
Re-running the installer or an Agent update re-attempts the same verified
download.

**Installer rules for the runtime step.** Both installers verify size then
SHA-256 from the manifest, extract into a private temporary root, and refuse the
whole archive when any member is not exactly `native/<tag>/<library>`: path
traversal, extra top-level entries, hidden (dot) entries, symlinks/reparse
points, nested directories, and files outside the library extension allowlist
are all rejected before anything is installed. The previous runtime is moved to
`native/<tag>.rollback` and **kept until the whole installation transaction
commits** — pairing, Portal sign-in, ownership, and service/cloud-health steps
can still fail after the runtime is in place, and each of them must be able to
put the replaced runtime back. The backup is deleted only beside the executable
backup on the success path. First-install semantics are separate: a run that
replaced nothing removes the runtime it installed, and never claims otherwise. A
restore that fails keeps the `.rollback` directory and is reported as `could not
be fully restored`, never as a clean rollback.

**Older releases without a runtime.** When the manifest declares no
`agent-runtime` artifact, the installer keeps whatever runtime is already
installed and prints that it is keeping it; if none is installed it says dictation
stays unavailable. It never deletes a runtime to make the message simpler and
never falls back to an unverified download.

**Job budget.** The Agent release job keeps `timeout-minutes: 35`. The runtime
build adds a whisper.cpp compile, dylib signing, and the staged smoke, and the
Intel figure is unknown until the first authorized `macos-15-intel` run; raising
the budget without that measurement would only hide the unknown. The observed
Apple Silicon figure (build 18.3 s in this worktree) is recorded in
`REPORT.md` §10, not used to justify a blanket increase.

## CI coverage

`.github/workflows/ci.yml` keeps one `native-stt` job per desktop runner:

| Runner | Proves |
|---|---|
| `ubuntu-24.04` | x64 ELF compiles portably, verifies (including the `$ORIGIN`, loader, and instruction-set checks), loads, stages |
| `ubuntu-24.04-arm` | arm64 ELF compiles on its own CPU against the declared baseline, verifies (the same three checks), loads, stages — the lane that would have caught the v1.0.22 defect |
| `macos-26` | arm64 Mach-O compiles with Metal, verifies, loads, stages |
| `macos-15-intel` | **genuine** x64 Mach-O compiles, verifies, loads, stages on Intel hardware |
| `windows-2025` | x64 PE compiles, verifies, loads, stages |

Each job asserts the runner CPU the matrix label claims, sets
`SANAD_STT_REQUIRE_NATIVE=1` so the smoke test and the instruction-set guard fail
instead of skipping, installs `binutils` on Linux when the image lacks
`objdump`, and runs the installer, `--verify`, the load smoke test, and the
stage/archive path. The two Linux lanes then publish the staged folder they just
verified as `native-stt-runtime-linux-<arch>` (three-day retention), so the
payload can be exercised on hardware **older than the runner** — the one proof CI
cannot make about itself, and the exact gap that let v1.0.22 ship with
`native_stt_ldd_*=ok` on libraries no Neoverse-N1 could execute. Every step that
can execute on a Windows runner runs under `pwsh`; each `bash` step in a
Windows-capable job carries an explicit non-Windows guard and a `pwsh` twin with
the same tool command, and a guard test fails when either property is missing.

Genuine Intel **decode** (audio through a real model) is not part of CI: models
are never bundled, so a decode proof needs a model download and belongs to a
live acceptance run on Intel hardware.

## Regression tests

| Test | Covers |
|---|---|
| `agent/test/stt/stt_native_platform_test.dart` | ABI matrix, Intel platform scope, Metal per architecture, required files, legacy alias bounds, candidate order, Mach-O/ELF/PE inspection, ELF `$ORIGIN` search-path parsing |
| `agent/test/stt/native_runtime_readiness_test.dart` | missing/preparing readiness, the native-root marker, foreign-architecture rejection, the recorded install-failure reason, and the packaged retry path |
| `agent/test/guards/installer_runtime_rollback_test.dart` | real `scripts/install.sh`: a runtime failure, checksum mismatch, or download error still installs the Agent, restores the predecessor runtime, and records the reason; transaction rollback; verified install clears the record |
| `agent/test/core/update/agent_update_runtime_policy_test.dart` | Agent self-update completes with `restart_required` on a runtime download error or checksum mismatch and records the cause; a verified runtime installs and clears it |
| `agent/test/core/update/agent_runtime_bundle_test.dart` | verification order, layout allowlist, Windows staging, and the recorded failure cause per status |
| `client/test/unit/services/verified_agent_bootstrap_installer_test.dart` | Client bootstrap: a runtime download/checksum/layout failure never fails the install and records the cause; a verified runtime installs |
| `scripts/sanad_dev/test/runtime/lifecycle/native_runtime_probe_test.dart` | architecture-qualified probe, one bounded legacy alias, unknown host pair, and a failing installer that never blocks `run` |
| `agent/test/stt/native_runtime_smoke_test.dart` | real load of the built runtime (skips without one, fails when `SANAD_STT_REQUIRE_NATIVE=1`) |
| `agent/test/tool/stt_native_runtime_test.dart` | verification rules, pin states, Linux `$ORIGIN` relocatability, the loader gate, the instruction-set guard (SVE/I8MM/BF16 and AVX-512 listings rejected, dotprod and AVX2 accepted, mangled names ignored, missing disassembler stated), staging allowlist, stage record, strict pin failures, builder argument vectors, download request resolution |
| `agent/test/tool/stt_native_archive_test.dart` | reproducible tar.gz bytes, header fields, checksums, entry order |
| `agent/test/tool/native_builder_script_test.dart` | the tool→builder argument contract against the real script (plan mode), architecture mismatch refusal, CMake-spelling rejection, the Linux install-rpath and stale-cache contract, the portable `GGML_NATIVE=OFF` baseline and the arm64 floor resolved through a fake `uname`, the v4 build-cache key, and the Windows `-DGGML_NATIVE` contract |
| `agent/test/tool/native_runtime_package_contract_test.dart` | release contract ↔ archive layout ↔ installers ↔ workflow agreement, including the 35-minute budget, the pwsh-twin rule, and a scan that fails on any `bash` step in a Windows-capable job |
| `agent/test/guards/installer_runtime_rollback_test.dart` | real `scripts/install.sh` in a sandbox: a later service failure restores the runtime this run replaced, a failed restore keeps the backup and never reports a clean rollback, symlink and hidden members are refused, a release without a runtime keeps the installed one |

## Deferred — not claimed in this change

The narrowed closure ships local and cloud dictation on the platforms below with
the failure policy above. These items are explicitly **not** done and must not be
read as delivered:

- **A re-validation of dictation on the release host.** This change makes the
  runtime portable and adds the guard that proves it; it does not by itself
  re-run the arm64 acceptance session that failed with `SIGILL`. That is a
  separate, explicitly scheduled validation.
- **CPU-variant runtime dispatch.** There is no `GGML_CPU_ALL_VARIANTS` /
  `GGML_BACKEND_DL` build that ships several CPU baselines and picks one at load
  time. One portable baseline per target is shipped; a host below the floor
  declared in
  [Portable instruction-set baseline](#portable-instruction-set-baseline) cannot
  run dictation, and macOS/Windows payloads are not disassembled by the guard.
- **A `windows-arm64` producer.** Still a declared row with no lane, and now
  documented as impossible to produce portably with MSVC.
- **Executed install, update, and dictation proof on Windows and Linux.** The
  installers, the updater, and the Client bootstrap implement the same policy on
  all three platforms, and the Windows staged-restart transaction has unit
  coverage, but no Windows or Linux release install, update, or dictation session
  was executed for this change. Only macOS Apple Silicon was exercised locally.
  This is a *proof* gap, not a support gap: `windows-x64`, `windows-arm64`,
  `linux-x64`, and `linux-arm64` are declared rows in the platform matrix, the
  manifest, and the installer contract, and the whisper-only Linux arm64 build
  (whisper.cpp batch, no sherpa engine) is the decided behavior — it is delivered
  as described in [Engine availability](#engine-availability), and its own
  release install and dictation session remain unproven until that leg runs.
- **Signing proof.** No notarized Agent, Developer-ID-signed runtime library, or
  GitHub attestation was produced or verified here. The release pipeline owns
  signing; this change asserts only that verification stays mandatory.
- **Test-tooling enhancements.** The Client archive fixture now builds its
  archive with a standard encoder instead of the host `tar`, because bsdtar emits
  PAX records the release writer never produces. No broader archive-fixture or
  cross-platform test harness work is included.
- **Genuine Intel decode.** Unchanged: it needs a model download and a live
  acceptance run on Intel hardware.
