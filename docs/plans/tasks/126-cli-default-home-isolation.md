---
title: "Task 126: CLI Default Home Isolation"
description: "G0 incident fix: the CLI selects --home before any Home access, Home-owning stores refuse unisolated test opens and the real default Home, and the delegate supervisor hands workers their task Home through the environment."
status: "in_review"
current_gate: "Writer round 1"
priority: "critical"
depends_on: "Plan 83 (83c Agent secret vault)"
file_budget: 30
---

# Task 126: CLI Default Home Isolation

## 1. Incident

On 2026-10-21 a `sanad … --home <TestHome>` call from a Plan 83 checkout migrated the **default** Home: eight provider and five MCP secrets moved into the OS vault and `provider_secrets.json` and `mcp_secrets.json` were deleted from it.

Root cause in `agent/bin/sanad_agent.dart` `main()`: `SanadHomeBootstrap.prepareAll()`, `SecretVaults.open()` (which migrates and deletes the legacy files), the bundled-skill sync and `.env` seeding ran before any command parsed `--home`, so they resolved the Home from `SANAD_HOME`, else `$HOME/.sanad`. `--home` was applied only later by the command layer (`SanadCommand.sanadHome`, `StandaloneCliTurnClient.start`).

## 2. Triage

| Entry point | Before | After |
| --- | --- | --- |
| `bin/sanad_agent.dart` non-pure commands | Bootstrap, vault open/migration, skill sync, `.env` seeding on the inherited Home | `SanadCommandRunner.selectedHome` + `selectSanadHome` first; all Home access follows |
| Supervised daemon parent (`HotRestartManager.run`) | Ran after no selection; reads `Config` and `.local_token` from the inherited Home | Runs after selection; the child receives the same arguments and re-selects |
| `bin/daemon.dart` | Called with no `--home`; Home comes from the caller's selection or the environment | Unchanged: no ordering defect of its own |
| Standalone `run`/`chat` client | Second vault open after `setSanadHomeOverride` | Same Home as the entry already selected |
| Unparseable command line | Bootstrap + vault on the inherited Home, then usage error | Usage error only (exit `64`), no Home access |
| `--home X` with inherited `SANAD_STATE_HOME=Y` | Identity in `X`, `state.db` in `Y` | `--home` selects the complete Home; state resolves in `X` |
| Delegate supervisor | `--home <abs>` but inherited `SANAD_HOME`/`SANAD_STATE_HOME` | Child env gets `SANAD_HOME=<home>`, inherited `SANAD_STATE_HOME` removed |

Contradictions with current docs, reported first:

- `test/evolution/agent_state_database_isolation_test.dart` asserted that `AgentStateDatabase.atPath` needs no global override. This task deliberately reverses that: explicit paths now also require explicit test isolation. The test is updated, and 12 suites that passed temporary paths without declaring isolation now use `useIsolatedSanadStateRoot()`.
- `sanad run` without `--home` while the default daemon is down still runs standalone on the default Home and opens its `state.db` read-write. That is the documented default-Home contract, not a selection defect, and is left unchanged; the test guard prevents tests from reaching it.

## 3. Plan

1. One Home resolver: `SanadCommandRunner.selectedHome(arguments)` parses with the runner's own parser (innermost command `--home` wins over the top-level option) and normalizes with `normalizeSanadHomeOption`, which `SanadCommand.sanadHome`, `schedule` and `skills` also use. `selectSanadHome` sets both root overrides.
2. One test guard: `rejectUnisolatedTestHomeAccess` (`agent/lib/core/sanad_home/test_runtime_isolation.dart`) — `isDartTestRuntime() && !hasExplicitSanadStateIsolation()`, plus a canonical match against `defaultSanadHome()`. Used by every `AgentStateDatabase` on-disk open, `SecretVaults.open`/`openDetached`, and `createAgentSecretStore`.
3. Test secret-store seam: under the Dart test runner and with `SANAD_E2E_TEST_MODE=true` (the existing subprocess/daemon E2E switch), `createAgentSecretStore` returns the owner-only file store in the selected Home, so tests and E2E subprocesses never reach the Keychain, DPAPI or Secret Service.
4. Supervisor: `taskEnvironment` gives a worker with a task Home `SANAD_HOME=<home>` and drops inherited `SANAD_STATE_HOME`.
5. Docs: `docs/technical/sanad_cli_architecture.md` §3 and §8, vault section of `docs/technical/execution_trust_and_permission_authority.md`, `agent/AGENTS.md`, `agent/bin/AGENTS.md`, delegate-task-supervisor `SKILL.md`.

## 4. Definition of Done

- [x] (a) `agent/test/cli/cli_home_selection_isolation_test.dart`: the real CLI entry with `HOME=<tmpB>`, no `SANAD_HOME`/`SANAD_STATE_HOME`, `--home <tmpA>` (command option, top-level option, `=` form) leaves `<tmpB>/.sanad` with planted legacy secret files byte-for-byte untouched, no `state.db`; an unparseable command line touches neither Home.
- [x] (b) `agent/test/core/sanad_home/test_runtime_isolation_test.dart`: the guard refuses unisolated opens and the real default Home; isolated temporary Homes open.
- [x] Supervisor regression: the Home propagation test asserts the worker env.
- [x] Red and green logs under the coordinator's `temp/g0/` evidence folder.
- [x] `fvm dart analyze` (agent), `fvm flutter analyze` (client), full agent unit suite, `lint_wiki`.

## 5. Round Log

### Round 1 — writer

- Red baseline: `origin/main` plus only the new helpers and the test secret-store seam (no wiring). 7 of 13 new tests failed: `atPath` and both vault opens did not refuse; all four CLI subprocess cases lost `provider_secrets.json` from the default Home — the incident reproduced inside temporary roots.
- Green: all 13 new tests pass. The first full-suite pass after the guard failed 83 tests in 12 suites, every one the new `atPath` refusal; they are isolated with `useIsolatedSanadStateRoot()` (the concurrency suite's worker isolates select their own root).
- Supervisor: the extended Home propagation test fails on the old `supervisor.mjs` (worker saw the caller's `SANAD_HOME`) and passes after the fix. Its macOS `/var` → `/private/var` canonicalization failure is fixed for that test; three other supervisor tests keep the same pre-existing macOS failure on `origin/main`.
- The full suite excludes only the two explicit macOS Keychain round-trip tests in `agent/test/core/agent_secret_store_test.dart`, because this round must not touch the real Keychain.
