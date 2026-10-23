// The worker's loop: the monitor tick, the control-request inbox, and shutdown.
//
// This is the only module that owns a timer or a filesystem watcher, and the only
// one that ends the process on the run's behalf:
//
// 1. The monitor re-arms itself on the smallest threshold actually in play, so a
//    task that overrides the run default is noticed as promptly as its own
//    setting promises, and it drives the reconcile pass and the retry sender.
// 2. `checkRunCompletion` is the single terminal decision: a closed run whose
//    tasks all settled clears every timer and exits 0 after journaling
//    `run_completed`.
// 3. `runWorker` starts everything. Nothing else in this folder runs during
//    construction, so the composition root can build every owner first and call
//    this last.

import { appendFileSync, watch } from 'node:fs';

import { TERMINAL_STATUSES } from '../supervisor-events.mjs';
import { processIsAlive } from '../supervisor-core.mjs';
import { groupHasLiveMembers, signalTaskProcess } from './child-process.mjs';

const STALL_CHECK_MIN_MS = 200;
const STALL_CHECK_MAX_MS = 15_000;
// Control requests are picked up by a watcher and, as a guarantee, by this
// bounded rescan: a missed filesystem event must not strand a cancelled or
// closed run until its deadline.
const REQUEST_RESCAN_MS = 500;

