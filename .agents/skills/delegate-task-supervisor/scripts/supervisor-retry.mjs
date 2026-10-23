// Retry policy for the delegate supervisor.
//
// Two independent recoveries live here, both driven by a clock that is passed
// in so a test can use a fake one instead of sleeping:
//
// 1. A daemon session that stopped `blocked` on a transient cause (provider
//    timeout, network error, rate limit) is retried with `sanad session retry`.
//    The daemon spends its own automatic-retry budget before it reports
//    `blocked`, so a blocked worker needs an external caller to resume it.
// 2. A spawn that exits `78` ("Could not confirm a healthy Sanad daemon")
//    within seconds of launch never reached a turn; relaunching it is a launch
//    repair, not a failure of the task.
//
// Keeping the decisions pure (no fs, no child processes, no Date.now) is what
// makes grace, backoff, and exhaustion testable with a fake clock.

// A blocked task is left alone for a grace period first: a turn that recovers
// on its own must not be retried, and the daemon's own budget runs during the
// first seconds of a block.
export const DEFAULT_AUTO_RETRY_GRACE_MS = 180_000;
export const DEFAULT_AUTO_RETRY_MAX_ATTEMPTS = 3;
export const DEFAULT_AUTO_RETRY_BACKOFF_MS = 30_000;
export const AUTO_RETRY_BACKOFF_CAP_MS = 300_000;

// Causes a retry can plausibly clear. Anything else is not retried
// automatically: a wrong credential, an exhausted quota, a question, or a
// permission prompt needs a human, and retrying would only hide the cause.
export const TRANSIENT_BLOCK_CAUSES = new Set([
  'provider_timeout',
  'provider_timeout_error',
  'network_error',
  'networkError',
  'rate_limit',
  'rateLimit',
  'upstream_rate_limit',
  'upstreamRateLimit',
  'overloaded',
]);

// Documented refusals. They are listed explicitly so an operator reading the
// code sees the promise, and so the policy never depends on a cause simply
// being unknown.
export const NEVER_AUTO_RETRY_CAUSES = new Set([
  'auth_error',
  'provider_quota',
  'needs_input',
  'needs_permission',
]);

// Exit 78 is the CLI's own "the daemon is not healthy yet" signal. It is
// produced during the health pre-check, before any turn exists.
export const LAUNCH_RETRY_EXIT_CODE = 78;
export const DEFAULT_LAUNCH_RETRY_MAX_ATTEMPTS = 3;
export const DEFAULT_LAUNCH_RETRY_BACKOFF_MS = 2_000;
export const LAUNCH_RETRY_BACKOFF_CAP_MS = 30_000;
// "Within seconds of launch": a long turn that dies with 78 at the end is not a
// launch race, so it is never relaunched silently.
export const LAUNCH_RETRY_WINDOW_MS = 60_000;

/**
 * Exponential delay for the Nth retry (0-based): base, 2x base, 4x base, …
 */
export function backoffDelay(attemptIndex, baseMs, capMs) {
  const base = Number.isFinite(baseMs) && baseMs > 0 ? baseMs : 0;
  const cap = Number.isFinite(capMs) && capMs > 0 ? capMs : Number.POSITIVE_INFINITY;
  const exponent = Math.max(0, Math.min(30, Math.floor(attemptIndex)));
  return Math.min(cap, base * 2 ** exponent);
}

/**
 * What to do about one task's current block.
 *
 * `attempts` counts retries already sent for this block, and `lastRetryAtMs`
 * is when the newest one was sent (null before the first). The result is a
 * decision only; the caller journals and spawns.
 */
