// Dynamically changing a live run: the control requests and their commands.
//
// A running supervisor owns its manifest, so a coordinator cannot rewrite it.
// Every mutation is a request file under `<run>/requests`, answered by the
// supervisor with a receipt: add, enqueue, continue, steer, retry, cancel,
// set-concurrency, and close.
//
// The launch observation helpers live with them because a command that claims a
// task started must prove the task left the queue instead of reporting an
// optimistic launch.

import { existsSync, mkdirSync, readFileSync, statSync, unlinkSync, watch } from 'node:fs';
import { basename, dirname, isAbsolute, join, resolve } from 'node:path';

import {
  fail,
  loadManifest,
  processIsAlive,
  readJson,
  requireTask,
  runPaths,
  secondsOption,
  sha256,
  singleRun,
  writeJsonAtomic,
} from './supervisor-core.mjs';
import { validateSpec } from './supervisor-spec.mjs';
import { describeQueuedTask, formatQueueOutcome, queueSnapshot } from './supervisor-views.mjs';
import { TERMINAL_STATUSES } from './supervisor-events.mjs';

// Task states `retry` may resume. `retrying` is included because the daemon is
// waiting on its own resume timer there: a manual retry shortens that wait
// instead of starting a second turn. `waiting` stays for rate-limit
// waits and for tasks observed through an older worker artifact.
export const RETRYABLE_TASK_STATUSES = ['blocked', 'waiting', 'retrying'];
// `start`/`enqueue`/`continue` verify that every submitted task actually left
// the queue instead of reporting an optimistic launch.
const DEFAULT_VERIFY_MS = 15_000;
const VERIFY_MIN_INTERVAL_MS = 50;
// A steering message, a retry, or a follow probe is relayed to a live daemon
// session; a hung CLI must not hold the supervisor's control-request path open
// indefinitely.
export const STEER_TIMEOUT_MS = 30_000;
export const RETRY_TIMEOUT_MS = 45_000;
// A provider instance id or model id is passed through verbatim; only an empty
// or non-string value is dropped, so a blank flag never becomes `--provider ""`.
export function normalizeRetryRoute(value) {
  if (value == null) return null;
  const text = String(value).trim();
  return text.length ? text : null;
}

function sendControlRequest(runDir, requestData, timeoutMs = 15_000) {
  const paths = runPaths(runDir);
  const manifest = loadManifest(runDir);
  if (manifest.status === 'stale' || (manifest.status === 'running' && !processIsAlive(manifest.supervisorPid))) {
    fail('supervisor process is not running');
  }
  if (manifest.status === 'completed') {
    fail('run is already completed');
  }
  if (manifest.closed && ['add', 'enqueue'].includes(requestData.type)) {
    fail(`cannot ${requestData.type} tasks to closed run`);
  }
  mkdirSync(paths.requests, { recursive: true });

  const reqId = `req-${Date.now()}-${process.pid}-${Math.random().toString(36).slice(2, 8)}`;
  const reqFile = join(paths.requests, `${reqId}.req.json`);
  const ackFile = join(paths.requests, `${reqId}.ack.json`);

  writeJsonAtomic(reqFile, { id: reqId, ...requestData });

  let watcher = null;

  return new Promise((resolvePromise, reject) => {
    let deadlineTimer = null;
    const cleanup = () => {
      if (deadlineTimer) clearTimeout(deadlineTimer);
      if (watcher) {
        try { watcher.close(); } catch {}
      }
      try { unlinkSync(ackFile); } catch {}
      try { unlinkSync(reqFile); } catch {}
    };

    const check = () => {
      if (!existsSync(ackFile)) return;
      let ack;
      try {
        ack = JSON.parse(readFileSync(ackFile, 'utf8'));
      } catch {
        return;
      }
      cleanup();
      if (ack.ok) {
        resolvePromise(ack);
      } else {
        reject(new Error(ack.error || 'request rejected by supervisor'));
      }
    };

    try {
      watcher = watch(paths.requests, (_eventType, filename) => {
        if (!filename || String(filename) === basename(ackFile)) check();
      });
      watcher.once('error', (error) => {
        cleanup();
        reject(new Error(`request acknowledgement watch failed: ${error.message}`));
      });
    } catch (error) {
      cleanup();
      reject(new Error(`request acknowledgement watch failed: ${error.message}`));
      return;
    }

    deadlineTimer = setTimeout(() => {
      const supervisorAlive = processIsAlive(manifest.supervisorPid);
      cleanup();
      reject(new Error(supervisorAlive
        ? `request timed out after ${timeoutMs}ms`
        : 'supervisor process died before acknowledging request'));
    }, timeoutMs);

    // Register first and rescan second so an acknowledgement written during
    // watcher setup is still consumed without an interval-based polling loop.
    check();
  });
}

