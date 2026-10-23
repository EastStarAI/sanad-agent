// Follow a daemon-owned turn after the worker that started it is gone.
//
// `sanad run` is only the transport for one daemon turn: the daemon owns the turn,
// persists it, and can finish it — or ask a question — after the transport is
// gone. `beginFollow` records the worker's exit and probes the durable session
// once immediately; a readable live turn promotes the task to `following`, and
// every later poll mirrors the durable state into exactly the journal transitions
// an attached worker would have produced, so the retry policy, the stall notices,
// and every watcher keep working unchanged. A turn that is not observable at all
// leaves the worker's own verdict in place instead of inventing one.

import { existsSync, mkdirSync, renameSync } from 'node:fs';
import { basename, join } from 'node:path';

import { parseIsoMillis, readResultDigest } from '../supervisor-core.mjs';
import {
  followDeadlineMsFor,
  followOutcome,
  followPollMsFor,
  interpretSessionSnapshot,
  parseSessionShowOutput,
} from '../supervisor-follow.mjs';
import { formatShortDuration } from '../supervisor-views.mjs';

/**
 * The coordinator's triage view of one task's `result.json`.
 *
 * `sanad run` writes the versioned artifact (status, exit_code, text, ...);
 * wrapper tasks may additionally publish `branch`, `head_sha`, and `pr_url`.
 * Reading them here means a completion line already carries everything needed
 * to decide the next step, without a second call.
 */
