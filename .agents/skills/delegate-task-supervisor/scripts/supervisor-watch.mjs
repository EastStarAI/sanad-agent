// The durable watch loop.
//
// `watch` is the coordinator interface for several runs at once: it persists
// the last handled sequence per run in a cursor file, replays what a re-invoked
// orchestrator missed, and prints one line per actionable event. Reconciliation
// runs first, so a worker that died without journaling still wakes the watcher.
//
// The wake vocabulary itself is shared with `watch-once.mjs` through
// `supervisor-events.mjs`; this module only decides when to read the journal.

import { existsSync, readFileSync, watch } from 'node:fs';
import { basename, dirname, join, resolve } from 'node:path';

import {
  fail,
  formatDuration,
  parseIsoMillis,
  secondsOption,
  taskResultForView,
  writeJsonAtomic,
} from './supervisor-core.mjs';
import {
  readManifestQuiet,
  reconcileRun,
  runIsFinished,
  runPaths,
} from './supervisor-registry.mjs';
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