export async function addCommand(options) {
  const runDir = singleRun(options, 'add');
  if (!options.spec) fail('add requires --spec');
  const manifest = loadManifest(runDir);
  const existingIds = new Set(Object.keys(manifest.tasks || {}));
  const tasks = validateSpec(readJson(resolve(options.spec), 'task spec'), existingIds);
  try {
    const ack = await sendControlRequest(runDir, {
      type: 'add',
      tasks,
    });
    if (options.json) {
      process.stdout.write(`${JSON.stringify({
        runDir,
        added: true,
        taskIds: ack.taskIds,
        active: ack.active,
        maxConcurrency: ack.maxConcurrency,
        tasks: ack.tasks,
      }, null, 2)}\n`);
    } else {
      process.stdout.write(`Added ${ack.taskIds.length} held task(s) to run: ${ack.taskIds.join(', ')}\n`);
      for (const outcome of ack.tasks || []) {
        process.stdout.write(`  ${formatQueueOutcome(outcome)}\n`);
      }
    }
  } catch (error) {
    fail(error.message, 1);
  }
}

export async function enqueueCommand(options) {
  const runDir = singleRun(options, 'enqueue');
  const verifyMs = verifyOption(options);
  let request;
  if (options.spec) {
    const manifest = loadManifest(runDir);
    const existingIds = new Set(Object.keys(manifest.tasks || {}));
    const tasks = validateSpec(readJson(resolve(options.spec), 'task spec'), existingIds);
    request = { type: 'enqueue', spec: true, tasks };
  } else {
    let taskIds = [];
    if (options.task) {
      taskIds = [options.task];
    } else if (options.tasks) {
      taskIds = options.tasks.split(',').map((s) => s.trim()).filter(Boolean);
    } else {
      fail('enqueue requires --spec, --task <id>, or --tasks <id1,id2>');
    }
    request = { type: 'enqueue', spec: false, taskIds };
  }

  try {
    const ack = await sendControlRequest(runDir, request);
    // The acknowledgement says what the worker decided; verification says what
    // is actually observable afterwards (started, honestly queued, or failed to
    // spawn), so a reported launch is never merely assumed.
    const verification = await observeLaunch(runDir, ack.taskIds || [], { verifyMs });
    if (options.json) {
      process.stdout.write(`${JSON.stringify({
        runDir,
        enqueued: true,
        taskIds: ack.taskIds,
        active: ack.active,
        maxConcurrency: ack.maxConcurrency,
        queued: ack.queued,
        tasks: ack.tasks,
        verification,
      }, null, 2)}\n`);
    } else {
      process.stdout.write(`Enqueued ${ack.taskIds.length} task(s): ${ack.taskIds.join(', ')}\n`);
      for (const line of verification.summary) {
        process.stdout.write(`  ${line}\n`);
      }
      if (verification.timedOut) {
        process.stdout.write(`  (verification timed out after ${verification.timeoutMs}ms)\n`);
      }
    }
    if (verification.spawnFailed.length) process.exit(1);
  } catch (error) {
    fail(error.message, 1);
  }
}

