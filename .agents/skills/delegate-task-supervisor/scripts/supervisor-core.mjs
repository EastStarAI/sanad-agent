// Shared primitives for the supervisor scripts.
//
// This is the bottom layer of the supervisor scripts: the entrypoint, the
// control commands, the read-only views, the watch loop, and the validator all
// import from it, and none of them keeps a private copy of a primitive. That is
// what stops a command and a worker from disagreeing about a run path, a
// manifest field, or a queue threshold.
//
// Three groups live here, each mechanical rather than policy:
//
// 1. Fail-fast primitives: `fail`, single-run resolution, and seconds options.
//    Every command reports a bad flag through the same exit path.
// 2. Durable primitives: atomic JSON writes and the hash the workspace registry
//    keys an identity by.
// 3. Run facts: the `result.json` digest, and the queue and progress arithmetic
//    `status`, `watch`, and the worker all report.
//
// Nothing here knows a command name, so every other script may import it.

import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';

import { TERMINAL_STATUSES } from './supervisor-events.mjs';

// A task that waits for a slot while every slot is busy is normal; a task that
// stays invisible in the queue for minutes is the silent stall live rounds
// reported. The worker journals one `queued_stall` notice per task per queue
// episode after this default, and `status` recomputes the same condition on
// read so a caller that never watched still sees it.
export const DEFAULT_QUEUED_STALL_MS = 120_000;
// A running task that publishes no progress for this long is silent, not busy.
// The worker journals one `progress_stall` notice per stall episode and a
// `progress_resumed` notice when progress returns.
export const DEFAULT_PROGRESS_STALL_MS = 900_000;
export function fail(message, code = 2) {
  process.stderr.write(`supervisor: ${message}\n`);
  process.exit(code);
}

export function singleRun(options, command) {
  if (options.runs.length > 1) fail(`${command} accepts a single --run`);
  if (!options.run) fail(`${command} requires --run`);
  return resolve(options.run);
}

// Fractional seconds are only useful for compressed-time tests; a run that
// wants the documented default simply omits the flag.
export function secondsOption(options, key, defaultMs, label) {
  if (options[key] == null) return defaultMs;
  const seconds = Number(options[key]);
  if (!Number.isFinite(seconds) || seconds < 0) fail(`${label} must be a non-negative number`);
  return Math.round(seconds * 1000);
}

export function readJson(path, label = path) {
  try {
    return JSON.parse(readFileSync(path, 'utf8'));
  } catch (error) {
    fail(`cannot read ${label}: ${error.message}`);
  }
}

export function sleepSync(milliseconds) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, milliseconds);
}

export function writeJsonAtomic(path, value) {
  mkdirSync(dirname(path), { recursive: true });
  const temporary = `${path}.${process.pid}.tmp`;
  writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
  const deadline = Date.now() + 2_000;
  while (true) {
    try {
      renameSync(temporary, path);
      return;
    } catch (error) {
      const transientWindowsContention = process.platform === 'win32'
        && ['EPERM', 'EACCES', 'EBUSY'].includes(error.code);
      if (!transientWindowsContention || Date.now() >= deadline) throw error;
      sleepSync(25);
    }
  }
}

export function getArgValue(args, taskId, ...flags) {
  const values = [];
  for (let i = 0; i < args.length; i += 1) {
    for (const flag of flags) {
      if (args[i] === flag) {
        const value = args[i + 1];
        if (!value || value.startsWith('-')) {
          fail(`task ${taskId} ${flag} requires a value`);
        }
        values.push(value);
      } else if (args[i].startsWith(`${flag}=`)) {
        const value = args[i].slice(flag.length + 1);
        if (!value) fail(`task ${taskId} ${flag} requires a value`);
        values.push(value);
      }
    }
  }
  if (values.length > 1) {
    fail(`task ${taskId} contains duplicate ${flags[0]} values`);
  }
  return values[0] ?? null;
}

function firstNonEmptyLine(value) {
  if (typeof value !== 'string') return null;
  for (const line of value.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (trimmed) return trimmed;
  }
  return null;
}

