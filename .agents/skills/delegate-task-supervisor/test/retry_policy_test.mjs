// The retry policy is pure and clock-injected, so grace, backoff, and exhaustion
// are tested with a fake clock instead of wall time. The integration side
// (supervisor_test.mjs) then only has to prove the wiring.

import assert from 'node:assert/strict';
import test from 'node:test';

import {
  AUTO_RETRY_BACKOFF_CAP_MS,
  DEFAULT_AUTO_RETRY_BACKOFF_MS,
  DEFAULT_AUTO_RETRY_GRACE_MS,
  DEFAULT_AUTO_RETRY_MAX_ATTEMPTS,
  DEFAULT_LAUNCH_RETRY_MAX_ATTEMPTS,
  LAUNCH_RETRY_WINDOW_MS,
  attemptsForEpisode,
  backoffDelay,
  planAutoRetry,
  planLaunchRetry,
  retryAfterMs,
  retryPolicy,
} from '../scripts/supervisor-retry.mjs';

const BLOCKED_AT = Date.parse('2026-10-22T12:00:00.000Z');
const at = (offsetMs) => BLOCKED_AT + offsetMs;

test('a blocked task is left alone during the grace period and retried after it', () => {
  const before = planAutoRetry({
    status: 'blocked',
    cause: 'provider_timeout',
    blockedAtMs: BLOCKED_AT,
    nowMs: at(DEFAULT_AUTO_RETRY_GRACE_MS - 1),
  });
  assert.equal(before.action, 'wait');
  assert.equal(before.reason, 'grace');
  assert.equal(before.dueAtMs, at(DEFAULT_AUTO_RETRY_GRACE_MS));

  const due = planAutoRetry({
    status: 'blocked',
    cause: 'provider_timeout',
    blockedAtMs: BLOCKED_AT,
    nowMs: at(DEFAULT_AUTO_RETRY_GRACE_MS),
  });
  assert.equal(due.action, 'retry');
  assert.equal(due.attempt, 1);
  assert.equal(due.maxAttempts, DEFAULT_AUTO_RETRY_MAX_ATTEMPTS);
  // The first retry's next deadline starts the exponential ladder.
  assert.equal(due.delayMs, DEFAULT_AUTO_RETRY_BACKOFF_MS);
});

test('backoff doubles per attempt, honours a custom base, and is capped', () => {
  assert.equal(backoffDelay(0, 1_000, 60_000), 1_000);
  assert.equal(backoffDelay(1, 1_000, 60_000), 2_000);
  assert.equal(backoffDelay(2, 1_000, 60_000), 4_000);
  assert.equal(backoffDelay(3, 1_000, 60_000), 8_000);
  assert.equal(backoffDelay(10, 1_000, 60_000), 60_000);
  assert.equal(backoffDelay(0, 0, 60_000), 0);
  assert.equal(backoffDelay(99, DEFAULT_AUTO_RETRY_BACKOFF_MS, AUTO_RETRY_BACKOFF_CAP_MS), AUTO_RETRY_BACKOFF_CAP_MS);
});

test('each retry waits for its own backoff window before the next one', () => {
  const first = planAutoRetry({
    status: 'blocked',
    cause: 'network_error',
    blockedAtMs: BLOCKED_AT,
    nowMs: at(200_000),
    graceMs: 120_000,
    backoffMs: 30_000,
  });
  assert.equal(first.action, 'retry');
  assert.equal(first.attempt, 1);

  const tooEarly = planAutoRetry({
    status: 'blocked',
    cause: 'network_error',
    blockedAtMs: BLOCKED_AT,
    lastRetryAtMs: at(200_000),
    attempts: 1,
    nowMs: at(200_000 + 15_000),
    graceMs: 120_000,
    backoffMs: 30_000,
  });
  assert.equal(tooEarly.action, 'wait');
  assert.equal(tooEarly.reason, 'backoff');
  // One attempt already spent, so the next window is base * 2^1.
  assert.equal(tooEarly.dueAtMs, at(200_000 + 60_000));

  const second = planAutoRetry({
    status: 'blocked',
    cause: 'network_error',
    blockedAtMs: BLOCKED_AT,
    lastRetryAtMs: at(200_000),
    attempts: 1,
    nowMs: at(200_000 + 60_000),
    graceMs: 120_000,
    backoffMs: 30_000,
  });
  assert.equal(second.action, 'retry');
  assert.equal(second.attempt, 2);
  // The second retry also reports the window that will precede a third one.
  assert.equal(second.delayMs, 60_000);
});

