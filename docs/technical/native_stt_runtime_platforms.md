---
title: "Native Dictation Runtime Platforms"
description: "Platform tag, directory layout, verification rules, and release staging for the in-process whisper.cpp dictation runtime, including macOS Intel (x64)."
---

# Native Dictation Runtime Platforms

The local dictation engine is a native whisper.cpp shim (`libsanad_whisper`)
loaded through `dart:ffi` inside the agent daemon. Its binaries are per-OS and
**per-CPU-architecture** build products, are not tracked in git, and must be
reproducible on the machine that will load them.

This page owns the platform matrix, where each build lives, what a verification
proves, and how a packaged Agent receives the runtime. It does not own the
dictation transport or model catalog; see
[Local Dictation](local_dictation.md) for those.

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

### Ownership

| Concern | Owner |
|---|---|
| Tag, directory, required files, Metal per architecture, deployment target | `agent/lib/infrastructure/stt/stt_native_platform.dart` |
| Discovery of the shim at runtime, readiness probe, `dart:ffi` entry points | `agent/lib/infrastructure/stt/whispercpp_bindings.dart` |
| Install, verify, stage, and archive | `agent/tool/ensure_native_stt.dart`, `stt_native_runtime.dart`, `stt_native_archive.dart` |
| Build from a whisper.cpp tree | `agent/tool/build_whispercpp.sh`, `agent/tool/build_whispercpp.ps1` |
| Which platform may dictate at all | `DictationService` platform gate (see the integration hook below) |

The mapping reads `Abi.current()`, never a substring of `Platform.version`. A
version string is not an architecture: it is a kernel/SDK description, so a
substring match both misfires and cannot express "this build is x64".

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
   one `agent-runtime` artifact per Agent platform and architecture
   (`sanad-agent-runtime-1.0.20-<platform>-<architecture>.tar.gz`,
   `format: tar.gz`). `generate-manifest` fails when a declared archive is
   missing, so the archive is part of the release candidate and its real sha256
   and size land in the release manifest. `scripts/install.sh` and
   `scripts/install.ps1` select that entry, verify size and sha256, reject an
   archive whose layout is not exactly `native/<tag>/` with library files only,
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
| `ubuntu-24.04` | x64 ELF compiles, verifies, loads, stages |
| `macos-26` | arm64 Mach-O compiles with Metal, verifies, loads, stages |
| `macos-15-intel` | **genuine** x64 Mach-O compiles, verifies, loads, stages on Intel hardware |
| `windows-2025` | x64 PE compiles, verifies, loads, stages |

Each job asserts the runner CPU the matrix label claims, sets
`SANAD_STT_REQUIRE_NATIVE=1` so the smoke test fails instead of skipping, and
runs the installer, `--verify`, the load smoke test, and the stage/archive path.
Every step that can execute on a Windows runner runs under `pwsh`; each `bash`
step in a Windows-capable job carries an explicit non-Windows guard and a `pwsh`
twin with the same tool command, and a guard test fails when either property is
missing.

Genuine Intel **decode** (audio through a real model) is not part of CI: models
are never bundled, so a decode proof needs a model download and belongs to a
live acceptance run on Intel hardware.

## Regression tests

| Test | Covers |
|---|---|
| `agent/test/stt/stt_native_platform_test.dart` | ABI matrix, Intel platform scope, Metal per architecture, required files, legacy alias bounds, candidate order, Mach-O/ELF/PE inspection |
| `agent/test/stt/native_runtime_readiness_test.dart` | missing/preparing readiness, the native-root marker, foreign-architecture rejection, the recorded install-failure reason, and the packaged retry path |
| `agent/test/guards/installer_runtime_rollback_test.dart` | real `scripts/install.sh`: a runtime failure, checksum mismatch, or download error still installs the Agent, restores the predecessor runtime, and records the reason; transaction rollback; verified install clears the record |
| `agent/test/core/update/agent_update_runtime_policy_test.dart` | Agent self-update completes with `restart_required` on a runtime download error or checksum mismatch and records the cause; a verified runtime installs and clears it |
| `agent/test/core/update/agent_runtime_bundle_test.dart` | verification order, layout allowlist, Windows staging, and the recorded failure cause per status |
| `client/test/unit/services/verified_agent_bootstrap_installer_test.dart` | Client bootstrap: a runtime download/checksum/layout failure never fails the install and records the cause; a verified runtime installs |
| `scripts/sanad_dev/test/runtime/lifecycle/native_runtime_probe_test.dart` | architecture-qualified probe, one bounded legacy alias, unknown host pair, and a failing installer that never blocks `run` |
| `agent/test/stt/native_runtime_smoke_test.dart` | real load of the built runtime (skips without one, fails when `SANAD_STT_REQUIRE_NATIVE=1`) |
| `agent/test/tool/stt_native_runtime_test.dart` | verification rules, pin states, staging allowlist, stage record, strict pin failures, builder argument vectors, download request resolution |
| `agent/test/tool/stt_native_archive_test.dart` | reproducible tar.gz bytes, header fields, checksums, entry order |
| `agent/test/tool/native_builder_script_test.dart` | the tool→builder argument contract against the real script (plan mode), architecture mismatch refusal, CMake-spelling rejection |
| `agent/test/tool/native_runtime_package_contract_test.dart` | release contract ↔ archive layout ↔ installers ↔ workflow agreement, including the 35-minute budget, the pwsh-twin rule, and a scan that fails on any `bash` step in a Windows-capable job |
| `agent/test/guards/installer_runtime_rollback_test.dart` | real `scripts/install.sh` in a sandbox: a later service failure restores the runtime this run replaced, a failed restore keeps the backup and never reports a clean rollback, symlink and hidden members are refused, a release without a runtime keeps the installed one |

## Deferred — not claimed in this change

The narrowed closure ships local and cloud dictation on the platforms below with
the failure policy above. These items are explicitly **not** done and must not be
read as delivered:

- **Windows and Linux packaging proof.** The installers, the updater, and the
  Client bootstrap implement the same policy on all three platforms, and the
  Windows staged-restart transaction has unit coverage, but no Windows or Linux
  release install, update, or dictation session was executed for this change.
  Only macOS Apple Silicon was exercised locally.
- **Signing proof.** No notarized Agent, Developer-ID-signed runtime library, or
  GitHub attestation was produced or verified here. The release pipeline owns
  signing; this change asserts only that verification stays mandatory.
- **Test-tooling enhancements.** The Client archive fixture now builds its
  archive with a standard encoder instead of the host `tar`, because bsdtar emits
  PAX records the release writer never produces. No broader archive-fixture or
  cross-platform test harness work is included.
- **Genuine Intel decode.** Unchanged: it needs a model download and a live
  acceptance run on Intel hardware.
