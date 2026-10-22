---
id: 125
title: Pre-start failures release the session queue; CLI run and compact report real terminal state
status: in_review
created: 2026-10-21
parent_task: none
follow_up_of: G2 (live defects seen during Plans 83 and 107)
depends_on: []
delivery: local commits on fix/g2-queue-timeouts (no push, no PR)
---

# Task 125 — Session Queue Release and CLI Timeouts

## Goal

A turn that fails before or outside the engine's typed recovery never holds the session queue. `sanad run` exits as soon as the daemon blocks or refuses its turn. `sanad session compact` waits for the real terminal state of its compaction operation.

## Defects (observed live during Plans 83 and 107)

1. **A blocked work item holds the session queue.** When a turn fails before the run starts, no `SuspendedRun` is created and the work item stays blocked. Every later message in the session then queues behind it forever.
2. **`sanad run` waits until `--timeout` (exit `124`)** after the daemon has already blocked or refused the session.
3. **`sanad session compact` returns `query_timeout` after 5 s** while the daemon keeps compacting.

## Root Cause (from source, `origin/main` `fe6204b1`)

### Defect 1

- `SessionTurnExecutor.runTurn` (`agent/lib/interfaces/runtime/session_turn_executor.dart`) has three failure exits:
  - `RuntimeRecoveryRequired`: the engine classified the failure, reported a notice, and the orchestrator records a `SuspendedRun`. Retry, Change Provider and Stop work.
  - `ThinkingSelectionException` (Task 115): a typed pre-dispatch rejection that terminalizes the owned work item as `cancelled` and releases the queue.
  - A generic `catch`: every other exception. It moves the owned durable work item to `blocked` and reports a forced blocked notice ("Execution could not start"), but it **never calls `onRecoveryRequired`**, so no `SuspendedRun` exists.
- The generic `catch` is reached by every failure the engine does not convert into recovery:
  - `LocalRuntimeOrchestrator.buildSessionMetadata`: a registered workspace whose folder is missing (`StateError`).
  - `buildRuntimeContext`: an execution root that is missing or is not a directory (`FileSystemException`).
  - Attachment admission without request identity, and `AttachmentStore.loadAdmission` failures.
  - `LocalRuntimeCatalog.buildTools` failures, such as policy or MCP catalog construction errors.
  - Provider failures that reach `RunnerRecoveryCoordinator` without a provider instance id (the coordinator returns `false` and rethrows).
- The result is a durable `blocked` row with no in-memory suspension. Three things follow:
  - `isSessionBusy` stays true through `findActiveWorkItem`.
  - `_drainNextQueuedEvent` never promotes queued work.
  - `resumeSuspended` returns `missing`, so the advertised Retry does nothing. A new `auto` message sees the active notice and emits `resuming`, but nothing resumes. Only Stop can release the session.
- The same `catch` on a **resume** turn (`isResume`) keeps the documented blocked state. When the resume came from the restored FIFO queue rather than `resumeSuspended`, it also had no `SuspendedRun`, so it stranded in the same way.

### Defect 2

- `OneshotRunner` (`agent/lib/cli/oneshot/oneshot_runner.dart`) treats `CliRuntimeNoticeEvent.isRecovering` (`waiting`, `blocked`, `resuming`, `cleared`) as advisory.
- A `blocked` notice waits for an explicit intervention that a non-interactive run cannot give. The run therefore always ended at its own `--timeout` with exit `124` and then sent Stop.
- `agent/test/cli/standalone_cli_process_test.dart` and `docs/technical/sanad_cli_architecture.md` §5 pinned this behaviour as a contract. That contract contradicts the requirement and is changed here (triage note).

### Defect 3

- `LocalGatewayCliClient.compactSession` defaults to a hard-coded `Duration(seconds: 5)`. `SessionCompactCommand` also falls back to a literal `5` for an unparsable `--timeout`.
- The daemon's `session.compact_result` is sent only after `runCompaction` finishes (Task 119). One compaction provider pass is bounded by `Config.compactionPassTimeout`, which defaults to 600 s.
- A slow but healthy compaction therefore became `query_timeout` and exit `1`.

