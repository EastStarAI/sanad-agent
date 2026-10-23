// Reconcile the manifest with what is actually true.
//
// Two kinds of drift are repaired here, and nothing else is: a task that has been
// waiting too long in the queue or that has gone silent while running is
// journaled exactly once per episode, and a task whose worker process is gone and
// whose handle was lost is settled instead of staying `running` forever. `status`
// recomputes the same stall conditions on read, so a coordinator that never
// watched is not blind — this module only owns the journaled copy of that verdict.

import { TERMINAL_STATUSES } from '../supervisor-events.mjs';
import {
  parseIsoMillis,
  processIsAlive,
  readResultDigest,
} from '../supervisor-core.mjs';
import { describeQueuedTask, progressThresholdMs } from '../supervisor-views.mjs';

export function createReconciler(ctx) {
  // A queued task that outlives the stall threshold while every slot is busy is
  // journaled exactly once per queue episode; `status` recomputes the same
  // condition on read so a caller that never watched is not left blind.
  const flagQueueStall = (id) => {
    const task = ctx.taskMap.get(id);
    const state = ctx.manifest.tasks[id];
    if (!task || !state || state.status !== 'queued' || state.queueStall) return;
    const description = describeQueuedTask(ctx.manifest, id);
    if (!description || !description.stalled) return;
    const at = new Date().toISOString();
    state.queueStall = {
      at,
      queuedForMs: description.queuedForMs,
      thresholdMs: description.stallThresholdMs,
      active: description.active,
      maxConcurrency: description.maxConcurrency,
      position: description.position,
      queuedTop: description.queuedTotal,
      reason: description.reason,
    };
    ctx.notice(task, 'queued_stall', { ...state.queueStall });
  };

  // A running task that publishes no progress for its threshold is silent:
  // journal it once per stall episode, and clear the flag (with a
  // non-actionable `progress_resumed` notice) as soon as progress returns, so a
  // later stall is reported again.
  const flagProgressStall = (id) => {
    const task = ctx.taskMap.get(id);
    const state = ctx.manifest.tasks[id];
    if (!task || !state) return;
    if (!['running', 'resuming'].includes(state.status)) return;
    const reference = state.lastProgressAt ?? state.startedAt ?? state.stateSince ?? null;
    const referenceMs = reference ? parseIsoMillis(reference) : null;
    if (referenceMs == null) return;
    const thresholdMs = progressThresholdMs(ctx.manifest, state);
    const silentForMs = Math.max(0, Date.now() - referenceMs);
    if (silentForMs < thresholdMs) {
      if (state.progressStall) {
        state.progressStall = null;
        ctx.notice(task, 'progress_resumed', { silentForMs, lastProgressAt: reference });
      }
      return;
    }
    if (state.progressStall) return;
    state.progressStall = {
      at: new Date().toISOString(),
      silentForMs,
      thresholdMs,
      lastProgressAt: reference,
      status: state.status,
    };
    ctx.notice(task, 'progress_stall', { ...state.progressStall });
  };

  // The worker owns every child handle, so a task that is still `running` after
  // its process is gone and its handle was lost can never settle on its own.
  // This net guarantees no task is left running forever.
  const reapLostWorkers = () => {
    for (const [id, state] of Object.entries(ctx.manifest.tasks)) {
      if (ctx.settled.has(id)) continue;
      if (!state || ['queued', 'held'].includes(state.status)) continue;
      // A followed task has no worker on purpose: its daemon turn is observed by
      // the follow poll, not by a process this supervisor owns.
      if (ctx.isFollowing(state)) continue;
      if (ctx.children.has(id)) continue;
      if (!processIsAlive(state.pid)) markWorkerLost(id);
    }
  };

  const markWorkerLost = (id) => {
    const task = ctx.taskMap.get(id);
    const state = ctx.manifest.tasks[id];
    if (!task || !state || ctx.settled.has(id)) return;
    const digest = readResultDigest(state.resultPath);
    // A published terminal artifact is the task's own last word; the process
    // disappearing afterwards is not a lost worker.
    if (digest?.status && TERMINAL_STATUSES.has(digest.status)) {
      ctx.settled.add(id);
      ctx.transition(task, digest.status, {
        finishedAt: new Date().toISOString(),
        stateSince: new Date().toISOString(),
        cause: 'result_recorded_after_exit',
        recovered: true,
        result: digest,
      });
      ctx.checkRunCompletion();
      return;
    }
    ctx.settled.add(id);
    ctx.active = Math.max(0, ctx.active - 1);
    const finishedAt = new Date().toISOString();
    ctx.transition(task, 'failed', {
      finishedAt,
      stateSince: finishedAt,
      cause: 'worker_lost',
      kind: 'worker_lost',
      error: 'task process is no longer running and no terminal result was recorded',
    });
    ctx.checkRunCompletion();
    ctx.launchAvailable();
  };

  return { flagQueueStall, flagProgressStall, reapLostWorkers };
}
