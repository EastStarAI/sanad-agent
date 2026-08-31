# Evolution Database Contract

## Scope
This contract applies to `agent/lib/evolution/db/`.

## Connection Ownership
- Use one shared `AgentStateDatabase` connection for sessions, provider metadata, runtime work, notices, pending input, and route transitions.
- Repositories receive the shared connection; they must not open independent handles to the same state database.
- Cross-table aggregate mutations execute transactionally through one owning coordinator.
- Default on-disk connection construction fails closed under `dart test` unless state has been explicitly redirected; tests use in-memory or temporary state and never inherit the user's database.

## Repository Ownership
- Each table has one repository responsible for schema-facing CRUD and query semantics.
- Composition facades may delegate but must not duplicate SQL or maintain parallel state.
- Keep DTO/enums at a stable export seam only while migration requires it.
- Legacy tables and methods remain migration-only and cannot accept new production work.

## Session Data
- Workspace identity is an immutable UUID; filesystem path and display name are mutable workspace properties and must never replace it in session or runtime references.
- Persist workspace id and provider/model route as recoverable session state.
- Replacing canonical history preserves `messages.id` for the longest byte-identical prefix and rewrites only the changed suffix; appending a turn must not invalidate durable compaction ranges.
- Compaction claims persist only a redacted semantic fingerprint and occurrence for the retained-tail end; history hydration uses it to relocate the same logical anchor after suffix row ids are rewritten.
- Removing a workspace record must not cascade into sessions or messages;
  their stable workspace reference remains historical conversation metadata.
- Preserve raw request identity on accepted user messages and route transitions.
- Persist `message_id`, `turn_id`, `history_status`, `input_kind`, and
  `origin_message_id` as first-class message columns. Normal reads return
  `active` rows only; superseded rows stay stored.
- `sessions.history_revision` is independent from execution and route revisions. Soft rewind revalidates the latest active root and accepts the replacement user record in one transaction with that compare-and-swap.
- Session lineage (`lineage_id`, `parent_session_id`, fork target identities,
  `fork_sequence`) is independent of session lifetime. Deleting a parent
  nulls `parent_session_id` on children and never cascades to child rows.
- Canonical user acceptance alone advances session-list user-message ordering.
- Title compare-and-set, deletion, and route transitions remain atomic with their owning session data.

## Data Safety
- Redact nested durable payloads, tool arguments/results, recovered text, and event metadata before SQLite writes where contracts require redaction.
- Secrets never enter state database tables.
- Partial unique active-work constraints remain final enforcement and must not escape as raw SQLite errors.
