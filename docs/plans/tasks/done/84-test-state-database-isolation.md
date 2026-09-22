## Goal

Prevent Dart tests from opening the user's live Sanad state database when a test forgets to select an isolated state owner.

## Locked Decisions and Scope

- The default on-disk `AgentStateDatabase()` constructor fails closed under the Dart test runner unless the test explicitly selects an isolated home/state-home override.
- Tests may continue to use `AgentStateDatabase.inMemory()` or `AgentStateDatabase.atPath(...)` without an override.
- SQLite lock waiting is not a substitute for test isolation.
- The Task 51/52 implementation remains intact; this repair only hardens its test boundary and fixes the missing durable-message mock stub.

## Gates

### G0 — Discovery

- [x] Correlate the daemon crash with concurrent `dart test` processes holding the live `state.db`.
- [x] Identify the interface test that constructs `SessionManager` without isolated state.
- [x] Trace the Task 51/52 test hang to an unstubbed durable-message lookup.

### G1 — Isolation and Test Repair

- [x] Reject unisolated default state-database opens under `dart test` before filesystem access.
- [x] Make the permission-resume interface test inject an in-memory state database.
- [x] Stub durable-message reads in the shared orchestrator test fixture.

### G2 — Verification

- [x] Run focused isolation and interface regression tests.
- [x] Run the agent analyzer and full fast agent suite with bounded output.
- [x] Confirm the test runner does not open the user's `state.db`.
- [x] Update Graphify and review the final diff.

## Acceptance Criteria

- [x] An unisolated `AgentStateDatabase()` call under `dart test` fails before filesystem access.
- [x] Explicit temporary, in-memory, and explicit-path databases remain supported.
- [x] The stop-cleanup regression starts its stream and completes without timeout.
- [x] The complete agent test suite holds no descriptor for the user's live database.

## Definition of Done

- [x] The nearest database/core contracts and Sanad Home protection design describe fail-closed test isolation.
- [x] Focused tests, full fast agent tests, and `fvm dart analyze` pass.
- [x] `graphify update .` completes after code changes.
