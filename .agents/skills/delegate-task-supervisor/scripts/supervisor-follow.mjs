// Follow policy for a `sanad` worker that exits while its daemon turn is still
// in flight.
//
// A `sanad run` process is only the transport for one daemon turn; the turn
// itself is owned and persisted by the daemon. A worker that exits early — a
// transient block after its provider timed out, a daemon restart that reclaims
// the turn — therefore does not end the work. Reporting `failed` there is what
// left a real session parked in `needs_input` with nobody watching
// (2026-10-23, run7/lt-b14-c).
//
// Everything here is pure: the snapshot interpretation, the deadline, and the
// outcome rule are decided from plain objects so the state machine can be tested
// without a live daemon, and the worker keeps only the I/O.

import { TERMINAL_STATUSES } from './supervisor-events.mjs';
import { retryAfterMs } from './supervisor-retry.mjs';

// A followed turn is polled, not streamed. The interval is long enough to cost
// nothing next to a turn that takes minutes, and short enough that a question
// reaches the operator promptly.
export const DEFAULT_FOLLOW_POLL_MS = 30_000;
// Bounded, always: the default deadline applies only when the task declares no
// `--timeout` of its own, and that timeout is the documented follow window.
export const DEFAULT_FOLLOW_DEADLINE_MS = 3_600_000;
// Consecutive unreadable probes that mean the session is gone (a Home switch, a
// deleted session, an unreachable daemon) instead of a single slow read.
export const DEFAULT_FOLLOW_LOST_POLLS = 3;
// One probe is bounded well below the default poll interval so a hung CLI can
// never stack probes.
export const DEFAULT_FOLLOW_PROBE_TIMEOUT_MS = 20_000;

// Durable session states that still own the turn. `stopping` is deliberately not
// here: a stopping session has already decided the turn's outcome.
export const IN_FLIGHT_SNAPSHOT_STATES = new Set(['running', 'queued', 'waiting', 'blocked', 'resuming']);

// What the last live observation was, in the order the outcome rule reads it.
export const LIVE_KINDS = new Set(['live', 'resuming', 'waiting', 'intervention', 'blocked', 'stopping']);

/**
 * The run's follow policy, with every value explicit so the manifest and the
 * handshake never depend on a hidden default.
 */
export function followPolicy({
  pollMs = DEFAULT_FOLLOW_POLL_MS,
  deadlineMs = DEFAULT_FOLLOW_DEADLINE_MS,
  lostAfterPolls = DEFAULT_FOLLOW_LOST_POLLS,
  probeTimeoutMs = DEFAULT_FOLLOW_PROBE_TIMEOUT_MS,
} = {}) {
  return {
    pollMs: positiveInteger(pollMs, DEFAULT_FOLLOW_POLL_MS),
    deadlineMs: positiveInteger(deadlineMs, DEFAULT_FOLLOW_DEADLINE_MS),
    lostAfterPolls: positiveInteger(lostAfterPolls, DEFAULT_FOLLOW_LOST_POLLS),
    probeTimeoutMs: positiveInteger(probeTimeoutMs, DEFAULT_FOLLOW_PROBE_TIMEOUT_MS),
  };
}

function positiveInteger(value, fallback) {
  const number = Number(value);
  return Number.isInteger(number) && number > 0 ? number : fallback;
}

function argumentValue(args, flag) {
  if (!Array.isArray(args)) return null;
  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === flag) {
      const value = args[index + 1];
      return value == null ? null : value;
    }
    if (typeof token === 'string' && token.startsWith(`${flag}=`)) {
      return token.slice(flag.length + 1);
    }
  }
  return null;
}

/**
 * Poll interval for one task: a task may declare its own `followPollMs`, and the
 * run default applies otherwise. Compressed values exist for tests only.
 */
export function followPollMsFor(task, defaultMs) {
  const own = Number(task?.followPollMs);
  if (Number.isInteger(own) && own > 0) return own;
  const fallback = Number(defaultMs);
  return Number.isInteger(fallback) && fallback > 0 ? fallback : DEFAULT_FOLLOW_POLL_MS;
}