## Design

### Defect 1: choice and justification

- **Fresh turns use a typed terminal outcome, not a suspended state.**
  - The generic `catch` covers failures that the engine did not classify as recoverable. On the pre-start paths no provider request was dispatched and no tool started, so no continuation checkpoint exists to resume.
  - A Retry would run the same admission again and fail again, while holding FIFO for every later message.
  - The runtime contract (`agent/lib/interfaces/runtime/AGENTS.md`) requires blocked work to expose a working Retry, a failed resume to keep controllable ownership, and terminal delivery only after a durable owner commit.
  - The fix follows the Task 115 precedent:
    1. Terminalize the exact owned durable work item to `cancelled` through `transitionOwnedWorkItem`. Completion is never guessed and nothing is replayed.
    2. Clear only a runtime notice that this run owns.
    3. Deliver one final error answer carrying `error_code: turn_failed`.
    4. Let `onTurnComplete` release busy ownership and drain the next queued item.
  - A stale loser, whose durable ownership already moved on, stays silent and does not drain.
  - Completed history and tool results are preserved, the same as Stop. The latest user root stays eligible for Edit or Retry replay.
- **Resume turns keep a resumable suspended state.** They have a durable checkpoint, and the contract keeps a failed resume blocked and controllable. The generic `catch` now also calls `onRecoveryRequired`, so the orchestrator holds a `SuspendedRun` for Retry, Change Provider and new-message resume, and the queue stays owned by the blocked item that has a working way out.
- Engine-classified recovery (`RuntimeRecoveryRequired`) is unchanged. It already records a `SuspendedRun`.

### Defect 2

- A `blocked` runtime notice for the run's session ends `sanad run` at once:
  - exit `1`, terminal status `failed`, `cause: blocked`
  - one stderr line: `Error: blocked: <reason>. Intervene with sanad session stop <id> or retry from a client.` The reason and the intervention sentence are composed by the CLI, so exactly one period separates them (round 2, N1).
- The CLI does not send Stop on `blocked`. The blocked work stays daemon-owned for intervention.
- `waiting`, `resuming` and `cleared` stay advisory, because the daemon still owns automatic progress for them.
- A typed refusal (`final_answer.error_code`, including the new `turn_failed`) already exits `1` at once.

### Defect 3

- `sanad session compact` waits for the correlated terminal `session.compact_result` of its single dispatch, which is never resent.
- The default wait bound is the compaction pass timeout read from the target Home's `config.yaml`. A new central accessor, `ModelAwareRuntimePolicy.compactionPassTimeoutForHome`, reads it. `--timeout` still overrides the bound, and an invalid value falls back to the same central bound, not to a literal.
- If the bound passes without a result, the CLI reports `outcome: unconfirmed`, never failed, and exits `124`. It also tells the user how to poll: `sanad session show <id>` now includes a `compaction` summary (the latest lifecycle `compaction_id`, `status` and `trigger` from hydrated history).

## Tests (red first, then green)

- [x] Orchestrator plus durable state: `agent/test/interfaces/runtime/pre_start_failure_queue_release_test.dart`.
  - A pre-start failure (missing workspace folder) terminalizes its work item, delivers a typed `turn_failed` answer, raises no blocked notice and drains the queued follow-up.
  - A failed restored resume keeps a `SuspendedRun`, so Retry claims it.
