---
plan_id: 108
issue: https://github.com/EastStarAI/sanad-agent/issues/213
branch: fix/108-pending-ask-survives-restart
status: in_progress
current_gate: G0
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

### G1 — Fix
- [x] Exclude user-interaction tool calls (`system_ask_user`, permission-gated tools awaiting a decision) from ambiguous/unknown terminalization during resume classification.
- [x] Route them to the existing suspended-checkpoint / pending-input restore path so the question is re-armed as pending.
- [x] Preserve existing ambiguous-interruption behavior for all other non-replay-safe tools (no security regression of #124).

### G2 — Regression coverage
- [x] Unit/integration coverage: pending `system_ask_user` across forced shutdown → restore as pending (`agent/test/interfaces/runtime/pending_ask_restart_repro_test.dart`).
- [x] Same coverage for a pending permission request.
- [x] Coverage that non-idempotent tools with real side effects are not restored as waits.

### G3 — Verification and docs
- [x] `fvm dart analyze` clean in `agent/`.
- [x] Focused tests pass; full fast agent suite passes (2084 tests).
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
- [ ] PR delivered from this branch referencing plan 108 and issue #213.
- [ ] Live behavioral verification on a managed runtime (pending user confirmation).
