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
  boundary itself is the contract.

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
