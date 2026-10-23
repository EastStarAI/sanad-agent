// Run identity, the workspace registry, and run paths.
//
// The coordinator remembers a project/session per workspace across runs, and
// every command addresses a run by an absolute directory. Both live here so a
// path is derived in one place: `runPaths` for the run's own records,
// `taskRunPaths` for one task's artifacts, and the workspace registry under the
// user config directory.
//
// `reconcileRun` belongs to this owner because it rewrites the run record from
// what the task artifacts already say: it is the only writer that turns a dead
// worker or a settled session into manifest state, and both `status` and
// `watch` call it before they report.

import { createHash } from 'node:crypto';
import { appendFileSync, existsSync, readFileSync, realpathSync } from 'node:fs';
import { homedir } from 'node:os';
import { isAbsolute, join, resolve } from 'node:path';

import {
  applyVisibleResult,
  fail,
  processIsAlive,
  readJson,
  readResultDigest,
  resultBelongsToTask,
  sha256,
  writeJsonAtomic,
} from './supervisor-core.mjs';
import { TERMINAL_STATUSES } from './supervisor-events.mjs';

export function canonicalWorkspace(path) {
  if (!isAbsolute(path)) fail(`workspace must be absolute: ${path}`);
  const normalized = resolve(path);
  try {
    return realpathSync(normalized);
  } catch {
    fail(`workspace does not exist: ${path}`);
  }
}

function configRoot() {
  if (process.platform === 'win32') {
    return process.env.APPDATA || join(homedir(), 'AppData', 'Roaming');
  }
  return process.env.XDG_CONFIG_HOME || join(homedir(), '.config');
}

function registryPath() {
  return join(configRoot(), 'delegate-task-supervisor', 'workspaces.json');
}

function workspaceKey(path) {
  return createHash('sha256').update(path).digest('hex').slice(0, 24);
}

function loadRegistry() {
  const path = registryPath();
  if (!existsSync(path)) return { version: 'delegate-workspaces.v1', workspaces: {} };
  const value = readJson(path, 'workspace registry');
  if (value.version !== 'delegate-workspaces.v1' || typeof value.workspaces !== 'object') {
    fail(`unsupported workspace registry at ${path}`);
  }
  return value;
}

export function identityFor(workspace) {
  const canonical = canonicalWorkspace(workspace);
  const registry = loadRegistry();
  return registry.workspaces[workspaceKey(canonical)] || {
    path: canonical,
    antigravity: null,
    opencode: null,
    sanad: null,
  };
}

export function recordIdentity(task, result) {
  const projectId = result?.projectId ?? result?.project_id ?? null;
  const conversationId = result?.conversationId ?? result?.conversation_id ?? null;
  const sessionId = result?.sessionId ?? result?.session_id ?? null;
  if (!projectId && !conversationId && !sessionId) return;

  const registry = loadRegistry();
  const key = workspaceKey(task.workspace);
  const entry = registry.workspaces[key] || {
    path: task.workspace,
    antigravity: null,
    opencode: null,
    sanad: null,
  };
  const now = new Date().toISOString();
  if (task.implementer === 'antigravity' || task.implementer === 'agy') {
    entry.antigravity = { projectId, conversationId, updatedAt: now };
  } else if (task.implementer === 'opencode') {
    entry.opencode = { sessionId, updatedAt: now };
  } else if (task.implementer === 'sanad') {
    entry.sanad = { sessionId, updatedAt: now };
  }
  registry.workspaces[key] = entry;
  writeJsonAtomic(registryPath(), registry);
}

export function runPaths(runDir) {
  return {
    manifest: join(runDir, 'manifest.json'),
    journal: join(runDir, 'events.jsonl'),
    tasks: join(runDir, 'tasks.json'),
    requests: join(runDir, 'requests'),
    supervisorLog: join(runDir, 'supervisor.log'),
  };
}

// Task artifacts live in the run directory. A remote `sanad-client` task
// streams its NDJSON lifecycle events and terminal `--json` envelope over
// stdout, so the relayed stdout log is both the observed timeline and the
// source of the captured result; `--out-dir` would only create remote files.
export function taskRunPaths(task, runDir) {
  const stdoutPath = join(runDir, `${task.id}.stdout.log`);
  const stderrPath = join(runDir, `${task.id}.stderr.log`);
  if (!task.remote) {
    return { stdoutPath, stderrPath, timelinePath: task.timelinePath, resultPath: task.resultPath };
  }
  return {
    stdoutPath,
    stderrPath,
    timelinePath: stdoutPath,
    resultPath: task.resultPath ?? join(runDir, `${task.id}.result.json`),
  };
}

export function withRunPaths(task, runDir) {
  return { ...task, ...taskRunPaths(task, runDir) };
}

export function loadManifest(runDir) {
  const path = runPaths(resolve(runDir)).manifest;
  if (!existsSync(path)) fail(`manifest not found: ${path}`);
  return readJson(path, 'run manifest');
}

export function requireTask(manifest, id) {
  const task = manifest.tasks?.[id];
  if (!task) fail(`task not found: ${id}`);
  return task;
}

export function readManifestQuiet(runDir) {
  const path = runPaths(runDir).manifest;
  if (!existsSync(path)) return null;
  try {
    return JSON.parse(readFileSync(path, 'utf8'));
  } catch {
    return null;
  }
}

export function runIsFinished(runDir) {
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
export function identityCommand(options) {
  if (!options.workspace) fail('identity requires --workspace');
  process.stdout.write(`${JSON.stringify(identityFor(options.workspace), null, 2)}\n`);
}
