---
title: "Schedule Control Protocol"
description: "Unified local/cloud protocol commands, envelopes, projections, error codes, change broadcasts, and failure surfacing for device-owner schedule control."
---

# Schedule Control Protocol

> **Owning task:** `docs/plans/tasks/139-client-schedules-screen.md` (§Protocol, A2–A4)
> **Authority specification:** `docs/technical/execution_trust_and_permission_authority.md` §1
> **State contract:** `docs/technical/agent_database_schema.md` §3.3 and §3.4
> **Client surfaces:** Schedules list, schedule detail with a Run history tab, create/edit form

## 1. Goal and Overview

The schedule protocol lets the device owner control recurring work without going through the model:
list schedules, preview a candidate definition, create, edit, pause, resume, run now, delete, and read a
per-schedule run history. The model keeps its own path through the `schedule_task` tool, which stays
owner-scoped to its conversation (Task 112a D6).

Two invariants shape the whole family:

1. **One code path.** Local Gateway loopback and the Cloud Gateway relay use the same commands, payloads,
   responses, and error envelopes (S11). Transport resolves per request in `DeviceConnectionCoordinator`;
   no handler branches on transport type.
2. **Structured, never a sentence.** Every response projects structured recurrence fields. The Agent's
   English recurrence summary (`ScheduleDefinition.humanRecurrenceSummary`) stays model-facing; the Client
   composes its own localized label from `kind`, `interval_minutes`, `at_time`, `weekdays`, `month_day`,
   and `zone`.

---

## 2. Transport Invariant

- Commands travel inside the standard `device_command` envelope with a canonical `request_id`.
- `protocol/canonical_command_translator.dart` accepts the family and produces one canonical event per
  command; `SanadProtocolBridge` dispatches it and does nothing else.
- Handlers receive dependencies as constructor inputs (`CronScheduler`, `SessionManager`, the default
  zone, the family broadcast). A handler never resolves a runtime owner through `getIt`.
- `schedule_command_handler.dart` owns the mutating commands; `schedule_query_handler.dart` owns the
  read-only queries; `handlers/support/schedule_request.dart` owns request validation and
  `handlers/support/schedule_projection.dart` owns the wire projections and protocol limits.

---

## 3. Authority and Permission Gate

- Authority comes from the transport, never from the payload
  (`docs/technical/execution_trust_and_permission_authority.md` §1). Every authenticated client transport
  — authenticated loopback Local Gateway, authenticated Cloud Gateway relay, in-process CLI — is stamped
  `command_authority: owner`; anything else is `unverified`.
- A command without `owner` authority is refused with `permission_denied` and mutates nothing, including
  the read-only queries.
- The handlers always call the control layer as the device owner (`ScheduleCaller.user()`). The model
  path is separate and keeps `ScheduleCaller.model(sessionId)`.
- **Creation.** A Client command always creates `owner_kind='user'`, and a user-owned `continuous`
  schedule starts with **no** conversation (D1, S2). `owner_kind` is set by the command family and is not
  a payload field: a payload carrying `owner_kind` is rejected as an unknown field, so a hand-crafted
  request cannot claim the model kind (D5).
- **Mutation.** `ScheduleControl` decides who may mutate a row: a `user` row is mutable by device-owner
  authority only; a `model` row is mutable by its owning conversation and by device-owner authority (S15).
  `permission_denied` from that layer names the owner and never mutates.
- **Delete** requires a literal `confirm: true` and deletes the schedule plus its run rows only — never a
  conversation, a message, or an attachment (S10, D7).

---

## 4. Commands and Event Contracts

Commands take a *bounded* payload: the two identity keys (`request_id`, `command_authority`) plus the
fields listed for that command. Any other key is `invalid_request`.

