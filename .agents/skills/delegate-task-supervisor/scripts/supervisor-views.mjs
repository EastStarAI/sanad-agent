// Read-only surfaces: status, inspect, timeline, logs, and the viewer.
//
// These commands report what a run already recorded. The only write any of them
// performs is `status`'s repair of a run whose supervisor is gone, journaled like
// any worker transition. The session footer and the status/brief lines are
// formatted here because a coordinator reads the same facts from several entry
// points (`status`, its `--brief` form, the verbose form, and the task footer)
// and they must agree; the queue arithmetic they quote comes from
// `supervisor-core.mjs`.

import { spawn, spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, statSync, watch, writeFileSync } from 'node:fs';
import { basename, dirname, join, resolve } from 'node:path';

import {
  applyVisibleResult,
  describeProgress,
  describeQueuedTask,
  fail,
  formatDuration,
  formatShortDuration,
  processIsAlive,
  progressThresholdMs,
  queueSnapshot,
  queuedStallThreshold,
  readJson,
  readResultDigest,
  singleRun,
  taskResultForView,
  writeJsonAtomic,
} from './supervisor-core.mjs';
import { loadManifest, reconcileRun, requireTask, runPaths } from './supervisor-registry.mjs';
import {
  SCRIPT_PATH,
  launchThroughWindowsExplorer,
  windowsBatchQuote,
} from './supervisor-windows.mjs';
import { TERMINAL_STATUSES } from './supervisor-events.mjs';
import {
  DEFAULT_AUTO_RETRY_MAX_ATTEMPTS,
  DEFAULT_LAUNCH_RETRY_MAX_ATTEMPTS,
} from './supervisor-retry.mjs';

function resolveSessionDetails(task, manifest) {
  let result = null;
  if (task.resultPath && existsSync(task.resultPath)) {
    try {
      result = JSON.parse(readFileSync(task.resultPath, 'utf8'));
    } catch {}
  }

  const pid = task.pid ?? manifest?.tasks?.[task.id]?.pid ?? null;
  const isAlive = pid ? processIsAlive(pid) : false;
  const terminalStates = new Set(['completed', 'failed', 'timeout', 'cancelled', 'aborted', 'interrupted', 'incomplete', 'needs_review', 'follow_lost']);
  // Once the supervisor observes process exit, its terminal transition wins
  // over a stale nonterminal result artifact.
  const rawStatus = terminalStates.has(task.status)
    ? task.status
    : (result?.status || task.status);
  const cause = result?.cause || task.cause || (rawStatus === 'timeout' ? 'timeout' : null);
  let stateSince = result?.state_since || result?.stateSince || null;
  if (!stateSince && task.status === rawStatus) stateSince = task.stateSince || null;
  if (!stateSince && terminalStates.has(rawStatus)) {
    stateSince = task.finishedAt || result?.ended_at || result?.endedAt || null;
  }
  const lastProgressAt = result?.last_progress_at || result?.lastProgressAt || task.lastProgressAt || null;

  let sessionState = 'unknown';
  if (rawStatus === 'completed') {
    sessionState = 'completed';
  } else if (rawStatus === 'incomplete') {
    sessionState = 'incomplete';
  } else if (rawStatus === 'needs_review') {
    sessionState = 'needs review';
  } else if (terminalStates.has(rawStatus)) {
    sessionState = 'stopped';
  } else if (rawStatus === 'needs_input') {
    sessionState = 'waiting for input';
  } else if (rawStatus === 'needs_permission') {
    sessionState = 'waiting for permission';
  } else if (rawStatus === 'waiting') {
    sessionState = 'waiting';
  } else if (rawStatus === 'retrying') {
    // The daemon is retrying a retryable failure on its own: neither a stop nor
    // an intervention, so the footer names the attempt and its budget.
    const daemonRetry = task.daemonRetry ?? result?.daemonRetry ?? null;
    const counters = daemonRetry && (daemonRetry.attempt != null || daemonRetry.budget != null)
      ? ` (${daemonRetry.attempt ?? '?'}/${daemonRetry.budget ?? '?'})`
      : '';
    sessionState = `retrying${counters}`;
  } else if (rawStatus === 'blocked') {
    sessionState = 'blocked';
  } else if (rawStatus === 'resuming') {
    sessionState = 'resuming';
  } else if (rawStatus === 'following') {
    // The worker is gone but the daemon still owns the turn: walking away here is
    // exactly the failure this state was added to prevent.
    sessionState = 'following the daemon turn';
  } else if (rawStatus === 'follow_lost') {
    sessionState = 'follow lost';
  } else if (rawStatus === 'running') {
    // PID liveness proves only that a process exists. Report working only when
    // the runtime or supervisor recorded actual progress.
    sessionState = lastProgressAt ? 'working' : 'unknown';
  } else if (rawStatus === 'queued') {
    sessionState = 'queued';
  } else if (rawStatus === 'held') {
    sessionState = 'held';
  }

  const parseMillis = (value) => {
    if (!value) return null;
    const parsed = new Date(value).getTime();
    return Number.isNaN(parsed) ? null : parsed;
  };
  const explicitDuration = result?.duration_ms ?? result?.durationMs ?? null;
  const startTime = parseMillis(task.startedAt || result?.started_at || result?.startedAt);
  const endTime = parseMillis(task.finishedAt || result?.ended_at || result?.endedAt)
    ?? (terminalStates.has(rawStatus) ? null : Date.now());
  const elapsedMs = Number.isFinite(explicitDuration)
    ? explicitDuration
    : (startTime != null && endTime != null ? Math.max(0, endTime - startTime) : null);

  let observationSource = result ? 'result.json' : 'manifest';
  if (task.follow) {
    // A followed task is observed through the daemon, not through a process: say
    // so instead of implying that a pid proves the turn is working.
    observationSource = `daemon session (followed, ${task.follow.lastPollAt ? `last poll ${task.follow.lastPollAt}` : 'no poll yet'})`;
  } else if (pid) {
    observationSource += isAlive ? ` (process alive: ${pid})` : ' (process not running)';
  }

  const formatIso = (value, fallback) => {
    if (!value) return fallback;
    const parsed = new Date(value);
    return Number.isNaN(parsed.getTime()) ? fallback : parsed.toISOString();
  };

  return {
    taskId: task.id,
    sessionState,
    cause: cause || '-',
    stateSince: formatIso(stateSince, '[unknown time]'),
    lastProgressAt: formatIso(lastProgressAt, '-'),
    elapsed: formatDuration(elapsedMs),
    elapsedMs,
    observationSource,
    // Follow facts ride with the observation instead of being inferred by a
    // reader from a pid that no longer exists.
    follow: task.follow
      ? {
        active: task.follow.active === true,
        reason: task.follow.reason ?? null,
        since: formatIso(task.follow.since, '[unknown time]'),
        deadlineAt: formatIso(task.follow.deadlineAt, '-'),
        lastPollAt: formatIso(task.follow.lastPollAt, 'never'),
        polls: Number(task.follow.polls) || 0,
        resultSource: task.follow.resultSource ?? null,
      }
      : null,
    currentTime: new Date().toISOString(),
  };
}