export async function continueCommand(options) {
  const runDir = singleRun(options, 'continue');
  if (!options.task) fail('continue requires --task <id>');
  if (!options['brief-file']) fail('continue requires --brief-file <path>');
  const briefPath = options['brief-file'];
  if (!isAbsolute(briefPath)) fail('--brief-file must be an absolute path');
  if (!existsSync(briefPath) || !statSync(briefPath).isFile()) {
    fail(`--brief-file does not exist: ${briefPath}`);
  }
  const verifyMs = verifyOption(options);
  const manifest = loadManifest(runDir);
  const state = requireTask(manifest, options.task);

  // Pre-flight so an obviously unsafe re-dispatch never reaches the worker; the
  // worker repeats every check authoritatively.
  if (!TERMINAL_STATUSES.has(state.status)) {
    fail(`task ${options.task} is ${state.status}; continue needs a finished task (cancel it first)`);
  }
  if (processIsAlive(state.pid)) {
    fail(`task ${options.task} still has a live worker process (pid ${state.pid}); stop it and verify it is gone before continuing`);
  }

  try {
    const ack = await sendControlRequest(runDir, {
      type: 'continue',
      taskId: options.task,
      briefPath: resolve(briefPath),
      newSession: options['new-session'] === true,
    });
    const verification = await observeLaunch(runDir, [options.task], { verifyMs });
    if (options.json) {
      process.stdout.write(`${JSON.stringify({
        runDir,
        continued: true,
        taskId: ack.taskId,
        attempt: ack.attempt,
        previousAttempt: ack.previousAttempt,
        previousStatus: ack.previousStatus,
        status: ack.status,
        briefPath: ack.briefPath,
        newSession: ack.newSession,
        archived: ack.archived,
        archiveDir: ack.archiveDir,
        active: ack.active,
        maxConcurrency: ack.maxConcurrency,
        verification,
      }, null, 2)}\n`);
    } else {
      process.stdout.write(
        `Continued task ${ack.taskId} as attempt ${ack.attempt} (previous: ${ack.previousStatus}).`
        + ` Brief: ${ack.briefPath}${ack.newSession ? ' (new session)' : ''}\n`,
      );
      if (ack.archived?.length) {
        process.stdout.write(`  archived attempt ${ack.previousAttempt}: ${ack.archiveDir}\n`);
      }
      for (const line of verification.summary) process.stdout.write(`  ${line}\n`);
    }
    if (verification.spawnFailed.length) process.exit(1);
  } catch (error) {
    fail(error.message, 1);
  }
}

export async function steerCommand(options) {
  const runDir = singleRun(options, 'steer');
  if (!options.task) fail('steer requires --task <id>');
  const hasMessage = typeof options.message === 'string';
  const hasMessageFile = typeof options['message-file'] === 'string';
  if (hasMessage === hasMessageFile) {
    fail('steer requires exactly one of --message or --message-file');
  }
  if (hasMessageFile) {
    const messageFile = options['message-file'];
    if (!isAbsolute(messageFile)) fail('--message-file must be an absolute path');
    if (!existsSync(messageFile) || !statSync(messageFile).isFile()) {
      fail(`--message-file does not exist: ${messageFile}`);
    }
    if (!readFileSync(messageFile, 'utf8').trim()) fail('--message-file is empty');
  } else if (!String(options.message).trim()) {
    fail('--message must not be empty');
  }

  const manifest = loadManifest(runDir);
  const state = requireTask(manifest, options.task);
  if (state.status !== 'running') {
    fail(`task ${options.task} is ${state.status}; steer needs a running task (use continue for a finished one)`);
  }
  if (!state.sessionId) {
    fail(`task ${options.task} has no recorded session id yet; wait until the session is observable, then steer`);
  }

  try {
    const ack = await sendControlRequest(runDir, {
      type: 'steer',
      taskId: options.task,
      message: hasMessage ? options.message : null,
      messageFile: hasMessageFile ? resolve(options['message-file']) : null,
    }, STEER_TIMEOUT_MS + 15_000);
    if (options.json) {
      process.stdout.write(`${JSON.stringify({
        runDir,
        steered: true,
        taskId: ack.taskId,
        sessionId: ack.sessionId,
        requestId: ack.requestId,
        cliRequestId: ack.cliRequestId ?? null,
        messageSha256: ack.messageSha256,
        messageLength: ack.messageLength,
        journalSeq: ack.journalSeq,
        exitCode: ack.exitCode,
      }, null, 2)}\n`);
      return;
    }
    process.stdout.write(
      `Steered task ${ack.taskId} (session ${ack.sessionId}): request ${ack.requestId}`
      + ` journaled at seq ${ack.journalSeq}; message sha256 ${String(ack.messageSha256).slice(0, 12)}…`
      + ` (${ack.messageLength} bytes, body not journaled).\n`,
    );
  } catch (error) {
    fail(error.message, 1);
  }
}