| Command | Response event | Request → response payload |
|---|---|---|
| `schedule.list` | `schedule.list_result` | `{}` → `{schedules: [...], truncated: bool}` |
| `schedule.preview` | `schedule.preview_result` | candidate definition → `{valid, next_run_at?, zone?, error_code?}` |
| `schedule.create` | `schedule.created` | create payload → `{schedule: {...}}` |
| `schedule.update` | `schedule.updated` | `{id, task?, name?, conversation_mode?, workspace_id?, provider_instance_id?, model?, ...recurrence}` → `{schedule: {...}}` |
| `schedule.pause` | `schedule.updated` | `{id}` → `{schedule: {...}}` with `enabled: false` |
| `schedule.resume` | `schedule.updated` | `{id}` → `{schedule: {...}}` with `enabled: true` and the recomputed `next_run_at` |
| `schedule.run_now` | `schedule.run_accepted` | `{id}` → `{run_id, session_id, accepted_at}` |
| `schedule.delete` | `schedule.deleted` | `{id, confirm: true}` → `{id, deleted: true}` |
| `schedule.runs` | `schedule.runs_result` | `{schedule_id, limit?, cursor?}` → `{schedule_id, runs: [...], has_more, next_cursor?}` |

### 4.1. Accepted request fields

| Field | Commands | Type | Notes |
|---|---|---|---|
| `request_id` | all | string | Correlation id echoed on the response. |
| `command_authority` | all | string | Transport-stamped; a sender may only lower it. |
| `id` | update, pause, resume, run_now, delete | string | Required, non-blank. |
| `schedule_id` | runs | string | Required, non-blank. |
| `confirm` | delete | boolean | Only the literal `true` confirms. |
| `task` | create, update | string | Required and non-blank on create; on update it is only read when present. |
| `name` | create, update | string or null | Display name. `null` on update clears it. |
| `conversation_mode` | create, update | string | `continuous` (default) or `new_each_run`. |
| `workspace_id`, `provider_instance_id`, `model` | create, update | string or null | Conversation route stored with the schedule; used when its conversation is created. |
| `kind` | create, update, preview | string | `once`, `interval`, `daily`, `weekly`, `monthly`. |
| `time`, `at`, `in`, `every`, `interval`, `zone` | create, update, preview | string | Recurrence values; `zone` is `local` or a fixed offset. |
| `interval_minutes` | create, update, preview | integer | Interval shape. |
| `day_of_month`, `month_day` | create, update, preview | integer | Monthly shape (`day_of_month` is canonical). |
| `weekdays` | create, update, preview | array of strings | `mon`…`sun`. |
| `limit` | runs | integer | `1..200`, default `50`. |
| `cursor` | runs | string | Opaque keyset cursor minted by the previous page. |

The wire shape is canonical: the definition parser is lenient for model-authored tool arguments (it
accepts a numeric string or a comma-separated weekday string), but a device-owner command rejects a wrong
wire type with `invalid_request` instead of coercing it.

### 4.2. Create Payload

```json
{
  "request_id": "req-123",
  "task": "Summarise the open items in this workspace.",
  "name": "Morning brief",
  "kind": "daily",
  "time": "09:00",
  "zone": "+03:00",
  "conversation_mode": "continuous",
  "workspace_id": "ws_1",
  "provider_instance_id": "inst_1",
  "model": "gpt-5"
}
```

A created row appears immediately in `schedule.list`; its conversation is created by the first run
(timer, recovery, or Run now), never by `schedule.create` (S2, S3, A4).

### 4.3. Update Semantics

- `update` merges: an omitted field keeps its stored value, an explicit `null` clears an editable
  settings column (`name`, `workspace_id`, `provider_instance_id`, `model`).
- A partial recurrence merges over the stored shape through
  `ScheduleDefinition.mergeUpdateArgs`, so moving a weekly schedule to a new `time` stays weekly instead
  of being re-inferred as another kind. Supplying `kind` replaces the whole definition (112a D10, P7).
- An update with nothing to change is `invalid_request` — it would otherwise recompute `next_run_at` for
  an unchanged definition.
- An edit during an active run applies to the next run only (S24).

### 4.4. Row Projection

`schedules[]` and the `schedule` object of every single-row response carry exactly these fields:

