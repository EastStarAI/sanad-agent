---
title: "Task 439 — Windows GGML Native Build Correctness"
issue: "https://github.com/EastStarAI/sanad-agent/issues/439"
status: implemented-pending-re-review
---

## Goal

Make the Windows x64 whisper builder and release proof enforce the documented `GGML_NATIVE=OFF` / AVX2 baseline, and establish whether the v1.0.23 runtime owns the reported production crash.

**Outcome:** the builder genuinely did not pass `OFF`, every Windows x64 build now records `GGML_NATIVE:BOOL=OFF` or fails before staging, and the v1.0.23 runtime is the **proven** crash owner at the published-artifact level — on an AVX2-only host it faulted with `STATUS_ILLEGAL_INSTRUCTION` at model load while the AVX2 control decoded. The claim is bounded to that host and that artifact; the reporting user's machine is not proven.

## Locked Scope

- Fix and prove PowerShell/CMake argument construction and cache validation.
- Inspect official v1.0.23 Agent/runtime assets only after manifest/SHA verification.
- Attribute the production crash only as far as isolated A/B evidence carries it, bound to the tested host and artifact. The reporting user's machine, and the configure that produced the released payload, stay unproven.
- Do not lower the accepted Windows x64 AVX2 floor or add GPU acceleration.
- Do not change the accepted `GGML_NATIVE` implementation to record crash evidence; the integration is documentation.

## Gates

### G0 — Artifact and Build Audit

- [x] Reproduce the literal `GGML_NATIVE:BOOL=$ggmlNative` cache value.
- [x] Verify v1.0.23 asset hashes, layout, load behavior, and available ISA evidence.
- [x] Record whether the artifact audit can prove or only bound crash risk — at G0 it could only bound it, so an isolated A/B was commissioned and is integrated below (E7).

### G1 — Build Fix

- [x] Pass `OFF` unambiguously on Windows x64.
- [x] Fail closed when the generated cache is missing, literal, or not exactly `OFF`.
- [x] Add focused regression coverage at the builder/release boundary.

### G2 — Verification

- [x] Rebuild and prove the cache value and native runtime load.
- [x] Run owning analyzer/tests with elapsed/bounded output.
- [x] Update native-runtime documentation.
- [x] Graphify skipped — explicitly waived by the user for this Windows STT delivery, so the graph was **not** refreshed and no claim is made that it was. See the Definition of Done for the same waiver.

## Evidence

### E1 — The literal value is real (PowerShell parsing rule)

Windows PowerShell 5.1 argument-mode probe: a bare token that starts with `-`
and contains `=` is parsed as a parameter assignment and its right-hand side is
**not** expanded. `Foo=$ggmlNative` (no leading dash) and
`"-DGGML_NATIVE=$ggmlNative"` (quoted) both expand to `OFF`;
`-DGGML_NATIVE=$ggmlNative` does not.

### E2 — The literal reaches CMake's cache (real CMake + MSVC, this host)

Running the pre-fix configure block verbatim against whisper.cpp `v1.9.5`
(`d1be6fd`, MSVC 19.51, CMake 4.3) wrote:

```
GGML_NATIVE:BOOL=$ggmlNative
GGML_AVX2:BOOL=OFF
```

and ggml's own configure log took the **native** branch:
`Performing Test HAS_AVX512_1` / `HAS_AVX512_2`, then
`Adding CPU backend variant ggml-cpu: /arch:AVX2 GGML_AVX2;GGML_FMA;GGML_F16C`.
Those probes only run when `GGML_NATIVE` is truthy
(`ggml/src/ggml-cpu/CMakeLists.txt`, `if (MSVC) / if (GGML_NATIVE) include(FindSIMD.cmake)`),
so the build host — not the declared contract — decided the instruction set.

### E3 — v1.0.23 shipped that decision

`sanad-agent-runtime-1.0.23-windows-x64.tar.gz`, SHA-256
`61f9a286cb69064ff0aa1c6b3cd4757579347f34c90f28267a602c5417d1ae10`, 9 418 038 bytes,
verified three ways: the release manifest, the GitHub asset digest, and the
downloaded bytes all agree. Layout matches the archive contract exactly
(`native/windows-x64/{whisper,ggml,ggml-base,ggml-cpu,sanad_whisper}.dll` plus
`sherpa/{onnxruntime,sherpa-onnx-c-api}.dll`). `dumpbin /headers` reports
`8664 machine (x64)` for the shim and both backends.

