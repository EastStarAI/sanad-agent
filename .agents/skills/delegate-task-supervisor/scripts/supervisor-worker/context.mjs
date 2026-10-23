// The worker's shared context: the run record, the live counters, and the journal.
//
// A run has exactly one of each — one manifest, one sequence, one active-slot
// count, one set of task collections — and every owner in this folder reads and
// writes them through this object instead of through a closure of its own. The
// four writers below are the only code that appends to `events.jsonl` or rewrites
// `manifest.json`, so a task transition, a notice, and the run record can never
// disagree about the sequence number, the queue order, or the live counters.
//
// Construction only builds state: no writer runs, no timer is armed, and no peer
// owner is called until the composition root invokes `runWorker`. That is what
// lets the other modules be created in any order and still share one context.

import { appendFileSync, mkdirSync } from 'node:fs';
import { resolve } from 'node:path';

import {
  DEFAULT_AUTO_RETRY_BACKOFF_MS,
  DEFAULT_AUTO_RETRY_GRACE_MS,
  DEFAULT_AUTO_RETRY_MAX_ATTEMPTS,
  DEFAULT_LAUNCH_RETRY_BACKOFF_MS,
  DEFAULT_LAUNCH_RETRY_MAX_ATTEMPTS,
  retryPolicy,
} from '../supervisor-retry.mjs';
import {
  DEFAULT_FOLLOW_DEADLINE_MS,
  DEFAULT_FOLLOW_LOST_POLLS,
  DEFAULT_FOLLOW_POLL_MS,
  DEFAULT_FOLLOW_PROBE_TIMEOUT_MS,
  followPolicy,
} from '../supervisor-follow.mjs';
import {
  DEFAULT_PROGRESS_STALL_MS,
  DEFAULT_QUEUED_STALL_MS,
} from '../supervisor-views.mjs';
import { CANCEL_FORCE_KILL_MS } from '../supervisor-windows.mjs';
import {
  fail,
  integerOption,
  publicTask,
  readJson,
  runPaths,
  withRunPaths,
  writeJsonAtomic,
} from '../supervisor-core.mjs';