export function planAutoRetry({
  status,
  cause,
  blockedAtMs,
  lastRetryAtMs = null,
  attempts = 0,
  nowMs,
  graceMs = DEFAULT_AUTO_RETRY_GRACE_MS,
  maxAttempts = DEFAULT_AUTO_RETRY_MAX_ATTEMPTS,
  backoffMs = DEFAULT_AUTO_RETRY_BACKOFF_MS,
  retryAfterMs = null,
} = {}) {
  if (status !== 'blocked') return { action: 'none', reason: 'not_blocked' };
  if (NEVER_AUTO_RETRY_CAUSES.has(cause)) {
    return { action: 'none', reason: 'non_transient', cause };
  }
  if (!TRANSIENT_BLOCK_CAUSES.has(cause)) {
    return { action: 'none', reason: 'unknown_cause', cause: cause ?? null };
  }
  const now = Number(nowMs);
  if (!Number.isFinite(now) || !Number.isFinite(blockedAtMs)) {
    return { action: 'none', reason: 'unknown_block_time' };
  }
  // A rate-limit notice may publish its own retry-after; waiting less than that
  // guarantees a second rejection, so the grace period is the larger of the two.
  const waitMs = Math.max(
    Number.isFinite(graceMs) && graceMs > 0 ? graceMs : 0,
    Number.isFinite(retryAfterMs) && retryAfterMs > 0 ? retryAfterMs : 0,
  );
  const graceDueAt = blockedAtMs + waitMs;
  if (now < graceDueAt) return { action: 'wait', reason: 'grace', dueAtMs: graceDueAt };

  if (attempts >= maxAttempts) {
    return {
      action: 'none',
      reason: 'attempts_exhausted',
      exhausted: true,
      attempts,
      maxAttempts,
    };
  }

  if (Number.isFinite(lastRetryAtMs)) {
    const backoffDueAt = lastRetryAtMs + backoffDelay(attempts, backoffMs, AUTO_RETRY_BACKOFF_CAP_MS);
    if (now < backoffDueAt) return { action: 'wait', reason: 'backoff', dueAtMs: backoffDueAt };
  }

  const attempt = attempts + 1;
  return {
    action: 'retry',
    attempt,
    maxAttempts,
    delayMs: backoffDelay(attempts, backoffMs, AUTO_RETRY_BACKOFF_CAP_MS),
  };
}

/**
 * Whether a finished spawn is a transient launch failure worth relaunching.
 *
 * `startedAtMs`/`endedAtMs` bound the window; an unknown window is accepted
 * because exit 78 is itself the daemon-health signal and reporting a healthy
 * launch as a task failure is the worse error.
 */
export function planLaunchRetry({
  exitCode,
  startedAtMs = null,
  endedAtMs = null,
  attempts = 0,
  maxAttempts = DEFAULT_LAUNCH_RETRY_MAX_ATTEMPTS,
  backoffMs = DEFAULT_LAUNCH_RETRY_BACKOFF_MS,
  windowMs = LAUNCH_RETRY_WINDOW_MS,
} = {}) {
  if (exitCode !== LAUNCH_RETRY_EXIT_CODE) return { action: 'none', reason: 'not_transient_exit' };
  if (attempts >= maxAttempts) {
    return { action: 'none', reason: 'attempts_exhausted', attempts, maxAttempts };
  }
  if (Number.isFinite(startedAtMs) && Number.isFinite(endedAtMs)) {
    const elapsedMs = Math.max(0, endedAtMs - startedAtMs);
    if (elapsedMs > windowMs) return { action: 'none', reason: 'slow_exit', elapsedMs };
  }
  const attempt = attempts + 1;
  return {
    action: 'retry',
    attempt,
    maxAttempts,
    delayMs: backoffDelay(attempts, backoffMs, LAUNCH_RETRY_BACKOFF_CAP_MS),
  };
}

/**
 * The run's policy, with every value made explicit so the manifest and the
 * handshake never depend on a hidden default.
 */
export function retryPolicy({
  enabled = false,
  graceMs = DEFAULT_AUTO_RETRY_GRACE_MS,
  maxAttempts = DEFAULT_AUTO_RETRY_MAX_ATTEMPTS,
  backoffMs = DEFAULT_AUTO_RETRY_BACKOFF_MS,
  launchMaxAttempts = DEFAULT_LAUNCH_RETRY_MAX_ATTEMPTS,
  launchBackoffMs = DEFAULT_LAUNCH_RETRY_BACKOFF_MS,
} = {}) {
  return {
    enabled: enabled === true,
    graceMs,
    maxAttempts,
    backoffMs,
    launchMaxAttempts,
    launchBackoffMs,
  };
}

/**
 * A task's retries for the current block. A retry that succeeds ends the block,
 * so the next block starts a fresh budget instead of inheriting an exhausted one.
 */
export function attemptsForEpisode(taskState, episode) {
  const entries = Array.isArray(taskState?.retryAttempts) ? taskState.retryAttempts : [];
  return entries.filter((entry) => entry && entry.episode === episode);
}

/**
 * A retry-after hint from a blocking notice, in milliseconds (`retry_after`
 * seconds is the documented field; a millisecond field is accepted too).
 */
export function retryAfterMs(data) {
  if (!data || typeof data !== 'object') return null;
  const candidates = [data.retry_after_ms, data.retryAfterMs, data.retry_after, data.retryAfter];
  for (const candidate of candidates) {
    const value = Number(candidate);
    if (!Number.isFinite(value) || value <= 0) continue;
    // A bare `retry_after` is seconds in the provider contracts.
    const field = candidate === data.retry_after_ms || candidate === data.retryAfterMs;
    return Math.round(field ? value : value * 1000);
  }
  return null;
}
