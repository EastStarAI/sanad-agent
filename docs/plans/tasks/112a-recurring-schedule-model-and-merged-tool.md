---
title: "Task 112a — Recurring Schedule Model and Merged Schedule Tool"
status: ported onto current main (branch feat/112-port, awaiting review)
current_gate: A4
remaining_estimate: 0%
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
  created_at, updated_at, last_run_at, last_status, enabled`. The legacy `run_at` column is **kept**
  as a write-only mirror of `next_run_at` (amended on the port: no rename, see "Additive
  migration" under "Port onto current main") by an **idempotent additive migration**; pre-existing rows migrate to
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
      - `agent/lib/evolution/scheduling/schedule_model.dart` (new; one module owning the value
        object, vocabulary parsing, zone interpretation, and occurrence computation — the planned
        separate `occurrence_calculator.dart` was consolidated into it to keep the scheduling rules
        in a single pure-Dart unit)
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

- [x] Migrate the table to the D8 column set with the idempotent, guarded migration. *(Port
      amendment: `run_at` is kept and mirrored instead of renamed to `next_run_at`.)*
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

## Port onto current main (2026-10-21)

The original delivery (branch `feat/112-recurring-schedules-merged-tool`, draft PR #224) sits on
`b02b9e62`. Main then merged the Task 110/113a SRP refactor (`adc128ec`), which turned `SessionDB`
into a facade over repositories. The net 112 change (commits `094add95`, `ae75b5af`, `5b58ee12`,
`8403c13d`) was **transplanted** onto `origin/main` at `adc128ec` on branch `feat/112-port`, not
merged; the plan-77 commits on the old branch contributed no net diff and were not carried. The
original branch and PR #224 were not modified.

### Ownership map — old code to new owner

| Old location (112 branch) | Owner on the port |
|---|---|
| `SessionDB.saveScheduledTask` / `getScheduledTask` / `getAllScheduledTasks` SQL (D8 column set) | `ScheduledTaskRepository` (`agent/lib/evolution/db/scheduled_task_repository.dart`); `SessionDB` only forwards with the same signatures |
| `AgentStateDatabase` `scheduled_tasks` DDL, `_migrateScheduledTasks`, `idx_scheduled_tasks_next_run` | `AgentStateDatabase` (unchanged owner; hunk applied cleanly) |
| `Config.scheduleTimezone` | `Config` (additive getter; unrelated main changes kept) |
| `RuntimeContextBuilder` `Today:` line (B3) | `AgentContextAssembler.formatDateLine` — see 112b B-D7 amendment |
| scheduling module, `CronScheduler`, `ScheduleTaskTool`, `ToolsRegistry` alias, `Toolsets`, tests | same files; main had not touched them since `b02b9e62` |
| `interfaces_test.mocks.dart` | regenerated from current lib with a build filter (main's committed copy was already stale against main's own lib) |

**Schema version:** the agent-state database has no integer schema version; migrations are
guarded and idempotent. `_migrateScheduledTasks` runs after main's existing migrations in
`_createSchemaAndMigrate`.

### Additive migration (coordinator-required fix, 2026-10-21)

The delivered migration renamed `run_at` to `next_run_at`. That is not additive: after it, an older
agent (main today, or a rollback) on the same Home inserts and reads `run_at` and fails, and test
Homes return to main after every live run. The port now:

- never renames or drops: `run_at` stays (with its legacy `NOT NULL` on old tables), and
  `next_run_at` is added beside it; the new `CREATE TABLE` carries `run_at TEXT` (nullable), and the
  columns the pre-112 `INSERT` omits (`next_run_at`, `updated_at`) are nullable there;
- writes `run_at` = `next_run_at` on every save (`ScheduledTaskRepository`), so writes succeed on an
  old `run_at NOT NULL` table and an older agent sees current instants;
- reads only `next_run_at`; at every open, `next_run_at` takes `run_at` where they differ (only an
  older agent's write can make them differ) and `run_at` is filled where empty;
- tests (`agent/test/evolution/scheduled_tasks_migration_test.dart`): old table with rows migrates
  with both columns equal and a second run changes nothing; a write and upsert on an old
  `run_at NOT NULL` table; the pre-112 raw `INSERT`/upsert/`SELECT ... ORDER BY run_at`/`DELETE`
  copied verbatim succeed on a migrated table and on a freshly created one; rows an older agent
  wrote are resynchronized at the next open.

Verification after this fix: `fvm dart analyze` no issues; migration suite 8 passed; focused 112
suites 114 passed; full agent suite 3,075 passed, 14 skipped, 0 failed.

Rollback residue (not a column problem, recorded for the operator): an older agent reading a
migrated Home sees recurring rows as one-shot tasks at `run_at` and deletes each after it fires or
after its stale-task grace, because its code has no recurrence. Rows survive only while no older
agent runs on that Home.

### Defects found by the port review and fixed

The old implementation was re-reviewed against this record and 112b before the full suites; it was
not accepted as finished. Each fix has a regression test (the two scheduler fixes were
mutation-checked: reverting either makes its test fail).

| # | Severity | Defect | Fix |
|---|---|---|---|
| P1 | major | `GatewayManager` awaits `initialize()` before it subscribes, so a startup fire-inside-grace was persisted as `fired` and then emitted into a listener-less broadcast stream and lost (contradicts B-D2 "never a silent drop"); tests hid it by subscribing first | `CronScheduler` holds events emitted with no listener and delivers them on first subscription |
| P2 | major | the time-awareness line threw for an unsupported `SCHEDULE_TIMEZONE` (e.g. an IANA id), failing every workspace context build | single date line in `AgentContextAssembler`, invalid zone falls back to `local` |
| P3 | major | a second, workspace-only date line (`Today:`) duplicated the assembler's `Date:` line, could disagree with it near midnight under a fixed offset, was absent without a workspace, and contradicted the runtime-context rule against time stamps | one zone-aware `Date: YYYY-MM-DD (zone: X)` line; `RuntimeContextBuilder` and `docs/agent_engine/capability_runtime.md` returned to main |
| P4 | medium | no upper bound on `interval` / `in`: huge values overflowed `DateTime` arithmetic (far-past next run, `RangeError`, backward stepping in restart re-arm) | both capped at 366 days, compared in minutes before any `Duration` is built |
| P5 | medium | optional parameters sent as `null` counted as present, changing inferred action/kind or rejecting valid calls | absent values (`null`, blank, empty list) are dropped at the tool boundary and in `ScheduleDefinition.parse` |
| P6 | medium | an offset-less `at` was read in host-local time, ignoring the schedule zone (D3) | reinterpreted as wall-clock time in the schedule zone |
| P7 | medium | a partial `update` (e.g. only `time` on a weekly schedule) was re-inferred as a new shape, silently turning weekly into daily | without `kind`, update merges over the existing definition; with `kind` it replaces it (D10 clarified in the schema description) |
| P8 | minor | interval dispatch anchored on the previous run's actual (late) time, and restart re-arm on `last_run_at`, so cadence drifted by timer lateness (B-D3) | both anchor on the stored slot grid |
| P9 | minor | mixed shapes `interval`+`at`/`in` and `once`+calendar fields were accepted with fields dropped (D2) | rejected with a message naming the conflict |
| P10 | minor | `once in 30 seconds` summarized as "once in 0 minutes" | summary renders seconds; the legacy `seconds` unit stays accepted for one-shot delays only (main accepted it, B-D4) |
| P11 | minor | next-run rendering differed per zone (`local` had no designator, `Z` had milliseconds) | one format `YYYY-MM-DDTHH:MM:SS` + `Z`/`±HH:MM` |

### Port verification (2026-10-21, final tree)

| Gate | Command (from the package directory) | Result |
|---|---|---|
| Agent analyzer | `fvm dart analyze` | no issues |
| Focused 112 suites | scheduling, recovery, migration, evolution tracks, tool, registry, tools, assembler and date-zone tests | 110 passed |
| Agent full suite | `fvm dart test` | 3,071 passed, 14 skipped, 0 failed |
| Restart E2E | `fvm dart test --concurrency=1 e2e_test/durable_recovery_restart_e2e_test.dart` | 7 passed, 5 failed; F.2.2 (`schedule_task` side effect exactly once across restart) passed. The same 5 (F.2.1, F.2.6, F.2.8, F.2.11, F.2.12) fail identically on clean `origin/main` `adc128ec`, so they are pre-existing and unrelated to scheduling |
| Client analyzer | `fvm flutter analyze` | no issues |
| Client full suite | `fvm flutter test` | 1,734 passed, 1 skipped (no Client file changed) |

Not changed: the reversed fold condition in the `@visibleForTesting` `ScheduleZone.simulatedDst`
seam is dead code with a correct result (test-only); recorded here rather than altered.

## Review gate and delivery

The implementer's diff was reviewed by an independent agent before this task was closed. The
reviewer confirmed seven recorded findings with evidence and repaired them in the same worktree:

- **R1 (major)** — the simulated daylight seam was reachable production code: it is now
  `@visibleForTesting`, and a new test exercises the `local` zone across a real host daylight
  transition, skipping with a logged reason only on a host whose zone never observes one. On this
  host (`EEST+0300`) the test runs.
- **R2 (major)** — dispatch emitted the run event before persisting: the advanced instant (or the
  deletion for a one-shot task) is now persisted first, which is the at-most-once ordering. This is
  `112b` decision B-D1 and is therefore already satisfied.
- **R3 (major)** — the recorded outcome used a value outside the locked vocabulary: it is now
  `fired`, and the schema document names `fired` / `skipped_missed` / `error`.
- **R4 (minor)** — the model-facing schema now marks `action` required while legacy inference stays
  for calls persisted before the merge.
- **R5 (minor)** — the duplicated environment read is gone; `Config` owns the zone default.
- **R6 (minor)** — the mirrored `run_at` key and its read fallback are gone; only the migration
  rename and its test remain. *(Superseded on the port: the rename was replaced by an additive
  migration that keeps `run_at` as a write-only mirror; reads still use `next_run_at` only.)*
- **R7 (minor)** — the unreachable second weekly scan was removed.

Independently re-verified by the orchestrator after the review, not accepted on report alone:
`fvm dart analyze` exit 0, `fvm dart test test/capabilities test/evolution` exit 0 with 483 passed
and 6 skipped in 14s, and the repaired code confirmed present in the delivered commit.

Delivery: branch `feat/112-recurring-schedules-merged-tool` on top of
`feature/view-image-docs-plan-77`, opened as a draft pull request with the mandatory labels. The
recurring wake, recovery, and time-awareness work continues in
`docs/plans/tasks/112b-recurring-wake-integration-and-recovery.md` on the same branch and pull
request. No merge or ready-for-review transition happens without explicit authorization.