/**
 * Follow deadline for one task.
 *
 * "The task's own timeout" is the `--timeout <seconds>` the worker was launched
 * with: that is the window its caller declared for the whole turn, and a follow
 * phase that outlives it would report progress the caller already gave up on. A
 * task without one inherits the run deadline.
 */
export function followDeadlineMsFor(task, defaultMs) {
  const declared = Number(argumentValue(task?.args, '--timeout'));
  if (Number.isFinite(declared) && declared > 0) return Math.round(declared * 1000);
  const own = Number(task?.followDeadlineMs);
  if (Number.isInteger(own) && own > 0) return own;
  const fallback = Number(defaultMs);
  return Number.isInteger(fallback) && fallback > 0 ? fallback : DEFAULT_FOLLOW_DEADLINE_MS;
}

function firstText(...values) {
  for (const value of values) {
    if (typeof value === 'string' && value.trim()) return value.trim();
  }
  return null;
}

function isAskUserRequest(pending) {
  if (!pending || typeof pending !== 'object') return false;
  if (pending.tool_name === 'system_ask_user') return true;
  return Array.isArray(pending.questions) && pending.questions.length > 0;
}

/**
 * The last JSON projection printed by `sanad session show <id> --json`.
 *
 * Scanning from the end keeps a diagnostic line that the CLI printed before its
 * envelope from discarding an otherwise valid answer.
 */
export function parseSessionShowOutput(stdout) {
  const text = typeof stdout === 'string' ? stdout : '';
  const lines = text.split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
  for (let index = lines.length - 1; index >= 0; index -= 1) {
    const line = lines[index];
    if (!line.startsWith('{')) continue;
    let payload;
    try {
      payload = JSON.parse(line);
    } catch {
      continue;
    }
    if (!payload || typeof payload !== 'object' || Array.isArray(payload)) continue;
    if (payload.error && typeof payload.status !== 'string') {
      return { ok: false, payload: null, error: String(payload.error).slice(0, 400) };
    }
    if (typeof payload.status !== 'string' && !payload.execution_snapshot) continue;
    return { ok: true, payload, error: null };
  }
  return { ok: false, payload: null, error: 'session show did not return a session projection' };
}

/**
 * One durable session projection reduced to the supervisor's vocabulary.
 *
 * Order matters. A published block or a pending request outranks the top-level
 * `status`, because `session show` reports `running` whenever an in-flight
 * projection exists and `idle` once nothing is publishing — neither of which
 * says whether the turn finished or was stopped.
 */