```json
{
  "id": "task_1730000000000000",
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
  "owner_session_id": "8f14e45f-ea0a-4c1a-9c1f-0d1c9b3e1234",
  "owner_session_title": "Morning brief runs",
  "conversation_mode": "continuous",
  "workspace_id": "ws_1",
  "provider_instance_id": "inst_1",
  "model": "gpt-5",
  "last_run_at": "2026-10-23T09:00:04Z",
  "last_status": "fired",
  "consecutive_failures": 0,
  "created_at": "2026-10-23T08:12:00.000Z",
  "updated_at": "2026-10-23T08:12:00.000Z"
}
```

Projection rules:

- `next_run_at` is rendered in the schedule's own zone (`formatInstant`), so it carries an explicit
  designator (`Z` or `±HH:MM`). `created_at`, `updated_at`, and `last_run_at` are UTC ISO-8601.
- `weekdays` is `null` or an array of `mon`…`sun`; a stored comma-separated value never reaches the wire.
- `owner_session_id` is the conversation the schedule is bound to: the owning conversation of a model row,
  or the `continuous` conversation of a user row once it exists. It is `null` for a schedule that has no
  conversation yet and always `null` for `new_each_run`. An empty stored value is never presented as an
  identity (D1).
- `owner_session_title` is the stored conversation title, and only that: `null` when
  `owner_session_id` is `null` or the conversation has no title. The Agent never derives or translates it.
- `consecutive_failures` counts the newest terminal runs of the schedule; a non-failed terminal run ends
  the streak. Manual and scheduled failures count the same (S22).
- `schedule.list` is ordered by `next_run_at` ascending then `id`, and stops at
  `ScheduleWireLimits.maxListedSchedules` (500) with `truncated: true`; no client page depends on the tail.

### 4.5. Run Projection

`runs[]` carries exactly:

```json
{
  "id": "run_1730000004000000",
  "run_at": "2026-10-23T09:00:04.000Z",
  "status": "succeeded",
  "trigger": "scheduled",
  "duration_ms": 41230,
  "error": null,
  "session_id": "8f14e45f-ea0a-4c1a-9c1f-0d1c9b3e1234",
  "message_id": "msg_9c1f0d1c",
  "has_position": true
}
```

- `status` is `running`, `succeeded`, `failed`, or `skipped`. `trigger` is `scheduled`, `manual`, or
  `recovery`.
- `has_position` is true exactly when `message_id` is set — the only case in which the Client can open
  that run inside its conversation (S9, S20).
- The projection carries no conversation title, message text, task text, or command output.
- `schedule.runs` paging is a keyset on `(run_at DESC, id DESC)`: `limit` defaults to `50` and is clamped
  to `1..200`, `has_more` reports a further page, and `next_cursor` is present only while one exists.
  Reading never prunes; retention is applied on write (`ScheduleRunRetention`).

### 4.6. Run cursor

The cursor is opaque base64url over a versioned JSON object:

```json
{"v": 1, "s": "task_…", "t": "2026-10-23T09:00:04.000Z", "i": "run_…"}
```

`s` binds the schedule, so a cursor minted for one schedule is rejected with `invalid_request` when it is
presented for another. A cursor that is not decodable, is empty, or carries an unknown version is
`invalid_request` as well.

---

## 5. Change Broadcast: `schedule.changed`

After **every successful mutation** the Agent publishes `schedule.changed` through
`GatewayManager.publishFamilyEvent`, so every Sanad client on every platform refreshes instead of showing a
stale list. A command's own `emitEnvelope` reaches only the requester.

```json
{ "schedule_id": "task_…", "change": "created" }
```

`change` is one of `created`, `updated`, `paused`, `resumed`, `run_now`, `deleted`. `run_now` is included
because it writes a run row: another client watching Run history refreshes on it.

---

## 6. Failure Surfacing: `schedule.run_failed`

A failed run writes its terminal row (`status="failed"`, bounded redacted `error`, `duration_ms`) and
publishes one canonical `schedule.run_failed` event to **the run's conversation**:

