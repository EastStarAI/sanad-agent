// Shared primitives for the supervisor scripts.
//
// This is the bottom layer: the entrypoint and the command modules above it
// import from here, and none of them keeps a private copy of a primitive. That
// is what stops a command and a worker from disagreeing about a run path, a
// manifest field, or a timestamp.
//
// Three groups live here, each mechanical rather than policy:
//
// 1. Fail-fast primitives: `fail`, single-run resolution, and seconds options.
//    Every command reports a bad flag through the same exit path.
// 2. The run record's addressing: `runPaths` and `taskRunPaths` derive every
//    path, and `loadManifest`/`requireTask` are the two ways it is read.
// 3. Durable primitives and run facts: atomic JSON writes, the hash the
//    workspace registry keys an identity by, process liveness, and the
//    `result.json` digest a terminal task is reported from.
//
// Nothing here knows a command name, so every other script may import it.

import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';

import { TERMINAL_STATUSES } from './supervisor-events.mjs';

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

export function runPaths(runDir) {
  return {
    manifest: join(runDir, 'manifest.json'),
    journal: join(runDir, 'events.jsonl'),
    tasks: join(runDir, 'tasks.json'),
    requests: join(runDir, 'requests'),
    supervisorLog: join(runDir, 'supervisor.log'),
  };
}

// Task artifacts live in the run directory. A remote `sanad-client` task
// streams its NDJSON lifecycle events and terminal `--json` envelope over
// stdout, so the relayed stdout log is both the observed timeline and the
// source of the captured result; `--out-dir` would only create remote files.
export function taskRunPaths(task, runDir) {
  const stdoutPath = join(runDir, `${task.id}.stdout.log`);
  const stderrPath = join(runDir, `${task.id}.stderr.log`);
  if (!task.remote) {
    return { stdoutPath, stderrPath, timelinePath: task.timelinePath, resultPath: task.resultPath };
  }
  return {
    stdoutPath,
    stderrPath,
    timelinePath: stdoutPath,
    resultPath: task.resultPath ?? join(runDir, `${task.id}.result.json`),
  };
}

export function withRunPaths(task, runDir) {
  return { ...task, ...taskRunPaths(task, runDir) };
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

export function loadManifest(runDir) {
  const path = runPaths(resolve(runDir)).manifest;
  if (!existsSync(path)) fail(`manifest not found: ${path}`);
  return readJson(path, 'run manifest');
}

export function requireTask(manifest, id) {
  const task = manifest.tasks?.[id];
  if (!task) fail(`task not found: ${id}`);
  return task;
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
