---
title: "Task 112a — Recurring Schedule Model and Merged Schedule Tool"
status: pending
current_gate: A0
remaining_estimate: 100%
depends_on: "None"
evidence_id: "sched-recurrence"
evidence_fingerprint: "sha256:0e9237785d2fa58cbcfc8a8856c65d33452919bba2bd900701c4db22cf325bd1"
file_budget: 14
---

# Task 112a — Recurring Schedule Model and Merged Schedule Tool

Base branch: this task starts from `feature/view-image-docs-plan-77` (the tool-result model and the
typed execution boundary already landed there). Do not modify the closed task files under
`docs/plans/tasks/done/`; this task records its own decisions here.

## Goal

The agent can create, list, update, and cancel durable recurring schedules through one
action-oriented tool, with a bounded schedule vocabulary, an explicit timezone rule, and
storage that survives a daemon restart.

## Locked decisions

- **D1 — One tool, typed result.** The model-facing scheduling surface becomes a single
  action-oriented tool named `schedule_task` with actions `create | list | cancel | update`.
  It implements `executeResult` as the authoritative boundary required by `BaseTool` and keeps
  `execute` only as the thin `displayText` projection the other tools use. The former
  `list_scheduled_tasks` tool file is removed; its name must stay resolvable through a
  **lookup-only alias** in `ToolsRegistry`, because `ToolExecutionCoordinator` resolves a tool by
  `registry.getTool(toolCall.name)` and persisted/replayed tool-call identity must keep working.
  Aliases are lookup-only: they never add a second entry to `allTools`/`allSpecs` and never appear
  in the model-facing catalog.
- **D2 — Bounded schedule vocabulary.** No general cron expressions. Accepted shapes:
  - `once`: `at` absolute ISO-8601, or `in <n> <minutes|hours|days>` (default when no recurrence
    is supplied; existing behavior).
  - `interval`: `every <n> <minutes|hours|days>` — elapsed-time semantics.
  - `daily`: `time` as `HH:MM` wall clock.
  - `weekly`: `weekdays` (one or more of `mon..sun`) plus `time`.
  - `monthly`: `day_of_month` (1..31) plus `time`.
  Any other shape is rejected with an error listing the accepted forms. `days` exists only in
  `interval` and `in`; calendar shapes use wall-clock `time`.
- **D3 — Timezone.** A schedule carries a zone: `local` (default) or a fixed UTC offset
  (`Z`, `+HH:MM`, `-HH:MM`). The agent-level default comes from the environment/config key
  `SCHEDULE_TIMEZONE` (default `local`) and is persisted with each schedule at creation, so a later
  config change cannot reinterpret an existing schedule. Calendar recurrence
  (`daily`/`weekly`/`monthly`) is computed in the schedule's zone; `interval` measures elapsed
  time. IANA zone identifiers are rejected in this release with a clear message; `local` uses the
  host operating-system zone rules through Dart local `DateTime` (no timezone/IANA package here).
- **D4 — No end condition.** Recurring schedules repeat until canceled: no repeat-count and no
  end-date parameter in this release.
- **D5 — A schedule has an owner.** `create` requires a session context; without one it fails with
  a clear error. The previous `cron-session` silent fallback is removed.
- **D6 — Mutation is owner-scoped, visibility is device-wide.** `list` returns every schedule on
  this agent and labels each with its owning conversation. `cancel` and `update` are allowed only
  for schedules owned by the calling session; a foreign schedule is denied with a visible error
  naming the owning conversation, never a silent no-op.
- **D7 — Single writer.** Every schedule mutation goes through `CronScheduler`. Tools never write
  the persistence layer directly.
- **D8 — Storage.** `scheduled_tasks` becomes the durable source of truth with columns:
  `id, task, session_id, kind, interval_minutes, at_time, weekdays, month_day, zone, next_run_at,
  created_at, updated_at, last_run_at, last_status, enabled`. The legacy `run_at` column is renamed
  to `next_run_at` by an **idempotent additive migration**; pre-existing rows migrate to
  `kind='once'`, `zone='local'`, `enabled=1`, `next_run_at = old run_at`. Use the repository's
  existing guarded-migration pattern and make a second run a no-op.
