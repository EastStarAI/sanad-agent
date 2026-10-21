---
title: "111 — Terminal final-answer classification and footer integrity"
status: "in_progress"
current_gate: "G4 — Live verification (coordinator)"
remaining_estimate: "Gate-based only; G0–G3 closed, live verification pending."
---

# Goal

Every durable, terminal assistant reply must reach the Client as a final answer
(`EventKind.finalAnswer`) so its footer — timestamp, usage statistics, copy, and
Fork — is present in both the live timeline and any history hydration, instead of
degrading to the transient Thoughts surface that keeps only a copy action.

# Reported symptom

Some assistant replies render exactly like a final answer but show **only the
copy button**: no timestamp, no token/model/duration metadata, no Fork. The user
confirmed the timestamp is absent, which excludes a "final answer with partial
metadata" explanation and proves the reply is rendered through the transient
`thinking` surface.

# Locked decisions and scope

References are against `origin/main` `adc128ec` (after the Task 110 SRP split).

- The shared primary UI split is intentional and stays: `thinking` renders the
  final-answer Markdown body with a copy action but never the metadata footer
  (`client/lib/features/conversations/presentation/widgets/event_tile.dart:192-198`,
  `docs/technical/reasoning_thoughts_separation.md` §Shared Primary UI).
- `responseMetaParts` returning nothing for non-final-answer kinds is correct
  (`client/lib/utils/format_utils.dart:11-12`) and `isForkableFinalAnswer`
  correctly requires `EventKind.finalAnswer`
  (`client/lib/features/conversations/domain/models/canonical_event.dart:86-93`).
- Therefore the defect is upstream: a durable terminal reply is classified,
  emitted, or stamped as non-terminal (`thought`).
- The Client is not changed by this task.

# G0 findings (closed)

Evidence was read **read-only** from the primary Sanad Home `state.db`
(`sqlite3 "file:…/state.db?mode=ro"`, re-measured 2026-10-21):

- 2 760 active no-tool, non-steer assistant rows; 778 lack
  `metadata.terminal_work_item_id`. 772 of those end their turn (next active row
  is a user row or nothing), so they are genuine final answers; 6 are mid-turn
  commentary. All 772 carry `turn_id`, 767 carry `usage`, 769 carry `run_id`.
- 366 of the 772 unstamped terminal rows still have a `completed` work item whose
  `continuation_metadata.owner_run_id` equals the row's `run_id`. A work item
  completes only through a **committed** terminal commit, so for those rows the
  stamp was written and later erased. The remaining 406 have no work item left
  (pruned), so their history cannot be decided.
- 250 unstamped terminal rows have `finishReason: unknown`;
  `SessionForkCopy.isForkableFinalAnswer` refuses those without the stamp, so
  Fork also fails server-side for them, not only in the Client.
- The available daemon log window holds no `Terminal commit rejected` line, so
  the live `stale_owner` / `recovery_owns_state` path is not shown to contribute.

## Confirmed root cause

Two defects combine:

1. **The stamp is written, then erased by a later history rewrite.**
   - `SessionTurnExecutor` calls `attachMetadataToLastAssistantMessage`
     (`agent/lib/engine/agent_runner.dart:1460-1470`) first. That runs
     `SessionManager.saveSessionHistory`
     (`agent/lib/evolution/session_manager.dart:204-233`), which bumps the
     history revision and caches the unstamped rows at that revision.
   - `commitTerminal` → `_persistAssistantResult`
     (`agent/lib/evolution/db/runtime/session_execution_state_coordinator.dart:864-914`)
     then stamps that same row **in place** and does not bump the revision.
   - On the next turn, `AgentRunner._reloadPersistedHistory`
     (`agent/lib/engine/agent_runner.dart:572-577`) gets the stale cached,
     unstamped copy from `SessionManager.getSession`
     (`agent/lib/evolution/session_manager.dart:103-116`).
   - The next `saveHistory` reaches `SessionMessageRepository._replaceMessagesInDatabase`
     (`agent/lib/evolution/db/session_message_repository.dart:65-123`). That
     function overwrites every aligned row whose JSON differs, which drops
     `terminal_work_item_id` / `terminal_generation`.
2. **History classification is page-scoped.**
   - `SessionQueryHandler._buildHistoryEnvelope`
     (`agent/lib/interfaces/platforms/sanad_gateway/handlers/session_query_handler.dart:207-216,466-551`)
     treats an unstamped reply as terminal only when it is the newest no-tool
     assistant row **of the fetched page** (`legacyFinalAssistant`). Every other
     unstamped terminal reply is emitted as `type: 'thought'` without `usage`,
     `model`, `runtime_ms`, or `MessageHistoryIdentity.wireFields`. That is why
     the statistics and Fork disappear together.
   - Search uses a third rule: the newest assistant row of the **session**
     (`agent/lib/evolution/db/session_repository.dart:305-325`).

The live completion path
(`agent/lib/interfaces/runtime/session_turn_executor.dart:563-570`) stays the
documented silent `stale_owner` / `recovery_owns_state` contract
(`docs/technical/agent_runtime.md:239-240`). It is not the observed cause.

# Gates

## G0 — Discovery confirmation

- [x] Confirm the upstream path: history classification plus a stamp erased by
      history rewrite. The silent terminal commit is not implicated.
- [x] Record the evidence (above).
- [x] Live path: no `Terminal commit rejected` line in the available log window.
- [x] Missing stamp: written, then erased by the stale-cache history rewrite.
- [x] Root cause recorded before any source edit.