```json
{
  "schedule_id": "task_…",
  "schedule_name": "Morning brief",
  "run_id": "run_…",
  "session_id": "8f14e45f-…",
  "consecutive_failures": 3,
  "suggest_pause": true
}
```

- Owner: `schedule_run_failure_notice.dart` is the publisher. It is injected at the composition root into
  the scheduler's `ScheduleRunFailureSink`, so no handler grows to publish it and
  `handlers/session_query_handler.dart` is untouched.
- The notice is **live and model-invisible**: it travels as a canonical event to the Sanad client family
  and is never written to model history.
- `suggest_pause` is true from the third consecutive failure (S16). A manual failure counts exactly like a
  scheduled one (S22). Nothing disables the schedule.
- `schedule_name` is the stored name or `null`; the Client localizes its own label.
- The payload carries **no error text** (owner decision 2026-10-23). The bounded, redacted failure text
  lives in the run row and is read through `schedule.runs`, so no command output, file content, or
  timeline text can reach a live event. The Agent's English `error` text never becomes a UI string.
- Durability comes from the runs table plus `consecutive_failures` in `schedule.list`, not from the notice.

---

## 7. Validation and Error Codes

| Code | When |
|---|---|
| `invalid_request` | Unknown field, wrong wire type, missing/blank `id` or `schedule_id`, `confirm` absent or not `true`, out-of-range `limit`, malformed or foreign cursor, or an `update` with nothing to change |
| `invalid_schedule` | `ScheduleDefinition.parse` rejected the definition (vocabulary, `HH:MM`, weekday, `day_of_month`, interval bound, mixed shapes, unsupported zone) |
| `schedule_not_found` | Unknown schedule id |
| `schedule_expired` | Resume of a `once` schedule whose instant has passed (D6) |
| `schedule_orphaned` | `resume` or `run_now` of a model-owned schedule whose owning conversation was deleted (S23, D10) |
| `permission_denied` | Unverified transport; or a model-authority caller naming a row it does not own (never reachable from the Client) |
| `internal_error` | Repository or scheduler failure; nothing mutated |

Rules:

- Every request is validated completely before the first mutation: authority, then the unknown-field gate,
  then each value, then the definition. A rejected request mutates nothing and broadcasts nothing.
- Error envelopes keep the existing shape and carry a stable, non-secret `message`:

```json
{ "type": "error", "payload": { "request_id": "req-123", "code": "invalid_request", "message": "Unknown field in schedule.create payload: owner_kind." } }
```

- A message names fields and violated rules only. It never echoes a payload value, a task text, a stack
  trace, or command output.
- `schedule.preview` is the one command that answers an invalid definition inside its result
  (`{"valid": false, "error_code": "invalid_schedule"}`) instead of an error envelope, because reporting
  invalidity is its purpose. A malformed preview request (unknown field, wrong type) still fails with
  `invalid_request`.

---

## 8. Logging and Security Invariants

1. **No payload logging.** Handlers log the command name, schedule id, run id, protocol code, owner kind,
   conversation mode, and a streak count. They never log a task text, a payload map, a message text, or
   command output.
2. **No model exposure.** A schedule command is not a model turn and never enters a prompt, a tool
   argument, or a tool result. `schedule.run_failed` is client-only and model-invisible.
3. **Bounded failure text.** A run row's `error` is passed through `SecretsRedactor` and cut to
   `ScheduleRunErrorPolicy.maxErrorLength` (500) before it is stored; readers only ever see that stored
   value.
4. **Single writer.** `CronScheduler` (with `ScheduleControl`, `ScheduleRunRecorder`, and
   `ScheduleConversationFactory`) is the only writer of `scheduled_tasks` and `scheduled_task_runs`. The
   handlers call the control layer; they never touch a repository.
5. **Self-contained prompts.** A screen-created task is user-authored and self-contained (S19), and the
   run message is the task text verbatim.
6. **Additive migrations only.** The protocol never introduces a schema change; it reads and writes the
   Task 139 columns through the existing additive migration (112a D8).
