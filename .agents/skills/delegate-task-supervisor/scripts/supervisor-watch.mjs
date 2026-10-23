// The durable watch loop and the run reconciliation behind it.
//
// `watch` is the coordinator interface for several runs at once: it persists
// the last handled sequence per run in a cursor file, replays what a re-invoked
// orchestrator missed, and prints one line per actionable event.
//
// `reconcileRun` lives here because it answers the same question one step
// earlier: a worker that died without journaling, or a session that settled
// after its worker exited, is turned into manifest state before either `watch`
// or `status` reports it. `status` imports it rather than keeping a copy.
//
// The wake vocabulary itself is shared with `watch-once.mjs` through
// `supervisor-events.mjs`; this module only decides when to read the journal.

import { appendFileSync, existsSync, readFileSync, watch } from 'node:fs';
import { basename, dirname, join, resolve } from 'node:path';

import {
  applyVisibleResult,
  fail,
  formatDuration,
  parseIsoMillis,
  processIsAlive,
  readResultDigest,
  resultBelongsToTask,
  runPaths,
  secondsOption,
  taskResultForView,
  writeJsonAtomic,
} from './supervisor-core.mjs';
import { TERMINAL_STATUSES, isActionableEvent } from './supervisor-events.mjs';

const WATCH_EVENT_VERSION = 'delegate-watch-event.v1';
const CURSOR_VERSION = 'delegate-watch-cursor.v1';
// Reading the whole journal is deliberate: run journals are small (one record
// per state change), and a single read gives the watcher a consistent snapshot
// instead of a race between separate seeks.
function readJournalEvents(journalPath) {
  if (!existsSync(journalPath)) return [];
  let content;
  try {
    content = readFileSync(journalPath, 'utf8');
  } catch {
    return [];
  }
  const events = [];
  for (const line of content.split(/\r?\n/)) {
    if (!line.trim()) continue;
    let event;
    try {
      event = JSON.parse(line);
    } catch {
      // A partially flushed trailing line is re-read on the next scan.
      continue;
    }
    if (event && Number.isInteger(event.seq)) events.push(event);
  }
  return events;
}

function readManifestQuiet(runDir) {
  const path = runPaths(runDir).manifest;
  if (!existsSync(path)) return null;
  try {
    return JSON.parse(readFileSync(path, 'utf8'));
  } catch {
    return null;
  }
}

function loadCursor(cursorPath) {
  if (!existsSync(cursorPath)) return { version: CURSOR_VERSION, updatedAt: null, runs: {} };
  let value;
  try {
    value = JSON.parse(readFileSync(cursorPath, 'utf8'));
  } catch (error) {
    fail(`cannot read watch cursor ${cursorPath}: ${error.message}`);
  }
  if (value?.version !== CURSOR_VERSION || value.runs === null || typeof value.runs !== 'object') {
    fail(`unsupported watch cursor at ${cursorPath}`);
  }
  return value;
}

function cursorSeq(cursor, runDir) {
  const seq = Number(cursor.runs?.[runDir]?.seq);
  return Number.isInteger(seq) && seq >= 0 ? seq : 0;
}

// Cursor writes are atomic (temp file + rename), so a watcher that is killed
// mid-write can never leave a truncated cursor that replays or skips events.
function saveCursor(cursorPath, cursor) {
  cursor.updatedAt = new Date().toISOString();
  writeJsonAtomic(cursorPath, cursor);
}

function runIsFinished(runDir) {
  const manifest = readManifestQuiet(runDir);
  if (!manifest) return true;
  if (['completed', 'stale', 'failed'].includes(manifest.status)) return true;
  if (manifest.closed) {
    const tasks = Object.values(manifest.tasks || {});
    if (tasks.every((task) => TERMINAL_STATUSES.has(task?.status))) return true;
  }
  return false;
}

/**
 * Repairs a run whose supervisor is gone.
 *
 * A dead supervisor leaves tasks parked in a live-looking state forever, which
 * is how a coordinator ends up believing five sessions are running when only
 * four are. Nothing else can write this run, so the repair is performed here
 * (and journaled exactly like a worker transition). A live run is never
 * touched: its worker owns task state.
 */
