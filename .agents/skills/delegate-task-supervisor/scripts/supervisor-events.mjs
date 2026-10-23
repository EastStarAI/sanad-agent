// Shared journal vocabulary for the supervisor scripts.
//
// Two readers consume the same `events.jsonl` journal: `watch-once.mjs` (one
// event, one run, read-only) and `supervisor.mjs watch` (many runs, durable
// cursor). They must agree on which records are worth waking an orchestrator,
// so the sets live here instead of being copied into both scripts.

// Terminal task states. A task in any of these never runs again unless it is
// explicitly continued as a new attempt.
//
// `follow_lost` is terminal on purpose: once the supervisor can no longer read
// the durable session it followed, nothing can report that turn's outcome, so a
// coordinator has to decide instead of waiting for a wake-up that cannot come.
export const TERMINAL_STATUSES = new Set([
  'completed',
  'failed',
  'timeout',
  'aborted',
  'interrupted',
  'cancelled',
  'incomplete',
  'needs_review',
  'follow_lost',
  'agy_unavailable',
  'opencode_unavailable',
]);

// Non-state notices that still need a human or coordinator decision: a stall
// means nothing is moving, `worker_lost` means the last runner vanished, and
// `retry_exhausted` means recovery was already attempted and failed.
// `progress_resumed`, `auto_retry`, and `retry_sent` are deliberately absent:
// recovery needs no intervention and a sent retry is the caller's own action.
export const ACTIONABLE_KINDS = new Set([
  'queued_stall',
  'progress_stall',
  // A task whose process outlived its supervisor is still running, but nothing
  // owns it any more: the coordinator must decide to wait for it or to stop it.
  'worker_orphaned',
  // The run's supervisor is gone while work is still non-terminal: no further
  // progress is possible without a new decision. Distinct from a stale progress
  // notice, which only says one task went quiet.
  'supervisor_dead',
  // The automatic recovery policy gave up; a coordinator must take over.
  'retry_exhausted',
]);

// States an orchestrator must react to: terminal outcomes plus every stop that
// asks for input or permission. `running`, `resuming`, `following`, `queued`,
// `held`, `waiting`, and plain progress are not actionable.
//
// A followed task mirrors its durable state into these same statuses, so a
// question, a permission request, a block, or a failure reaches a coordinator
// whether the worker is still attached or already gone.
export const ACTIONABLE_STATUSES = new Set([
  ...TERMINAL_STATUSES,
  'blocked',
  'needs_input',
  'needs_permission',
]);

// `watch-once` keeps its wider legacy wake set (it also surfaces `waiting` and
// `resuming`, which are useful for a single blocked waiter but noisy in a
// coordinator stream). `following` is deliberately absent: following a live
// turn is transport progress, not a decision. Run-level notices are matched on
// `to` because that is where the supervisor journal repeats their kind.
export const WATCH_STATUSES = new Set([
  ...ACTIONABLE_STATUSES,
  'waiting',
  'resuming',
  'queued_stall',
  'supervisor_dead',
  'retry_exhausted',
]);

/**
 * True when a journal record deserves an orchestrator wake-up.
 *
 * The record shape is the supervisor journal: `to` is the resulting state or
 * notice kind, and `kind` repeats the notice kind. Run-level records
 * (`run_completed`) are excluded because they are derived from task outcomes
 * the caller already received.
 */
export function isActionableEvent(event) {
  if (!event || typeof event !== 'object') return false;
  if (event.kind === 'run_completed') return false;
  if (event.kind && ACTIONABLE_KINDS.has(event.kind)) return true;
  return ACTIONABLE_STATUSES.has(event.to);
}

/**
 * True when a `watch-once` caller should receive this record by default.
 */
export function isWatchableEvent(event) {
  if (!event || typeof event !== 'object') return false;
  if (event.kind === 'run_completed') return true;
  if (WATCH_STATUSES.has(event.to)) return true;
  return false;
}