export async function retryCommand(options) {
  const runDir = singleRun(options, 'retry');
  if (!options.task) fail('retry requires --task <id>');
  const provider = normalizeRetryRoute(options.provider);
  const model = normalizeRetryRoute(options.model);
  if (options.provider != null && !provider) fail('--provider must not be empty');
  if (options.model != null && !model) fail('--model must not be empty');

  const manifest = loadManifest(runDir);
  const state = requireTask(manifest, options.task);
  // A retry resumes an existing turn; it can never start one. A running task
  // has nothing to resume and a finished task is the `continue` path.
  if (!RETRYABLE_TASK_STATUSES.includes(state.status)) {
    fail(`task ${options.task} is ${state.status}; retry needs a blocked or waiting task (use continue for a finished one)`);
  }
  if (!state.sessionId) {
    fail(`task ${options.task} has no recorded session id yet; wait until the session is observable, then retry`);
  }

  try {
    const ack = await sendControlRequest(runDir, {
      type: 'retry',
      taskId: options.task,
      provider,
      model,
    }, RETRY_TIMEOUT_MS + 15_000);
    if (options.json) {
      process.stdout.write(`${JSON.stringify({
        runDir,
        retried: ack.ok === true,
        taskId: ack.taskId,
        sessionId: ack.sessionId,
        attempt: ack.attempt ?? null,
        result: ack.result ?? null,
        exitCode: ack.exitCode ?? null,
        cliRequestId: ack.cliRequestId ?? null,
        journalSeq: ack.journalSeq ?? null,
        provider,
        model,
      }, null, 2)}\n`);
      return;
    }
    process.stdout.write(
      `Retried task ${ack.taskId} (session ${ack.sessionId}): ${ack.result ?? 'sent'}`
      + ` attempt ${ack.attempt ?? '?'} journaled at seq ${ack.journalSeq ?? '?'}`
      + `${ack.cliRequestId ? ` (cli request ${ack.cliRequestId})` : ''}.\n`,
    );
  } catch (error) {
    fail(error.message, 1);
  }
}