function formatSessionFooter(details) {
  return [
    '--- Session Observability ---',
    `Task ID:            ${details.taskId}`,
    `Session State:      ${details.sessionState}`,
    `Cause:              ${details.cause}`,
    `State Since:        ${details.stateSince}`,
    `Last Progress:      ${details.lastProgressAt}`,
    `Elapsed:            ${details.elapsed}`,
    `Observation Source: ${details.observationSource}`,
    ...(details.follow
      ? [`Follow:             ${details.follow.active ? 'active' : 'ended'}`
        + ` since ${details.follow.since}`
        + `, deadline ${details.follow.deadlineAt}`
        + `, polls ${details.follow.polls}`
        + `, last poll ${details.follow.lastPollAt}`
        + `${details.follow.resultSource ? `, result from ${details.follow.resultSource}` : ''}`]
      : []),
    `Current Time:       ${details.currentTime}`,
    '-----------------------------',
  ].join('\n');
}

// One run's read view. `status` repairs a run whose supervisor is gone (that is
// the only writer left) and never mutates a live run.
function statusSnapshot(runDir) {
  const manifest = loadManifest(runDir);
  if (manifest.status === 'running' && !processIsAlive(manifest.supervisorPid)) {
    manifest.status = 'stale';
    manifest.staleReason = 'Supervisor process is not running.';
  }
  const snapshot = queueSnapshot(manifest);
  for (const task of Object.values(manifest.tasks || {})) {
    const details = resolveSessionDetails(task, manifest);
    task.sessionState = details.sessionState;
    task.sessionCause = details.cause;
    task.lastProgressAt = details.lastProgressAt !== '-' ? details.lastProgressAt : null;
    task.stateSince = details.stateSince !== '[unknown time]' ? details.stateSince : null;
    // A queued task always carries its position, the live counts, the reason
    // it is waiting, and whether it already exceeded the stall threshold.
    const queue = task.status === 'queued' ? describeQueuedTask(manifest, task.id) : null;
    if (queue) task.queue = queue;
    // Progress age is recomputed on read: a caller that never watched still
    // sees a silent turn instead of an apparently busy one.
    task.progress = describeProgress(manifest, task);
    // The visible result of this task, decided once for every reader: a followed
    // task keeps the verdict it earned from the durable session, and a worker
    // artifact that disagrees with it is reported as `later-result` instead of
    // replacing it.
    applyVisibleResult(task, readResultDigest(task.resultPath));
  }
  manifest.active = snapshot.active;
  manifest.queuedStallMs = queuedStallThreshold(manifest);
  manifest.progressStallMs = progressThresholdMs(manifest);
  manifest.queue = {
    active: snapshot.active,
    maxConcurrency: snapshot.maxConcurrency,
    queued: snapshot.queued.map((entry) => ({
      id: entry.id,
      ...describeQueuedTask(manifest, entry.id),
    })),
  };
  // A run whose supervisor is alive but has nothing left to run is idle, not
  // running: the distinction is what tells a coordinator no progress is coming.
  // A followed task is still in flight even though it holds no worker slot, so a
  // run that only follows is never reported as idle.
  const following = Object.values(manifest.tasks || {})
    .some((task) => task?.follow?.active === true);
  manifest.idle = manifest.status === 'running'
    && snapshot.active === 0
    && snapshot.queued.length === 0
    && !following
    && !manifest.closed;
  return manifest;
}