export function interpretSessionSnapshot(payload) {
  const empty = {
    kind: 'ended',
    state: 'idle',
    status: 'idle',
    cause: null,
    requestId: null,
    intervention: null,
    retryAfterMs: null,
    updatedAt: null,
    executionState: null,
  };
  if (!payload || typeof payload !== 'object') return empty;

  const snapshot = payload.execution_snapshot && typeof payload.execution_snapshot === 'object'
    ? payload.execution_snapshot
    : null;
  const pending = payload.pending_permission_request && typeof payload.pending_permission_request === 'object'
    ? payload.pending_permission_request
    : null;
  const notice = payload.runtime_notice && typeof payload.runtime_notice === 'object'
    ? payload.runtime_notice
    : null;
  const reportedStatus = typeof payload.status === 'string' ? payload.status : null;
  const executionState = typeof snapshot?.state === 'string' ? snapshot.state : null;
  // A durable cause is reported by builds that project the runtime notice or the
  // block cause; the worker's own artifact cause is the fallback the worker adds.
  const cause = firstText(
    payload.cause,
    payload.block_cause,
    payload.blocked_cause,
    notice?.cause,
    snapshot?.cause,
  );
  const updatedAt = firstText(payload.updated_at, snapshot?.updated_at);
  const retryAfter = retryAfterMs(notice) ?? retryAfterMs(snapshot) ?? retryAfterMs(payload);

  if (pending) {
    const requestId = firstText(pending.request_id, pending.requestId);
    const kind = reportedStatus === 'needs_permission' || reportedStatus === 'needs_input'
      ? reportedStatus
      : (isAskUserRequest(pending) ? 'needs_input' : 'needs_permission');
    // Only the documented intervention fields are forwarded. A tool input or a
    // provider payload can carry a secret, and the attached path never
    // journals one either.
    const intervention = {
      kind,
      ...(requestId ? { request_id: requestId } : {}),
      ...(typeof pending.tool_name === 'string' ? { tool_name: pending.tool_name } : {}),
      ...(Array.isArray(pending.questions) ? { questions: pending.questions } : {}),
    };
    return {
      kind: 'intervention',
      state: kind,
      status: kind,
      cause,
      requestId,
      intervention,
      retryAfterMs: retryAfter,
      updatedAt,
      executionState,
    };
  }

  switch (executionState) {
    case 'blocked':
      return { ...empty, kind: 'blocked', state: 'blocked', status: 'blocked', cause, retryAfterMs: retryAfter, updatedAt, executionState };
    case 'waiting':
      return { ...empty, kind: 'waiting', state: 'waiting', status: 'waiting', cause, updatedAt, executionState };
    case 'resuming':
      return { ...empty, kind: 'resuming', state: 'resuming', status: 'resuming', cause, updatedAt, executionState };
    case 'stopping':
      return { ...empty, kind: 'stopping', state: 'stopping', status: 'stopping', cause: firstText(cause, 'stopped'), updatedAt, executionState };
    case 'running':
    case 'queued':
      return { ...empty, kind: 'live', state: 'running', status: 'running', cause, updatedAt, executionState };
    case 'idle':
      return { ...empty, updatedAt, executionState };
    default:
      break;
  }
  if (reportedStatus === 'running') {
    return { ...empty, kind: 'live', state: 'running', status: 'running', cause, updatedAt, executionState };
  }
  return { ...empty, updatedAt, executionState };
}

/**
 * The final state a followed task earns when the durable turn ends.
 *
 * A terminal `result.json` produced *during* the follow wins: it is the turn's
 * own written verdict. Otherwise the outcome is read from the durable session
 * the supervisor actually observed, never from the worker's pre-follow artifact
 * (run7's early `failed` was exactly that trap). A turn that ended before the
 * first probe produced no evidence at all, so it is reported as `incomplete`
 * instead of a guess.
 */
export function followOutcome({ lastLive = null, cause = null, artifact = null } = {}) {
  if (artifact?.status && TERMINAL_STATUSES.has(artifact.status)) {
    return {
      status: artifact.status,
      cause: artifact.cause ?? cause ?? null,
      resultSource: 'worker_artifact',
      note: null,
      error: artifact.error ?? null,
    };
  }
  if (lastLive === 'stopping') {
    return {
      status: 'failed',
      cause: cause ?? 'stopped',
      resultSource: 'daemon_session',
      note: 'the durable session reported a stop; the turn did not finish',
      error: 'the daemon session was stopping when the follow observed it',
    };
  }
  if (lastLive === 'blocked') {
    return {
      status: 'failed',
      cause: cause ?? 'blocked',
      resultSource: 'daemon_session',
      note: 'the durable turn ended while blocked; no recovery resumed it',
      error: 'the daemon turn ended in a blocked state',
    };
  }
  if (lastLive && LIVE_KINDS.has(lastLive)) {
    return {
      status: 'completed',
      cause: null,
      resultSource: 'daemon_session',
      note: 'the outcome comes from the daemon session, not from a worker artifact',
      error: null,
    };
  }
  return {
    status: 'incomplete',
    cause: 'turn_outcome_unknown',
    resultSource: 'daemon_session',
    note: 'the turn ended before the first follow probe, so no durable evidence of success or failure was observed',
    error: 'the daemon turn ended without an observable outcome',
  };
}
