---
title: "Windows STT CPU Thread Default"
status: completed
issue: "https://github.com/EastStarAI/sanad-agent/issues/445"
---

## Goal

Use the accepted Windows CPU benchmark to avoid the expensive six-thread default on supported Windows x64 hosts while preserving explicit configuration and non-Windows behavior. Addresses Issue #445 ("Windows CPU dictation spends excess work at the six-thread default").

## Evidence

`docs/plans/tasks/windows-stt-cpu-thermal-benchmark.md` is the accepted record of the fixed AVX2-safe 2/4/6-thread comparison (independent reviewer session `oneshot-4d7cc4db-2df6-485b-b5aa-7dd0aafbf91c`, verdict ACCEPT). In its certified evidence set, `matrix-ar-final`, the 4-thread row has a **median** RTF of 0.628 and a **median** total of 27.55 CPU-seconds per 11.0 s utterance, which clears the investigator-chosen interactive thresholds (median RTF `<= 0.65`, median CPU-seconds `<= 30`). Six threads saved 1.27 s of **median** wall time in that same set while adding 6.31 CPU-seconds per utterance; the corroborating sets reproduce the ordering and the direction of the gap (4 -> 6 wall saving 0.84 s, 1.50 s, and 1.63 s in the interleaved control), but with n = 3 per cell the 1.27 s value itself is a certified-set figure, not a resolved difference. The benchmark establishes no temperature, package-power, fan, or energy result, so this task claims only the latency and CPU-seconds trade it measured.

## Scope

- Make the implicit default ABI-aware and independently testable.
- On Windows x64, cap the implicit default at four threads without oversubscribing machines with fewer than four logical processors.
- Preserve the existing six-thread wide-machine policy for non-Windows ABIs; its evidence comes from the Apple Metal path and must not be generalized to Windows CPU inference.
- Preserve explicit `stt.threads` values and the existing validation range (`1..16`).
- Update the owning technical documentation and focused tests.
- Do not change model selection, GPU policy, native build flags, runtime acquisition, or Client UI.

## Acceptance Criteria

- [x] Windows x64 resolves `2 -> 2`, `4 -> 4`, `8 -> 4`, and `16 -> 4` for the implicit default.
- [x] Representative macOS/Linux ABIs preserve the existing wide-machine `>=8 -> 6` behavior.
- [x] Unknown/non-positive core counts remain safely bounded at four.
- [x] An explicit valid `stt.threads` value still wins unchanged.
- [x] Focused tests prove ABI behavior and configuration precedence.
- [x] Agent analyzer and focused tests pass with bounded output.
- [x] Documentation cites the accepted benchmark and distinguishes latency/CPU evidence from unmeasured temperature and energy.
- [ ] Graphify is updated after the code change — **waived by the user for this task.** The contract's publish path `graphify-out/graph.json` is absent in this worktree and in the primary checkout, and `.gitignore:57-58` ignores `graphify-out/` and `.graphify/`. A git-ignored CLI store **does** exist at `.graphify/` (`graph.json` + `GRAPH_REPORT.md`, built 22:33:26 from this worktree's changed tree; it contains `defaultSttThreadsFor` and zero case-sensitive occurrences of the removed `sttThreadsFor`), so graph state exists but produces no tracked artifact, and it was not refreshed after the 22:48:18 comment-only edit. The box stays unchecked for that reason — not because no graph existed.

## Definition of Done

- [x] Product code, tests, and technical documentation form one focused candidate.
- [x] No commit, push, PR, daemon restart, Home, or database change occurs without the existing authorization boundary.
- [x] A separate DeepSeek V4.1 Flash Max reviewer accepts or rejects the candidate; corrections return to the original implementer session and re-review returns to the original reviewer session. Accepted by session `oneshot-0a8abe36-b671-49ae-ae89-c5d8b052c9e3` after three review rounds (2026-11-14T21:23:41Z).

## Progress

Single owner: `defaultSttThreadsFor(abi, cores)` in
`agent/lib/infrastructure/stt/stt_settings.dart`, reached by the implicit
`config.yaml` paths through `defaultSttThreads`. `windowsX64` caps at
`min(4, cores)`; every other ABI keeps `min(4, cores)` below eight cores and `6`
from eight up; a non-positive width resolves to four. The `abi` argument of
`SttSettings.load` now selects both the `use_gpu` and the `threads` default, so
both carve-outs are provable from any host.