/**
 * Retry facts for one task, computed the same way the worker does so a caller
 * that only reads the manifest sees the budget, the attempts already spent on
 * the current block, and the next deadline.
 */
function retryFacts(manifest, task) {
  const policy = manifest?.autoRetry ?? {};
  const episode = Number.isInteger(task?.retryEpisode) ? task.retryEpisode : 0;
  const entries = Array.isArray(task?.retryAttempts) ? task.retryAttempts : [];
  const attempts = entries.filter((entry) => entry && entry.episode === episode);
  return {
    enabled: task?.autoRetry == null ? policy.enabled === true : task.autoRetry === true,
    attempts: attempts.length,
    maxAttempts: Number.isInteger(policy.maxAttempts) ? policy.maxAttempts : DEFAULT_AUTO_RETRY_MAX_ATTEMPTS,
    nextRetryAt: task?.nextRetryAt ?? null,
    exhausted: Boolean(task?.retryExhaustedAt),
    lastResult: attempts.at(-1)?.result ?? null,
    lastExitCode: attempts.at(-1)?.exitCode ?? null,
    launchAttempts: Array.isArray(task?.launchRetries) ? task.launchRetries.length : 0,
    launchMaxAttempts: Number.isInteger(policy.launchMaxAttempts)
      ? policy.launchMaxAttempts
      : DEFAULT_LAUNCH_RETRY_MAX_ATTEMPTS,
  };
}

