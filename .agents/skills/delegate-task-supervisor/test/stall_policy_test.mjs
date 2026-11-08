// Stall policy unit tests: fixed clocks, no live supervisor.
//
// The two false alarms this policy replaced (2026-11-08, run12) were
// time-shaped, so every case here is expressed with an explicit `now` instead of
// waiting for a threshold to pass in real time: a busy task is never silent, a
// task waiting for a busy concurrency slot is never a queue stall, and only a
// free-but-unlaunched queue or slots held by dead processes wake a coordinator.

import assert from 'node:assert/strict';
import test from 'node:test';

const {
  advancedSignals,
  evaluateProgress,
  progressReference,
  queueStallVerdict,
  signatureOf,
} = await import(new URL('../scripts/supervisor-stalls.mjs', import.meta.url));

const NOW = Date.parse('2026-11-09T00:00:00.000Z');
const iso = (msBefore) => new Date(NOW - msBefore).toISOString();

const runningTask = (overrides = {}) => ({
  id: 'task',
  status: 'running',
  pid: 1234,
  startedAt: iso(3_600_000),
  stateSince: iso(3_600_000),
  lastProgressAt: iso(3_600_000),
  progressStallMs: null,
  ...overrides,
});

const queuedState = (overrides = {}) => ({
  id: 'waiter',
  status: 'queued',
  queuedAt: iso(600_000),
  queuedSeq: 2,
  queueStall: null,
  ...overrides,
});

const manifestOf = (tasks, overrides = {}) => ({
  maxConcurrency: 1,
  active: 1,
  queuedStallMs: 120_000,
  progressStallMs: 900_000,
  ...overrides,
  tasks,
});

// ---------------------------------------------------------------------------
// Progress signals.
// ---------------------------------------------------------------------------

test('a task that is writing is not silent, and a changed artifact is the signal', () => {
  const previous = {
    timeline: { size: 10, mtimeMs: 1 },
    stdout: { size: 100, mtimeMs: 1 },
    stderr: null,
    result: null,
  };
  // A headless Sanad turn: the timeline still holds only its `running` record
  // while stdout carries the whole case.
  const current = {
    timeline: { size: 10, mtimeMs: 1 },
    stdout: { size: 4_096, mtimeMs: 2 },
    stderr: null,
    result: null,
  };
  assert.deepEqual(advancedSignals(previous, current), ['stdout']);

  // Identical samples are not progress, however long the task has been running.
  assert.deepEqual(advancedSignals(current, { ...current }), []);
});

test('an appearing artifact is progress; a vanishing one is not', () => {
  const beforeTimeline = { timeline: null, stdout: { size: 0, mtimeMs: 0 }, stderr: null, result: null };
  const withTimeline = { timeline: { size: 42, mtimeMs: 5 }, stdout: { size: 0, mtimeMs: 0 }, stderr: null, result: null };
  assert.deepEqual(advancedSignals(beforeTimeline, withTimeline), ['timeline']);

  const stdoutRemoved = { timeline: { size: 42, mtimeMs: 5 }, stdout: null, stderr: null, result: null };
  assert.deepEqual(advancedSignals(withTimeline, stdoutRemoved), []);
});

test('a rewrite at the same size still counts, and so does a truncation', () => {
  const before = { timeline: null, stdout: { size: 40, mtimeMs: 10 }, stderr: null, result: null };
  assert.deepEqual(
    advancedSignals(before, { ...before, stdout: { size: 40, mtimeMs: 11 } }),
    ['stdout'],
  );
  assert.deepEqual(
    advancedSignals(before, { ...before, stdout: { size: 4, mtimeMs: 11 } }),
    ['stdout'],
  );
});

test('the first sample of an episode is a baseline, not progress', () => {
  const sample = { timeline: null, stdout: { size: 900, mtimeMs: 1 }, stderr: null, result: null };
  assert.deepEqual(advancedSignals(null, sample), []);
  assert.deepEqual(advancedSignals(undefined, sample), []);
});

test('an unreadable artifact is a null signature instead of a fake size', () => {
  assert.equal(signatureOf(null), null);
  assert.equal(signatureOf({ size: 'big', mtimeMs: 1 }), null);
  assert.deepEqual(signatureOf({ size: 12, mtimeMs: 34 }), { size: 12, mtimeMs: 34 });
});

// ---------------------------------------------------------------------------
// Progress verdict: silence is measured from the latest signal.
// ---------------------------------------------------------------------------

test('a task whose latest signal is recent is not stalled, however old it is', () => {
  const state = runningTask({ lastProgressAt: iso(6_000), startedAt: iso(3_600_000) });
  const verdict = evaluateProgress({ state, manifest: manifestOf({ task: state }), now: NOW });
  assert.equal(verdict.stalled, false);
  assert.equal(verdict.silentForMs, 6_000);
  assert.equal(verdict.thresholdMs, 900_000);
  assert.equal(verdict.reference, state.lastProgressAt);
});

test('a task with no signal past its threshold is stalled', () => {
  const state = runningTask({ lastProgressAt: iso(901_000) });
  const verdict = evaluateProgress({ state, manifest: manifestOf({ task: state }), now: NOW });
  assert.equal(verdict.stalled, true);
  assert.equal(verdict.silentForMs, 901_000);
});

test('a task that never published its own signal is measured from its start', () => {
  const state = runningTask({ lastProgressAt: null, startedAt: iso(950_000) });
  const verdict = evaluateProgress({ state, manifest: manifestOf({ task: state }), now: NOW });
  assert.equal(verdict.stalled, true);
  assert.equal(verdict.reference, state.startedAt);
  assert.equal(verdict.lastProgressAt, null);
  assert.equal(progressReference(state), state.startedAt);
});

