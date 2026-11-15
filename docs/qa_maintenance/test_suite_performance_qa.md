---
title: "Test Suite Performance and Ownership QA"
description: "Package boundaries, deterministic timer/event testing, hotspot thresholds, and subprocess/port integration classification for Agent, Client, and `sanad-dev` suites."
---

# Test Suite Performance and Ownership QA

## Purpose

This matrix prevents fast Agent and Client tests from silently accumulating
production timers, request timeouts, external resources, or tests owned by a
different package.

## Package ownership

| Surface | Owned coverage | Excluded coverage |
|---|---|---|
| Agent | daemon policy, persistence, capabilities, transports, and runtime behavior | Flutter widgets and developer-tool implementation |
| Client | Flutter state, widgets, repositories, and transport projections | Pure-Dart `sanad-dev` implementation |
| `sanad-dev` | CLI parsing, bootstrap, process discovery, ownership, journals, and runtime control | Client widget behavior |
| Shared endpoints | canonical non-secret environment-to-service mapping | Client or CLI orchestration |

The `sanad-dev` package must load, analyze, and run without Flutter dependencies.
Its platform wrappers and historical compatibility entry must both reach the
same package-owned CLI. A worktree smoke verifies help, stopped-runtime status,
and dry-run discovery without starting a runtime or changing source ownership.

## Deterministic timing matrix

- Request-failure tests explicitly fail or replace their fake transport; they do
  not wait for the production request timeout.
- Retry-policy tests bypass production backoff through a deterministic test
  service while dedicated recovery tests retain timer/cancellation coverage.
- Device-code tests inject the poll waiter; production keeps its minimum poll
  interval unchanged.
- Local reconnect tests inject only the delay policy and still observe the real
  `connecting` then `error` lifecycle transition.
- Scheduler tests separate registration from timer delivery. Registration is
  asserted from scheduled state; delivery awaits the exact event rather than a
  padded sleep.
- Asynchronous routing tests yield to the event queue only as required; fixed
  settling sleeps are prohibited.
- Wrapper, subprocess, filesystem-permission, and loopback-port tests remain
  narrow integration coverage. They are not converted into mocks when the OS
  boundary itself is the contract. A loopback harness cannot keep its
  reservation once the probe socket closes, so it binds each attempt on a
  freshly reserved ephemeral port and re-reserves on an address-in-use
  collision (`agent/test/support/ephemeral_loopback_port.dart`); a released
  probe port is never treated as owned, and a fixed port is never acceptable.

## Slow-runner timing contracts

Release-workflow runners (macOS Intel, `windows-2025`) are much slower than a
developer machine, so OS-boundary tests declare explicit budgets instead of
relying on the default 30-second test timeout:

- A guard that must spawn the real CLI entrypoint compiles the Agent once per
  file (`dart compile kernel` into a temporary directory) and runs that artifact
  for every case, so one file pays one compilation instead of one per test.
  Compilation is awaited inside the first case because `setUpAll` inherits the
  default test timeout and cannot declare a generous one; each case declares a
  test timeout above the compile plus invocation budget.
- Waits on a process the test does not own are deadline-based, exit as soon as
  the observable contract appears, and set the surrounding test timeout above
  the deadline. Sampling that boundary on an interval is not a settling sleep
  and never retries the producer: the Windows detached PowerShell replacement
  handshake observes its result file for up to 60 seconds, and the daemon-backed
  readiness case observes `Daemon is running` for up to 120 seconds.
- A larger budget changes no assertion: exceeding a deadline still fails the
  case on its original expectations.

### Native dictation lane additions

`Native dictation` also runs `test/stt/stt_digest_test.dart` and
`test/stt/stt_download_pipeline_test.dart`, because those two files own the
operating-system half of the download path: the digest selects a per-OS SHA-256
(CommonCrypto on macOS, OpenSSL EVP on Linux, BCrypt on Windows) and the write
pipeline opens a second file handle for writeback. Running them on one Linux
shard proves neither.

Measured on macOS arm64 (M-series), warm, `SANAD_STT_REQUIRE_NATIVE=1`, one file
per `dart test` process and then the two together with `--concurrency 1`:

| Invocation | Wall time | Reported case time |
| --- | --- | --- |
| `test/stt/stt_digest_test.dart` | 1.0 s | < 1 s |
| `test/stt/stt_download_pipeline_test.dart` | 2.5–2.6 s | ~1 s |
| both, `--concurrency 1` | 3.6–3.9 s | ~1 s |
| `test/stt/stt_digest_cost_test.dart` | 6.4 s | 3.0 s |
| `test/stt/stt_pipeline_cost_test.dart` | 1.3 s | ~0.3 s |

The digest file lost 0.8–0.9 s when its ratio case moved out: that case hashed
64 MiB three times inside the suite, and the cost gate below does the same work
once, alone.

The wall time is `dart test` bootstrap plus compilation; the correctness cases\nthemselves are about a second. Estimated per lane for the two correctness files,\nusing the measured 2.4–3.0× per-unit factor of `macos-15-intel` against arm64 and\nallowing for JIT/process overhead on Windows:

