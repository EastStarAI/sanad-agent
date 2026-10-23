# Schedules Feature Contract

## Scope
This contract applies to `client/lib/features/schedules/`.

## Protocol Ownership
- `SchedulesClient` (`data/schedules_client.dart`) is the only Client transport for the schedule protocol
  (`docs/technical/schedule_control_protocol.md`) and it uses `DeviceCommandClient`, so local and cloud
  routes are identical and no screen selects a transport.
- One Client method per command and query: `list`, `preview`, `create`, `update`, `pause`, `resume`,
  `runNow`, `delete`, `runs`. Payloads carry documented fields only; `owner_kind` is never sent, and
  `delete` always sends the protocol's `confirm: true` (the user confirmation belongs to the screen).
- `runs` passes `limit` and the opaque `cursor` through unchanged. No Client code parses, mints, sorts, or
  rewrites a cursor.
- `schedule.changed` is a payload-free signal and `schedule.run_failed` is a typed
  `ScheduleRunFailureNotice`. Neither is ever projected as data; the notice carries no error text and is
  never written to state, a log, or history.
- Rotation of the recurrence vocabulary (kind, interval, time, weekdays, day of month, zone) stays
  structured. The Agent's English recurrence sentence never becomes a UI string; the Client composes its
  own localized summary.

## Typed Errors
- `ScheduleErrorCode.fromWireCode` is the only place a protocol code becomes a Client value, and
  `ScheduleException` carries the typed code plus the schedule id. The Agent's `message` is operator copy:
  it is never carried, logged as a value, or shown.
- A code this Client does not know degrades to `unknown` with its wire token kept for diagnosis; a closed
  socket, a timeout, or an unreachable device is `deviceUnavailable` and never a protocol code.
- A response that omits its own projection (a single-row response without `schedule`, a delete that does
  not report `deleted: true`) is a protocol violation, not a silent success.

## Cubit Ownership
- One cubit owns the whole feature (`presentation/bloc/schedules_cubit.dart`). Helpers are coordinators
  with typed callbacks, never extra cubits.
- Nothing loads on construction or from `build`: a surface calls `load()` from its own lifecycle and from
  Retry. A `load()` during a read joins it and queues at most one follow-up read.
- `SchedulesState.schedules` is non-empty only for `loaded`, so an offline or failed state cannot present
  a stale row as current. `DeviceConfig.isOnline == false` short-circuits before any request, and the
  open detail and preview are dropped with the list.
- A second identical in-flight action (same kind, same target) returns `ScheduleActionOutcome.busy` and
  sends nothing.
- A successful mutation re-reads the authoritative list instead of patching the response row in, because
  the list is ordered by the next instant the mutation may have moved. `schedule.changed` re-reads the
  list and the open run page through the same admission rules.
- Only the newest `schedule.preview` answer may emit; a superseded candidate never lands.
- `SchedulesState.conversationIdsWithSchedules` is derived from the current `schedule.list` snapshot. The
  sidebar marker and the conversation-delete warning consume it; do not add a second command for it.

## Domain Rules
- `Schedule` tolerates additive wire fields and malformed values; one unexpected row never breaks the list.
- `owner_kind` is read-only. A model-owned row without an owning conversation is `isOrphaned`: the surface
  offers Edit and Delete only, and `resume`/`run_now` answer `schedule_orphaned`.
- Run now stays available on a paused row and never resumes it. `suggestsPause` starts at the third
  consecutive failure; nothing auto-disables a schedule.

## Routes and Screens
- `AppRoutes.schedules` and `AppRoutes.scheduleDetail` are declared before `AppRoutes.session` so
  `schedules` is never captured as a session id.
- The two screens are thin shells: they create the cubit from DI for the route device, call `load()` once
  from `initState`, and own no list, form, or dialog state. Feature UI beyond the shells belongs to the
  task that adds it.
