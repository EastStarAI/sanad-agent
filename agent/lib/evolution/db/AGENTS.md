# Evolution Database Contract

## Scope
This contract applies to `agent/lib/evolution/db/`.

## Connection Ownership
- Use one shared `AgentStateDatabase` connection for sessions, provider metadata, runtime work, notices, pending input, route transitions, and maintenance timestamps.
- Repositories receive the shared connection; they must not open independent handles to the same state database.
- Cross-table aggregate mutations execute transactionally through one owning coordinator.
- `AgentStateDatabase` owns page-layout statistics and `VACUUM`, and must reject `VACUUM` while it holds an open transaction.

## Repository Ownership
- Each table has one repository responsible for schema-facing CRUD and query semantics.
- Composition facades may delegate but must not duplicate SQL or maintain parallel state.
- Keep DTO/enums at a stable export seam only while migration requires it.
- Legacy tables and methods remain migration-only and cannot accept new production work.
- `AgentMaintenanceStateRepository` is the sole owner of `agent_maintenance_state` success timestamps.
- `AgentStateMaintenanceService` owns startup maintenance policy: orphan cleanup timing, 14-day terminal work-item retention, prune/vacuum throttles, and vacuum thresholds. It runs once per daemon boot and must not become a user-facing setting surface.

## Session Data
- Workspace identity is an immutable UUID; filesystem path and display name are mutable workspace properties and must never replace it in session or runtime references.
- Persist workspace id and provider/model route as recoverable session state.
- Preserve raw request identity on accepted user messages and route transitions.
- Canonical user acceptance alone advances session-list user-message ordering.
- Title compare-and-set, deletion, and route transitions remain atomic with their owning session data.

## Data Safety
- Redact nested durable payloads, tool arguments/results, recovered text, and event metadata before SQLite writes where contracts require redaction.
- Secrets never enter state database tables.
- Partial unique active-work constraints remain final enforcement and must not escape as raw SQLite errors.
