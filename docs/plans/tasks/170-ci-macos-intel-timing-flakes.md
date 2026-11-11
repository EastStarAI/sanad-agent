# 170 — The two macOS Intel timing flakes in the v1.0.23 tag run

**Status:** implementing on `fix/ci-macos-intel-flakes`
**Owners:** `agent/test/stt/stt_digest_test.dart` (the correctness half it keeps),
`agent/test/stt/stt_digest_cost_test.dart` (the speed gate's own process),
`agent/test/core/sanad_home/runtime_ownership_holder_test.dart` (the readiness
deadlines), `.github/workflows/ci.yml` (the `Native dictation` step),
`scripts/ci/lane_inputs.txt` (that file's lane declaration)
**Contract:** [docs/operations/continuous_integration.md](../../operations/continuous_integration.md),
[docs/qa_maintenance/test_suite_performance_qa.md](../../qa_maintenance/test_suite_performance_qa.md)
**Predecessor:** #164 / PR402 (the native digest this gate measures), #169 / PR407
(the pipeline cost gate's own process, which this change copies)
**Evidence:** v1.0.23 tag run `42902755118`, job `Native dictation (macos-15-intel)`,
attempts 1 and 2

## Goal

Both failures in that run are test-harness timing defects, not product failures,
and neither may be repaired by weakening what it asserts:

1. The digest speed claim was one sequential pure-then-native wall-clock interval
   inside a suite that runs beside other suites. Attempt 1 measured
   `2.1436228186256465` (native 556 ms, pure Dart 1193 ms for 64 MiB) while the
   native backend was selected and both arms returned identical digests. A
   sequential pair charges the shorter arm for whatever the host did during it.
2. The lock-holder test gave a fresh `dart` process 10 wall-clock seconds to JIT
   its entry point, prepare a Home, take a file lock, and print `locked`. The
   same repository had measured that spawn-and-compile shape at up to **36 s** on
   `macos-15-intel` and had already moved the sibling ownership test to a 120 s
   failure deadline one day earlier; this file copied the stale literal.

## Locked decisions and scope

- **The ownership synchronization event does not change.** The test keeps waiting
  for the exact `locked` line; only the failure deadline moves to 120 s (3.3× the
  measured worst case) with a 120 s exit deadline and a 5 min outer `Timeout`, and
  a stall now fails with the phase, the child pid, its exit status, and the
  captured stderr instead of a bare `TimeoutException`.
- **The digest ratio moves, it does not shrink.** The timing case leaves the
  concurrently executed unit file. `stt_digest_test.dart` keeps every parity,
  native-selection, independent-context, wide-chunk, finish, and cleanup case
  unchanged.
- **The replacement gate is the one #169 established,** in the existing five-OS
  `Native dictation` matrix and in no new job: one 64 MiB buffer, both arms
  warmed, five **alternating paired** trials, equal-digest and native-selection
  checks, structured per-trial output, and the **median paired wall-clock ratio**
  against the unchanged **2.5×**.
- **Fail closed on calibration.** A lane below 2.5× is reported with its numbers
  and stops there. The bound is a performance-policy decision (optimize the copy/
  call path or approve a platform threshold with evidence), never a test edit.
- **Deferred:** portable CPU-time FFI (`getrusage`/`GetProcessTimes`), production
  instrumentation or update-count seams, a compiled lock helper, and refactoring
  both ownership tests onto a shared harness.

## Gates

### G0 — Evidence and root cause
- [x] Both failures read out of run `42902755118` attempts 1 and 2, and the
      adjusted per-lane rates from the previous 60 runs (digest 1/10, holder 1/13
      on `macos-15-intel`, both 0 on the other lanes).
- [x] The 36 s spawn-and-compile measurement on `macos-15-intel` that already
      moved `runtime_ownership_test.dart` to 120 s.
- [x] Confirmed the failed digest case asserted no correctness property: the
      native backend was selected and both arms produced the expected digest.

### G1 — Ownership deadlines (one file)
- [x] `runtime_ownership_holder_test.dart` waits for the exact `locked` line with
      a 120 s failure deadline, a 120 s exit deadline, and a 5 min outer timeout.
- [x] A premature stdout close and a readiness timeout both fail with the phase,
      the child pid, its exit status (or that it outlived the exit budget), and
      the trimmed captured stderr.
- [x] The child is still a real separate process, and every existing assertion
      (record names the child pid, launcher id and nonce, live child, refused
      second owner, live-holder wording without "stale", clean release exit) is
      unchanged.

### G2 — Digest gate in its own process
- [x] The timing case is gone from `stt_digest_test.dart`; its header now states
      where the speed claim is measured.
- [x] `stt_digest_cost_test.dart` gates the median of five alternating paired
      trials at 2.5× on one 64 MiB buffer, asserts native selection, and asserts
      both arms produce the reference SHA-256 on every trial.
- [x] Each trial prints one structured line and the verdict line prints the
      median, all trials, the platform, the byte count, and the threshold.

### G3 — CI wiring and lane declaration
- [x] `Native dictation` runs the new file in its own step (bash and `pwsh`
      twins), beside the pipeline cost gate, in the existing matrix.
- [x] `scripts/ci/lane_inputs.txt` declares `entry native-stt
      agent/test/stt/stt_digest_cost_test.dart`, and
      `agent/test/tool/ci_lane_inputs_test.dart` passes.
- [x] The stale comments in `ci.yml` that explained the old in-suite ratio are
      corrected.

### G4 — Documentation
- [x] `docs/operations/continuous_integration.md` describes both cost gates and
      why each owns a process.
- [x] `docs/qa_maintenance/test_suite_performance_qa.md` records the measured
      per-file costs, the new step, and the corrected concurrency statement.
- [x] `docs/plans/tasks/164-stt-download-throughput.md` points its "measurably
      faster" invariant at the gate that now measures it.
- [x] `docs/llms.txt` indexes this record.

### G5 — Verification and delivery
- [x] `fvm dart analyze` on every touched path.
- [x] Each changed test in its own process locally: `stt_digest_test.dart`,
      `stt_digest_cost_test.dart`, `runtime_ownership_holder_test.dart`, and
      `runtime_ownership_test.dart`.
- [x] PR opened with `type/test`, `comp/agent`, and `platform/macos` after the
      label manifest was re-read, and the label set re-verified from
      `gh pr diff --name-only`.
- [x] CI settles on the exact head, and the per-lane benchmark step duration,
      median ratio, and trial numbers are recorded in the delivery report.
- [x] The holder case is re-run on `macos-15-intel` at least 3× through
      `gh run rerun --job` to cross the contention window it failed in. There is
      no retry logic in the test.
- [x] Fail-closed check: if any lane's median is below 2.5×, the delivery stops
      and reports that lane's numbers as an owner decision instead of shipping a
      lowered, skipped, or retried gate.

## Out of scope

Portable process-CPU-time measurement, a production seam that counts native
updates, precompiling the lock helper, `--concurrency 1` removal from the digest/
pipeline step, and any change to `stt_digest.dart` or the lock implementation.