export function createWorkerContext(options) {
  const runDir = resolve(options.run || '');
  let maxConcurrency = Number(options['max-concurrency']);
  const queuedStallMs = options['queued-stall-ms'] == null
    ? DEFAULT_QUEUED_STALL_MS
    : Number(options['queued-stall-ms']);
  let progressStallMs = options['progress-stall-ms'] == null
    ? DEFAULT_PROGRESS_STALL_MS
    : Number(options['progress-stall-ms']);
  if (!runDir
    || !Number.isInteger(maxConcurrency) || maxConcurrency < 1
    || !Number.isInteger(progressStallMs) || progressStallMs < 1
    || !Number.isInteger(queuedStallMs) || queuedStallMs < 1) {
    fail('invalid internal worker invocation');
  }
  const closeWhenIdle = options['close-when-idle'] === true;
  // The grace window the run was started with: cancel and the forced kill use it,
  // so a compressed value never has to be re-derived in the worker.
  const cancelForceKillMs = integerOption(options, 'cancel-force-kill-ms', CANCEL_FORCE_KILL_MS, '--cancel-force-kill-ms', 1);
  // The policy the run was started with. Every value is explicit here so the
  // worker never re-derives a default the handshake did not report.
  const autoRetry = retryPolicy({
    enabled: options['auto-retry'] === true,
    graceMs: integerOption(options, 'auto-retry-grace-ms', DEFAULT_AUTO_RETRY_GRACE_MS, '--auto-retry-grace-ms', 1),
    maxAttempts: integerOption(options, 'auto-retry-max-attempts', DEFAULT_AUTO_RETRY_MAX_ATTEMPTS, '--auto-retry-max-attempts', 1),
    backoffMs: integerOption(options, 'auto-retry-backoff-ms', DEFAULT_AUTO_RETRY_BACKOFF_MS, '--auto-retry-backoff-ms', 1),
    launchMaxAttempts: integerOption(options, 'launch-retry-max-attempts', DEFAULT_LAUNCH_RETRY_MAX_ATTEMPTS, '--launch-retry-max-attempts', 0),
    launchBackoffMs: integerOption(options, 'launch-retry-backoff-ms', DEFAULT_LAUNCH_RETRY_BACKOFF_MS, '--launch-retry-backoff-ms', 1),
  });
  // The follow policy the run was started with. A task whose worker exits while
  // its daemon turn is still in flight is followed with exactly these bounds.
  const followPolicyConfig = followPolicy({
    pollMs: integerOption(options, 'follow-poll-ms', DEFAULT_FOLLOW_POLL_MS, '--follow-poll-ms', 1),
    deadlineMs: integerOption(options, 'follow-deadline-ms', DEFAULT_FOLLOW_DEADLINE_MS, '--follow-deadline-ms', 1),
    lostAfterPolls: integerOption(options, 'follow-lost-polls', DEFAULT_FOLLOW_LOST_POLLS, '--follow-lost-polls', 1),
    probeTimeoutMs: integerOption(options, 'follow-probe-timeout-ms', DEFAULT_FOLLOW_PROBE_TIMEOUT_MS, '--follow-probe-timeout-ms', 1),
  });
  const paths = runPaths(runDir);
  mkdirSync(paths.requests, { recursive: true });
  const initialTasks = readJson(paths.tasks, 'normalized tasks').tasks
    .map((task) => withRunPaths(task, runDir));
  const taskMap = new Map(initialTasks.map((task) => [task.id, task]));
  const taskList = [...initialTasks];
  // One object owns every live value a later owner may read or change. A local
  // copy of `seq`, `active`, `queueSeq`, or `maxConcurrency` would be a second
  // source of truth, so there is none: readers go through `ctx` and nothing
  // caches one across a callback or an awaited probe.
  const ctx = {
    runDir,
    maxConcurrency,
    queuedStallMs,
    progressStallMs,
    closeWhenIdle,
    cancelForceKillMs,
    autoRetry,
    followPolicyConfig,
    paths,
    taskMap,
    taskList,
    seq: 0,
    active: 0,
    queueSeq: initialTasks.length,
    settled: new Set(),
    timelineWatchers: new Map(),
    children: new Map(),
    forceKillTimers: new Map(),
    // Session stops and retries in flight: `continue` must not re-dispatch a task
    // while its previous daemon session is still being torn down (one session per
    // task), and the retry policy must never send two retries for one block.
    pendingSessionStops: new Map(),
    retryInFlight: new Set(),
    launchRetryTimers: new Map(),
    // Followed tasks: the interval that polls a daemon-owned turn after the worker
    // that started it is gone, and the guard that keeps one probe in flight.
    followTimers: new Map(),
    followInFlight: new Set(),
  };

  const workerStartedAt = new Date().toISOString();
  const manifest = {
    version: 'delegate-supervisor.v1',
    runDir,
    supervisorPid: process.pid,
    status: 'running',
    closed: false,
    seq: ctx.seq,
    startedAt: workerStartedAt,
    finishedAt: null,
    maxConcurrency: ctx.maxConcurrency,
    active: ctx.active,
    queuedStallMs: ctx.queuedStallMs,
    progressStallMs: ctx.progressStallMs,
    autoRetry: ctx.autoRetry,
    follow: ctx.followPolicyConfig,
    cancelForceKillMs: ctx.cancelForceKillMs,
    closeWhenIdle: ctx.closeWhenIdle,
    queueSeq: ctx.queueSeq,
    tasks: Object.fromEntries(initialTasks.map((task, index) => [task.id, {
      ...publicTask(task, runDir, 'queued'),
      queuedAt: workerStartedAt,
      queuedSeq: index + 1,
    }])),
  };
  ctx.manifest = manifest;

  // The manifest is the only state a read-only `status` sees, so the live
  // counters are written with every state change instead of being derived.
  const persist = () => {
    manifest.active = ctx.active;
    manifest.queueSeq = ctx.queueSeq;
    writeJsonAtomic(paths.manifest, manifest);
  };

  // The normalized task list is the worker's own input, but a real launch change
  // (a continued task with a new brief) must survive a later read of the run.
  const persistTasks = () => {
    writeJsonAtomic(paths.tasks, {
      version: 'delegate-task-spec.v1',
      tasks: taskList.map((task) => {
        const { stdoutPath, stderrPath, ...rest } = task;
        if (task.remote) rest.timelinePath = null;
        return rest;
      }),
    });
  };

  const transition = (task, to, extra = {}) => {
    const state = manifest.tasks[task.id];
    if (!state) return;
    const from = state.status;
    // Entering the queue stamps FIFO order and start time; entering a running
    // state clears any stall flag from the previous queue episode.
    const queueFields = to === 'queued'
      ? { queuedAt: new Date().toISOString(), queuedSeq: ++ctx.queueSeq, queueStall: null }
      : (to === 'running' ? { queueStall: null } : {});
    // Every block is its own retry episode: recovery through a retry must not
    // leave the next block with an exhausted budget, and the receipt time is a
    // fallback clock for a notice that carried no timestamp.
    const retryFields = to === 'blocked'
      ? {
        retryEpisode: (state.retryEpisode ?? 0) + 1,
        blockedAt: new Date().toISOString(),
        nextRetryAt: null,
        retryExhaustedAt: null,
      }
      : {};
    Object.assign(state, queueFields, retryFields, extra, { status: to });
    manifest.seq = ++ctx.seq;
    const event = {
      seq: ctx.seq,
      taskId: task.id,
      implementer: task.implementer,
      workspace: task.workspace,
      from,
      to,
      at: new Date().toISOString(),
      ...extra,
    };
    appendFileSync(paths.journal, `${JSON.stringify(event)}\n`, 'utf8');
    persist();
  };

  // Non-transition notices (`queued_stall`, `cancel_requested`, `session_stop`)
  // never change task state but share the monotonic sequence, so a watcher
  // cursor stays valid across both kinds of journal record.
  const notice = (task, kind, extra = {}) => {
    const state = task ? manifest.tasks[task.id] : null;
    manifest.seq = ++ctx.seq;
    const event = {
      seq: ctx.seq,
      taskId: task?.id ?? null,
      implementer: task?.implementer ?? null,
      workspace: task?.workspace ?? null,
      from: state?.status ?? null,
      to: kind,
      kind,
      at: new Date().toISOString(),
      ...extra,
    };
    appendFileSync(paths.journal, `${JSON.stringify(event)}\n`, 'utf8');
    persist();
    return event;
  };

  // The four writers are the context's only executable surface: every owner
  // journals through them, and none of them keeps a private copy of the run
  // record or the sequence.
  ctx.persist = persist;
  ctx.persistTasks = persistTasks;
  ctx.transition = transition;
  ctx.notice = notice;

  return ctx;
}