`dumpbin /disasm:nobytes` over `ggml-cpu.dll`, with every figure below counted
over the same listing (a line count is the reproducible metric, because one
instruction can name two `zmm` operands):

| Pattern | Instruction lines | Occurrences |
|---|---|---|
| `zmm<register>` operand | **6 497** | 11 926 |
| `k1`–`k7` mask register | 383 | 386 |
| `zmmword` memory-size spelling | 2 711 | 2 711 |
| `vpternlogq` (AVX-512 only) | 36 | 36 |
| `vscalefps` (AVX-512 only) | 3 | 3 |
| `vrndscaleps` (AVX-512 only) | 8 | 8 |

All `zmm` substrings total 11 926 + 2 711 = 14 637, which is why an undefined
"zmm count" is ambiguous: `zmmword` is a memory-size keyword, not a register.
`whisper.dll`, `ggml-base.dll` and `sanad_whisper.dll` contain no `zmm` at all.
There is one `ggml-cpu.dll` and no per-variant siblings, so
`GGML_CPU_ALL_VARIANTS` was off and no runtime dispatch can select a lower
variant.

Load behaviour on this host (Intel i9-9880H — **no** AVX-512): all five libraries
load in dependency order and `sanad_whisper_system_info()` reports
`… AVX2 = 1 | F16C = 1 | FMA = 1 | AVX512 = 1 | OPENMP = 1 | REPACK = 1`, i.e.
the shipped payload declares an instruction set this machine does not implement.

### E4 — A/B against the fixed builder

Same host, same whisper.cpp tree, same toolchain, fixed script:

- Cache: `GGML_NATIVE:BOOL=OFF`, `GGML_AVX2:BOOL=ON`, `GGML_BMI2:BOOL=ON`,
  `GGML_AVX512:BOOL=OFF`; ggml appends
  `/arch:AVX2 GGML_AVX2;GGML_FMA;GGML_F16C;__BMI2__;GGML_BMI2` and never runs an
  `HAS_AVX512` probe.
- `ggml-cpu.dll`: `zmm` register operands = **0** (0 lines), `ymm` = 21 219
  occurrences over 10 952 lines — measured with the same patterns as E3, so the
  two listings are directly comparable.
- Banner: `… AVX2 = 1 | F16C = 1 | FMA = 1 | BMI2 = 1 | OPENMP = 1 | REPACK = 1`,
  no `AVX512`.
- The warm cache left by E2 was discarded by the stale-cache guard
  (`Discarding a CMake cache configured for platform 'x64' and
  GGML_NATIVE='$ggmlNative'`), which also proves the guard now compares against a
  value that can actually match.

### E5 — Crash causality: bounded by this task, then proven elsewhere

This task's own audit could not close causality, and said so. It established that
the v1.0.23 Windows x64 payload requires AVX-512 while its declared floor is
AVX2, so a host without AVX-512 would fault with `STATUS_ILLEGAL_INSTRUCTION`
(`0xC000001D`) the first time AVX-512 code executed. It could not supply the
reported crash's exception code, faulting module and offset, the affected host's
CPU and OS build, or an A/B decode of the same audio on both payloads — and E3's
load test deliberately stopped at `LoadLibrary` + banner, because a payload that
*loads* is not a payload that *runs*.

E7 later made that first-execution point precise: it is not a dispatch-selected
kernel but object initialisation during model load, which is why the fault is
unconditional rather than dependent on which kernels a host would choose.

That missing A/B was run as a separate investigation and is now integrated as
**E7**. The bound above is superseded for the tested host and artifact.

### E7 — The isolated A/B (integrated, independently accepted)

Accepted evidence: [Windows production dictation crash — v1.0.23 native runtime](../../qa_maintenance/windows_stt_production_crash_reproduction.md).
Recorded there with repository-relative paths only; no machine-absolute paths, no
process ids, and no raw event-log or dump payloads are carried into the
repository.

The claims this task now rests on, all reproduced independently by the reviewer:

