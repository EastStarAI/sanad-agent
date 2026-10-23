# Agent Evolution Contract

## Scope
This contract applies to `agent/lib/evolution/`.

## Evolution Ownership
- Own session/message persistence, title generation, scheduling, memory, and durable runtime state.
- Keep interface admission, engine history, capability execution, and protocol delivery outside this domain.
- Durable tables have one repository owner and share one agent-state database connection.
- `AttachmentStore` owns session/message-scoped attachment bytes beneath the Agent state home. Callers stream only through bounded create/write/commit/cancel operations; generated opaque identities—not caller filenames—derive paths. Promotion requires verified bytes and existing same-session message ownership.
- Attachment lookup is an exact `(session_id, attachment_id)` grant. Public projections never contain resolved paths. Session deletion removes metadata and bytes idempotently; startup cleanup removes partial files, missing-message metadata, and unowned promoted directories.

## Sessions and Titles
- Persist every accepted interaction through `SessionManager` with workspace and selected model as first-class session state.
- History records keep stable `message_id` and `turn_id`. Normal session history exposes active records only; soft rewind never deletes the original attempt.
- History rewrites align rows by `message_id`, never by content: identity-aligned rows keep `messages.id` even when their content changes, only a structural divergence re-inserts the active suffix, superseded rows are never deleted by a rewrite, and duplicate identities fail loudly (rules in `agent/lib/evolution/db/AGENTS.md`). Stored `providerState` and `metadata` round-trip byte-identically.
- Conversation-history search is Agent-owned and separate from ordinary session pagination. It may search titles plus active visible user/assistant content (including visible thoughts, excluding reasoning and tools), returns one bounded hit per session, and issues history anchors rather than exposing private or internal message payloads.
- Forked sessions keep an independent `lineage_id`. Parent deletion nulls `parent_session_id` and leaves child history intact. Fork materialization also clones terminal compaction lifecycle rows inside the selected prefix with child-owned identities and remapped message ranges, so the child preserves both visible history and the latest effective model projection.
- Automatic placeholders persist as pending title ownership; explicit, generated, fallback, manual, and migrated titles are final.
- Pending sessions remain eligible for intelligent title generation after a committed assistant response, including resumed turns, and interrupted pending work is recovered from persisted history at daemon startup.
- Start live title generation only after terminal commit/delivery and pass the immutable successful-turn LLM route.
- Title work outlives the active run but writes through compare-and-set against both the captured placeholder and pending state; rename, delete, or newer title wins.
- Emit session update only after compare-and-set succeeds.
- Clean title output to the user's language, preserve the 3–7 word request and 80-character storage cap, and remove reasoning/prefix/quote artifacts.

## Compaction boundaries (Plan 53b)
- `session_compaction_operations` (B1) is the sole owner of durable compaction lifecycle, internal summaries, and range metadata.
- Canonical `messages` rows are never deleted or replaced by compaction; model projection reads the latest eligible completed boundary plus live message rows.
- `messages.id` endpoints are activation-time bounds for source/tail ranges; globally allocated ids may contain numeric gaps after edit/retry, so projection walks the session's ordered rows between those endpoints. A hashed semantic tail-end anchor plus occurrence preserves lifecycle placement when suffix rewrite replaces that row id. `sessions.history_revision` (B1) provides CAS for snapshot activation.
- `CompactionBoundaryRepository` owns claim, terminal transition, and latest-boundary reads; see `docs/technical/context_compaction.md` §8.
- Completed boundary identity, ranges, summary, route, and estimates are immutable. The repository binds `provider_confirmed_request_tokens_after` and additive diagnostics exactly once to the reserved first same-route provider response using that boundary; unreserved, mismatched, missing, or later responses cannot overwrite the receipt.
- The claim transaction also binds `last_pre_compaction_call` once from the newest active assistant usage snapshot (`context_usage` authoritative when present without splicing mutable turn totals), recording only provider-reported identity/usage plus an explicit applicability and reason; without current-material comparison applicability fails closed to `unknown` with `material_unverified`. Completion, failure, restart, and later grown calls carry it unchanged; unknown stays unknown rather than falling back to an older call, zero, or an estimate.
- `SessionHistoryRevisionRepository` bumps `sessions.history_revision` on canonical message insert/replace; compaction activation CAS depends on it.
- `ModelProjectionBuilder` (B2) in `agent/lib/evolution/compaction/` builds ephemeral provider conversation payloads: one projected user summary anchor, verbatim retained tail, and post-boundary messages. System/runtime context stays in `AgentContextAssembler`.
- `CompactionActivationService` (B3) completes or fails a started operation atomically, bumps projection revision only after successful commit, and publishes one boundary change for interface consumers; it does not drain queued work.
- `CanonicalConversationTimeline` / `SessionDB.getPersistedMessages()` serve UI and audit; they never filter at compaction boundaries.
- Missing any summarized-source endpoint or the retained-tail start in a completed boundary marks that boundary projection-ineligible and emits an invalidation diagnostic, projecting full or next eligible history without throwing ModelProjectionException. A surviving tail start with a replaced tail end remains eligible and projects the replacement suffix. Numeric gaps between present endpoints are valid and must not be synthesized or rejected. `history_revision` is a monotonic write counter; `history_revision_future` means the boundary claims a revision ahead of live history (restore/rollback).

## Scheduling
- Persist scheduled tasks and their per-run history; restore both on startup.
- `CronScheduler` is the single writer of `scheduled_tasks` and `scheduled_task_runs`; tools and other callers read through it and never write either repository directly. Cancel and update are owner-scoped to the originating session; listing is device-wide.
- `owner_kind` decides who may mutate a row: a model-owned row is mutable by its owning conversation and by device-owner authority, a user-owned row by device-owner authority only. The kind is set by the receiving command family and is never read from a payload, so a model turn cannot widen its own scope.
- `owner_kind` is written once by the schedule's insert and is immutable afterwards: no save and no repository method may change it, so a re-save can never hand a user-owned schedule to the model path. `name`, `conversation_mode`, `run_session_id`, `workspace_id`, `provider_instance_id`, and `model` are insert-only for the same reason — the scheduler re-saves a schedule with legacy parameters after every run and must preserve them byte-for-byte — and `ScheduledTaskRepository.updateScheduleSettings` is the single edit path for those six.
- A run row starts `running` before the dispatch event leaves the scheduler and reaches exactly one terminal state; a terminal row is never rewritten. Retention is bounded on write — the newest 200 rows per schedule and nothing older than 90 days — and never on read.
- A terminalized failed run reports its outcome through `ScheduleRunFailureSink`, injected at the composition root. The scheduler never depends on the gateway layer, and the publisher of the client-facing notice lives there, not here.
- A recurring dispatch persists the advanced next instant and outcome before it emits the run event (at-most-once). A run event emitted before the gateway subscribes is held and delivered on subscription, never silently dropped.
- Scheduled events preserve originating session identity and enter through normal gateway/orchestrator admission. A schedule dispatch is always its own turn — immediate when the conversation is idle, queued behind the active turn when it is busy — and never a mid-turn steer: its payload carries `delivery_intent='queue'` and the run id as `request_id`, so the turn commits the user message the run row anchors on.
- Scheduler and curator tests remain isolated from provider-instance routing unless explicitly under test.

## Suspension Boundary
- Persist execution-suspending tool calls before waiting.
- Decision acceptance is a conditional single-winner transition and survives daemon/client restart.
- A matching unresolved suspension remains the active waiting owner across restart until a decision claims it or Stop clears it.
- Store enough tool, identity, origin, and continuation context to redisplay and resume through normal runtime paths.