export function readResultDigest(resultPath) {
  if (!resultPath || !existsSync(resultPath)) return null;
  let result;
  try {
    result = JSON.parse(readFileSync(resultPath, 'utf8'));
  } catch {
    return null;
  }
  if (!result || typeof result !== 'object') return null;
  const pick = (...keys) => {
    for (const key of keys) {
      const value = result[key];
      if (typeof value === 'string' && value.trim()) return value.trim();
    }
    return null;
  };
  const summarySource = pick('summary', 'final_summary', 'finalSummary') ?? firstNonEmptyLine(result.text);
  const summary = summarySource
    ? (summarySource.replace(/\s+/g, ' ').trim().slice(0, 200) || null)
    : null;
  return {
    path: resultPath,
    status: typeof result.status === 'string' ? result.status : null,
    branch: pick('branch', 'git_branch'),
    headSha: pick('head_sha', 'headSha', 'sha'),
    prUrl: pick('pr_url', 'prUrl', 'pull_request_url'),
    summary,
    // The attempt window is what tells a result of *this* task from a later
    // attempt that reused the same `--out-dir`.
    startedAt: pick('started_at', 'startedAt'),
    endedAt: pick('ended_at', 'endedAt'),
    exitCode: typeof result.exit_code === 'number'
      ? result.exit_code
      : (typeof result.exitCode === 'number' ? result.exitCode : null),
    // A worker that exits without writing a verdict still leaves its cause, and a
    // followed turn reuses it when the durable session does not report one.
    cause: pick('cause', 'error_cause', 'block_cause'),
    error: pick('error', 'error_message'),
  };
}

export function sha256(value) {
  return createHash('sha256').update(value).digest('hex');
}

/**
 * Whether a `result.json` artifact belongs to this task's attempt.
 *
 * `continue` archives an attempt's artifacts, but two tasks may also be declared
 * with the same `--out-dir` (the live run4 evidence did exactly that). An
 * artifact that started after the task settled was produced by a later attempt,
 * so it is neither adopted as this task's outcome nor printed as its result.
 */
export function resultBelongsToTask(task, digest) {
  if (!digest) return false;
  const startedMs = parseIsoMillis(digest.startedAt);
  const finishedMs = parseIsoMillis(task?.finishedAt);
  if (startedMs == null || finishedMs == null) return true;
  return startedMs <= finishedMs;
}

/**
 * The result a followed task publishes for its own verdict.
 *
 * A followed turn has no worker artifact of its own: its outcome comes from the
 * durable session or from the operator, including the reason it is not a
 * completion. Recording one result object keeps the status line, `status
 * --json`, and the journal agreeing on the same status — a late worker artifact
 * can never be printed next to it as if the two described the same thing.
 */
export function applyVisibleResult(task, artifact) {
  if (!task) return 'none';
  if (task.follow?.resultSource === 'daemon_session' && task.resultSource === 'daemon_session') {
    if (artifact && artifact.status !== task.result?.status) {
      const changed = task.laterResult?.status !== artifact.status;
      task.laterResult = artifact;
      return changed ? 'later' : 'none';
    }
    return 'none';
  }
  if (!artifact) {
    // A resolved follow owns its visible result even when it has none to show.
    return 'none';
  }
  if (!resultBelongsToTask(task, artifact)) {
    task.laterResult = artifact;
    if (task.result) delete task.result;
    return 'later';
  }
  // An operator cancellation is authoritative, so a worker artifact that reports
  // its own `interrupted`/`failed` exit is triage evidence, never the task's
  // result: `cancelled` and `result interrupted` on one line is the same
  // contradiction a followed completion must not show.
  if (task.cancellationRequested === true && artifact.status !== task.status) {
    task.laterResult = artifact;
    return 'later';
  }
  if (TERMINAL_STATUSES.has(task.status) || task.recovered) {
    task.result = artifact;
    return 'adopted';
  }
  return 'none';
}

/**
 * The result a reader should show for one task: the recorded one when the task
 * has one (a follow verdict is one), else the artifact on its path when that
 * artifact belongs to this attempt.
 */
export function taskResultForView(task) {
  const recorded = task && Object.hasOwn(task, 'result') ? task.result : null;
  if (recorded) {
    const digest = recorded;
    return resultBelongsToTask(task, digest) ? digest : null;
  }
  const digest = readResultDigest(task?.resultPath);
  if (!digest) return null;
  return resultBelongsToTask(task, digest) ? digest : null;
}

export function processIsAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

export function formatDuration(ms) {
  if (ms == null || isNaN(ms) || ms < 0) return 'unknown';
  const totalSeconds = Math.floor(ms / 1000);
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = totalSeconds % 60;
  if (hours > 0) return `${hours}h ${minutes}m ${seconds}s`;
  if (minutes > 0) return `${minutes}m ${seconds}s`;
  return `${seconds}s`;
}

export function parseIsoMillis(value) {
  if (!value) return null;
  const parsed = new Date(value).getTime();
  return Number.isNaN(parsed) ? null : parsed;
}

// Queue ages and stall thresholds are often sub-second during a live
// investigation; printing `0s` for a configured 600ms limit hides the setting.
export function formatShortDuration(ms) {
  if (ms == null || isNaN(ms) || ms < 0) return 'unknown';
  return ms < 1000 ? `${Math.round(ms)}ms` : formatDuration(ms);
}

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
 * Progress age for one task: how long since the last observable progress.
 *
 * `status` recomputes this on read (a caller that never watched must still see
 * a silent turn), and the same computation drives the worker's stall notices.
 */