- [x] CLI one-shot against the daemon event contract: `agent/test/cli/run_command_test.dart`. A `blocked` notice exits `1` at once with one line and no Stop, and `waiting` and `resuming` stay advisory.
- [x] CLI compact against the daemon contract: `agent/test/cli/session_command_test.dart`. The default bound comes from config, an invalid `--timeout` falls back to it, an exhausted bound reports `unconfirmed` with `124`, and `session show` reports the latest `compaction`.
- [x] Contract flip: `agent/test/interfaces/platforms/sanad_gateway/attachment_replay_boundary_test.dart`. A failed attachment admission is now `cancelled`, not `blocked`.
- [x] Standalone process contract flipped: `agent/test/cli/standalone_cli_process_test.dart` now expects an immediate `1`, not `124`.
- [x] Round 2 client visibility (F1), red first then green:
  - `client/test/unit/bloc/refused_first_turn_release_test.dart`: a `turn_failed` answer and a `blocked` notice each release the awaiting draft and keep its text; a canonical acceptance still clears it.
  - `client/test/unit/services/device_conversation_event_handler_test.dart`: a typed refusal keeps its `error_code` and survives an empty history swap; an accepted user message supersedes it.
  - `client/test/unit/home_screen_route_session_test.dart`: a selected session with no device projection is presented instead of the `Loading...` placeholder.
  - `client/test/widget/refused_send_composer_test.dart`: a refused send ends the acceptance wait and keeps the text editable.
- [x] Round 2 CLI reason text (N1), red first then green: `agent/test/cli/run_command_test.dart` pins one clean reason line for a typed refusal and for a blocked notice.
- [x] Daemon E2E (`--concurrency=1`): `agent/e2e_test/session_queue_release_e2e_test.dart`.
  - A real daemon releases the queue after a pre-start failure.
  - The real `sanad run` exits at once on a refused turn.
  - The real `sanad session compact` waits through a slow compaction.

## Gates

Round 2 gate results on the merged tree:

- [x] `fvm dart analyze` (agent) and `fvm flutter analyze` (client) are clean.
- [x] Full agent suite: 3420 passed, 15 skipped (after the follow-up merge).
- [x] Full client suite: 2016 passed.
- [x] Agent E2E with `--concurrency=1`: `session_queue_release_e2e_test.dart` 3 passed; `context_compaction_daemon_e2e_test.dart` plus `durable_recovery_restart_e2e_test.dart` 23 passed.
- [x] Client E2E with `--concurrency=1`: 14 passed.
- [x] Merge integration: the merge from `182d6a40` brought the new on-disk state isolation guard, so the r1 E2E harness now declares its temporary roots with `setSanadHomeOverride`/`setSanadStateHomeOverride`. Without that, all three E2E cases failed on the merged tree.
- [x] Test-home isolation for round 2: the fast suites keep their own contracts (in-process overrides and one temporary `SANAD_STATE_HOME` per spawned daemon). A run-wide `SANAD_HOME`/`SANAD_STATE_HOME` override is not possible because the suite asserts default root resolution, and redirecting `HOME` makes the toolchain re-resolve its own cache.
- [x] The full agent suite (3322 passed, 15 skipped) and the full client suite (1952 passed, 1 skipped) pass.
- [x] The affected E2E passes with `--concurrency=1`: the new `session_queue_release_e2e_test.dart`, plus `context_compaction_daemon_e2e_test.dart` and `durable_recovery_restart_e2e_test.dart` (25 tests).
- [x] `lint_wiki` passes.
- [x] Docs and AGENTS are updated in the same commits:
  - `agent/lib/interfaces/runtime/AGENTS.md`
  - `docs/technical/provider_protocol.md` §5
  - `docs/technical/sanad_cli_architecture.md` §5, §9 and §9.3
  - `docs/qa_maintenance/cli_session_observability_intervention_qa.md` §6
  - `docs/operations/user_guide.md`
  - `docs/agent_engine/sanad_delegate_relay.md` §4.3
- [x] Round 2 docs and contracts:
  - `client/AGENTS.md` (conversation ownership: acceptance release and retained refusal)
  - `docs/technical/client_conversation_cache_schema.md` §5 and §6
  - `docs/technical/communication_protocols.md` §4.6
  - `docs/technical/sanad_cli_architecture.md` §5
  - `docs/qa_maintenance/cli_session_observability_intervention_qa.md` §4
- [ ] Coordinator review and live acceptance on one Test Home (scenarios below).