## G1 — Terminal classification authority (agent)

- [x] One evolution-owned classifier decides "terminal assistant result" as
      the stamp, **or** a no-tool, non-steer assistant row whose next active row
      in the **session** is a user row or nothing. It is independent of page
      position.
- [x] History delivery and session search use that classifier. Fork
      eligibility stays stamp-based on purpose: `session_fork_service_test.dart`
      locks "rejects unknown-finish assistant text without a terminal marker".
- [x] Terminal replies keep identity fields and statistics in history.
- [x] Non-terminal assistant text (typed `thought`, commentary followed by more
      assistant output in the same turn, steer segments) stays on the transient
      Thoughts surface.

## G2 — Terminal stamp integrity (agent)

- [x] An in-place terminal stamp invalidates revision-keyed history caches.
- [x] A history rewrite of the same message identity carries the durable
      terminal stamp forward instead of erasing it.
- [x] A regression test commits a terminal result, rewrites session history from
      memory, and re-reads the row.

## G3 — Live-path completion (agent)

- [x] The silent `stale_owner` / `recovery_owns_state` outcome stays silent. G1
      coverage proves that the unstamped durable reply still hydrates as
      `final_answer`.

## G4 — Verification, documentation, and delivery

- [x] Focused agent tests cover classification, stamp integrity, fork
      eligibility, and the thought/final-answer split.
- [x] Agent analyzer and full agent suite pass. The Client is untouched, so no
      Client suite is needed.
- [ ] Live verification scenarios are handed to the coordinator.
- [x] Owning documentation is updated in the same session
      (`docs/technical/reasoning_thoughts_separation.md`,
      `docs/technical/communication_protocols.md`,
      `docs/technical/agent_database_schema.md`, the nearest `AGENTS.md`).

# Acceptance Criteria

- [x] Given an assistant reply whose durable row is the terminal result of its
      turn, when the Client hydrates history for that session, then the reply is
      delivered as `final_answer` with `message_id`, `turn_id`, token usage,
      model, duration, and the Fork control available.
- [x] Given a session page that is not the newest page, when older replies are
      loaded, then terminal replies in that page are still delivered as
      `final_answer`, because classification no longer depends on page position.
- [x] Given intermediate assistant text before a tool call or a steer segment,
      when history is hydrated, then it still renders as the transient Thoughts
      surface with a copy action only.
- [x] Given a committed terminal result, when a later turn rewrites session
      history from memory, then the row keeps `terminal_work_item_id` and
      `terminal_generation`.
- [x] Automated coverage fails on the pre-fix classification and stamp
      behavior and passes after the fix.

# Definition of Done

- [x] `fvm dart analyze` clean in `agent/`. `fvm flutter analyze` clean in
      `client/` as a no-regression check.
- [x] Focused and full agent tests pass with the changed behavior covered.
- [ ] Live verification scenarios recorded for the coordinator.
- [x] Documentation updated; no stale or contradictory contract text remains.
- [ ] No push or PR without explicit user authorization.

## Implementation

- `agent/lib/evolution/db/terminal_assistant_classifier.dart` (new): the single
  definition of a terminal reply (`isTerminal`), the stamp carry-forward
  (`carryForwardStamp`), and the equivalent SQL predicate (`sqlIsTerminal`).
- `SessionHistoryPage.followingMessage`: the first active row after the page,
  read by `SessionMessageRepository.getPersistedMessagePage`.
- `SessionQueryHandler._buildHistoryEnvelope`: the page-scoped
  `legacyFinalAssistant` is replaced by the classifier.
- `SessionRepository.searchSessions`: the newest-row-of-session rule is
  replaced by `sqlIsTerminal`.
- `SessionMessageRepository._replaceMessagesInDatabase`: identity-matched
  replacements keep a stored terminal stamp.
- `SessionExecutionStateCoordinator._persistAssistantResult`: an in-place stamp
  bumps `history_revision`.
- On the primary Home (read-only), the SQL classifier marks 2 754 of 2 760
  candidates terminal: 1 982 stamped plus 772 unstamped turn-enders. The other
  6 are mid-turn commentary.
- Remaining gap: legacy rows whose stamp was already erased **and** whose
  `finishReason` is `unknown` (250 on the primary Home) now render the footer,
  but the server still refuses their Fork under the locked fork contract. New
  replies keep their stamp, so this does not recur.

## Verification evidence (logs under `temp/111/`)

- Pre-fix red: `g2-prefix-red.log` (3/3 stamp tests fail),
  `g1-history-prefix-red.log` (3/4 history tests fail),
  `g1-search-prefix-red.log` (1 search test fails).
- `fvm dart analyze` (agent): No issues found — `agent-analyze.log`.
- Focused (8 files): +129, all passed — `focused-green.log`.
- Full agent suite `fvm dart test`: +3011 ~14, all passed —
  `agent-full-suite.log`.
- `fvm flutter analyze` (client, untouched, after `gen-l10n`): No issues
  found — `client-analyze.log`.
- No port-binding E2E run: no socket, daemon, or restart boundary changed.
- `graphify update .`: succeeded — `graphify-update.log`.

## Current status

Ported to `.agent/worktrees/111-port` on branch
`fix/111-final-answer-terminal-classification-v2` from `origin/main`
(`adc128ec`). G0–G3 are closed and automated verification is green. Live
verification in the worktree runtime is pending with the coordinator. There is
no push and no PR.
