// Reconcile the manifest with what is actually true.
//
// Three kinds of drift are repaired here, and nothing else is: a task that has
// been waiting too long in the queue, a task that has gone silent while running,
// and a task whose worker process is gone and whose handle was lost. Each is
// journaled exactly once per episode instead of staying `running` forever.
// `status` recomputes the same queue and progress conditions on read through the
// shared `supervisor-stalls.mjs` policy, so a coordinator that never watched is
// not blind — this module only owns the journaled copy of that verdict.

import { statSync } from 'node:fs';

import { TERMINAL_STATUSES } from '../supervisor-events.mjs';
import {
  parseIsoMillis,
  processIsAlive,
  readResultDigest,
} from '../supervisor-core.mjs';
import { describeQueuedTask } from '../supervisor-views.mjs';
import {
  advancedSignals,
  evaluateProgress,
  signatureOf,
} from '../supervisor-stalls.mjs';

const LIVE_STATUSES = new Set(['running', 'resuming']);

export function createReconciler(ctx) {
  // A queued task that outlives the stall threshold is only journaled when the
  // verdict says the queue is genuinely stuck: `awaiting_slot` is the queue doing
  // its job and is reported by `status` instead of waking a coordinator.
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

  // Progress is whatever a working task actually writes: its timeline, its
  // stdout/stderr streams, and its result artifact. Reading one blessed event
  // type was the whole defect — a headless `sanad run` publishes only lifecycle
  // records to its timeline and streams its entire case to stdout, so the old
  // clock sat at `startedAt` for the whole turn and every long task was declared
  // silent at exactly its threshold (2026-11-08, run12: ten false notices while
  // `status` reported progress seconds old).
  const progressSamples = new Map();

  const sampleSignals = (task) => {
    const signature = (path) => {
      if (!path) return null;
      try {
        return signatureOf(statSync(path));
      } catch {
        return null;
      }
    };
    return {
      timeline: signature(task.timelinePath),
      stdout: signature(task.stdoutPath),
      stderr: signature(task.stderrPath),
      result: signature(task.resultPath),
    };
  };

  // Called once per monitor tick, before the stall verdicts, so one pass over the
  // running tasks produces at most one manifest write instead of one per signal.
  const sampleProgressSignals = () => {
    let changed = false;
    for (const [id, state] of Object.entries(ctx.manifest.tasks)) {
      if (!state || ctx.settled.has(id) || !LIVE_STATUSES.has(state.status)) continue;
      const task = ctx.taskMap.get(id);
      if (!task) continue;
      const current = sampleSignals(task);
      const previous = progressSamples.get(id);
      progressSamples.set(id, current);
      // The first sample of an episode is the baseline: nothing has been observed
      // long enough to be called new progress yet.
      if (!previous) continue;
      if (advancedSignals(previous, current).length === 0) continue;
      state.lastProgressAt = new Date().toISOString();
      changed = true;
    }
    if (changed) ctx.persist();
  };

  // A running task with no signal for its threshold is silent: journal it once
  // per stall episode, and clear the flag (with a non-actionable
  // `progress_resumed` notice) as soon as progress returns, so a later stall is
  // reported again and ongoing work never re-fires.
  const flagProgressStall = (id) => {
    const task = ctx.taskMap.get(id);
    const state = ctx.manifest.tasks[id];
    if (!task || !state || !LIVE_STATUSES.has(state.status)) return;
    const verdict = evaluateProgress({ state, manifest: ctx.manifest });
    if (!verdict.stalled) {
      if (state.progressStall) {
        // The resume reports the silence it ends, not the zero age of the signal
        // that ended it: the stall's own clock is the start of the window.
        const stall = state.progressStall;
        const stallMs = stall.lastProgressAt ? parseIsoMillis(stall.lastProgressAt) : null;
        const resumedAt = state.lastProgressAt ?? new Date().toISOString();
        const resumedMs = parseIsoMillis(resumedAt);
        state.progressStall = null;
        ctx.notice(task, 'progress_resumed', {
          silentForMs: stallMs == null || resumedMs == null
            ? verdict.silentForMs
            : Math.max(0, resumedMs - stallMs),
          thresholdMs: verdict.thresholdMs,
          lastProgressAt: stall.lastProgressAt ?? null,
          resumedAt,
        });
      }
      return;
    }
    if (state.progressStall) return;
    state.progressStall = {
      at: new Date().toISOString(),
      silentForMs: verdict.silentForMs,
      thresholdMs: verdict.thresholdMs,
      lastProgressAt: verdict.reference,
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

  return { flagQueueStall, flagProgressStall, sampleProgressSignals, reapLostWorkers };
}