function briefTaskLine(manifest, task) {
  const details = resolveSessionDetails(task, manifest);
  const progress = task.progress ?? describeProgress(manifest, task);
  const parts = [task.id, task.status, `elapsed ${details.elapsed}`];
  // Progress age is only meaningful while a turn is live; a terminal task
  // showing "progress 3s ago" reads like activity that is not happening.
  const liveTask = ['running', 'resuming'].includes(task.status);
  parts.push(`progress ${!liveTask || progress.silentForMs == null
    ? '-'
    : `${formatShortDuration(progress.silentForMs)} ago`}`);
  if (task.status === 'queued' && task.queue) {
    parts.push(`queue #${task.queue.position}/${task.queue.queuedTotal} ${task.queue.reason}`);
  }
  if (progress.stalled) parts.push('PROGRESS_STALL');
  if (task.queueStall) parts.push('QUEUED_STALL');
  if ((task.attempt ?? 1) > 1) parts.push(`attempt ${task.attempt}`);
  // Retry facts belong on the task line: a blocked task without them looks like
  // a permanent stop, and an exhausted one looks identical to a fresh block.
  const retry = retryFacts(manifest, task);
  if (retry.attempts > 0) parts.push(`retries ${retry.attempts}/${retry.maxAttempts}`);
  if (retry.nextRetryAt) parts.push(`next-retry ${retry.nextRetryAt}`);
  if (retry.exhausted) parts.push('RETRY_EXHAUSTED');
  if (retry.launchAttempts > 0) parts.push(`launch-retries ${retry.launchAttempts}`);
  // The daemon's own retry counters. While one is pending the task is live, so
  // the line names the attempt the runtime is running instead of leaving a bare
  // `retrying` status that a reader has to interpret.
  if (task.daemonRetry) {
    parts.push(`daemon-retry ${task.daemonRetry.attempt ?? '?'}/${task.daemonRetry.budget ?? '?'}`);
  } else if (task.status === 'retrying') {
    parts.push('daemon-retry');
  }
  const result = taskResultForView(task);
  if (TERMINAL_STATUSES.has(task.status) || result) {
    parts.push(`result ${result?.status ?? task.status}`);
    if (result?.prUrl) parts.push(`pr ${result.prUrl}`);
    if (result?.headSha) parts.push(`sha ${result.headSha}`);
    if (result?.branch) parts.push(`branch ${result.branch}`);
    if (result?.summary) parts.push(`summary ${result.summary}`);
  }
  // A followed task reads like any other live task, so the line says where the
  // observation comes from and when the next probe is due.
  if (task.follow) {
    parts.push(`followed ${task.follow.active ? 'since' : 'until'} ${task.follow.since ?? '-'}`);
    parts.push(`polls ${Number(task.follow.polls) || 0}`);
    if (task.follow.active && task.follow.deadlineAt) parts.push(`follow-deadline ${task.follow.deadlineAt}`);
    if (task.follow.resultSource) parts.push(`result-source ${task.follow.resultSource}`);
  }
  if (task.laterResult) parts.push(`later-result ${task.laterResult.status}`);
  if (task.error) parts.push(`error ${String(task.error).slice(0, 160)}`);
  return `  ${parts.join('  ')}`;
}

function briefRunHeader(runDir, manifest) {
  const snapshot = queueSnapshot(manifest);
  const closedIndicator = manifest.closed ? ' (closed)' : '';
  const idleIndicator = manifest.idle ? ' (idle)' : '';
  return `RUN ${runDir}  ${manifest.status}${closedIndicator}${idleIndicator}`
    + `  active=${snapshot.active}/${snapshot.maxConcurrency ?? '?'}`
    + `  queued=${snapshot.queued.length}`
    + `  tasks=${Object.keys(manifest.tasks || {}).length}`
    + `  seq=${manifest.seq}`
    + `  supervisor=${manifest.supervisorPid}`;
}

function briefView(runDir, manifest) {
  return {
    runDir,
    status: manifest.status,
    closed: manifest.closed === true,
    idle: manifest.idle === true,
    active: manifest.active,
    maxConcurrency: manifest.maxConcurrency ?? null,
    seq: manifest.seq,
    supervisorPid: manifest.supervisorPid ?? null,
    tasks: Object.values(manifest.tasks || {}).map((task) => {
      const details = resolveSessionDetails(task, manifest);
      const progress = task.progress ?? describeProgress(manifest, task);
      const result = taskResultForView(task);
      return {
        id: task.id,
        status: task.status,
        attempt: task.attempt ?? 1,
        elapsed: details.elapsed,
        progressAgeMs: progress.silentForMs,
        progressStalled: progress.stalled,
        queue: task.queue
          ? { position: task.queue.position, queuedTotal: task.queue.queuedTotal, reason: task.queue.reason }
          : null,
        resultStatus: result?.status ?? (TERMINAL_STATUSES.has(task.status) ? task.status : null),
        resultPath: result?.path ?? task.resultPath ?? null,
        branch: result?.branch ?? null,
        headSha: result?.headSha ?? null,
        prUrl: result?.prUrl ?? null,
        summary: result?.summary ?? null,
        follow: task.follow
          ? {
            active: task.follow.active === true,
            reason: task.follow.reason ?? null,
            since: task.follow.since ?? null,
            deadlineAt: task.follow.deadlineAt ?? null,
            pollMs: task.follow.pollMs ?? null,
            polls: Number(task.follow.polls) || 0,
            lastPollAt: task.follow.lastPollAt ?? null,
            lastSnapshot: task.follow.lastSnapshot ?? null,
            resultSource: task.follow.resultSource ?? null,
            note: task.note ?? null,
          }
          : null,
        retry: retryFacts(manifest, task),
        laterResult: task.laterResult
          ? { status: task.laterResult.status, path: task.laterResult.path, startedAt: task.laterResult.startedAt ?? null }
          : null,
        error: task.error ?? null,
      };
    }),
  };
}