## Proposed Live Scenarios (one Test Home)

1. **Queue release.**
   - Register a workspace, delete its folder, and send a message. Expect one error answer, no blocked banner, and an idle session.
   - Send a second message in the same session. It runs at once and does not queue.
2. **Resumable failed resume.** Not reliably reproducible live. It is covered by the deterministic test only.
3. **CLI blocked exit.**
   - Run `sanad run --home <test-home> --timeout 120` against a provider route that blocks (for example an image prompt on a text-only route). Expect exit `1` within seconds, one `Error: blocked: …` line, and the Client still showing the blocked notice with Retry, Change Provider and Stop.
   - Run the same against a route that refuses (a missing workspace folder). Expect exit `1` at once with `turn_failed`.
4. **CLI compact.** Run `sanad session compact <id> --home <test-home> --json` on a long session whose compaction takes more than 5 s. Expect `outcome: accepted` and exit `0` after the real duration, with one dispatch and one operation row.

## Round Log

- **Round 1 (writer, 2026-10-21):** Plan written from the source triage above, then implemented.
  - **Defect 1.** The generic `catch` in `SessionTurnExecutor.runTurn` now splits:
    - A fresh turn is terminalized `cancelled` for its exact owner, answers with `error_code: turn_failed`, clears only its own notice and drains FIFO. A stale loser stays silent.
    - A resume stays `blocked` and calls `onRecoveryRequired`.
  - **Defect 2.** `OneshotRunner` ends on `CliRuntimeNoticeEvent.isBlocked`: exit `1`, one line, `cause: blocked`, no Stop.
  - **Defect 3.** `ModelAwareRuntimePolicy.compactionPassTimeoutForHome` is the central wait bound.
    - `SessionCompactCommand` uses it, and `LocalGatewayCliClient.compactSession` defaults to `ModelAwareCompactionPolicy.defaultPassTimeout` instead of a literal 5 s.
    - An exhausted wait reports `unconfirmed`, exit `124` and a `poll` hint.
    - `session show` gains a `compaction` summary.
    - The E2E fixture gains `__SANAD_E2E_COMPACTION_DELAY__<seconds>`.
  - **Red evidence:** every new or flipped test failed on the original source.
    - D1: missing `turn_failed`; the resume recorded no suspended run.
    - D2: a 5 s unit timeout, standalone `124` after 60 s, and E2E `124` after 120 s.
    - D3: a default of 5 s or null, and exit `1` where `124` was expected.
    - E2E: all three cases failed.
  - **Green evidence:** focused tests, the full suites, the affected E2E and lint all passed. Logs are in the private workspace `temp/g2/`.
  - **Not verified live:** the Test Home scenarios above are proposed only.
  - **Out of scope, noted:** `runTurn` returns before creating an `ActiveRun` when `turnRequest.message` is empty, which would leave admitted durable work `running`. Whether any admitted turn, such as an attachment-only one, can reach it was not confirmed, so this was not changed and is left for triage.

