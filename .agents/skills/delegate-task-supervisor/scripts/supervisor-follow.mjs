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
// Consecutive unreadable probes that are never enough on their own: a session
// that is gone is only declared gone once both this count and the grace window
// below have elapsed, so one slow CLI can never end a follow.
export const DEFAULT_FOLLOW_LOST_POLLS = 3;
// How long a confirmed follow tolerates unreadable probes before it ends.
//
// A daemon restart is not a deleted session. The transport refuses connections
// for as long as the daemon takes to come back — migrations, secret vault,
// session rehydration — and three 30s polls are 90 seconds, which is shorter
// than a cold start. On 2026-11-09 (run13) a deliberate restart therefore turned
// four live, `resuming` sessions into terminal `follow_lost` tasks, and one of
// them finished its turn afterwards. The window is deliberately generous and
// named: a *definitive* answer from the CLI (`error_code: session_not_found`)
// still ends the follow at once, so the only thing this costs is patience for an
// unreachable daemon.
export const DEFAULT_FOLLOW_UNREADABLE_GRACE_MS = 300_000;
// One probe is bounded well below the default poll interval so a hung CLI can
// never stack probes.
export const DEFAULT_FOLLOW_PROBE_TIMEOUT_MS = 20_000;
// The CLI's machine-readable answer for a session id the daemon does not know
// (`sanad session show <id> --json`). Every other failure is a transport or an
// unknown fault, which is exactly the difference between "gone" and "not now".
export const SESSION_NOT_FOUND_CODE = 'session_not_found';

// Durable session states that still own the turn. `stopping` is deliberately not
// here: a stopping session has already decided the turn's outcome.
export const IN_FLIGHT_SNAPSHOT_STATES = new Set(['running', 'queued', 'waiting', 'blocked', 'resuming']);

// What the last live observation was, in the order the outcome rule reads it.
export const LIVE_KINDS = new Set(['live', 'resuming', 'retrying', 'waiting', 'intervention', 'blocked', 'stopping']);

// Notice statuses that themselves promise a resume: the daemon waits on a timer
// and then continues the same request.
export const AUTO_RESUME_NOTICE_STATUSES = new Set(['waiting', 'resuming']);

// The durable session state that means "nothing is publishing this turn any
// more". It says the turn stopped, never why, and never that it finished.
export const ENDED_SNAPSHOT_STATE = 'idle';

function messageCount(value) {
  const number = Number(value);
  return Number.isInteger(number) && number >= 0 ? number : null;
}

function integerOrNull(value) {
  const number = Number(value);
  return Number.isInteger(number) ? number : null;
}

/**
 * The daemon's retry classification for one durable session projection.
 *
 * `session show --json` publishes the active runtime notice next to the durable
 * execution snapshot, and the notice carries `retry_attempt`/`retry_budget`
 * whenever the runtime scheduled an automatic attempt. That is the authoritative
 * evidence this function reads, so an observer never has to infer recovery from
 * the word `blocked`:
 *
 * - a `waiting` notice or `waiting` snapshot waits on a resume timer;
 * - a `blocked` notice whose attempt counter is still below its budget belongs
 *   to a retry the runtime is already performing (the shape that made
 *   `sanad run` exit 1 and this supervisor record `failed` on 2026-10-23);
 * - anything else is parked and needs an operator.
 *
 * A `fatal` notice is never a retry: a permanently rejected request is not
 * retried by definition, whatever counters its reason happens to carry.
 *
 * An ended snapshot outranks the notice for the same reason. A projection can
 * still carry the notice of a turn that already finished, and `idle` says the
 * daemon stopped publishing that turn, so a leftover `waiting` notice must not
 * keep the follower in `retrying` forever.
 */