| Claim | Evidence |
|---|---|
| The tested host is exactly on the declared x64 floor | Intel i9-9880H, `AVX2=true`, `AVX512F=false`, Windows 11 build 26200 |
| The subject is the published artifact | `sanad-agent-runtime-1.0.23-windows-x64.tar.gz`, `61f9a286…7d1ae10`, 9 418 038 B — manifest, `SHA256SUMS` and GitHub asset digest all agree; the packaged Agent stages exactly this tarball |
| The release runtime faults | `0xC000001D` `STATUS_ILLEGAL_INSTRUCTION` at `ggml-cpu.dll+0x84249`, during model load, reached through the shim's model-load entry one FFI frame down |
| The fault is unconditional, not dispatch-guarded | the preceding `je` is a null check on an allocation; the faulting instruction is an EVEX `vmovups zmm0` in compiler-emitted object initialisation, so no runtime variant selection could have avoided it |
| The AVX2 control does not fault | same model, audio, harness and `dartvm.exe`, differing only in `SANAD_WHISPER_LIBRARY`; the control is the pre-existing local build staged at `agent/native/windows-x64/` — **a different binary from E4's rebuild**, though both are AVX2-only — and it decoded to completion and freed the context (`zmm=0`) |
| Windows corroborates the process fault independently | two `Application Error 1000` records and two WER `BEX64` records with one shared fault bucket, one per attempt |

**What this proves:** the published v1.0.23 `windows-x64` native runtime contains
AVX-512 that executes unconditionally at model load, and therefore faults on any
x64 host that meets the documented AVX2 floor but lacks AVX-512. That makes it
the owner of a crash of this class, and it is the mechanism E2 and E3 predicted.

**What it does not prove, and this task must not state:**

- that the reporting user's machine hit the same fault address — its CPU
  features and event log were never collected;
- that the released payload was produced by the literal `$ggmlNative` cache
  value — the release `CMakeCache.txt` was never captured, so E2's mechanism is a
  plausible cause of the released bits, not a demonstrated one;
- that the packaged `.exe` end-to-end path behaves identically — deliberately
  not exercised, since it needs a second daemon and a throwaway Home.

The two halves stay distinct: **the build defect is reproducible here (E1–E4);
the crash is proven elsewhere and integrated by reference (E7).**

### E6 — Independent review round 1, and what it changed

The reviewer reproduced the asset audit (digest, layout, mnemonic counts), the
CMake mechanism and the cache contract independently, and accepted the direction.
Four warnings were corrections to *this candidate's own evidence and assertions*,
and all four were real:

| Finding | Correction |
|---|---|
| **W1** the new `GGML_NATIVE:BOOL` ordering assertion was satisfied by the script's header comment, because `indexOf` hit that prose (line 33) instead of the guard | re-anchored to the guard's decision, `lastIndexOf('$cachedNativeValue -ne $ggmlNative')`; the platform-cache test was re-anchored the same way to `$cachedPlatform -ne $Arch` |
| **W2** the "no bare token" regex required the line to *end* in `$`, so `-DGGML_NATIVE=$ggmlNative` — the exact v1.0.23 form — passed it | replaced with `hasBareDefineWithVariable`, which strips double-quoted spans and matches `-D…=$\w+`; the test now asserts the helper rejects the historical form **and** accepts the quoted fix, so it cannot silently stop testing the defect |
| **W3** the doc said `FindSIMD` uses `try_compile` | it uses `check_c_source_runs`, a **try_run**. Corrected, and the correction is the stronger statement: AVX-512 is enabled only when the build runner can *execute* the probe, which is why this AVX2-only host ended at `/arch:AVX2` under the same broken script |
| **W4** the doc said `objdump` "does not read a PE image" | false — GNU binutils ships PE/COFF targets. The real cause is that `_objdumpDisassembly` throws `SttDisassemblyUnavailable('host')` for any non-Linux host and the Windows runner installs no `binutils`. Both places corrected to the host-gate reason |

Two further items were accepted without changing scope: the `zmm` figure now
carries its counting method (E3), and the cache's remaining bypass
(`CL=/arch:AVX512`) is stated in the owning doc instead of being implied away.

The self-verifying replacement for W2 immediately found two further defects in
the replacement itself, which is why it is written as an assertion pair rather
than a source grep:

1. it matched the **script's own header comment**, which documents the defect by
   quoting `-DGGML_NATIVE=$ggmlNative` in backticks — the same class of
   false-positive as W1, so comments and double-quoted spans are now stripped
   before matching;