test('only a live task can be silent', () => {
  for (const status of ['blocked', 'waiting', 'needs_input', 'completed', 'queued', 'following']) {
    const state = runningTask({ status, lastProgressAt: iso(3_600_000) });
    const verdict = evaluateProgress({ state, manifest: manifestOf({ task: state }), now: NOW });
    assert.equal(verdict.stalled, false, `${status} must never be reported as a progress stall`);
  }
  const resuming = runningTask({ status: 'resuming', lastProgressAt: iso(901_000) });
  assert.equal(evaluateProgress({ state: resuming, manifest: manifestOf({ task: resuming }), now: NOW }).stalled, true);
});

test('a per-task threshold overrides the run default', () => {
  const state = runningTask({ lastProgressAt: iso(5_000), progressStallMs: 1_000 });
  const verdict = evaluateProgress({ state, manifest: manifestOf({ task: state }), now: NOW });
  assert.equal(verdict.thresholdMs, 1_000);
  assert.equal(verdict.stalled, true);
});

// ---------------------------------------------------------------------------
// Queue verdict.
// ---------------------------------------------------------------------------

const alive = () => true;
const dead = () => false;

test('waiting for a busy slot is never a queue stall, however long it lasts', () => {
  const holder = runningTask({ id: 'holder', pid: 999 });
  const waiter = queuedState({ queuedAt: iso(600_000) });
  const manifest = manifestOf({ holder, waiter }, { active: 1, maxConcurrency: 1 });
  const verdict = queueStallVerdict({
    manifest,
    state: waiter,
    snapshot: { active: 1, maxConcurrency: 1, queued: [{ id: 'waiter', state: waiter, position: 1 }] },
    now: NOW,
    isAlive: alive,
  });
  assert.equal(verdict.reason, 'awaiting_slot');
  assert.equal(verdict.stalled, false);
  assert.equal(verdict.holdsSlot, true);
  assert.equal(verdict.queuedForMs, 600_000);
  assert.match(verdict.reasonText, /waiting for a concurrency slot \(1\/1 active\)/);
});

test('a free slot the task was not launched into is a stall once it is overdue', () => {
  const waiter = queuedState({ queuedAt: iso(600_000) });
  const manifest = manifestOf({ waiter }, { active: 0, maxConcurrency: 2 });
  const verdict = queueStallVerdict({
    manifest,
    state: waiter,
    snapshot: { active: 0, maxConcurrency: 2, queued: [{ id: 'waiter', state: waiter, position: 1 }] },
    now: NOW,
    isAlive: alive,
  });
  assert.equal(verdict.reason, 'launch_pending');
  assert.equal(verdict.stalled, true);
  assert.match(verdict.reasonText, /slot is free but the task is not launched yet/);
});

test('a just-queued task is not late yet', () => {
  const waiter = queuedState({ queuedAt: iso(5_000) });
  const manifest = manifestOf({ waiter }, { active: 0, maxConcurrency: 2 });
  const verdict = queueStallVerdict({
    manifest,
    state: waiter,
    snapshot: { active: 0, maxConcurrency: 2, queued: [] },
    now: NOW,
    isAlive: alive,
  });
  assert.equal(verdict.stalled, false);
});

test('slots held by processes that are already gone are a frozen queue', () => {
  const ghost = runningTask({ id: 'ghost', pid: 4242 });
  const waiter = queuedState({ queuedAt: iso(600_000) });
  const manifest = manifestOf({ ghost, waiter }, { active: 1, maxConcurrency: 1 });
  const verdict = queueStallVerdict({
    manifest,
    state: waiter,
    snapshot: { active: 1, maxConcurrency: 1, queued: [{ id: 'waiter', state: waiter, position: 1 }] },
    now: NOW,
    isAlive: dead,
  });
  assert.equal(verdict.reason, 'slots_frozen');
  assert.equal(verdict.frozen, true);
  assert.equal(verdict.stalled, true);
  assert.match(verdict.reasonText, /held by a task whose process is gone/);
});

test('a followed turn holds its slot without ever looking frozen', () => {
  const followed = runningTask({
    id: 'followed',
    pid: 4242,
    status: 'following',
    follow: { lastPollAt: iso(1_000), active: true },
  });
  const waiter = queuedState({ queuedAt: iso(600_000) });
  const manifest = manifestOf({ followed, waiter }, { active: 1, maxConcurrency: 1 });
  const verdict = queueStallVerdict({
    manifest,
    state: waiter,
    snapshot: { active: 1, maxConcurrency: 1, queued: [] },
    now: NOW,
    isAlive: dead,
  });
  assert.equal(verdict.reason, 'awaiting_slot');
  assert.equal(verdict.stalled, false);
});

test('a slot holder with no pid is never reported as frozen', () => {
  const unknown = runningTask({ id: 'unknown', pid: null });
  const waiter = queuedState({ queuedAt: iso(600_000) });
  const manifest = manifestOf({ unknown, waiter }, { active: 1, maxConcurrency: 1 });
  const verdict = queueStallVerdict({
    manifest,
    state: waiter,
    snapshot: { active: 1, maxConcurrency: 1, queued: [] },
    now: NOW,
    isAlive: dead,
  });
  assert.equal(verdict.reason, 'awaiting_slot');
  assert.equal(verdict.stalled, false);
});
