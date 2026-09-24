---
status: superseded
closure_reason: remaining-work-transferred-not-certified-complete
superseded_by: docs/plans/97-windows-first-agent-client-performance.md
current_gate: closed-transferred
priority: high
platforms: windows, macos, linux
depends_on: sanad-dev-windows-command-latency
---

# sanad-dev Cross-Platform Test Baseline Reliability

## Closure and transfer to Plan 97

**Closed as superseded, not completed.** This file is a historical evidence record,
not an active execution queue. All previously unchecked items (46 entries)
are transferred to the successor owners below. Checked items retain their
historical meaning; no unverified acceptance or security result is marked passed.
The successor owns the complete original obligations, including negative cases,
security review, documentation and delivery reconciliation, not only a summary.
Archived under docs/plans/done with superseded status; references point to this record or its Plan 97 successor. No independent work remains here.

| Original outstanding scope | New execution owner |
|---|---|
| G0 — inventory, startup separation, slowest ten cases | [97a](docs/plans/tasks/97a-baseline-and-ownership.md) |
| G1–G4 — fixtures, ownership isolation, cleanup, wrappers | [97d](docs/plans/tasks/97d-windows-test-baseline.md) |
| G5–G6 + acceptance — full hosted suites twice per OS, lane evidence/counts, fork safety, regression budgets, docs | [97k](docs/plans/tasks/97k-regression-budgets-and-report.md) |
| Runtime smoke + final lifecycle evidence | [97l](docs/plans/tasks/97l-interactive-final-acceptance.md) |

## Historical plan and evidence (non-executable)

The following goals, gates and acceptance statements describe the original task.
`Transferred` entries are preserved requirements now owned by the table above;
they are not open checkboxes in this retired plan. Historical commands and merge
instructions do not authorize new execution or duplicate delivery.



## Goal

Restore a deterministic, green `scripts/sanad_dev` baseline on Windows, macOS,
and Linux while preserving real OS-boundary coverage. Separate package/FVM
startup cost from case execution, remove platform-invalid fixtures, and ensure
future runtime-tool changes cannot silently regress a platform that was not used
for local development.

## Motivation and Baseline

- The Windows full suite currently exposes pre-existing failures involving
  POSIX-shaped path fixtures, ownership fixtures, secure runtime-file timing,
  and component-journal timing/cleanup.
- A Windows `fvm dart test` invocation on the measured host adds about 22 seconds
  before test execution; individual secure atomic writes take about nine seconds.
- Focused tests pass with an appropriate case timeout, but the full-suite signal
  must distinguish infrastructure startup, real integration cost, functional
  failure, and leaked exclusive resources.
- The runtime CLI and POSIX wrapper changes affect macOS/Linux as well as
  Windows, so hosted cross-platform lanes must be authoritative before merge.

## Scope

- All tests owned by `scripts/sanad_dev/test/` and their fixtures/helpers.
- Windows path, ownership, ACL, journal, subprocess, and timeout fixtures.
- macOS/Linux bootstrap, executable artifact, background relaunch, permission,
  process-discovery, and atomic-publication coverage.
- CI job structure, bounded logs, timing evidence, and platform matrix for the
  standalone package.
- Documentation in `docs/qa_maintenance/test_suite_performance_qa.md` and the
  runtime ownership QA matrix.

## Out of Scope

- Weakening production security, ownership, discovery, or atomic-write behavior
  to make a test pass.
- Skipping an affected platform lane or marking a failing test as unsupported
  when production claims support.
- Calling global Dart/Flutter instead of FVM.
- Optimizing the Windows secure runtime-file backend itself; that belongs to the
  dedicated security-reviewed performance task.
- Client widget or Agent product tests unrelated to `sanad-dev`.

## Test Classification

Every test must be classified as one of:

1. **Pure unit:** no process, filesystem permission, network port, or production
   timer dependency.
2. **Hermetic filesystem:** temporary paths and deterministic fake metadata,
   but no real ownership/ACL contract.
3. **OS integration:** real process table, ACL/mode, atomic replacement,
   subprocess, terminal adapter, or executable wrapper behavior.
4. **Exclusive integration:** binds a real port or owns a globally exclusive
   process/resource and therefore may require sequential execution.

Only class 4 may force global/sequential scheduling. Class 3 may use a larger
case timeout when measured OS work justifies it, but must remain narrowly scoped.

## Gates

### G0 — Baseline Inventory

- **Transferred to Plan 97:** Run the complete standalone package suite on Windows, macOS, and Linux and
      capture bounded failure lists plus total/case timing.
- **Transferred to Plan 97:** Separate FVM/package startup from test-case execution.
- **Transferred to Plan 97:** Classify every failure by product defect, platform-invalid fixture,
      timeout budget, resource contention, or leaked subprocess/port.
- **Transferred to Plan 97:** Record the slowest ten cases per platform and identify shared fixtures.

### G1 — Platform-Neutral Fixtures

- **Transferred to Plan 97:** Replace hard-coded `/users/...`, slash assumptions, drive assumptions,
      and case-sensitivity assumptions with explicit platform-neutral builders
      where the behavior under test is platform-neutral.
- **Transferred to Plan 97:** Retain literal POSIX and Windows paths only in parser tests that explicitly
      declare the target syntax and do not consult the host filesystem.
- **Transferred to Plan 97:** Normalize expected paths through the production-equivalent comparison
      boundary rather than ad hoc string replacement.