export function statusCommand(options) {
  const runDirs = [...new Set(options.runs.map((entry) => resolve(entry)))];
  if (!runDirs.length) fail('status requires --run');
  const brief = options.brief === true;
  const snapshots = runDirs.map((runDir) => {
    reconcileRun(runDir);
    return { runDir, manifest: statusSnapshot(runDir) };
  });

  if (brief) {
    if (options.json) {
      const payload = {
        version: 'delegate-status-brief.v1',
        runs: snapshots.map(({ runDir, manifest }) => briefView(runDir, manifest)),
      };
      process.stdout.write(`${JSON.stringify(payload, null, 2)}\n`);
      return;
    }
    for (const { runDir, manifest } of snapshots) {
      process.stdout.write(`${briefRunHeader(runDir, manifest)}\n`);
      for (const task of Object.values(manifest.tasks || {})) {
        process.stdout.write(`${briefTaskLine(manifest, task)}\n`);
      }
    }
    return;
  }

  if (options.json) {
    if (snapshots.length === 1) {
      // A single run keeps its manifest shape, which existing callers parse.
      process.stdout.write(`${JSON.stringify(snapshots[0].manifest, null, 2)}\n`);
      return;
    }
    process.stdout.write(`${JSON.stringify({
      version: 'delegate-status.v1',
      runs: snapshots.map(({ runDir, manifest }) => ({ runDir, ...manifest })),
    }, null, 2)}\n`);
    return;
  }

  snapshots.forEach(({ runDir, manifest }, index) => {
    if (index > 0) process.stdout.write('\n');
    if (snapshots.length > 1) process.stdout.write(`${runDir}\n`);
    printVerboseStatus(manifest, options, snapshots.length);
  });
}

function printVerboseStatus(manifest, options, runCount = 1) {
  const closedIndicator = manifest.closed ? ' (closed)' : '';
  const idleIndicator = manifest.idle ? ' (idle)' : '';
  process.stdout.write(`RUN ${manifest.status}${closedIndicator}${idleIndicator}  seq=${manifest.seq}  supervisor=${manifest.supervisorPid}\n`);
  process.stdout.write('TASK\tIMPLEMENTER\tSTATUS\tPID\tWORKSPACE\n');
  for (const task of Object.values(manifest.tasks)) {
    process.stdout.write(`${task.id}\t${task.implementer}\t${task.status}\t${task.pid ?? '-'}\t${task.workspace}\n`);
  }

  const snapshot = queueSnapshot(manifest);
  if (snapshot.queued.length > 0) {
    process.stdout.write(
      `\nQUEUE active=${snapshot.active}/${snapshot.maxConcurrency ?? '?'}`
      + `  queued=${snapshot.queued.length}  stall-after=${formatShortDuration(queuedStallThreshold(manifest))}\n`,
    );
    for (const entry of snapshot.queued) {
      const description = describeQueuedTask(manifest, entry.id);
      process.stdout.write(
        `  ${entry.id}\tposition ${description.position} of ${description.queuedTotal}`
        + `\tqueued ${formatShortDuration(description.queuedForMs)}`
        + `\t${description.reason}: ${description.reasonText}`
        + `${description.stalled ? '  QUEUED_STALL' : ''}\n`,
      );
    }
  }

  const stalled = Object.values(manifest.tasks).filter((task) => task.progress?.stalled);
  if (stalled.length > 0) {
    process.stdout.write(
      `\nPROGRESS silent past ${formatShortDuration(progressThresholdMs(manifest))}:\n`,
    );
    for (const task of stalled) {
      process.stdout.write(
        `  ${task.id}\tno progress for ${formatShortDuration(task.progress.silentForMs)}`
        + `\t(last: ${task.progress.lastProgressAt ?? 'unknown'})\n`,
      );
    }
  }

  // Severed transport is its own section: a task whose worker exited is still
  // in flight, and an operator reading status must not mistake the missing pid
  // for a missing turn.
  const followed = Object.values(manifest.tasks).filter((task) => task.follow);
  if (followed.length > 0) {
    process.stdout.write('\nFOLLOW (worker exited, daemon turn in flight):\n');
    for (const task of followed) {
      const follow = task.follow;
      process.stdout.write(
        `  ${task.id}\t${follow.active ? 'following' : 'ended'}`
        + `\tsince ${follow.since ?? '-'}`
        + `\tdeadline ${follow.active ? follow.deadlineAt ?? '-' : '-'}`
        + `\tpolls ${Number(follow.polls) || 0}`
        + `\tlast poll ${follow.lastPollAt ?? 'never'}`
        + `${follow.resultSource ? `\tresult from ${follow.resultSource}` : ''}`
        + `${follow.lastSnapshot ? `\tlast seen ${follow.lastSnapshot.kind}` : ''}\n`,
      );
    }
  }

  const target = options.task && runCount === 1 ? requireTask(manifest, options.task) : null;
  if (target) {
    const details = resolveSessionDetails(target, manifest);
    process.stdout.write(`\n${formatSessionFooter(details)}\n`);
  } else if (runCount === 1 && !options.task) {
    for (const task of Object.values(manifest.tasks)) {
      const details = resolveSessionDetails(task, manifest);
      process.stdout.write(`\n${formatSessionFooter(details)}\n`);
    }
  }
}

