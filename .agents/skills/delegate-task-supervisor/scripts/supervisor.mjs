#!/usr/bin/env node

import { spawn } from 'node:child_process';
import { closeSync, existsSync, mkdirSync, openSync } from 'node:fs';
import { isAbsolute, resolve } from 'node:path';

// Retry decisions (blocked-session retry and exit-78 launch relaunch) are pure
// and clock-injected, so grace, backoff, and exhaustion are testable without
// sleeping and both the CLI and the worker share one rule set.
import {
  DEFAULT_AUTO_RETRY_BACKOFF_MS,
  DEFAULT_AUTO_RETRY_GRACE_MS,
  DEFAULT_AUTO_RETRY_MAX_ATTEMPTS,
  DEFAULT_LAUNCH_RETRY_BACKOFF_MS,
  DEFAULT_LAUNCH_RETRY_MAX_ATTEMPTS,
  LAUNCH_RETRY_EXIT_CODE,
  retryPolicy,
} from './supervisor-retry.mjs';
// Follow decisions (deadline, snapshot interpretation, durable outcome) are pure
// for the same reason: a worker exits while its turn is still in flight, and the
// rule that keeps the task non-terminal must be testable without a daemon.
import {
  DEFAULT_FOLLOW_DEADLINE_MS,
  DEFAULT_FOLLOW_LOST_POLLS,
  DEFAULT_FOLLOW_POLL_MS,
  DEFAULT_FOLLOW_PROBE_TIMEOUT_MS,
  followPolicy,
} from './supervisor-follow.mjs';

// Command and surface owners. The entrypoint keeps the CLI contract — flag
// parsing, `HELP`, `start`, `main`, and the `__worker` composition root — and
// routes every command to the module that owns it.
import {
  fail,
  integerOption,
  publicTask,
  readJson,
  runPaths,
  secondsOption,
  writeJsonAtomic,
} from './supervisor-core.mjs';
import { identityCommand } from './supervisor-registry.mjs';
import { validateSpec } from './supervisor-spec.mjs';
import {
  CANCEL_FORCE_KILL_MS,
  SCRIPT_PATH,
  launchThroughWindowsExplorer,
  waitForWindowsWorkerHandshake,
  workerFollowArgs,
  workerRetryArgs,
  writeWindowsWorkerBroker,
} from './supervisor-windows.mjs';
import {
  addCommand,
  cancelCommand,
  closeCommand,
  continueCommand,
  enqueueCommand,
  observeLaunch,
  retryCommand,
  setConcurrencyCommand,
  steerCommand,
  verifyOption,
} from './supervisor-control.mjs';
import {
  DEFAULT_PROGRESS_STALL_MS,
  DEFAULT_QUEUED_STALL_MS,
  inspectCommand,
  logsCommand,
  statusCommand,
  timelineCommand,
  viewCommand,
} from './supervisor-views.mjs';
import { watchCommand } from './supervisor-watch.mjs';
// The worker's owners. `workerCommand` creates the one shared context and wires
// these onto it; the loop itself belongs to the scheduler.
import { createWorkerContext } from './supervisor-worker/context.mjs';
import { createReconciler } from './supervisor-worker/reconcile.mjs';
import { createScheduler } from './supervisor-worker/scheduler.mjs';
import { createLauncher } from './supervisor-worker/launcher.mjs';
import { createTimelineObserver } from './supervisor-worker/timeline.mjs';
import { createFollower } from './supervisor-worker/follower.mjs';
import { createSessionSupport } from './supervisor-worker/session.mjs';
import { createRequestHandler } from './supervisor-worker/requests.mjs';

