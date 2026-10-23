// Project a task's own event stream into journal transitions.
//
// A local task tails an artifact file and a remote relay task parses its streamed
// stdout, but both must produce exactly the same journal records, so the record
// handler is shared and this module owns both read paths. It is the only place a
// task's session id is picked up, which is what lets `cancel`, `steer`, and
// `retry` target the exact daemon session the worker created.

import {
  closeSync,
  existsSync,
  mkdirSync,
  openSync,
  readSync,
  statSync,
  watch,
  writeSync,
} from 'node:fs';
import { basename, dirname } from 'node:path';

import { retryAfterMs } from '../supervisor-retry.mjs';

export function createTimelineObserver(ctx) {
  const recordSessionId = (task, sessionId) => {
    if (!sessionId) return;
    const state = ctx.manifest.tasks[task.id];
    if (!state || state.sessionId === sessionId) return;
    state.sessionId = sessionId;
    ctx.persist();
  };

  // One processed timeline record. Local tasks tail an artifact file and remote
  // relay tasks parse their streamed stdout, but both must produce exactly the
  // same journal transitions, so the handler is shared.
  const createTimelineHandler = (task) => {
    let lastSeenType = null;
    let lastSeenRequestId = null;

    return (line) => {
      if (!line || !line.trim() || ctx.settled.has(task.id)) return;
      let event;
      try {
        event = JSON.parse(line);
      } catch {
        return;
      }

      const type = event.type;
      const data = event.data || {};
      const sessionId = event.session_id || event.sessionId || data.session_id || data.sessionId || null;
      const requestId = data.request_id || data.requestId || null;

      // The session id can arrive on any event, and usually after the launch
      // transition already reported `running`. Recording it here is what lets
      // `cancel` stop the exact daemon session later; it persists only when the
      // id actually changes, so per-token events cost nothing.
      recordSessionId(task, sessionId);

      if (type === 'needs_input' || type === 'needs_permission') {
        if (lastSeenType === type && lastSeenRequestId === requestId) return;
        lastSeenType = type;
        lastSeenRequestId = requestId;

        // Forward only the documented G2 intervention fields. Whitelisting
        // avoids leaking future provider/tool payload fields into the shared
        // supervisor journal.
        const intervention = {
          kind: data.kind || type,
          ...(requestId ? { request_id: requestId } : {}),
          ...(typeof data.tool_name === 'string'
            ? { tool_name: data.tool_name }
            : {}),
          ...(Array.isArray(data.questions)
            ? { questions: data.questions }
            : {}),
        };

        ctx.transition(task, type, {
          sessionId,
          requestId,
          intervention,
          kind: type,
          stateSince: event.timestamp || null,
        });
      } else if (type === 'retrying') {
        // The daemon scheduled another attempt for a retryable failure. This is
        // progress, not a verdict: the turn stays live and the attempt counters
        // are recorded so a status line can say `retrying (n/N)`.
        const attempt = Number(data.retry_attempt ?? data.retryAttempt);
        const budget = Number(data.retry_budget ?? data.retryBudget);
        const noticeIdentity = requestId || `${attempt ?? '?'}/${budget ?? '?'}`;
        if (lastSeenType === type && lastSeenRequestId === noticeIdentity) return;
        lastSeenType = type;
        lastSeenRequestId = noticeIdentity;
        ctx.transition(task, 'retrying', {
          ...(sessionId ? { sessionId } : {}),
          cause: data.cause || data.code || 'unknown',
          daemonRetry: {
            ...(Number.isInteger(attempt) ? { attempt } : {}),
            ...(Number.isInteger(budget) ? { budget } : {}),
          },
          ...(retryAfterMs(data) ? { retryAfterMs: retryAfterMs(data) } : {}),
          stateSince: event.timestamp || null,
        });
      } else if (type === 'blocked' || type === 'waiting') {
        const cause = data.cause || data.code || 'unknown';
        const noticeIdentity = requestId || cause;
        if (lastSeenType === type && lastSeenRequestId === noticeIdentity) return;
        lastSeenType = type;
        lastSeenRequestId = noticeIdentity;
        // A rate-limit notice may publish its own retry-after; the policy waits
        // for it instead of retrying into a guaranteed rejection.
        const retryAfter = retryAfterMs(data);
        ctx.transition(task, type, {
          // An event without a session id must never erase the one already
          // recorded: cancel, steer, and retry all depend on it.
          ...(sessionId ? { sessionId } : {}),
          cause,
          ...(retryAfter ? { retryAfterMs: retryAfter } : {}),
          stateSince: event.timestamp || null,
        });
      } else if (type === 'resumed') {
        if (ctx.manifest.tasks[task.id]?.status === 'running') return;
        lastSeenType = 'resumed';
        ctx.transition(task, 'resuming', {
          ...(sessionId ? { sessionId } : {}),
          requestId: null,
          intervention: null,
          cause: null,
          stateSince: event.timestamp || null,
        });
      } else if (type === 'running') {
        if (ctx.manifest.tasks[task.id]?.status === 'running') return;
        lastSeenType = 'running';
        ctx.transition(task, 'running', {
          ...(sessionId ? { sessionId } : {}),
          requestId: null,
          intervention: null,
          cause: null,
          stateSince: event.timestamp || null,
        });
      }

      if (type === 'tool_use' || event.part?.type === 'tool' || event.tool_executions) {
        const taskState = ctx.manifest.tasks[task.id];
        if (taskState) {
          const progressAt = event.timestamp || null;
          if (!progressAt) return;
          if (taskState.status === 'resuming') {
            ctx.transition(task, 'running', {
              cause: null,
              stateSince: progressAt,
              lastProgressAt: progressAt,
            });
          } else {
            // Tool boundaries are meaningful progress and low-frequency.
            // Assistant text can arrive per token, so it must never trigger
            // persistent manifest writes here.
            taskState.lastProgressAt = progressAt;
            ctx.persist();
          }
        }
      }
    };
  };

  const observeTimeline = (task, child) => {
    if (!task.timelinePath) return;
    const timelinePath = task.timelinePath;
    const dir = dirname(timelinePath);
    mkdirSync(dir, { recursive: true });

    let offset = 0;
    const handleLine = createTimelineHandler(task);

    const readAvailable = () => {
      if (ctx.settled.has(task.id)) return;
      if (!existsSync(timelinePath)) return;
      let stat;
      try {
        stat = statSync(timelinePath);
      } catch {
        return;
      }
      if (stat.size <= offset) return;

      let chunk;
      try {
        const fd = openSync(timelinePath, 'r');
        const buffer = Buffer.alloc(stat.size - offset);
        readSync(fd, buffer, 0, buffer.length, offset);
        closeSync(fd);
        chunk = buffer.toString('utf8');
      } catch {
        return;
      }

      const lastNewline = chunk.lastIndexOf('\n');
      if (lastNewline === -1) return;

      const completeChunk = chunk.slice(0, lastNewline + 1);
      offset += Buffer.byteLength(completeChunk, 'utf8');

      const lines = completeChunk.split(/\r?\n/);
      for (const line of lines) {
        handleLine(line);
      }
    };

    try {
      const watcher = watch(dir, (_eventType, filename) => {
        if (!filename || String(filename) === basename(timelinePath)) {
          readAvailable();
        }
      });
      ctx.timelineWatchers.set(task.id, watcher);
    } catch {
      // If watching fails, fall back
    }

    readAvailable();
  };

  // Remote relay tasks are streamed through the worker: their lifecycle events
  // and terminal `--json` envelope share stdout, so the worker mirrors both
  // streams into the task logs and journals events as they arrive. A filesystem
  // watch over a file the worker itself opened is not reliable enough for live
  // intervention detection, and the terminal transition must wait for the pipe
  // to drain so the envelope is never truncated.
  const observeRelayStream = (task, child, stdoutFd, stderrFd) => {
    const handleLine = createTimelineHandler(task);
    let pending = '';
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (chunk) => {
      try { writeSync(stdoutFd, chunk); } catch {}
      pending += chunk;
      let index = pending.indexOf('\n');
      while (index !== -1) {
        handleLine(pending.slice(0, index));
        pending = pending.slice(index + 1);
        index = pending.indexOf('\n');
      }
    });
    child.stderr.setEncoding('utf8');
    child.stderr.on('data', (chunk) => {
      try { writeSync(stderrFd, chunk); } catch {}
    });
  };

  return { observeTimeline, observeRelayStream };
}
