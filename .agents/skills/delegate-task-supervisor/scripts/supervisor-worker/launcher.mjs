// Launch, relaunch, and settle one task's worker.
//
// The launcher owns the whole life of a child process and nothing else:
//
// 1. `launchTask` fills one slot: it opens the task's artifact descriptors, spawns
//    the worker as the leader of its own process group, journals `running` with
//    the pid and pgid, and hands the stream to its observer.
// 2. `finishTask` is the single exit verdict. An exit is not a departure (a group
//    member may still be alive), a published `result.json` is the task's own last
//    word, a remote relay is judged by its `--json` envelope, an exit 78 is a
//    launch race and is relaunched, and a Sanad worker that exits while the daemon
//    still owns its turn is handed to the follower instead of being reported
//    `failed`.
// 3. `launchAvailable` is the only entry point a peer calls: it fills every free
//    slot from the queue in order and respects a pending launch backoff.

import { closeSync, existsSync, openSync, readFileSync } from 'node:fs';

import { TERMINAL_STATUSES } from '../supervisor-events.mjs';
import { parseIsoMillis, readResultDigest, writeJsonAtomic } from '../supervisor-core.mjs';
import { recordIdentity } from '../supervisor-registry.mjs';
import { planLaunchRetry } from '../supervisor-retry.mjs';
import {
  GROUP_SIGNALS_SUPPORTED,
  signalTaskProcess,
  spawnCommand,
  survivingGroupMembers,
  taskEnvironment,
} from './child-process.mjs';

