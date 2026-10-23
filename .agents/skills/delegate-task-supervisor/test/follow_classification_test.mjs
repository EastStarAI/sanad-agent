// The follow classifier is pure, so the four readings that used to collapse into
// `failed` are tested without a daemon:
//
// 1. a retryable failure with budget left is `retrying` (live progress);
// 2. an exhausted budget is `blocked` (a coordinator decision);
// 3. a non-retryable failure is `blocked` immediately;
// 4. `resuming` keeps its own meaning.
//
// 2026-10-23: a provider timeout with a scheduled retry was published as
// `blocked`, so `sanad run` exited 1 and the supervisor recorded `failed` while
// the daemon resumed the same turn seconds later.

import assert from 'node:assert/strict';
import test from 'node:test';

import {
  autoRetryFacts,
  followOutcome,
  interpretSessionSnapshot,
} from '../scripts/supervisor-follow.mjs';

const timeoutNotice = (overrides = {}) => ({
  session_id: 'sess-1',
  status: 'waiting',
  reason: 'timeout',
  title: 'Request timed out',
  message: 'The request took too long to complete.',
  retry_attempt: 1,
  retry_budget: 1,
  retry_after_ms: 2000,
  resume_at: '2026-10-23T06:57:03.000Z',
  ...overrides,
});

const summary = ({ users = 1, replies = 0 } = {}) => ({
  message_count: users + replies + 3,
  user_messages: users,
  final_answers: replies,
  tool_calls: 1,
  tool_results: 1,
});

test('a waiting notice is an automatic retry, with its counters', () => {
  const facts = autoRetryFacts(timeoutNotice(), 'waiting');
  assert.equal(facts.pending, true);
  assert.equal(facts.attempt, 1);
  assert.equal(facts.budget, 1);
  assert.equal(facts.budgetLeft, false);
  assert.equal(facts.label, 'retrying (1/1)');
});

test('a blocked notice with budget left is still a retry in progress', () => {
  // Older projections published the retryable failure as blocked while the
  // attempt was scheduled. The counters are what tell the two apart.
  const facts = autoRetryFacts(
    timeoutNotice({ status: 'blocked', retry_attempt: 1, retry_budget: 3 }),
    'blocked',
  );
  assert.equal(facts.pending, true);
  assert.equal(facts.label, 'retrying (1/3)');
});

test('a blocked notice whose budget is spent is not a retry', () => {
  const facts = autoRetryFacts(
    timeoutNotice({ status: 'blocked', retry_attempt: 1, retry_budget: 1 }),
    'blocked',
  );
  assert.equal(facts.pending, false);
  assert.equal(facts.budgetLeft, false);
});

test('a non-retryable failure publishes no counters and is not a retry', () => {
  const facts = autoRetryFacts(
    { session_id: 'sess-1', status: 'blocked', reason: 'auth', message: 'Authentication failed' },
    'blocked',
  );
  assert.equal(facts.pending, false);
  assert.equal(facts.attempt, null);
  assert.equal(facts.budget, null);
  assert.equal(facts.label, 'retrying');
});

test('a fatal notice is never reported as a retry, even with budget left', () => {
  const facts = autoRetryFacts(
    timeoutNotice({ status: 'fatal', retry_attempt: 1, retry_budget: 3 }),
    'blocked',
  );
  assert.equal(facts.pending, false);
});

test('a durable waiting state with no notice is still an automatic retry', () => {
  const facts = autoRetryFacts(null, 'waiting');
  assert.equal(facts.pending, true);
  assert.equal(facts.label, 'retrying');
});

test('the snapshot of a retrying turn is a live retry, not a block', () => {
  const snapshot = interpretSessionSnapshot({
    session_id: 'sess-1',
    status: 'retrying',
    execution_snapshot: { state: 'waiting' },
    runtime_notice: timeoutNotice(),
    summary: summary(),
  });
  assert.equal(snapshot.kind, 'retrying');
  assert.equal(snapshot.status, 'retrying');
  assert.equal(snapshot.executionState, 'waiting');
  assert.equal(snapshot.retry.attempt, 1);
  assert.equal(snapshot.retry.budget, 1);
  assert.equal(snapshot.retry.reason, 'timeout');
  assert.equal(snapshot.retryAfterMs, 2000);
});

test('the snapshot of an exhausted retry is blocked, unchanged', () => {
  const snapshot = interpretSessionSnapshot({
    session_id: 'sess-1',
    status: 'blocked',
    execution_snapshot: { state: 'blocked' },
    runtime_notice: timeoutNotice({ status: 'blocked' }),
    summary: summary(),
  });
  assert.equal(snapshot.kind, 'blocked');
  assert.equal(snapshot.retry.pending, false);
});

test('the snapshot of a non-retryable failure is blocked immediately', () => {
  const snapshot = interpretSessionSnapshot({
    session_id: 'sess-1',
    status: 'blocked',
    execution_snapshot: { state: 'blocked' },
    runtime_notice: { session_id: 'sess-1', status: 'blocked', reason: 'auth', message: 'Authentication failed' },
    summary: summary(),
  });
  assert.equal(snapshot.kind, 'blocked');
  assert.equal(snapshot.retry.reason, 'auth');
  assert.equal(snapshot.retry.pending, false);
});

test('resuming keeps its own kind instead of becoming a retry', () => {
  const snapshot = interpretSessionSnapshot({
    session_id: 'sess-1',
    status: 'resuming',
    execution_snapshot: { state: 'resuming' },
    runtime_notice: { session_id: 'sess-1', status: 'resuming', reason: 'retrying' },
    summary: summary(),
  });
  assert.equal(snapshot.kind, 'resuming');
});

test('a pending question outranks the retry counters', () => {
  const snapshot = interpretSessionSnapshot({
    session_id: 'sess-1',
    status: 'needs_input',
    execution_snapshot: { state: 'waiting' },
    runtime_notice: timeoutNotice(),
    summary: summary(),
    pending_permission_request: {
      request_id: 'req-1',
      tool_name: 'system_ask_user',
      questions: [{ question: 'Which provider?' }],
    },
  });
  assert.equal(snapshot.kind, 'intervention');
  assert.equal(snapshot.status, 'needs_input');
});

test('a turn observed retrying completes only when the durable counts prove a reply', () => {
  const finished = followOutcome({
    lastLive: 'retrying',
    cause: 'timeout',
    evidence: { source: 'summary', finalAnswers: 1, userMessages: 1 },
    baseline: { finalAnswers: 0, userMessages: 1 },
  });
  assert.equal(finished.status, 'completed');
  assert.equal(finished.resultSource, 'daemon_session');

  const interrupted = followOutcome({
    lastLive: 'retrying',
    cause: 'timeout',
    evidence: { source: 'summary', finalAnswers: 0, userMessages: 1 },
    baseline: { finalAnswers: 0, userMessages: 1 },
  });
  assert.equal(interrupted.status, 'failed');
  assert.equal(interrupted.cause, 'timeout');
});

test('a turn that ended blocked is still a failure with the block cause', () => {
  const outcome = followOutcome({
    lastLive: 'blocked',
    cause: 'timeout',
    evidence: { source: 'summary', finalAnswers: 0, userMessages: 1 },
  });
  assert.equal(outcome.status, 'failed');
  assert.equal(outcome.cause, 'timeout');
  assert.equal(outcome.note, 'the durable turn ended while blocked; no recovery resumed it');
});
