---
id: 134
title: CLI session stop parity with the Client UI stop (release blocker)
status: in_review
gate: coordinator review open
created: 2026-10-22
parent_task: none (release blocker for delegation)
depends_on: []
delivery: own PR
---

# Task 134 — CLI `session stop` parity with the Client UI Stop

## Goal

Make `sanad session stop <session-id>` take the same path and reach the same
authoritative end state as the Sanad Client's Stop button, and make
`session show` stop reporting a stopped session as `running`.

Live evidence (main runtime, 2026-10-22), a turn wedged by a provider
`invalid_request` that kept `in_flight = {type: thought_stream, status: running,
run_id: run_1792632757780140_1}` with a frozen `updated_at`:

1. `sanad session stop <id>` printed “stopped” once while `session show` stayed `running`.
2. A second `sanad session stop` failed with `CliClientException(stop_timeout)`.
3. The Client UI Stop stopped the same session at once.
4. After that, CLI `session show` still reported `running` with the same frozen `updated_at`.
5. RD11: after a CLI stop the Client UI showed the session in an ERROR (blocked) state instead of stopped.

Dashboard:

| # | Severity | Defect | Status |
|---|---|---|---|
| RD9 | High | CLI stop reports success before the daemon is idle; an already-stopped session returns `stop_timeout` | fixed |
| RD9b | High | Daemon never releases the in-memory `in_flight` projection on stop, so `session show` reports `running` forever | fixed |
| RD9c | High | CLI stop names no `run_id` even though the session projection carries the in-flight owner | fixed |
| RD11 | High | A stop leaves the durable blocked notice / `awaiting_permission` checkpoint behind, so the UI renders an ERROR state after the CLI stop | fixed |

## Owner map

| Concern | Owner |
|---|---|
| Dispatch and confirmation of the CLI stop | `agent/lib/cli/client/local_gateway_cli_client.dart` (`stop`, `_readSessionRuntimeState`) |
| Run-identity resolution and user output | `agent/lib/cli/runner/commands/session_command.dart` (`SessionStopCommand`) |
| REPL `/stop` reporting | `agent/lib/cli/repl/slash_command_handler.dart` (`_handleStop`) |
| Session status derivation | `agent/lib/cli/runner/commands/session_command.dart` (`SessionShowCommand`) |
| Authoritative stop semantics | `agent/lib/interfaces/runtime/session_stop_coordinator.dart` |
| Blocked-recovery release | `agent/lib/interfaces/runtime/session_turn_executor.dart` |
| Stop run identity transport | `agent/lib/interfaces/runtime/session_run_orchestrator.dart` (`requestStop(stopRunId:)`) |
| Durable checkpoint cleanup | `agent/lib/evolution/db/suspended_checkpoint_repository.dart` + `persisted_runtime_state_repository.dart` |

## Root cause

### 1. The daemon does not branch on transport — the CLI stop is the same stop

`LocalDaemonServerPlatform` translates `execute_command` with `command: 'stop'`
through `SanadProtocolBridge.translateCommand` → `CanonicalToAgentTranslator`
(`type: 'stop'`, `runId` from `payload.run_id`) → `SessionRunOrchestrator.handleEvent`,
which calls the session-scoped `requestStop`. The Client UI sends
`{request_id, session_id, recovery_owner_token}`; the CLI sends
`{session_id, run_id?, request_id}`; `recovery_owner_token` only enables
`captureStopRecovery` (draft/queued recovery for the UI), and `device_id` only
affects response routing. No daemon branch, authority check, or run-id gate
distinguishes the two transports. The observable difference came from the two
defects below, not from the daemon ignoring the command.

### 2. The in-flight projection is never released (RD9b, RD9-4, RD11)