function followResultDigest(outcome, state, finishedAt) {
  if (!outcome?.status) return null;
  return {
    status: outcome.status,
    source: outcome.resultSource ?? 'daemon_session',
    sessionId: state?.sessionId ?? null,
    cause: outcome.cause ?? null,
    error: outcome.error ?? null,
    text: outcome.note ?? null,
    endedAt: finishedAt,
  };
}
export function createFollower(ctx) {

  // -------------------------------------------------------------------------
  // Following a daemon-owned turn after its worker exited
  // -------------------------------------------------------------------------
  // `sanad run` is only the transport for one daemon turn; the turn itself is
  // owned and persisted by the daemon. A worker that exits early — a transient
  // provider timeout, a daemon restart that reclaims the turn — therefore does
  // not end the work. Reporting it `failed` is exactly what left a real session
  // parked in `needs_input` with nobody watching (2026-10-23, run7).
  //
  // `following` keeps the task non-terminal and the poll below mirrors the
  // durable state into the very transitions an attached worker produces, so the
  // retry policy, the stall notices, and every watcher keep working unchanged.
  const isFollowing = (state) => state?.follow?.active === true;

  const stopFollowTimer = (id) => {
    const timer = ctx.followTimers.get(id);
    if (!timer) return;
    clearInterval(timer);
    ctx.followTimers.delete(id);
  };

  // The worker's own `result.json` can hold an early verdict the daemon later
  // contradicted. It is archived, never deleted, so a followed turn can never be
  // reported through it and the evidence stays available for triage.
  const archivePreFollowResult = (state) => {
    if (!state.resultPath || !existsSync(state.resultPath)) return [];
    const dir = join(ctx.runDir, 'follow', state.id, `attempt-${state.attempt ?? 1}`);
    mkdirSync(dir, { recursive: true });
    const target = join(dir, basename(state.resultPath));
    try {
      renameSync(state.resultPath, target);
      return [target];
    } catch {
      return [];
    }
  };

  // An artifact is the followed turn's own verdict only when it was produced
  // inside the follow window.
  const resultWrittenDuringFollow = (state) => {
    const digest = readResultDigest(state.resultPath);
    if (!digest) return null;
    const startedMs = parseIsoMillis(digest.startedAt);
    const followMs = parseIsoMillis(state.follow?.since);
    if (startedMs == null || followMs == null || startedMs < followMs) return null;
    return digest;
  };

  const settleFollow = (task, outcome) => {
    const state = ctx.manifest.tasks[task.id];
    if (!state || ctx.settled.has(task.id)) return;
    stopFollowTimer(task.id);
    ctx.followInFlight.delete(task.id);
    ctx.settled.add(task.id);
    const finishedAt = new Date().toISOString();
    // The verdict and the result shown for it are one fact. A followed turn's
    // outcome comes from the durable session, so a worker artifact on the same
    // path is triage evidence only: it is never printed as the task's result
    // (2026-10-23: a killed worker wrote `interrupted` after the follow settled
    // `completed`, and the status line showed both).
    const digest = outcome.resultDigest
      ?? (outcome.resultSource === 'worker_artifact' ? readResultDigest(state.resultPath) : null)
      ?? (outcome.resultSource === 'worker_artifact' ? null : followResultDigest(outcome, state, finishedAt));
    const follow = {
      ...(state.follow ?? {}),
      active: false,
      endedAt: finishedAt,
      reason: outcome.followReason ?? state.follow?.reason ?? null,
      resultSource: outcome.resultSource ?? 'daemon_session',
      outcome: outcome.status,
      ...(outcome.evidence ? { evidence: outcome.evidence } : {}),
    };
    ctx.transition(task, outcome.status, {
      finishedAt,
      stateSince: finishedAt,
      cause: outcome.cause ?? null,
      follow,
      resultSource: follow.resultSource,
      note: outcome.note ?? null,
      pid: null,
      // Always written, so a stale artifact-based result can never survive a
      // daemon-session verdict: the follow owns the visible result from here.
      result: digest ?? null,
      requestId: null,
      intervention: null,
      error: outcome.error ?? null,
    });
    const attemptNumber = state.attempt ?? 1;
    state.attempts = [
      ...(state.attempts ?? []).filter((entry) => entry.attempt !== attemptNumber),
      {
        attempt: attemptNumber,
        startedAt: state.startedAt ?? null,
        finishedAt,
        status: outcome.status,
        exitCode: state.exitCode ?? null,
        signal: state.signal ?? null,
        cause: outcome.cause ?? null,
        sessionId: state.sessionId ?? null,
        result: digest,
        resultSource: follow.resultSource,
        followed: true,
      },
    ];
    ctx.persist();
    ctx.checkRunCompletion();
    ctx.launchAvailable();
  };

  // One readable snapshot, applied exactly like the attached timeline handler:
  // the durable state becomes the task state, and only real transitions are
  // journaled. Polling the same block every interval writes nothing.
  const applyFollowSnapshot = (task, snapshot) => {
    const state = ctx.manifest.tasks[task.id];
    if (!state || !isFollowing(state)) return;
    const follow = state.follow;
    const nowIso = new Date().toISOString();
    const observedAt = snapshot.updatedAt ?? nowIso;

    if (snapshot.kind === 'ended') {
      settleFollow(task, followOutcome({
        lastLive: follow.lastLive ?? null,
        cause: follow.lastCause ?? state.cause ?? null,
        artifact: resultWrittenDuringFollow(state),
        // `idle` only says the session stopped publishing: the durable counts
        // decide whether the turn actually finished.
        evidence: snapshot.evidence ?? null,
        baseline: follow.turnBaseline ?? null,
      }));
      return;
    }
    if (snapshot.kind === 'stopping') {
      settleFollow(task, followOutcome({
        lastLive: 'stopping',
        cause: snapshot.cause ?? follow.lastCause ?? state.cause ?? null,
      }));
      return;
    }

    follow.lastLive = snapshot.kind;
    if (snapshot.kind === 'retrying') {
      // The daemon scheduled another automatic attempt. The task stays live and
      // says so, with the attempt counters, instead of parking as `blocked` and
      // waiting for a retry an operator was never needed for.
      const cause = snapshot.cause ?? state.cause ?? 'unknown';
      follow.lastCause = cause;
      const daemonRetry = {
        ...(typeof snapshot.retry?.attempt === 'number' ? { attempt: snapshot.retry.attempt } : {}),
        ...(typeof snapshot.retry?.budget === 'number' ? { budget: snapshot.retry.budget } : {}),
      };
      const label = snapshot.retry?.label ?? 'retrying';
      if (state.status !== 'retrying' || (state.cause ?? null) !== cause
        || JSON.stringify(state.daemonRetry ?? null) !== JSON.stringify(daemonRetry)) {
        ctx.transition(task, 'retrying', {
          sessionId: state.sessionId ?? null,
          cause,
          daemonRetry,
          retryLabel: label,
          stateSince: observedAt,
          ...(snapshot.retryAfterMs ? { retryAfterMs: snapshot.retryAfterMs } : {}),
        });
        return;
      }
      state.lastProgressAt = nowIso;
      ctx.persist();
      return;
    }
    if (snapshot.kind === 'blocked' || snapshot.kind === 'waiting') {
      const cause = snapshot.cause ?? state.cause ?? 'unknown';
      follow.lastCause = cause;
      if (state.status === snapshot.status && (state.cause ?? null) === cause) {
        // The same block, still in flight: no transition to report.
        state.lastProgressAt = nowIso;
        ctx.persist();
        return;
      }
      ctx.transition(task, snapshot.status, {
        sessionId: state.sessionId ?? null,
        cause,
        stateSince: observedAt,
        ...(snapshot.retryAfterMs ? { retryAfterMs: snapshot.retryAfterMs } : {}),
      });
      return;
    }
    if (snapshot.kind === 'resuming') {
      if (state.status !== 'resuming') {
        ctx.transition(task, 'resuming', {
          sessionId: state.sessionId ?? null,
          requestId: null,
          intervention: null,
          cause: null,
          stateSince: observedAt,
        });
      }
      state.lastProgressAt = nowIso;
      ctx.persist();
      return;
    }
    if (snapshot.kind === 'intervention') {
      const changed = state.status !== snapshot.status
        || (state.requestId ?? null) !== (snapshot.requestId ?? null);
      if (changed) {
        // The same whitelisted intervention payload the attached path forwards:
        // kind, request id, tool name, and questions. A tool input, an answer, or
        // a credential is never journaled.
        ctx.transition(task, snapshot.status, {
          sessionId: state.sessionId ?? null,
          requestId: snapshot.requestId,
          intervention: snapshot.intervention,
          kind: snapshot.status,
          stateSince: observedAt,
        });
      } else {
        state.lastProgressAt = nowIso;
        ctx.persist();
      }
      return;
    }

    // A live turn. The durable projection is the only progress evidence a
    // followed task can offer, so a readable live poll refreshes it. The task
    // stays `following` — the honest state for a turn with no worker — instead
    // of claiming a process that does not exist.
    if (state.status !== 'following') {
      ctx.transition(task, 'following', {
        kind: 'following',
        reason: 'turn_resumed_without_worker',
        sessionId: state.sessionId ?? null,
        requestId: null,
        intervention: null,
        cause: null,
        stateSince: observedAt,
      });
    }
    state.lastProgressAt = nowIso;
    ctx.persist();
  };

  const settleFollowLost = (task, reason, detail) => {
    settleFollow(task, {
      status: 'follow_lost',
      cause: reason,
      resultSource: 'daemon_session',
      note: 'the durable session could not be read any more; the turn may still be running on the daemon',
      error: detail,
    });
    const state = ctx.manifest.tasks[task.id];
    if (state) state.follow = { ...state.follow, active: false, lostReason: reason };
  };

  const pollFollow = async (task) => {
    const initial = ctx.manifest.tasks[task.id];
    if (!task || !initial || ctx.settled.has(task.id) || !isFollowing(initial)) return;
    if (ctx.followInFlight.has(task.id)) return;
    const deadlineMs = parseIsoMillis(initial.follow.deadlineAt);
    if (deadlineMs != null && Date.now() >= deadlineMs) {
      settleFollow(task, {
        status: 'timeout',
        cause: 'follow_deadline',
        resultSource: 'daemon_session',
        note: `the follow window of ${formatShortDuration(initial.follow.deadlineMs)} after the worker exited expired`,
        error: 'the daemon turn was still in flight when the follow window expired',
      });
      return;
    }
    const invocation = ctx.sessionShowInvocation(task, initial.sessionId);
    if (!invocation.command) {
      settleWorkerVerdict(task, 'follow_unsupported');
      return;
    }
    const probeTimeoutMs = initial.follow.probeTimeoutMs ?? ctx.followPolicyConfig.probeTimeoutMs;
    const lostAfterPolls = initial.follow.lostAfterPolls ?? ctx.followPolicyConfig.lostAfterPolls;
    ctx.followInFlight.add(task.id);
    try {
      const probe = await ctx.runAuxiliaryCommand(invocation, task, probeTimeoutMs);
      const current = ctx.manifest.tasks[task.id];
      if (!current || !isFollowing(current)) return;
      const parsed = probe.ok
        ? parseSessionShowOutput(probe.stdout)
        : {
          ok: false,
          error: probe.error ?? `session show exited ${probe.exitCode ?? 'unknown'}`,
        };
      current.follow.lastPollAt = new Date().toISOString();
      if (!parsed.ok) {
        current.follow.unreadablePolls = (current.follow.unreadablePolls ?? 0) + 1;
        current.follow.lastError = String(parsed.error ?? 'session show failed').slice(0, 400);
        if (current.follow.unreadablePolls >= lostAfterPolls) {
          // Before the turn was confirmed in flight the worker's own verdict is
          // the honest answer; afterwards the follow itself is what was lost.
          if (current.follow.confirmed === true) {
            settleFollowLost(
              task,
              'session_unreadable',
              `${current.follow.unreadablePolls} consecutive session reads failed: ${current.follow.lastError}`,
            );
          } else {
            settleWorkerVerdict(task, 'session_unreadable');
          }
          return;
        }
        ctx.persist();
        return;
      }
      current.follow.unreadablePolls = 0;
      current.follow.lastError = null;
      current.follow.polls = (current.follow.polls ?? 0) + 1;
      const snapshot = interpretSessionSnapshot(parsed.payload);
      current.follow.lastSnapshot = {
        kind: snapshot.kind,
        state: snapshot.state,
        requestId: snapshot.requestId,
        cause: snapshot.cause,
        updatedAt: snapshot.updatedAt,
      };
      if (current.follow.confirmed !== true) {
        // The first readable answer decides whether there is anything to follow
        // at all: a session that already reports no in-flight turn leaves the
        // worker verdict untouched.
        if (snapshot.kind === 'ended') {
          settleWorkerVerdict(task, 'turn_not_in_flight');
          return;
        }
        confirmFollow(task, snapshot);
        return;
      }
      applyFollowSnapshot(task, snapshot);
    } catch (error) {
      const current = ctx.manifest.tasks[task.id];
      if (!current || !isFollowing(current)) return;
      current.follow.unreadablePolls = (current.follow.unreadablePolls ?? 0) + 1;
      current.follow.lastError = String(error?.message ?? error).slice(0, 400);
      current.follow.lastPollAt = new Date().toISOString();
      if (current.follow.unreadablePolls >= lostAfterPolls) {
        if (current.follow.confirmed === true) {
          settleFollowLost(
            task,
            'session_unreadable',
            `${current.follow.unreadablePolls} consecutive session reads failed: ${current.follow.lastError}`,
          );
        } else {
          settleWorkerVerdict(task, 'session_unreadable');
        }
        return;
      }
      ctx.persist();
    } finally {
      ctx.followInFlight.delete(task.id);
    }
  };

  // The first readable snapshot that still shows a live turn is what promotes
  // the task to `following`: a worker that exits after a turn genuinely ended is
  // still reported with its own verdict, and only a turn nothing has finished is
  // followed.
  const confirmFollow = (task, snapshot) => {
    const state = ctx.manifest.tasks[task.id];
    if (!state || !isFollowing(state)) return;
    state.follow.confirmed = true;
    state.follow.confirmedAt = new Date().toISOString();
    // The durable counts at the moment the follow starts are the baseline a final
    // reply has to beat: a reply that appears afterwards is this turn's own.
    state.follow.turnBaseline = snapshot.evidence ?? null;
    // A group that outlived the direct child is not a departed transport, and the
    // reason says so instead of claiming the worker left a turn in flight.
    const groupAlive = state.follow.workerExit?.groupAlive === true;
    state.follow.reason = groupAlive ? 'worker_exited_group_alive' : 'worker_exited_turn_in_flight';
    ctx.transition(task, 'following', {
      pid: null,
      kind: 'following',
      reason: state.follow.reason,
      cause: state.workerCause ?? state.follow.workerExit?.cause ?? null,
      workerExit: state.follow.workerExit,
      follow: state.follow,
      lastProgressAt: state.follow.confirmedAt,
      requestId: null,
      intervention: null,
    });
    applyFollowSnapshot(task, snapshot);
    startFollowTimer(task);
  };

  // The turn is not observable at all, so the worker's own terminal verdict is
  // what the task is left with; nothing is invented from a session that could not
  // be read.
  const settleWorkerVerdict = (task, reason) => {
    const state = ctx.manifest.tasks[task.id];
    if (!state || ctx.settled.has(task.id)) return;
    const workerExit = state.follow?.workerExit ?? {};
    // The worker's own exit verdict is kept as-is when it is a real failure
    // status; `interrupted` is one of them, and it is never upgraded to
    // `completed` here.
    const status = ['failed', 'timeout', 'incomplete', 'interrupted'].includes(workerExit.status)
      ? workerExit.status
      : 'failed';
    settleFollow(task, {
      status,
      cause: state.workerCause ?? workerExit.cause ?? (status === 'timeout' ? 'timeout' : null),
      resultSource: 'worker_artifact',
      resultDigest: state.preFollowResult ?? null,
      followReason: reason,
      note: reason === 'session_unreadable'
        ? 'the daemon session could not be read, so the worker verdict stands'
        : 'the daemon session reported no in-flight turn, so the worker verdict stands',
      error: reason === 'session_unreadable'
        ? 'the daemon session could not be read after the worker exited'
        : null,
    });
  };

  const startFollowTimer = (task) => {
    const state = ctx.manifest.tasks[task.id];
    if (!state || !isFollowing(state)) return;
    stopFollowTimer(task.id);
    const timer = setInterval(() => {
      pollFollow(task).catch((error) => {
        ctx.notice(task, 'follow_poll_error', { error: String(error?.message ?? error).slice(0, 400) });
      });
    }, state.follow.pollMs ?? ctx.followPolicyConfig.pollMs);
    ctx.followTimers.set(task.id, timer);
  };

  // A worker exit that may leave a live turn behind: record the exit, archive the
  // early artifact, and probe the durable session before anything is journaled.
  const beginFollow = (task, exit) => {
    const state = ctx.manifest.tasks[task.id];
    if (!state) return;
    const since = new Date().toISOString();
    const deadlineMs = followDeadlineMsFor(task, ctx.followPolicyConfig.deadlineMs);
    const pollMs = followPollMsFor(task, ctx.followPolicyConfig.pollMs);
    const preFollow = readResultDigest(state.resultPath);
    const archived = archivePreFollowResult(state);
    if (preFollow && archived.length > 0) preFollow.path = archived[0];
    state.preFollowResult = preFollow;
    state.follow = {
      active: true,
      confirmed: false,
      reason: 'probing_turn',
      since,
      deadlineAt: new Date(Date.now() + deadlineMs).toISOString(),
      deadlineMs,
      pollMs,
      lostAfterPolls: ctx.followPolicyConfig.lostAfterPolls,
      probeTimeoutMs: ctx.followPolicyConfig.probeTimeoutMs,
      polls: 0,
      unreadablePolls: 0,
      lastPollAt: null,
      lastSnapshot: null,
      lastLive: null,
      lastCause: null,
      archived,
      workerExit: {
        at: since,
        exitCode: exit.exitCode ?? null,
        signal: exit.signal ?? null,
        status: exit.status ?? null,
        cause: exit.cause ?? null,
        // A group that outlived the direct child: the transport exited, but a
        // member of its tree is still alive and may still own the session.
        groupAlive: Boolean(exit.groupSurvivors),
        ...(exit.groupSurvivors ? { groupSurvivors: exit.groupSurvivors } : {}),
      },
    };
    ctx.persist();
    // The first probe is immediate: the turn may already be over, and making the
    // operator wait a whole interval for a fact already available helps nobody.
    pollFollow(task).catch((error) => {
      ctx.notice(task, 'follow_poll_error', { error: String(error?.message ?? error).slice(0, 400) });
    });
  };

  return { isFollowing, beginFollow, settleFollow };
}
