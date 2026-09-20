status: planned
priority: high
platforms: windows, macos, linux
depends_on: sanad-dev-windows-command-latency
---

# sanad-dev Cross-Platform Test Baseline Reliability

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

- [ ] Run the complete standalone package suite on Windows, macOS, and Linux and
      capture bounded failure lists plus total/case timing.
- [ ] Separate FVM/package startup from test-case execution.
- [ ] Classify every failure by product defect, platform-invalid fixture,
      timeout budget, resource contention, or leaked subprocess/port.
- [ ] Record the slowest ten cases per platform and identify shared fixtures.

### G1 — Platform-Neutral Fixtures

- [ ] Replace hard-coded `/users/...`, slash assumptions, drive assumptions,
      and case-sensitivity assumptions with explicit platform-neutral builders
      where the behavior under test is platform-neutral.
- [ ] Retain literal POSIX and Windows paths only in parser tests that explicitly
      declare the target syntax and do not consult the host filesystem.
- [ ] Normalize expected paths through the production-equivalent comparison
      boundary rather than ad hoc string replacement.
- [ ] Add fixture tests for spaces, Unicode, drive roots, UNC syntax where
      supported, POSIX roots, and case behavior.

### G2 — Ownership and Secure-File Test Isolation

- [ ] Give each test a unique temporary Home/runtime root and ensure teardown is
      bounded and observable.
- [ ] Distinguish mocked ownership-policy unit tests from real OS ACL/mode
      integration tests.
- [ ] Make expected owner/process identity fixtures host-independent while
      retaining negative PID-reuse and foreign-owner cases.
- [ ] Apply measured case timeouts only to real OS integration tests; never hide
      deadlock or unbounded polling with a suite-wide timeout increase.
- [ ] Keep security assertions unchanged while the separate secure-file task is
      pending.

### G3 — Journal, Subprocess, and Port Cleanup

- [ ] Track every spawned fixture process and prove it exits on success, failure,
      and timeout.
- [ ] Ensure component journals flush/close without relying on fixed sleeps.
- [ ] Reserve real ports deterministically and run only conflicting cases
      sequentially.
- [ ] Assert no test leaves a launcher record, startup locator, temporary file,
      child process, or listening port after teardown.
- [ ] Preserve exit codes and show only bounded diagnostic output in CI.

### G4 — Runtime CLI and Wrapper Parity

- [ ] Verify PowerShell and POSIX wrappers share artifact fingerprint inputs,
      fail-closed stale/missing behavior, and `setup`/`run`/`switch` preparation.
- [ ] Verify the POSIX artifact remains executable and background AOT relaunch
      omits its own path while JIT execution retains the script argument.
- [ ] Verify content-addressed artifact reuse does not delete an executable path
      needed by an active POSIX launcher or overwrite a locked Windows artifact.
- [ ] Verify `setup` preserves a functional foreign-checkout shim on every
      platform and `install --force` is the explicit ownership change.
- [ ] Verify warm runtime commands invoke neither `fvm spawn` nor `fvm dart` on
      Windows, macOS, or Linux.

### G5 — Hosted Cross-Platform CI Gate

- [ ] Run format/analyzer and the complete standalone package suite on current
      hosted Windows, macOS, and Linux images.
- [ ] Add focused wrapper smoke for help, setup, stale failure, dry run, stopped
      status, and background child argument construction on each OS.
- [ ] Keep fork-origin jobs secret-free and independent of signing/deployment.
- [ ] Fail when any supported platform lane is skipped, cancelled, or missing
      expected test count/evidence.
- [ ] Publish bounded per-platform timing summaries that distinguish bootstrap
      overhead from case execution.

### G6 — Documentation and Stable Baseline

- [ ] Update test-performance and runtime-ownership QA docs with classifications,
      timeout ownership, and platform evidence.
- [ ] Remove stale suppressions, duplicated fixtures, and contradictory comments.
- [ ] Record the final green test count and timing range for each platform.
- [ ] Establish a regression threshold for new slow cases without creating flaky
      wall-clock assertions on shared CI hosts.

## Acceptance Criteria

- [ ] The complete `scripts/sanad_dev` suite passes on Windows, macOS, and Linux
      in two consecutive hosted runs.
- [ ] No supported lane is skipped and no failure is hidden by weakening product
      assertions or broad timeout increases.
- [ ] Path and ownership fixtures are deterministic on all three platforms.
- [ ] Tests leave no process, port, launcher record, journal lock, or temporary
      runtime state behind.
- [ ] POSIX wrapper/runtime behavior introduced by the Windows latency work is
      explicitly covered and green on macOS/Linux.
- [ ] Test commands continue to use FVM and generated artifacts remain untracked.

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
