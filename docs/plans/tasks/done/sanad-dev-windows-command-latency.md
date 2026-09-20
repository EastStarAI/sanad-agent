---
status: complete
current_gate: done
---

# sanad-dev Windows Command Latency

## Goal

Reduce repeated `sanad-dev` runtime-command latency on Windows while preserving FVM-pinned setup, worktree routing, runtime ownership validation, and fail-closed prerequisite handling.

## Locked Decisions and Scope

- Keep FVM as the only tool used to install Flutter, resolve packages, and compile Dart source.
- Build a checkout-local native `sanad-dev` runtime executable during `setup`; runtime commands execute that prepared artifact without repeating FVM SDK discovery.
- `run` and `switch` continue to prepare stale prerequisites before entering the runtime CLI; other runtime commands remain non-mutating with respect to bootstrap and fail with an exact `sanad-dev setup` recovery instruction when the artifact is missing or stale.
- Preserve caller-worktree redispatch, unified Home selection, launcher ownership checks, and existing runtime command semantics.
- Optimize repeated runtime discovery only when focused measurements show material remaining latency after the bootstrap fix.
- Do not switch the active primary runtime to this worktree.

## Evidence Baseline

- Windows `sanad-dev status`: approximately 59.2 seconds.
- `fvm spawn 3.47.0 --version`: approximately 20.8 seconds.
- `fvm dart --version`: 17–26 seconds, while the same pinned SDK's `dart.exe --version` starts in approximately 0.06 seconds.
- Runtime-internal discovery: approximately 7–9 seconds, led by the 101-port Agent scan at approximately 4.5–4.9 seconds.

## Gates

### G0 — Discovery

- [x] Measure wrapper, FVM, Dart, process discovery, Agent discovery, and ownership stages independently on Windows.
- [x] Identify repeated FVM SDK resolution and repeated runtime discovery in source.

### G1 — Prepared Runtime CLI

- [x] Add deterministic runtime-source fingerprinting and checkout-local native artifact preparation to both platform wrappers.
- [x] Make runtime commands use the prepared artifact while keeping setup and run preparation semantics intact.
- [x] Add bootstrap regression coverage for artifact creation, staleness, content-addressed artifact reuse, foreign-shim-safe worktree setup, and non-mutating runtime-command failure.
- [x] Make native AOT background relaunch omit the script argument while preserving the script argument for JIT execution.

### G2 — Focused Discovery Optimization

- [x] Re-measure `sanad-dev status` from this worktree after G1.
- [x] Reuse one runtime context and run Agent/Client discovery concurrently without weakening full-range discovery or ambiguity detection.
- [x] Preserve existing selection logic and run focused discovery coverage.

### G3 — Documentation and Verification

- [x] Update the owning runtime contract, developer guide, technical design, and QA matrix.
- [x] Run the standalone package analyzer and focused tests with bounded output; attempt the full suite and record unrelated Windows-only baseline failures.
- [x] Run preparation and repeated `sanad-dev status` commands from this worktree, record timings, and verify the primary runtime remains unaffected.
- [x] Start the worktree Agent through the native AOT `--background` path, verify its managed lease, gateway, bounded journal, and status, then stop it through `sanad-dev stop agent`.
- [x] Confirm Graphify is unavailable in this checkout, so no graph update is required.

## Acceptance Criteria

- [x] Given a prepared unchanged checkout, a Windows runtime command does not invoke `fvm spawn`, `fvm dart`, or dependency setup before entering the CLI.
- [x] Given missing or stale runtime artifacts, `status` fails without bootstrap mutation and directs the user to `sanad-dev setup`.
- [x] Given `run` or `switch` with stale runtime source, setup rebuilds the native CLI before runtime entry.
- [x] Caller-worktree redispatch executes the artifact owned by that worktree.
- [x] Measured warm stopped-runtime `sanad-dev status` latency on this Windows host is 3.41–3.65 seconds versus the 59.2-second baseline under normal system load; a managed Agent-only status completed its internal work in 11.75 seconds. Concurrent CIM-heavy diagnostics can temporarily raise either result and are not representative of serial CLI use.
- [x] A fingerprint-matched cached executable is reused after stamp rollback, avoiding overwrite of a still-running Windows artifact.
- [x] Runtime ownership status remains managed for the primary runtime, and worktree-local checks do not mutate or stop it.

## Definition of Done

- [x] Relevant contracts and design/operations/QA documentation are current.
- [x] `scripts/sanad_dev` analysis and task-focused tests pass; the full Windows suite was attempted and exposed unrelated pre-existing path-fixture and secure-file failures.
- [x] Windows startup/secure-file tests require a raised test timeout on this host: one FVM test invocation adds about 22 seconds before test execution and one secure atomic write takes about 9 seconds because owner-only ACL and atomic replacement use multiple PowerShell child processes. No security semantics were weakened in this latency change.
- [x] Wrapper bootstrap tests pass on Windows.
- [x] Live worktree command timings and behavior are verified.
- [x] The final diff contains no generated native executable, package cache, credentials, or machine-specific path.