// Remote delegation through `sanad-client` reports the relayed CLI exit code
// instead of a locally produced `result.json` status, so the supervisor owns
// this mapping. 69 (no live Client for the Home) and 77 (Client CLI disabled)
// mean the task never started on the target device and needs operator action,
// so both surface as blocked with the Client's own diagnostic as the cause.
const REMOTE_EXIT_STATUSES = new Map([
  [124, { status: 'timeout', cause: 'timeout' }],
  [130, { status: 'cancelled', cause: 'cancelled' }],
  [69, { status: 'blocked', cause: 'client_unavailable' }],
  [77, { status: 'blocked', cause: 'client_cli_disabled' }],
]);
// A forced kill is verified after this delay: a process the kernel just SIGKILLed
// is still visible until its parent reaps it, and that is not a survivor.
const GROUP_KILL_VERIFY_MS = 250;
export function createLauncher(ctx) {

// The terminal `--json` envelope relayed on stdout is the remote task result:
// a compact JSON object without a `type` field that carries the relayed exit
// code (and normally the session identity). Relayed lifecycle events always
// carry `type`, so they can never be mistaken for the envelope.
function lastRemoteEnvelope(content) {
  const accept = (value) => value != null
    && typeof value === 'object'
    && !Array.isArray(value)
    && !('type' in value)
    && (typeof value.exit_code === 'number' || typeof value.session_id === 'string');
  const lines = content.split(/\r?\n/);
  for (let index = lines.length - 1; index >= 0; index -= 1) {
    const line = lines[index].trim();
    if (!line.startsWith('{') || !line.endsWith('}')) continue;
    let parsed;
    try {
      parsed = JSON.parse(line);
    } catch {
      continue;
    }
    if (accept(parsed)) return parsed;
  }
  // A client that pretty-prints the envelope still produces one JSON document.
  const trimmed = content.trim();
  if (trimmed.startsWith('{')) {
    try {
      const parsed = JSON.parse(trimmed);
      if (accept(parsed)) return parsed;
    } catch {
      // Mixed stdout: only the line scan can succeed.
    }
  }
  return null;
}

function captureRemoteResult(task) {
  if (!task.resultPath || !task.stdoutPath || !existsSync(task.stdoutPath)) return;
  let content;
  try {
    content = readFileSync(task.stdoutPath, 'utf8');
  } catch {
    return;
  }
  const envelope = lastRemoteEnvelope(content);
  if (!envelope) return;
  writeJsonAtomic(task.resultPath, envelope);
}

// The Client CLI writes its unreachable/disabled diagnostics to stderr; the
// last line is the operator-facing cause behind a blocked remote task.
function lastDiagnosticLine(path) {
  if (!path || !existsSync(path)) return null;
  let content;
  try {
    content = readFileSync(path, 'utf8');
  } catch {
    return null;
  }
  const line = content.split(/\r?\n/).map((entry) => entry.trim()).filter(Boolean).at(-1) ?? null;
  if (!line) return null;
  return line.length > 400 ? `${line.slice(0, 397)}...` : line;
}

  // A relaunch is scheduled, not immediate: the daemon that just failed its
  // health check needs a moment, and the attempt history must survive. The task
  // returns to `queued` so concurrency accounting stays honest, and
  // `launchAvailable` refuses to start it before `launchRetryAt`.
  const scheduleLaunchRetry = (task, code, signal, plan) => {
    const state = ctx.manifest.tasks[task.id];
    if (!state) return;
    ctx.active = Math.max(0, ctx.active - 1);
    ctx.children.delete(task.id);
    const forceKillTimer = ctx.forceKillTimers.get(task.id);
    if (forceKillTimer) {
      clearTimeout(forceKillTimer);
      ctx.forceKillTimers.delete(task.id);
    }
    if (ctx.timelineWatchers.has(task.id)) {
      try { ctx.timelineWatchers.get(task.id).close(); } catch {}
      ctx.timelineWatchers.delete(task.id);
    }
    const startedAtMs = parseIsoMillis(state.startedAt);
    const attempt = {
      attempt: plan.attempt,
      at: new Date().toISOString(),
      exitCode: code,
      signal,
      elapsedMs: startedAtMs == null ? null : Math.max(0, Date.now() - startedAtMs),
      backoffMs: plan.delayMs,
      cause: 'daemon_unavailable',
    };
    state.launchRetries = [...(state.launchRetries ?? []), attempt];
    ctx.notice(task, 'launch_retry', { ...attempt, maxAttempts: plan.maxAttempts });
    const resumeAt = new Date(Date.now() + plan.delayMs).toISOString();
    ctx.transition(task, 'queued', {
      pid: null,
      cause: 'daemon_unavailable',
      launchRetryAt: resumeAt,
      launchRetries: state.launchRetries,
      error: `spawn exited ${code} before a healthy daemon answered; relaunch`
        + ` ${plan.attempt}/${plan.maxAttempts} in ${plan.delayMs}ms`,
    });
    const timer = setTimeout(() => {
      ctx.launchRetryTimers.delete(task.id);
      if (ctx.settled.has(task.id)) return;
      if (ctx.manifest.tasks[task.id]?.status !== 'queued') return;
      launchAvailable();
    }, plan.delayMs);
    ctx.launchRetryTimers.set(task.id, timer);
  };

  // A cancelled group whose leader exited first still has to be forced: the
  // wrapper is not the tree. The escalation is armed on the task rather than on a
  // child handle, so it fires even though the task already settled, and it
  // reports a group that survives its own SIGKILL instead of assuming it died.
  const forceKillGroupLater = (task, graceMs) => {
    const timer = setTimeout(() => {
      ctx.forceKillTimers.delete(task.id);
      const state = ctx.manifest.tasks[task.id] ?? null;
      if (!state) return;
      signalTaskProcess(state, null, 'SIGKILL');
      const verify = setTimeout(() => {
        const survivors = survivingGroupMembers(Number(state.pgid));
        if (!survivors) return;
        state.groupSurvivors = survivors;
        ctx.notice(task, 'worker_group_alive', {
          pgid: survivors.pgid,
          aliveAfterMs: survivors.aliveAfterMs,
          forced: true,
          forcedAfterMs: graceMs,
        });
      }, GROUP_KILL_VERIFY_MS);
      if (typeof verify.unref === 'function') verify.unref();
    }, graceMs);
    if (typeof timer.unref === 'function') timer.unref();
    ctx.forceKillTimers.set(task.id, timer);
  };

  const finishTask = (task, code, signal, launchError = null) => {
    if (ctx.settled.has(task.id)) return;
    // Exit 78 is the CLI's daemon-health pre-check: the spawn never reached a
    // turn, so relaunching it is a launch repair instead of a task failure. The
    // attempt is recorded and journaled, and the task returns to the queue for
    // its backoff window rather than settling as failed.
    const launchState = ctx.manifest.tasks[task.id];
    const launchPlan = launchError || !launchState
      ? { action: 'none' }
      : planLaunchRetry({
        exitCode: code,
        startedAtMs: parseIsoMillis(launchState.startedAt),
        endedAtMs: Date.now(),
        attempts: (launchState.launchRetries ?? []).length,
        maxAttempts: ctx.autoRetry.launchMaxAttempts,
        backoffMs: ctx.autoRetry.launchBackoffMs,
      });
    if (launchPlan.action === 'retry' && launchState.cancellationRequested !== true) {
      scheduleLaunchRetry(task, code, signal, launchPlan);
      return;
    }
    ctx.settled.add(task.id);
    ctx.active -= 1;
    ctx.children.delete(task.id);
    const forceKillTimer = ctx.forceKillTimers.get(task.id);
    if (forceKillTimer) {
      clearTimeout(forceKillTimer);
      ctx.forceKillTimers.delete(task.id);
    }

    if (ctx.timelineWatchers.has(task.id)) {
      try { ctx.timelineWatchers.get(task.id).close(); } catch {}
      ctx.timelineWatchers.delete(task.id);
    }

    // An exit is not a departure. The direct child can exit while a member of its
    // process group is still alive and still attached to the session — exactly
    // the 2026-10-23 `fvm` wrapper case. Nothing is concluded from the exit
    // before the group has been verified, and a surviving group is reported
    // instead of being described as a transport that left.
    const groupSurvivors = survivingGroupMembers(ctx.manifest.tasks[task.id]?.pgid);
    if (groupSurvivors) {
      // Always recorded, so a reader can see that the tree outlived the child.
      Object.assign(ctx.manifest.tasks[task.id], { groupSurvivors });
      // A cancelled task is already being killed as a group by the force-kill
      // timer; the survivor there is expected, so only an exit nobody is chasing
      // is worth a coordinator's attention.
      if (launchState?.cancellationRequested !== true) {
        ctx.notice(task, 'worker_group_alive', {
          pgid: groupSurvivors.pgid,
          pid: launchState?.pid ?? null,
          exitCode: code,
          signal,
          aliveAfterMs: groupSurvivors.aliveAfterMs,
        });
      }
    }
    // The cancellation timer above was cleared with the child handle, so the
    // forced kill is re-armed on the task: the wrapper exiting is not the group
    // exiting, and a cancelled tree must still be brought down.
    if (groupSurvivors && launchState?.cancellationRequested === true) {
      forceKillGroupLater(task, ctx.cancelForceKillMs);
    }

    let result = null;
    // Remote tasks have no local artifact producer, so the relayed `--json`
    // envelope on stdout is materialized into the task result path first.
    if (task.remote) captureRemoteResult(task);
    if (task.resultPath && existsSync(task.resultPath)) {
      try {
        result = JSON.parse(readFileSync(task.resultPath, 'utf8'));
      } catch {
        // Preserve process outcome when a producer leaves malformed output.
      }
    }
    const reportedStatus = result?.status ?? null;
    // An operator cancellation is authoritative: a signalled child may publish
    // `interrupted` or leave a stale `failed`, and neither may mask the fact
    // that this task was cancelled.
    const cancellationRequested = ctx.manifest.tasks[task.id]?.cancellationRequested === true;
    const remoteExit = task.remote && !TERMINAL_STATUSES.has(reportedStatus)
      ? REMOTE_EXIT_STATUSES.get(code) ?? null
      : null;
    // A relay that exits 0 without publishing the `--json` envelope cannot be
    // trusted as a completed turn: the Client CLI also reports success when the
    // control socket closes without a terminal result frame.
    const remoteCaptureMissing = task.remote && !launchError && code === 0 && result == null;
    const status = cancellationRequested
      ? 'cancelled'
      : TERMINAL_STATUSES.has(reportedStatus)
        ? reportedStatus
        : remoteExit
          ? remoteExit.status
          : remoteCaptureMissing
            ? 'incomplete'
            : code === 0 && !launchError
              ? 'completed'
              : 'failed';
    const remoteDiagnostic = task.remote && (remoteExit || remoteCaptureMissing)
      ? lastDiagnosticLine(task.stderrPath)
      : null;
    const identity = result == null ? null : {
      projectId: result.projectId ?? result.project_id ?? null,
      conversationId: result.conversationId ?? result.conversation_id ?? null,
      sessionId: result.sessionId ?? result.session_id ?? null,
    };
    if (result) recordIdentity(task, result);
    const finishedAt = new Date().toISOString();
    // A Sanad worker is only the transport for one daemon turn. When it exits
    // while the daemon still owns the turn, the task is followed instead of being
    // reported as failed: that is exactly the case where the daemon later asked a
    // question nobody saw (run7, 2026-10-23). The probe below is what proves the
    // turn is still in flight; until it says otherwise the task stays live.
    // `interrupted` belongs here too: a transport killed by a signal (the
    // 2026-10-23 live check sent SIGTERM to the group) writes its own
    // `interrupted` artifact while the daemon still holds the turn and its
    // pending question. Treating it as final is the same defect as settling a
    // failed transport: the daemon decides, and a turn that is really gone is
    // still reported by `turn_not_in_flight`.
    const followCandidate = task.implementer === 'sanad'
      && !task.remote
      && !cancellationRequested
      && !launchError
      && Boolean(ctx.manifest.tasks[task.id]?.sessionId)
      && ['failed', 'timeout', 'incomplete', 'interrupted'].includes(status);
    if (followCandidate) {
      // The turn is not final: this task is followed, not settled. The worker's
      // slot is released above, and the follow poll owns the task from here.
      ctx.settled.delete(task.id);
      Object.assign(ctx.manifest.tasks[task.id], {
        exitCode: code,
        signal,
        reportedStatus,
        workerCause: result?.cause ?? null,
      });
      ctx.beginFollow(task, {
        exitCode: code,
        signal,
        status,
        cause: result?.cause ?? (status === 'timeout' ? 'timeout' : null),
        // Recorded so the follow reports a surviving group instead of claiming
        // the transport left the turn unattended.
        groupSurvivors,
      });
      // The worker's slot is free even though the task is not finished, so a
      // queued task must be able to take it right away.
      launchAvailable();
      return;
    }
    ctx.transition(task, status, {
      pid: ctx.manifest.tasks[task.id]?.pid ?? null,
      finishedAt,
      stateSince: finishedAt,
      exitCode: code,
      signal,
      reportedStatus,
      identity,
      // The status line shows one verdict. A cancellation is the operator's, so
      // the signalled child's own `interrupted` artifact is reported as
      // `later-result` instead of contradicting the task's status.
      ...(cancellationRequested
        ? {
          cause: 'cancelled',
          cancelledAt: finishedAt,
          result: {
            status: 'cancelled',
            source: 'operator',
            sessionId: ctx.manifest.tasks[task.id]?.sessionId ?? null,
            cause: 'cancelled',
            endedAt: finishedAt,
          },
        }
        : {}),
      ...(task.remote ? { resultCaptured: result != null } : {}),
      ...(remoteExit && !cancellationRequested ? { cause: remoteExit.cause } : {}),
      ...(remoteCaptureMissing && !cancellationRequested ? { cause: 'missing_result_envelope' } : {}),
      ...(remoteDiagnostic ? { error: remoteDiagnostic } : {}),
      ...(launchError ? { error: launchError.message, cause: 'spawn_failed' } : {}),
    });

    // Attempt history: a continued task keeps the outcome of every attempt, so
    // one task identity can be re-scoped without losing what happened before.
    const finishedState = ctx.manifest.tasks[task.id];
    if (finishedState) {
      const attemptNumber = finishedState.attempt ?? 1;
      const digest = readResultDigest(finishedState.resultPath);
      finishedState.attempts = [
        ...(finishedState.attempts || []).filter((entry) => entry.attempt !== attemptNumber),
        {
          attempt: attemptNumber,
          startedAt: finishedState.startedAt ?? null,
          finishedAt,
          status,
          exitCode: code,
          signal,
          cause: finishedState.cause ?? null,
          sessionId: finishedState.sessionId ?? null,
          result: digest,
        },
      ];
      ctx.persist();
    }

    ctx.checkRunCompletion();
    launchAvailable();
  };

  const launchTask = (task) => {
    ctx.active += 1;
    const stdoutFd = openSync(ctx.manifest.tasks[task.id].stdoutPath, 'a');
    const stderrFd = openSync(ctx.manifest.tasks[task.id].stderrPath, 'a');
    const effectiveArgs = task.effectiveArgs || task.args;
    const streamRelay = task.remote === true;
    let fdsClosed = false;
    const closeTaskFds = () => {
      if (fdsClosed) return;
      fdsClosed = true;
      try { closeSync(stdoutFd); } catch {}
      try { closeSync(stderrFd); } catch {}
    };
    let child;
    try {
      // Stdin is never inherited: a delegated Sanad task reads its brief from
      // `--brief-file`, and `sanad-client` blocks on piped stdin until EOF, so
      // the child receives an immediate EOF instead of the supervisor's stdin.
      const spawnOptions = {
        cwd: task.spawnCwd || task.workspace,
        env: taskEnvironment(task, process.env),
        windowsHide: true,
        // The worker leads its own process group so cancel, the forced kill, and
        // shutdown can signal the whole tree instead of the wrapper only.
        detached: GROUP_SIGNALS_SUPPORTED,
        stdio: streamRelay ? ['ignore', 'pipe', 'pipe'] : ['ignore', stdoutFd, stderrFd],
      };
      child = spawnCommand(task.command, effectiveArgs, spawnOptions);
    } catch (error) {
      closeTaskFds();
      finishTask(task, 127, null, error);
      return;
    }
    ctx.children.set(task.id, child);
    if (!streamRelay) closeTaskFds();
    const startedAt = new Date().toISOString();
    ctx.transition(task, 'running', {
      pid: child.pid,
      // The group id is the leader's pid; it is recorded so every later signal
      // and every repair read targets the same group the worker was spawned in.
      pgid: GROUP_SIGNALS_SUPPORTED ? child.pid : null,
      startedAt,
      stateSince: startedAt,
      queueStall: null,
      progressStall: null,
      lastProgressAt: startedAt,
      launchRetryAt: null,
      cancellationRequested: false,
    });

    if (streamRelay) {
      ctx.observeRelayStream(task, child, stdoutFd, stderrFd);
    } else {
      ctx.observeTimeline(task, child);
    }

    child.once('error', (error) => {
      closeTaskFds();
      finishTask(task, 127, null, error);
    });
    if (streamRelay) {
      // `close` fires after both pipes are drained, so the captured envelope is
      // complete before the terminal transition reads it.
      child.once('close', (code, signal) => {
        closeTaskFds();
        finishTask(task, code, signal);
      });
    } else {
      child.once('exit', (code, signal) => finishTask(task, code, signal));
    }
  };

  function launchAvailable() {
    for (const task of ctx.taskList) {
      if (ctx.active >= ctx.maxConcurrency) break;
      const taskState = ctx.manifest.tasks[task.id];
      if (taskState && taskState.status === 'queued' && !ctx.settled.has(task.id)) {
        // A task waiting out its launch backoff is not ready yet; starting it
        // early would turn every other settlement into a retry bypass.
        const retryAt = parseIsoMillis(taskState.launchRetryAt);
        if (retryAt != null && retryAt > Date.now()) continue;
        launchTask(task);
      }
    }
  }

  return { launchAvailable };
}