export function reconcileRun(runDir) {
  const paths = runPaths(runDir);
  const manifest = readManifestQuiet(runDir);
  if (!manifest) return { runDir, manifest: null, changed: false, lost: [], recovered: [], orphaned: [] };
  let changed = false;
  let supervisorDied = false;
  if (manifest.status === 'running' && !processIsAlive(manifest.supervisorPid)) {
    supervisorDied = true;
    manifest.status = 'stale';
    manifest.staleReason = 'Supervisor process is not running.';
    manifest.supervisorDeadAt = new Date().toISOString();
    changed = true;
  }
  const outcome = { runDir, manifest, changed, lost: [], recovered: [], orphaned: [] };
  if (manifest.status !== 'stale') return outcome;

  let seq = Number.isInteger(manifest.seq) ? manifest.seq : 0;
  const records = [];
  // A dead supervisor with work still non-terminal is its own, actionable fact:
  // nothing will ever advance those tasks again. It is reported once, at the
  // moment the run is repaired, and it is deliberately not a `progress_stall` —
  // that one only says a single task went quiet while its supervisor is alive.
  if (supervisorDied && manifest.supervisorDeadNoticed !== true) {
    const nonTerminal = Object.entries(manifest.tasks || {})
      .filter(([, task]) => task && !TERMINAL_STATUSES.has(task.status))
      .map(([id]) => id);
    if (nonTerminal.length > 0) {
      seq += 1;
      records.push({
        seq,
        taskId: null,
        implementer: null,
        workspace: null,
        from: 'running',
        to: 'supervisor_dead',
        at: manifest.supervisorDeadAt,
        kind: 'supervisor_dead',
        supervisorPid: manifest.supervisorPid ?? null,
        nonTerminal,
      });
      manifest.supervisorDeadNoticed = true;
    }
  }
  for (const [id, task] of Object.entries(manifest.tasks || {})) {
    if (!task) continue;
    if (TERMINAL_STATUSES.has(task.status)) {
      // A completion that landed after the supervisor died must still be
      // reported: an already-repaired `failed/worker_lost` task upgrades to the
      // task's own terminal artifact instead of staying wrong forever.
      if (task.cause === 'worker_lost') {
        const late = readResultDigest(task.resultPath);
        if (late?.status && TERMINAL_STATUSES.has(late.status) && resultBelongsToTask(task, late)) {
          seq += 1;
          task.status = late.status;
          task.cause = 'result_recorded_after_exit';
          task.error = null;
          task.result = late;
          task.laterResult = null;
          records.push({
            seq,
            taskId: id,
            implementer: task.implementer ?? null,
            workspace: task.workspace ?? null,
            from: 'failed',
            to: late.status,
            at: new Date().toISOString(),
            kind: 'recovered',
            cause: 'result_recorded_after_exit',
            recovered: true,
          });
          outcome.recovered.push(id);
          changed = true;
        }
      } else {
        // A terminal task keeps its own outcome. If the artifact on its path was
        // produced after it settled (a later attempt reused the same --out-dir),
        // it is reported as `later-result` for triage instead of being adopted or
        // printed as this task's result. A followed task is the same case with a
        // stronger reason: its verdict came from the durable session.
        if (applyVisibleResult(task, readResultDigest(task.resultPath)) === 'later') changed = true;
      }
      continue;
    }
    if (['queued', 'held'].includes(task.status)) continue;
    const from = task.status;
    // A followed task has no worker to lose: the supervisor died while polling a
    // daemon-owned turn, so nothing here can observe that turn again. A terminal
    // artifact written during the follow is still adopted; otherwise the honest
    // report is that the outcome is unknown, not that the worker vanished.
    if (task.follow?.active === true) {
      const lateFollow = readResultDigest(task.resultPath);
      const adoptFollow = lateFollow?.status && TERMINAL_STATUSES.has(lateFollow.status)
        && resultBelongsToTask(task, lateFollow);
      const followStatus = adoptFollow ? lateFollow.status : 'failed';
      const followFinishedAt = new Date().toISOString();
      Object.assign(task, {
        status: followStatus,
        finishedAt: followFinishedAt,
        stateSince: followFinishedAt,
        cause: adoptFollow ? 'result_recorded_after_exit' : 'follow_abandoned',
        recovered: true,
        follow: { ...task.follow, active: false, endedAt: followFinishedAt },
        ...(adoptFollow ? { result: lateFollow } : {}),
      });
      if (!adoptFollow) {
        task.error = 'the supervisor died while following the daemon session; the turn outcome is unknown';
      }
      seq += 1;
      records.push({
        seq,
        taskId: id,
        implementer: task.implementer ?? null,
        workspace: task.workspace ?? null,
        from,
        to: followStatus,
        at: followFinishedAt,
        kind: adoptFollow ? 'recovered' : 'follow_abandoned',
        cause: task.cause,
        recovered: true,
      });
      if (adoptFollow) outcome.recovered.push(id);
      else outcome.lost.push(id);
      changed = true;
      continue;
    }
    // A process that is still alive is still running, even though its
    // supervisor is gone. Failing it would be as wrong as claiming it is
    // healthy, so the run reports it as orphaned and journals that once; the
    // next read after the process exits records the real `worker_lost` outcome.
    if (processIsAlive(task.pid)) {
      const orphanFields = {
        orphaned: true,
        orphanPid: task.pid,
        orphanNote: 'process outlived its supervisor and is unmanaged',
        orphanSince: task.orphanSince ?? new Date().toISOString(),
      };
      const needsNotice = task.orphanNoticed !== true;
      Object.assign(task, orphanFields, needsNotice ? { orphanNoticed: true } : {});
      if (needsNotice) {
        seq += 1;
        records.push({
          seq,
          taskId: id,
          implementer: task.implementer ?? null,
          workspace: task.workspace ?? null,
          from,
          to: from,
          at: new Date().toISOString(),
          kind: 'worker_orphaned',
          cause: 'supervisor_stale',
          orphanPid: task.pid,
        });
      }
      outcome.orphaned.push(id);
      changed = true;
      continue;
    }
    const digest = readResultDigest(task.resultPath);
    const terminalFromResult = digest?.status && TERMINAL_STATUSES.has(digest.status)
      && resultBelongsToTask(task, digest);
    const status = terminalFromResult ? digest.status : 'failed';
    const cause = terminalFromResult ? 'result_recorded_after_exit' : 'worker_lost';
    const finishedAt = new Date().toISOString();
    Object.assign(task, {
      status,
      finishedAt,
      stateSince: finishedAt,
      cause,
      recovered: true,
      orphaned: false,
      ...(digest ? { result: digest } : {}),
    });
    if (!terminalFromResult) {
      task.error = 'task process is no longer running and no terminal result was recorded';
    }
    seq += 1;
    records.push({
      seq,
      taskId: id,
      implementer: task.implementer ?? null,
      workspace: task.workspace ?? null,
      from,
      to: status,
      at: finishedAt,
      kind: terminalFromResult ? 'recovered' : 'worker_lost',
      cause,
      recovered: true,
    });
    if (terminalFromResult) outcome.recovered.push(id);
    else outcome.lost.push(id);
    changed = true;
  }
  if (records.length) {
    appendFileSync(paths.journal, records.map((record) => `${JSON.stringify(record)}\n`).join(''), 'utf8');
  }
  if (changed) {
    // Live counters belong to the dead worker, so they are recomputed here
    // instead of being carried over into a repaired manifest.
    manifest.active = Object.values(manifest.tasks || {})
      .filter((task) => task && !TERMINAL_STATUSES.has(task.status) && !['queued', 'held'].includes(task.status))
      .length;
    manifest.seq = seq;
    writeJsonAtomic(paths.manifest, manifest);
  }
  outcome.changed = changed;
  return outcome;
}

