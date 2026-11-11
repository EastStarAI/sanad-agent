# 169 — The two defects the real Windows lane found in the STT suites

**Status:** implemented on `fix/stt-windows-ci`
**Owners:** `agent/test/stt/stt_download_pipeline_test.dart` (the refused-write
contract), `agent/test/stt/stt_pipeline_cost_test.dart` (the cost gate's new
process), `.github/workflows/ci.yml` (the lane that runs it)
**Contract:** [docs/technical/local_dictation.md](../../technical/local_dictation.md),
[docs/operations/continuous_integration.md](../../operations/continuous_integration.md)
**Predecessor:** #168 / PR406 (the `close()` handle boundary this regression test
now exercises on the failure path)
**Evidence:** PR405 run `42911356395`, job `Native dictation (windows-2025)`

## Goal

The per-OS dictation lane PR405 introduces runs the download write pipeline on
`windows-2025` for the first time. It found two things the Linux and macOS lanes
could not, and both are in the tests rather than in the shipped pipeline: a
regression test that never closed the handle it opened, and a cost gate whose
measurement shape charged the isolate for its neighbours.

## Locked decisions and scope

- **The leaking test closes what it opened.** `a refused write surfaces as
  SttWriteFailure with its errno` proved the typed error and then returned without
  closing the pipeline, so the sink's `RandomAccessFile` stayed open. On Windows an
  open handle on a file inside a directory makes the directory undeletable, and the
  suite's `tearDown` reported the failure as `OS Error: ... errno = 32` instead of
  as a test failure. The fix is two lines at the end of that test — `close()` must
  rethrow the same typed failure, and the descriptor must be gone — not a second
  test restating the contract, so the duplicate that had been added to cover the
  gap is removed.
- **The cost gate owns a file, therefore a process.** A ratio measured beside
  another suite, or always in the same order, charges one arm for the other's
  contention and warm-up. The gate moves out of `stt_download_pipeline_test.dart`
  into `stt_pipeline_cost_test.dart`, which warms both arms, runs five alternating
  paired trials, and judges the **median** paired ratio.
- **The threshold does not move.** It stays `> 0.5` (the isolate may cost up to
  twice the in-process sink) on every platform. A lane that cannot meet it with
  this method reports its numbers; changing the bound is a policy decision, not a
  test edit.
- **The lane runs it explicitly.** `Native dictation` gained two steps (bash and
  PowerShell) for the new file, because a step that lists files by name would
  otherwise leave the gate on the Linux shards only.

## Invariants the tests pin

| Invariant | Test |
|---|---|
| A refused write surfaces as `SttWriteFailure` with its errno, and closing it rethrows the same failure after releasing the descriptor | `test/stt/stt_download_pipeline_test.dart` |
| The isolate hop stays inside twice the in-process sink for one window of bytes | `test/stt/stt_pipeline_cost_test.dart` |

## Result

macOS arm64 (owner's machine, ambient load), median of five alternating pairs:
**1.054** (`1.054, 1.821, 0.527, 1.482, 0.593`). The spread is the point of the
paired median: the same code measured 0.527 in one pair and 1.821 in another.

`windows-2025` under the old in-suite shape measured in-process 443 ms against
isolate 1232 ms for 64 MiB — a ratio of 0.36, or the isolate at 2.78x. The lane's
number under the new shape is recorded in the delivery report for this task; the
bound was not changed to meet it.

## Verification

- `fvm dart analyze lib/infrastructure/stt test/stt` — no issues.
- Each suite in its own process, all green: `stt_digest_test` (10),
  `stt_download_pipeline_test` (29), `stt_install_memory_bound_test` (3),
  `stt_install_resume_test` (10), `stt_model_store_test` (15),
  `stt_install_control_test` (11), `dictation_control_install_test` (10),
  `dictation_model_readiness_test` (9), `stt_pipeline_cost_test` (1).
