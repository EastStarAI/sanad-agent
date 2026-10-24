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
  never written to state, a log, or history. The notice is nevertheless a **freshness signal**: a failed
  run broadcasts no `schedule.changed`, so it triggers the cubit's own coalesced list re-read (and the
  open schedule's first run page), which is what keeps `consecutive_failures` and the failure badge
  current. Ask the Agent for the authoritative snapshot; never patch a row from the notice.
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
- **Open conversation anchors on `anchor_event_id` and nothing else.** It is the canonical history event
  id of the run's user message (`history:<sessionId>:<rowId>:user_message:0`), so it is what
  `SessionMessagesCubit.requestHistoryAnchor` receives and what the viewport anchor records. The run's
  `message_id` is a message identity, not a canonical event id, and substituting it makes the anchored
  load fail and the conversation open at its tail (S20). A `null` anchor — no position, an unresolvable
  one, or an older Agent that does not send the field — opens the conversation at its default position
  and is not an error. The action is offered whenever the run has a `session_id`; a run still in flight
  has none yet.

## Routes and Screens
- `AppRoutes.schedules` and `AppRoutes.scheduleDetail` are declared before `AppRoutes.session` so
  `schedules` is never captured as a session id.
- Both routes render inside the real device chrome: `AppRouter` builds `HomeScreen(deviceContent:
  SchedulesRouteSurface(...))`, and `SchedulesRouteSurface` resolves the chrome's cubit and renders
  `SchedulesScreen` or `ScheduleDetailScreen` in the content slot. The routes stay device-scoped and align
  the active device with the route device; conversation routing does not run while a device content
  surface owns the slot.
- `SchedulesChromeScope` (mounted by `HomeScreen`) owns **one** device-scoped `SchedulesCubit` for the
  chrome's active device and exposes it through `SchedulesScope`. The sidebar marker, the conversation
  delete warning (S23), the run-failure notice, and both routes read that one snapshot, so the marker
  costs no extra command. The scope drops the snapshot when the device goes offline and re-reads when it
  returns. A page pumped without the scope creates its own cubit, so a focused test never needs the
  chrome.
- One cubit for the feature: helpers are coordinators with typed callbacks, never a second cubit. A
  surface calls `load()` from its own lifecycle and from Retry, never from `build`.
- Screens own presentation state only: the editor's draft, the open tab, and the hover state. They never
  compute an occurrence (the preview is the Agent's answer), never parse a cursor, and never branch on
  local/cloud transport.
- Availability is decided by the row's own derived facts, not by the surface: run now stays enabled on a
  paused row and never resumes it (S21), an orphaned model-owned row offers edit and delete only
  (S23, D10), and every action is disabled while the device cannot accept it (S18).
- The recurrence summary and every status label are composed Client-side from the structured row fields
  and `AppLocalizations`. No Agent sentence becomes UI copy; the Agent `message` is never rendered.
- The form reuses the shared new-conversation widgets — `ComposerWorkspaceChip`, `ComposerModelChip`, and
  the `ModelPickerDialog` that chip opens. A second picker implementation under this feature is a guard
  failure (`client/test/guards/schedules_model_picker_guard_test.dart`); the primary action sits outside
  the scrolling body so a long form never hides it.
- A failed run reaches the user as the chrome's non-modal notice: localized, naming the schedule, with
  the pause suggestion only when `suggest_pause` is true, and carrying no error text. The bounded failure
  text lives in the run history row and nothing is persisted from the live event.
- Availability has one owner: `scheduleActionsEnabled(device:, state:)`. Every action — create, pause,
  resume, run now, edit, delete, and the editor's submit — is closed when the device is offline **or** the
  state is `deviceUnavailable`, so the banner and the actions can never disagree. An editor opened while
  the device could answer refuses submit with the typed unavailable copy instead of letting the request
  fail.
- Instants are rendered in the offset the Agent wrote them with (`ScheduleInstant`), never in the
  Client's own timezone: `zone: local` means the *Agent's* local zone, so a remote device's 09:00 must not
  become 06:00. An explicit `±HH:MM` zone keeps its stored offset.
