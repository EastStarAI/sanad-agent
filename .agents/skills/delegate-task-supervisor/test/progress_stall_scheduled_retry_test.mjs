// Stall policy for a turn the daemon is retrying on its own.
//
// 2026-11-09: the daemon was legitimately rate-limited, the Client rendered
// `retrying automatically in 30s (attempt 1 of 3)`, and `status` reported a
// `progress_stall` ~17 minutes into a wait the daemon was still honouring. A
// scheduled retry is progress no worker can publish as output, so the silence
// clock must start at the deadline the daemon itself stated.
//
// The rule under test is one rule: `evaluateProgress` is what `status` renders
// and what the worker journal records, so a read-only surface can never disagree
// with the journal. A deadline that has *passed* still stalls — the daemon
// promised an attempt and none arrived — which is the half of the rule that
// keeps a lost wake-up reportable.

import assert from 'node:assert/strict';
import test from 'node:test';

const { evaluateProgress, retryDeadlineMs } = await import(
  new URL('../scripts/supervisor-stalls.mjs', import.meta.url)
);
const { interpretSessionSnapshot } = await import(
  new URL('../scripts/supervisor-follow.mjs', import.meta.url)
);
const { createReconciler } = await import(
  new URL('../scripts/supervisor-worker/reconcile.mjs', import.meta.url)
);

const NOW = Date.parse('2026-11-09T00:00:00.000Z');
const isoAt = (offsetMs) => new Date(NOW + offsetMs).toISOString();

const manifestOf = (overrides = {}) => ({
  maxConcurrency: 1,
  active: 1,
  progressStallMs: 60_000,
  ...overrides,
});

const rateLimitNotice = (overrides = {}) => ({
  session_id: 'sess-rate-limited',
  request_id: 'req-turn-1',
  status: 'waiting',
  reason: 'upstream_rate_limit',
  severity: 'warning',
  title: 'OpenCodeGo Rate limit reached',
  message:
    'Too many requests to OpenCodeGo. Wait or switch provider. Retrying '
    + 'automatically in 30s (attempt 1 of 3).',
  retry_attempt: 1,
  retry_budget: 3,
  retry_after_ms: 30_000,
  resume_at: isoAt(30_000),
  ...overrides,
});

/** The `session show --json` projection the daemon publishes for that turn. */
const rateLimitedProjection = (overrides = {}) => ({
  session_id: 'sess-rate-limited',
  status: 'retrying',
  execution_state: 'resuming',
  execution_snapshot: { state: 'resuming', request_id: 'req-turn-1' },
  runtime_notice: rateLimitNotice(),
  retry: {
    pending: true,
    stopped: false,
    notice_status: 'waiting',
    reason: 'upstream_rate_limit',
    attempt: 1,
    budget: 3,
    resume_in_ms: 30_000,
    label: 'retrying (1/3)',
  },
  ...overrides,
});

// ---------------------------------------------------------------------------
// The projected snapshot names the cause and the deadline.
// ---------------------------------------------------------------------------

test('the projection names the daemon cause and the stated resume deadline', () => {
  const snapshot = interpretSessionSnapshot(rateLimitedProjection());

  assert.equal(snapshot.kind, 'retrying');
  assert.equal(snapshot.status, 'retrying');
  assert.equal(
    snapshot.retry.reason,
    'upstream_rate_limit',
    'a scheduled retry must name its cause, not leave the coordinator guessing',
  );
  assert.equal(snapshot.retry.label, 'retrying (1/3)');
  assert.equal(snapshot.retry.attempt, 1);
  assert.equal(snapshot.retry.budget, 3);
  assert.equal(snapshot.retryAfterMs, 30_000);
  assert.equal(
    snapshot.retryResumeAt,
    isoAt(30_000),
    'the snapshot must carry the deadline the daemon itself stated',
  );
});

test('a worker-classified cause is never overwritten by the notice reason', () => {
  const snapshot = interpretSessionSnapshot(
    rateLimitedProjection({ cause: 'provider_timeout' }),
  );

  assert.equal(snapshot.kind, 'retrying');
  assert.equal(snapshot.cause, 'provider_timeout');
  assert.equal(snapshot.retry.reason, 'upstream_rate_limit');
});

// ---------------------------------------------------------------------------
// The stall clock is max(lastSignal, retryDeadline).
// ---------------------------------------------------------------------------

test('a stated resume_at is the deadline, and it is measured from the daemon', () => {
  assert.equal(
    retryDeadlineMs({ daemonRetry: { attempt: 1, budget: 3, resumeAt: isoAt(30_000) } }),
    NOW + 30_000,
  );
});