export function createScheduler(ctx) {
  // The monitor tick follows the smallest threshold actually in play, so a task
  // that overrides the run default with a short silence window is noticed as
  // promptly as its own setting promises. The interval is re-evaluated on every
  // tick because a later `enqueue` can add an even shorter override.
  const monitorTickMs = () => {
    const thresholds = [ctx.queuedStallMs, ctx.progressStallMs];
    // A retry due time is a deadline like any stall threshold: the tick has to
    // be fine enough to honour a compressed grace or backoff window. A task may
    // opt in on its own, so the run flag is not the only source of urgency.
    if (ctx.autoRetry.enabled || ctx.taskList.some((task) => task.autoRetry === true)) {
      thresholds.push(ctx.autoRetry.graceMs, ctx.autoRetry.backoffMs);
    }
    for (const state of Object.values(ctx.manifest.tasks)) {
      const own = Number(state?.progressStallMs);
      if (Number.isInteger(own) && own > 0) thresholds.push(own);
    }
    return Math.max(
      STALL_CHECK_MIN_MS,
      Math.min(STALL_CHECK_MAX_MS, Math.floor(Math.min(...thresholds) / 4)),
    );
  };

  let monitorIntervalMs = 0;
  let monitorTimer = null;
  const monitorTick = () => {
    for (const [id, state] of Object.entries(ctx.manifest.tasks)) {
      if (state.status === 'queued' && !state.queueStall) ctx.flagQueueStall(id);
    }
    for (const id of Object.keys(ctx.manifest.tasks)) ctx.flagProgressStall(id);
    for (const id of Object.keys(ctx.manifest.tasks)) ctx.maybeAutoRetry(id);
    ctx.reapLostWorkers();
    armMonitor();
  };
  const armMonitor = () => {
    const next = monitorTickMs();
    if (monitorTimer && next === monitorIntervalMs) return;
    if (monitorTimer) clearInterval(monitorTimer);
    monitorIntervalMs = next;
    monitorTimer = setInterval(monitorTick, next);
  };

  function checkRunCompletion() {
    const totalTasks = Object.keys(ctx.manifest.tasks).length;
    // `--close-when-idle` makes an otherwise open run terminate as soon as every
    // task is terminal and nothing is queued, so a coordinator is never left
    // waiting on a supervisor that has no work left.
    if (!ctx.manifest.closed && ctx.closeWhenIdle && totalTasks > 0 && ctx.settled.size >= totalTasks) {
      const nothingQueued = !Object.values(ctx.manifest.tasks).some((task) => task.status === 'queued');
      if (nothingQueued) ctx.manifest.closed = true;
    }
    if (!ctx.manifest.closed) return;
    if (ctx.settled.size >= totalTasks) {
      ctx.manifest.status = 'completed';
      ctx.manifest.finishedAt = new Date().toISOString();
      const event = {
        seq: ++ctx.seq,
        taskId: null,
        implementer: null,
        workspace: null,
        from: 'running',
        to: 'completed',
        at: ctx.manifest.finishedAt,
        kind: 'run_completed',
      };
      ctx.manifest.seq = ctx.seq;
      appendFileSync(ctx.paths.journal, `${JSON.stringify(event)}\n`, 'utf8');
      ctx.persist();
      clearInterval(keepAliveTimer);
      clearInterval(monitorTimer);
      try { reqWatcher.close(); } catch {}
      process.exit(0);
    }
  }

  // Every timer and watcher the loop owns. `runWorker` assigns them once, before
  // the first tick or request can be processed, and `checkRunCompletion` clears
  // them on the terminal path.
  let reqWatcher = null;
  let reqRescan = null;
  let keepAliveTimer = null;

  // A graceful stop is a group operation too: stopping this worker must not leave
  // the trees it started running with nobody observing them. Every live task
  // group is signalled, given the same grace window a cancel uses, and then
  // force-killed. A worker killed outright (SIGKILL) cannot run this, which is
  // exactly the case the repair path reports as an orphan.
  let shuttingDown = false;
  const shutdown = () => {
    if (shuttingDown) return;
    shuttingDown = true;
    const live = [...ctx.children.keys()]
      .map((id) => ctx.manifest.tasks[id])
      .filter((state) => state && !TERMINAL_STATUSES.has(state.status));
    const signalled = live
      .map((state) => signalTaskProcess(state, ctx.children.get(state.id) ?? null, 'SIGTERM'))
      .filter(Boolean);
    if (!live.length) {
      process.exit(0);
      return;
    }
    ctx.notice(null, 'worker_shutdown', {
      tasks: live.map((state) => state.id),
      signalled: signalled.map((entry) => ({ signal: entry.signal, pgid: entry.pgid, group: entry.group })),
      forceKillMs: ctx.cancelForceKillMs,
    });
    const force = () => {
      for (const state of live) {
        signalTaskProcess(ctx.manifest.tasks[state.id] ?? state, ctx.children.get(state.id) ?? null, 'SIGKILL');
      }
      process.exit(0);
    };
    const deadline = setTimeout(force, ctx.cancelForceKillMs);
    if (typeof deadline.unref === 'function') deadline.unref();
    const poll = setInterval(() => {
      const stillRunning = live.some((state) => groupHasLiveMembers(Number(state.pgid))
        || processIsAlive(ctx.manifest.tasks[state.id]?.pid));
      if (stillRunning) return;
      clearInterval(poll);
      clearTimeout(deadline);
      process.exit(0);
    }, 50);
    if (typeof poll.unref === 'function') poll.unref();
  };
  function runWorker() {
    // The watcher is the fast path; the rescan is the contract. A missed filesystem
    // event (a dropped watch under load, a platform that coalesces them) must never
    // leave a control request unanswered until its deadline, so the directory is
    // re-read on a bounded interval as well.
    reqWatcher = watch(ctx.paths.requests, () => ctx.processPendingRequests());
    reqRescan = setInterval(() => ctx.processPendingRequests(), REQUEST_RESCAN_MS);
    if (typeof reqRescan.unref === 'function') reqRescan.unref();
    keepAliveTimer = setInterval(() => {}, 30_000);
    process.on('SIGTERM', shutdown);
    process.on('SIGINT', shutdown);
    ctx.persist();
    // The monitor starts after every handler it calls is initialized, and its
    // first tick is what evaluates retry deadlines.
    armMonitor();
    ctx.launchAvailable();
    checkRunCompletion();
    ctx.processPendingRequests();
  }

  return { armMonitor, checkRunCompletion, runWorker };
}