export function inspectCommand(options) {
  const runDir = singleRun(options, 'inspect');
  if (!options.task) fail('inspect requires --task <id>');
  const manifest = loadManifest(runDir);
  const task = requireTask(manifest, options.task);
  let result = null;
  if (task.resultPath && existsSync(task.resultPath)) {
    result = readJson(task.resultPath, `result for ${task.id}`);
  }
  process.stdout.write(`${JSON.stringify({ task, result }, null, 2)}\n`);
}

function readLastLines(path, count) {
  if (!existsSync(path)) return '';
  const lines = readFileSync(path, 'utf8').split(/\r?\n/);
  if (lines.at(-1) === '') lines.pop();
  const observed = lines.slice(-count).map((line) => formatTimelineLine(line));
  return `${observed.join('\n')}${observed.length ? '\n' : ''}`;
}

function formatObservedLogContent(content, receiptTime) {
  const lines = content.split(/\r?\n/);
  const trailingNewline = lines.at(-1) === '';
  if (trailingNewline) lines.pop();
  const observed = lines.map((line) => formatTimelineLine(line, receiptTime));
  return `${observed.join('\n')}${trailingNewline && observed.length ? '\n' : ''}`;
}

function followFiles(entries, options = {}) {
  const offsets = new Map();
  const watchers = [];
  const drain = (entry) => {
    if (!entry.path || !existsSync(entry.path)) return;
    const size = statSync(entry.path).size;
    const offset = offsets.get(entry.path) ?? 0;
    if (size < offset) offsets.set(entry.path, 0);
    const nextOffset = offsets.get(entry.path) ?? 0;
    if (size === nextOffset) return;
    const content = readFileSync(entry.path, 'utf8').slice(nextOffset);
    offsets.set(entry.path, size);
    const now = new Date().toISOString();
    entry.consume(content, now);
  };

  const runDir = options.runDir || null;
  const observerFile = runDir ? join(runDir, 'observers', `${process.pid}.json`) : null;
  const observerRecord = {
    pid: process.pid,
    command: options.command || 'follow',
    taskId: options.taskId || null,
    startedAt: new Date().toISOString(),
    endedAt: null,
    status: 'active',
    cancellationSignal: null,
  };

  if (observerFile) {
    try {
      mkdirSync(dirname(observerFile), { recursive: true });
      writeJsonAtomic(observerFile, observerRecord);
    } catch {}
  }

  for (const entry of entries) {
    if (entry.path && existsSync(entry.path)) offsets.set(entry.path, statSync(entry.path).size);
  }
  const directories = new Map();
  for (const entry of entries) {
    if (!entry.path) continue;
    const dir = dirname(entry.path);
    if (!existsSync(dir)) continue;
    if (!directories.has(dir)) directories.set(dir, []);
    directories.get(dir).push(entry);
  }
  for (const [dir, dirEntries] of directories) {
    const watcher = watch(dir, (_event, filename) => {
      for (const entry of dirEntries) {
        if (!filename || String(filename) === basename(entry.path)) drain(entry);
      }
    });
    watchers.push(watcher);
  }
  for (const entry of entries) drain(entry);

  const close = (signal = null) => {
    const endedAt = new Date().toISOString();
    for (const watcher of watchers) watcher.close();
    if (observerFile) {
      try {
        observerRecord.endedAt = endedAt;
        observerRecord.status = signal ? 'cancelled' : 'completed';
        observerRecord.cancellationSignal = signal;
        writeJsonAtomic(observerFile, observerRecord);
      } catch {}
    }
    if (signal) {
      process.stderr.write(`[observer cancelled by ${signal} at ${endedAt}]\n`);
    }
    process.exit(0);
  };
  process.on('SIGINT', () => close('SIGINT'));
  process.on('SIGTERM', () => close('SIGTERM'));
  if (watchers.length === 0) fail('no observable files exist yet');
}

