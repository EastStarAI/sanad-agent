# Evolution Database Contract

## Scope
This contract applies to `agent/lib/evolution/db/`.

## Connection Ownership
- Use one shared `AgentStateDatabase` connection for sessions, provider metadata, runtime work, notices, pending input, and route transitions.
- Repositories receive the shared connection; they must not open independent handles to the same state database.
- Cross-table aggregate mutations execute transactionally through one owning coordinator.

## Repository Ownership
- Each table has one repository responsible for schema-facing CRUD and query semantics.
- Composition facades may delegate but must not duplicate SQL or maintain parallel state.
- Keep DTO/enums at a stable export seam only while migration requires it.
- Legacy tables and methods remain migration-only and cannot accept new production work.

## Session Data
- Workspace identity is an immutable UUID; filesystem path and display name are mutable workspace properties and must never replace it in session or runtime references.
- Persist workspace id and provider/model route as recoverable session state.
- Removing a workspace record must not cascade into sessions or messages;
  their stable workspace reference remains historical conversation metadata.
- Preserve raw request identity on accepted user messages and route transitions.
- Canonical user acceptance alone advances session-list user-message ordering.
- Title compare-and-set, deletion, and route transitions remain atomic with their owning session data.

## Data Safety
- Redact nested durable payloads, tool arguments/results, recovered text, and event metadata before SQLite writes where contracts require redaction.
- Secrets never enter state database tables.
- Partial unique active-work constraints remain final enforcement and must not escape as raw SQLite errors.
