// Test-only process ownership guard.
//
// The supervisor starts detached workers on purpose, so a test must be able to
// clean them up without ever signalling a process it did not start. Two rules
// are enforced here, in one place:
//
// 1. A pid may only be signalled if *this test* spawned it (the registry below)
//    and its command line still names the fixture it was spawned for, which is
//    what protects a reused pid.
// 2. A pattern kill is never allowed. `pkill -f supervisor.mjs` reaches the
//    coordinator's live supervisors — it did exactly that during the 2026-10-22
//    live round and froze four runs — so the guard refuses even to spawn a
//    command whose text looks like one.
//
// Abandoned fixtures (a test process that died before its teardown) are repaired
// by `sweepOrphanedFixtures`, which proves ownership from the command line and
// the fixture manifests instead of from a process name.

import { spawn, spawnSync } from 'node:child_process';
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

// A process name or pattern is never an ownership proof, and a kill selected by
// one is exactly the bug this module exists to prevent.
const FORBIDDEN_KILL = /\b(pkill|killall|taskkill|kill-pattern)\b/i;

export function assertNoPatternKill(value) {
  const text = Array.isArray(value) ? value.join(' ') : String(value ?? '');
  if (FORBIDDEN_KILL.test(text)) {
    throw new Error(`refusing a process kill selected by pattern or name: ${text.slice(0, 120)}`);
  }
}

export function processCommand(pid) {
  if (process.platform === 'win32') return '';
  if (!Number.isInteger(pid) || pid <= 0) return '';
  const result = spawnSync('ps', ['-p', String(pid), '-o', 'command='], { encoding: 'utf8' });
  return result.status === 0 ? (result.stdout || '').trim() : '';
}

export function processIsAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

/**
 * One test's process registry. `spawn` is a drop-in for `child_process.spawn`
 * that remembers the pid and the fixture needle it belongs to.
 */
export function createProcessGuard({ label = 'process-guard' } = {}) {
  const tracked = new Map();
  let disposed = false;

  const describe = (pid) => `${label}: pid ${pid}`;

  const guard = {
    spawn(command, args = [], options = {}, { needle = null } = {}) {
      assertNoPatternKill(command);
      assertNoPatternKill(args);
      const child = spawn(command, args, options);
      if (Number.isInteger(child.pid)) {
        tracked.set(child.pid, { needle, command, args: [...args] });
        child.once('exit', () => {
          if (tracked.get(child.pid)?.command === command) tracked.delete(child.pid);
        });
      }
      return child;
    },

    // A pid another helper started can still be adopted, as long as the caller
    // names the fixture that proves ownership.
    track(pid, needle) {
      if (!Number.isInteger(pid)) throw new Error(`${label}: cannot track a non-pid`);
      tracked.set(pid, { needle, command: null, args: [] });
      return pid;
    },

    owns(pid) {
      return tracked.has(pid);
    },

    trackedPids() {
      return [...tracked.keys()];
    },

    /**
     * Signal one pid this test spawned. Anything else is refused loudly: a guard
     * that silently ignores an unknown pid teaches the wrong habit. Death is
     * confirmed with `waitGone`, because a killed child is reaped by the event
     * loop and cannot be observed synchronously.
     */
    terminate(pid, signal = 'SIGKILL') {
      assertNoPatternKill(signal);
      if (!tracked.has(pid)) {
        throw new Error(`${describe(pid)} was not spawned by this test; refusing to signal it`);
      }
      const entry = tracked.get(pid);
      const command = processCommand(pid);
      if (entry.needle && command && !command.includes(entry.needle)) {
        throw new Error(`${describe(pid)} no longer belongs to ${entry.needle}; refusing to signal it`);
      }
      if (!command) {
        // Already gone: forget it and report that nothing was signalled.
        tracked.delete(pid);
        return false;
      }
      try {
        process.kill(pid, signal);
      } catch {
        tracked.delete(pid);
        return false;
      }
      return true;
    },

    /** Confirm a signalled pid is gone, escalating once if it ignores SIGTERM. */
    async waitGone(pid, timeoutMs = 3_000) {
      const deadline = Date.now() + timeoutMs;
      while (Date.now() < deadline) {
        if (!processIsAlive(pid)) {
          tracked.delete(pid);
          return true;
        }
        await new Promise((resolvePromise) => setTimeout(resolvePromise, 25));
      }
      try {
        process.kill(pid, 'SIGKILL');
      } catch {
        // Already gone.
      }
      await new Promise((resolvePromise) => setTimeout(resolvePromise, 100));
      const gone = !processIsAlive(pid);
      if (gone) tracked.delete(pid);
      return gone;
    },

    /** Terminate every tracked pid whose needle names this fixture. */
    terminateFixture(needle) {
      let reaped = 0;
      for (const pid of [...tracked.keys()]) {
        const entry = tracked.get(pid);
        if (entry?.needle !== needle) continue;
        if (guard.terminate(pid)) reaped += 1;
        // Reconciliation happens in the caller's await; this is a best effort.
      }
      return reaped;
    },

    /** Teardown: every pid is gone and the registry is empty. */
    async dispose() {
      disposed = true;
      for (const pid of [...tracked.keys()]) {
        try {
          guard.terminate(pid);
          await guard.waitGone(pid);
        } catch {
          // A pid that no longer matches its needle is not ours to kill.
        }
      }
      return tracked.size === 0;
    },

    get disposed() {
      return disposed;
    },
  };

  return guard;
}

