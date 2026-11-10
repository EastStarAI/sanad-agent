// The guard is the only place a test may signal a process, so its two refusals
// are tested directly: an untracked pid is never signalled, and a kill selected
// by pattern or name never even becomes a command.

import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdirSync, mkdtempSync, realpathSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

import {
  assertNoPatternKill,
  createProcessGuard,
  processIsAlive,
  sweepOrphanedFixtures,
} from './process_guard.mjs';

test('the guard kills a pid it spawned and forgets it', async () => {
  const guard = createProcessGuard({ label: 'unit' });
  const child = guard.spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], {}, { needle: 'setInterval' });
  assert.ok(Number.isInteger(child.pid));
  assert.equal(guard.owns(child.pid), true);
  assert.equal(processIsAlive(child.pid), true);

  assert.equal(guard.terminate(child.pid), true);
  assert.equal(await guard.waitGone(child.pid), true);
  assert.equal(processIsAlive(child.pid), false);
  assert.equal(guard.owns(child.pid), false);
});

test('the guard refuses a pid this test did not spawn and leaves it alive', async () => {
  const guard = createProcessGuard({ label: 'unit' });
  // A process started outside the guard is exactly the "someone else's live
  // supervisor" case: refusing is the whole point.
  const decoy = spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], { stdio: 'ignore' });
  try {
    assert.throws(() => guard.terminate(decoy.pid), /was not spawned by this test/);
    assert.equal(processIsAlive(decoy.pid), true);
  } finally {
    // The decoy is cleaned up through its own handle, never by pattern.
    decoy.kill('SIGKILL');
  }
});

test('the guard refuses a tracked pid whose command line no longer names its fixture', () => {
  const guard = createProcessGuard({ label: 'unit' });
  const child = guard.spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], {}, { needle: '/fixture-that-is-not-in-argv' });
  try {
    assert.throws(() => guard.terminate(child.pid), /no longer belongs to/);
    assert.equal(processIsAlive(child.pid), true);
  } finally {
    child.kill('SIGKILL');
  }
});

test('a kill selected by pattern or name is never allowed', () => {
  for (const forbidden of ['pkill -f supervisor.mjs', 'killall node', 'taskkill /IM node.exe']) {
    assert.throws(() => assertNoPatternKill(forbidden), /selected by pattern or name/);
  }
  assert.doesNotThrow(() => assertNoPatternKill('ps -p 1234 -o command='));
  assert.doesNotThrow(() => assertNoPatternKill(['session', 'stop', 'sess-1']));
  const guard = createProcessGuard();
  assert.throws(
    () => guard.spawn('pkill', ['-f', 'supervisor.mjs'], {}),
    /selected by pattern or name/,
  );
});

test('the abandoned-fixture sweep only signals pids whose command line names the fixture', () => {
  const root = realpathSync(mkdtempSync(join(tmpdir(), 'delegate-guard-test-')));
  const result = sweepOrphanedFixtures({ root, prefix: 'delegate-', dryRun: true });
  assert.deepEqual(result.reaped, []);
  // A directory outside the prefix is never scanned, so a live run elsewhere on
  // the machine cannot be reached by a test sweep.
  const outside = sweepOrphanedFixtures({ root: tmpdir(), prefix: 'delegate-guard-test-', dryRun: true });
  assert.equal(outside.reaped.length, 0);
});

test('the sweep stays inside the fixture families its caller declares', () => {
  // Two fixture families under one root, both with a live pid named by a manifest.
  // A caller that owns only the first must not even scan the second: `node --test
  // test/*_test.mjs` runs test files concurrently, so a broad sweep can signal a
  // fixture a running file still owns (2026-11-10).
  const root = realpathSync(mkdtempSync(join(tmpdir(), 'delegate-guard-scope-')));
  const own = join(root, 'delegate-guard-scope-own-');
  const foreign = join(root, 'delegate-guard-scope-foreign-');
  const spawnLive = (needle) => spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)', needle], { stdio: 'ignore' });
  mkdirSync(join(own, 'run'), { recursive: true });
  mkdirSync(join(foreign, 'run'), { recursive: true });
  const ownPid = spawnLive(own);
  const foreignPid = spawnLive(foreign);
  try {
    // The sweep reads a task's run manifest one level below the fixture root.
    for (const [directory, pid] of [[own, ownPid.pid], [foreign, foreignPid.pid]]) {
      writeFileSync(join(directory, 'run', 'manifest.json'), JSON.stringify({ supervisorPid: pid, tasks: {} }), 'utf8');
    }
    const scoped = sweepOrphanedFixtures({ root, prefixes: ['delegate-guard-scope-own-'], dryRun: true });
    assert.deepEqual(scoped.reaped.map((entry) => entry.pid), [ownPid.pid]);
    // A single prefix keeps working for the one-family caller.
    const single = sweepOrphanedFixtures({ root, prefix: 'delegate-guard-scope-foreign-', dryRun: true });
    assert.deepEqual(single.reaped.map((entry) => entry.pid), [foreignPid.pid]);
    // Nothing was signalled: a dry run only reports.
    assert.equal(processIsAlive(ownPid.pid), true);
    assert.equal(processIsAlive(foreignPid.pid), true);
  } finally {
    ownPid.kill('SIGKILL');
    foreignPid.kill('SIGKILL');
  }
});