const HELP = `delegate-task-supervisor

Usage:
  supervisor.mjs start --spec <tasks.json> --run-dir <absolute-dir> [--max-concurrency <n>] [--queued-stall-ms <n>] [--progress-stall-sec <n>] [--verify-sec <n>] [--auto-retry] [--auto-retry-grace-ms <n>] [--auto-retry-backoff-ms <n>] [--auto-retry-max-attempts <n>] [--follow-poll-ms <n>] [--follow-deadline-ms <n>] [--follow-lost-polls <n>] [--cancel-force-kill-ms <n>] [--close-when-idle]
  supervisor.mjs add --run <dir> --spec <tasks.json> [--json]
  supervisor.mjs enqueue --run <dir> (--task <id> | --tasks <id1,id2> | --spec <tasks.json>) [--verify-sec <n>] [--json]
  supervisor.mjs cancel --run <dir> --task <id> [--json]
  supervisor.mjs continue --run <dir> --task <id> --brief-file <path> [--new-session] [--verify-sec <n>] [--json]
  supervisor.mjs steer --run <dir> --task <id> (--message <text> | --message-file <path>) [--json]
  supervisor.mjs retry --run <dir> --task <id> [--provider <instance-id>] [--model <model-id>] [--json]
  supervisor.mjs set-concurrency --run <dir> --max <n> [--json]
  supervisor.mjs close --run <dir> [--abort-queued] [--wait] [--json]
  supervisor.mjs status (--run <dir> [--run <dir> ...]) [--brief] [--json] [--task <id>]
  supervisor.mjs watch --run <dir> [--run <dir> ...] --cursor <file> [--once] [--timeout-sec <n>] [--all] [--json]
  supervisor.mjs inspect --run <dir> --task <id>
  supervisor.mjs timeline --run <dir> --task <id> [--follow]
  supervisor.mjs logs --run <dir> --task <id> [--stream stdout|stderr|both] [--tail <n>] [--follow]
  supervisor.mjs view --run <dir> --task <id>
  supervisor.mjs identity --workspace <absolute-path>

Concurrency is always reported. When --max-concurrency is omitted, start uses
one slot per spec task (no artificial queueing) and prints the effective value as
\`maxConcurrency\` in its JSON handshake. Queued tasks report their position,
the active/max counts, and the reason they are waiting; \`status\` repeats that
for every queued task and flags a task that stalled past --queued-stall-ms
(default ${DEFAULT_QUEUED_STALL_MS}ms).

\`watch\` is the coordinator interface for several runs at once: it persists the
last handled sequence per run in --cursor, replays everything an orchestrator
missed, and prints exactly one line per actionable event (terminal states,
blocked/intervention, and stall notices). Plain progress is never a wake-up.
--once prints the current batch and exits, which suits an orchestrator that is
re-invoked when the watcher exits.

\`steer\` relays a mid-turn message to a running task's daemon session without
stopping it; \`continue\` re-dispatches a finished task as a numbered new attempt
with a delta brief. Both are journaled, and steering never records the message
body.

\`retry\` resumes a task the daemon left \`blocked\` or \`waiting\` by sending\n\`sanad session retry <session-id>\`, so a headless worker recovers the same way
the Client's Retry action does. With --auto-retry (or a per-task \"autoRetry\"
spec field) the supervisor applies the policy itself: a transient cause
(provider_timeout, network_error, rate_limit) blocked for longer than the grace
period (default ${DEFAULT_AUTO_RETRY_GRACE_MS}ms) is retried with exponential
backoff up to ${DEFAULT_AUTO_RETRY_MAX_ATTEMPTS} attempts, then reported as an
actionable \`retry_exhausted\`. auth_error, provider_quota, needs_input, and
needs_permission are never retried automatically. A spawn that exits
${LAUNCH_RETRY_EXIT_CODE} within seconds of launch is a launch race, not a task
failure, so it is relaunched up to ${DEFAULT_LAUNCH_RETRY_MAX_ATTEMPTS} times
with backoff before it counts as failed.

\`follow\`: when a Sanad worker exits while the daemon still owns its turn, the
task becomes \`following\` instead of \`failed\`. The worker polls
\`sanad session show <id> --json\` every --follow-poll-ms (default
${DEFAULT_FOLLOW_POLL_MS}ms) and journals the same transitions an attached
worker produces (needs_input, needs_permission, blocked, waiting, resuming,
completed, failed), so the automatic retry policy applies to a followed task
too. The follow window is the task's own --timeout, or --follow-deadline-ms
(default ${DEFAULT_FOLLOW_DEADLINE_MS}ms). After --follow-lost-polls (default
${DEFAULT_FOLLOW_LOST_POLLS}) consecutive unreadable session reads the task ends
\`follow_lost\` instead of blocking forever. Every attention state still wakes a
watcher; \`following\` itself is progress, never a wake-up. A followed turn is
\`completed\` only when its durable messages hold a final assistant reply; an
idle session without one ends \`failed\` with cause \`turn_interrupted\`.

\`process groups\`: every task is spawned as the leader of its own process group
(POSIX) and the group id is recorded as \`pgid\`. Cancel, the forced kill after
--cancel-force-kill-ms (default ${CANCEL_FORCE_KILL_MS}ms), and a graceful
supervisor shutdown signal the group, and an exit is only treated as a departure
after the group is verified empty. A group that outlives its direct child is
journaled as \`worker_group_alive\` and the follow names it
(\`worker_exited_group_alive\`) instead of claiming the turn lost its transport.
`;