2. it did not match the real form at all, because `[A-Za-z]+` cannot span the
   underscore in `-DGGML_NATIVE=`; the name side is now `[A-Za-z]\w*`.

Both repaired assertions were then mutation-tested against the real script:

| Mutation | Result |
|---|---|
| drop the quotes around `"-DGGML_NATIVE=$ggmlNative"` (reintroduce the v1.0.23 form) | test fails — `Expected: contains '"-DGGML_NATIVE=$ggmlNative"'` |
| remove `-ne $ggmlNative` from the stale-cache comparison | test fails — `Expected: a non-negative value / Actual: <-1>` with `the guard must compare the cache against the required value` |

Both mutations were reverted; the script's configure array (line 85 quoted), the
guard decision (line 119) and the configure invocation (line 124) are back to the
reviewed state. The first `GGML_NATIVE:BOOL` token in the script is on line 33 —
the header comment — which is exactly why the old `indexOf` ordering assertion
could never fail.

## Follow-ups

- **S2 — a PE instruction-set gate for Windows (not attempted here).** The cache
  check proves the *configure*, not the *binary*: `CL=/arch:AVX512` leaves
  `GGML_NATIVE:BOOL=OFF` in the cache and still produces an AVX-512 DLL.
  `dumpbin /disasm` exists on every Windows runner that has MSVC and would close
  this directly. It is deliberately out of scope for this task because it changes
  the `--verify` contract rather than the builder: it needs a second
  `SttDisassembler` implementation (locating `dumpbin` under the VS toolchain), a
  separate forbidden-instruction rule set for Intel syntax (registers without
  `%`, `k0`–`k7`, different decorator spellings), CI wiring on the Windows lane,
  its own parser tests, and re-publication of the doc statement that Windows has
  no gate. Attempting it inside this candidate would mean shipping an unverified
  gate on the lane that already produced one defect.
- The Windows builder's `SANAD_BUILD_PLAN_ONLY` environment check is redundant
  with `-PlanOnly`. It is kept for symmetry with the POSIX script and is not
  exercised on its own.

## Acceptance Criteria

- [x] Every Windows x64 build records `GGML_NATIVE:BOOL=OFF` — the flag is
      splatted from an expanded array element (E4) and the value is read back
      from the cache before anything compiles.
- [x] A literal or wrong value fails before staging/publication — the builder
      throws, and `ensure_native_stt` re-reads the same cache at the staging
      boundary (`sttGgmlNativeCacheProblem`).
- [x] Release verification records evidence consistent with the declared AVX2
      baseline — the builder prints `GGML_NATIVE:BOOL=OFF (windows-x64)`, the
      rebuilt payload contains no AVX-512 and reports no `AVX512` flag (E4),
      where v1.0.23 did both (E3).
- [x] The report states the crash owner with its bound: proven for the tested
      host and the published artifact (E7), and explicitly not proven for the
      reporting user's machine or for the configure that produced the released
      bytes.

## Definition of Done

- [x] Implementation, tests, and docs are complete in the isolated worktree.
- [x] Focused verification passes on Windows: `fvm dart analyze` clean;
      `test/tool/native_builder_script_test.dart` — all new coverage green.
      One **pre-existing, unrelated** failure remains in the same file
      (`every decode owns a fresh whisper state over shared weights` expects
      `cleanup:\n` but this checkout has CRLF because `core.autocrlf=true`); the
      file it reads is unmodified by this task.
- [x] Integration round: the independently accepted crash evidence is recorded in
      a tracked page ([crash reproduction](../../qa_maintenance/windows_stt_production_crash_reproduction.md)),
      linked from the owning technical page, and summarized as E7, with the
      `GGML_NATIVE` implementation unchanged. Graphify is waived for this Windows
      STT delivery by explicit user decision, so the graph is intentionally not
      refreshed in this round.
- [ ] A separate reviewer session accepts the candidate; fixes return to the
      original implementer session and re-review returns to the original
      reviewer session. **Round 1 returned `ACCEPT` with W1–W4** (E6); all four
      are corrected in this candidate and it is returned to that reviewer. The
      crash evidence itself was separately accepted by that same reviewer session
      (`oneshot-befacf07-22a4-4d31-9fa9-8d749302919a`) before this integration.
- [x] Stop before Ready/merge without separate authorization — no commit, push,
      or PR was created.
