// The task's binding to its own CLI, for every call the supervisor makes into the
// daemon session a worker created.
//
// Stop, show, steer, and retry all have to reach the same binary, source entry,
// Home, and gateway the task spawned with, so they are built from one
// `sessionInvocation` rather than four argument lists that could drift apart. The
// bounded capture below is the only way the supervisor waits on an auxiliary
// command, and it never waits forever.

import { basename } from 'node:path';

import { getArgValue } from '../supervisor-core.mjs';
import { SANAD_CLIENT_COMMAND } from '../supervisor-spec.mjs';
import { STEER_TIMEOUT_MS } from '../supervisor-control.mjs';
import { spawnCommand, taskEnvironment } from './child-process.mjs';

export function createSessionSupport(ctx) {
  // Every auxiliary CLI call that targets a task's daemon session (stop, steer,
  // retry) is built here: it mirrors the task's own invocation form and pins, so
  // the call reaches the same binary, source entry, Home, and gateway the task
  // spawned with. One helper means the three commands cannot drift apart.
  const sessionInvocation = (task, sessionArgs) => {
    const pinned = [...sessionArgs];
    const gateway = getArgValue(task.args, task.id, '--gateway-url');
    if (gateway) pinned.push('--gateway-url', gateway);
    if (task.home) pinned.push('--home', task.home);
    const base = basename(task.command).toLowerCase();
    if (task.remote) {
      if (!SANAD_CLIENT_COMMAND.test(base)) return { reason: 'unsupported_remote_invocation' };
      if (!task.remoteDevice) return { reason: 'no_remote_device' };
      return {
        command: task.command,
        args: ['-d', task.remoteDevice, ...pinned],
        cwd: task.spawnCwd || task.workspace,
      };
    }
    if (task.implementer !== 'sanad') return { reason: 'not_a_sanad_task' };
    if (/^sanad(\.(exe|cmd|bat))?$/.test(base)) {
      return { command: task.command, args: pinned, cwd: task.spawnCwd || task.workspace };
    }
    if (/^fvm(\.(exe|cmd|bat))?$/.test(base)
      && task.args[0] === 'dart' && task.args[1] === 'run') {
      return {
        command: task.command,
        args: ['dart', 'run', task.args[2], ...pinned],
        cwd: task.spawnCwd || task.workspace,
      };
    }
    return { reason: 'unsupported_invocation' };
  };

  const sessionStopInvocation = (task, sessionId) => {
    if (!sessionId) return { reason: 'no_session_id' };
    if (task.remote) return { reason: 'remote_session' };
    if (task.implementer !== 'sanad') return { reason: 'not_a_sanad_task' };
    return sessionInvocation(task, ['session', 'stop', sessionId]);
  };

  // The read side of the same binding: `sanad session show <id> --json` is how a
  // follower observes a turn whose worker is gone. It inherits the task's own
  // Home, gateway, and invocation form, so the poll always reads the session the
  // worker created.
  const sessionShowInvocation = (task, sessionId) => {
    if (!sessionId) return { reason: 'no_session_id' };
    return sessionInvocation(task, ['session', 'show', sessionId, '--json']);
  };

  const requestSessionStop = (task, sessionId) => {
    const invocation = sessionStopInvocation(task, sessionId);
    if (!invocation.command) {
      return { requested: false, sessionId: sessionId ?? null, reason: invocation.reason };
    }
    let child;
    try {
      child = spawnCommand(invocation.command, invocation.args, {
        cwd: invocation.cwd,
        env: taskEnvironment(task, process.env),
        windowsHide: true,
        stdio: 'ignore',
      });
    } catch (error) {
      return { requested: false, sessionId, reason: error.message };
    }
    if (sessionId) ctx.pendingSessionStops.set(task.id, sessionId);
    child.once('error', (error) => {
      ctx.pendingSessionStops.delete(task.id);
      ctx.notice(task, 'session_stop', {
        sessionId,
        result: 'error',
        error: error.message,
      });
    });
    child.once('exit', (code, signal) => {
      ctx.pendingSessionStops.delete(task.id);
      ctx.notice(task, 'session_stop', {
        sessionId,
        result: code === 0 ? 'completed' : 'failed',
        exitCode: code,
        signal,
      });
    });
    return { requested: true, sessionId };
  };

  // Steering is the mid-turn channel into a live daemon session: the gateway
  // applies the message at the next execution boundary, so the task keeps its
  // session and its progress instead of being cancelled and re-dispatched.
  // `sessionSteerInvocation` is the single binding to the CLI contract
  // (`sanad session steer --session <id> --message-file <path> [--json]`).
  const sessionSteerInvocation = (task, sessionId, messageFile) => {
    if (!sessionId) return { reason: 'no_session_id' };
    return sessionInvocation(task, ['session', 'steer', '--session', sessionId, '--message-file', messageFile, '--json']);
  };

  // The recovery counterpart of steer: a turn the daemon left `blocked` has no
  // live owner to resume it, and a headless worker has no Client to press
  // Retry. `sanad session retry <id> [--provider <id>] [--model <id>] [--json]`
  // sends the same `session.runtime_retry` command the Client does.
  const sessionRetryInvocation = (task, sessionId, { provider = null, model = null } = {}) => {
    if (!sessionId) return { reason: 'no_session_id' };
    const args = ['session', 'retry', sessionId];
    if (provider) args.push('--provider', provider);
    if (model) args.push('--model', model);
    args.push('--json');
    return sessionInvocation(task, args);
  };

  // Bounded capture of one auxiliary CLI call (steer). The supervisor never
  // waits forever on an auxiliary command.
  const runAuxiliaryCommand = (invocation, task, timeoutMs = STEER_TIMEOUT_MS) => new Promise((resolvePromise) => {
    let child;
    try {
      child = spawnCommand(invocation.command, invocation.args, {
        cwd: invocation.cwd,
        env: taskEnvironment(task, process.env),
        windowsHide: true,
        stdio: ['ignore', 'pipe', 'pipe'],
      });
    } catch (error) {
      resolvePromise({ ok: false, error: error.message, exitCode: null, signal: null, stdout: '', stderr: '' });
      return;
    }
    let stdout = '';
    let stderr = '';
    let timedOut = false;
    child.stdout?.setEncoding('utf8');
    child.stderr?.setEncoding('utf8');
    child.stdout?.on('data', (chunk) => { stdout += chunk; });
    child.stderr?.on('data', (chunk) => { stderr += chunk; });
    const timer = setTimeout(() => {
      timedOut = true;
      try { child.kill('SIGTERM'); } catch {}
    }, timeoutMs);
    if (typeof timer.unref === 'function') timer.unref();
    const complete = (code, signal) => {
      clearTimeout(timer);
      resolvePromise({
        ok: !timedOut && code === 0,
        error: timedOut ? `command timed out after ${timeoutMs}ms` : null,
        exitCode: code,
        signal,
        stdout,
        stderr,
      });
    };
    child.once('error', (error) => {
      clearTimeout(timer);
      resolvePromise({ ok: false, error: error.message, exitCode: null, signal: null, stdout, stderr });
    });
    child.once('exit', complete);
  });

  return {
    sessionShowInvocation,
    requestSessionStop,
    sessionSteerInvocation,
    sessionRetryInvocation,
    runAuxiliaryCommand,
  };
}