const BOOLEAN_FLAGS = new Set([
  'follow',
  'json',
  'wait',
  'abort-queued',
  'brief',
  'once',
  'all',
  'close-when-idle',
  'new-session',
  'auto-retry',
]);

function parseOptions(argv) {
  const options = { _: [], runs: [] };
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (!token.startsWith('--')) {
      options._.push(token);
      continue;
    }
    const key = token.slice(2);
    if (BOOLEAN_FLAGS.has(key)) {
      options[key] = true;
      continue;
    }
    const value = argv[index + 1];
    if (value == null || value.startsWith('--')) fail(`missing value for ${token}`);
    if (key === 'run') {
      // `--run` repeats for the read-only commands (`status`, `watch`). The
      // single-run commands read `options.run` and fail closed when a caller
      // passes more than one.
      options.runs.push(value);
      if (options.run == null) options.run = value;
    } else {
      options[key] = value;
    }
    index += 1;
  }
  return options;
}

async function startCommand(options) {
  if (!options.spec || !options['run-dir']) fail('start requires --spec and --run-dir');
  if (!isAbsolute(options['run-dir'])) fail('--run-dir must be absolute');
  const runDir = resolve(options['run-dir']);
  const paths = runPaths(runDir);
  mkdirSync(runDir, { recursive: true });
  mkdirSync(paths.requests, { recursive: true });
  if (existsSync(paths.manifest) || existsSync(paths.journal)) {
    fail(`run directory already contains supervisor state: ${runDir}`);
  }
  const spec = readJson(resolve(options.spec), 'task spec');
  const tasks = validateSpec(spec);
  // Concurrency is never a hidden default: the effective value is validated,
  // persisted, and printed by `start`. Omitting the flag means one slot per spec
  // task, so a fresh run never silently queues behind a single slot.
  const maxConcurrency = options['max-concurrency'] == null
    ? Math.max(1, tasks.length)
    : Number(options['max-concurrency']);
  if (!Number.isInteger(maxConcurrency) || maxConcurrency < 1) {
    fail('--max-concurrency must be a positive integer');
  }
  const queuedStallMs = options['queued-stall-ms'] == null
    ? DEFAULT_QUEUED_STALL_MS
    : Number(options['queued-stall-ms']);
  if (!Number.isInteger(queuedStallMs) || queuedStallMs < 1) {
    fail('--queued-stall-ms must be a positive integer');
  }
  // The silence threshold is a run-level default that a spec may override per
  // task. `--progress-stall-ms` exists for compressed-time diagnosis and tests.
  const progressStallMs = options['progress-stall-ms'] == null
    ? secondsOption(options, 'progress-stall-sec', DEFAULT_PROGRESS_STALL_MS, '--progress-stall-sec')
    : Number(options['progress-stall-ms']);
  if (!Number.isInteger(progressStallMs) || progressStallMs < 1) {
    fail('--progress-stall-ms must be a positive integer');
  }
  const verifyMs = verifyOption(options);
  const closeWhenIdle = options['close-when-idle'] === true;
  // `--auto-retry` enables the policy for the whole run; a spec may enable or
  // disable it per task, and only an enabling default is inherited.
  const autoRetry = retryPolicy({
    enabled: options['auto-retry'] === true || spec.autoRetry === true,
    graceMs: integerOption(options, 'auto-retry-grace-ms', DEFAULT_AUTO_RETRY_GRACE_MS, '--auto-retry-grace-ms', 1),
    maxAttempts: integerOption(options, 'auto-retry-max-attempts', DEFAULT_AUTO_RETRY_MAX_ATTEMPTS, '--auto-retry-max-attempts', 1),
    backoffMs: integerOption(options, 'auto-retry-backoff-ms', DEFAULT_AUTO_RETRY_BACKOFF_MS, '--auto-retry-backoff-ms', 1),
    launchMaxAttempts: integerOption(options, 'launch-retry-max-attempts', DEFAULT_LAUNCH_RETRY_MAX_ATTEMPTS, '--launch-retry-max-attempts', 0),
    launchBackoffMs: integerOption(options, 'launch-retry-backoff-ms', DEFAULT_LAUNCH_RETRY_BACKOFF_MS, '--launch-retry-backoff-ms', 1),
  });
  // Following a daemon-owned turn is part of the run's contract, so its window
  // and cadence are reported by the handshake instead of living in the worker.
  const follow = followPolicy({
    pollMs: integerOption(options, 'follow-poll-ms', DEFAULT_FOLLOW_POLL_MS, '--follow-poll-ms', 1),
    deadlineMs: integerOption(options, 'follow-deadline-ms', DEFAULT_FOLLOW_DEADLINE_MS, '--follow-deadline-ms', 1),
    lostAfterPolls: integerOption(options, 'follow-lost-polls', DEFAULT_FOLLOW_LOST_POLLS, '--follow-lost-polls', 1),
    probeTimeoutMs: integerOption(options, 'follow-probe-timeout-ms', DEFAULT_FOLLOW_PROBE_TIMEOUT_MS, '--follow-probe-timeout-ms', 1),
  });
  const startedAt = new Date().toISOString();
  // The grace window between the cancelling SIGTERM and the forced SIGKILL. It
  // is reported by the handshake and passed to the worker, so a compressed value
  // in a test or a diagnosis is the same value everywhere.
  const cancelForceKillMs = integerOption(options, 'cancel-force-kill-ms', CANCEL_FORCE_KILL_MS, '--cancel-force-kill-ms', 1);
  writeJsonAtomic(paths.tasks, { version: 'delegate-task-spec.v1', tasks });
  writeJsonAtomic(paths.manifest, {
    version: 'delegate-supervisor.v1',
    runDir,
    supervisorPid: null,
    status: 'starting',
    closed: false,
    seq: 0,
    startedAt,
    finishedAt: null,
    maxConcurrency,
    active: 0,
    queuedStallMs,
    progressStallMs,
    autoRetry,
    follow,
    cancelForceKillMs,
    closeWhenIdle,
    queueSeq: tasks.length,
    tasks: Object.fromEntries(tasks.map((task, index) => [task.id, {
      ...publicTask(task, runDir, 'queued'),
      queuedAt: startedAt,
      queuedSeq: index + 1,
    }])),
  });

  if (process.platform === 'win32') {
    try {
      const brokerPath = writeWindowsWorkerBroker(runDir, paths, maxConcurrency, queuedStallMs, progressStallMs, autoRetry, follow, closeWhenIdle, cancelForceKillMs);
      launchThroughWindowsExplorer(brokerPath);
      const running = waitForWindowsWorkerHandshake(paths);
      const verification = await observeLaunch(runDir, tasks.map((task) => task.id), { verifyMs });
      process.stdout.write(`${JSON.stringify({
        runDir,
        supervisorPid: running.supervisorPid,
        cursor: 0,
        maxConcurrency,
        queuedStallMs,
        progressStallMs,
        autoRetry,
        follow,
        cancelForceKillMs,
        closeWhenIdle,
        tasks: tasks.length,
        verification,
      })}\n`);
      if (verification.spawnFailed.length) process.exit(1);
    } catch (error) {
      fail(error.message, 1);
    }
    return;
  }

  const logFd = openSync(paths.supervisorLog, 'a');
  const child = spawn(process.execPath, [
    SCRIPT_PATH,
    '__worker',
    '--run', runDir,
    '--max-concurrency', String(maxConcurrency),
    '--queued-stall-ms', String(queuedStallMs),
    '--progress-stall-ms', String(progressStallMs),
    ...workerRetryArgs(autoRetry),
    ...workerFollowArgs(follow),
    '--cancel-force-kill-ms', String(cancelForceKillMs),
    ...(closeWhenIdle ? ['--close-when-idle'] : []),
  ], {
    detached: true,
    windowsHide: true,
    stdio: ['ignore', logFd, logFd],
  });
  closeSync(logFd);
  child.unref();
  // A launch is only reported after it is observed: every submitted task must
  // be running, honestly queued behind busy slots, or visibly failed.
  const verification = await observeLaunch(runDir, tasks.map((task) => task.id), { verifyMs });
  process.stdout.write(`${JSON.stringify({
    runDir,
    supervisorPid: child.pid,
    cursor: 0,
    maxConcurrency,
    queuedStallMs,
    progressStallMs,
    autoRetry,
    follow,
    cancelForceKillMs,
    closeWhenIdle,
    tasks: tasks.length,
    verification,
  })}\n`);
  if (verification.spawnFailed.length) process.exit(1);
}

