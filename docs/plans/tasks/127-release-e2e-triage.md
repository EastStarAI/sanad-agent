---
title: "Task 127 - Release E2E Triage"
description: "Triage and fix the six agent E2E tests that fail on main before the release."
---

# Task 127 - Release E2E Triage

Branch `fix/release-e2e-triage`, based on `main` `182d6a40`.

Scope: `agent/e2e_test/` fixtures, one E2E isolation guard, and documentation.
No product behavior change was required. Every failure classified as either a
stale fixture written against a superseded contract or a test-isolation defect
against a contract that was already documented on `main`.

## Failure Classification

| Test | Cause class | Evidence | Fix commit |
|---|---|---|---|
| `agent/e2e_test/local_tool_permissions_e2e_test.dart`: *local daemon requests permission before executing a sensitive platform tool* | Stale test; contract unchanged | The case read a device id from the welcome frame and cast it to `String`. That frame is `type` + `platform_id` + `url` only (`docs/technical/sanad_cli_architecture.md` §4.1, `LocalDaemonServerPlatform._acceptClient`), and the Client ignores the welcome identity entirely. The cast threw `type 'Null' is not a subtype of type 'String'` before the permission path was exercised. | `05b5c501` |
| `agent/e2e_test/local_tool_permissions_e2e_test.dart`: *parallel external file reads present permission requests one at a time* | Stale test; same fixture defect | Same cast at the second case's setup; no product behavior was involved. | `05b5c501` |
| `agent/e2e_test/remote_device_control_e2e_test.dart`: *device.runtime.restart reconnects and keeps workspace plus MCP mutations* | Test isolation defect against a documented contract (`#249`, Task 126) | The suite stores an MCP bearer token. Its daemon ran without `SANAD_E2E_TEST_MODE`, so `createAgentSecretStore()` selected the macOS Keychain and `save_mcp_server` returned `AgentSecretStoreUnavailable: macOS Keychain write (add) failed (-60008)`. `agent/AGENTS.md` requires E2E subprocesses to never reach the OS credential vault through the default secret store; `#249` made E2E mode select the owner-only file store inside the temporary Home. | `ad02ed76` |
| `agent/e2e_test/thinking_mode_gate_i_e2e_test.dart`: *I.2 unsupported explicit selection skips provider HTTP call* | Stale test after an intended contract change (`#229`; `agent/lib/core/AGENTS.md`) | The fixture fabricated `status: unsupported` as a `profile` record inside the seeded model cache. Since `#229`, capability authority is the five documented layers, `unsupported` comes only from a positive authority report, and the profile policy reports absence of evidence as `unknown`. The rebuilt descriptor no longer matched the fabricated cache revision, the route resolved `unknown`, and the explicit selection was admitted with the provider default: one provider HTTP call instead of zero. | `d5c11d06` |
| ... *I.3 model switch revalidates stale thinking selection via daemon* | Stale test; same fixture cause | The same `unknown` resolution meant the route-scoped correction never fired, so persisted `high` survived the switch to the unsupported model (`Expected: null, Actual: 'high'`). | `d5c11d06` |
| ... *I.4 daemon restart revalidates persisted thinking on restore* | Stale fixture cause plus an unreliable observation point | The fixture had the same fabricated evidence, and the case also waited for a live `final_answer`. Startup recovery drains the restored queued turn as soon as the gateway is up, so the answer was published ~60 ms before the test client attached and the wait timed out. | `d5c11d06` |

## Security Note for Item 1

There is no product regression. With the fixture corrected, the daemon:

1. emits `tool_permission_request` for `system_screenshot` before any dispatch;
2. dispatches nothing before the decision (new probe assertion:
   `deviceEventCount(sessionId, 'platform_tool_call') == 0`);
3. emits `platform_tool_call` only after the allow response;
4. returns `SCREEN_OK` after the tool result.

`PermissionManager` and its policy path were never bypassed, so the security
invariant held on `main`; only the fixture was unable to observe it.

## Round Log

### Round 1 - reproduce on `main`

Baseline: `e2e-main-baseline-r2.log` (release gate run) reported six failures in
the three files listed above. Each failure was reproduced in isolation with a
temporary `HOME`, `SANAD_HOME`, and `SANAD_STATE_HOME` before any edit; all six
reproduced with identical errors.

### Round 2 - fixes, red before green

1. `05b5c501` - permissions fixtures. The welcome frame carries no device
   identity, so the cases now use a test-owned device id on their canonical
   envelopes. The first case now runs through the existing frame probe, which
   also makes "no platform call before the decision" explicit. The unused
   `StreamIterator` helper was removed.
