# Evolution Database Contract

## Scope
This contract applies to `agent/lib/evolution/db/`.

## Schema Ownership
- `AgentStateDatabase` owns the connection and applies the schema; the table DDL and every in-place additive migration live in exactly one module under `agent/lib/evolution/db/schema/`: `sessions_messages_schema.dart`, `attachments_schema.dart`, `scheduling_schema.dart`, `workspaces_schema.dart`, `runtime_work_schema.dart`, `provider_schema.dart`, `compaction_schema.dart`, and `maintenance_schema.dart`. Legacy workspace identity migration lives in `agent/lib/evolution/db/migrations/workspace_identity_migration.dart`.
- `AgentStateDatabase._createSchemaAndMigrate` is the single ordered list that calls those owners. Preserve the call order and the statement order inside each module: the emitted DDL, the table order, and the row migrations must stay byte-identical, and `agent/test/evolution/agent_state_schema_snapshot_test.dart` pins the result for fresh and legacy databases.
- `schema/schema_migration_support.dart` is the one owner of `safeAddColumn`, `tableExists`, `columnExists`, and `isBusyOrLocked`. A schema module must not grow its own column-existence probe, and lock contention must never be swallowed as an already-applied migration.
- No module introduces `PRAGMA user_version`, reorders the migration sequence, or rebuilds a table outside its owning migration (decision A3).

## Connection Ownership
- Use one shared `AgentStateDatabase` connection for sessions, provider metadata, runtime work, notices, pending input, route transitions, and maintenance timestamps.
- Repositories receive the shared connection; they must not open independent handles to the same state database.
- Cross-table aggregate mutations execute transactionally through one owning coordinator.
- Default on-disk connection construction fails closed under `dart test` unless state has been explicitly redirected; tests use in-memory or temporary state and never inherit the user's database.
- `AgentStateDatabase` owns page-layout statistics and `VACUUM`, and must reject `VACUUM` while it holds an open transaction.
- `AgentStateDatabase.readOnlyAtPath` is the only inspection handle for a Home another runtime may own: SQLite `OpenMode.readOnly` plus `PRAGMA query_only`, with no bootstrap, schema creation, migration, or WAL switch. Inspection readers must tolerate a missing or older schema rather than migrate it.

## Concurrency Policy
- On-disk connections run in WAL journal mode with a 5000ms `busy_timeout`. In-memory connections keep the 5000ms `busy_timeout` only (SQLite cannot enable WAL for `:memory:`).
- Outer transactions, schema initialization, migrations, and database-wide `VACUUM` wrap their work in a bounded busy-retry loop: up to 3 retries with progressive backoff (50/100/200ms) and a `WARNING` log per retry, rethrowing the underlying `SqliteException` on exhaustion.
- Nested transactions use SQLite savepoints inside the retry boundary and must never retry independently.

## Repository Ownership
- Each table has one repository responsible for schema-facing CRUD and query semantics.
- Composition facades may delegate but must not duplicate SQL or maintain parallel state.
- Session database responsibilities are decomposed into cohesive owners behind the `SessionDB` facade:
  - `SessionRepository`: session lifecycle, metadata, titles, and workspace records.
  - `SessionMessageRepository`: message replace, append and read, history pages and projection, and originating tool-call lookup. It is the only owner of the history-rewrite algorithm.
  - `ScheduledTaskRepository`: every `scheduled_tasks` read and write (create/upsert, single read, ordered list, delete) plus the schema-tolerant `inspectScheduledTasks` read (PRAGMA/SELECT only; missing and pre-112 tables) used by read-only inspection; the table schema and its additive migration live in `schema/scheduling_schema.dart` and stay reachable as `AgentStateDatabase.migrateScheduledTasks` for the migration suites.
  - `ScheduledTaskRepository` write authority: `owner_kind` is written once at insert and is immutable afterwards — no save and no method may change it. The six editable settings (`name`, `conversation_mode`, `run_session_id`, `workspace_id`, `provider_instance_id`, `model`) are insert-only in `saveScheduledTask`, so a scheduler re-save with legacy parameters preserves them byte-for-byte, and `updateScheduleSettings` (omit keeps, null clears, `owner_kind` never touched) is their single edit path.
  - `ScheduledTaskRunRepository`: every `scheduled_task_runs` read and write — the `running` row a dispatch writes first, the user-message anchor, the compare-and-set terminal transition, bounded keyset pages, write-side retention pruning, and per-schedule deletion. The table DDL is owned by the same schema module as the schedules it belongs to, and deleting a schedule composes both deletes in one transaction.
  - `SuspendedCheckpointRepository`: suspended checkpoints and work-item state.
  - `SessionForkCommitRepository`: fork, soft-rewind, and root-user commit records.
  - `SessionDB`: delegating facade preserving the public API surface; it holds no SQL of its own and must never carry a second copy of a repository algorithm.