export async function cancelCommand(options) {
  const runDir = singleRun(options, 'cancel');
  if (!options.task) fail('cancel requires --task <id>');
  try {
    const ack = await sendControlRequest(runDir, { type: 'cancel', taskIds: [options.task] });
    if (options.json) {
      process.stdout.write(`${JSON.stringify({
        runDir,
        cancelled: true,
        taskId: ack.taskId,
        from: ack.from,
        status: ack.status,
        signalled: ack.signalled,
        // The group is what was signalled, and the group id is what an operator
        // (or a repair) has to address if the tree outlives the leader.
        pgid: ack.pgid ?? null,
        group: ack.group === true,
        sessionId: ack.sessionId ?? null,
        sessionStop: ack.sessionStop ?? null,
        followed: ack.followed === true,
        alreadyRequested: ack.alreadyRequested === true,
      }, null, 2)}\n`);
      return;
    }
    if (ack.alreadyRequested) {
      process.stdout.write(`Cancellation for task ${ack.taskId} was already requested; waiting for it to settle.\n`);
      return;
    }
    if (ack.status === 'aborted') {
      process.stdout.write(`Cancelled task ${ack.taskId} (${ack.from} -> aborted); it will never start.\n`);
      return;
    }
    const signalText = ack.followed
      ? 'no worker process; the turn is followed through the daemon session'
      : (ack.signalled
        ? `signalled ${ack.signalled}${ack.group === true ? ` to process group ${ack.pgid}` : ''}`
        : 'no live process to signal');
    const sessionText = ack.sessionStop?.requested
      ? `session ${ack.sessionStop.sessionId} stop requested`
      : `daemon session stop not requested (${ack.sessionStop?.reason || 'unknown'})`;
    process.stdout.write(
      `Cancelling task ${ack.taskId} (${ack.from}): ${signalText}; ${sessionText}. `
      + `The terminal state is recorded as cancelled.\n`,
    );
  } catch (error) {
    fail(error.message, 1);
  }
}

export async function setConcurrencyCommand(options) {
  const runDir = singleRun(options, 'set-concurrency');
  if (options.max == null) fail('set-concurrency requires --max <n>');
  const requested = Number(options.max);
  if (!Number.isInteger(requested) || requested < 1) {
    fail('--max must be a positive integer');
  }
  try {
    const ack = await sendControlRequest(runDir, {
      type: 'set-concurrency',
      maxConcurrency: requested,
    });
    if (options.json) {
      process.stdout.write(`${JSON.stringify({
        runDir,
        previous: ack.previous,
        maxConcurrency: ack.maxConcurrency,
        active: ack.active,
        queued: ack.queued,
        started: ack.started,
        tasks: ack.tasks,
      }, null, 2)}\n`);
      return;
    }
    process.stdout.write(
      `Concurrency ${ack.previous} -> ${ack.maxConcurrency} (${ack.active}/${ack.maxConcurrency} active, ${ack.queued} queued)\n`,
    );
    for (const outcome of ack.tasks || []) {
      process.stdout.write(`  ${formatQueueOutcome(outcome)}\n`);
    }
  } catch (error) {
    fail(error.message, 1);
  }
}

export function verifyOption(options) {
  if (options['verify-ms'] != null) {
    const requested = Number(options['verify-ms']);
    if (!Number.isInteger(requested) || requested < 0) fail('--verify-ms must be a non-negative integer');
    return requested;
  }
  return secondsOption(options, 'verify-sec', DEFAULT_VERIFY_MS, '--verify-sec');
}

// One task's launch state as a caller can observe it. A queued task counts as
// resolved only when the queue is the honest reason (every slot is busy); a
// task that is merely "launch pending" is still unresolved, because that is
// exactly the state that produced a reported launch that never ran.
function observeTaskState(runDir, id) {
  const manifestPath = runPaths(runDir).manifest;
  let manifest;
  try {
    manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
  } catch {
    return null;
  }
  const state = manifest?.tasks?.[id];
  if (!state) return { id, status: 'unknown', settled: false, spawnFailed: false, runStatus: manifest?.status ?? null };
  const snapshot = queueSnapshot(manifest);
  const queued = state.status === 'queued';
  const queue = queued ? describeQueuedTask(manifest, id) : null;
  const originalStatus = ['blocked', 'needs_input', 'needs_permission', 'waiting', 'resuming', 'following'].includes(state.status);
  // A `running` observation is only a launch once a pid exists: a spawn that is
  // about to fail passes through `running` with no pid for one tick, and counting
  // that as an observed launch reported a failed spawn as a success.
  const settled = (state.status === 'running' && Number.isInteger(state.pid))
    || TERMINAL_STATUSES.has(state.status)
    || originalStatus
    || (queued && queue?.reason === 'awaiting_slot');
  const observation = {
    id,
    status: state.status,
    pid: state.pid ?? null,
    attempt: state.attempt ?? 1,
    cause: state.cause ?? null,
    error: state.error ?? null,
    sessionId: state.sessionId ?? null,
    spawnFailed: state.status === 'failed' && state.cause === 'spawn_failed',
    settled,
    queue: queue ? {
      position: queue.position,
      queuedTotal: queue.queuedTotal,
      reason: queue.reason,
      reasonText: queue.reasonText,
    } : null,
    active: snapshot.active,
    maxConcurrency: snapshot.maxConcurrency,
    runStatus: manifest?.status ?? null,
  };
  observation.line = formatObservationLine(observation);
  return observation;
}

