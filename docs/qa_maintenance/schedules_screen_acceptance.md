---
title: "Schedules Screen Live Acceptance"
description: "Live acceptance record for the Task 139 Schedules list, detail page, run history, editor, and sidebar marker: the two local legs on the shipped code, the finding-by-finding fixes with re-live proof, the code-inspected cloud parity decision, and the obstacles worth keeping for future testers."
---

# Schedules Screen Live Acceptance

> **Owning task:** [Task 139 — Schedules Screen, Schedule Control, and Run History](../plans/tasks/139-client-schedules-screen.md)
> **Protocol:** [Schedule Control Protocol](../technical/schedule_control_protocol.md)
> **Product surface:** [Sanad Agent Features](../product/features.md) §Scheduling

## Result

| Leg | Scope | Result |
|---|---|---|
| Local, one Test Home (first pass) | Task 139 acceptance steps 1–10 | **10 steps exercised** — 7 clean passes; steps 2, 5, and 10 exposed defects (F1–F3), and two freshness/display defects (F4, F5) were recorded alongside them |
| Local, one Test Home (re-live) | The same code after F1–F5 were fixed | **R1–R6 PASS** — every defect closed, no regression in steps 3, 4, or 10 |
| Cloud relay | Task 139 acceptance step 11 | **Verified by code inspection** (owner decision, 2026-10-24) — see [Step 11](#step-11--cloud-parity-verified-by-code-inspection) |

Both legs ran on the same shipped code. The first leg used PR #328 head `237749e6`; the re-live used
`5f801029`, whose tree is byte-identical to the merge commit `59c7bb4b` that now carries the feature
(`git diff --quiet 5f801029 59c7bb4b` exits 0). The findings therefore describe earlier states of the
same screens, not a different implementation.

## Candidate provenance

Every commit below is on `main`. The acceptance target is the client and agent code of the last two
rows together.

| Item | PR | Merge commit on `main` |
|---|---|---|
| 139-01 state columns, run table, repositories | #312 | `e646a99753f9` |
| 139-02 scheduler control, run recorder, schedule conversations | #317 | `e2d5daef0934` |
| 139-03 `schedule_task` pause/resume/run_now and name | #321 | `96da5bd74b0e` |
| 139-04 schedule protocol: commands, queries, events | #325 | `b99641fc422c` |
| 139-05 reusable model and workspace chips | #322 | `319aa24a86b2` |
| 139-06 Client data client, cubit, routes | #326 | `3f8654fe2ae9` |
| 139-07 Client screens: list, detail, run history, editor, marker | #328 | `59c7bb4b700d` |
| Continuous-conversation and run-anchor fix (live acceptance of #328) | #329 | `61595acbc7c6` |

The protocol family itself was live-checked one layer down, at TH3, against PR #325 `60f2ce65`: every
response, broadcast, and error code matched the spec, every rejected request mutated nothing, and no
schedule canary reached a scheduler or handler log. That leg is the wire-level evidence behind the UI
steps here; it is not repeated in this record.

## Environment

| Item | Value |
|---|---|
| First leg candidate | `237749e6` (`feat(schedules): 139-07 …`, PR #328 head) |
| Re-live candidate | `5f801029` (`fix(schedules): 139-07 delta 2 …`), containing `61595acb` (#329); tree identical to `59c7bb4b` |
| Test Home | TH1 (`~/.sanad-test`) only; TH3 was used by the 139-04 wire leg. The primary Home was never selected. |
| Runtime | `sanad-dev run all --driver --no-cloud --home <test-home> --background`, then bounded `status`, `logs`, `restart agent`, `stop agent`, and `run agent` |
| Managed routes | the Test Home's own agent (local gateway) and one driver-enabled Client, both owned by that launcher; `Cloud gateway: disabled` for the acceptance legs |
| Route isolation | `status` reported the Test Home as requested, resolved, and selected Home, the worktree's own agent port and VM-service port, and `Runtime source commit` equal to the leg's candidate. Nothing resolved to the primary Home or the primary local-gateway port. |
| DB reads | `sqlite3 "file:<test-home>/state.db?mode=ro"` only — no write, no schema change |
| Shapes used instead of waiting days | `interval_minutes: 1` for scheduled fires a minute apart, `daily 09:00 local` for the create/preview path, `interval_minutes: 30` for manual and failure probes, and the product's own `sanad_agent session stop` for a turn that must not finish |
| Out dir | the delegate run's own out directory, outside the repository |

No token, credential, secret, or user prompt content is reproduced in this document.

## Scenario evidence — steps 1–10

The verdict column is the final one. Where the first leg failed, the re-live check that closed it is
named; where the first leg passed, nothing changed that step's code path.

| # | Acceptance step (abridged) | First leg | Re-live | Final |
|---|---|---|---|---|
| 1 | `daily` schedule created from the screen with no conversation: it appears in the list, `next_run_at` is in the future, no conversation exists yet | PASS — `schedules_empty` → `schedules_create_btn` → `schedule_editor_sheet`; the row carried `conversation_mode=continuous`, `next_run_at` ~7 h ahead, and the session count did not move | — | **PASS** |
| 2 | The first run creates exactly one conversation in the chosen workspace with the chosen provider/model; a second run appends to it | **FAIL (F1)** — the first fire was correct; every later *scheduled* fire created a new conversation (3 fires → 3 conversations on a `continuous` row) | R1: four scheduled fires at `interval_minutes: 1` all landed in one conversation, `run_session_id` never churned, the session count rose by exactly 1, the conversation carried the editor's workspace/provider/model, and the agent logged exactly one `Created conversation` line | **PASS** |
| 3 | `new_each_run`: two runs produce two conversations, each reachable from its run row | PASS | R6: two `Run now` runs on a `new_each_run` row produced two conversations; each run row's Open conversation opened **its own** conversation (route key `conversation-timeline:<sessionId>`) | **PASS** |
| 4 | Run now fires immediately with `trigger=manual` and a duration, the next instant is unchanged, and the same action on a paused row leaves it paused | PASS — run row at +1 s, `next_run_at` unchanged, `enabled` stayed `0` | R6: `enabled` stayed `0`, `next_run_at` byte-identical, the run appended to the existing conversation | **PASS** |
| 5 | Run history shows `running` in flight and a terminal state afterwards with the error text, and **Open conversation lands on that run's user message** | **FAIL (F2)** — the states and the error text were correct; the anchor opened the conversation at its tail | R2: with the conversation padded to 22 messages, one driver batch (tap + probe at +200 ms and after a 2.5 s settle) found the run's own user row and never the tail; an in-flight run's button is disabled while its `session_id` is empty | **PASS** |
| 6 | Pause stops the timer and survives a daemon restart; resume re-arms at the next future instant | PASS — no fire past the paused instant, `CronScheduler initialized with 1 active tasks` after the restart, resume recomputed from *now* | — | **PASS** |
| 7 | Delete removes the schedule and its run rows and keeps conversations readable; deleting a conversation pauses its schedules, deletes none, and resuming a `continuous` one continues in a new conversation | PASS with a tooling gap — schedule delete went through the UI (`scheduled_tasks` 0, `scheduled_task_runs` 0, all four conversations readable); the conversation-delete **dialog** could not be opened by the driver, so the delete used the product's own `sanad_agent session delete`, and its consequence was verified live (schedule kept and paused, `run_session_id` cleared, run rows kept, resume created a new conversation) | — | **PASS** — the warning's rendering is covered by widget test and its condition by the live marker set; see [step 7](#step-7--the-conversation-delete-warning)
| 8 | A failing run shows the badge, the notice inside the run's conversation, and the pause suggestion at the third consecutive failure; nothing auto-disables | PASS with a freshness observation (F5) — six consecutive failures kept `enabled=1`; the suggestion text was reachable only through `ui find --within schedule_failure_notice`; the badge lagged until the next list read | R5: with the page never navigated, the badge appeared at `3` and then incremented to `4` | **PASS** |
| 9 | A model turn in an unrelated conversation cannot pause, run, or delete a screen-created schedule; the same action from the screen succeeds | PASS — the tool refused with the owner named (`… is owned by the device user and cannot be modified from conversation …`) and changed nothing; the screen action then succeeded | — | **PASS** |
| 10 | Agent stopped → "Unavailable" with disabled actions and no stale list, then recovery without a client restart | **PARTIAL (F3)** — banner, absence of any stale row, and recovery were correct; **New schedule** stayed enabled and still opened the form | R3: banner + retry present, `schedules_create_btn` `enabled=False`, no list and no row action, the tap opened no sheet, and recovery refreshed in ~22 s with the same client process | **PASS** |

Cross-cutting observations that held on both legs: the Schedules page keeps one device-scoped cubit, so
returning from a conversation did not re-fetch or flash; measured transitions were 0.5–0.9 s; run
history rendered in under a second.

## Findings

Every finding is closed. The fix column names the commit, and the proof column names the re-live check
that would fail again if the fix regressed.

| # | Finding | Severity | Fix | Re-live proof |
|---|---|---|---|---|
| F1 | A `continuous` schedule opened a **new conversation on every scheduled fire**: the timer dispatched with the record captured when it was armed, and `ScheduleConversationFactory` persisted the new `run_session_id` without the in-memory record learning it. `run_now` re-read the row per call and was already correct. | high (S3) | #329 `61595acb` — a timer or recovery dispatch reads the schedule row before resolving its conversation | R1 — four fires, one conversation, one `Created conversation` log line |
| F2 | **Open conversation** never landed on the run's user message: a message UUID was passed as a canonical `anchor_event_id`, so the anchored load failed silently and the conversation opened at its default place. | high (S20) | #329 `61595acb` adds `anchor_event_id` to the run projection (canonical `history:<sessionId>:<rowId>:user_message:0`, built by the single owner `SessionHistoryEventId`); #328 `59c7bb4b` (delta 2, `5f801029`) makes the Client send only that value | R2 — the padded conversation rendered the run's own user row and not the tail |
| F3 | **New schedule** stayed enabled while the page showed Unavailable: the action was gated on the device's `isOnline` flag, which had not flipped while the schedules state was already `deviceUnavailable`. | medium (S18) | #328 `59c7bb4b` (delta 1, `2dc4f5c9`) — one owner, `scheduleActionsEnabled(device:, state:)`, closes create, pause, resume, run now, edit, delete, and the editor's submit when the device is offline **or** the state is `deviceUnavailable` | R3 — `schedules_create_btn` disabled, and a dispatched tap opened no sheet |
| F4 | `local`-zone instants rendered as their **UTC** wall clock in the preview, the list, and the run-history times (`09:00` local appearing as `6:00 AM`). | low (display) | #328 `59c7bb4b` (delta 1, `2dc4f5c9`) — `ScheduleInstant` renders the offset the Agent wrote; `zone: local` means the *Agent's* zone | R4 — `Next run: … 9:00 AM` on the create and edit previews, run-history times in the same designator, `6:00 AM` absent from the tree, and a `-05:00` negative-offset probe rendered `12:00 PM` instead of the host clock's `8:00 PM` |
| F5 | The failure badge lagged one failure: a failed run broadcasts no `schedule.changed`, so the badge only refreshed on the next list read. | low (freshness) | #328 `59c7bb4b` (delta 1, `2dc4f5c9`) — the `schedule.run_failed` notice is also a freshness signal: the cubit re-reads the list (and the open schedule's first run page) through its coalesced load and never projects the notice | R5 — badge absent at 2 failures, `3` at the third, `4` at the fourth, with no navigation |

F1–F5 were the only product findings. Step 7's dialog gap is a tooling gap, not a sixth finding; it is
recorded below and as obstacle 3.

## Step 7 — the conversation-delete warning

Step 7 has two halves. The schedule half was verified end to end in the UI. The conversation half could
not be driven through the Client's dialog, so its **warning** is verified by widget test plus its live
condition, and the delete itself was performed through the product's own agent command — the same
agent-side hook the Client calls.

Recorded as a tooling gap rather than a defect, because the product path works for a human and the
condition it depends on was proven live:

- **The condition:** the conversation that owned a schedule carried `schedule_marker_<sessionId>` in the
  sidebar. That marker and the S23 warning read the same `schedule.list` snapshot, so "the warning would
  render for this conversation" is true by the live evidence, not by inference.
- **The rendering:** `client/test/widget/schedules/schedules_marker_test.dart` asserts the warning renders
  only for a conversation that owns schedules and not for one that does not.
- **The consequence:** deleting the conversation through the product's own
  `sanad_agent session delete <sessionId>` left the schedule present and **paused** (never deleted),
  cleared its `run_session_id`, kept its run rows, and resuming from the screen created a new conversation
  on the next fire.
- **What remains open for tooling:** the hover-gated more button is still the only way in. Stable keys
  `conversation_delete_confirm_btn` and `conversation_delete_cancel_btn` (added in #328 `59c7bb4b`, delta 1)
  remove the second half of the gap — both buttons are addressable once the dialog is open — not the first.
- **Why it is not a finding:** nothing in the shipped Client is wrong. The driver lacks hover, long-press,
  and pointer-move, and the long-press sheet entries are unkeyed.

## Step 11 — cloud parity (verified by code inspection)

The task's step 11 asked for steps 1–10 repeated "over the cloud relay with the local daemon not directly
reachable". Owner decision 2026-10-24 replaces that with a code-inspection proof, the same decision
recorded for Task 140 in
[Secrets Screen Live Acceptance](secrets_screen_acceptance.md#step-10--cloud-parity-verified-by-code-inspection):
a same-device pair whose local gateway is switched off is **not a supported product configuration**
([Communication Protocols](../technical/communication_protocols.md) §3.2). A real cloud live test needs
two Test Homes configured for the cloud, one Agent and one Client each, both signed in.

The schedules feature has exactly one command path, and it cannot observe or select a transport:

| Claim | Citation |
|---|---|
| The feature speaks the protocol through one data client, which holds one `DeviceCommandClient` and nothing transport-shaped | `client/lib/features/schedules/data/schedules_client.dart:32` (`final DeviceCommandClient _commands;`), documented at `:16`–`:18` |
| Every command and query leaves through that one client | `client/lib/features/schedules/data/schedules_client.dart:225` (`_commands.request(...)` inside the single `_request` helper); broadcasts read `:182` (`_commands.events(...)`) |
| That client resolves transport per call, entirely inside the coordinator | `client/lib/features/devices/data/device_command_client.dart:19` (class), `:26` (coordinator field), `:46` (`ensureConnectedEndpointForAgent` in `request`), `:33` (the same call in `events`) |
| The route decision is the coordinator's local-reachability rule | `client/lib/features/devices/data/device_connection_coordinator.dart:183`–`185` (`resolve()` → `scope = localReachable ? local : cloud`), `:266` (`isLocalReachable` = desktop ∧ same hardware ∧ live local socket) |
| The cubit states the invariant and does not branch on scope | `client/lib/features/schedules/presentation/bloc/schedules_cubit.dart:292`–`:296` |
| Nothing under `client/lib/features/schedules/` can observe a transport | search over all 24 Dart files in the feature: **zero** matches for `ConnectionScope`, `isLocalReachable`, `preferred_connection_scope`, `AppConfig`, or a gateway URL; the only device flag read is `DeviceConfig.isOnline`, which is the S18 availability rule, and `schedule_device_scope.dart:16` reads the device *inventory* to resolve a route's `deviceId` |
| The screens themselves never branch | `schedules_screen.dart:97` and `schedule_detail_screen.dart:111` gate actions on `scheduleActionsEnabled(device:, state:)`; `schedule_availability.dart:18` owns that rule and reads no transport symbol |
| The agent side is one family, not one path per transport | `docs/technical/schedule_control_protocol.md` §2 (`device_command` envelope, one canonical event per command, handlers never resolve a runtime owner), §4.1 (accepted fields), §9 (one Client contract for both routes) |

Because the command family, the projection, the typed errors, and the strings are one shared path, a
Client reaching a device over the cloud exercises the code the local leg exercised. The local leg proves
the Agent side against a real database and real provider turns; the cloud leg would re-prove transport,
which the cross-transport suites already cover.

## Obstacles worth keeping for future testers

1. **Isolate a scheduler defect by comparing the timer path with the manual path (F1 cost ~12 min).** The
   first two fires must be waited for (60 s each), and the difference only appears on the *second* fire.
   The evidence that separates them: `run_session_id` churn in the row, the session count, and one
   `ScheduleConversationFactory` log line per fire.
2. **Proving an anchor needs a long conversation and one driver batch (F2 cost ~14 min).** Pad the
   conversation to ~20 messages, open the conversation from a *different* active conversation first, then
   issue `tap` + `wait_for` at +200 ms **and** after a ~2.5 s settle inside a single `ui batch`. A plain
   `tap` waits 2 s and hides "opened at the tail" behind "opened somewhere".
3. **The conversation more-button is hover-gated** (`MouseRegion`/`_isHovered`). Taps by key, by
   `--within` the row, and by coordinates are all silent. Use the product CLI for the delete
   (`sanad_agent session delete <sessionId>`), and read the marker set for the warning condition.
4. **A keyed SnackBar hides its keyed grandchildren from `snapshot`.** `schedule_failure_notice_suggestion`
   is rendered but invisible to a page dump; `ui find --within schedule_failure_notice --type Text` finds
   it. Same class of limitation as the 140-04 `walkKeyedChildren` gap.
5. **The list row's and detail page's "Next run" lines are unkeyed plain `Text`**, so `sanad-dev ui` cannot
   read them (`find --text`, `--within` the row, `--within` the tab, and `--type Text` all return 0). Verify
   the formatter through the keyed editor preview (create and edit) and the run-history times instead, and
   use a negative offset (`12:00` at `-05:00`) to rule out the host clock.
6. **`enter-text` on `schedule_editor_interval_field` and `schedule_editor_time_field` always reports "no
   observable effect"** — a `TextFormField` value is not exposed to the inspector. Use `--no-verify`; the
   submitted row (`interval_minutes=1`, `at_time=09:00`) and the preview are the proof. The same applies to
   `schedule_editor_mode_switch`, which reports `no_observable_change`; the created
   `conversation_mode` is the proof.
7. **A schedule with no workspace has no tools.** A fail probe that asks for `shell_execute` is refused with
   "I don't have a `shell_execute` tool available in this session". Produce failures with a long-form
   writing turn plus `session stop` instead, and choose a workspace when a probe needs tools.
8. **A blocked turn keeps its run `running`.** End it with the product's own `sanad_agent session stop
   <sessionId>` — that is also how the failure rows were produced. Under the default workspace policy each
   turn needs one `permission_option_once` approval; never choose "always allow" for an acceptance run.
9. **`session stop` must be issued immediately after `Run now`.** A `session stop` that starts after two
   navigation taps plus a cold `fvm dart run` lands after a short turn has already succeeded; issue the tap
   and the stop in the same shell.
10. **The failure badge does not exist below three consecutive failures.** `suggestsPause` is
    `consecutiveFailures >= 3`, so F5 can only be observed by reaching three and then four.
11. **A schedule-created conversation may not be in the sidebar's rendered page.** It was the most recently
    updated session and still appeared zero times in the sidebar tree; reach it from the run row's Open
    conversation instead.
12. **Stop the whole group before relaunching with different flags.** While a managed runtime exists,
    `run client --driver` is satisfied by a component-control `start` that relaunches the Client from its
    recorded profile; `stop all --force` first, then launch the group once with the intended flags.
13. **A `restart agent` can leave the recorded runtime source stale** and briefly report the previous
    commit; verify the leg's candidate with `status` after a `stop`/`run` cycle rather than trusting a
    restart's own echo.

Timing: the first leg took ~59 minutes (the F1 and F2 investigations were ~26 of them); the re-live took
~28 minutes.

## What a cloud live leg would need

Two Test Homes configured for the cloud — one Agent and one Client each, both signed in, both devices
present in the account — with the schedule commands dispatched to the *remote* Home. The same-device
relay-only shape is not a supported configuration and is not a valid test setup; see
[Communication Protocols](../technical/communication_protocols.md) §3.2.