- Keep DTO/enums at a stable export seam only while migration requires it.
- Legacy tables and methods remain migration-only and cannot accept new production work.
- `WorkspaceSecurityPolicyRepository` (`capabilities/permissions/`) is the sole owner of `workspace_security_policies`; `WorkspacesSchema.applySecurityPolicies` only creates the table. The table is additive and rollback-safe: never rename or drop its columns. Workspace removal deletes the workspace's policy row in the same transaction (`LocalWorkspaceRuntimeService.removeWorkspace` on the `SessionDB.state` connection); `exec_root:` rows are kept.
- `UserSecretMetadataRepository` (`evolution/db/user_secret_metadata_repository.dart`) is the sole owner of `user_secret_metadata`: the non-secret metadata (description, arrival source, created/updated instants) of a secret whose value lives only in the vault's `custom:` namespace. Its DDL lives in `schema/user_secrets_schema.dart`, applied last so no earlier module moves. The table holds no value, no hash of one, and no prefix of one; the repository likewise stores and returns no value, and `UserSecretCatalog` plus the Task 84 acquisition path reach it only through its methods.
- `AgentMaintenanceStateRepository` is the sole owner of `agent_maintenance_state` success timestamps and the pending-vacuum marker.
- `AgentStateMaintenanceService` owns post-ready maintenance policy: idle/grace gating, bounded orphan and terminal deletion batches, 14-day retention, prune/vacuum throttles, and vacuum thresholds. It must not perform cleanup before daemon readiness or expose user-facing settings.
- Full `VACUUM` is never a startup or serving-path operation. The service marks qualifying work pending and may execute it only at the controlled-exit boundary after restart drain and response flush.

## Session Data
- Workspace identity is an immutable UUID; filesystem path and display name are mutable workspace properties and must never replace it in session or runtime references.
- Persist workspace id and provider/model route as recoverable session state.
- Replacing canonical history (owned by `SessionMessageRepository`; both `SessionDB.replaceMessages` and `replaceMessagesInTransaction` only delegate to it) aligns rows by `message_id`, never by content: every identity-aligned row whose stored data differs is updated in place through `MessageHistoryIdentity.persist(sqliteId:)` and keeps `messages.id`, so content transforms (image pruning, provider-state clearing, steer stamping, metadata) never invalidate durable compaction ranges. Only the first structural divergence (insert, removal, reorder, identity change) deletes and re-inserts the remaining active rows; that delete is scoped to active rows and never removes superseded audit rows. Legacy rows without a stored `message_id` align by position only with a message that has no explicit id.
- The terminal commit is the only writer of the terminal stamp (`terminal_work_item_id`, `terminal_generation`). An in-place stamp bumps `history_revision`, and a history rewrite must carry a stored stamp forward to a same-`message_id` replacement that lacks it; a rewrite never erases a stamp.
- `TerminalAssistantClassifier` is the single definition of a terminal assistant reply (stamp, or no-tool non-steer assistant whose next active session row is absent or a root user input). History delivery and session search use it; no caller may classify by page position or by "newest assistant" alone.
- Positional identity reuse for an incoming message without `message_id` must not take an id that another incoming message carries explicitly. Duplicate `message_id`s in one replacement throw before any write and roll back.
- Anchored history hydration begins at the anchor's active persistence row and reads newer rows in chronological order. Older `has_more`/`next_cursor` and newer `has_newer`/`next_newer_cursor` are independent, opaque, fingerprinted keyset directions; an oldest-row anchor must retain following context and remain forward-pageable to the authoritative tail.
- A failed compaction operation records its summarization attempts and billed usage in the same accounting columns as a completed one; its projection estimate columns stay NULL.
- Compaction claims persist only a redacted semantic fingerprint and occurrence for the retained-tail end; history hydration uses it to relocate the same logical anchor after suffix row ids are rewritten.
- Removing a workspace record must not cascade into sessions or messages;
  their stable workspace reference remains historical conversation metadata.
- Preserve raw request identity on accepted user messages and route transitions. An automatic-failover transition also stores `anchor_message_id`, the newest active row's `message_id` at commit time, so history can place the notice where it appeared live; `message_id` (not `messages.id`) keeps the anchor valid across in-place rewrites.
- `SessionMessageRepository` owns the narrow lookups history placement needs (`latestActiveMessageId`, `activeRowIdForMessageId`, `legacyRouteNoticeAnchorRowId`, `lastActiveForkCopiedRowId`). Post-fork rows never carry `origin_message_id`, so the newest active copied row is the end of a child's copied prefix.
- Persist `message_id`, `turn_id`, `history_status`, `input_kind`, and
  `origin_message_id` as first-class message columns. Normal reads return
  `active` rows only; superseded rows stay stored.
- `sessions.history_revision` is independent from execution and route revisions. Soft rewind revalidates the latest active root and accepts the replacement user record in one transaction with that compare-and-swap.
- Soft-rewind attachment association commits in that same transaction: every replacement attachment must match exactly one staged row or a retained row owned by the target message in the same session. Missing, foreign, or stale associations reject and roll back the entire admission, preserving history, revision and previous attachment ownership.
- Originating tool-call resolution across page-budget boundaries queries strictly within the same session id by turn id or tool-call id, returning only immutable tool name, call id, and raw arguments without loading full history or crossing session boundaries.
- Session lineage (`lineage_id`, `parent_session_id`, fork target identities,
  `fork_sequence`) is independent of session lifetime. Deleting a parent
  nulls `parent_session_id` on children and never cascades to child rows.
- A materialized fork copies every terminal compaction lifecycle event ordered inside its selected active prefix. Each child operation owns a new compaction id and ranges remapped to child message rows in the same transaction; started or post-target operations are never copied.
- Canonical user acceptance alone advances session-list user-message ordering.
- Title compare-and-set, deletion, and route transitions remain atomic with their owning session data.

## Data Safety
- Redact nested durable payloads, tool arguments/results, recovered text, and event metadata before SQLite writes where contracts require redaction.
- Secret values never enter state database tables. `user_secret_metadata` carries metadata only; a value stays in the vault's `custom:` namespace, and the metadata owner has no API that accepts one.
- Partial unique active-work constraints remain final enforcement and must not escape as raw SQLite errors.