/**
 * Renders one journal record for a coordinator: the transition, its elapsed
 * time, and — for a terminal outcome — the result status, artifact path, and
 * any branch/SHA/PR the task published. No second call is needed to triage.
 */
function enrichWatchEvent(runDir, event) {
  const actionable = isActionableEvent(event);
  const manifest = readManifestQuiet(runDir);
  const task = event.taskId ? manifest?.tasks?.[event.taskId] ?? null : null;
  const at = event.at ?? event.timestamp ?? null;
  const enriched = {
    version: WATCH_EVENT_VERSION,
    run: runDir,
    ...event,
    actionable,
  };
  if (!event.taskId) {
    // A dead supervisor is a run-level fact, so the line names the lost pid and
    // the tasks it left non-terminal instead of pretending a task stalled.
    const detail = event.kind === 'supervisor_dead'
      ? ` (supervisor pid ${event.supervisorPid ?? '?'} is gone;`
        + ` ${(event.nonTerminal ?? []).length} non-terminal task(s): ${(event.nonTerminal ?? []).join(', ')})`
      : (event.cause ? ` (${event.cause})` : '');
    enriched.line = `${at ?? '[unknown time]'}  RUN ${event.to}${detail}`;
    return enriched;
  }
  const terminal = TERMINAL_STATUSES.has(event.to);
  const startedAt = task?.startedAt ?? null;
  const finishedAt = task?.finishedAt ?? at;
  const elapsedMs = startedAt
    ? Math.max(0, (parseIsoMillis(finishedAt) ?? Date.now()) - (parseIsoMillis(startedAt) ?? 0))
    : null;
  const result = terminal ? taskResultForView(task) : null;
  enriched.elapsedMs = elapsedMs;
  enriched.elapsed = elapsedMs == null ? null : formatDuration(elapsedMs);
  enriched.attempt = task?.attempt ?? 1;
  if (result) enriched.result = result;

  const parts = [
    `${at ?? '[unknown time]'}`,
    event.taskId,
    `${event.from ?? '?'} -> ${event.to}${event.cause ? ` (${event.cause})` : ''}`,
  ];
  if (enriched.elapsed) parts.push(`elapsed ${enriched.elapsed}`);
  if (enriched.attempt > 1) parts.push(`attempt ${enriched.attempt}`);
  if (result) {
    if (result.status) parts.push(`result ${result.status}`);
    if (result.prUrl) parts.push(`pr ${result.prUrl}`);
    if (result.headSha) parts.push(`sha ${result.headSha}`);
    if (result.branch) parts.push(`branch ${result.branch}`);
    if (result.summary) parts.push(`summary ${result.summary}`);
    parts.push(`result-file ${result.path}`);
  }
  enriched.line = parts.join('  ');
  return enriched;
}