- **Round 2 (writer, 2026-10-22):** Merged `origin/main` (`182d6a40`, merge `1e29c8fc`, no conflicts) and closed F1 and N1 from the live r1 findings. A follow-up upstream commit (`3c561edc`, Task 127) arrived during the round and was merged the same way; it touched only E2E tests and docs, so the results below were rerun on that tree.
  - **F1 on main: yes.** The client defects reproduce on `182d6a40`'s own code paths.
    - The r1 branch carried no client changes, so before this round its client tree was byte-identical to `origin/main` (`git diff origin/main 1e29c8fc -- client/` is empty).
    - Reverting only `client/lib` to that tree and rerunning the four new tests failed all of them:
      - `a typed turn_failed refusal releases the awaiting draft and keeps the text`: the draft stayed pending.
      - `a blocked runtime notice releases the awaiting draft and keeps the text`: the same on main's daemon outcome, so the composer stayed locked there too.
      - `a typed refusal keeps its code and survives an empty history swap`: the refusal was dropped and `error_code` never reached the canonical event.
      - `a selected session with no device projection is still presented`: the route returned the `Loading...` placeholder.
    - What differs on main is which surface shows the failure, not whether the client defects exist.
      - Main's generic `catch` (`git show origin/main:agent/lib/interfaces/runtime/session_turn_executor.dart`) leaves the work item `blocked`, reports a forced blocked notice ("Execution could not start"), and still emits `Error: <cause>` without an `error_code`.
      - The client therefore showed a blocked banner (an error surface) while its composer stayed locked, its header stayed on `Loading...`, and nothing was persisted.
      - On this branch the same failure delivers one typed `turn_failed` answer instead of a notice, and the client rendered none of it because the answer was not persisted and the empty history swap dropped it.
  - **F1 root causes (client):**
    1. `ConversationDraftCache` cleared a pending request only from a matching canonical acceptance. A turn refused before dispatch never publishes `user_message`, so `pendingRequestId` stayed set: the composer kept its acceptance indicator, refused a second send, and only an edit cleared it.
    2. `UnifiedDeviceMapper` dropped `error_code`, so a typed refusal was indistinguishable from a completed answer.
    3. `DeviceConversationStore.setHistory` replaced the whole timeline, and a refused turn persists no history, so the live `final_answer` disappeared on the next hydration (empty session, no user row, no error).
    4. `HomeScreen.resolveRouteSession` required a matching `deviceId` as well as a matching session id. A session the Client had just created was selected before its device projection settled, so the route kept presenting the identity placeholder (`Loading...`) for a session id it already owned.
  - **F1 fix:**
    - `ConversationDraftCache.releasePendingRequest` (via `ConversationCacheStore.releasePendingRequest` and `ConversationCacheRepository.releaseRefusedDraft`) clears only the pending marker of the draft whose request matches, keeping its text, workspace and route.
    - `SessionCubit` releases that draft on a `final_answer` carrying `error_code` and on a `blocked` `session.runtime_notice`, so main's behaviour and this branch's behaviour both unlock the composer.
    - `ConversationInputPanel` restores the draft text instead of clearing the composer when the pending marker is released without acceptance.
    - `UnifiedDeviceMapper` keeps `error_code` in canonical metadata.
    - `DeviceConversationStore` retains the session's latest typed refusal and re-appends it after every `setHistory` that does not represent the same request, dropping it once an accepted `user_message` for that session arrives.
    - `HomeScreen.resolveRouteSession` presents a selected session by id, and `SessionCubit.markSessionSelectedSync` upgrades an identity placeholder to the authoritative session of the same id.
  - **N1 root cause:** both CLI reason lines reused daemon text verbatim. The typed-refusal branch composed `'$code: ${event.finalMessage}'` on an answer that already read `'Error: <cause>'`, and the blocked branch appended `. Intervene …` to a notice that already ended with a period.
  - **N1 fix:** `OneshotRunner._reasonSentence` is the single owner of the reason text: it drops a leading `Error:` prefix and the trailing punctuation, then supplies exactly one terminal period. The refusal line is now `Error: turn_failed: Bad state: Workspace folder is unavailable.` and the block line is `Error: blocked: <reason>. Intervene with sanad session stop <id> or retry from a client.`
  - **Red evidence:** every new test failed before its fix, and the four F1 tests also failed with `client/lib` reverted to `182d6a40`.
  - **Green evidence:** the focused tests, the affected client unit/widget suites and both analyzers passed. Suite results are recorded under Gates.
  - **Merge integration:** the merge brought the new on-disk state isolation guard, which rejected the r1 E2E harness' in-isolate database seed. The harness now declares its own temporary roots with `setSanadHomeOverride`/`setSanadStateHomeOverride` and clears them on teardown.
  - **Not fixed, now out of scope by design:** the daemon still persists neither the refused user root nor its answer. The client keeps that refusal visible for the session, but a Client restart or another Client will not see it. Persisting the refused turn durably is a daemon contract change and is left for triage.
