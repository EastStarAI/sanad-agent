// The guard is the only place a test may signal a process, so its two refusals
// are tested directly: an untracked pid is never signalled, and a kill selected
// by pattern or name never even becomes a command.

import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtempSync, realpathSync } from 'node:fs';
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