test('the budget is exhausted after N attempts and never retried again', () => {
  const exhausted = planAutoRetry({
    status: 'blocked',
    cause: 'provider_timeout',
    blockedAtMs: BLOCKED_AT,
    lastRetryAtMs: at(400_000),
    attempts: 3,
    maxAttempts: 3,
    nowMs: at(900_000),
  });
  assert.equal(exhausted.action, 'none');
  assert.equal(exhausted.reason, 'attempts_exhausted');
  assert.equal(exhausted.exhausted, true);
  assert.equal(exhausted.attempts, 3);
  assert.equal(exhausted.maxAttempts, 3);
});

test('a non-transient cause is never retried, whatever the clock says', () => {
  for (const cause of ['auth_error', 'provider_quota', 'needs_input', 'needs_permission']) {
    const plan = planAutoRetry({
      status: 'blocked',
      cause,
      blockedAtMs: BLOCKED_AT,
      nowMs: at(10 * DEFAULT_AUTO_RETRY_GRACE_MS),
    });
    assert.equal(plan.action, 'none', cause);
    assert.equal(plan.reason, 'non_transient', cause);
  }
});

test('an unknown cause and a non-blocked status are not retried', () => {
  assert.equal(planAutoRetry({
    status: 'blocked',
    cause: 'something_new',
    blockedAtMs: BLOCKED_AT,
    nowMs: at(10 * DEFAULT_AUTO_RETRY_GRACE_MS),
  }).reason, 'unknown_cause');

  for (const status of ['running', 'resuming', 'waiting', 'completed', 'failed']) {
    const plan = planAutoRetry({
      status,
      cause: 'provider_timeout',
      blockedAtMs: BLOCKED_AT,
      nowMs: at(10 * DEFAULT_AUTO_RETRY_GRACE_MS),
    });
    assert.equal(plan.action, 'none', status);
    assert.equal(plan.reason, 'not_blocked', status);
  }

  // Without a block timestamp there is no grace window to measure, so the
  // policy refuses instead of retrying immediately.
  assert.equal(planAutoRetry({
    status: 'blocked',
    cause: 'provider_timeout',
    blockedAtMs: null,
    nowMs: at(0),
  }).reason, 'unknown_block_time');
});

test('a rate-limit notice with retry-after is not retried before its own deadline', () => {
  assert.equal(retryAfterMs({ retry_after: 45 }), 45_000);
  assert.equal(retryAfterMs({ retryAfterMs: 1_500 }), 1_500);
  assert.equal(retryAfterMs({}), null);

  // Shorter than the grace period: the grace still wins.
  const graceWins = planAutoRetry({
    status: 'blocked',
    cause: 'rate_limit',
    blockedAtMs: BLOCKED_AT,
    retryAfterMs: retryAfterMs({ retry_after: 90 }),
    nowMs: at(DEFAULT_AUTO_RETRY_GRACE_MS - 1),
  });
  assert.equal(graceWins.action, 'wait');
  assert.equal(graceWins.dueAtMs, at(DEFAULT_AUTO_RETRY_GRACE_MS));

  // Longer than the grace period: the provider's own deadline wins, so a retry
  // is not spent on a guaranteed rejection.
  const tooEarly = planAutoRetry({
    status: 'blocked',
    cause: 'rate_limit',
    blockedAtMs: BLOCKED_AT,
    retryAfterMs: retryAfterMs({ retry_after: 300 }),
    nowMs: at(DEFAULT_AUTO_RETRY_GRACE_MS + 1_000),
  });
  assert.equal(tooEarly.action, 'wait');
  assert.equal(tooEarly.dueAtMs, at(300_000));

  const due = planAutoRetry({
    status: 'blocked',
    cause: 'rate_limit',
    blockedAtMs: BLOCKED_AT,
    retryAfterMs: retryAfterMs({ retry_after: 300 }),
    nowMs: at(300_000),
  });
  assert.equal(due.action, 'retry');
});

