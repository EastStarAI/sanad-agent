---
title: "Task 438 — Development Native STT Provisioning"
issue: "https://github.com/EastStarAI/sanad-agent/issues/438"
status: implemented (review round applied)
---

## Goal

Make a supported fresh source checkout prepare native dictation through `sanad-dev setup` or `sanad-dev run` without a manual Dart command, while keeping every preparation failure observable and dictation-only.

## Locked Scope

- `scripts/sanad_dev` owns source-run orchestration; `agent/tool/ensure_native_stt.dart` owns runtime acquisition/build/verification.
- Windows must never discard preparation diagnostics to the null device.
- Daemon startup must not be blocked by optional dictation preparation.
- Use a verified compatible artifact when one exists; otherwise use the pinned source/build path or report a typed prerequisite failure.
- Do not change production dictation decoding, models, or transport in this task.

## Locked Decisions

- **One acquisition owner.** `agent/tool/ensure_native_stt.dart` stays the only code that downloads, builds, or verifies the runtime. The launcher and the wrappers invoke it; none of them restates its arguments or verification.
- **`setup` waits, `run` never does.** `setup` runs the tool awaited, reports the tool's own machine keys, and always exits 0 (a failed preparation must not fail the bootstrap a developer depends on). `run` starts the same tool **detached** — the shell owns the log, so the attempt survives the launcher — and reports only that it started plus where the result will appear. A launcher that exits cannot verify a verdict, and an attached child either dies mid-build or holds the terminal behind it.
- **`switch` prepares nothing.** It moves an already-running runtime group; there is no checkout to bootstrap and no attempt to start.
- **No new acquisition channel.** A verified `_archive` pin, `--archive-url`, `--whisper-src`/`WHISPER_CPP_SRC`, or a discovered whisper.cpp tree remain the only ways to acquire a runtime; when none is available the tool reports `prerequisite_missing` instead of inventing an unverified download.
- **One attempt at a time, asserted atomically on the marker readiness already reads.** `agent/native/.stt-preparing` (fresh for 30 minutes, `sttPreparingMarkerMaxAge`) is the single-flight claim. The tool takes it with one exclusive create and writes its pid; a loser reports `busy` instead of staging the same `native/<tag>.tmp` twice. No second state file or lock is introduced.
- **A dead claim is recovered, not waited out.** A marker whose recorded pid is provably gone expires immediately (`kill -0` / `tasklist`), so a killed attempt cannot block retries for the whole window. A marker with no readable pid counts as live, because an unprovable claim is never cleared by guesswork. `--force` stays the deliberate override for a stuck *live* attempt.
- **Typed terminal result instead of prose.** The tool ends with `native_stt_stage`, `native_stt_result`, and `native_stt_failure`; the wrappers read `native_stt_result=` from the attempt's own slice of the log, so `busy` is never reported as `ready` and an earlier `ready` cannot answer for a later failure. The agreement is a cross-package contract, asserted rather than trusted.
- **The Client no longer asks for a developer command.** Readiness keeps its reason and the "Set up now" retry; the sentence and the `prepare_unavailable` payload name managed preparation instead of `fvm dart run tool/ensure_native_stt.dart`.

## Gates

### G0 — Discovery
- [x] Map current `setup`/`run` preparation ownership, retry behavior, logs, and tests.
  - Before this task: `setup` prepared nothing (install → dependencies → runtime CLI compile); `run` called `prepareNativeDictation`, which spawned a **detached** `cmd /c "fvm dart run tool\ensure_native_stt.dart > NUL 2>&1"` on Windows and `> native/.stt-prepare.log` elsewhere, on every run with no dedup, no typed result, and a prose-only failure.
  - `run`'s setup prelude never awaited anything dictation-related, and `sanad-dev setup` itself never invoked the tool, so a fresh checkout had no supported path.
  - The daemon's `prepareRuntime` retry appended to `native/.stt-prepare.log`; readiness read `native/.stt-preparing` (< 30 min) for `native_runtime_preparing`.
  - The Client carried the dead end: `dictationRuntimeMissing` and the `prepare_unavailable` payload both told the user to run the acquisition command by hand.
