---
title: "Task 112b — Recurring Wake Integration, Recovery, and Time Awareness"
status: delivered (draft pull request open)
current_gate: B4
remaining_estimate: 0%
depends_on: "112a"
evidence_id: "sched-recurrence"
evidence_fingerprint: "sha256:0e9237785d2fa58cbcfc8a8856c65d33452919bba2bd900701c4db22cf325bd1"
file_budget: 12
---

# Task 112b — Recurring Wake Integration, Recovery, and Time Awareness

Base branch: this task continues on the 112a branch, which starts from
`feature/view-image-docs-plan-77`. Do not modify the closed task files under `docs/plans/tasks/done/`.

## Goal

Recurring schedules fire exactly once per due instant, re-arm correctly from durable state after a
restart, never burst after downtime, stop immediately when canceled, and the runtime context tells
the agent today's date in the schedule's zone.

## Locked decisions

- **B-D1 — Advance before dispatch. (Already landed in the reviewed 112a gate.)** The next instant
  is persisted **before** the run event is emitted, so a crash cannot fire the same slot twice. A
  crash between persisting and emitting may skip one occurrence; that is the accepted direction of
  error (at-most-once, never duplicate). Do not re-implement it here; keep its regression test green
  and extend recovery around it.
- **B-D2 — Startup re-arm with an explicit missed-occurrence policy.** On initialization every
  enabled schedule computes its next future instant. A missed instant inside the grace window fires
  once immediately; a missed instant beyond grace is skipped with a recorded reason and the schedule
  advances to its next future instant. Grace is half the period clamped to `[120s, 2h]`. Never a
  burst, and never a silent drop.
- **B-D3 — Interval anchoring.** `interval` recurrence anchors on the stored last run, not on the
  restart instant, so a restart never re-anchors the cadence. Calendar recurrence is anchored on the
  wall-clock definition in the schedule's zone.
- **B-D4 — One-shot behavior is unchanged**, including its existing startup grace window. Only
  recurring kinds are re-armed.
- **B-D5 — Cancel and update are immediate.** `cancel` removes the in-memory timer and the row
  through `CronScheduler`; `update` replaces the timer with the recomputed instant. No timer may
  survive its schedule.
- **B-D6 — Outcome bookkeeping.** Each dispatch records `last_run_at` and `last_status`
  (`fired`, `skipped_missed`, `error`) so the listing can show the last outcome. A skipped
  occurrence carries the reason in the log and in `last_status`.
- **B-D7 — Time awareness (separable concern).** The runtime context gains one line stating today's
  date and the schedule zone label, derived per turn and containing **no clock time**, so the context
  stays byte-stable within a day and a long conversation sees the current day. This gate is a
  separate concern from scheduling and must remain independently revertible.
- **B-D8 — Out of scope.** Isolated/separate run sessions for scheduled work, delivery or reporting
  targets, pause/resume, run-now, retry/backoff after a failed run, and any Client surface.

## Gates

### B0 — Discovery

- [x] Read the 112a result: the scheduling module, the storage column set, and the merged tool.
- [x] Read `agent/lib/evolution/cron_scheduler.dart`, `agent/bin/daemon.dart` registration, and
      `agent/lib/interfaces/gateway_manager.dart` event handling to confirm the wake path.
- [x] Read `agent/lib/capabilities/runtime/runtime_context_builder.dart` and its call sites in
      `agent/lib/interfaces/runtime/local_runtime_orchestrator.dart`, and confirm the context is
      rebuilt per turn before changing it.
- [x] Record the B0 file list in this task before editing:
      - `agent/lib/evolution/scheduling/schedule_model.dart`
      - `agent/lib/evolution/cron_scheduler.dart`
      - `agent/lib/evolution/db/session_db.dart`
      - `agent/lib/evolution/db/agent_state_database.dart`
      - `agent/lib/capabilities/tools/schedule_task_tool.dart`
      - `agent/bin/daemon.dart`
      - `agent/lib/interfaces/gateway_manager.dart`
      - `agent/lib/capabilities/runtime/runtime_context_builder.dart`
      - `agent/lib/interfaces/runtime/local_runtime_orchestrator.dart`
      - `agent/lib/capabilities/runtime/AGENTS.md`
      - `agent/lib/engine/agent_context_assembler.dart`
      - `agent/test/capabilities/schedule_task_tool_test.dart`
      - `agent/test/evolution/scheduling_test.dart`
      - `docs/technical/agent_database_schema.md`
      - `docs/product/features.md`
      - `docs/agent_engine/capability_runtime.md`

### B1 — Durable dispatch and recovery

- [x] (landed in 112a) Dispatch persists the advanced next instant before emitting the run event
      (B-D1); the ordering regression test already exists and must stay green.
- [x] Implement the startup re-arm and the missed-occurrence policy (B-D2) with the grace window
      owned by one place, shared by every recurring kind.
- [x] Implement interval anchoring on the stored last run (B-D3) and preserve one-shot behavior
      (B-D4).