`SessionManager.saveInFlightSnapshot` writes the partial-stream projection that
`get_session_history` returns as `in_flight` and that `session show` turns into
`status: running`. It was cleared on terminal commit, error, tool start, and
steer boundaries — but **not** by a stop, and **not** when a run entered a
blocked/waiting recovery (`RuntimeRecoveryRequired`). A stopped or
blocked session therefore kept reporting `running` with the last chunk's
timestamp for the life of the daemon process; nothing could ever correct it.

### 3. Stop left durable intervention state behind (RD11)

`SessionStopCoordinator` removed `_suspendedEvents` (memory) and cancelled work
items but never deleted `suspended_checkpoints` rows. A session parked on a
permission prompt kept `pending_permission_request`, so the history projection
kept reporting `needs_permission`, and a persisted `blocked` notice could be
re-served to the Client as an attention/ERROR state.

### 4. The CLI confirmation was not authoritative (RD9)

`LocalGatewayCliClient.stop()`:

- sampled `get_session_history` **once**, immediately after dispatching `stop`,
  and returned success when that sample looked idle — before the daemon had
  applied the stop. That is the “printed stopped while the session stayed
  running” report;
- otherwise required a fresh `CliTurnCancelledEvent`. The daemon emits
  `stopped` only when the stop had work to release (`hadWork`), so a second
  stop on an already-cancelled session waited the full request timeout and
  failed with `stop_timeout`;
- sent no `run_id`, so the acknowledgement could not name the execution the
  operator observed.

### 5. `session show` trusted the projection alone (RD9-4)

`SessionShowCommand` derived `running` from `in_flight` presence only. Even
with a truthful durable `execution_snapshot` (`idle`), a leftover snapshot kept
the session `running` in every machine-readable inspection.

## Fix

1. `SessionStopCoordinator._executeStop` releases the stopped owner's
   `in_flight` projection synchronously with the invalidation
   (`_releaseInFlightProjection`), and a newer active run keeps its own
   projection untouched.
2. `_executeStop` deletes the session's durable suspended checkpoints and the
   durable runtime notice, so a stop terminalizes interactive waits and cannot
   resurrect a blocked/ERROR state.