export function autoRetryFacts(notice, executionState = null) {
  const map = notice && typeof notice === 'object' ? notice : null;
  const noticeStatus = typeof map?.status === 'string' ? map.status : null;
  const reason = typeof map?.reason === 'string' && map.reason ? map.reason : null;
  const attempt = integerOrNull(map?.retry_attempt ?? map?.retryAttempt);
  const budget = integerOrNull(map?.retry_budget ?? map?.retryBudget);
  const budgetLeft = attempt != null && budget != null && budget > 0 && attempt < budget;
  const noticeSchedules = noticeStatus === 'waiting';
  const stateSchedules = executionState === 'waiting';
  const retryableNotice = noticeStatus == null || noticeStatus === 'waiting' || noticeStatus === 'blocked';
  // `idle` means the turn ended: a notice it left behind cannot schedule an
  // attempt, so the follower settles instead of reporting `retrying` forever.
  const ended = executionState === ENDED_SNAPSHOT_STATE;
  const pending = noticeStatus === 'fatal' || ended
    ? false
    : (noticeSchedules || stateSchedules || (retryableNotice && budgetLeft));
  return {
    pending,
    noticeStatus,
    // The structured reason (`timeout`, `auth`, …). Reporting only: the retry
    // policy keeps its own transient-cause vocabulary, which the worker artifact
    // already provides, so `cause` is never rewritten from a notice.
    reason,
    attempt,
    budget,
    budgetLeft,
    label: attempt == null || budget == null || budget <= 0
      ? 'retrying'
      : `retrying (${attempt}/${budget})`,
  };
}

/**
 * The durable completion evidence a `sanad session show --json` projection
 * carries.
 *
 * `session show --json` exposes no terminal turn record: `execution_snapshot`
 * holds `state`, `revision`, `updated_at`, and `turn_started_at` only, and no
 * field of the projection states a per-turn verdict. So the evidence used here
 * is the durable message accounting in `summary`, which the CLI derives from the
 * persisted messages themselves:
 *
 * - `summary.final_answers` counts the `final_answer` rows (the assistant's
 *   finished replies) the daemon wrote for the session;
 * - `summary.user_messages` counts the turns a caller sent to it.
 *
 * A turn that finished normally leaves a final answer behind. A turn that was
 * stopped, cancelled, or lost mid-flight leaves its user message plus whatever
 * tool activity it produced, and no final answer — exactly the 2026-10-23 shape
 * (`user`, `thinking`, `system_ask_user`, tool result, 0 replies) that was
 * reported as `completed`.
 *
 * Returns `null` when the projection carries no counts at all, so "unknown" is
 * never mistaken for "unfinished".
 */
export function turnEvidence(payload) {
  if (!payload || typeof payload !== 'object') return null;
  const summary = payload.summary && typeof payload.summary === 'object' ? payload.summary : null;
  if (!summary) return null;
  const finalAnswers = messageCount(summary.final_answers);
  const userMessages = messageCount(summary.user_messages);
  if (finalAnswers == null && userMessages == null) return null;
  const toolResults = messageCount(summary.tool_results);
  return {
    source: 'summary',
    finalAnswers: finalAnswers ?? 0,
    userMessages: userMessages ?? 0,
    ...(toolResults == null ? {} : { toolResults }),
    messageCount: messageCount(payload.message_count) ?? messageCount(summary.message_count),
  };
}

/**
 * Whether the durable counts prove the followed turn finished normally.
 *
 * The rule is the message-based one, because it is the only one the durable
 * state supports:
 *
 * 1. A final answer that appeared *during* the follow window is the turn's own
 *    written reply, whatever else the session holds (a steered turn also adds a
 *    user message, so the plain count comparison alone would misread it).
 * 2. Otherwise the session must hold at least one final answer for every user
 *    turn it received: the last user turn then has its reply, and an
 *    interrupted turn can never satisfy that.
 *
 * Anything else is an unfinished turn, never a completion.
 */
export function finalReplyEvidence(evidence, baseline = null) {
  if (!evidence) {
    return {
      finished: false,
      reason: 'no_completion_evidence',
      finalAnswers: null,
      userMessages: null,
      baselineFinalAnswers: null,
      detail: 'the session projection carried no message accounting',
    };
  }
  const baselineAnswers = messageCount(baseline?.finalAnswers);
  const counts = `${evidence.finalAnswers} final answer(s) for ${evidence.userMessages} user message(s)`;
  if (baselineAnswers != null && evidence.finalAnswers > baselineAnswers) {
    return {
      finished: true,
      reason: 'final_reply_during_follow',
      finalAnswers: evidence.finalAnswers,
      userMessages: evidence.userMessages,
      baselineFinalAnswers: baselineAnswers,
      detail: `a final answer appeared after the worker exited (${counts}, ${baselineAnswers} when the follow started)`,
    };
  }
  if (evidence.finalAnswers >= 1 && evidence.finalAnswers >= evidence.userMessages) {
    return {
      finished: true,
      reason: 'final_reply_for_last_turn',
      finalAnswers: evidence.finalAnswers,
      userMessages: evidence.userMessages,
      baselineFinalAnswers: baselineAnswers,
      detail: `the session holds a final answer for every user turn (${counts})`,
    };
  }
  return {
    finished: false,
    reason: 'no_final_reply',
    finalAnswers: evidence.finalAnswers,
    userMessages: evidence.userMessages,
    baselineFinalAnswers: baselineAnswers,
    detail: counts,
  };
}