/**
 * `watch` is the coordinator interface: several runs, a durable cursor, and one
 * line per actionable event. Nothing that happened while no watcher ran is
 * lost, and nothing already handled is printed twice.
 */
export async function watchCommand(options) {
  const runDirs = [...new Set(options.runs.map((entry) => resolve(entry)))];
  if (!runDirs.length) fail('watch requires at least one --run');
  for (const runDir of runDirs) {
    if (!existsSync(runDir)) fail(`run directory does not exist: ${runDir}`);
  }
  if (!options.cursor) fail('watch requires --cursor <file>');
  const cursorPath = resolve(options.cursor);
  const once = options.once === true;
  const includeAll = options.all === true;
  const timeoutMs = secondsOption(options, 'timeout-sec', 0, '--timeout-sec');

  const cursor = loadCursor(cursorPath);
  const runs = runDirs.map((runDir) => ({
    runDir,
    journal: runPaths(runDir).journal,
    manifest: runPaths(runDir).manifest,
    handled: cursorSeq(cursor, runDir),
  }));

  const pendingCursor = new Map();
  let inFlight = 0;
  let drained = null;
  let wake = null;
  let stopped = false;
  const watchers = [];

  const flushCursor = () => {
    let changed = false;
    for (const [runDir, seq] of pendingCursor) {
      if (seq > cursorSeq(cursor, runDir)) {
        cursor.runs[runDir] = { seq, updatedAt: new Date().toISOString() };
        changed = true;
      }
    }
    pendingCursor.clear();
    if (changed) saveCursor(cursorPath, cursor);
  };

  const whenDrained = () => {
    if (inFlight === 0) return Promise.resolve();
    return new Promise((resolvePromise) => { drained = resolvePromise; });
  };

  const emit = (entry) => {
    const line = options.json
      ? `${JSON.stringify(entry)}\n`
      : `${entry.line}\n`;
    inFlight += 1;
    // The cursor advances only after this line is flushed, so a watcher that
    // dies mid-print replays the event instead of losing it.
    process.stdout.write(line, () => {
      inFlight -= 1;
      if (inFlight === 0) {
        flushCursor();
        const resolver = drained;
        drained = null;
        resolver?.();
      }
    });
  };

  const scan = () => {
    const batch = [];
    for (const run of runs) {
      const events = readJournalEvents(run.journal);
      let boundary = run.handled;
      for (const event of events) {
        if (event.seq > boundary) boundary = event.seq;
        if (event.seq <= run.handled) continue;
        const enriched = enrichWatchEvent(run.runDir, event);
        if (includeAll || enriched.actionable) batch.push(enriched);
      }
      if (boundary > (pendingCursor.get(run.runDir) ?? 0)) pendingCursor.set(run.runDir, boundary);
    }
    batch.sort((left, right) => {
      const leftAt = parseIsoMillis(left.at ?? left.timestamp) ?? 0;
      const rightAt = parseIsoMillis(right.at ?? right.timestamp) ?? 0;
      if (leftAt !== rightAt) return leftAt - rightAt;
      return left.seq - right.seq;
    });
    return batch;
  };

  const cycle = async () => {
    for (const runDir of runDirs) reconcileRun(runDir);
    const batch = scan();
    for (const entry of batch) emit(entry);
    for (const run of runs) {
      run.handled = Math.max(run.handled, pendingCursor.get(run.runDir) ?? 0);
    }
    await whenDrained();
    flushCursor();
    return batch.length;
  };

  const announce = () => {
    const resolver = wake;
    wake = null;
    resolver?.();
  };
  const waitForWake = () => new Promise((resolvePromise) => { wake = resolvePromise; });

  for (const dir of new Set(runs.map((run) => dirname(run.journal)))) {
    try {
      const watcher = watch(dir, (_eventType, filename) => {
        if (!filename) {
          announce();
          return;
        }
        const name = String(filename);
        if (runs.some((run) => name === basename(run.journal) || name === basename(run.manifest))) {
          announce();
        }
      });
      watcher.once('error', () => {});
      watchers.push(watcher);
    } catch {
      // The bounded liveness rescan below keeps the watcher working.
    }
  }
  // Filesystem events are the primary wake-up path; this bounded rescan also
  // repairs a run whose supervisor died while no watcher was listening.
  const liveness = setInterval(announce, 500);
  const stop = () => {
    if (stopped) return;
    stopped = true;
    clearInterval(liveness);
    for (const watcher of watchers) {
      try { watcher.close(); } catch {}
    }
  };

  const deadline = timeoutMs > 0
    ? setTimeout(() => {
      stop();
      process.stderr.write(`supervisor: watch timed out after ${timeoutMs}ms with no new actionable event\n`);
      process.exit(4);
    }, timeoutMs)
    : null;
  if (deadline && typeof deadline.unref === 'function') deadline.unref();

  const finishIfAllRunsEnded = () => {
    if (!runDirs.every((runDir) => runIsFinished(runDir))) return false;
    stop();
    return true;
  };

  try {
    while (!stopped) {
      const printed = await cycle();
      if (once && printed > 0) {
        stop();
        return;
      }
      if (finishIfAllRunsEnded()) return;
      if (once && printed === 0) {
        // Nothing actionable yet: wait for the next wake-up instead of
        // re-invoking the caller with an empty batch.
        await waitForWake();
        continue;
      }
      await waitForWake();
    }
  } finally {
    stop();
  }
}