3. `SessionTurnExecutor` releases the projection of the run that enters a
   blocked/waiting recovery (guarded by that run's `run_id`).
4. `requestStop` accepts `stopRunId` and the orchestrator forwards
   `event.runId`; the `stopped` payload names the addressed run even when the
   owner already left the active map. Stop stays session-scoped — the run id
   never gates cancellation.
5. `LocalGatewayCliClient.stop()` dispatches `stop` immediately with
   `session_id`, optional `run_id`, and one `request_id`, then re-reads
   authoritative state in a bounded loop (default 15 s, 250 ms interval)
   until `in_flight` and `pending_permission_request` are both absent. A
   matching `stopped` event only wakes the loop early. `stop_timeout` is raised
   without any success output.
6. `SessionStopCommand` resolves the in-flight `run_id` from session state
   first (best-effort) and prints `Session <id> stopped.` only after
   confirmation.
7. `SessionShowCommand` reports `running` only when `in_flight` exists **and**
   the durable execution projection is not `idle`/`queued`.
8. `/stop` renders a neutral “dispatched, not yet confirmed idle” notice for an
   unconfirmed stop instead of a send failure.

## Tests (red-first)

| Test | Red without the fix |
|---|---|
| `test/interfaces/interfaces_test.dart` — *stop releases the partial-stream projection so the session reports idle* | yes: frozen `in_flight` remained after `requestStop` |
| `test/interfaces/interfaces_test.dart` — *blocked recovery releases the projection and stop names the addressed run* | yes: projection kept; acknowledged run id was null |
| `test/interfaces/interfaces_test.dart` — *E.1 requestStop … atomically* (checkpoint assertion) | yes: 1 `awaiting_permission` row survived the stop |
| `test/cli/local_gateway_cli_client_test.dart` — *dispatches steer and waits for authoritative scoped stop* | yes: stop payload carried no `run_id` |
| `test/cli/local_gateway_cli_client_test.dart` — *never treats a stopped event as proof that the session is idle* | yes under the previous “event completes the stop” logic |
| `test/cli/local_gateway_cli_client_test.dart` — *fails with stop_timeout while the session keeps running* | pins the failure path |
| `test/cli/session_command_test.dart` — *names the in-flight run id from session state* / *still dispatches the stop when session state cannot be read* | pins resolution + best-effort dispatch |
| `test/cli/session_command_test.dart` — *reports idle instead of a stale in-flight snapshot …* | yes: stale snapshot reported `running` |

## Gates

- `cd agent && fvm dart analyze` → no issues.
- `fvm dart test test/cli/local_gateway_cli_client_test.dart test/cli/session_command_test.dart test/interfaces/interfaces_test.dart` → pass.
- `SANAD_HOME=<temp> SANAD_STATE_HOME=<temp> fvm dart test test/cli/` → 348 pass.
- `fvm dart test` (full agent suite, no env overrides; the suite isolates itself) → 3443 pass, 15 skipped, 0 fail.

## Live verification plan (Test Home only)

Never touch `~/.sanad` or a running runtime. Use a dedicated Test Home worktree
(`.agent/worktrees/test-home-2`, Home `~/.sanad-test-2`, port 58124) or a fresh
`SANAD_HOME` under a temp directory with `SANAD_STATE_HOME` beside it.

1. Start the branch runtime in the Test Home (`sanad-dev run` from that
   worktree); record the selected port.
2. Create a session with `sanad session new` and start a turn that blocks
   (`sanad run --timeout 600 "<prompt>"` against a provider whose request is
   rejected, or the deterministic E2E provider fixture).
3. Confirm the wedge: `sanad session show <id> --json` → `running`,
   `in_flight.run_id` present, `updated_at` frozen across two reads.
4. `sanad session stop <id>` → prints `Session <id> stopped.` and exits `0` only
   after confirmation; `sanad session show <id> --json` → `status: idle`,
   `in_flight: null`, `pending_permission_request: null`, `execution_snapshot.state: idle`.
5. Repeat `sanad session stop <id>` → exits `0` (idempotent) without
   `stop_timeout`.
6. In the Client UI attached to the same Test Home, confirm the stopped session
   shows the stopped/normal attention state and never an ERROR/blocked state.
7. Stop a session parked on a permission prompt: `sanad session stop <id>` must
   confirm idle and the UI must drop the permission card.
8. Negative control: point `sanad` at a daemon that never becomes idle and
   confirm `stop_timeout`, exit `1`, and no “stopped” output.

## Round Log

### Round 1 — 2026-10-22 (implementer)

- Read the master/nested contracts, the CLI architecture page, and the code paths named in the brief.
- Compared both stop commands field by field (`session_id`, `run_id`, `request_id`,
  `recovery_owner_token`, `device_id`, command name): the daemon path is identical;
  `recovery_owner_token` only enables draft/queued recovery for a client that can consume it.
- Found the never-released `in_flight` projection (`clearInFlightSnapshot` had no stop or
  recovery-block caller), the untouched `suspended_checkpoints` rows, the single-sample
  confirmation in the CLI client, the missing run identity, and the projection-only
  `session show` status.
- Implemented the daemon releases (projection, checkpoints, notice), the `stopRunId`
  transport, the dispatch-then-confirm CLI stop, the command-level run-id resolution, the
  `session show` staleness guard, and the REPL notice split.
- Red-first evidence: with the daemon release calls disabled the two new
  `interfaces_test` cases fail with the exact live snapshot
  (`type: thought_stream`, frozen `updated_at`); with the checkpoint delete disabled the E.1
  assertion reports one surviving `awaiting_permission` row; with the legacy stop payload the
  CLI test reports a null `run_id`.
- Docs updated: `agent/AGENTS.md` (stop releases the projection and interactive-wait
  checkpoints), `docs/technical/sanad_cli_architecture.md` (§9.3 stop confirmation contract,
  §9.1 stop row, §9.4 status derivation), `docs/agent_engine/sanad_delegate_relay.md` (§4.3),
  `docs/qa_maintenance/cli_session_observability_intervention_qa.md` (§5).
- Gates: analyzer clean; focused suites pass; `test/cli/` 348 pass under a temporary
  `SANAD_HOME`/`SANAD_STATE_HOME`; full agent suite 3443 pass / 15 skipped.
  Note: exporting `SANAD_HOME`/`SANAD_STATE_HOME` for the *full* suite makes the Home-guard
  tests fail by design (they assert the real defaults), so the full suite is run bare.
- No runtime was started, stopped, or restarted; `~/.sanad` was not touched; nothing pushed.

### Round 2 — 2026-10-22 (live check, attempt 2, safe method)

TH2 (`test-home-2`, Home `~/.sanad-test-2`, port 58124) on `5569efdd`. Only
`fvm dart run bin/sanad_agent.dart` was used, every call pinned with `--home`,
`SANAD_HOME` and `--gateway-url ws://127.0.0.1:58124/ws`; no compiled binary, no
launchd/relaunch wrapper, no detached process, no OS credential prompt. Full
evidence: `~/.sanad-delegate/runs/release-gate/live-134/RESULT.md`.

- **Stop during a running tool call — PASS.** Marker `sh -c sleep 300; …` was a
  direct child of the TH2 daemon. Two snapshots during the tool call showed
  `execution_snapshot.state: running` with a frozen `updated_at`. `session stop`
  returned rc=0 in 5.18 s and printed `Session <id> stopped.` at 04:49:06.703Z,
  i.e. **25 ms after** the durable state became idle (`updated_at`
  04:49:06.677836Z); the marker process was already gone, still gone at +5 s.
- **Idempotent — PASS.** Second stop rc=0 in 5.05 s, printed `stopped.`, no
  `stop_timeout`, state unchanged.
- **UI state — PASS.** The Client's per-workspace conversation cache never learns
  CLI-created sessions (no sidebar refresh), so one managed client restart was
  needed; afterwards both stopped sessions render as normal, enabled rows with no
  blocked/ERROR indicator and no approval card, and the daemon logged
  `RuntimeNotice [cleared]` at the stop.
- **Continue after stop — PASS.** A new short message on the stopped session
  returned exit 0 with the expected text.
- **Permission-parked stop — PASS (protocol), card PARTIAL.** Default mode, no
  `--allow-all-tools`: the park survived its own CLI client exiting, and the stop
  cleared `pending_permission_request` to idle in 5.88 s (still idle at +5 s). The
  card itself was never rendered for that request (it predated the Client knowing
  the session), and a second identical gated request ran **without** any
  permission request, so card disappearance could not be observed. RD11's durable
  checkpoint delete is likewise not exercised live: this park path writes no
  `suspended_checkpoints` row.
- **Discovery leak — FINDING.** `--home` + `SANAD_HOME` do not pin the endpoint:
  discovery probes **58085 (main) first** and otherwise scans 58086..58185. Both
  read-only probes without `--gateway-url` went to `ws://127.0.0.1:58085/gateway`
  and got 401. TH1/TH2/TH3 share one `.local_token`, so with 58085 not answering,
  an unpinned `session stop` could attach to a sibling Test Home. `--gateway-url`
  must stay mandatory for CLI live work.
- Teardown: TH2 reset `5569efdd` → `dc7ee42f`, agent restarted and healthy on
  58124, worktree unlocked, no leftovers.

### Open items for the coordinator

- Live verification steps 1–8 require a Test Home runtime and the Client UI; not run by the
  implementer.
- `sanad run`'s timeout/SIGINT path now waits for idle confirmation before its scoped stop
  returns; the relay window (`docs/agent_engine/sanad_delegate_relay.md` §4.3) already reserves
  a 30 s grace and needs no change.