function formatTimelineLine(line, receiptTime = null) {
  if (!line || !line.trim()) return null;
  let event;
  let isJson = true;
  try {
    event = JSON.parse(line);
  } catch {
    isJson = false;
  }

  let sourceTime = null;
  if (isJson) {
    const rawTime = event.timestamp ?? event.at ?? null;
    if (rawTime != null) {
      try {
        const d = new Date(rawTime);
        if (!isNaN(d.getTime())) sourceTime = d.toISOString();
      } catch {}
    }
  }

  const effectiveReceipt = receiptTime || (isJson ? (event.received_at || event.receivedAt || null) : null);
  let receiptIso = null;
  if (effectiveReceipt) {
    try {
      const d = new Date(effectiveReceipt);
      if (!isNaN(d.getTime())) receiptIso = d.toISOString();
    } catch {}
  }

  let timeLabel;
  if (sourceTime) {
    timeLabel = receiptIso ? `${sourceTime} (received: ${receiptIso})` : sourceTime;
  } else {
    timeLabel = receiptIso ? `[unknown time] (received: ${receiptIso})` : '[unknown time]';
  }

  if (!isJson) {
    const leadingIso = line.match(/^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2}))(?:\s+|$)(.*)$/);
    if (leadingIso) {
      const parsed = new Date(leadingIso[1]);
      if (!Number.isNaN(parsed.getTime())) {
        const sourceLabel = parsed.toISOString();
        const label = receiptIso ? `${sourceLabel} (received: ${receiptIso})` : sourceLabel;
        return `${label}  ${leadingIso[2]}`.trimEnd();
      }
    }
    return `${timeLabel}  ${line}`;
  }

  if (event.taskId && event.to) {
    const causeStr = event.cause ? ` (${event.cause})` : '';
    return `${timeLabel}  ${event.taskId}  ${event.from} -> ${event.to}${causeStr}`;
  }

  const type = event.type || event.part?.type || 'event';
  if (type === 'tool_use' || event.part?.type === 'tool') {
    const part = event.part || {};
    const state = part.state || {};
    const input = state.input || {};
    const detail = input.filePath || input.path || input.pattern || input.command || '';
    return `${timeLabel}  tool:${part.tool || 'unknown'}  ${state.status || ''}  ${String(detail).slice(0, 240)}`.trimEnd();
  }
  if (type === 'text') {
    return `${timeLabel}  text  ${String(event.part?.text || event.text || '').replace(/\s+/g, ' ').slice(0, 500)}`;
  }
  if (type === 'notice') {
    const code = event.code || event.data?.code || 'notice';
    const message = event.message || event.data?.message || '';
    return `${timeLabel}  notice:${code}  ${message}`.trimEnd();
  }
  if (type === 'retrying') {
    const attempt = event.data?.retry_attempt ?? event.data?.retryAttempt;
    const budget = event.data?.retry_budget ?? event.data?.retryBudget;
    const counters = attempt == null && budget == null ? '' : ` (${attempt ?? '?'}/${budget ?? '?'})`;
    const message = event.message || event.data?.message || '';
    return `${timeLabel}  retrying${counters}  ${message}`.trimEnd();
  }
  if (type === 'blocked' || type === 'waiting') {
    const cause = event.cause || event.data?.cause || event.code || event.data?.code || 'unknown';
    const message = event.message || event.data?.message || '';
    return `${timeLabel}  ${type} (${cause})  ${message}`.trimEnd();
  }
  if (type === 'resumed' || type === 'resuming') {
    return `${timeLabel}  resuming`.trimEnd();
  }
  if (type === 'needs_input' || type === 'needs_permission') {
    const tool = event.data?.tool_name ? ` tool=${event.data.tool_name}` : '';
    return `${timeLabel}  ${type}${tool}`.trimEnd();
  }
  const reason = event.part?.reason ? ` reason=${event.part.reason}` : '';
  return `${timeLabel}  ${type}${reason}`.trimEnd();
}

