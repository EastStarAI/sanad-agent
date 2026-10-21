---
id: 117
title: Session history integrity — in-place history rewrite and bounded recovery summarizer
status: completed
gate: completed-with-recovery-live-residual
created: 2026-10-21
parent_task: none (split from 106)
depends_on: []
delivery: own PR (squash-merged to main)
---

# Task 117 — Session History Integrity

## Goal

History rewrites must not destroy unrelated rows, their identities or completed compaction boundaries. A session with no eligible boundary must be recoverable within bounded provider calls, or get a bounded, actionable notice.

## Origin

Split from [Task 106](docs/plans/tasks/done/106-compaction-resilience-and-token-estimation-repair.md). Task 106 delivered 0P: an invalidated boundary is now projection-ineligible instead of locking the session with `ModelProjectionException`. This task removes the root cause (0P-F1) and bounds the fallback (0P-F2). A read-only design report is held in the coordinator's records.

## Scope

1. **0P-F1 — identity-aligned in-place rewrite** (`agent/lib/evolution/db/session_db.dart` `_replaceMessagesInDatabase`, `agent/lib/evolution/db/message_history_identity.dart` `assignIdentities`/`_reuseExisting`).
   - Rows whose `message_id` aligns are updated in place, keeping `messages.id`, even when content changes (`HistoryImagePruner`, provider-state clearing, steer stamping, metadata edits).
   - Re-insert only from the first structural divergence (insert, removal, reorder).
   - A mid-history insert without `message_id` must not take a displaced row's identity (today the inserted `HistoryHealer` row is silently lost and re-healed on every load). Duplicate `message_id`s fail loudly and roll back.
   - The tail delete is scoped to the replaced active rows, so superseded audit rows survive.
2. **Optional second slice — re-anchor boundary endpoints by `message_id`** so structural inserts inside a summarized range keep compaction. The DB record stays immutable; resolution happens in memory and fails closed on order conflicts. *Moved out of this task to [Task 118](docs/plans/tasks/118-compaction-accuracy-and-target.md); structural inserts keep the 0P ineligible-without-lockout behavior.*
3. **0P-F2 — bounded recovery summarizer** (`agent/lib/engine/context/context_compaction_engine.dart` `_generateRecoverySummary` and chunking).
   - A per-pass token budget with a safety ratio, greedy packing of atomic tool-pair groups, a deterministic text cap for oversize groups, and bounded hierarchical reduce.
   - Carry the eligible previous summary into the reduce.
   - Fail before any provider call with a new specific cause when the source exceeds the configured capacity.
   - Constants live in `agent/lib/core/config.dart`.
4. **Already-affected sessions.** Keep the 0P behavior (ineligible, record preserved, full or next-eligible projection). Never fabricate anchors; a new boundary comes from normal preflight.

## Boundaries

- No deletion of canonical history, no silent anchor repair, no DB edits to user sessions.
- `Message.providerState` and `metadata` stay opaque and round-trip byte-identically; [Task 116](docs/plans/tasks/done/116-deepseek-reasoning-replay-across-tool-history.md) relies on this.
- Tail-selection and target changes belong to [Task 118](docs/plans/tasks/118-compaction-accuracy-and-target.md).
- Run focused suites normally; `--concurrency=1` only for port-binding E2E tests.

## Gates

- [x] Red → green: a middle-row content change keeps all row ids; a mid-history insert keeps the inserted row; duplicate `message_id` rolls back; superseded rows survive replace (`agent/test/evolution/session_history_in_place_rewrite_test.dart`, `agent/test/engine/history_healer_test.dart`).
- [x] A completed boundary stays eligible after `HistoryImagePruner` pruning and provider-state clearing inside its source range (`agent/test/evolution/model_projection_builder_test.dart`).
- [x] The legacy affected shape stays ineligible with its record unchanged (0P regression lock).
- [x] Recovery for a source larger than four windows: every request is within budget and the call count is bounded; over capacity fails with zero recovery provider calls (only the original overflowing request was sent) and an actionable localized notice (`agent/test/engine/compaction_bounded_recovery_test.dart`). Skipping the ordinary request on an estimated overflow is not implemented.
- [x] Owning docs: `docs/technical/context_compaction.md`, `agent/lib/evolution/AGENTS.md`, `agent/lib/evolution/db/AGENTS.md`, engine `AGENTS.md`, `docs/agent_engine/context_compaction_design.md`, `docs/qa_maintenance/context_compaction_qa.md`.
- [x] Independent coordinator review (see Acceptance Evidence).
- [x] Delegated Sanad live acceptance on the Test Home, history integrity: rewrites inside the source range keep row ids, superseded rows and old compaction records; restart stable. The 0P live gate deferred from Task 106 (r2/r3 `not_run`) closes here.
- [x] Live bounded recovery on a session larger than four windows engaged as designed. Its completion is not proven: a recovery pass hit the provider timeout (moved to [Task 118](docs/plans/tasks/118-compaction-accuracy-and-target.md)).
- [ ] Live `/compact` on the image session followed by continuation: not run (token cost). The in-place image rewrite itself was observed live.

## Representative Data

Real sessions exported read-only from the main Home are staged privately for this task. The import procedure is in the coordinator's records. Do not import from the normal Home ad hoc, and never mutate it.

## Dependencies

- Must land before [Task 118](docs/plans/tasks/118-compaction-accuracy-and-target.md): 118's tail selection reads the boundary ranges this task stabilizes.
- Task 116 landed first; the merge with it was conflict-free.

## Acceptance Evidence — 2026-10-21

- **Coordinator review:** agent `dart analyze` clean; client `flutter analyze` clean. Focused suites: 55 passed for the in-place rewrite, bounded recovery, projection builder, history healer and pagination tests; 36 passed for the boundary repository. Writer's full agent suite: 2874 passed, 14 skipped. Client formatter and tile tests 24/24.
- **Live on a Test Home with the representative corpus (two rounds):**
  - History integrity PASS: no row-id changes, superseded rows preserved, old compaction records unchanged, exactly one boundary-invalidated log line, restart stable.
  - `HistoryImagePruner` rewrote two image rows in place with the same ids (Option A confirmed live).
  - Bounded recovery engaged as designed (3 chunks, per-pass budget 44,694, estimated source 96,218). In both rounds a recovery pass failed on a provider timeout. The failure was contained: the session stayed usable and showed a notice. Cause: the 90 s `connectTimeout` in `agent/lib/engine/adapters/provider_watchdog_config.dart` caps non-streamed compaction passes; it predates this task.
  - The image-session `/compact` step was not run because of its token cost.

## Residual Items Moved Out

- **To [Task 118](docs/plans/tasks/118-compaction-accuracy-and-target.md):**
  - The compaction-pass provider timeout above (non-streamed compaction passes capped by the 90 s `connectTimeout`).
  - The overflow-path breaker: after a failed automatic compaction, overflow compaction still runs in the same run because `_autoCompactionBlockedForRun` is not checked on the overflow path in `agent/lib/engine/agent_runner.dart`.
  - Both predate Task 117.
- **New follow-up task (to be numbered):** a blocked work item can hold the session queue. Predates Task 117.
- **Daemon E2E F.53.6** (rejected thinking preparation returns `accepted`) in `agent/e2e_test/context_compaction_daemon_e2e_test.dart` fails identically on the pre-117 base `2286267a`; it is unrelated to this task and not fixed here.
