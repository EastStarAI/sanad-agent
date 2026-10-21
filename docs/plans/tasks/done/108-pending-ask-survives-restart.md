---
plan_id: 108
issue: https://github.com/EastStarAI/sanad-agent/issues/213
branch: fix/108-pending-ask-survives-restart
status: done
current_gate: G3
---

# 108 — Pending ask-user / permission tool survives abrupt shutdown and restart

## Goal

When a `system_ask_user` question (or a tool-permission decision) is pending user input and the Agent stops — abruptly (`kill -9` / force quit) or through a managed restart — the tool must remain **pending** after restart and be restorable through the suspended-checkpoint path. It must never be converted into the ambiguous-interruption error result:

```
Error: Tool execution was interrupted before completion could be confirmed. The outcome is unknown, and the tool was not executed again to avoid duplicating side effects.
```

## Locked decisions and scope

- Regression of the class fixed in PR #124 and PR #149; root cause lives in resume classification, not in a new subsystem.
- In scope: Agent resume/recovery paths (`continuation_checkpoint_coordinator`, `agent_runner`, `suspended_resume_service`, `platform_runtime_bridge`), pending-input/checkpoint persistence for `system_ask_user` and permission requests, and regression tests.
- Out of scope: changing the ambiguous-interruption behavior for tools with real side effects; client UI changes beyond what current pending/needs_input rendering already supports.
- `system_ask_user` and permission prompts are user-interaction tools with **no side effects**; classifying them as ambiguous is always wrong.

## Gates

