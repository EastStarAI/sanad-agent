---
id: 117
title: Session history integrity — in-place history rewrite and bounded recovery summarizer
status: planned
gate: design-complete
created: 2026-10-21
parent_task: none (split from 106)
depends_on: []
delivery: own PR
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
2. **Optional second slice — re-anchor boundary endpoints by `message_id`** so structural inserts inside a summarized range keep compaction. The DB record stays immutable; resolution happens in memory and fails closed on order conflicts.
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

- [ ] Red → green: a middle-row content change keeps all row ids; a mid-history insert keeps the inserted row; duplicate `message_id` rolls back; superseded rows survive replace.
- [ ] A completed boundary stays eligible after `HistoryImagePruner` pruning and provider-state clearing inside its source range (`agent/test/evolution/model_projection_builder_test.dart`).
- [ ] The legacy affected shape stays ineligible with its record unchanged (0P regression lock).
- [ ] Recovery for a source larger than four windows: every request is within budget and the call count is bounded; over capacity fails with zero provider calls and an actionable localized notice.
- [ ] Owning docs: `docs/technical/context_compaction.md`, `agent/lib/evolution/AGENTS.md`, engine `AGENTS.md`.
- [ ] Independent review, then delegated Sanad live acceptance on the Test Home: a compaction plus image or tool-repair history so a rewrite lands inside the source range, then continuation; and a session larger than four windows. The 0P live gate deferred from Task 106 (r2/r3 `not_run`) closes here.

## Representative Data

Real sessions exported read-only from the main Home are staged privately for this task. The import procedure is in the coordinator's records. Do not import from the normal Home ad hoc, and never mutate it.

## Dependencies

- Must land before [Task 118](docs/plans/tasks/118-compaction-accuracy-and-target.md): 118's tail selection reads the boundary ranges this task stabilizes.
- No file overlap with Task 116; the two can run in parallel.
