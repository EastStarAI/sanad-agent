---
title: "Task 139 — Schedules Screen, Schedule Control, and Run History"
description: "Give schedules a real product surface: a standalone Client list and detail page, a create/edit form that reuses the existing new-conversation widgets, pause/resume/run-now, a per-schedule conversation mode, a persisted run history anchored to the run's conversation, and one local/cloud protocol path, while the model stays owner-scoped and the device owner can control any schedule."
status: pending
current_gate: "Wave 1 (agent state) blocked on 138-11; Wave 2 (protocol) blocked on 138-08"
remaining_estimate: 100%
base_commit: 09d5c34a
depends_on: "138-11 (schema modules), 138-08 (bridge translator), 138-09 (history projection host), 113b 113-02 (composer split) — see Work split"
---

# Task 139 — Schedules Screen, Schedule Control, and Run History

## Goal

Turn recurring schedules from a model-only capability into a surface the user owns: a standalone
Schedules list per device, a detail page with a **Run history** tab, and a create/edit form that can
schedule work without the user having to start a conversation first.

Two invariants hold throughout:

1. The **model** stays owner-scoped: a model turn may touch only schedules owned by its own
   conversation (Task 112a D6, unchanged).
2. The **device owner** may control any schedule on the device, because the human operating the device
   is the authority D6 never had to consider.

Scope: `agent/` (state, scheduler, tool, protocol) and `client/` (list, detail, run history, form,
conversation marker, shared widget extraction). No change to the schedule vocabulary, the zone rule,
or the recovery policy of Task 112b.

## Verified starting point (2026-10-23, `09d5c34a`)

| Fact | Evidence |
|---|---|
| A schedule persists `enabled` but nothing can set it to false | `agent/lib/evolution/scheduling/schedule_model.dart` (`ScheduledTaskRecord.enabled`; `fromRow` defaults it to `1`); no `enabled: false` write exists under `agent/lib/evolution/` |
| Startup already honors a paused row | `agent/lib/evolution/cron_scheduler.dart` `initialize()` skips `!record.enabled` |
| The scheduler exposes create/list/get/cancel/update only | `agent/lib/evolution/cron_scheduler.dart` (`createSchedule`, `getSchedule`, `listSchedules`, `cancelSchedule`, `updateSchedule`; 608 lines) |
| The tool's action set is `create \| list \| cancel \| update` | `agent/lib/capabilities/tools/schedule_task_tool.dart` schema `action.enum` |
| Mutations are owner-scoped to the calling session, reads are device-wide | `CronScheduler.cancelSchedule`/`updateSchedule` compare `record.sessionId` with `callerSessionId` (D6) |
| `create` refuses to run without a session context | `ScheduleTaskTool._handleCreate` and `CronScheduler.createSchedule` deny when the session is empty (D5) |
| There is no run history: one row per schedule carries only `last_run_at`/`last_status` | `docs/technical/agent_database_schema.md` §3.3; `ScheduledTaskRepository` has no run table |
| The schema document still says pause/resume is out of scope | `docs/technical/agent_database_schema.md` §3.3, `enabled` column note |
| No schedule command or query exists in the gateway protocol | zero `schedule.` cases in the `handleCommand` switch of `agent/lib/interfaces/platforms/sanad_gateway/sanad_protocol_bridge.dart` |
| The bridge must be edited to add a command family, and it is allowlisted at 1,327 lines | `agent/test/guards/file_size_ratchet_guard_test.dart`; 138-08 is already moving that switch into `protocol/canonical_command_translator.dart` |
| `scheduled_tasks` DDL lives in an allowlisted 1,635-line file that 138-11 is splitting into `evolution/db/schema/` modules | `agent/test/guards/file_size_ratchet_guard_test.dart`; `docs/plans/tasks/138-agent-srp-tier2.md` item 138-11 |
| The Client has no scheduling surface at all | zero `Scheduled`/`schedule_task` references under `client/lib` |
| The conversation sidebar has no product pages: it composes workspaces and conversations only | `client/lib/features/conversations/presentation/widgets/sidebar/sidebar_composition.dart` (66 lines), `sidebar_sections.dart` (332 lines), `sidebar_conversation_row.dart` (766 lines) |
| The new-conversation pickers exist but their composer chips are private to a 1,634-line allowlisted host | `conversation_input/model_picker_dialog.dart` (`ModelPickerDialog({onSelected(providerId, modelId), device})`, 999 lines); `conversation_input/conversation_input_composer.dart` (1,634 lines, allowlisted); `client/lib/utils/workspace_picker_helper.dart`; workspaces through `ConversationCacheRepository.refreshWorkspaces` → `list_workspaces` |
| The composer split that would expose those chips is already planned | `docs/plans/tasks/113b-srp-tier2-client-presentation.md` item 113-02 (`composer_model_chip.dart`, flat `composer_*.dart`) |
| Device commands resolve transport per request, never per screen | `client/lib/features/devices/data/device_command_client.dart` (`DeviceCommandClient.request`, `DeviceCommandException.code`), `DeviceConnectionCoordinator` |

