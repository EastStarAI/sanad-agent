# Agent Evolution Contract

## Scope
This contract applies to `agent/lib/evolution/`.

## Evolution Ownership
- Own session/message persistence, title generation, scheduling, memory, and durable runtime state.
- Keep interface admission, engine history, capability execution, and protocol delivery outside this domain.
- Durable tables have one repository owner and share one agent-state database connection.

## Sessions and Titles
- Persist every accepted interaction through `SessionManager` with workspace and selected model as first-class session state.
- Automatic placeholders persist as pending title ownership; explicit, generated, fallback, manual, and migrated titles are final.
- Pending sessions remain eligible for intelligent title generation after a committed assistant response, including resumed turns, and interrupted pending work is recovered from persisted history at daemon startup.
- Start live title generation only after terminal commit/delivery and pass the immutable successful-turn LLM route.
- Title work outlives the active run but writes through compare-and-set against both the captured placeholder and pending state; rename, delete, or newer title wins.
- Emit session update only after compare-and-set succeeds.
- Clean title output to the user's language, preserve the 3–7 word request and 80-character storage cap, and remove reasoning/prefix/quote artifacts.

## Compaction boundaries (Plan 53b)
- `session_compaction_operations` (B1) is the sole owner of durable compaction lifecycle, internal summaries, and range metadata.
- Canonical `messages` rows are never deleted or replaced by compaction; model projection reads the latest eligible completed boundary plus live message rows.
- `messages.id` is the durable identity for source/tail ranges; `sessions.history_revision` (B1) provides CAS for snapshot activation.
- `CompactionBoundaryRepository` owns claim, terminal transition, and latest-boundary reads; see `docs/technical/context_compaction.md` §8.
- Completed boundary identity, ranges, summary, route, and estimates are immutable. The repository alone may reconcile `provider_confirmed_request_tokens_after` exactly once from null to the first same-route provider response; later responses are no-ops.
- `SessionHistoryRevisionRepository` bumps `sessions.history_revision` on canonical message insert/replace; compaction activation CAS depends on it.
- `ModelProjectionBuilder` (B2) in `agent/lib/evolution/compaction/` builds ephemeral provider conversation payloads: one projected user summary anchor, verbatim retained tail, and post-boundary messages. System/runtime context stays in `AgentContextAssembler`.
- `CompactionActivationService` (B3) completes or fails a started operation atomically, bumps projection revision only after successful commit, and publishes one boundary change for interface consumers; it does not drain queued work.
- `CanonicalConversationTimeline` / `SessionDB.getPersistedMessages()` serve UI and audit; they never filter at compaction boundaries.
- Partial row-id gaps in the newest completed boundary reject projection via `ModelProjectionException`; fully superseded ranges skip to an older eligible boundary or canonical fallback.

## Scheduling
- Persist scheduled tasks and restore them on startup.
- Scheduled events preserve originating session identity and enter through normal gateway/orchestrator admission.
- Scheduler and curator tests remain isolated from provider-instance routing unless explicitly under test.

## Suspension Boundary
- Persist execution-suspending tool calls before waiting.
- Decision acceptance is a conditional single-winner transition and survives daemon/client restart.
- A matching unresolved suspension remains the active waiting owner across restart until a decision claims it or Stop clears it.
- Store enough tool, identity, origin, and continuation context to redisplay and resume through normal runtime paths.