- [x] Decide the leanest compatible artifact/cache contract without duplicating release verification.
  - Reuse the existing channels unchanged: the pinned `_archive`/`--archive-url` download (verified by the release manifest's sha256), the pinned source/build path, or a typed `prerequisite_missing`. No new cache, no second verifier, no release-metadata client in the launcher.

### G1 — Implementation
- [x] Add one reusable preparation owner used by setup and run.
  - `agent/tool/ensure_native_stt.dart` remains that owner. `scripts/sanad-dev setup` awaits it through `run_dictation_prepare`; `scripts/sanad-dev.ps1` does the same through `Invoke-DictationPreparation`; `run` passes `false` so the launcher starts it detached via `prepareNativeDictation`, and `switch` never prepares at all.
- [x] Preserve a bounded durable Windows result/log and expose retryable failure state.
  - Every attempt appends to `agent/native/.stt-prepare.log`; each writer resets it to one header line before starting when the previous attempt pushed it past 1 MiB (the daemon resets before it spawns, because the shell owns the handle afterwards). No preparation surface discards output. A failure is reported with its stage, typed cause, that log, and the managed `sanad-dev setup` retry; the tool prints the same three machine keys for CI and issue reports. The PowerShell wrapper appends each line as it arrives (one UTF-8 no-BOM handle, `AutoFlush`), so an interrupted build keeps everything it produced.
- [x] Remove the dead-end Client instruction when managed preparation is available.
  - `client/lib/l10n/app_en.arb` / `app_ar.arb` `dictationRuntimeMissing` and the daemon's `prepare_unavailable` payload now describe managed preparation plus the existing "Set up now" retry.

### G2 — Verification
- [x] Cover ready, fresh-checkout success, missing prerequisite, failed acquisition, and no-repeat background attempts.
  - `scripts/sanad_dev/test/runtime/lifecycle/native_runtime_probe_test.dart`: ready means no attempt; one attempt against the durable log; an in-flight marker with a live owner starts nothing; an abandoned claim (owner gone) is cleared and replaced; a typed failure lands in the log; a ready attempt is recorded; `busy` is reported as busy and never as ready; a failing runner never throws; an oversized log is bounded; the legacy macOS alias stays bounded; and the *real* spawn path is covered with a fake `fvm` — detached, streaming into the durable log, and never claiming a verdict it cannot observe.
  - `scripts/sanad_dev/test/cli/sanad_dev_bootstrap_test.dart` and `sanad_dev_windows_bootstrap_test.dart`: `setup` ends with exactly one acquisition invocation, reports `ready` only from the tool's keys, reports `busy` as "already running" without a failure, a failed preparation keeps `setup` at exit 0 with the failing lines and the typed keys in the log, `run` never invokes the tool eagerly, and incremental `setup` repeats only the dictation stage.
  - `agent/test/stt/stt_native_platform_test.dart`: fresh/stale/future markers, a dead owner expiring immediately, an unreadable marker never being cleared, the exclusive claim refusing a second attempt, `--force` replacing a live claim, and the log bound.
  - `agent/test/tool/native_runtime_package_contract_test.dart` (`development launcher preparation contract`): tool ↔ launcher key agreement, one claim rule and one window, no null-device redirect on any preparation line (including `$null` and `/dev/null`), the detached spawn guard (no child pipes, no poll timers), one shared log bound, and `setup` waits while `run` does not.
- [x] Run owning analyzers and focused tests with elapsed/bounded output.
- [x] Update the owning technical documentation and Graphify.

## Acceptance Criteria

- [x] Given a supported fresh checkout, setup/run reaches a verified native runtime without a manual Dart invocation.
  - `setup` invokes the acquisition tool itself and reports its keys (asserted in both wrapper suites); `run` starts it detached so the daemon is not delayed. Neither prints a command the user must run. Verified live on Windows: `sanad-dev setup` reached the acquisition stage, reported the typed failure, and exited 0.
- [x] Given an unavailable acquisition/build prerequisite, the daemon still starts and one durable typed diagnostic identifies the failed stage and retry path.
  - Live Windows evidence (no cmake, no whisper.cpp source, no pinned archive): `Preparing native dictation | unavailable`, then `native_stt_stage=acquire`, `native_stt_result=failed`, `native_stt_failure=prerequisite_missing` in `agent/native/.stt-prepare.log`, `retry: sanad-dev setup`, and `setup` still exited 0 — so `run` proceeds to start the daemon.
- [x] Windows output is never redirected to the null device.
  - The detached shell appends the attempt to the log, the wrappers append to the same file, and the contract test fails if any *preparation* line regains a null-device redirect (`NUL`, `> $null`, `/dev/null`), while non-preparation probes keep theirs.
- [x] Repeated run commands do not create overlapping or unbounded installer attempts.
  - One atomic exclusive claim decides a single attempt; a loser reports `busy` and stages nothing. A claim whose owner is gone is taken over instead of waited out, so a killed attempt cannot deadlock retries. The log is reset to one header line per attempt once it passes 1 MiB, by every writer.

## Definition of Done

- [x] Implementation and docs are complete in the isolated worktree.
- [x] Analyzer and focused tests pass.
- [ ] A separate reviewer session accepts the candidate; fixes return to the original implementer session and re-review returns to the original reviewer session.
- [ ] Stop before Ready/merge without separate authorization.

## Review Round (independent technical review)

The first candidate was reviewed and rejected on two blockers plus W1–W3 and
S1–S5. Everything below is either fixed or answered with proof; nothing was
waived.

| Item | Disposition |
|---|---|
| **B1** — background preparation lost its detachment | **Fixed.** The launcher spawns the attempt through `cmd /c` / `/bin/sh -c` with `ProcessStartMode.detached` and the shell owning `>> native/.stt-prepare.log`. No pipes and no poll timer exist, because a pending timer also keeps a Dart process alive (measured: 7.1 s empty vs 10.7 s with a 4 s periodic timer). The launcher now reports only what it can observe — that the attempt started, and where its result will appear — and `setup` remains the awaited report. The contract test fails if the spawn regains child pipes or a timer. |
| **B2** — `setup` printed "ready" for a `busy` refusal | **Fixed.** Both wrappers read `native_stt_result=` from the attempt's own slice of the log (bytes after the pre-attempt offset, so a previous `ready` cannot answer). `ready` prints ready; `busy` prints "already running" plus the log and is not a failure; anything else prints the failed stage, this attempt's tail, and the retry. Covered by a new busy case in both wrapper suites and by a probe test. |
| **B2b** — the documented escape for a stale marker was unreachable | **Fixed at the root, not by a flag.** The claim now records its owner's pid, and a claim whose process is provably gone expires immediately, so a killed attempt no longer blocks for the window. Nothing must be forced from a shell; `--force` stays the deliberate override for a stuck *live* attempt. |
| **W1** — PowerShell buffered the whole attempt | **Fixed.** One append handle with `AutoFlush`, one line per pipeline item, so the log streams and an interrupted attempt keeps what it wrote. Memory no longer holds the compiler output. |
| **W2** — the daemon's writer was unbounded, and wrappers deleted the log | **Fixed.** `resetBoundedSttPreparationLog` runs in the daemon *before* it spawns (the shell owns the handle afterwards), the shared bound is `sttPreparationLogLimitBytes = 1 MiB`, and every writer — launcher, daemon, both wrappers — writes one header line instead of deleting. Bounding is per attempt and documented as such. |
| **W3** — single flight was not atomic | **Fixed.** `sttClaimPreparation` is one exclusive create, so a loser cannot stage the same `native/<tag>.tmp`. The pid makes the claim self-expiring when its owner dies. The phrase "can never stage one runtime twice" is now true, and the launcher's pre-check mirrors the same rule. |
| **S1** — the real spawn path had no test | **Fixed.** `detached attempt` group drives the real `_startPreparationTool` with a fake `fvm`: output reaches the durable log, the launcher reports "started", and no ready verdict is claimed. |
| **S2** — the null-device contract test only rejected `NUL` | **Fixed.** `> $null`, `1>`/`2>` variants, and `/dev/null` spellings are rejected — but only on *preparation* lines, because `command -v … >/dev/null` in a tool-presence probe is legitimate. |
| **S3** — the Windows log assertion passed on an empty file | **Fixed.** The test now asserts the log content (`cmake is not installed`, the three typed keys) and that the failing lines are echoed on the terminal. |
| **S4** — bare `fvm` from a shim-started shell | **Fixed without quoting.** The wrappers export `SANAD_DEV_FVM_BIN`; the launcher prepends the resolved directory to the child's `PATH` and keeps the command quote-free, since `cmd /c` mis-parses a quoted program path (verified while implementing this round). |
| **S5** — docs claimed `switch` prepares | **Fixed.** `switch` prepares nothing; the technical doc, ownership doc, the package contract, and this plan now say so. |

## Evidence

All commands ran in the isolated worktree on this Windows host; output was bounded to the last lines and exit status preserved.

| Command | Result |
|---|---|
| `fvm dart analyze` in `agent/` | `No issues found!`, exit 0 |
| `fvm dart analyze` in `scripts/sanad_dev/` | `No issues found!`, exit 0 |
| `fvm flutter analyze` in `client/` | `No issues found!`, exit 0 |
| `fvm dart test test/runtime/lifecycle/native_runtime_probe_test.dart` | 16 passed, exit 0 |
| `fvm dart test test/cli/sanad_dev_bootstrap_test.dart test/cli/sanad_dev_windows_bootstrap_test.dart` | 14 passed, 19 POSIX-only skipped, exit 0 |
| `fvm dart test` in `scripts/sanad_dev/` | `+569 ~21 -36`; the 36 failures are the same set as an unmodified `HEAD` worktree (`+555 ~19 -36`) — zero regressions, 14 new passing tests |
| `fvm dart test test/stt/native_runtime_readiness_test.dart test/stt/dictation_service_test.dart test/stt/stt_native_platform_test.dart test/tool/native_runtime_package_contract_test.dart` | `+76 ~1 -3`, stable across three consecutive runs; the 3 are the `release workflow` cases that fail identically on the unmodified `HEAD` file (release.yml shape, out of scope) |
| `fvm flutter test test/core/locale_cubit_test.dart test/widget/dictation_model_sheet_test.dart` | 24 passed |
| `powershell -File scripts/sanad-dev.ps1 setup` (live, this worktree) | dictation `unavailable (6s)` with the durable log and retry; exit 0; log 2122 bytes, zero NUL bytes, keys `acquire`/`failed`/`prerequisite_missing` |
| live claim held by a running pid, then `setup` | `already running (7s)`, marker preserved — `busy` is reported as busy, never as ready |
| claim rewritten with a dead pid, then `setup` | the tool takes it over, reports `unavailable (6s)` for the real prerequisite failure, and clears the marker — no 30-minute block |
| `bash -n scripts/sanad-dev` | clean |
| PowerShell AST parse of `scripts/sanad-dev.ps1` | 0 parse errors |
| POSIX `run_dictation_prepare` exercised through git-bash with a fake `fvm` | `ready`, `busy` ("already running", no failure text), failed (this attempt's tail + keys + retry, exit 0), a stale `ready` not answering for a later failure, and the oversized-log header all behave as designed |
| Timer probe (`fvm dart run` of a periodic timer) | 7.1 s empty vs 10.7 s with a 4 s timer — a watcher would hold `run` open |
| `graphify update .` | code graph rebuilt after the review fixes |

The baseline for the launcher numbers was produced by `git worktree add --detach <temp> HEAD`, resolving that worktree's dependencies, and diffing the extracted `[E]` test names against this branch: `Compare-Object` reports no new failure and no newly fixed failure. The same baseline run reproduced the *pre-existing* `native_runtime_package_contract_test.dart` load failure (`Cannot open file: ../release/release-contract.json`) that this round removed: that suite read repository files relative to a process-wide `Directory.current` that another suite temporarily points at a temp checkout.

## Unresolved / Follow-ups

- **Pre-existing Windows-only failures (not introduced here).** `test/cli/sanad_dev_prepared_runtime_fingerprint_test.dart` and the harness-driven suites execute the POSIX `scripts/sanad-dev` through `Process.run`, which Windows rejects (`%1 is not a valid Win32 application`). This is identical on an unmodified `HEAD` worktree and is the CI (Linux) lane's responsibility.
- **A test harness that shares one process.** `agent/test/stt/native_runtime_readiness_test.dart` points the process-wide `Directory.current` at a temporary checkout, so any suite that reads repository files relatively can fail while it does. This round made the launcher contract suite root-relative and gave that teardown a bounded retry, which removed the two failures it produced here; other suites that read `../…` at declaration remain exposed to the same pattern and are a test-harness follow-up, not a product defect.
- **POSIX suite coverage.** The `skip: Platform.isWindows` group cannot execute here; syntax, help output, and every dictation branch (ready, busy, failed, stale-key, oversized log) were exercised through git-bash, and CI owns the full run.
- **Live dictation still needs a real runtime.** This host has no cmake, no whisper.cpp checkout, and no pinned archive, so the end-to-end proof is the typed `prerequisite_missing` diagnostic plus the existing load-smoke lane. A full build with a real cmake is the one path no Windows run in this task exercised.
- **Acceptance ownership.** The review that produced this round ran on an authorized delegated model, so the plan's independent-review DoD line stays open for the reviewer session that owns it; the technical findings are addressed above.
- **`windows-arm64`** still has no portable producer; unchanged by this task.