function collectManifests(directory, depth = 0) {
  const found = [];
  let entries;
  try {
    entries = readdirSync(directory, { withFileTypes: true });
  } catch {
    return found;
  }
  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    const child = join(directory, entry.name);
    const manifestPath = join(child, 'manifest.json');
    if (existsSync(manifestPath)) found.push(manifestPath);
    if (depth < 2) found.push(...collectManifests(child, depth + 1));
  }
  return found;
}

/**
 * Repair fixtures a dead test process left behind.
 *
 * Ownership is proven twice: the manifest must live under a fixture directory of
 * this test root, and the pid's command line must name that same directory. A
 * supervisor is found through its `--run <dir>`, a task through its fixture
 * paths. A reused pid that merely happens to match is never signalled.
 */
export function sweepOrphanedFixtures({ root = tmpdir(), prefix = 'delegate-', dryRun = false } = {}) {
  let candidates = [];
  try {
    candidates = readdirSync(root).filter((entry) => entry.startsWith(prefix));
  } catch {
    return { reaped: [], scanned: 0 };
  }
  const reaped = [];
  const sweep = (pid, needle) => {
    if (!Number.isInteger(pid) || pid <= 0) return;
    if (!processIsAlive(pid)) return;
    const command = processCommand(pid);
    if (!command || !command.includes(needle)) return;
    if (dryRun) {
      reaped.push({ pid, needle, dryRun: true });
      return;
    }
    try {
      process.kill(pid, 'SIGTERM');
    } catch {
      return;
    }
    const deadline = Date.now() + 1_500;
    while (Date.now() < deadline) {
      if (!processIsAlive(pid)) break;
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 50);
    }
    if (processIsAlive(pid)) {
      try {
        process.kill(pid, 'SIGKILL');
      } catch {
        // Already gone.
      }
    }
    reaped.push({ pid, needle, dryRun: false });
  };
  let scanned = 0;
  for (const entry of candidates) {
    const directory = join(root, entry);
    for (const manifestPath of collectManifests(directory)) {
      let manifest;
      try {
        manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
      } catch {
        continue;
      }
      scanned += 1;
      sweep(manifest.supervisorPid, directory);
      for (const task of Object.values(manifest.tasks || {})) {
        sweep(task?.pid, directory);
      }
    }
  }
  return { reaped, scanned };
}