### G0 — Discovery and reproduction evidence
- [x] Identify the exact resume entry point that produced the interruption error in the reported scenario (auto-recovery from #149, managed restart, or daemon restart path).
- [x] Trace why the suspended-checkpoint / pending-input restore path (`isAskUser` handling) did not win over ambiguous classification.
- [x] Write or confirm an automated repro that kills the process mid-`system_ask_user` and observes the error result in history.

**G0 findings (2026-10-15):**

1. `system_ask_user` saves a `SuspendedCheckpoint(status: 'awaiting_permission')` **before** awaiting the answer and deletes it in `finally` — an abrupt kill leaves the checkpoint intact (`local_runtime_catalog.dart` onExecute). A pending tool-permission prompt does the same in `permission_manager.dart`.
2. On daemon startup, `SessionRecoveryRestorer` classifies restorable work items in three places: the `running` loop, the `blocked` repair loop, and the `resuming` reclassification loop.
3. The `running` loop (added by #196) already protects a fully checkpoint-covered interactive wait, and the `blocked` loop repairs a falsely blocked one. **The `resuming` loop was never given the same guard.**
4. Consequence: a durable owner left in `resuming` — a claim was recorded (managed stop / auto-recovery claim) and the process died again before the user-input tool re-ran — reached `_metadataForAutomaticInterruptedResume()`, which sets `auto_recover_interrupted_tools_as_unknown` whenever `currently_executing_tools` is non-empty and the checkpoint kind is recognized.
5. That flag makes `AgentRunner._restoreCheckpointForResume` pass `neutralizeAllInterruptedTools: true`, so the still-pending `system_ask_user` tool call lands in `ambiguousToolCallIds` and `_recordAmbiguousToolInterruptions()` writes the reported error into durable history. The turn then auto-resumes and the question is lost.
6. `HistoryHealer` already protects suspended toolCallIds from the *synthetic* heal message, but it cannot help: the resume path writes the error result itself.

**Fix (G1):** extract `_isUnresolvedInteractiveWait(executingTools, suspendedToolCallIds)` and apply it in all three classification sites, closing the `resuming` hole and de-duplicating the previously repeated predicate. Mixed batches (some tools side-effected, some checkpoint-pending) keep today's ambiguous behavior by design.

**Ordering correction (2026-10-21):** the suspended set holds every non-`executing_tool` checkpoint, including `decision_ready`. In the `resuming` loop the new guard therefore shadowed the existing decision-ready branch (same `waiting` outcome, but that branch and its diagnostic became unreachable). The guard now runs after the decision-ready check. A pure reorder was chosen over a narrower `awaiting_permission`-only set because the suspended set is shared by the `running`, `blocked`, and provable-waiting checks, where including answered decisions is intended; a second set would split that one definition.

### G1 — Fix
- [x] Exclude user-interaction tool calls (`system_ask_user`, permission-gated tools awaiting a decision) from ambiguous/unknown terminalization during resume classification.
- [x] Route them to the existing suspended-checkpoint / pending-input restore path so the question is re-armed as pending.
- [x] Preserve existing ambiguous-interruption behavior for all other non-replay-safe tools (no security regression of #124).

### G2 — Regression coverage
- [x] Unit/integration coverage: pending `system_ask_user` across forced shutdown → restore as pending (`agent/test/interfaces/runtime/pending_ask_restart_repro_test.dart`).
- [x] Same coverage for a pending permission request.
- [x] Coverage that non-idempotent tools with real side effects are not restored as waits.
- [x] Coverage that a `resuming` owner whose checkpoint is `decision_ready` still reaches the decision-ready branch (outcome and diagnostic), proven failing before the ordering correction.

### G3 — Verification and docs
- [x] `fvm dart analyze` clean in `agent/`.
- [x] Focused tests pass; full fast agent suite passes (2084 tests on the original base; re-verified after the main merge, see Evidence).
- [x] Update owning `AGENTS.md` / `docs/` statements that this behavior makes stale (incremental reverse documentation DoD).
- [x] Run `graphify update .` after code changes.

## Acceptance Criteria

- [x] Given a pending `system_ask_user` question, when the Agent process is killed abruptly and restarted, then the conversation still shows the pending question and the user can answer it; the tool result is not the interruption error.
- [x] Given a pending permission request, when the same sequence occurs, then the permission prompt is restored as pending.
- [x] Given a non-idempotent tool (e.g. shell command) mid-execution at kill time, when restarted, then it is not restored as a wait (unchanged safe behavior).
- [x] All restart entry points that recover sessions (managed restart, forced shutdown recovery, auto-recovery) behave identically for pending user-interaction tools.

## Definition of Done

- [x] Analyzer and focused/full fast test suites pass in the worktree.
- [x] Documentation updated in the same session as the code change.
- [x] Regression coverage exists for all three acceptance scenarios above.
- [x] PR delivered from this branch referencing plan 108 and issue #213 (PR #215).
- [x] Live behavioral verification on a managed runtime (see Live Evidence).

## Integration Evidence

- 2026-10-21: merged `origin/main` (`f77f0571`) into the branch with no textual conflicts. Main's startup compaction-orphan reconciliation and the 106b/116/117 runtime changes do not touch `resuming` classification and compose with this guard.
- After the merge and the ordering correction: `fvm dart analyze` clean; `pending_ask_restart_repro_test.dart` 6/6; `test/interfaces/runtime/` 114 passed; full agent suite 2923 passed, 14 skipped.

- After re-merging `origin/main` (`6a832396`, no overlapping paths): `fvm dart analyze` clean; `test/interfaces/runtime/` 114 passed.

## Coordinator Review

- The ordering correction is a reorder only: the interactive-wait guard now runs after the decision-ready check, so the decision-ready reclaim branch and its diagnostic are reachable again. Accepted.
- Tests: `pending_ask_restart_repro_test.dart` 6/6; runtime folder 114 passed; full agent suite 2923 passed, 14 skipped.

## Live Evidence (isolated Test Home, 7 model calls)

- Case 1: a pending `system_ask_user` survived a verified `SIGKILL` of the daemon child; the ask stayed pending, and answering it resumed the turn to completion.
- Case 2: two kills before answering; the ask stayed pending and the answer completed the turn.
- Case 3: a pending shell permission prompt survived a kill, and "allow once" completed the turn.
- Across all cases: 0 "interrupted before completion" results and 0 blocked notices.

## Live-check Plan (isolated Test Home)

1. From the 108 worktree, start the worktree-scoped runtime with `sanad-dev run` and confirm with `sanad-dev status` that its Sanad Home is the worktree-isolated Test Home, never the primary or a shared test Home. A provider must be configured in that Home.
2. Prompt the model to call `system_ask_user` and confirm the question is pending. Optional read-only evidence: work item `running`/`waiting` with the ask id in `currently_executing_tools`; checkpoint `awaiting_permission`.
3. Abrupt stop: resolve the PID listening on that runtime's daemon port, verify it is the daemon child of the `HotRestartManager` supervisor and that its `SANAD_HOME` is the Test Home, then send `SIGKILL` to that PID only. The supervisor treats the non-zero exit as a crash and respawns the daemon with the same Home and ports. Without a supervisor, use `sanad-dev stop` and `sanad-dev run` from the same worktree.
4. Pass: bounded agent logs show no interruption result and no blocked notice; the client still shows the pending question; answering it resumes and completes the turn with the answer as the tool result.
5. Repeat with a second kill before answering, with a pending tool-permission prompt, and (best effort, racy) with a graceful `sanad-dev restart agent` immediately followed by the verified kill to hit the `resuming` path.