Evidence:

- `agent/test/stt/stt_settings_test.dart` — Windows x64 2/4/8/16, small-host
  non-oversubscription, macOS/Linux wide-machine policy, non-positive width,
  absent-key routing for a missing file and for a `stt:` section without
  `threads`, and an explicit `threads` value winning on every ABI.
- `fvm dart analyze` in `agent/`: no issues.
- `fvm dart test test/stt/stt_settings_test.dart test/stt/warm_engine_test.dart`:
  all tests passed.

Documentation: `docs/technical/local_dictation.md` owns the per-ABI table, the
benchmark citation, and the explicit statement that temperature, package power,
and fan behaviour were not measured; `docs/technical/native_stt_runtime_platforms.md`
points at it beside the other ABI-aware default. The absent-key path previously
fell back to the literal `4` when `config.yaml` was missing; it now follows the
same resolver so the Windows x64 cap is not bypassed on the default home. For
every non-Windows ABI the resolver still answers `min(4, cores)` / `6`, so the
wide-machine policy is unchanged.

### Graphify state and the user's waiver

Graphify was checked as bounded evidence rather than assumed, and the check
turned up a state the first replacement rationale got wrong:

- The contract's publish path, `graphify-out/graph.json`, is absent in this
  worktree and in the primary checkout; `.gitignore:57-58` ignores both
  `graphify-out/` and `.graphify/`.
- A git-ignored CLI store **does** exist at `.graphify/` — `graph.json` plus
  `GRAPH_REPORT.md` and its scope/branch/worktree records, built 22:33:26 from
  this worktree's changed tree. Its content matches the working tree rather than
  HEAD: it contains `defaultSttThreadsFor` and zero case-sensitive occurrences of
  the removed `sttThreadsFor`.
- That store was **not** refreshed after the final 22:48:18 comment-only edit to
  `agent/lib/infrastructure/stt/stt_settings.dart`.

The user then explicitly waived further Graphify work for this task. The
criterion is therefore recorded as **waived by the user**, not as satisfied and
not as "no graph exists": graph state exists, it yields no tracked artifact, and
refreshing it for a comment-only edit was waived.

### Correction rounds

Reviewer session `oneshot-0a8abe36-b671-49ae-ae89-c5d8b052c9e3` rejected the
first candidate on documentation integrity, not on the code it had verified, and
rejected the second on the truthfulness of the Graphify rationale. Every finding
is resolved in this candidate:

| Round | Finding | Resolution |
|---|---|---|
| 1 | B1 cited benchmark not accepted in-repo | The benchmark record is now part of this branch with `status: accepted`, the certified `matrix-ar-final` 2/4/6 table, and the reviewer session record; both citations resolve. |
| 1 | B2 Graphify criterion checked while the contract path was absent | The criterion is unchecked with the bounded check recorded above. |
| 1 | W1 unqualified target/variability wording | The cited figures now name `matrix-ar-final` and qualify both RTF and CPU-seconds as medians; the unsupported "higher variability" claim is removed and the 1.27 s gap is bounded to the certified set, with the corroborating 0.84/1.50/1.63 s deltas stated. |
| 2 | B2 rationale claimed "no repository graph existed" | Corrected: a git-ignored `.graphify/` store exists and was built from the changed tree, `graphify-out/graph.json` is absent, the store predates the comment-only edit, and the user waived further Graphify work; the criterion is marked waived rather than justified by absence. |
| 2 | Numeric text: 4-thread wall minimum and inconsistent headroom | The benchmark table and its confidence paragraph now read `6.602` (raw `6.6019`), and the 4-thread latency margin is stated against one base (3.4 % of the 0.65 threshold) with the cost margin as 8.2 %. |
| 3 | Re-review of the waiver and numeric edits | **ACCEPT** from the same session `oneshot-0a8abe36-b671-49ae-ae89-c5d8b052c9e3`; it independently re-measured the `.graphify/` store (size, mtime, symbol content), recomputed 3.46 %/8.18 % headroom, and re-ran the analyzer plus focused tests. No blocking findings; its two residual notes (the pre-existing `stt.threads: 17` case is untested, and Windows arm64 keeps `>=8 -> 6` by design) are already disclosed above. |

No product behavior changed in these rounds: only documentation and one Dart doc
comment. `fvm dart analyze` and the focused STT settings tests were re-run.