test('a retry_after_ms wait is measured from the state that published it', () => {
  assert.equal(
    retryDeadlineMs({ status: 'retrying', stateSince: isoAt(-5_000), retryAfterMs: 30_000 }),
    NOW + 25_000,
  );
  assert.equal(
    retryDeadlineMs({ status: 'retrying', stateSince: isoAt(-5_000) }),
    null,
    'no stated wait is no deadline, never a manufactured one',
  );
});

test('a live retry is never silent before its deadline', () => {
  const verdict = evaluateProgress({
    state: {
      status: 'resuming',
      stateSince: isoAt(-120_000),
      lastProgressAt: isoAt(-120_000),
      daemonRetry: { attempt: 1, budget: 3, resumeAt: isoAt(30_000) },
    },
    manifest: manifestOf(),
    now: NOW,
  });

  assert.equal(verdict.stalled, false);
  assert.equal(verdict.silentForMs, 0);
  assert.equal(verdict.retryDeadlineAt, isoAt(30_000));
  assert.equal(verdict.thresholdMs, 60_000);
});

test('a passed retry deadline stalls, because no attempt arrived', () => {
  const verdict = evaluateProgress({
    state: {
      status: 'running',
      stateSince: isoAt(-600_000),
      lastProgressAt: isoAt(-600_000),
      daemonRetry: { attempt: 1, budget: 3, resumeAt: isoAt(-120_000) },
    },
    manifest: manifestOf(),
    now: NOW,
  });

  assert.equal(
    verdict.stalled,
    true,
    'a promise the daemon did not keep is exactly what a coordinator must hear',
  );
  assert.equal(verdict.silentForMs, 120_000);
  assert.equal(verdict.retryDeadlineAt, isoAt(-120_000));
});

test('the latest signal still wins over a deadline already overtaken', () => {
  const verdict = evaluateProgress({
    state: {
      status: 'running',
      stateSince: isoAt(-600_000),
      lastProgressAt: isoAt(-10_000),
      daemonRetry: { attempt: 1, budget: 3, resumeAt: isoAt(-300_000) },
    },
    manifest: manifestOf(),
    now: NOW,
  });

  assert.equal(verdict.stalled, false);
  assert.equal(verdict.silentForMs, 10_000);
});

test('plain silence with no retry evidence still stalls at its threshold', () => {
  const verdict = evaluateProgress({
    state: { status: 'running', startedAt: isoAt(-600_000) },
    manifest: manifestOf(),
    now: NOW,
  });

  assert.equal(verdict.stalled, true);
  assert.equal(verdict.silentForMs, 600_000);
  assert.equal(verdict.retryDeadlineAt, null);
});

// ---------------------------------------------------------------------------
// The worker journal applies the same rule the read-only view renders.
// ---------------------------------------------------------------------------

function makeReconciler(taskState) {
  const notices = [];
  const task = { id: 'task-1' };
  const manifest = { tasks: { 'task-1': taskState }, progressStallMs: 60_000 };
  const ctx = {
    taskMap: new Map([['task-1', task]]),
    manifest,
    settled: new Set(),
    children: new Map(),
    persist: () => {},
    notice: (_task, kind, data) => notices.push({ kind, data }),
    isFollowing: () => false,
    transition: () => {},
    checkRunCompletion: () => {},
    launchAvailable: () => {},
  };
  return { reconciler: createReconciler(ctx), notices, taskState };
}

test('the journal never flags a stall before the daemon deadline', () => {
  const now = Date.now();
  const { reconciler, notices, taskState } = makeReconciler({
    id: 'task-1',
    status: 'running',
    stateSince: new Date(now - 600_000).toISOString(),
    lastProgressAt: new Date(now - 600_000).toISOString(),
    daemonRetry: {
      attempt: 1,
      budget: 3,
      resumeAt: new Date(now + 30_000).toISOString(),
    },
  });

  reconciler.flagProgressStall('task-1');

  assert.deepEqual(notices, []);
  assert.equal(taskState.progressStall ?? null, null);
});

test('the journal flags the stall once the deadline passes', () => {
  const now = Date.now();
  const { reconciler, notices, taskState } = makeReconciler({
    id: 'task-1',
    status: 'running',
    stateSince: new Date(now - 600_000).toISOString(),
    lastProgressAt: new Date(now - 600_000).toISOString(),
    daemonRetry: {
      attempt: 1,
      budget: 3,
      resumeAt: new Date(now - 120_000).toISOString(),
    },
  });

  reconciler.flagProgressStall('task-1');

  assert.equal(notices[0]?.kind, 'progress_stall');
  assert.ok(
    notices[0]?.data.silentForMs >= 120_000,
    'the stall is measured from the deadline the daemon did not keep',
  );
  assert.ok(
    notices[0]?.data.silentForMs < 300_000,
    'not from the last signal ten minutes ago: the deadline is the later clock',
  );
  assert.equal(notices[0]?.data.silentForMs, taskState.progressStall?.silentForMs);
});