export function timelineCommand(options) {
  const runDir = singleRun(options, 'timeline');
  if (!options.task) fail('timeline requires --task <id>');
  const manifest = loadManifest(runDir);
  const task = requireTask(manifest, options.task);
  const journalPath = runPaths(runDir).journal;

  const printSupervisorEvents = (content, receiptTime = null) => {
    for (const line of content.split(/\r?\n/)) {
      if (!line.trim()) continue;
      try {
        const event = JSON.parse(line);
        if (event.taskId === task.id) process.stdout.write(`${formatTimelineLine(line, receiptTime)}\n`);
      } catch {
        // Ignore malformed partial lines; atomic append records are newline terminated.
      }
    }
  };
  const printTaskEvents = (content, receiptTime = null) => {
    for (const line of content.split(/\r?\n/)) {
      if (!line.trim()) continue;
      process.stdout.write(`${formatTimelineLine(line, receiptTime)}\n`);
    }
  };

  if (existsSync(journalPath)) printSupervisorEvents(readFileSync(journalPath, 'utf8'));
  if (task.timelinePath && existsSync(task.timelinePath)) {
    printTaskEvents(readFileSync(task.timelinePath, 'utf8'));
  }
  const details = resolveSessionDetails(task, manifest);
  process.stdout.write(`\n${formatSessionFooter(details)}\n`);

  if (options.follow) {
    followFiles([
      { path: journalPath, consume: printSupervisorEvents },
      { path: task.timelinePath, consume: printTaskEvents },
    ], { runDir, command: 'timeline', taskId: task.id });
  }
}

export function logsCommand(options) {
  const runDir = singleRun(options, 'logs');
  if (!options.task) fail('logs requires --task <id>');
  const manifest = loadManifest(runDir);
  const task = requireTask(manifest, options.task);
  const stream = options.stream || 'both';
  if (!['stdout', 'stderr', 'both'].includes(stream)) fail('--stream must be stdout, stderr, or both');
  const tail = options.tail == null ? 100 : Number(options.tail);
  if (!Number.isInteger(tail) || tail < 1) fail('--tail must be a positive integer');
  const entries = [];
  if (stream === 'stdout' || stream === 'both') entries.push({ label: 'stdout', path: task.stdoutPath });
  if (stream === 'stderr' || stream === 'both') entries.push({ label: 'stderr', path: task.stderrPath });
  for (const entry of entries) {
    process.stdout.write(`--- ${entry.label} ---\n${readLastLines(entry.path, tail)}`);
  }
  const details = resolveSessionDetails(task, manifest);
  process.stdout.write(`\n${formatSessionFooter(details)}\n`);

  if (options.follow) {
    followFiles(entries.map((entry) => ({
      path: entry.path,
      consume: (content, receiptTime) => process.stdout.write(
        `[${entry.label}] ${formatObservedLogContent(content, receiptTime)}`,
      ),
    })), { runDir, command: 'logs', taskId: task.id });
  }
}

function posixQuote(value) {
  return `'${String(value).replaceAll("'", `'"'"'`)}'`;
}

export function viewCommand(options) {
  const runDir = singleRun(options, 'view');
  if (!options.task) fail('view requires --task <id>');
  const args = [SCRIPT_PATH, 'timeline', '--run', runDir, '--task', options.task, '--follow'];
  if (process.platform === 'darwin') {
    const command = [process.execPath, ...args].map(posixQuote).join(' ');
    const script = `tell application "Terminal"\nactivate\ndo script ${JSON.stringify(command)}\nend tell`;
    const child = spawn('osascript', ['-e', script], { detached: true, stdio: 'ignore' });
    child.unref();
  } else if (process.platform === 'win32') {
    const viewerPath = join(runDir, `view-${options.task}.cmd`);
    const command = [process.execPath, ...args].map(windowsBatchQuote).join(' ');
    writeFileSync(
      viewerPath,
      [
        '@echo off',
        `title Delegate Task Timeline - ${options.task}`,
        command,
        'echo.',
        'echo Timeline viewer exited with code %ERRORLEVEL%.',
        'pause',
        '',
      ].join('\r\n'),
      'utf8',
    );
    try {
      launchThroughWindowsExplorer(viewerPath);
    } catch (error) {
      fail(error.message, 1);
    }
  } else {
    const candidates = [
      ['x-terminal-emulator', ['-e', process.execPath, ...args]],
      ['gnome-terminal', ['--', process.execPath, ...args]],
      ['konsole', ['-e', process.execPath, ...args]],
      ['xfce4-terminal', ['-e', [process.execPath, ...args].map(posixQuote).join(' ')]],
    ];
    let launched = false;
    for (const [command, terminalArgs] of candidates) {
      const available = spawnSync('sh', ['-c', `command -v ${posixQuote(command)}`], { stdio: 'ignore' });
      if (available.status !== 0) continue;
      const terminal = spawn(command, terminalArgs, { detached: true, stdio: 'ignore' });
      terminal.unref();
      launched = true;
      break;
    }
    if (!launched) fail('no supported terminal launcher found');
  }
  process.stdout.write(`${JSON.stringify({ opened: true, taskId: options.task, runDir })}\n`);
}