- **D9 — Bounded output.** Tool output always exposes the schedule id plus a human recurrence
  summary, the next instant rendered in the schedule's zone, and the last status. No internal
  bookkeeping fields. `list` is capped (default 50) with an explicit truncation note. Errors use
  `isError` with a `ToolResultErrorCode`, not free-form prefixes alone.
- **D10 — `update` scope.** `update` may change the `task` text and/or the schedule definition and
  recomputes the next instant. `pause`/`resume`, `run-now`, and delivery/reporting targets are out of
  scope.
- **D11 — Out of scope.** The `sanad schedule` CLI stub, any Client (Flutter) surface, and any
  client-facing settings UI. The timezone setting is agent-side only in this release.

## Gates

### A0 — Discovery

- [x] Read `agent/AGENTS.md`, `agent/lib/capabilities/AGENTS.md`, and the nearest contracts for every
      directory touched (`agent/lib/evolution/`, `agent/lib/capabilities/registry/`).
- [x] Read the current scheduling implementation end to end: `agent/lib/evolution/cron_scheduler.dart`,
      both scheduling tools, `agent/lib/capabilities/registry/toolsets.dart`,
      `agent/lib/capabilities/registry/tools_registry.dart`,
      `agent/lib/engine/runtime/tool_execution_coordinator.dart` (tool resolution + typed result
      contract), and the `scheduled_tasks` section of `agent/lib/evolution/db/session_db.dart` and
      `agent/lib/evolution/db/agent_state_database.dart`.
- [x] Enumerate the affected test surface: `agent/test/evolution/evolution_tracks_test.dart`,
      `agent/test/capabilities/tools_test.dart`, `agent/test/capabilities/registry_test.dart`,
      `agent/test/interfaces/interfaces_test.mocks.dart` (generated), and
      `agent/e2e_test/durable_recovery_restart_e2e_test.dart`.
- [x] Record the A0 file list in this task before editing:
      - `agent/lib/evolution/scheduling/schedule_model.dart` (new)
      - `agent/lib/evolution/scheduling/occurrence_calculator.dart` (new)
      - `agent/lib/evolution/cron_scheduler.dart`
      - `agent/lib/evolution/db/session_db.dart`
      - `agent/lib/evolution/db/agent_state_database.dart`
      - `agent/lib/capabilities/tools/schedule_task_tool.dart`
      - `agent/lib/capabilities/tools/list_scheduled_tasks_tool.dart` (deleted)
      - `agent/lib/capabilities/registry/toolsets.dart`
      - `agent/lib/capabilities/registry/tools_registry.dart`
      - `agent/lib/core/config.dart`
      - `agent/test/evolution/scheduling_test.dart` (new)
      - `agent/test/evolution/evolution_tracks_test.dart`
      - `agent/test/capabilities/tools_test.dart`
      - `agent/test/capabilities/registry_test.dart`
      - `agent/test/interfaces/interfaces_test.mocks.dart`
      - `docs/technical/agent_database_schema.md`
      - `docs/product/features.md`


### A1 — Scheduling model and occurrence computation

- [x] Add a pure scheduling module under `agent/lib/evolution/scheduling/` owning: the schedule value
      object (kind + parameters + zone), parsing/validation of the D2 vocabulary, canonical
      serialization for storage, a human recurrence summary, and next-occurrence computation.
- [x] The same module owns zone interpretation: `local` resolves through Dart local `DateTime`; a
      fixed offset resolves arithmetically. Both directions of a daylight transition must keep the
      intended local wall-clock time; the gap/fold instants are pinned by test.
- [x] Reject invalid input explicitly: unknown kind, malformed `HH:MM`, out-of-range weekday,
      `day_of_month` outside 1..31, non-positive interval, `interval` mixed with calendar fields, and
      IANA zone ids.