/**
 * The run's follow policy, with every value explicit so the manifest and the
 * handshake never depend on a hidden default.
 */
export function followPolicy({
  pollMs = DEFAULT_FOLLOW_POLL_MS,
  deadlineMs = DEFAULT_FOLLOW_DEADLINE_MS,
  lostAfterPolls = DEFAULT_FOLLOW_LOST_POLLS,
  unreadableGraceMs = DEFAULT_FOLLOW_UNREADABLE_GRACE_MS,
  probeTimeoutMs = DEFAULT_FOLLOW_PROBE_TIMEOUT_MS,
} = {}) {
  return {
    pollMs: positiveInteger(pollMs, DEFAULT_FOLLOW_POLL_MS),
    deadlineMs: positiveInteger(deadlineMs, DEFAULT_FOLLOW_DEADLINE_MS),
    lostAfterPolls: positiveInteger(lostAfterPolls, DEFAULT_FOLLOW_LOST_POLLS),
    unreadableGraceMs: positiveInteger(unreadableGraceMs, DEFAULT_FOLLOW_UNREADABLE_GRACE_MS),
    probeTimeoutMs: positiveInteger(probeTimeoutMs, DEFAULT_FOLLOW_PROBE_TIMEOUT_MS),
  };
}

/**
 * What one failed durable-session probe means for a confirmed follow.
 *
 * The rule is the one thing this module never had, and the 2026-11-09 outage is
 * what its absence cost: every failure was the same failure, so a daemon restart
 * that outlived three polls ended four live sessions as `follow_lost`.
 *
 * - `definitive` is the CLI's own `session_not_found` answer: the id is not on
 *   this daemon any more (deleted, or a different Home). Waiting cannot help, so
 *   the poll floor is the only bound.
 * - Anything else (unreachable gateway, probe timeout, unknown fault) may be a
 *   restart. It is tolerated until both `minPolls` failures **and** the grace
 *   window have elapsed, then reported with the elapsed wait so the operator can
 *   tell "the daemon never came back" from "the session is gone".
 *
 * `firstFailureAtMs` is the first failure of the current run, so a flapping
 * daemon earns one window per outage rather than one per poll. `waitedMs` is
 * null when no failure has been observed at all.
 */
