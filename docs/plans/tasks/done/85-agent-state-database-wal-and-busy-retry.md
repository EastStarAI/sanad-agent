## Goal

Enable resilient multi-process and multi-instance concurrency on `AgentStateDatabase` (`state.db`) using SQLite Write-Ahead Logging (WAL), an explicit busy timeout, and a bounded 3-attempt backoff retry loop with structured logging before failing on database lock contention.

## Current Status

- Current gate: complete through G4 Task 65 integration.
- Remaining work: 0%.

## Locked Decisions and Scope

- `AgentStateDatabase` enables `PRAGMA journal_mode = WAL;` and `PRAGMA busy_timeout = 5000;` on connection initialization (`_init`).
- Write operations, transactions, and schema setup intercept `SqliteException` with busy/locked error codes (`SQLITE_BUSY` [5] or `SQLITE_LOCKED` [6]).
- When busy/locked, retry up to 3 attempts with progressive backoff (e.g. 50ms, 100ms, 200ms) and emit a clear structured warning log for each retry attempt before waiting and retrying.
- If all 3 attempts fail, rethrow the original `SqliteException`.
- Database sidecar files (`state.db-wal`, `state.db-shm`) are secured with owner-only permissions via existing `SanadHomeBootstrap.secureDatabaseFilesSync`.
- Concurrency behavior and retry resiliency must be proven via unit tests and an isolated real on-disk E2E/concurrency test running multiple simultaneous transactions across separate database handles without data corruption or premature lock failures.

## Gates

### G0 — Discovery & Design
- [x] Verify `AgentStateDatabase` initialization, connection lifecycles, and transaction savepoints.
- [x] Identify all direct write paths (`transaction`, `_init`, migrations) susceptible to `SQLITE_BUSY`/`SQLITE_LOCKED`.
- [x] Design the bounded 3-attempt retry loop, backoff schedule, and structured logging format.

### G1 — Implementation
- [x] Configure `PRAGMA journal_mode = WAL;` and `PRAGMA busy_timeout = 5000;` in `AgentStateDatabase._init`.
- [x] Implement `_retryOnBusy<T>()` / retry wrapper in `AgentStateDatabase` with 3 attempts, backoff delay, and warning logs.
- [x] Wrap `transaction<T>()` and schema migration execution with retry logic.
- [x] Verify sidecar permission boundaries for WAL and SHM files in `SanadHomeBootstrap`.

### G2 — Verification & Testing
- [x] Write `agent/test/evolution/agent_state_database_retry_test.dart` (Unit test verifying 3 retries, logging output, and rethrow on exhaustion).
- [x] Write `agent/test/evolution/agent_state_database_concurrency_test.dart` (E2E concurrency test verifying simultaneous multi-connection writes on an isolated on-disk database).
- [x] Run `fvm dart analyze` in `agent/` with clean exit status.
- [x] Run the complete test suite in `agent/` ensuring all tests pass.
- [x] Run `graphify update .` and update documentation/contracts.

### G3 — Review & Repair
- [x] Replace production backoff waits in unit tests with an injected deterministic wait seam and assert the exact 50/100/200ms schedule.
- [x] Make concurrency-worker initialization and transaction failures surface immediately instead of hanging until the suite timeout.
- [x] Close the owned SQLite handle when on-disk initialization fails while still securing any created database sidecars.
- [x] Re-run focused retry/concurrency/security coverage, the analyzer, and the complete Agent test suite.

### G4 — Task 65 Integration
- [x] Fast-forward the worktree to the `main` revision containing Task 65 and preserve its maintenance schema, page statistics, and transaction guard.
- [x] Resolve the shared schema/contract documentation by combining maintenance and WAL/retry behavior.
- [x] Apply the shared busy-retry policy to Task 65's database-wide `VACUUM` primitive while preserving its outside-transaction guard.
- [x] Run Task 65 maintenance tests together with Task 85 retry/concurrency tests.
- [x] Run the Agent analyzer and complete test suite on the integrated tree.
- [x] Refresh Graphify and close the task at 0% remaining.

## Acceptance Criteria
- [x] `AgentStateDatabase` runs in WAL mode with a 5000ms busy timeout.
- [x] Concurrent lock contention triggers up to 3 retries with warning logs logged on each attempt.
- [x] Exhausted retries rethrow the underlying `SqliteException`.
- [x] Simultaneous write transactions across multiple handles on the same isolated database file resolve successfully without lock errors.
- [x] Automated Unit and E2E concurrency tests pass deterministically.

## Definition of Done
- [x] All code changes in `agent/lib/evolution/db/agent_state_database.dart` adhere to repository DRY principles.
- [x] Contracts in `agent/lib/evolution/db/AGENTS.md` and `docs/` reflect the WAL mode and retry policy.
- [x] Unit and E2E tests pass with bounded output.
- [x] `fvm dart analyze` in `agent/` passes with zero diagnostics.
