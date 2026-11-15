# Windows production dictation crash — v1.0.23 native runtime

Reproduction record for the reported Windows dictation crash, and the
instruction-set defect it attributes to the published v1.0.23 `windows-x64`
runtime. The owning defect and its fix live in
[Task 439](../plans/tasks/439-windows-ggml-native-build.md); this page records the
crash evidence that page cites, so the crash claim has a tracked home that does
not depend on out-of-tree artifacts.

## Verdict and its bound

**Confirmed owner: the published v1.0.23 `windows-x64` native dictation
runtime.** Its `ggml-cpu.dll` carries AVX-512 (EVEX / `zmm`) instructions that
execute unconditionally while the whisper model loads, so it faults with
`STATUS_ILLEGAL_INSTRUCTION` (`0xC000001D`) on any x64 host that cannot execute
AVX-512 — the exact class the declared AVX2 floor exists to serve.

**Bounded to this host and this artifact.** The A/B below was run on one
machine and one released tarball, both identified here. Two claims are
deliberately **not** made:

- **The reporting user's machine is not proven to have hit this fault.** Its CPU
  feature set and Windows event log were never collected. What is proven is that
  the artifact they would have installed contains code that faults this way on
  the documented AVX2 floor, which matches the reported symptom and host class.
- **The producing configure is not proven.** The release `CMakeCache.txt` was
  never captured, so why the release build emitted AVX-512 despite the
  `GGML_NATIVE=OFF` contract is open. The artifact's instruction-set content is
  the proven link; the flags that produced it are inferred. See
  [Task 439](../plans/tasks/439-windows-ggml-native-build.md) for the argument
  defect that plausibly produced it, which is separately reproducible.

## Host

| Property | Value |
|---|---|
| CPU | Intel Core i9-9880H (Coffee Lake Refresh), 8 cores / 16 threads |
| `PF_AVX_INSTRUCTIONS_AVAILABLE` | `true` |
| `PF_AVX2_INSTRUCTIONS_AVAILABLE` | `true` |
| `PF_AVX512F_INSTRUCTIONS_AVAILABLE` | **`false`** |
| OS | Windows 11 Pro, build 26200 |

The host sits exactly on the documented Windows x64 floor: it can run a portable
AVX2 runtime and cannot run AVX-512 code. Features were read through
`kernel32!IsProcessorFeaturePresent`, and the same census was re-derived
independently during review.

## Artifact identity

The runtime was downloaded from the `v1.0.23` GitHub release and verified before
execution against the release manifest, `SHA256SUMS`, and the GitHub asset
digest — all three agree:

| Artifact | Size | SHA-256 |
|---|---|---|
| `sanad-agent-runtime-1.0.23-windows-x64.tar.gz` | 9 418 038 | `61f9a286cb69064ff0aa1c6b3cd4757579347f34c90f28267a602c5417d1ae10` |
| `release-manifest.json` | 7 817 | `017a1e044387fa66fe283eb3bca60c74231ca93661031ae96b36bbd32f6b9d74` |
| manifest row | — | `agent-runtime` / `windows` / `x64` |

Archive members match the documented layout and nothing else, so packaging is not
implicated: `native/windows-x64/{ggml-base,ggml-cpu,ggml,sanad_whisper,whisper}.dll`
and `native/windows-x64/sherpa/{onnxruntime,sherpa-onnx-c-api}.dll`.

Members after extraction:

| File | Size | SHA-256 |
|---|---|---|
| `ggml-cpu.dll` | 1 048 064 | `726371182118fb627e11583fe83172e9a4e5602081943e6dbab1be988282e6de` |
| `whisper.dll` | 1 370 112 | `9500016dc7a1c05bd3c993a2a6389fcf87b7a56a0060b495778093eeae656a66` |
| `sanad_whisper.dll` | 136 704 | `e6b77287600836286de8b04511fff6812edfadd8b6397e9a33a21667a1584e68` |
| `ggml.dll` | 62 976 | `fe947f9448b47fdc5557db435150786ba28cfe95045b78b13d6aebb0e4451ba4` |
| `ggml-base.dll` | 693 760 | `6cc59025bb5d51223b0d25407395970d6d95810d7bd8039ddde1b4fa35650de0` |

