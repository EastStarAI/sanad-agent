// The worker's control plane: the request inbox, its dispatcher, and the task
// operations a request selects.
//
// One request file is processed exactly once, acknowledged atomically, and then
// acted on by the single operation that owns that request type. `cancel`,
// `continue`, `steer`, and `retry` refuse a task whose state does not match the
// operation — a live worker blocks a re-dispatch, a running task cannot be
// steered without a session id, and only a blocked or waiting task is retried — so
// a raw request file can never make the worker contradict its own manifest. The
// retry sender is shared by the manual command and the automatic policy, and the
// message body of a steer is never journaled.

import {
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  renameSync,
  statSync,
  unlinkSync,
  writeFileSync,
} from 'node:fs';
import { basename, isAbsolute, join, resolve } from 'node:path';

import { TERMINAL_STATUSES } from '../supervisor-events.mjs';
import {
  parseIsoMillis,
  processIsAlive,
  publicTask,
  sha256,
  withRunPaths,
  writeJsonAtomic,
} from '../supervisor-core.mjs';
import {
  RETRY_TIMEOUT_MS,
  RETRYABLE_TASK_STATUSES,
  normalizeRetryRoute,
} from '../supervisor-control.mjs';
import { attemptsForEpisode, planAutoRetry, retryAfterMs } from '../supervisor-retry.mjs';
import { queueOutcomes, queueSnapshot } from '../supervisor-views.mjs';
import { signalTaskProcess } from './child-process.mjs';

// `sanad session retry` exit codes (B5 contract). The supervisor reports the
// daemon's own verdict instead of inventing one: `retrying` means the recovery
// transition was acknowledged, `not_blocked` means nothing was sent.
const RETRY_EXIT_OUTCOMES = new Map([
  [0, 'retrying'],
  [1, 'transport_error'],
  [3, 'not_blocked'],
  [4, 'rejected'],
  [5, 'unacknowledged'],
  [8, 'state_unreadable'],
]);
function lastNonEmptyLine(value) {
  if (typeof value !== 'string') return null;
  const lines = value.split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
  return lines.length ? lines.at(-1) : null;
}

// A CLI command prints one `--json` envelope as the last stdout line; reading a
// field from it keeps the supervisor's journal correlated with the CLI's own
// request id instead of the supervisor's guess.
function lastJsonField(stdout, keys) {
  const last = lastNonEmptyLine(stdout);
  if (!last || !last.startsWith('{')) return null;
  let parsed;
  try {
    parsed = JSON.parse(last);
  } catch {
    return null;
  }
  for (const key of keys) {
    const value = parsed?.[key];
    if (typeof value === 'string' && value.trim()) return value.trim();
  }
  return null;
}

/**
 * The coordinator's triage view of one task's `result.json`.
 *
 * `sanad run` writes the versioned artifact (status, exit_code, text, ...);
 * wrapper tasks may additionally publish `branch`, `head_sha`, and `pr_url`.
 * Reading them here means a completion line already carries everything needed
 * to decide the next step, without a second call.
 */
export function createRequestHandler(ctx) {

/**
 * The visible result of one task, and what a `result.json` on its path means for
 * it.
 *
 * A terminal artifact belongs to the task when it was produced inside the
 * task's own window. A followed task is the one exception: its verdict was read
 * from the durable session, so an artifact written afterwards is triage evidence
 * (`laterResult`) and never the task's result.
 */
// The delta brief replaces the task's declared brief input. Only documented
// brief flags are rewritten so an arbitrary argument list is never guessed at.
function replaceBriefArgument(args, briefPath) {
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === '--brief-file' || arg === '-b' || arg === '--prompt-file') {
      if (index + 1 >= args.length) return null;
      return {
        flag: arg,
        args: [...args.slice(0, index + 1), briefPath, ...args.slice(index + 2)],
      };
    }
    for (const flag of ['--brief-file=', '--prompt-file=']) {
      if (arg.startsWith(flag)) {
        return {
          flag,
          args: [...args.slice(0, index), `${flag}${briefPath}`, ...args.slice(index + 1)],
        };
      }
    }
  }
  return null;
}