export function describeProgress(manifest, task, now = Date.now()) {
  const thresholdMs = progressThresholdMs(manifest, task);
  const reference = task.lastProgressAt ?? task.startedAt ?? task.stateSince ?? null;
  const referenceMs = reference ? parseIsoMillis(reference) : null;
  const silentForMs = referenceMs == null ? null : Math.max(0, now - referenceMs);
  const live = ['running', 'resuming'].includes(task.status);
  return {
    lastProgressAt: task.lastProgressAt ?? null,
    silentForMs,
    thresholdMs,
    // `blocked`, `waiting`, and intervention states are already actionable
    // transitions; only a live turn can be silent.
    stalled: live && silentForMs != null && silentForMs >= thresholdMs,
    noticed: task.progressStall ?? null,
  };
}

// Queue order is FIFO by the moment a task entered `queued`: the worker stamps
// `queuedSeq` on every transition, so a read-only `status` reproduces exactly
// the positions the worker uses when it fills slots.
export function queueSnapshot(manifest) {
  const active = Number.isInteger(manifest?.active) ? manifest.active : 0;
  const maxConcurrency = Number.isInteger(manifest?.maxConcurrency) ? manifest.maxConcurrency : null;
  const entries = Object.entries(manifest?.tasks || {});
  const queued = entries
    .filter(([, state]) => state?.status === 'queued')
    .map(([id, state], index) => ({
      id,
      state,
      order: Number.isInteger(state.queuedSeq)
        ? state.queuedSeq
        : Number.MAX_SAFE_INTEGER - entries.length + index,
    }))
    .sort((left, right) => left.order - right.order)
    .map((entry, index) => ({ id: entry.id, state: entry.state, position: index + 1 }));
  return { active, maxConcurrency, queued };
}

// Why a task is still waiting: a full slot is the honest answer, and a task
// that outlives the stall threshold while slots are occupied is flagged so a
// silent queue can never be mistaken for progress.
export function describeQueuedTask(manifest, id, now = Date.now()) {
  const snapshot = queueSnapshot(manifest);
  const entry = snapshot.queued.find((item) => item.id === id);
  if (!entry) return null;
  const counts = `${snapshot.active}/${snapshot.maxConcurrency ?? '?'} active`;
  const queuedAt = entry.state.queuedAt ?? null;
  const queuedForMs = queuedAt == null ? null : Math.max(0, now - (parseIsoMillis(queuedAt) ?? now));
  const awaitingSlot = snapshot.maxConcurrency != null && snapshot.active >= snapshot.maxConcurrency;
  return {
    position: entry.position,
    queuedTotal: snapshot.queued.length,
    active: snapshot.active,
    maxConcurrency: snapshot.maxConcurrency,
    queuedAt,
    queuedForMs,
    stallThresholdMs: queuedStallThreshold(manifest),
    stalled: entry.state.queueStall != null
      || (awaitingSlot && queuedForMs != null && queuedForMs >= queuedStallThreshold(manifest)),
    reason: awaitingSlot ? 'awaiting_slot' : 'launch_pending',
    reasonText: awaitingSlot
      ? `waiting for a concurrency slot (${counts})`
      : `slot is free but the task is not launched yet (${counts})`,
  };
}

export function queueOutcomes(manifest, ids) {
  const snapshot = queueSnapshot(manifest);
  return ids.map((id) => {
    const state = manifest?.tasks?.[id];
    if (state?.status === 'queued') {
      return { id, status: 'queued', ...describeQueuedTask(manifest, id) };
    }
    return {
      id,
      // A launched task is reported as `started`, the operator-facing word for
      // "it left the queue and is now occupying a slot".
      status: state?.status === 'running' ? 'started' : (state?.status ?? 'unknown'),
      position: null,
      queuedTotal: snapshot.queued.length,
      active: snapshot.active,
      maxConcurrency: snapshot.maxConcurrency,
    };
  });
}

export function formatQueueOutcome(outcome) {
  const counts = `${outcome.active}/${outcome.maxConcurrency ?? '?'} active`;
  if (outcome.status === 'started') return `${outcome.id}: started (${counts})`;
  if (outcome.status === 'queued') {
    return `${outcome.id}: queued at position ${outcome.position} of ${outcome.queuedTotal}`
      + ` — ${outcome.reasonText}, queued for ${formatShortDuration(outcome.queuedForMs)}`;
  }
  if (outcome.status === 'held') {
    return `${outcome.id}: held — not queued until enqueue --task ${outcome.id} (${counts})`;
  }
  return `${outcome.id}: ${outcome.status} (${counts})`;
}