The packaged Agent installs exactly this `agent-runtime` tarball into
`native/<tag>/` (`agent/lib/core/update/agent_runtime_bundle.dart`, with
`checksumFailed` as a hard status), so v1.0.23 dictation loads byte-identical
copies of these files.

## A/B procedure

One existing harness, `agent/tool/stt_whispercpp_probe.dart`, run unmodified in a
disposable `dartvm.exe` child per arm. The only variable was
`SANAD_WHISPER_LIBRARY`, which `WhisperCppLibrary` checks before any directory
candidate (`agent/lib/infrastructure/stt/stt_native_platform.dart`), so no
fallback could silently select the other runtime. Both arms ran:

```text
fvm dart run tool/stt_whispercpp_probe.dart <model> <wav> ar 4 0
```

— Arabic, 4 threads, `use_gpu=0`, daemon-derived `audio_ctx`. The fixture was
the pinned `whisper.cpp` v1.9.5 `samples/jfk.wav` (352 078 bytes, SHA-256
`59dfb9a4acb36fe2a2affc14bacbee2920ff435cb13cc314a08c13f66ba7860e`); the model
was the locally installed `egy-whisper-turbo-ggml-q8` checkpoint (874 208 239
bytes), opened read-only.

| Arm | Runtime | `SANAD_WHISPER_LIBRARY` |
|---|---|---|
| A — control | locally built AVX2 runtime in `agent/native/windows-x64/` | that shim |
| B — subject | extracted v1.0.23 release runtime | that shim |

Each arm was exercised twice; the retained run of each is the second.

| Arm | Exit code | Outcome |
|---|---|---|
| A — local AVX2 build | `0` | decoded to completion, context freed |
| B — v1.0.23 release runtime | `-1073740791` (`0xC0000409`, Dart VM fail-fast after the native fault) | native fault during model load, no decode output |

Arm A therefore **decoded the same model and audio without a native fault**. Its
transcript was a degenerate repetition, so it proves a completed decode and says
nothing about recognition quality; no lexical claim is made.

## Crash evidence (arm B)

The Dart VM reported the root exception:
`ExceptionCode -1073741795` = **`0xC000001D` STATUS_ILLEGAL_INSTRUCTION**, with
the program counter inside the release compute library one FFI frame below the
shim's model-load entry, before the harness printed its first line:

```text
release-v1.0.23-windows-x64\native\windows-x64\ggml-cpu.dll+0x84249
  [Optimized]   WhisperCppLibrary.open.#ffiClosure0+0xa0
  [Unoptimized] WhisperCppLibrary.loadModel+0x363
```

Windows recorded the same process fault independently, twice, once per attempt:
`Application Error 1000` with `0xc0000409` in `dartvm.exe`, each followed by
`Windows Error Reporting 1001`, `Event Name: BEX64`, `P8: c0000409`, `P9: 7`,
all four records sharing one fault bucket. `0xC0000409` with subcode `7`
(`FAST_FAIL_FATAL_APP_EXIT`) is the Dart VM aborting after it caught and reported
the illegal instruction; the root exception is the `0xC000001D` above, not an
Agent-level error path. Storing raw event-log and dump payloads would add no
reproducible information, so only the fields that carry the claim are recorded
here.

## Fault-site instruction

`dumpbin /DISASM` over the release `ggml-cpu.dll` locates the reported RVA on an
unconditional EVEX vector move:

```text
0000000180084244: 48 85 C0           test   rax,rax
0000000180084247: 74 65              je     00000001800842AE
0000000180084249: 62 F1 7C 48 10 05  vmovups zmm0,zmmword ptr [00000001800D9B40h]
```

`62` is the EVEX prefix and `zmm0` is an AVX-512 register. The preceding `je` is
a null check on an allocation, **not** a CPUID or ISA dispatch, and the store is
compiler-emitted object initialisation followed by `vzeroupper`. The AVX-512
therefore runs unconditionally during model load rather than inside an optional,
dispatch-guarded kernel: there is no runtime path that could have selected a
lower variant instead. On this host that instruction raises `#UD` by definition.

## Instruction-set census

Register census over `dumpbin /DISASM` output. Every figure below is measured with
one pattern per row, because a count without its pattern is not reproducible:

