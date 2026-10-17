---
title: "Task 112b — Recurring Wake Integration, Recovery, and Time Awareness"
status: pending
current_gate: B0
remaining_estimate: 100%
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

- **B-D1 — Advance before dispatch.** The next instant is persisted **before** the run event is
  emitted, so a crash cannot fire the same slot twice. A crash between persisting and emitting may
  skip one occurrence; that is the accepted direction of error (at-most-once, never duplicate).
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

- [ ] Read the 112a result: the scheduling module, the storage column set, and the merged tool.
- [ ] Read `agent/lib/evolution/cron_scheduler.dart`, `agent/bin/daemon.dart` registration, and
      `agent/lib/interfaces/gateway_manager.dart` event handling to confirm the wake path.
- [ ] Read `agent/lib/capabilities/runtime/runtime_context_builder.dart` and its call sites in
      `agent/lib/interfaces/runtime/local_runtime_orchestrator.dart`, and confirm the context is
      rebuilt per turn before changing it.
- [ ] Record the B0 file list in this task before editing.

### B1 — Durable dispatch and recovery

- [ ] Make dispatch persist the advanced next instant before emitting the run event (B-D1).
- [ ] Implement the startup re-arm and the missed-occurrence policy (B-D2) with the grace window
      owned by one place, shared by every recurring kind.
- [ ] Implement interval anchoring on the stored last run (B-D3) and preserve one-shot behavior
      (B-D4).
- [ ] Record `last_run_at` / `last_status` per dispatch (B-D6).
- [ ] Tests cover: due-inside-grace firing once on startup and advancing; due-beyond-grace skipping
      with a recorded reason and advancing without a burst; a durable-ordering test proving no double
      fire when the process stops between persisting and emitting; interval cadence unchanged across
      a simulated restart; and one-shot behavior unchanged.

### B2 — Mutation liveness

- [ ] `cancel` stops the timer and removes the row; `update` replaces the timer with the recomputed
      instant (B-D5).
- [ ] Tests cover: no fire after cancel; no orphan timer after cancel; the timer set after an
      `update` matches the recomputed instant; disposal cancels every timer.

### B3 — Time awareness (separable)

- [ ] Add the date-and-zone line to the runtime context (B-D7) with no clock time, sourced from the
      same zone resolution used by scheduling.
- [ ] Tests cover: the line's presence and shape; the zone label matching the resolved zone; and
      byte-stability within one day.

### B4 — Documentation and verification

- [ ] Update the scheduling documentation for the wake, recovery, and missed-occurrence policy and
      the outcome fields.
- [ ] Update the runtime-context documentation if it enumerates the context sections.
- [ ] Report the gate outcome with exact commands, preserved exit status, and bounded output.

## Acceptance criteria

- [ ] A `daily` schedule whose instant passed 30 minutes ago fires exactly once on startup and
      advances to the next future instant, with `last_status='fired'`.
- [ ] A schedule missed by more than its grace window fires zero times, advances to the next future
      instant, and records `last_status='skipped_missed'` with a logged reason.
- [ ] Downtime spanning several occurrences produces one fire at most, never a burst.
- [ ] No double fire is observable when the process stops between persisting the advanced instant and
      emitting the event.
- [ ] An `interval` schedule keeps its cadence across a restart (no re-anchoring).
- [ ] After `cancel`, no event is emitted for that schedule and no row remains.
- [ ] A `daily` schedule at a fixed local time keeps that local time across both daylight transition
      directions when the zone is `local`.
- [ ] The runtime context contains today's date and zone, contains no clock time, and is identical
      within the same day.
- [ ] `fvm dart analyze` is clean and the focused test files pass with preserved exit status.

## Definition of Done

- [ ] `cd agent && set -o pipefail; fvm dart analyze 2>&1 | tail -5`
- [ ] `cd agent && set -o pipefail; fvm dart test test/evolution 2>&1 | tail -5`
- [ ] Documentation updated in this change (B4); no stale statement left in the owning documents.
- [ ] Diff reviewed for scope: B3 stays an isolated, revertible concern, and no file under
      `docs/plans/tasks/done/` is modified.
- [ ] **Do not commit.** The orchestrator reviews the diff, re-runs the gates, and commits.
- [ ] Report: status (`Succeeded` / `Failed` / `Unsure`), touched files, exact commands with
      outcomes, skipped coverage, and unresolved uncertainty.