2. `ad02ed76` - remote device control. Added `SANAD_E2E_TEST_MODE=true` to the
   spawned daemon environment so the credential write stays on the owner-only
   file store inside the temporary Home. Both temporary roots were already
   declared, as the E2E isolation rule requires.
3. `d5c11d06` - Gate I fixtures. `unsupported` evidence now comes from the
   shipped-defaults layer (`agent/model_capability_defaults.yaml`, route class
   `any`, documented unsupported controls) instead of a fabricated cache
   record. I.2 asserts the typed pre-dispatch rejection
   (`final_answer.error_code == thinking_capability_unsupported`) with zero
   provider HTTP calls instead of a blocked runtime notice. I.4 observes the
   restored turn through `get_session_history`, which is the durable outcome a
   late-attaching client actually receives.
4. Guard: `test/guards/e2e_state_isolation_contract_test.dart` now fails when an
   E2E suite that writes a credential (`'secrets':`, `save_mcp_server`) does not
   declare `SANAD_E2E_TEST_MODE`. The pre-fix remote device control file
   contained zero occurrences, so the guard would have caught the defect.
5. Follow-up `test(agent): bound the restored-turn history poll` - the I.4 poll
   now stops at its deadline instead of issuing one request with a non-positive
   remaining budget, so an exhausted wait reports "not found" instead of a
   transport timeout.

Contract documents were already correct and were therefore not rewritten:

- `docs/technical/sanad_cli_architecture.md` §4.1 already specifies the
  `platform_id` + `url` welcome frame.
- `agent/AGENTS.md` already forbids E2E subprocesses from reaching the OS
  credential vault.
- `agent/lib/core/AGENTS.md` already states that `unknown` admits the turn with
  the provider default and that `unsupported` comes only from a positive report.

Regression knowledge from this triage was recorded in
`docs/qa_maintenance/local_gateway_and_sanad_home_security_qa.md` (E2E
credential-store isolation and welcome-frame identity) and
`docs/qa_maintenance/provider_aware_thinking_mode_qa.md` (Gate I fixture
evidence source and restore observation).

### Round 3 - gates at final HEAD

| Gate | Command | Result |
|---|---|---|
| Analyzer | `fvm dart analyze` in `agent/` | Clean |
| Affected E2E | `fvm dart test e2e_test/local_tool_permissions_e2e_test.dart e2e_test/remote_device_control_e2e_test.dart e2e_test/thinking_mode_gate_i_e2e_test.dart --concurrency=1` in `agent/` | 7/7 passed |
| E2E isolation guard | `fvm dart test test/guards/e2e_state_isolation_contract_test.dart` in `agent/` | 4/4 passed |
| Full unit suite | `fvm dart test test` in `agent/` | 3399 passed, 9 skipped, 0 failed, plus `test/core/agent_secret_store_test.dart` 12 passed / 6 skipped |

Verification environment notes:

- Every reproduction and E2E run used a fresh temporary `HOME`, `SANAD_HOME`, and
  `SANAD_STATE_HOME`. The real Sanad Home was never opened.
- `fvm` itself hangs once `HOME` is redirected, so the same FVM-managed SDK was
  invoked through its resolved binary (`versions/3.47.0/bin/dart`) with
  `PUB_CACHE` pointing at the existing cache. SDK version consistency is
  unchanged.
- The full unit suite is split for one environment reason: `HOME` must stay the
  real user Home for `test/core/agent_secret_store_test.dart`, whose macOS
  Keychain implementation resolves the login keychain through `$HOME`. Under a
  redirected `HOME` those two cases fail with Keychain `-60008`, which is an
  OS-session property, not a product result. The rest of the suite is run with a
  redirected `HOME`; the Sanad Home stays untouched because those suites
  isolate themselves and the shared guard refuses the real default Home.

## Open risks

- `test/core/agent_secret_store_test.dart` still needs the real macOS login
  keychain, so it fails in a non-interactive or locked-keychain session. It is
  outside this task's six failures; making it vault-independent is a coverage
  decision for a follow-up.
- `agent/e2e_test/local_tool_permissions_e2e_test.dart` still picks its gateway
  port from a fixed band (`58820`-`59019`). `--concurrency=1` makes it safe
  today, but it does not follow the "bind a freshly reserved ephemeral port"
  rule for loopback harnesses.
- The Gate I fixtures now depend on a shipped-defaults model id. If that record
  is ever removed from `agent/model_capability_defaults.yaml`, I.2-I.4 fail
  loudly rather than silently degrading to an `unknown` route.
- Startup recovery can still complete a restored turn before any client
  attaches. That is correct product behavior; future durable-recovery tests must
  assert hydration rather than a live event.