| DLL | `zmm` substrings | `zmm` register operands | `ymm` \| `k` mask |
|---|---|---|---|
| release `ggml-cpu.dll` | `14637` | `11926` | present; `0` in the control |
| release `whisper.dll` | `0` | `0` | `0` |
| release `sanad_whisper.dll` | `0` | `0` | `0` |
| local A/B control `ggml-cpu.dll` | **`0`** | **`0`** | **`0`** |

`14637` counts every `zmm` substring and therefore includes the `2711` `zmmword`
memory-size spellings; the register-operand count is `11926`, spread over `6497`
instruction lines. The two reconcile exactly (`11926 + 2711 = 14637`), which is
why both are stated — an undefined "zmm count" is ambiguous. The mask-register
column is deliberately qualitative: `k`-operand counting depends on which
spellings a given scan matches and the two records in this repository use
different patterns, so it is reported as present-in-release and absent-in-control
rather than as a comparable integer. See
[Task 439](../plans/tasks/439-windows-ggml-native-build.md) for the
pattern-by-pattern table used on the payloads it rebuilt.

The AVX-512 is concentrated in `ggml-cpu.dll` — the ggml compute backend, the
member a native configure produces.

## Excluded owners

- **The Agent version and Dart control flow.** The fault is reached through the
  shim's model-load entry on an unmodified probe that never runs Agent dictation
  code, with the same Dart host in both arms; no Agent-level path is required to
  reproduce.
- **Packaging and archive layout.** Manifest, `SHA256SUMS` and asset digest all
  agree; members are exactly the documented allowlist plus the bounded `sherpa/`
  subtree; the loader preloaded the siblings and reached the libraries.
- **The model and the audio.** Both arms used the same checkpoint and the same
  pinned fixture; arm A decoded them without a native fault.
- **The host toolchain and SDK.** Both arms used the same `dartvm.exe` and the
  same worktree packages; only `SANAD_WHISPER_LIBRARY` differed.

## Why every gate stayed green

The Windows lane has no instruction-set gate, so nothing in-tree compares the
shipped bytes with the declared baseline. Four gates applied and each one
necessarily passed, for the reasons recorded in
[the owning technical page](../technical/native_stt_runtime_platforms.md#the-windows-configure-contract):

| Gate | State before the fix | Why it could not catch this |
|---|---|---|
| Builder cache contract | present, **pre-configure only** | It discarded a *previous* tree whose recorded value disagreed, then configured; nothing read the cache the configure wrote, so the literal value was rewritten and never inspected |
| Instruction-set disassembly | **absent on Windows** | The guard returns `skipped` for any non-Linux target *before* it consults `SANAD_STT_REQUIRE_NATIVE`, and `--verify` prints `native_stt_isa=skipped` and exits `0` |
| `agent/native/checksums.json` pins | `windows-x64` unpinned | Presence and machine-architecture only; no byte-level pin to compare |
| Real load smoke on the producing runner | passed | It answers "does it run *here*", never "can the declared floor run it" — and the producing runner is above the payload's requirement, not below it |

The last row is the structural reason this class keeps escaping: the same shape
produced v1.0.22's arm64 `SIGILL` with `native_stt_ldd_*=ok` green, and v1.0.23's
x64 `#UD` with every gate green.

## Remaining uncertainty

- The release-runner CPU features and the exact v1.0.23 configure invocation are
  unverified; the cache was never captured.
- The local control's own build flags are unrecorded, so only its instruction set
  is claimed, proven by disassembly.
- The reporting user's machine was not diagnosed. The claim is that the artifact
  contains code that faults on a host below its requirement, not that their crash
  was this instruction at this address.
- The packaged `.exe` end-to-end path was deliberately not exercised: doing so
  needs a second daemon and a throwaway Home, which was out of scope.

## Harness boundary

Both arms were plain `dartvm.exe` children of an evidence runner run outside the
repository. No daemon, Client, managed runtime, or alternate Sanad Home was
started; the model was opened read-only; and no product code was modified by the
investigation. The single host setting touched was the Windows Error Reporting
`DontShowUI` value, set so a modal dialog could not block a crashing child, then
removed and verified absent.