function formatObservationLine(observation) {
  const counts = `${observation.active ?? '?'}/${observation.maxConcurrency ?? '?'} active`;
  if (observation.status === 'running') {
    return `${observation.id}: running (pid ${observation.pid ?? '?'}, ${counts})`;
  }
  if (observation.status === 'queued') {
    const reason = observation.queue?.reasonText ?? 'queued';
    return `${observation.id}: queued at position ${observation.queue?.position ?? '?'} of ${observation.queue?.queuedTotal ?? '?'} — ${reason}`;
  }
  if (observation.spawnFailed) {
    return `${observation.id}: failed to spawn — ${observation.error ?? 'no diagnostic'}`;
  }
  if (TERMINAL_STATUSES.has(observation.status)) {
    const cause = observation.cause ? ` (${observation.cause})` : '';
    const error = observation.error ? ` — ${observation.error}` : '';
    return `${observation.id}: ${observation.status}${cause}${error}`;
  }
  if (observation.status === 'unknown') {
    return `${observation.id}: not present in the run manifest`;
  }
  if (observation.status === 'following') {
    return `${observation.id}: following the daemon turn — the worker exited, the session is still in flight`;
  }
  return `${observation.id}: ${observation.status}${observation.error ? ` — ${observation.error}` : ''}`;
}

/**
 * Waits until every submitted task is observably resolved, then reports what
 * was seen. Resolution is event-first (a directory watcher on the run) with a
 * bounded rescan, never a scheduled poll loop.
 */
export function observeLaunch(runDir, taskIds, { verifyMs = DEFAULT_VERIFY_MS } = {}) {
  const ids = [...new Set((taskIds || []).filter(Boolean))];
  const startedAt = Date.now();
  if (verifyMs <= 0 || ids.length === 0) {
    const observed = ids.map((id) => observeTaskState(runDir, id)
      ?? { id, status: 'unknown', settled: false, spawnFailed: false });
    return Promise.resolve({
      verified: false,
      waitedMs: 0,
      timeoutMs: verifyMs,
      timedOut: false,
      observed,
      spawnFailed: observed.filter((entry) => entry.spawnFailed).map((entry) => entry.id),
      summary: observed.map((entry) => entry.line ?? formatObservationLine(entry)),
    });
  }

  const manifestPath = runPaths(runDir).manifest;
  const observations = new Map();
  return new Promise((resolvePromise) => {
    let watcher = null;
    let rescan = null;
    let deadline = null;
    let done = false;
    const finish = (timedOut) => {
      if (done) return;
      done = true;
      clearInterval(rescan);
      clearTimeout(deadline);
      try { watcher?.close(); } catch {}
      const observed = ids.map((id) => observations.get(id) ?? {
        id,
        status: 'unknown',
        settled: false,
        spawnFailed: false,
        line: `${id}: not present in the run manifest`,
      });
      resolvePromise({
        verified: true,
        waitedMs: Date.now() - startedAt,
        timeoutMs: verifyMs,
        timedOut,
        observed,
        spawnFailed: observed.filter((entry) => entry.spawnFailed).map((entry) => entry.id),
        summary: observed.map((entry) => entry.line ?? formatObservationLine(entry)),
      });
    };
    const check = () => {
      let allSettled = true;
      let runStale = false;
      for (const id of ids) {
        const observation = observeTaskState(runDir, id);
        if (observation) {
          observations.set(id, observation);
          if (observation.runStatus === 'stale') runStale = true;
        }
        if (!observations.get(id)?.settled) allSettled = false;
      }
      if (allSettled) finish(false);
      else if (runStale) finish(false);
    };
    try {
      watcher = watch(dirname(manifestPath), (_eventType, filename) => {
        if (!filename || String(filename) === basename(manifestPath)) check();
      });
      watcher.once('error', () => {});
    } catch {
      // The bounded rescan below keeps verification working without a watcher.
    }
    rescan = setInterval(check, Math.max(VERIFY_MIN_INTERVAL_MS, Math.min(250, Math.floor(verifyMs / 8) || 50)));
    deadline = setTimeout(() => finish(true), verifyMs);
    // Register first and rescan second so a state that already changed is seen.
    check();
  });
}