## Binding decisions

Fixed by the product owner; not reopened here.

| # | Decision | Source |
|---|---|---|
| S1 | A create **and** edit form in the Client is in scope. | U1 |
| S2 | A screen-created schedule needs no pre-existing conversation. | U1, U5 |
| S3 | `continuous` mode: **one** dedicated conversation per schedule, created on its first run (or on Run now), every later run appended to it. | U5, U9 |
| S4 | One per-schedule switch, "Conversation mode": `continuous` (default) or `new_each_run` (a fresh conversation per run, linked from run history). | U7 |
| S5 | The form reuses the **existing** new-conversation widgets and content — the same optional workspace selector, the same provider/model picker popup, and the related input pieces — instead of rewriting them, refactoring them into shared widgets where needed. The chosen workspace, provider, and model are stored with the schedule and used for its conversation. | U6 + clarification |
| S6 | Form fields: name (optional), task text (required, self-contained), recurrence (once / interval / daily / weekly / monthly with their fields), advanced zone, workspace, provider+model, conversation mode, and a live "next run" preview. Create = save and appears in the list; the conversation is created on the first run or on Run now. Edit uses the same form (name, task, recurrence, workspace, model, mode); the owning conversation is **not** changeable. | U9 |
| S7 | A new persisted runs table per schedule (time, status, error, link to the run's session), and the run-history UI is in scope. | U2, U10 |
| S8 | Run history is a **tab on the schedule detail page**, showing time, status (`succeeded` / `failed` / `running`), duration, error, and **Open conversation**, which jumps to that run inside the conversation. A cross-schedule history tab is not in v1. | U10 |
| S9 | Run-history rows point at the run's **position** (turn/message) inside its conversation. | U5 |
| S10 | Deleting a schedule keeps its conversation(s); only the schedule and its run rows go. | U8 |
| S11 | Both screens behave identically over local and cloud connections. No local-only restrictions. | U4 |
| S12 | Schedules are a standalone sidebar page, and conversations that own schedules carry a marker. | accepted recommendation |
| S13 | Pause/resume use the existing `enabled` column; the agent gains `pause`, `resume`, and `run_now` actions. | accepted recommendation |
| S14 | Run now does not shift the next scheduled run. | accepted recommendation |
| S15 | A model turn stays owner-scoped (112a D6); the device owner may pause, resume, edit, run, or delete **any** schedule on the device. | accepted recommendation |
| S16 | Failures surface as a badge plus a message in the run's conversation; after 3 consecutive failures the UI suggests pausing. No auto-disable. | accepted recommendation |
| S17 | Desktop notifications wait for the notifications task. | accepted recommendation |
| S18 | An offline device shows "unavailable", never fabricated or cached state presented as current. | accepted recommendation |
| S19 | Prompts must be self-contained: a run must not depend on hidden context. Compaction owns growth. | U5 |

### Amendments this task records

| Law | Before | After |
|---|---|---|
| 112a D5 ("a schedule has an owner; `create` without a session fails") | every schedule needs a creator conversation | still true for the **model** path; a user-authority command may create a device-owned schedule with no conversation |
| 112a D10 ("`pause`/`resume`, `run-now` … out of scope") | out of scope | in scope (S13, S14) |
| 112a D9 ("list exposes id, recurrence summary, next instant, last status") | as written | additionally exposes the owner kind, the owning conversation or "device", `enabled`, and the consecutive-failure count; the Agent's English recurrence summary stays model-facing only (see the projection rule in §Protocol) |
| `docs/technical/agent_database_schema.md` §3.3 `enabled` note ("pause/resume is out of scope in this release; reserved for future lifecycle control") | stale | pause/resume is that lifecycle control |

### Design decisions taken to make the fixed decisions executable

Not product choices; they exist because the fixed decisions do not name a shape. Each respects the
additive-migration law of 112a D8 and the size ratchet.

| # | Decision |
|---|---|
| D1 | `scheduled_tasks` grows by **additive nullable/defaulted columns only** — no rename, no drop, no table rebuild, no tightened `NOT NULL`: `name TEXT`, `owner_kind TEXT NOT NULL DEFAULT 'model'` (`model` \| `user`), `conversation_mode TEXT NOT NULL DEFAULT 'continuous'`, `run_session_id TEXT`, `workspace_id TEXT`, `provider_instance_id TEXT`, `model TEXT`. Existing rows become `owner_kind='model'`, `conversation_mode='continuous'`, which is exactly today's behavior. `session_id` keeps its meaning as the conversation a run appends to for model-owned rows, and is the empty string for a user-owned `continuous` schedule whose conversation does not exist yet; `owner_kind` carries that meaning and no payload ever presents the empty string as an identity. |
| D2 | New table `scheduled_task_runs` (§A3) with its own repository owner. Retention is bounded: newest 200 rows per schedule and nothing older than 90 days, pruned on write. |
| D3 | New cohesive owners keep every edited host inside the ratchet: `evolution/db/scheduled_task_run_repository.dart`, `evolution/scheduling/schedule_run_recorder.dart`, `schedule_control.dart`, `schedule_conversation_factory.dart`, `handlers/schedule_command_handler.dart`, `handlers/schedule_query_handler.dart`, and — on the Client — `features/schedules/**` plus the extracted shared picker chips. `schedule_model.dart` (1,264), `sanad_protocol_bridge.dart` (1,327), `session_query_handler.dart` (1,482), and `conversation_input_composer.dart` (1,634) may not grow. |
| D4 | The "next run" preview is an agent answer, not a Client re-implementation (`schedule.preview`, §Protocol). The thin-client law puts schedule arithmetic in the Agent; the Client owns no second occurrence calculator. |
| D5 | Authority is explicit in the row: `owner_kind` decides who may mutate. The model path can only produce `owner_kind='model'`; only a user-authority command produces `owner_kind='user'`. A model turn can never widen its own scope, and no payload field selects the kind. |
| D6 | Resuming a `once` schedule whose instant has passed fails with `schedule_expired`; it never fires retroactively. |
| D7 | Deleting a schedule deletes its run rows in the same transaction and touches no session or message (S10). |
| D8 | A model-owned schedule keeps `conversation_mode='continuous'` and runs in its owning conversation; there is no conversation picker anywhere (U5). |
| D9 | A run row starts `running` when dispatch is accepted and reaches exactly one terminal state (`succeeded`, `failed`, or `skipped` for a missed occurrence that never ran). Duration is measured from dispatch acceptance to terminal state and stored as `duration_ms`. |

## Agent work

### A1 — State and repository

- Add the D1 columns through the existing guarded, idempotent migration, in the schema module that owns
  `scheduled_tasks` **after** 138-11 lands (`agent/lib/evolution/db/schema/scheduling_schema.dart`).
  Before 138-11 this item does not start: the DDL lives in an allowlisted 1,635-line file and may not
  grow.
- `ScheduledTaskRecord` gains `name`, `ownerKind`, `conversationMode`, `runSessionId`, `workspaceId`,
  `providerInstanceId`, `model`; `toMap`/`fromRow` round-trip them and `fromRow` defaults an old row to
  `name = null`, `ownerKind = 'model'`, `conversationMode = 'continuous'`, and null for the four route
  columns.
- `ScheduleDefinition`/`OccurrenceCalculator` are untouched by the storage change: the conversation and
  route columns are dispatch concerns, never part of the recurrence definition.
- Keep `run_at` mirrored as today (rollback safety) and keep `enabled` defaulted to `1`.

### A2 — Scheduler control

Extend `CronScheduler` with three actions, each a thin delegate so the host does not grow:

| Action | Behavior |
|---|---|
| `pauseSchedule(id, caller)` | set `enabled=0`, cancel the in-memory timer, keep `next_run_at` and `last_*` unchanged |
| `resumeSchedule(id, caller)` | set `enabled=1` and recompute the next instant from now (`OccurrenceCalculator.computeNextOccurrence`; interval anchors on the stored slot grid as today); a `once` whose instant has passed fails `schedule_expired` (D6) |
| `runNowSchedule(id, caller)` | record a `trigger='manual'` run row, dispatch into the conversation now, and **not** touch `next_run_at`, `last_run_at`, or `last_status` (S14) |

- Authority is one owner (`schedule_control.dart`): `owner_kind='user'` is mutable by user-authority
  callers only; `owner_kind='model'` is mutable by its owning conversation and by user-authority
  callers (S15). The model tool passes a model-authority caller and therefore keeps D6 exactly.
- `CronScheduler` remains the single writer (112a D7). No tool and no protocol handler writes
  `scheduled_tasks` or `scheduled_task_runs` directly.
- A paused schedule never fires from the timer, on restart, or during recovery. `initialize()`'s
  existing `!record.enabled` skip is already correct and gains a test rather than a change.

### A3 — Runs table

New table `scheduled_task_runs`, owned by `ScheduledTaskRunRepository`:

| Column | Type | Notes |
|---|---|---|
| `id` | `TEXT` PK | run identity (`run_<microseconds>`) |
| `schedule_id` | `TEXT` NOT NULL | parent schedule |
| `run_at` | `TEXT` NOT NULL | ISO-8601 UTC instant of the attempt |
| `status` | `TEXT` NOT NULL | `running` \| `succeeded` \| `failed` \| `skipped` (D9) |
| `trigger` | `TEXT` NOT NULL | `scheduled` \| `manual` \| `recovery` |
| `duration_ms` | `INTEGER` NULL | dispatch acceptance → terminal state (S8) |
| `error` | `TEXT` NULL | bounded, and passed through the existing secrets redactor before it is stored |
| `session_id` | `TEXT` NULL | the conversation the run appended to (S7) |
| `message_id` | `TEXT` NULL | the run's position inside that conversation (S9) |
| `created_at` | `TEXT` NOT NULL | row creation |

- Index `(schedule_id, run_at DESC)`; retention per D2 (`schedule_run_recorder.dart` prunes on write,
  never on read).
- Every dispatch path writes the `running` row before the event leaves the scheduler: timer fire,
  recovery in-grace fire, manual run. The missed-beyond-grace path writes `skipped` directly and never
  dispatches. At-most-once ordering (112b B-D1) covers the row write too.
- The terminal transition is written by the owner that observes the run's turn ending; until the
  correlation identity in Open question 1 is fixed, the item must not invent one.
- `last_run_at` / `last_status` keep their current meaning for compatibility; the runs table is the
  history of record and the only source for the Run history tab.

### A4 — Conversations for schedules

`schedule_conversation_factory.dart` is the only owner that creates a schedule's conversation:

- `continuous` (default): on the first dispatch — timer fire, recovery fire, or Run now — create one
  conversation with the stored `workspace_id`, `provider_instance_id`, and `model`, title it from the
  schedule (`name`, else a truncated task text), persist its id in `run_session_id`, then dispatch
  every later run into it (S3).
- `new_each_run`: create a fresh conversation per run with the same stored setup and record its id on
  that run row (S4).
- Session creation goes through the existing session-creation path (`SessionManager.createSession`
  plus the workspace assignment `create_session` already uses). Do not add a second creation path and
  do not touch title generation: the ordinary title owner still runs.
- The run message is the task text verbatim with no hidden context injected (S19). The form and the
  tool description both state that the task must be self-contained.

### A5 — Tool surface

`schedule_task` gains `pause`, `resume`, and `run_now`, plus optional `name` on create and update.
Unchanged: the vocabulary (D2), the zone rule (D3), `update` merge semantics (D10/P7), and bounded
output (D9 plus the amendment). A model turn that names a `user`-owned schedule, or another
conversation's schedule, is denied with `permission_denied` naming the owner — never a silent no-op
and never a partial mutation.

### A6 — Agent documentation

`docs/technical/agent_database_schema.md` (§3.3 columns, the new runs table, the additive migration
note, the schema-snapshot fixtures table), `docs/product/features.md` §Scheduling, and
`agent/lib/evolution/AGENTS.md` / `agent/lib/interfaces/platforms/sanad_gateway/AGENTS.md` where the
ownership statements become stale.

## Protocol

One code path for local and cloud (S11). Commands travel in the existing `device_command` envelope and
resolve transport per request in `DeviceConnectionCoordinator`; handlers receive dependencies as
constructor inputs and never resolve runtime owners through `getIt`.

### Commands and queries

| Command | Response | Payload (request → response) |
|---|---|---|
| `schedule.list` | `schedule.list_result` | `{}` → `{schedules:[…], truncated:bool}` |
| `schedule.preview` | `schedule.preview_result` | candidate definition → `{valid, next_run_at?, zone?, error_code?}` |
| `schedule.create` | `schedule.created` | the create payload below → the created row |
| `schedule.update` | `schedule.updated` | `{id, name?, task?, conversation_mode?, workspace_id?, provider_instance_id?, model?, …recurrence?}` → the updated row |
| `schedule.pause` | `schedule.updated` | `{id}` → the row with `enabled=false` |
| `schedule.resume` | `schedule.updated` | `{id}` → the row with `enabled=true` and the recomputed `next_run_at` |
| `schedule.run_now` | `schedule.run_accepted` | `{id}` → `{run_id, session_id, accepted_at}` |
| `schedule.delete` | `schedule.deleted` | `{id, confirm:true}` → `{id, deleted:true}` |
| `schedule.runs` | `schedule.runs_result` | `{schedule_id, limit?, cursor?}` → `{runs:[…], has_more, next_cursor?}` |

Create payload:

```json
{
  "name": "Morning brief",
  "task": "Summarise the open items in this workspace.",
  "kind": "daily",
  "time": "09:00",
  "zone": "+03:00",
  "conversation_mode": "continuous",
  "workspace_id": "…",
  "provider_instance_id": "…",
  "model": "…"
}
```

Row projection (`schedules[]` and every single-row response) — **structured, never a sentence**:

```json
{
  "id": "task_…",
  "name": "Morning brief",
  "task": "Summarise the open items in this workspace.",
  "kind": "daily",
  "interval_minutes": null,
  "at_time": "09:00",
  "weekdays": null,
  "month_day": null,
  "zone": "+03:00",
  "next_run_at": "2026-10-24T09:00:00+03:00",
  "enabled": true,
  "owner_kind": "user",
  "owner_session_id": "…",
  "owner_session_title": "Morning brief runs",
  "conversation_mode": "continuous",
  "workspace_id": "…",
  "provider_instance_id": "…",
  "model": "…",
  "last_run_at": "2026-10-23T09:00:04Z",
  "last_status": "fired",
  "consecutive_failures": 0,
  "created_at": "…",
  "updated_at": "…"
}
```

Run projection (`runs[]`): `{id, run_at, status, trigger, duration_ms, error, session_id, message_id,
has_position}`.

Localization rule: the recurrence **sentence** is Agent-internal and model-facing only. The Client composes its own localized summary from `kind` and the structured fields, so no English sentence from the Agent becomes a UI string.

### Validation and error codes

| Code | When |
|---|---|
| `invalid_request` | unknown field, wrong type, missing `id`, `confirm` absent on delete |
| `invalid_schedule` | `ScheduleDefinition.parse` rejected the definition (vocabulary, `HH:MM`, weekday, `day_of_month`, interval bound, mixed shapes, IANA zone) |
| `schedule_not_found` | unknown id |
| `schedule_expired` | resume of a `once` whose instant has passed (D6) |
| `permission_denied` | a model-authority caller naming a row it does not own (never reachable from the Client) |
| `internal_error` | repository or scheduler failure; nothing mutated |

- Every request is validated completely before the first mutation; a rejected request mutates nothing.
- Error envelopes keep the existing shape (`{type:"error", payload:{request_id, code, message}}`) with
  a stable, non-secret `message` — never a stack trace and never command output.
- After a successful mutation the Agent broadcasts `schedule.changed` (`{schedule_id, change}`) to
  every Sanad client on every platform through the existing family fan-out, so a second client
  refreshes instead of showing a stale list.

### Failure surfacing

- A failed run writes its terminal row (`status='failed'`, bounded `error`, `duration_ms`) and
  publishes one canonical `schedule.run_failed` event to that run's conversation carrying
  `{schedule_id, schedule_name, run_id, session_id, consecutive_failures, suggest_pause}`.
- `suggest_pause` is true from the third consecutive failure (S16). Nothing disables the schedule.
- `schedule.run_failed` is a live, model-invisible notice: never written to model history, never
  carrying command output; durability comes from the runs table plus `consecutive_failures` in
  `schedule.list`.

## Client work

### C1 — Entry points

- **Sidebar page.** New routes `AppRoutes.schedules = '/conversations/:deviceId/schedules'` and
  `AppRoutes.scheduleDetail = '/conversations/:deviceId/schedules/:scheduleId'`, so the pages keep the
  device chrome and the sidebar, plus a `Schedules` row in `sidebar_composition.dart` /
  `sidebar_sections.dart`. Both pages are scoped to the conversation's device.
- **Conversation marker.** A compact badge on `sidebar_conversation_row.dart` for a conversation that
  owns at least one schedule, derived from the same `schedule.list` snapshot (no extra command).
- **Create entry.** A primary "New schedule" action on the list page.

### C2 — Screens

- `SchedulesScreen` (list): name (or a derived label), localized recurrence summary, next run in the
  schedule's zone, last outcome, paused state, consecutive-failure badge, and row actions pause/resume,
  run now, edit, delete (confirmed).
- `ScheduleDetailScreen` with two tabs:
  - **Details** — the summary, the owner (conversation or device), the stored workspace/provider/model,
    conversation mode, pause/resume, run now, edit, delete.
  - **Run history** (S8, U10) — rows of time, status (`succeeded` / `failed` / `running`), duration,
    error, and **Open conversation**, which navigates to the run's conversation at that run's position
    when `has_position` is true and to the conversation otherwise.
- `ScheduleEditorSheet` (create/edit) in this order: name (optional) → task text (required, with the
  self-contained hint) → recurrence picker for once/interval/daily/weekly/monthly with the matching
  fields → advanced zone → workspace (S5) → provider+model (S5) → conversation mode switch (S4) → live
  next-run preview (D4, debounced `schedule.preview`, rendered in the selected zone) → Create / Save.
- Edit reuses the same widget with the row as its initial value; the owning conversation is shown and
  read-only (S6). Changing the recurrence through the form follows the existing `update` merge rule.

### C3 — Reusing the new-conversation widgets

Per S5 the form must not re-implement the new-conversation pieces. The shared surface is:

| Piece | Today | Required |
|---|---|---|
| Provider/model picker | `ModelPickerDialog` (public, 999 lines) | call it as-is; never grow it past 999 |
| Model chip / selector button | private `_ModelChip` inside `conversation_input_composer.dart` (1,634, allowlisted) | extract to `conversation_input/composer_model_chip.dart` and use it in both places |
| Workspace selector | composer workspace chip + `WorkspacePickerHelper` + `ConversationCacheRepository.refreshWorkspaces` | extract the chip to `conversation_input/composer_workspace_chip.dart` and use it in both places |
| Related input pieces | `conversation_input/` component library | reuse; do not fork copies into `features/schedules/` |

The extraction is the same work 113b item 113-02 already plans as flat `composer_*.dart` libraries. If
113-02 has landed, reuse those files and add nothing to the composer. If it has not, this task does the
extraction first as its own PR, keeps every key/semantics node byte-identical (113b C5), and **lowers**
`conversation_input_composer.dart`'s ratchet number — never raises it.

Choosing an **existing** workspace is identical on both routes (it reads the device's workspace list).
Creating a **new** workspace folder keeps the workspace feature's existing rule that the native folder
picker is a local-connection action; that is an inherited workspace constraint, not a Schedules
restriction, and it does not weaken S11 for any schedule action.

### C4 — States

| State | Presentation |
|---|---|
| loading | page skeleton; no request from `build` (Render and Request Independence) |
| empty | "No schedules yet" + the create action |
| error | typed message from `DeviceCommandException.code` in localized copy, plus Retry |
| device unavailable | "Unavailable" banner, actions disabled, **no stale list presented as current** (S18). `DeviceConfig.isOnline == false` short-circuits before any request; a socket that drops mid-action surfaces the same state |
| loaded | list/detail/run history; `schedule.changed` from another client refreshes through the owning cubit |

One cubit for the feature (113b C2: one cubit per feature; helpers are coordinators with typed
callbacks, not extra cubits).

### C5 — Strings

Every user-facing string is authored in `client/lib/l10n/app_en.arb` and translated in `app_ar.arb`;
no Arabic literal in handwritten Dart. At minimum: `schedules`, `newSchedule`, `scheduleName`,
`scheduleNameOptional`, `scheduleTask`, `scheduleTaskHint`, `scheduleRecurrence`,
`scheduleRecurrenceOnce/Interval/Daily/Weekly/Monthly`, `scheduleTime`, `scheduleWeekdays`,
`scheduleDayOfMonth`, `scheduleInterval`, `scheduleZone`, `scheduleWorkspace`, `scheduleModel`,
`scheduleConversationMode`, `scheduleModeContinuous`, `scheduleModeNewEachRun`,
`scheduleNextRunPreview`, `schedulePaused`, `pauseSchedule`, `resumeSchedule`, `runNow`,
`deleteSchedule`, `deleteScheduleConfirm`, `scheduleDetails`, `scheduleRunHistory`,
`scheduleRunStatusRunning/Succeeded/Failed/Skipped`, `scheduleRunTriggerManual`, `scheduleDuration`,
`scheduleOpenConversation`, `scheduleEmpty`, `scheduleUnavailable`, `scheduleLoadFailed`,
`scheduleSaveFailed`, `scheduleExpired`, `scheduleFailureSuggestion`,
`scheduleOwnedByConversation`, `scheduleOwnedByDevice`, `scheduleHasSchedules` (marker tooltip).

### C6 — Local and cloud

Both entry points and every action use `DeviceCommandClient` → `DeviceConnectionCoordinator`. No screen
selects a transport, reads a local credential, or branches on connection scope (S11). The same cubit,
states, and strings serve both routes.

## Security

### Run-now and create permission model

- **Transport authority, not payload.** Authority derives from the receiving transport
  (`docs/technical/execution_trust_and_permission_authority.md`): every authenticated client transport
  — loopback local, Cloud Gateway, in-process CLI — carries device-owner authority, which is why S11
  can promise identical behavior without a second authority path.
- **Creation.** A Client command always creates `owner_kind='user'`. The model tool can only create
  `owner_kind='model'` and still needs a session context. `owner_kind` is set by the receiving command
  family, never read from the payload, so a hand-crafted payload cannot claim the other kind (D5).
- **Mutation.** `user` rows are mutable by device-owner authority only. `model` rows are mutable by
  their owning conversation and by device-owner authority. A model turn naming a `user` row or a
  foreign row gets `permission_denied` with the owner named, and nothing mutates (S15, 112a D6).
- **Run now** never silently bypasses pause semantics: it is recorded with `trigger='manual'`, so the
  run history distinguishes it from a scheduled fire, and it never shifts `next_run_at` (S14).
- **Delete** requires an explicit `confirm:true` plus a Client confirmation dialog, and deletes the
  schedule and its run rows only (S10, D7) — never a conversation or a message.
- **Prompt content.** A UI-created prompt is user-authored and self-contained (S19), so a scheduled run
  cannot be steered by content the user never saw. A model-created prompt stays subject to the
  existing turn authority of its own conversation.
- **Failure text.** `error` in a run row and the `schedule.run_failed` notice are bounded and pass
  through the existing secrets redactor before storage or delivery; no command output, file content, or
  timeline text is copied into either.

## Tests and Definition of Done

### Agent

- Unit: additive migration on a fresh database, a pre-112 shape, and a current shape (three consecutive
  runs are no-ops); `fromRow` defaults for old rows; the seven new fields round-trip.
- Unit: pause cancels the timer and keeps `next_run_at`; resume recomputes on the stored slot grid;
  resume of an expired `once` is `schedule_expired`; a paused schedule never fires on restart or in
  recovery; run now leaves `next_run_at`/`last_run_at`/`last_status` untouched.
- Unit: a run row for every dispatch path starts `running`; the missed-beyond-grace path writes
  `skipped` and dispatches nothing; retention prunes to 200 per schedule and 90 days; the row write
  precedes the event.
- Unit: `continuous` creates exactly one conversation across many runs and reuses it; `new_each_run`
  creates one per run and links each from its run row; the conversation is created with the stored
  workspace/provider/model; a user-owned `continuous` schedule dispatches into a newly created
  conversation on Run now before any timer fire.
- Handler: every command's success path; each error code; unknown-field rejection mutating nothing;
  `schedule.changed` on mutation; `schedule.runs` pagination bound and cross-schedule rejection; the
  run projection carries no session title or content beyond the documented fields.
- Tool: `pause`/`resume`/`run_now` succeed on an owned row; `permission_denied` for a foreign row and for
  any `user`-owned row; `list` shows the owner kind and conversation label; the 112a vocabulary and
  merge rules stay green.
- Security: a forged `owner_kind` in a payload is ignored; a model-authority caller cannot mutate a user
  row; delete leaves sessions and messages intact.

### Client

- Cubit: load/admit/invalidate states, no fetch from `build` or a rebuild, device-unavailable mapping
  before a request, `schedule.changed` refresh, single-flight per action.
- Widget: loading/empty/error/unavailable/loaded; both detail tabs; the run history renders duration and
  status and opens the run's conversation; the create form validates required fields; the preview
  updates and shows an error for an invalid definition; edit shows the owning conversation read-only;
  delete asks for confirmation.
- Reuse: the form renders the extracted workspace and model chips and the existing
  `ModelPickerDialog`; a guard fails if a second picker implementation appears under
  `features/schedules/`.
- Localization: every new key exists in `en` and `ar`; no hard-coded English copy on the new surfaces;
  an RTL pass on the form, the list, and the run history.
- Guards: `client/test/guards/file_size_ratchet_guard_test.dart` and
  `agent/test/guards/file_size_ratchet_guard_test.dart` stay green, no raised number, no dead entry.

### Live acceptance (one Test Home; once locally, once through the cloud relay)

1. Create a `daily` schedule from the screen with no conversation: it appears in the list, `next_run_at`
   is in the future, and no conversation exists yet.
2. The first run creates exactly one conversation in the chosen workspace with the chosen
   provider/model; a second run appends to the same conversation.
3. `new_each_run`: two runs produce two conversations, each reachable from its run row.
4. Run now fires immediately, the run row says `trigger=manual` with a duration, and the next scheduled
   instant is unchanged.
5. Run history shows `running` while the turn is in flight and `succeeded`/`failed` afterwards, with the
   error text on failure.
6. Pause stops the timer and survives a daemon restart; resume re-arms at the next future instant.
7. Delete removes the schedule and its run rows and leaves its conversation(s) readable.
8. A failing run shows the badge, the message inside the run's conversation, and the pause suggestion
   after the third consecutive failure; nothing auto-disables.
9. A model turn in an unrelated conversation cannot pause, run, or delete a screen-created schedule; the
   same action from the screen succeeds.
10. Stop the device (or disconnect the cloud route): the page shows "Unavailable" with disabled actions,
    then recovers and refreshes on reconnect.
11. Repeat 1–10 over the cloud relay with the local daemon not directly reachable and confirm identical
    results.

### Definition of Done

- `cd agent && set -o pipefail; fvm dart analyze 2>&1 | tail -5` and
  `cd client && set -o pipefail; fvm flutter analyze 2>&1 | tail -5` are clean.
- Focused suites per item, then the full fast suite of each package on the frozen candidate, reporting
  command, exit code, counts, duration, and a bounded final-five-line summary.
- Daemon-backed E2E only where the change alters socket behavior beyond the new command family;
  otherwise handler + widget suites plus the live acceptance above are the bar.
- Documentation updated in the same change: schema, product, the protocol page, and the two owning
  contracts. No stale "pause is out of scope" statement survives.
- `graphify update .` after the code change.
- Size ratchet green; new responsibilities have owners, not one growing host.

## Work split

Ordered, with the file locks each item holds while its PR is open. Do not start an item whose lock is
held by an open SRP PR; merge that PR first (138 decision 8: no rebase across a lock).

| Item | Wave | Files locked | Blocked by |
|---|---|---|---|
| 139-01 state: columns + `scheduled_task_runs` + repositories | 1 | `agent/lib/evolution/db/schema/scheduling_schema.dart`, `evolution/db/scheduled_task_repository.dart`, `evolution/db/scheduled_task_run_repository.dart`, `evolution/scheduling/schedule_model.dart` (row fields only), `agent/test/evolution/*`, `docs/technical/agent_database_schema.md`, `agent/test/guards/file_size_ratchet_guard_test.dart` | **138-11**; **138-05** fixtures may need a new snapshot |
| 139-02 scheduler control + conversations + run recorder | 2 | `agent/lib/evolution/cron_scheduler.dart`, `evolution/scheduling/{schedule_control,schedule_run_recorder,schedule_conversation_factory}.dart` | 139-01 |
| 139-03 tool actions | 2 | `agent/lib/capabilities/tools/schedule_task_tool.dart`, `agent/lib/capabilities/AGENTS.md` | 139-02 |
| 139-04 protocol: commands, queries, events, broadcast, tests | 3 | `agent/lib/interfaces/platforms/sanad_gateway/handlers/{schedule_command_handler,schedule_query_handler}.dart`, `protocol/canonical_events.dart`, `agent/test/interfaces/platforms/sanad_gateway/**`, `docs/technical/schedule_control_protocol.md`, `docs/technical/communication_protocols.md` | **138-08** (dispatch table) and 139-02; the `schedule.run_failed` notice must not grow `handlers/session_query_handler.dart` (**138-09**, allowlisted 1,482) |
| 139-05 shared new-conversation widgets | 4 | `client/lib/features/conversations/presentation/widgets/conversation_input/composer_model_chip.dart`, `composer_workspace_chip.dart`, `conversation_input_composer.dart` (must shrink), `client/test/**composer*` | **113b 113-02** if it is open; otherwise this PR performs the extraction and lowers the composer's ratchet entry |
| 139-06 Client data + cubit + routes | 4 | `client/lib/features/schedules/data/**`, `domain/**`, `presentation/bloc/**`, `client/lib/core/navigation/{app_routes,app_router}.dart` | 139-04 (needs the commands) |
| 139-07 Client screens: list, detail, run history, form, marker | 5 | `client/lib/features/schedules/presentation/**`, `sidebar_composition.dart`, `sidebar_sections.dart`, `sidebar_conversation_row.dart`, `client/lib/l10n/app_{en,ar}.arb` | 139-05, 139-06. Keep `home_screen.dart` (975) under 1,000 |
| 139-08 live acceptance + close-out | 6 | this file, `docs/qa_maintenance/schedules_screen_acceptance.md`, `docs/product/features.md` | 139-07 |

- 139-01…139-04 are Agent-only; 139-05…139-08 are Client/QA. Each PR is independent once its
  predecessor merges; never run Agent and Client suites concurrently on one machine.
- Hard SRP dependencies: **138-11** (schema file), **138-08** (bridge switch), **138-09** (history
  projection host, only if a notice row is projected there), **113b 113-02** (composer chips). No other
  SRP item owns a file this task needs.
- `schedule_model.dart` is allowlisted and deferred by 138: 139-01 may add record fields but must stay
  at or under 1,264 lines. If it cannot, the new fields go to a companion file instead.

## Open questions

Not covered by U1–U10 or by the accepted recommendations. Do not decide them here.

1. **Run-history anchor identity.** S9 requires a position inside the conversation, and U10 requires
   "Open conversation" to jump there, but the scheduler emits a platform event and never sees the
   turn's durable identity. Which already-preserved identity links a run row to its exact message (a
   `message_id` written when the turn's user message commits, a reused `run_id`, or `run_at` only), and
   does the terminal `succeeded`/`failed` transition come from the same observation?
2. **Run now on a paused schedule.** Allowed as a manual override, or rejected with a typed error?
3. **Manual runs and the failure streak.** Does a failing manual run count toward the
   three-consecutive-failure pause suggestion, or only scheduled fires?
4. **A schedule whose conversation is deleted.** A model-owned schedule requires an owning conversation
   (112a D5). When the user deletes that conversation (54g territory), does the schedule
   cascade-delete, auto-pause, or does the deletion refuse while a schedule depends on it?
5. **Edit during an active run.** Should an edit apply to the next run only (today's `update`
   behavior) or be refused until the running turn ends?

## Out of scope

- A cross-schedule (device-wide) run-history tab: v1 ships only the per-schedule tab on the detail page
  (owner decision 2026-10-23).
- Desktop notifications for run completion or failure (S17; the notifications task owns them).
- A device-level "pause all" switch, cloning a schedule, templates, and natural-language editing from
  the screen.
- Any change to the recurrence vocabulary, the zone rule, or the recovery policy (112a D2–D4, 112b).
- A cross-device aggregate view: the pages are scoped to one device, and an unreachable device shows
  "unavailable".