- **Transferred to Plan 97:** Add fixture tests for spaces, Unicode, drive roots, UNC syntax where
      supported, POSIX roots, and case behavior.

### G2 — Ownership and Secure-File Test Isolation

- **Transferred to Plan 97:** Give each test a unique temporary Home/runtime root and ensure teardown is
      bounded and observable.
- **Transferred to Plan 97:** Distinguish mocked ownership-policy unit tests from real OS ACL/mode
      integration tests.
- **Transferred to Plan 97:** Make expected owner/process identity fixtures host-independent while
      retaining negative PID-reuse and foreign-owner cases.
- **Transferred to Plan 97:** Apply measured case timeouts only to real OS integration tests; never hide
      deadlock or unbounded polling with a suite-wide timeout increase.
- **Transferred to Plan 97:** Keep security assertions unchanged while the separate secure-file task is
      pending.

### G3 — Journal, Subprocess, and Port Cleanup

- **Transferred to Plan 97:** Track every spawned fixture process and prove it exits on success, failure,
      and timeout.
- **Transferred to Plan 97:** Ensure component journals flush/close without relying on fixed sleeps.
- **Transferred to Plan 97:** Reserve real ports deterministically and run only conflicting cases
      sequentially.
- **Transferred to Plan 97:** Assert no test leaves a launcher record, startup locator, temporary file,
      child process, or listening port after teardown.
- **Transferred to Plan 97:** Preserve exit codes and show only bounded diagnostic output in CI.

### G4 — Runtime CLI and Wrapper Parity

- **Transferred to Plan 97:** Verify PowerShell and POSIX wrappers share artifact fingerprint inputs,
      fail-closed stale/missing behavior, and `setup`/`run`/`switch` preparation.
- **Transferred to Plan 97:** Verify the POSIX artifact remains executable and background AOT relaunch
      omits its own path while JIT execution retains the script argument.
- **Transferred to Plan 97:** Verify content-addressed artifact reuse does not delete an executable path
      needed by an active POSIX launcher or overwrite a locked Windows artifact.
- **Transferred to Plan 97:** Verify `setup` preserves a functional foreign-checkout shim on every
      platform and `install --force` is the explicit ownership change.
- **Transferred to Plan 97:** Verify warm runtime commands invoke neither `fvm spawn` nor `fvm dart` on
      Windows, macOS, or Linux.

### G5 — Hosted Cross-Platform CI Gate

- **Transferred to Plan 97:** Run format/analyzer and the complete standalone package suite on current
      hosted Windows, macOS, and Linux images.
- **Transferred to Plan 97:** Add focused wrapper smoke for help, setup, stale failure, dry run, stopped
      status, and background child argument construction on each OS.
- **Transferred to Plan 97:** Keep fork-origin jobs secret-free and independent of signing/deployment.
- **Transferred to Plan 97:** Fail when any supported platform lane is skipped, cancelled, or missing
      expected test count/evidence.
- **Transferred to Plan 97:** Publish bounded per-platform timing summaries that distinguish bootstrap
      overhead from case execution.

### G6 — Documentation and Stable Baseline

- **Transferred to Plan 97:** Update test-performance and runtime-ownership QA docs with classifications,
      timeout ownership, and platform evidence.
- **Transferred to Plan 97:** Remove stale suppressions, duplicated fixtures, and contradictory comments.
- **Transferred to Plan 97:** Record the final green test count and timing range for each platform.
- **Transferred to Plan 97:** Establish a regression threshold for new slow cases without creating flaky
      wall-clock assertions on shared CI hosts.

## Acceptance Criteria

- **Transferred to Plan 97:** The complete `scripts/sanad_dev` suite passes on Windows, macOS, and Linux
      in two consecutive hosted runs.
- **Transferred to Plan 97:** No supported lane is skipped and no failure is hidden by weakening product
      assertions or broad timeout increases.
- **Transferred to Plan 97:** Path and ownership fixtures are deterministic on all three platforms.
- **Transferred to Plan 97:** Tests leave no process, port, launcher record, journal lock, or temporary
      runtime state behind.
- **Transferred to Plan 97:** POSIX wrapper/runtime behavior introduced by the Windows latency work is
      explicitly covered and green on macOS/Linux.
- **Transferred to Plan 97:** Test commands continue to use FVM and generated artifacts remain untracked.

## Verification Matrix

- Static: format, analyzer, size/cohesion guard, fixture/path audit.
- Unit: path normalization, fingerprinting, argument construction, ownership
  classification, and timeout-policy helpers.
- OS integration: PowerShell/POSIX wrappers, ACL/mode bits, atomic publication,
  process discovery, journals, and detached child behavior.
- Hosted: complete package suite on Windows, macOS, and Linux twice.
- Runtime smoke: isolated worktree dry run plus managed background Agent lifecycle
  where the hosted runner supports it without external services.

## Dependencies and Ordering

This task should normally execute before or alongside the secure runtime-file
performance task's G3/G4 verification because it provides a trustworthy
cross-platform baseline. It must not absorb the security backend implementation;
that change retains its own threat model and protected review.

## Rollback

Fixture and CI changes must remain separable from production behavior. If a
platform-specific test repair proves incorrect, revert that fixture or lane
change without reverting the runtime CLI latency improvement or weakening the
supported-platform contract.