function waitForRunCompletion(runDir, timeoutMs = 60_000) {
  const manifestPath = runPaths(runDir).manifest;
  return new Promise((resolvePromise, reject) => {
    let watcher;
    let deadlineTimer;
    const cleanup = () => {
      if (deadlineTimer) clearTimeout(deadlineTimer);
      try { watcher?.close(); } catch {}
    };
    const check = () => {
      let manifest;
      try {
        manifest = loadManifest(runDir);
      } catch {
        return;
      }
      if (manifest.status === 'running' && !processIsAlive(manifest.supervisorPid)) {
        // The worker writes its terminal state before it exits, so a reader can
        // observe "running" from a read that happened just before that write and a
        // dead pid from a check that happened just after the exit. The status is
        // re-read before a death is concluded, because a completion that this
        // window hides must never be reported as a lost supervisor.
        let latest = null;
        try {
          latest = loadManifest(runDir);
        } catch {
          latest = null;
        }
        cleanup();
        if (latest && ['completed', 'stale'].includes(latest.status)) {
          resolvePromise(latest);
          return;
        }
        reject(new Error('supervisor process died before the run completed'));
        return;
      }
      if (!['completed', 'stale'].includes(manifest.status)) return;
      cleanup();
      resolvePromise(manifest);
    };
    try {
      watcher = watch(dirname(manifestPath), (_eventType, filename) => {
        if (!filename || String(filename) === basename(manifestPath)) check();
      });
      watcher.once('error', (error) => {
        cleanup();
        reject(new Error(`run completion watch failed: ${error.message}`));
      });
    } catch (error) {
      reject(new Error(`run completion watch failed: ${error.message}`));
      return;
    }
    deadlineTimer = setTimeout(() => {
      cleanup();
      reject(new Error(`run did not complete within ${timeoutMs}ms`));
    }, timeoutMs);
    // Register first and rescan second to close the read/watch race.
    check();
  });
}

export async function closeCommand(options) {
  const runDir = singleRun(options, 'close');
  const abortQueued = options['abort-queued'] === true;
  try {
    const ack = await sendControlRequest(runDir, { type: 'close', abortQueued });
    if (options.wait) await waitForRunCompletion(runDir);
    const finalManifest = loadManifest(runDir);
    const aborted = ack.aborted || [];
    if (options.json) {
      process.stdout.write(`${JSON.stringify({
        runDir,
        closed: true,
        status: finalManifest.status,
        abortQueued,
        aborted,
      }, null, 2)}\n`);
    } else {
      process.stdout.write(`Closed run ${runDir} (status: ${finalManifest.status})\n`);
      if (aborted.length) {
        process.stdout.write(`  aborted ${aborted.length} task(s): ${aborted.join(', ')}\n`);
      } else if (abortQueued) {
        process.stdout.write('  no queued or held tasks needed aborting\n');
      }
    }
  } catch (error) {
    fail(error.message, 1);
  }
}