- [x] Record `last_run_at` / `last_status` per dispatch (B-D6). The `fired` path landed in 112a;
      this gate adds the `skipped_missed` and `error` paths and their reasons.
- [x] Tests cover: due-inside-grace firing once on startup and advancing; due-beyond-grace skipping
      with a recorded reason and advancing without a burst; a durable-ordering test proving no double
      fire when the process stops between persisting and emitting; interval cadence unchanged across
      a simulated restart; and one-shot behavior unchanged.

### B2 — Mutation liveness

- [x] `cancel` stops the timer and removes the row; `update` replaces the timer with the recomputed
      instant (B-D5).
- [x] Tests cover: no fire after cancel; no orphan timer after cancel; the timer set after an
      `update` matches the recomputed instant; disposal cancels every timer.

### B3 — Time awareness (separable)

- [x] Add the date-and-zone line to the runtime context (B-D7) with no clock time, sourced from the
      same zone resolution used by scheduling.
- [x] Tests cover: the line's presence and shape; the zone label matching the resolved zone; and
      byte-stability within one day.

### B4 — Documentation and verification

- [x] Update the scheduling documentation for the wake, recovery, and missed-occurrence policy and
      the outcome fields.
- [x] Reconcile the `enabled` column description in `docs/technical/agent_database_schema.md`
      ("0 if paused") with the fact that pause/resume is out of scope, so the column description does
      not imply an unimplemented feature.
- [x] Update the runtime-context documentation if it enumerates the context sections.
- [x] Report the gate outcome with exact commands, preserved exit status, and bounded output.

## Acceptance criteria

- [x] A `daily` schedule whose instant passed 30 minutes ago fires exactly once on startup and
      advances to the next future instant, with `last_status='fired'`.
- [x] A schedule missed by more than its grace window fires zero times, advances to the next future
      instant, and records `last_status='skipped_missed'` with a logged reason.
- [x] Downtime spanning several occurrences produces one fire at most, never a burst.
- [x] No double fire is observable when the process stops between persisting the advanced instant and
      emitting the event (regression of the 112a ordering fix).
- [x] An `interval` schedule keeps its cadence across a restart (no re-anchoring).
- [x] After `cancel`, no event is emitted for that schedule and no row remains.
- [x] A `daily` schedule at a fixed local time keeps that local time across both daylight transition
      directions when the zone is `local`.
- [x] The runtime context contains today's date and zone, contains no clock time, and is identical
      within the same day.
- [x] `fvm dart analyze` is clean and the focused test files pass with preserved exit status.

## Review gate and delivery

The implementer's diff was reviewed by an independent agent before this task was closed. The reviewer
confirmed or refuted each recorded hypothesis with evidence and repaired what it confirmed:

- **S1** — the time-awareness line was asserted only through its helper with overridden inputs, so the
  production resolution path was untested: the tests now assert the exact line shape and the absence of
  clock time on the built context and exercise the default build path, resolving the zone through the
  configured default.
- **S2** — preserving `last_run_at` on a skipped occurrence was deliberate but undocumented and
  unasserted: it is now stated in the product and schema documents, explained at the call site, and
  covered for both a calendar and an interval schedule, including cadence anchoring across a restart.
- **S3** — a stored last run far in the past was resolved by stepping one interval at a time: interval
  occurrence and most-recent-due computation now use step arithmetic with a bounded correction, with
  tests proving termination and at most one fire.
- **S4** — refuted as a defect: one-shot startup behavior and its existing grace window are unchanged and
  covered.
- **S5** — refuted as a defect: the capability runtime importing the scheduling module matches the layer
  order already used by the scheduling tool, and the module stays the single source of truth for zone
  resolution.
- **S6** — the duplicated one-shot branch in the grace policy was removed.

Independently re-verified by the orchestrator after the review, not accepted on report alone:
`fvm dart analyze` exit 0 and the full agent fast suite exit 0 with 2752 passed and 14 skipped before the
main merge, and 2826 passed and 14 skipped after it.

Delivery: commit on the same branch and pull request as 112a. The branch was then brought onto current
`main` with a merge commit; the six conflicted files were conflicts of lineage only (main's content was
byte-identical to this branch's pre-112a base), so this branch's version was authoritative. No merge or
ready-for-review transition happens without explicit authorization.

## Definition of Done

- [x] `cd agent && set -o pipefail; fvm dart analyze 2>&1 | tail -5`
- [x] `cd agent && set -o pipefail; fvm dart test test/evolution 2>&1 | tail -5`
- [x] Documentation updated in this change (B4); no stale statement left in the owning documents.
- [x] Diff reviewed for scope: B3 stays an isolated, revertible concern, and no file under
      `docs/plans/tasks/done/` is modified.
- [x] **Do not commit.** The orchestrator reviews the diff, re-runs the gates, and commits.
- [x] Report: status (`Succeeded` / `Failed` / `Unsure`), touched files, exact commands with
      outcomes, skipped coverage, and unresolved uncertainty.