- [x] Unit tests cover at least: `once` (absolute, relative, in the past), `interval` (anchored on a
      supplied previous run), `daily` across spring-forward and fall-back, `weekly` with multiple
      weekdays, and `monthly` day 31 skipping months that lack it.

### A2 — Durable storage and migration

- [x] Migrate the table to the D8 column set with the idempotent, guarded migration and the
      `run_at` → `next_run_at` rename.
- [x] Update the persistence methods that read/write schedules to the new column set, keeping the
      table's single owner (`agent/lib/evolution/db/session_db.dart`).
- [x] Regenerate `agent/test/interfaces/interfaces_test.mocks.dart` if a mocked signature changes.
- [x] Tests cover: a fresh database; an old-shape database migrating to `once`/`local`/`enabled`
      while keeping its instant; and a second migration run being a no-op.

### A3 — Merged action-oriented tool

- [x] Replace the two tools with one `ScheduleTaskTool` exposing `action` plus the D2/D3 fields,
      per-action required-field validation, `executeResult` as the authoritative boundary, and the
      D9 bounded output.
- [x] Add the lookup-only alias resolution in `ToolsRegistry` (D1) with a comment stating why it
      exists, and make `getTool`, `isRestartReplaySafe`, and `getSpec`-based lookups honor it.
- [x] Delete `list_scheduled_tasks_tool.dart` and update `Toolsets.coreTools`; exactly one
      scheduling tool must appear in the catalog.
- [x] Tests cover: each action's success path; per-action validation errors; `cancel` of an unknown
      id; `cancel` denied for a foreign session; `update` recomputing the next instant; listing an
      empty set; and alias lookup success while the catalog stays single.

### A4 — Documentation and verification

- [x] Update `docs/technical/agent_database_schema.md` (`scheduled_tasks` table specification) to the
      D8 column set and the migration note.
- [x] Update the scheduling section of `docs/product/features.md`: recurring schedules are now
      supported, with the bounded vocabulary and the `local`/fixed-offset timezone rule; remove the
      sentence stating recurring cron-style schedules are not supported.
- [x] Report the gate outcome with exact commands, preserved exit status, and bounded output.

## Acceptance criteria

- [x] Creating a `daily` schedule for `05:00` with `local` zone persists exactly one row with
      `kind='daily'`, `enabled=1`, and `next_run_at` strictly in the future, and the tool result
      contains the schedule id.
- [x] `list` returns that id with a recurrence summary and the next instant rendered in the
      schedule's zone, and labels the owning conversation.
- [x] `cancel` with an unknown id returns an error result and mutates nothing.
- [x] `cancel` from a non-owning session is denied, and the row plus its in-memory timer are
      unchanged.
- [x] `create` without a session context fails and persists nothing.
- [x] A schedule created with an IANA zone id is rejected with a message naming the accepted forms.
- [x] An old-shape database migrates without data loss and a second migration run changes nothing.
- [x] The model-facing catalog contains exactly one scheduling tool while the legacy name still
      resolves for lookup.
- [x] `fvm dart analyze` is clean and the focused test files pass with preserved exit status.

## Definition of Done

- [x] `cd agent && set -o pipefail; fvm dart analyze 2>&1 | tail -5`
- [x] `cd agent && set -o pipefail; fvm dart test test/capabilities test/evolution 2>&1 | tail -5`
- [x] Documentation updated in this change (A4) and no owning `AGENTS.md` statement left stale.
- [x] Diff reviewed for scope: no Client change, no CLI stub change, no unrelated cleanup, and no
      edit to files under `docs/plans/tasks/done/`.
- [x] **Do not commit.** The orchestrator reviews the diff, re-runs the gates, and commits.
- [x] Report: status (`Succeeded` / `Failed` / `Unsure`), touched files, exact commands with
      outcomes, skipped coverage, and unresolved uncertainty.