// `__worker` is the run's only executing process, and this is its composition
// root: it creates the one shared context, attaches every owner to it, and then
// starts the loop. Construction is inert — no owner runs, no timer is armed, and
// no peer is called until `runWorker` — so the wiring order below is unobservable.
// A factory may only add members: the state lives on the context, so a colliding
// key would silently replace a counter or another owner's surface, and the loop
// refuses to start with one.
function workerCommand(options) {
  const ctx = createWorkerContext(options);
  const surfaces = [
    createReconciler(ctx),
    createScheduler(ctx),
    createLauncher(ctx),
    createTimelineObserver(ctx),
    createFollower(ctx),
    createSessionSupport(ctx),
    createRequestHandler(ctx),
  ];
  for (const surface of surfaces) {
    for (const [key, value] of Object.entries(surface)) {
      if (Object.hasOwn(ctx, key)) fail(`internal worker wiring collision: ${key}`);
      ctx[key] = value;
    }
  }
  ctx.runWorker();
}

async function main() {
  const [command, ...rest] = process.argv.slice(2);
  if (!command || command === '-h' || command === '--help') {
    process.stdout.write(HELP);
    return;
  }
  const options = parseOptions(rest);
  switch (command) {
    case 'start': await startCommand(options); break;
    case '__worker': workerCommand(options); break;
    case 'add': await addCommand(options); break;
    case 'enqueue': await enqueueCommand(options); break;
    case 'cancel': await cancelCommand(options); break;
    case 'continue': await continueCommand(options); break;
    case 'steer': await steerCommand(options); break;
    case 'retry': await retryCommand(options); break;
    case 'watch': await watchCommand(options); break;
    case 'set-concurrency': await setConcurrencyCommand(options); break;
    case 'close': await closeCommand(options); break;
    case 'status': statusCommand(options); break;
    case 'inspect': inspectCommand(options); break;
    case 'timeline': timelineCommand(options); break;
    case 'logs': logsCommand(options); break;
    case 'view': viewCommand(options); break;
    case 'identity': identityCommand(options); break;
    default: fail(`unknown command: ${command}\n${HELP}`);
  }
}

await main().catch((error) => fail(error.message, 1));