test('a spawn that exits 78 within seconds of launch is relaunched, up to the limit', () => {
  const first = planLaunchRetry({ exitCode: 78, startedAtMs: 1_000, endedAtMs: 4_000 });
  assert.equal(first.action, 'retry');
  assert.equal(first.attempt, 1);
  assert.equal(first.maxAttempts, DEFAULT_LAUNCH_RETRY_MAX_ATTEMPTS);

  const second = planLaunchRetry({ exitCode: 78, startedAtMs: 1_000, endedAtMs: 4_000, attempts: 1 });
  assert.equal(second.attempt, 2);
  assert.ok(second.delayMs > first.delayMs, 'relaunch backoff must grow');

  const exhausted = planLaunchRetry({
    exitCode: 78,
    startedAtMs: 1_000,
    endedAtMs: 4_000,
    attempts: DEFAULT_LAUNCH_RETRY_MAX_ATTEMPTS,
  });
  assert.equal(exhausted.action, 'none');
  assert.equal(exhausted.reason, 'attempts_exhausted');
});

test('other exit codes and a late 78 are task failures, not launch races', () => {
  assert.equal(planLaunchRetry({ exitCode: 1, startedAtMs: 1_000, endedAtMs: 4_000 }).reason, 'not_transient_exit');
  assert.equal(planLaunchRetry({ exitCode: 0, startedAtMs: 1_000, endedAtMs: 4_000 }).action, 'none');
  const slow = planLaunchRetry({
    exitCode: 78,
    startedAtMs: 1_000,
    endedAtMs: 1_000 + LAUNCH_RETRY_WINDOW_MS + 1,
  });
  assert.equal(slow.action, 'none');
  assert.equal(slow.reason, 'slow_exit');
});

test('retry attempts are counted per block, so recovery restores the budget', () => {
  const state = {
    retryAttempts: [
      { attempt: 1, episode: 1, at: '2026-10-22T12:01:00.000Z' },
      { attempt: 2, episode: 1, at: '2026-10-22T12:03:00.000Z' },
      { attempt: 1, episode: 2, at: '2026-10-22T12:09:00.000Z' },
    ],
  };
  assert.equal(attemptsForEpisode(state, 1).length, 2);
  assert.equal(attemptsForEpisode(state, 2).length, 1);
  assert.equal(attemptsForEpisode(state, 3).length, 0);
  assert.equal(attemptsForEpisode({}, 1).length, 0);
});

test('the policy object records every effective value', () => {
  const defaults = retryPolicy();
  assert.equal(defaults.enabled, false);
  assert.equal(defaults.graceMs, DEFAULT_AUTO_RETRY_GRACE_MS);
  assert.equal(defaults.maxAttempts, DEFAULT_AUTO_RETRY_MAX_ATTEMPTS);
  assert.equal(defaults.backoffMs, DEFAULT_AUTO_RETRY_BACKOFF_MS);
  const custom = retryPolicy({ enabled: true, graceMs: 10, maxAttempts: 2, backoffMs: 5, launchMaxAttempts: 1, launchBackoffMs: 7 });
  assert.deepEqual(custom, {
    enabled: true,
    graceMs: 10,
    maxAttempts: 2,
    backoffMs: 5,
    launchMaxAttempts: 1,
    launchBackoffMs: 7,
  });
});