| Lane | Estimated added wall |
| --- | --- |
| `ubuntu-24.04`, `ubuntu-24.04-arm` | 4–5 s |
| `macos-26` | 4 s (measured) |
| `macos-15-intel` | 9–11 s |
| `windows-2025` | 6–8 s |

About 27–32 seconds of runner time across the five lanes, in exchange for proving
the shipped OS crypto backend and the real write pipeline on every operating
system the Agent is published for.

**Each ratio owns a process.** Two cost gates run beside those suites, and neither
may share a process with anything else: `test/stt/stt_digest_cost_test.dart`
(native SHA-256 against pure Dart, median at 2.5×) and
`test/stt/stt_pipeline_cost_test.dart` (the isolate hop against the same sink
in-process, median at 0.5, so the isolate may cost up to twice the in-process
sink). Both warm both arms, run five alternating paired trials, assert the same
output on every trial, and judge the median. Run beside another suite — or always
in the same order — one arm is charged for the other's contention: the pipeline
ratio measured 2.18× and failed once in four attempts on an idle machine, and the
digest ratio measured 2.14 on `macos-15-intel` while the native backend was
selected and correct. The correctness pair still passes `--concurrency 1`, which
no longer protects an assertion there. A failure in either gate is a real cost
regression, and neither bound is lowered, skipped, or retried to meet a lane.

## Performance regression gates

For a changed hotspot, compare like-for-like warm runs. It passes when median
execution improves by at least 30 percent or falls below 250 milliseconds while
retaining its assertions. Full-suite comparisons distinguish package load and
compilation from case execution. E2E or tests sharing exclusive ports may run
sequentially; ordinary unit and widget suites retain default parallelism.

A regression fails this matrix when a fast test introduces a fixed wait of 100
milliseconds or more without a documented timing contract, relies on an
external network/provider, leaves a process or port active, or moves
package-owned coverage back under another product's test tree.

## Windows Fast-Suite Isolation and Root-Cause Remediation

To ensure the Agent fast suite runs reliably in parallel on Windows without resorting to global `--concurrency=1` or masking legitimate failures, all tests and platform infrastructure must adhere to the following isolation rules:

1. **Mandatory Byte-Range Locks (`OS Error: errno = 33 / 32`):**
   - On Windows, `RandomAccessFile.lock(FileLock.exclusive)` enforces strict mandatory locking. Concurrent calls to `readAsBytesSync()` on locked credential or state files fail with `errno = 33` (`ERROR_LOCK_VIOLATION`). The runtime avoids reading lock file bytes concurrently while holding an exclusive handle, and retries transient lock collisions.
   - Teardown operations deleting temporary directories must guard against transient locks held by pending async file close operations, SQLite checkpointing, or background Windows indexing (`errno = 32`).

2. **Cross-Platform Path Separators & Normalization:**
   - Tests asserting path prefixes, directory listings, or JSON outputs must never hardcode POSIX `/` separators when evaluating filesystem paths on Windows. Use `p.join` or normalize paths before string matching.

3. **Line Ending Elasticity (CRLF vs LF):**
   - String indexing and regular expression matches on source files or release manifests must be CRLF-aware (`\r?\n`), preventing git checkout line-ending transformations from failing index lookups.

4. **Fixture & Mock Completeness:**
   - Interface additions (such as `SessionManager.getSessionRecord`) must be explicitly stubbed on mocks in test suites consuming those interfaces to avoid `MissingStubError` breaking turn orchestration.

5. **Windows Subprocess Startup & Signal Boundaries:**
   - Standalone CLI child processes on Windows experience JIT startup and PowerShell security bootstrap overhead. Fast-pathing bundled skills state via `.sanad-managed.json` eliminates repetitive PowerShell ACL calls.
   - Because Dart on Windows maps `Process.kill` to `TerminateProcess` (yielding `-1`) rather than delivering catchable POSIX `SIGINT`/`SIGTERM` traps, tests asserting POSIX signal exit codes (130/143) must guard real OS signal execution to non-Windows platforms while preserving stream-based signal unit tests on all platforms.

6. **Platform-Neutral Path and Wrapper Parity:**
   - Synthetic CLI test fixtures use platform-neutral path helpers rather than assuming hardcoded POSIX `/` or `/users/...` paths. Runtime identity comparisons use `equivalentPaths`, which performs a filesystem-free lexical check first, honors host case/separator semantics, strips real Windows `\\?\` and `\\?\UNC\` prefixes, rejects distinct roots without probing them, and resolves symlinks only as a fallback.
   - Platform bootstrap wrappers (`sanad-dev` and `sanad-dev.ps1`) maintain parity across package setup, lockfile integrity verification, checkout collision rejection, foreign checkout shim preservation, and content-addressed executable reuse. Windows locked-artifact coverage must hold a real exclusive handle and release it in `finally`; an unlocked stale-file deletion is not equivalent evidence.
   - Wrapper fixtures must not persist test directories into the host user PATH. Tests may suppress the PATH-persistence call only in their copied wrapper while continuing to verify the tracked wrapper contains the real user-scoped installation behavior. Recursive fixture teardown is strict: lock/process leakage fails the test rather than being swallowed.
