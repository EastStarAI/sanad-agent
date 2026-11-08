// Stall policy: what counts as progress, and what counts as a stalled queue.
//
// Two false alarms in one live coordinator round (2026-11-08, run12) produced this
// module. `progress_stall` fired for every long task at exactly its threshold,
// because the only progress source consulted was a `tool_use` timeline record
// that a headless Sanad turn never publishes: `lastProgressAt` was still
// `startedAt` after seventy minutes of streamed work, while `status --brief` at
// the same moment reported progress seconds old. `queued_stall` fired for tasks
// that were only waiting for a busy concurrency slot, which is the queue working
// exactly as designed.
//
// Both verdicts are therefore pure functions of observed state and a
// caller-supplied clock. `status` and the worker import the same rule, so a
// read-only surface can never disagree with the journal, and both can be
// verified with fixed timestamps instead of a live run.

import { parseIsoMillis, processIsAlive } from './supervisor-core.mjs';
import { TERMINAL_STATUSES } from './supervisor-events.mjs';

// A task that waits for a busy slot is expected, so the queue threshold only
// measures a genuinely stuck queue: a free slot nobody launched into, or slots
// held by processes that are already gone.
export const DEFAULT_QUEUED_STALL_MS = 120_000;
// A running task that publishes no progress for this long is silent, not busy.
export const DEFAULT_PROGRESS_STALL_MS = 900_000;

// Every artifact a working task writes. Growth in any of them is proof of life
// even when the task publishes no structured record at all, which is the normal
// shape of a local `sanad run --events` turn: its timeline carries the run's
// lifecycle and its whole case is streamed to stdout.
export const PROGRESS_SIGNAL_KEYS = ['timeline', 'stdout', 'stderr', 'result'];

// A task occupies a concurrency slot from launch until it settles. Queued and
// held tasks do not, and neither does anything already terminal.
const NON_HOLDING_STATUSES = new Set(['queued', 'held']);

export function queuedStallThreshold(manifest) {
  const configured = Number(manifest?.queuedStallMs);
  return Number.isFinite(configured) && configured > 0 ? configured : DEFAULT_QUEUED_STALL_MS;
}

export function progressThresholdMs(manifest, taskState = null) {
  const perTask = Number(taskState?.progressStallMs);
  if (Number.isFinite(perTask) && perTask > 0) return perTask;
  const configured = Number(manifest?.progressStallMs);
  return Number.isFinite(configured) && configured > 0 ? configured : DEFAULT_PROGRESS_STALL_MS;
}

/**
 * Comparable signature of one artifact stat result.
 *
 * The worker stats a task's files; this keeps the shape decision out of it, and
 * a missing or unreadable file is `null` rather than a manufactured size.
 */
export function signatureOf(stat) {
  if (!stat) return null;
  const size = Number(stat.size);
  const mtimeMs = Number(stat.mtimeMs ?? stat.mtime);
  if (!Number.isFinite(size) || !Number.isFinite(mtimeMs)) return null;
  return { size, mtimeMs };
}

/**
 * Which artifacts advanced between two samples of one task.
 *
 * A file that appears is progress (a timeline is created by the first record);
 * one that only vanishes is not, and an absent-to-absent pair never counts.
 */
export function advancedSignals(previous, current) {
  if (!previous || !current) return [];
  const advanced = [];
  for (const key of PROGRESS_SIGNAL_KEYS) {
    const after = current[key] ?? null;
    if (!after) continue;
    const before = previous[key] ?? null;
    if (!before) {
      advanced.push(key);
      continue;
    }
    if (before.size !== after.size || before.mtimeMs !== after.mtimeMs) advanced.push(key);
  }
  return advanced;
}

/** The clock a stall is measured from: the latest signal the task produced. */
export function progressReference(state) {
  return state?.lastProgressAt ?? state?.startedAt ?? state?.stateSince ?? null;
}

const LIVE_STATUSES = new Set(['running', 'resuming']);

/**
 * Progress verdict for one task.
 *
 * `reference` is the clock the silence was measured from, so a notice can name
 * the signal it waited on even when the task never published one of its own.
 */
export function evaluateProgress({ state, manifest, now = Date.now() }) {
  const reference = progressReference(state);
  const referenceMs = reference ? parseIsoMillis(reference) : null;
  const thresholdMs = progressThresholdMs(manifest, state);
  const silentForMs = referenceMs == null ? null : Math.max(0, now - referenceMs);
  const live = LIVE_STATUSES.has(state?.status);
  return {
    reference,
    lastProgressAt: state?.lastProgressAt ?? null,
    silentForMs,
    thresholdMs,
    // Silence only means something while the task is supposed to be working:
    // `blocked`, `waiting`, and intervention states are their own signal.
    stalled: Boolean(live && silentForMs != null && silentForMs >= thresholdMs),
  };
}

function slotHolders(manifest) {
  return Object.values(manifest?.tasks || {}).filter((state) => state
    && !TERMINAL_STATUSES.has(state.status)
    && !NON_HOLDING_STATUSES.has(state.status));
}

// A slot is only provably stuck when the task holding it has no process left and
// no followed daemon turn to free it. Anything unproven counts as alive, because
// the alternative is inventing the false alarm this policy exists to prevent.
function holderIsGone(state, isAlive) {
  if (!state || state.follow) return false;
  const pid = Number(state.pid);
  if (!Number.isInteger(pid) || pid <= 0) return false;
  return !isAlive(pid);
}

/**
 * Queue verdict for one waiting task.
 *
 * `awaiting_slot` is never a stall: the queue is doing its job and the task's
 * position is the honest report. A stall is one of two real defects — a free slot
 * the task was not launched into (`launch_pending`), or every slot held by a
 * process that is already gone (`slots_frozen`), which no scheduler will reclaim.
 */
export function queueStallVerdict({ manifest, state, snapshot, now = Date.now(), isAlive = processIsAlive }) {
  const active = Number.isInteger(snapshot?.active) ? snapshot.active : 0;
  const maxConcurrency = Number.isInteger(snapshot?.maxConcurrency) ? snapshot.maxConcurrency : null;
  const counts = `${active}/${maxConcurrency ?? '?'} active`;
  const queuedAt = state?.queuedAt ?? null;
  const queuedForMs = queuedAt == null ? null : Math.max(0, now - (parseIsoMillis(queuedAt) ?? now));
  const thresholdMs = queuedStallThreshold(manifest);
  const slotFull = maxConcurrency != null && active >= maxConcurrency;
  const holders = slotHolders(manifest);
  const frozen = slotFull && holders.length > 0 && holders.every((holder) => holderIsGone(holder, isAlive));
  const reason = frozen ? 'slots_frozen' : (slotFull ? 'awaiting_slot' : 'launch_pending');
  const overdue = queuedForMs != null && queuedForMs >= thresholdMs;
  const reasonText = reason === 'slots_frozen'
    ? `every concurrency slot is held by a task whose process is gone (${counts})`
    : (reason === 'awaiting_slot'
      ? `waiting for a concurrency slot (${counts})`
      : `slot is free but the task is not launched yet (${counts})`);
  return {
    reason,
    reasonText,
    active,
    maxConcurrency,
    queuedForMs,
    thresholdMs,
    holdsSlot: slotFull,
    frozen,
    // A just-queued task is not late yet, and waiting for a busy slot never is.
    stalled: overdue && reason !== 'awaiting_slot',
  };
}
