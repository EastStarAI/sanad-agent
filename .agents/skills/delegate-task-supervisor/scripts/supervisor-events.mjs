// Shared journal vocabulary for the supervisor scripts.
//
// Two readers consume the same `events.jsonl` journal: `watch-once.mjs` (one
// event, one run, read-only) and `supervisor.mjs watch` (many runs, durable
// cursor). They must agree on which records are worth waking an orchestrator,
// so the sets live here instead of being copied into both scripts.

// Terminal task states. A task in any of these never runs again unless it is
// explicitly continued as a new attempt.
export const TERMINAL_STATUSES = new Set([
  'completed',
  'failed',
  'timeout',
  'aborted',
  'interrupted',
  'cancelled',
  'incomplete',
  'needs_review',
  'agy_unavailable',
  'opencode_unavailable',
]);

// Non-state notices that still need a human or coordinator decision: a stall
// means nothing is moving, and `worker_lost` means the last runner vanished.
// `progress_resumed` is deliberately absent: recovery needs no intervention.
export const ACTIONABLE_KINDS = new Set([
  'queued_stall',
  'progress_stall',
  // A task whose process outlived its supervisor is still running, but nothing
  // owns it any more: the coordinator must decide to wait for it or to stop it.
  'worker_orphaned',
]);

// States an orchestrator must react to: terminal outcomes plus every stop that
// asks for input or permission. `running`, `resuming`, `queued`, `held`,
// `waiting`, and plain progress are not actionable.
export const ACTIONABLE_STATUSES = new Set([
  ...TERMINAL_STATUSES,
  'blocked',
  'needs_input',
  'needs_permission',
]);

// `watch-once` keeps its wider legacy wake set (it also surfaces `waiting` and
// `resuming`, which are useful for a single blocked waiter but noisy in a
// coordinator stream).
export const WATCH_STATUSES = new Set([
  ...ACTIONABLE_STATUSES,
  'waiting',
  'resuming',
  'queued_stall',
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