export function followReadFailure({
  failures = 0,
  firstFailureAtMs = null,
  nowMs = Date.now(),
  minPolls = DEFAULT_FOLLOW_LOST_POLLS,
  graceMs = DEFAULT_FOLLOW_UNREADABLE_GRACE_MS,
  definitive = false,
} = {}) {
  const count = Number.isInteger(Number(failures)) && Number(failures) > 0 ? Number(failures) : 0;
  const polls = positiveInteger(minPolls, DEFAULT_FOLLOW_LOST_POLLS);
  const grace = positiveInteger(graceMs, DEFAULT_FOLLOW_UNREADABLE_GRACE_MS);
  const startedMs = Number.isFinite(Number(firstFailureAtMs)) ? Number(firstFailureAtMs) : null;
  const waitedMs = startedMs == null ? null : Math.max(0, nowMs - startedMs);
  const graceElapsed = waitedMs != null && waitedMs >= grace;
  const pollFloorMet = count >= polls;
  return {
    failures: count,
    definitive: definitive === true,
    waitedMs,
    graceMs: grace,
    minPolls: polls,
    // Kept for the journal and the tests: the reason a follow may be ended.
    lost: pollFloorMet && (definitive === true || graceElapsed),
    cause: definitive === true
      ? SESSION_NOT_FOUND_CODE
      : 'session_unreadable',
    waitedFor: waitedMs == null ? null : `${count} failed read(s) in ${Math.round(waitedMs / 1000)}s`,
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

/** The first non-empty string of a daemon-supplied field, or null. */
export function firstText(...values) {
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
      return {
        ok: false,
        payload: null,
        error: String(payload.error).slice(0, 400),
        // The CLI's own classification of the failure. `session_not_found` is the
        // only answer that proves the session is gone from this daemon; every
        // other shape is a transport or unknown fault, which is a different fact
        // and must never end a follow on its own.
        errorCode: typeof payload.error_code === 'string' ? payload.error_code : null,
        // The CLI answered; the failure is its own report, not a missing answer.
        reported: true,
      };
    }
    if (typeof payload.status !== 'string' && !payload.execution_snapshot) continue;
    return { ok: true, payload, error: null, errorCode: null, reported: true };
  }
  return {
    ok: false,
    payload: null,
    error: 'session show did not return a session projection',
    errorCode: null,
    reported: false,
  };
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
    retryResumeAt: null,
    retry: null,
    updatedAt: null,
    executionState: null,
    evidence: null,
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
  // The recovery owner's classification: a scheduled (or still budgeted) retry
  // is progress, a park with no scheduled resume is a decision for a human.
  const retry = autoRetryFacts(notice, executionState);
  // The deadline the daemon itself stated. `retry_after_ms` is a countdown the
  // reader must anchor to an observation; `resume_at` is an absolute promise,
  // and it is what lets the worker journal a retry wait without guessing how
  // long ago it read the notice.
  const retryResumeAt = firstText(notice?.resume_at, notice?.resumeAt);
  // Every snapshot carries the durable completion evidence, so the outcome rule
  // reads the same numbers whether the turn ends on the first probe or later.
  const evidence = turnEvidence(payload);

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
      retryResumeAt,
      updatedAt,
      executionState,
      evidence,
      retry,
    };
  }

  // An automatic retry outranks the raw snapshot state: `waiting` waits for the
  // next attempt, and a `blocked` notice that still carries budget left belongs
  // to an attempt the daemon has already scheduled.
  if (retry.pending) {
    return {
      ...empty,
      kind: 'retrying',
      state: 'retrying',
      status: 'retrying',
      cause,
      retryAfterMs: retryAfter,
      retryResumeAt,
      updatedAt,
      executionState,
      evidence,
      retry,
    };
  }

  switch (executionState) {
    case 'blocked':
      return { ...empty, kind: 'blocked', state: 'blocked', status: 'blocked', cause, retryAfterMs: retryAfter, updatedAt, executionState, evidence, retry };
    case 'waiting':
      return { ...empty, kind: 'waiting', state: 'waiting', status: 'waiting', cause, updatedAt, executionState, evidence, retry };
    case 'resuming':
      return { ...empty, kind: 'resuming', state: 'resuming', status: 'resuming', cause, updatedAt, executionState, evidence, retry };
    case 'stopping':
      return { ...empty, kind: 'stopping', state: 'stopping', status: 'stopping', cause: firstText(cause, 'stopped'), updatedAt, executionState, evidence, retry };
    case 'running':
    case 'queued':
      return { ...empty, kind: 'live', state: 'running', status: 'running', cause, updatedAt, executionState, evidence, retry };
    case ENDED_SNAPSHOT_STATE:
      return { ...empty, updatedAt, executionState, evidence, retry };
    default:
      break;
  }
  if (reportedStatus === 'running') {
    return { ...empty, kind: 'live', state: 'running', status: 'running', cause, updatedAt, executionState, evidence, retry };
  }
  return { ...empty, updatedAt, executionState, evidence, retry };
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
 *
 * `idle` is not a verdict. It only says the session stopped publishing, so a
 * turn that ended after being observed live is `completed` only when the durable
 * counts prove it finished (`finalReplyEvidence`). Otherwise it is `failed` with
 * cause `turn_interrupted` — or the daemon's own cause — because the alternative
 * is telling a coordinator that work finished when nothing was ever answered
 * (2026-10-23: a killed transport, `idle` at 04:28:27.96Z, 0 replies, reported
 * `completed`).
 */
export function followOutcome({
  lastLive = null,
  cause = null,
  artifact = null,
  evidence = null,
  baseline = null,
} = {}) {
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
    const verdict = finalReplyEvidence(evidence, baseline);
    if (verdict.finished) {
      return {
        status: 'completed',
        cause: null,
        resultSource: 'daemon_session',
        note: `the outcome comes from the daemon session, not from a worker artifact: ${verdict.detail}`,
        evidence: verdict,
        error: null,
      };
    }
    return {
      status: 'failed',
      cause: cause ?? 'turn_interrupted',
      resultSource: 'daemon_session',
      note: 'the durable session stopped publishing without a final assistant reply, so the turn did not finish',
      evidence: verdict,
      error: `the daemon turn ended without a final assistant reply (${verdict.detail}); it was interrupted or cancelled`,
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
