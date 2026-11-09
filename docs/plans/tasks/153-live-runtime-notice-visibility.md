# Task 153 — Live Runtime Notice Visibility

Status: implemented (public `EastStarAI/sanad-agent`), one pull request, Client untouched.

## 1. Owner report

A conversation showed the Client banner `OpenCodeGo rate limit reached … retrying
automatically in 30s (attempt 1 of 3)` while the same session, at the same time, answered
`session show --json` with `execution_state: "resuming"`, `runtime_notice: null`, and
`retry: null`. The delegate supervisor then reported `progress_stall` roughly seventeen
minutes into a wait the daemon was still serving, and `session retry` refused the session as
"not blocked or waiting".

The Client was correct by construction: it renders the live `session.runtime_notice`
broadcast. Every other reader consumes the **durable** projection, and that projection was
the defect.

## 2. Root causes

| # | Owner | Defect |
|---|---|---|
| A | `session_query_handler.dart` (`_persistedNoticePayload`) | Only a `blocked` durable row survived the projection. A scheduled retry is persisted as `waiting` and a restart window is `resuming`, so both were dropped exactly when they mattered. |
| B | `session_query_handler.dart` | The durable store was resolved only through `_orchestrator?.persistedState`, so any composition without an orchestrator projected nothing at all — including for `blocked`. |
| C | `oneshot_runner.dart` (`DurableFollow.following`) | The re-attached branch journaled nothing and printed nothing: the notice that reached the dead socket was never replayed by the new transport. |
| D | `retry_command.dart` | The retry gate read the raw notice/snapshot statuses, so `resuming` + a `waiting` notice was refused. |
| E | `supervisor-stalls.mjs` | `silentForMs` was measured from the last signal only, with no notion of a wait the daemon announced. |
| F | `runtime_work_schema.dart` + repository + recovery service | `session_runtime_notices` had no `retry_attempt`/`retry_budget`, so a notice restored after a restart degraded to bare `retrying` and lost the budget that decides blocked versus retrying. |
| G | `supervisor-worker/follower.mjs` / `supervisor-views.mjs` | The daemon's structured reason was never recorded, so a retry that produced no artifact reported an unnamed cause. |

## 3. Owner decisions (2026-11-09) and what was implemented

1. **Projection breadth.** Every non-`cleared` durable notice is projected; the compaction
   `warning` keeps its stored, action-free shape. Recovery actions (`stop`, `retry`,
   `changeProvider`) are widened for every projected state so a scheduled wait is
   actionable.
2. **Store resolution.** `_persistedState ?? _orchestrator?.persistedState`.
3. **`session retry` on `resuming` + `waiting`.** Classified with
   `RuntimeRetryState.fromProjection`; a stated wait, a budget left, or a parked turn is
   retryable. The old `blocked | waiting` notice/snapshot fallback stays for older daemons,
   and a bare `resuming` notice is still refused because the attempt is already in flight.
4. **Stall clock.** `max(lastSignal, retryDeadline)`, where the deadline is
   `daemonRetry.resumeAt` else `retry_after_ms` measured from `stateSince`. A passed deadline
   still stalls. One exported rule (`retryDeadlineMs` / `evaluateProgress`) is called by
   `status`, `inspect`, and the worker journal.
5. **Cause vocabulary.** The daemon's reason is recorded verbatim as `daemonRetryReason`, is
   the task `cause` fallback when the worker artifact named none, and is printed by
   `status --brief` as `daemon-retry n/N <reason>`.
6. **No-counter notices.** A `waiting` state without counters still journals bare
   `retrying`.
7. **Scope.** Agent and supervisor only; the Client is untouched.

Additive `retry_attempt` / `retry_budget` columns persist and restore with the notice (both
nullable; an absent counter means "unknown budget", which is the previous behaviour, so no
backfill).

## 4. Definition of Done

| Item | Evidence |
|---|---|
| Durable projection | `agent/test/interfaces/platforms/sanad_gateway/session_runtime_notice_projection_test.dart` (4 cases; 3 failed before the change) |
| Relay re-attach | `agent/test/cli/oneshot_restart_follow_test.dart` → `a re-attached turn with a scheduled rate-limit retry journals retrying` |
| Retry acceptance | `agent/test/cli/session_command_test.dart` → the three `session retry` cases added around `accepts a scheduled wait whose durable owner is still resuming` |
| Counters across restart | `agent/test/core/provider_runtime/runtime_recovery_service_test.dart` → `a scheduled retry keeps its attempt counters across a restart` |
| Fake-provider 429 chain | `agent/test/engine/runtime/runner_recovery_coordinator_test.dart` → `a provider 429 reaches session show as a scheduled rate-limit retry` |
| Stall rule | `.agents/skills/delegate-task-supervisor/test/progress_stall_scheduled_retry_test.mjs` (10 fixed-clock cases) |
| Docs | `docs/technical/agent_database_schema.md`, `docs/technical/sanad_cli_architecture.md`, `docs/agent_engine/sanad_delegate_relay.md`, `docs/qa_maintenance/cli_session_observability_intervention_qa.md`, `.agents/skills/delegate-task-supervisor/SKILL.md` |

Baseline note: `test/supervisor_test.mjs` passes 60/60 on clean `origin/main` before this
change, so the failure recorded in the study notes was an environment/contention artifact,
not a pre-existing defect carried by this pull request.

## 5. Follow-ups (deliberately out of this change)

- `emitResuming()` still publishes a `resuming` notice without attempt counters, so a restart
  inside a transient resume still cannot report `retrying (n/N)` for that window.
- `LIVE_STATUSES` in `supervisor-stalls.mjs` still excludes `retrying`; making a `retrying`
  task stall-eligible once its deadline passes would be a behaviour expansion beyond the
  approved clock rule.
- The Client's countdown text ("Continuing automatically in 3s") is Client-side rendering of
  a live notice and needs no Agent change.