// `--new-session` drops the session pins so the next attempt starts a fresh
// daemon session instead of resuming the finished one.
function stripSessionArguments(args) {
  const stripped = [];
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === '--session' || arg === '-s') {
      index += 1;
      continue;
    }
    if (arg.startsWith('--session=') || arg === '--continue') continue;
    stripped.push(arg);
  }
  return stripped;
}

  const cancelTask = (id) => {
    const state = ctx.manifest.tasks[id];
    if (!state) return { ok: false, error: `task not found: ${id}` };
    const task = ctx.taskMap.get(id);
    if (!task) return { ok: false, error: `task not found: ${id}` };
    if (ctx.settled.has(id) || TERMINAL_STATUSES.has(state.status)) {
      return { ok: false, error: `task ${id} is already ${state.status}` };
    }
    const from = state.status;
    if (from === 'queued' || from === 'held') {
      // A task that never started is cancelled outright: no signal, no daemon
      // session, and no later launch because settlement is already recorded.
      ctx.settled.add(id);
      ctx.transition(task, 'aborted', {
        cancellationRequested: true,
        cancelledAt: new Date().toISOString(),
        error: from === 'queued'
          ? 'cancelled while queued; the task never started'
          : 'cancelled while held; the task was never queued',
      });
      ctx.checkRunCompletion();
      return { ok: true, taskId: id, from, status: 'aborted', signalled: null, sessionStop: null };
    }

    // In-flight turns (running, blocked, waiting, resuming, intervention) share
    // one cancellation path: the relay's own timeout semantics plus an explicit
    // daemon session stop when the session id is already known.
    if (state.cancellationRequested) {
      // A repeated cancel must not signal twice or spawn a second session stop;
      // the first request is already waiting for the child to settle.
      return { ok: true, taskId: id, from, status: 'cancelling', signalled: null, sessionStop: null, alreadyRequested: true };
    }
    // A followed task has no child process to signal: the turn belongs to the
    // daemon, so the stop is sent to the session and the task settles here
    // instead of waiting for an exit that already happened.
    if (ctx.isFollowing(state)) {
      state.cancellationRequested = true;
      const sessionId = state.sessionId ?? null;
      const sessionStop = ctx.requestSessionStop(task, sessionId);
      ctx.notice(task, 'cancel_requested', {
        sessionId,
        followed: true,
        signalled: null,
        sessionStop: sessionStop.requested === true,
        ...(sessionStop.reason ? { sessionStopReason: sessionStop.reason } : {}),
      });
      ctx.settleFollow(task, {
        status: 'cancelled',
        cause: 'cancelled',
        resultSource: 'operator',
        note: 'cancelled while following the daemon session',
        error: 'the turn was cancelled by the operator',
      });
      return {
        ok: true,
        taskId: id,
        from,
        status: 'cancelled',
        signalled: null,
        sessionId,
        sessionStop,
        followed: true,
      };
    }
    state.cancellationRequested = true;
    const sessionId = state.sessionId ?? null;
    const sessionStop = ctx.requestSessionStop(task, sessionId);
    const child = ctx.children.get(id) ?? null;
    // The signal goes to the worker's whole process group: a wrapper (`fvm`,
    // `npm`, `cmd`) forwarding or ignoring a signal must never leave the real
    // worker running after the cancel was reported as delivered.
    const signalled = child ? signalTaskProcess(state, child, 'SIGTERM') : null;
    if (signalled) {
      const timer = setTimeout(() => {
        if (ctx.settled.has(id)) return;
        const current = ctx.manifest.tasks[id] ?? null;
        // Same target for the forced kill: the group, not the leader that may
        // already be gone while its members ignore SIGTERM.
        signalTaskProcess(current, ctx.children.get(id) ?? null, 'SIGKILL');
      }, ctx.cancelForceKillMs);
      if (typeof timer.unref === 'function') timer.unref();
      ctx.forceKillTimers.set(id, timer);
    }
    ctx.notice(task, 'cancel_requested', {
      sessionId,
      signalled: signalled?.signal ?? null,
      pgid: signalled?.pgid ?? null,
      group: signalled?.group === true,
      sessionStop: sessionStop.requested === true,
      ...(sessionStop.reason ? { sessionStopReason: sessionStop.reason } : {}),
    });
    return {
      ok: true,
      taskId: id,
      from,
      status: 'cancelling',
      signalled: signalled?.signal ?? null,
      pgid: signalled?.pgid ?? null,
      group: signalled?.group === true,
      sessionId,
      sessionStop,
    };
  };

  // `continue` re-dispatches a finished task as a numbered new attempt with a
  // delta brief, in the same workspace and with the same task id. One session
  // per task: a live worker process or an in-flight session stop blocks the
  // re-dispatch, so two turns can never share one task identity.
  const continueTask = (req) => {
    const id = req.taskId;
    const state = ctx.manifest.tasks[id];
    const task = ctx.taskMap.get(id);
    if (!state || !task) return { ok: false, error: `task not found: ${id}` };
    if (ctx.manifest.closed) return { ok: false, error: 'cannot continue a task in a closed run' };
    if (!TERMINAL_STATUSES.has(state.status)) {
      return {
        ok: false,
        error: `task ${id} is ${state.status}; continue needs a finished task (cancel it first)`,
      };
    }
    if (processIsAlive(state.pid) || ctx.children.has(id)) {
      return {
        ok: false,
        error: `task ${id} still has a live worker process (pid ${state.pid}); stop it before continuing`,
      };
    }
    if (ctx.pendingSessionStops.has(id)) {
      return {
        ok: false,
        error: `task ${id} daemon session ${ctx.pendingSessionStops.get(id)} is still stopping; verify it is gone before continuing`,
      };
    }

    const briefPath = resolve(req.briefPath || '');
    if (!req.briefPath || !isAbsolute(req.briefPath) || !existsSync(briefPath) || !statSync(briefPath).isFile()) {
      return { ok: false, error: `--brief-file must be an existing absolute file path: ${req.briefPath}` };
    }
    const briefContent = readFileSync(briefPath, 'utf8');
    if (!briefContent.trim()) return { ok: false, error: '--brief-file is empty' };

    const replaced = replaceBriefArgument(task.args, briefPath);
    if (!replaced) {
      return {
        ok: false,
        error: `task ${id} has no --brief-file argument to replace; enqueue a new task instead of continuing`,
      };
    }
    let nextArgs = replaced.args;
    if (req.newSession) nextArgs = stripSessionArguments(nextArgs);

    const previousAttempt = state.attempt ?? 1;
    const attemptNumber = previousAttempt + 1;
    const archive = archiveAttemptArtifacts(state, previousAttempt);
    task.args = nextArgs;
    task.effectiveArgs = task.home ? [...nextArgs, '--home', task.home] : nextArgs;
    ctx.persistTasks();

    const previousStatus = state.status;
    state.attempt = attemptNumber;
    ctx.notice(task, 'continue_requested', {
      attempt: attemptNumber,
      previousAttempt,
      previousStatus,
      briefPath,
      briefSha256: sha256(briefContent),
      briefLength: briefContent.length,
      newSession: req.newSession === true,
      archived: archive.files,
    });
    ctx.settled.delete(id);
    ctx.transition(task, 'queued', {
      pid: null,
      startedAt: null,
      finishedAt: null,
      exitCode: null,
      signal: null,
      error: null,
      cause: null,
      identity: null,
      reportedStatus: null,
      lastProgressAt: null,
      progressStall: null,
      cancellationRequested: false,
      sessionId: null,
      attempt: attemptNumber,
      briefFile: briefPath,
      previousStatus,
      continuedAt: new Date().toISOString(),
    });
    ctx.launchAvailable();
    return {
      ok: true,
      taskId: id,
      attempt: attemptNumber,
      previousAttempt,
      previousStatus,
      status: ctx.manifest.tasks[id]?.status ?? 'queued',
      briefPath,
      newSession: req.newSession === true,
      archived: archive.files,
      archiveDir: archive.dir,
      active: ctx.active,
      maxConcurrency: ctx.maxConcurrency,
    };
  };

  // `steer` delivers a mid-turn message to a task that is already running. The
  // message body is transient: the journal keeps only its sha256 and length.
  const steerTask = async (req) => {
    const id = req.taskId;
    const state = ctx.manifest.tasks[id];
    const task = ctx.taskMap.get(id);
    if (!state || !task) return { ok: false, error: `task not found: ${id}` };
    if (state.status !== 'running') {
      return {
        ok: false,
        error: `task ${id} is ${state.status}; steer needs a running task (use continue for a finished one)`,
      };
    }
    const sessionId = state.sessionId ?? null;
    if (!sessionId) {
      return {
        ok: false,
        error: `task ${id} has no recorded session id yet; wait until the session is observable, then steer`,
      };
    }

    let messageFile = req.messageFile ? resolve(req.messageFile) : null;
    let temporaryFile = null;
    if (messageFile) {
      if (!isAbsolute(messageFile) || !existsSync(messageFile) || !statSync(messageFile).isFile()) {
        return { ok: false, error: `--message-file must be an existing absolute file path: ${req.messageFile}` };
      }
    } else if (typeof req.message === 'string' && req.message.trim().length > 0) {
      const directory = join(ctx.runDir, 'steer');
      mkdirSync(directory, { recursive: true });
      temporaryFile = join(directory, `steer-${id}-${Date.now()}.md`);
      writeFileSync(temporaryFile, req.message, 'utf8');
      messageFile = temporaryFile;
    } else {
      return { ok: false, error: 'steer requires --message or --message-file' };
    }

    try {
      const content = readFileSync(messageFile, 'utf8');
      const messageSha256 = sha256(content);
      const messageLength = content.length;
      const invocation = ctx.sessionSteerInvocation(task, sessionId, messageFile);
      if (!invocation.command) {
        return {
          ok: false,
          error: `cannot steer task ${id}: ${invocation.reason}`,
          reason: invocation.reason,
        };
      }
      const result = await ctx.runAuxiliaryCommand(invocation, task);
      const cliRequestId = lastJsonField(result.stdout, ['request_id', 'requestId']);
      const diagnostic = result.ok
        ? null
        : (lastNonEmptyLine(result.stderr) ?? result.error ?? 'steer command failed');
      const event = ctx.notice(task, 'steer_sent', {
        sessionId,
        // The supervisor's own control-request id, plus the CLI's request id
        // when the command reports one. The message body is never journaled.
        requestId: req.id ?? null,
        ...(cliRequestId ? { cliRequestId } : {}),
        messageSha256,
        messageLength,
        transport: 'message-file',
        result: result.ok ? 'completed' : 'failed',
        exitCode: result.exitCode,
        signal: result.signal,
        ...(diagnostic ? { error: String(diagnostic).slice(0, 400) } : {}),
      });
      if (!result.ok) {
        return {
          ok: false,
          error: `steer rejected for task ${id}: ${diagnostic ?? 'command failed'}`,
          taskId: id,
          sessionId,
          requestId: req.id ?? null,
          messageSha256,
          messageLength,
          journalSeq: event.seq,
        };
      }
      return {
        ok: true,
        taskId: id,
        sessionId,
        requestId: req.id ?? null,
        cliRequestId,
        messageSha256,
        messageLength,
        journalSeq: event.seq,
        exitCode: result.exitCode,
      };
    } finally {
      if (temporaryFile) {
        try { unlinkSync(temporaryFile); } catch {}
      }
    }
  };

  // One retry send, shared by the manual `retry` command and the automatic
  // policy. Only the journal kind differs (`retry_sent` vs `auto_retry`) so a
  // coordinator can tell its own instruction from the supervisor's budget;
  // neither is a wake-up. The daemon's verdict is reported, not invented, and a
  // refused retry (`not_blocked`) is not silently counted as a success.
  const retrySession = async (task, state, options) => {
    const {
      kind,
      provider = null,
      model = null,
      automatic = false,
      attempt = null,
      maxAttempts = null,
      delayMs = null,
    } = options;
    const sessionId = state.sessionId ?? null;
    const requestedAt = new Date().toISOString();
    const episode = state.retryEpisode ?? 0;
    const invocation = ctx.sessionRetryInvocation(task, sessionId, { provider, model });
    if (!invocation.command) {
      const unsupported = ctx.notice(task, kind, {
        sessionId,
        automatic,
        result: 'unsupported',
        reason: invocation.reason,
      });
      return {
        ok: false,
        error: `cannot retry task ${task.id}: ${invocation.reason}`,
        reason: invocation.reason,
        journalSeq: unsupported.seq,
      };
    }
    const result = await ctx.runAuxiliaryCommand(invocation, task, RETRY_TIMEOUT_MS);
    const outcome = result.exitCode == null
      ? 'failed'
      : RETRY_EXIT_OUTCOMES.get(result.exitCode) ?? 'failed';
    const cliRequestId = lastJsonField(result.stdout, ['request_id', 'requestId', 'notice_request_id']);
    const diagnostic = result.ok
      ? null
      : (lastNonEmptyLine(result.stderr) ?? result.error ?? 'retry command failed');
    // The attempt is recorded against the block that caused it, with the send
    // time (not the completion time) so backoff is measured from the request.
    const entry = {
      attempt: attempt ?? attemptsForEpisode(state, episode).length + 1,
      at: requestedAt,
      episode,
      automatic: automatic === true,
      cause: state.cause ?? null,
      provider,
      model,
      exitCode: result.exitCode,
      result: outcome,
      ...(delayMs != null ? { backoffMs: delayMs } : {}),
    };
    state.retryAttempts = [...(state.retryAttempts ?? []), entry];
    state.nextRetryAt = null;
    ctx.persist();
    const event = ctx.notice(task, kind, {
      sessionId,
      automatic: automatic === true,
      attempt: entry.attempt,
      ...(maxAttempts != null ? { maxAttempts } : {}),
      cause: entry.cause,
      provider,
      model,
      requestedAt,
      ...(cliRequestId ? { cliRequestId } : {}),
      result: outcome,
      sent: result.exitCode === 0,
      exitCode: result.exitCode,
      signal: result.signal,
      ...(delayMs != null ? { backoffMs: delayMs } : {}),
      ...(diagnostic ? { error: String(diagnostic).slice(0, 400) } : {}),
    });
    const ok = result.exitCode === 0;
    return {
      ok,
      taskId: task.id,
      sessionId,
      attempt: entry.attempt,
      ...(maxAttempts != null ? { maxAttempts } : {}),
      result: outcome,
      exitCode: result.exitCode,
      signal: result.signal,
      cliRequestId,
      journalSeq: event.seq,
      ...(ok ? {} : { error: `retry ${outcome} for task ${task.id}${diagnostic ? `: ${diagnostic}` : ''}` }),
    };
  };

  // `retry` is the manual recovery path for a blocked or waiting task. It is
  // refused for a task that is running (nothing to resume) or finished (the
  // `continue` path), and the worker repeats that check authoritatively.
  const retryTask = async (req) => {
    const id = req.taskId;
    const state = ctx.manifest.tasks[id];
    const task = ctx.taskMap.get(id);
    if (!state || !task) return { ok: false, error: `task not found: ${id}` };
    if (!RETRYABLE_TASK_STATUSES.includes(state.status)) {
      return {
        ok: false,
        error: `task ${id} is ${state.status}; retry needs a blocked or waiting task`,
      };
    }
    if (!state.sessionId) {
      return { ok: false, error: `task ${id} has no recorded session id yet; nothing to retry` };
    }
    if (ctx.retryInFlight.has(id)) {
      return { ok: false, error: `a retry for task ${id} is already in flight` };
    }
    ctx.retryInFlight.add(id);
    try {
      return await retrySession(task, state, {
        kind: 'retry_sent',
        provider: normalizeRetryRoute(req.provider),
        model: normalizeRetryRoute(req.model),
      });
    } finally {
      ctx.retryInFlight.delete(id);
    }
  };

  // A run-level `--auto-retry` is the default; a task's own spec flag wins, so a
  // single task can opt in without enabling the whole run.
  const taskAutoRetry = (task) => (task.autoRetry == null ? ctx.autoRetry.enabled : task.autoRetry === true);

  // The automatic budget. The daemon spends its own automatic retry before it
  // publishes `blocked`, so a blocked worker stays blocked until something
  // outside resumes it; this is that "something", journaled attempt by attempt.
  const maybeAutoRetry = (id) => {
    const task = ctx.taskMap.get(id);
    const state = ctx.manifest.tasks[id];
    if (!task || !state || ctx.settled.has(id) || state.cancellationRequested) return;
    if (!taskAutoRetry(task)) return;
    if (ctx.retryInFlight.has(id)) return;
    const episode = state.retryEpisode ?? 0;
    const attempts = attemptsForEpisode(state, episode);
    const plan = planAutoRetry({
      status: state.status,
      cause: state.cause,
      blockedAtMs: parseIsoMillis(state.stateSince) ?? parseIsoMillis(state.blockedAt),
      lastRetryAtMs: attempts.length ? parseIsoMillis(attempts.at(-1).at) : null,
      attempts: attempts.length,
      nowMs: Date.now(),
      graceMs: ctx.autoRetry.graceMs,
      maxAttempts: ctx.autoRetry.maxAttempts,
      backoffMs: ctx.autoRetry.backoffMs,
      retryAfterMs: state.retryAfterMs ?? null,
    });
    if (plan.action === 'wait') {
      const dueAt = new Date(plan.dueAtMs).toISOString();
      if (state.nextRetryAt !== dueAt) {
        state.nextRetryAt = dueAt;
        ctx.persist();
      }
      return;
    }
    if (plan.action === 'retry') {
      ctx.retryInFlight.add(id);
      retrySession(task, state, {
        kind: 'auto_retry',
        automatic: true,
        attempt: plan.attempt,
        maxAttempts: plan.maxAttempts,
        delayMs: plan.delayMs,
      }).catch((error) => {
        ctx.notice(task, 'auto_retry', {
          automatic: true,
          attempt: plan.attempt,
          result: 'error',
          error: String(error?.message ?? error).slice(0, 400),
        });
      }).finally(() => ctx.retryInFlight.delete(id));
      return;
    }
    if (plan.reason === 'attempts_exhausted' && !state.retryExhaustedAt) {
      // Actionable: the policy is done trying, so the next decision is a
      // coordinator's (switch provider, continue with a new brief, cancel).
      state.retryExhaustedAt = new Date().toISOString();
      const last = attempts.at(-1) ?? null;
      ctx.notice(task, 'retry_exhausted', {
        attempts: plan.attempts,
        maxAttempts: plan.maxAttempts,
        cause: state.cause ?? null,
        blockedSince: state.stateSince ?? null,
        lastRetryAt: last?.at ?? null,
        lastResult: last?.result ?? null,
        lastExitCode: last?.exitCode ?? null,
      });
    }
  };

  // Attempt artifacts are archived, not deleted: the previous attempt's result
  // stays available for triage after the task is re-scoped.
  const archiveAttemptArtifacts = (state, attemptNumber) => {
    const dir = join(ctx.runDir, 'attempts', state.id, `attempt-${attemptNumber}`);
    const sources = new Set([
      state.resultPath,
      state.timelinePath,
      state.stdoutPath,
      state.stderrPath,
    ].filter(Boolean));
    mkdirSync(dir, { recursive: true });
    const files = [];
    for (const source of sources) {
      if (!existsSync(source)) continue;
      const target = join(dir, basename(source));
      try {
        renameSync(source, target);
        files.push(target);
      } catch {
        // A file another process still holds open stays where it is; the attempt
        // record keeps pointing at the original path.
      }
    }
    return { dir, files };
  };

  function handleRequest(req) {
    if (req.type === 'add') {
      if (ctx.manifest.closed) {
        return { ok: false, error: 'cannot add tasks to closed run' };
      }
      const newTasks = req.tasks || [];
      for (const t of newTasks) {
        if (ctx.manifest.tasks[t.id]) {
          return { ok: false, error: `duplicate task id: ${t.id}` };
        }
      }
      for (const t of newTasks) {
        const task = withRunPaths(t, ctx.runDir);
        ctx.taskMap.set(task.id, task);
        ctx.taskList.push(task);
        ctx.manifest.tasks[task.id] = publicTask(task, ctx.runDir, 'held');
        ctx.transition(task, 'held');
      }
      ctx.persist();
      const addedIds = newTasks.map((t) => t.id);
      // Held tasks are reported per task too: an added task never starts until
      // it is explicitly enqueued, and the caller must see that.
      return {
        ok: true,
        taskIds: addedIds,
        active: ctx.active,
        maxConcurrency: ctx.maxConcurrency,
        queued: queueSnapshot(ctx.manifest).queued.length,
        tasks: queueOutcomes(ctx.manifest, addedIds),
      };
    }

    if (req.type === 'enqueue') {
      if (ctx.manifest.closed) {
        return { ok: false, error: 'cannot enqueue tasks to closed run' };
      }
      let ids;
      if (req.spec) {
        const newTasks = req.tasks || [];
        for (const t of newTasks) {
          if (ctx.manifest.tasks[t.id]) {
            return { ok: false, error: `duplicate task id: ${t.id}` };
          }
        }
        for (const t of newTasks) {
          const task = withRunPaths(t, ctx.runDir);
          ctx.taskMap.set(task.id, task);
          ctx.taskList.push(task);
          ctx.manifest.tasks[task.id] = publicTask(task, ctx.runDir, 'queued');
          ctx.transition(task, 'queued');
        }
        ids = newTasks.map((t) => t.id);
      } else {
        ids = req.taskIds || [];
        for (const id of ids) {
          const taskEntry = ctx.manifest.tasks[id];
          if (!taskEntry) {
            return { ok: false, error: `task not found: ${id}` };
          }
          if (taskEntry.status !== 'held') {
            return { ok: false, error: `task ${id} is not held (status: ${taskEntry.status})` };
          }
        }
        for (const id of ids) {
          const task = ctx.taskMap.get(id);
          ctx.transition(task, 'queued');
        }
      }
      ctx.persist();
      ctx.launchAvailable();
      // `launchAvailable` fills every free slot synchronously, so the per-task
      // outcome already reflects started-versus-queued plus the live counts.
      return {
        ok: true,
        taskIds: ids,
        active: ctx.active,
        maxConcurrency: ctx.maxConcurrency,
        queued: queueSnapshot(ctx.manifest).queued.length,
        tasks: queueOutcomes(ctx.manifest, ids),
      };
    }

    if (req.type === 'cancel') {
      const ids = req.taskIds || [];
      if (ids.length !== 1) {
        return { ok: false, error: 'cancel requires exactly one task id' };
      }
      return cancelTask(ids[0]);
    }

    if (req.type === 'continue') {
      return continueTask(req);
    }

    if (req.type === 'steer') {
      // Async by nature (it waits for one bounded CLI call); the request
      // processor awaits a returned promise before writing the acknowledgement.
      return steerTask(req);
    }

    if (req.type === 'retry') {
      return retryTask(req);
    }

    if (req.type === 'set-concurrency') {
      const requested = Number(req.maxConcurrency);
      if (!Number.isInteger(requested) || requested < 1) {
        return { ok: false, error: 'max concurrency must be a positive integer' };
      }
      const previous = ctx.maxConcurrency;
      ctx.maxConcurrency = requested;
      ctx.manifest.maxConcurrency = requested;
      ctx.persist();
      const queuedBefore = queueSnapshot(ctx.manifest).queued.map((entry) => entry.id);
      ctx.launchAvailable();
      const started = queuedBefore.filter((id) => ctx.manifest.tasks[id]?.status === 'running');
      return {
        ok: true,
        previous,
        maxConcurrency: ctx.maxConcurrency,
        active: ctx.active,
        started,
        queued: queueSnapshot(ctx.manifest).queued.length,
        tasks: queueOutcomes(ctx.manifest, started),
      };
    }

    if (req.type === 'close') {
      if (ctx.manifest.closed) {
        return { ok: true, alreadyClosed: true };
      }
      ctx.manifest.closed = true;
      const aborted = [];
      for (const [id, tEntry] of Object.entries(ctx.manifest.tasks)) {
        if (tEntry.status === 'held') {
          const task = ctx.taskMap.get(id);
          ctx.settled.add(id);
          ctx.transition(task, 'aborted', { error: 'run closed while task was held' });
          aborted.push(id);
        } else if (req.abortQueued && tEntry.status === 'queued') {
          const task = ctx.taskMap.get(id);
          ctx.settled.add(id);
          ctx.transition(task, 'aborted', {
            cancellationRequested: true,
            cancelledAt: new Date().toISOString(),
            error: 'queued task aborted by close --abort-queued',
          });
          aborted.push(id);
        }
      }
      ctx.persist();
      return { ok: true, closed: true, aborted, abortQueued: req.abortQueued === true };
    }

    return { ok: false, error: `unknown request type: ${req.type}` };
  }

  // Requests are processed once: `steer` is asynchronous, so a second watcher
  // event must not run the same request twice.
  const inFlightRequests = new Set();

  function processPendingRequests() {
    if (!existsSync(ctx.paths.requests)) return;
    let entries;
    try {
      entries = readdirSync(ctx.paths.requests);
    } catch {
      return;
    }
    for (const entry of entries) {
      if (!entry.endsWith('.req.json')) continue;
      if (inFlightRequests.has(entry)) continue;
      const reqFile = join(ctx.paths.requests, entry);
      const ackFile = join(ctx.paths.requests, entry.replace(/\.req\.json$/, '.ack.json'));
      if (existsSync(ackFile)) continue;
      let req;
      try {
        req = JSON.parse(readFileSync(reqFile, 'utf8'));
      } catch {
        continue;
      }
      inFlightRequests.add(entry);
      const complete = (ack) => {
        inFlightRequests.delete(entry);
        writeJsonAtomic(ackFile, ack);
        try { unlinkSync(reqFile); } catch {}
        if (req.type === 'close') {
          ctx.checkRunCompletion();
        }
      };
      let result;
      try {
        result = handleRequest(req);
      } catch (error) {
        complete({ ok: false, error: error.message });
        continue;
      }
      if (result && typeof result.then === 'function') {
        result.then(complete, (error) => complete({ ok: false, error: error.message }));
      } else {
        complete(result);
      }
    }
  }

  return { maybeAutoRetry, processPendingRequests };
}
