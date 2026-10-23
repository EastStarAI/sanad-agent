#!/usr/bin/env node

import { spawn } from 'node:child_process';
import {
  appendFileSync,
  closeSync,
  existsSync,
  mkdirSync,
  openSync,
  readFileSync,
  readSync,
  readdirSync,
  renameSync,
  statSync,
  unlinkSync,
  watch,
  writeFileSync,
  writeSync,
} from 'node:fs';
import { basename, dirname, isAbsolute, join, resolve } from 'node:path';

// Journal vocabulary is shared with `watch-once.mjs` so both readers agree on
// which records deserve an orchestrator wake-up.
import { TERMINAL_STATUSES } from './supervisor-events.mjs';
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
  attemptsForEpisode,
  planAutoRetry,
  planLaunchRetry,
  retryAfterMs,
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
  followDeadlineMsFor,
  followOutcome,
  followPolicy,
  followPollMsFor,
  interpretSessionSnapshot,
  parseSessionShowOutput,
} from './supervisor-follow.mjs';

// Command and surface owners. The entrypoint keeps the CLI contract — flag
// parsing, `HELP`, `main`, and the worker — and routes every command to the
// module that owns it.
import {
  DEFAULT_PROGRESS_STALL_MS,
  DEFAULT_QUEUED_STALL_MS,
  describeQueuedTask,
  fail,
  formatShortDuration,
  getArgValue,
  parseIsoMillis,
  processIsAlive,
  progressThresholdMs,
  queueOutcomes,
  queueSnapshot,
  readJson,
  readResultDigest,
  secondsOption,
  sha256,
  sleepSync,
  writeJsonAtomic,
} from './supervisor-core.mjs';
import {
  identityCommand,
  recordIdentity,
  runPaths,
  taskRunPaths,
  withRunPaths,
} from './supervisor-registry.mjs';
import { SANAD_CLIENT_COMMAND, validateSpec } from './supervisor-spec.mjs';
import {
  CANCEL_FORCE_KILL_MS,
  SCRIPT_PATH,
  launchThroughWindowsExplorer,
  waitForWindowsWorkerHandshake,
  windowsBatchQuote,
  workerFollowArgs,
  workerRetryArgs,
  writeWindowsWorkerBroker,
} from './supervisor-windows.mjs';
import {
  RETRYABLE_TASK_STATUSES,
  RETRY_TIMEOUT_MS,
  STEER_TIMEOUT_MS,
  addCommand,
  cancelCommand,
  closeCommand,
  continueCommand,
  enqueueCommand,
  normalizeRetryRoute,
  observeLaunch,
  retryCommand,
  setConcurrencyCommand,
  steerCommand,
  verifyOption,
} from './supervisor-control.mjs';
import {
  inspectCommand,
  logsCommand,
  statusCommand,
  timelineCommand,
  viewCommand,
} from './supervisor-views.mjs';
import { watchCommand } from './supervisor-watch.mjs';

// Remote delegation through `sanad-client` reports the relayed CLI exit code
// instead of a locally produced `result.json` status, so the supervisor owns
// this mapping. 69 (no live Client for the Home) and 77 (Client CLI disabled)
// mean the task never started on the target device and needs operator action,
// so both surface as blocked with the Client's own diagnostic as the cause.
const REMOTE_EXIT_STATUSES = new Map([
  [124, { status: 'timeout', cause: 'timeout' }],
  [130, { status: 'cancelled', cause: 'cancelled' }],
  [69, { status: 'blocked', cause: 'client_unavailable' }],
  [77, { status: 'blocked', cause: 'client_cli_disabled' }],
]);
// `sanad session retry` exit codes (B5 contract). The supervisor reports the
// daemon's own verdict instead of inventing one: `retrying` means the recovery
// transition was acknowledged, `not_blocked` means nothing was sent.
const RETRY_EXIT_OUTCOMES = new Map([
  [0, 'retrying'],
  [1, 'transport_error'],
  [3, 'not_blocked'],
  [4, 'rejected'],
  [5, 'unacknowledged'],
  [8, 'state_unreadable'],
]);
const STALL_CHECK_MIN_MS = 200;
const STALL_CHECK_MAX_MS = 15_000;
// Control requests are picked up by a watcher and, as a guarantee, by this
// bounded rescan: a missed filesystem event must not strand a cancelled or
// closed run until its deadline.
const REQUEST_RESCAN_MS = 500;
// A forced kill is verified after this delay: a process the kernel just SIGKILLed
// is still visible until its parent reaps it, and that is not a survivor.
const GROUP_KILL_VERIFY_MS = 250;
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

// Compressed-time switches take milliseconds directly so a test can exercise a
// three-minute grace period in a fraction of a second.
function integerOption(options, key, defaultValue, label, minimum = 0) {
  if (options[key] == null) return defaultValue;
  const value = Number(options[key]);
  if (!Number.isInteger(value) || value < minimum) {
    fail(`${label} must be an integer >= ${minimum}`);
  }
  return value;
}

// The terminal `--json` envelope relayed on stdout is the remote task result:
// a compact JSON object without a `type` field that carries the relayed exit
// code (and normally the session identity). Relayed lifecycle events always
// carry `type`, so they can never be mistaken for the envelope.
function lastRemoteEnvelope(content) {
  const accept = (value) => value != null
    && typeof value === 'object'
    && !Array.isArray(value)
    && !('type' in value)
    && (typeof value.exit_code === 'number' || typeof value.session_id === 'string');
  const lines = content.split(/\r?\n/);
  for (let index = lines.length - 1; index >= 0; index -= 1) {
    const line = lines[index].trim();
    if (!line.startsWith('{') || !line.endsWith('}')) continue;
    let parsed;
    try {
      parsed = JSON.parse(line);
    } catch {
      continue;
    }
    if (accept(parsed)) return parsed;
  }
  // A client that pretty-prints the envelope still produces one JSON document.
  const trimmed = content.trim();
  if (trimmed.startsWith('{')) {
    try {
      const parsed = JSON.parse(trimmed);
      if (accept(parsed)) return parsed;
    } catch {
      // Mixed stdout: only the line scan can succeed.
    }
  }
  return null;
}

function captureRemoteResult(task) {
  if (!task.resultPath || !task.stdoutPath || !existsSync(task.stdoutPath)) return;
  let content;
  try {
    content = readFileSync(task.stdoutPath, 'utf8');
  } catch {
    return;
  }
  const envelope = lastRemoteEnvelope(content);
  if (!envelope) return;
  writeJsonAtomic(task.resultPath, envelope);
}

// The Client CLI writes its unreachable/disabled diagnostics to stderr; the
// last line is the operator-facing cause behind a blocked remote task.
function lastDiagnosticLine(path) {
  if (!path || !existsSync(path)) return null;
  let content;
  try {
    content = readFileSync(path, 'utf8');
  } catch {
    return null;
  }
  const line = content.split(/\r?\n/).map((entry) => entry.trim()).filter(Boolean).at(-1) ?? null;
  if (!line) return null;
  return line.length > 400 ? `${line.slice(0, 397)}...` : line;
}

function lastNonEmptyLine(value) {
  if (typeof value !== 'string') return null;
  const lines = value.split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
  return lines.length ? lines.at(-1) : null;
}

// A CLI command prints one `--json` envelope as the last stdout line; reading a
// field from it keeps the supervisor's journal correlated with the CLI's own
// request id instead of the supervisor's guess.
function lastJsonField(stdout, keys) {
  const last = lastNonEmptyLine(stdout);
  if (!last || !last.startsWith('{')) return null;
  let parsed;
  try {
    parsed = JSON.parse(last);
  } catch {
    return null;
  }
  for (const key of keys) {
    const value = parsed?.[key];
    if (typeof value === 'string' && value.trim()) return value.trim();
  }
  return null;
}

/**
 * The coordinator's triage view of one task's `result.json`.
 *
 * `sanad run` writes the versioned artifact (status, exit_code, text, ...);
 * wrapper tasks may additionally publish `branch`, `head_sha`, and `pr_url`.
 * Reading them here means a completion line already carries everything needed
 * to decide the next step, without a second call.
 */
function followResultDigest(outcome, state, finishedAt) {
  if (!outcome?.status) return null;
  return {
    status: outcome.status,
    source: outcome.resultSource ?? 'daemon_session',
    sessionId: state?.sessionId ?? null,
    cause: outcome.cause ?? null,
    error: outcome.error ?? null,
    text: outcome.note ?? null,
    endedAt: finishedAt,
  };
}

/**
 * The visible result of one task, and what a `result.json` on its path means for
 * it.
 *
 * A terminal artifact belongs to the task when it was produced inside the
 * task's own window. A followed task is the one exception: its verdict was read
 * from the durable session, so an artifact written afterwards is triage evidence
 * (`laterResult`) and never the task's result.
 */
// The delta brief replaces the task's declared brief input. Only documented
// brief flags are rewritten so an arbitrary argument list is never guessed at.
function replaceBriefArgument(args, briefPath) {
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === '--brief-file' || arg === '-b' || arg === '--prompt-file') {
      if (index + 1 >= args.length) return null;
      return {
        flag: arg,
        args: [...args.slice(0, index + 1), briefPath, ...args.slice(index + 2)],
      };
    }
    for (const flag of ['--brief-file=', '--prompt-file=']) {
      if (arg.startsWith(flag)) {
        return {
          flag,
          args: [...args.slice(0, index), `${flag}${briefPath}`, ...args.slice(index + 1)],
        };
      }
    }
  }
  return null;
}

// `--new-session` drops the session pins so the next attempt starts a fresh
// daemon session instead of resuming the finished one.
function stripSessionArguments(args) {
  const stripped = [];
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === '--session' || arg === '-s') {
      index += 1;
      continue;
    }
    if (arg.startsWith('--session=') || arg === '--continue') continue;
    stripped.push(arg);
  }
  return stripped;
}

function publicTask(task, runDir, initialStatus = 'queued') {
  const derived = taskRunPaths(task, runDir);
  return {
    id: task.id,
    implementer: task.implementer,
    workspace: task.workspace,
    sourceRoot: task.sourceRoot ?? null,
    home: task.home ?? null,
    spawnCwd: task.spawnCwd ?? task.workspace,
    remote: task.remote ?? false,
    remoteDevice: task.remoteDevice ?? null,
    status: initialStatus,
    pid: null,
    startedAt: null,
    finishedAt: null,
    exitCode: null,
    signal: null,
    resultPath: derived.resultPath,
    timelinePath: derived.timelinePath,
    timelineFormat: task.timelineFormat,
    stdoutPath: derived.stdoutPath,
    stderrPath: derived.stderrPath,
    knownIdentity: task.knownIdentity,
    identity: null,
    // A task is one identity with numbered attempts: every `continue` adds an
    // entry here and archives the previous attempt's artifacts.
    attempt: 1,
    attempts: [],
    // Retry bookkeeping: `retryEpisode` numbers each distinct block so a retry
    // that recovers the turn does not leave the next block with no budget.
    retryEpisode: 0,
    retryAttempts: [],
    launchRetries: [],
    nextRetryAt: null,
    retryExhaustedAt: null,
    autoRetry: task.autoRetry ?? null,
    sessionId: null,
    lastProgressAt: null,
    progressStall: null,
    progressStallMs: task.progressStallMs ?? null,
  };
}

// A worker with a declared task Home receives that Home in its environment as
// well as through `--home`: `SANAD_HOME` names it, and an inherited
// `SANAD_STATE_HOME` is removed so runtime state resolves inside the same Home
// (the worktree Home model). Nothing the worker starts can then fall back to
// the caller's Home, even before it parses `--home`.
function taskEnvironment(task, baseEnv) {
  if (!task.home) return baseEnv;
  const env = { ...baseEnv, SANAD_HOME: task.home };
  delete env.SANAD_STATE_HOME;
  return env;
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

// Commands are spawned directly except Windows `.cmd`/`.bat` wrappers, which
// need Node's shell mode after shell metacharacters have been rejected at
// validation time. Both task launches and session-stop requests share it.
function spawnCommand(command, args, spawnOptions) {
  const isBatch = process.platform === 'win32' && /\.(cmd|bat)$/i.test(command);
  if (!isBatch) return spawn(command, args, spawnOptions);
  const batchCommand = [command, ...args].map(windowsBatchQuote).join(' ');
  return spawn(
    process.env.ComSpec || 'cmd.exe',
    ['/d', '/s', '/c', `"${batchCommand}"`],
    { ...spawnOptions, windowsVerbatimArguments: true },
  );
}

function workerCommand(options) {
  const runDir = resolve(options.run || '');
  let maxConcurrency = Number(options['max-concurrency']);
  const queuedStallMs = options['queued-stall-ms'] == null
    ? DEFAULT_QUEUED_STALL_MS
    : Number(options['queued-stall-ms']);
  let progressStallMs = options['progress-stall-ms'] == null
    ? DEFAULT_PROGRESS_STALL_MS
    : Number(options['progress-stall-ms']);
  if (!runDir
    || !Number.isInteger(maxConcurrency) || maxConcurrency < 1
    || !Number.isInteger(progressStallMs) || progressStallMs < 1
    || !Number.isInteger(queuedStallMs) || queuedStallMs < 1) {
    fail('invalid internal worker invocation');
  }
  const closeWhenIdle = options['close-when-idle'] === true;
  // The grace window the run was started with: cancel and the forced kill use it,
  // so a compressed value never has to be re-derived in the worker.
  const cancelForceKillMs = integerOption(options, 'cancel-force-kill-ms', CANCEL_FORCE_KILL_MS, '--cancel-force-kill-ms', 1);
  // The policy the run was started with. Every value is explicit here so the
  // worker never re-derives a default the handshake did not report.
  const autoRetry = retryPolicy({
    enabled: options['auto-retry'] === true,
    graceMs: integerOption(options, 'auto-retry-grace-ms', DEFAULT_AUTO_RETRY_GRACE_MS, '--auto-retry-grace-ms', 1),
    maxAttempts: integerOption(options, 'auto-retry-max-attempts', DEFAULT_AUTO_RETRY_MAX_ATTEMPTS, '--auto-retry-max-attempts', 1),
    backoffMs: integerOption(options, 'auto-retry-backoff-ms', DEFAULT_AUTO_RETRY_BACKOFF_MS, '--auto-retry-backoff-ms', 1),
    launchMaxAttempts: integerOption(options, 'launch-retry-max-attempts', DEFAULT_LAUNCH_RETRY_MAX_ATTEMPTS, '--launch-retry-max-attempts', 0),
    launchBackoffMs: integerOption(options, 'launch-retry-backoff-ms', DEFAULT_LAUNCH_RETRY_BACKOFF_MS, '--launch-retry-backoff-ms', 1),
  });
  // The follow policy the run was started with. A task whose worker exits while
  // its daemon turn is still in flight is followed with exactly these bounds.
  const followPolicyConfig = followPolicy({
    pollMs: integerOption(options, 'follow-poll-ms', DEFAULT_FOLLOW_POLL_MS, '--follow-poll-ms', 1),
    deadlineMs: integerOption(options, 'follow-deadline-ms', DEFAULT_FOLLOW_DEADLINE_MS, '--follow-deadline-ms', 1),
    lostAfterPolls: integerOption(options, 'follow-lost-polls', DEFAULT_FOLLOW_LOST_POLLS, '--follow-lost-polls', 1),
    probeTimeoutMs: integerOption(options, 'follow-probe-timeout-ms', DEFAULT_FOLLOW_PROBE_TIMEOUT_MS, '--follow-probe-timeout-ms', 1),
  });
  const paths = runPaths(runDir);
  mkdirSync(paths.requests, { recursive: true });
  const initialTasks = readJson(paths.tasks, 'normalized tasks').tasks
    .map((task) => withRunPaths(task, runDir));
  const taskMap = new Map(initialTasks.map((task) => [task.id, task]));
  const taskList = [...initialTasks];

  let seq = 0;
  let active = 0;
  let queueSeq = initialTasks.length;
  const settled = new Set();
  const timelineWatchers = new Map();
  const children = new Map();
  const forceKillTimers = new Map();
  // Session stops and retries in flight: `continue` must not re-dispatch a task
  // while its previous daemon session is still being torn down (one session per
  // task), and the retry policy must never send two retries for one block.
  const pendingSessionStops = new Map();
  const retryInFlight = new Set();
  const launchRetryTimers = new Map();
  // Followed tasks: the interval that polls a daemon-owned turn after the worker
  // that started it is gone, and the guard that keeps one probe in flight.
  const followTimers = new Map();
  const followInFlight = new Set();

  const workerStartedAt = new Date().toISOString();
  const manifest = {
    version: 'delegate-supervisor.v1',
    runDir,
    supervisorPid: process.pid,
    status: 'running',
    closed: false,
    seq,
    startedAt: workerStartedAt,
    finishedAt: null,
    maxConcurrency,
    active,
    queuedStallMs,
    progressStallMs,
    autoRetry,
    follow: followPolicyConfig,
    cancelForceKillMs,
    closeWhenIdle,
    queueSeq,
    tasks: Object.fromEntries(initialTasks.map((task, index) => [task.id, {
      ...publicTask(task, runDir, 'queued'),
      queuedAt: workerStartedAt,
      queuedSeq: index + 1,
    }])),
  };

  // The manifest is the only state a read-only `status` sees, so the live
  // counters are written with every state change instead of being derived.
  const persist = () => {
    manifest.active = active;
    manifest.queueSeq = queueSeq;
    writeJsonAtomic(paths.manifest, manifest);
  };

  // The normalized task list is the worker's own input, but a real launch change
  // (a continued task with a new brief) must survive a later read of the run.
  const persistTasks = () => {
    writeJsonAtomic(paths.tasks, {
      version: 'delegate-task-spec.v1',
      tasks: taskList.map((task) => {
        const { stdoutPath, stderrPath, ...rest } = task;
        if (task.remote) rest.timelinePath = null;
        return rest;
      }),
    });
  };

  const transition = (task, to, extra = {}) => {
    const state = manifest.tasks[task.id];
    if (!state) return;
    const from = state.status;
    // Entering the queue stamps FIFO order and start time; entering a running
    // state clears any stall flag from the previous queue episode.
    const queueFields = to === 'queued'
      ? { queuedAt: new Date().toISOString(), queuedSeq: ++queueSeq, queueStall: null }
      : (to === 'running' ? { queueStall: null } : {});
    // Every block is its own retry episode: recovery through a retry must not
    // leave the next block with an exhausted budget, and the receipt time is a
    // fallback clock for a notice that carried no timestamp.
    const retryFields = to === 'blocked'
      ? {
        retryEpisode: (state.retryEpisode ?? 0) + 1,
        blockedAt: new Date().toISOString(),
        nextRetryAt: null,
        retryExhaustedAt: null,
      }
      : {};
    Object.assign(state, queueFields, retryFields, extra, { status: to });
    manifest.seq = ++seq;
    const event = {
      seq,
      taskId: task.id,
      implementer: task.implementer,
      workspace: task.workspace,
      from,
      to,
      at: new Date().toISOString(),
      ...extra,
    };
    appendFileSync(paths.journal, `${JSON.stringify(event)}\n`, 'utf8');
    persist();
  };

  // Non-transition notices (`queued_stall`, `cancel_requested`, `session_stop`)
  // never change task state but share the monotonic sequence, so a watcher
  // cursor stays valid across both kinds of journal record.
  const notice = (task, kind, extra = {}) => {
    const state = task ? manifest.tasks[task.id] : null;
    manifest.seq = ++seq;
    const event = {
      seq,
      taskId: task?.id ?? null,
      implementer: task?.implementer ?? null,
      workspace: task?.workspace ?? null,
      from: state?.status ?? null,
      to: kind,
      kind,
      at: new Date().toISOString(),
      ...extra,
    };
    appendFileSync(paths.journal, `${JSON.stringify(event)}\n`, 'utf8');
    persist();
    return event;
  };

  // A queued task that outlives the stall threshold while every slot is busy is
  // journaled exactly once per queue episode; `status` recomputes the same
  // condition on read so a caller that never watched is not left blind.
  const flagQueueStall = (id) => {
    const task = taskMap.get(id);
    const state = manifest.tasks[id];
    if (!task || !state || state.status !== 'queued' || state.queueStall) return;
    const description = describeQueuedTask(manifest, id);
    if (!description || !description.stalled) return;
    const at = new Date().toISOString();
    state.queueStall = {
      at,
      queuedForMs: description.queuedForMs,
      thresholdMs: description.stallThresholdMs,
      active: description.active,
      maxConcurrency: description.maxConcurrency,
      position: description.position,
      queuedTop: description.queuedTotal,
      reason: description.reason,
    };
    notice(task, 'queued_stall', { ...state.queueStall });
  };

  // A running task that publishes no progress for its threshold is silent:
  // journal it once per stall episode, and clear the flag (with a
  // non-actionable `progress_resumed` notice) as soon as progress returns, so a
  // later stall is reported again.
  const flagProgressStall = (id) => {
    const task = taskMap.get(id);
    const state = manifest.tasks[id];
    if (!task || !state) return;
    if (!['running', 'resuming'].includes(state.status)) return;
    const reference = state.lastProgressAt ?? state.startedAt ?? state.stateSince ?? null;
    const referenceMs = reference ? parseIsoMillis(reference) : null;
    if (referenceMs == null) return;
    const thresholdMs = progressThresholdMs(manifest, state);
    const silentForMs = Math.max(0, Date.now() - referenceMs);
    if (silentForMs < thresholdMs) {
      if (state.progressStall) {
        state.progressStall = null;
        notice(task, 'progress_resumed', { silentForMs, lastProgressAt: reference });
      }
      return;
    }
    if (state.progressStall) return;
    state.progressStall = {
      at: new Date().toISOString(),
      silentForMs,
      thresholdMs,
      lastProgressAt: reference,
      status: state.status,
    };
    notice(task, 'progress_stall', { ...state.progressStall });
  };

  // The worker owns every child handle, so a task that is still `running` after
  // its process is gone and its handle was lost can never settle on its own.
  // This net guarantees no task is left running forever.
  const reapLostWorkers = () => {
    for (const [id, state] of Object.entries(manifest.tasks)) {
      if (settled.has(id)) continue;
      if (!state || ['queued', 'held'].includes(state.status)) continue;
      // A followed task has no worker on purpose: its daemon turn is observed by
      // the follow poll, not by a process this supervisor owns.
      if (isFollowing(state)) continue;
      if (children.has(id)) continue;
      if (!processIsAlive(state.pid)) markWorkerLost(id);
    }
  };

  const markWorkerLost = (id) => {
    const task = taskMap.get(id);
    const state = manifest.tasks[id];
    if (!task || !state || settled.has(id)) return;
    const digest = readResultDigest(state.resultPath);
    // A published terminal artifact is the task's own last word; the process
    // disappearing afterwards is not a lost worker.
    if (digest?.status && TERMINAL_STATUSES.has(digest.status)) {
      settled.add(id);
      transition(task, digest.status, {
        finishedAt: new Date().toISOString(),
        stateSince: new Date().toISOString(),
        cause: 'result_recorded_after_exit',
        recovered: true,
        result: digest,
      });
      checkRunCompletion();
      return;
    }
    settled.add(id);
    active = Math.max(0, active - 1);
    const finishedAt = new Date().toISOString();
    transition(task, 'failed', {
      finishedAt,
      stateSince: finishedAt,
      cause: 'worker_lost',
      kind: 'worker_lost',
      error: 'task process is no longer running and no terminal result was recorded',
    });
    checkRunCompletion();
    launchAvailable();
  };

  // The monitor tick follows the smallest threshold actually in play, so a task
  // that overrides the run default with a short silence window is noticed as
  // promptly as its own setting promises. The interval is re-evaluated on every
  // tick because a later `enqueue` can add an even shorter override.
  const monitorTickMs = () => {
    const thresholds = [queuedStallMs, progressStallMs];
    // A retry due time is a deadline like any stall threshold: the tick has to
    // be fine enough to honour a compressed grace or backoff window. A task may
    // opt in on its own, so the run flag is not the only source of urgency.
    if (autoRetry.enabled || taskList.some((task) => task.autoRetry === true)) {
      thresholds.push(autoRetry.graceMs, autoRetry.backoffMs);
    }
    for (const state of Object.values(manifest.tasks)) {
      const own = Number(state?.progressStallMs);
      if (Number.isInteger(own) && own > 0) thresholds.push(own);
    }
    return Math.max(
      STALL_CHECK_MIN_MS,
      Math.min(STALL_CHECK_MAX_MS, Math.floor(Math.min(...thresholds) / 4)),
    );
  };

  let monitorIntervalMs = 0;
  let monitorTimer = null;
  const monitorTick = () => {
    for (const [id, state] of Object.entries(manifest.tasks)) {
      if (state.status === 'queued' && !state.queueStall) flagQueueStall(id);
    }
    for (const id of Object.keys(manifest.tasks)) flagProgressStall(id);
    for (const id of Object.keys(manifest.tasks)) maybeAutoRetry(id);
    reapLostWorkers();
    armMonitor();
  };
  const armMonitor = () => {
    const next = monitorTickMs();
    if (monitorTimer && next === monitorIntervalMs) return;
    if (monitorTimer) clearInterval(monitorTimer);
    monitorIntervalMs = next;
    monitorTimer = setInterval(monitorTick, next);
  };

  // A relaunch is scheduled, not immediate: the daemon that just failed its
  // health check needs a moment, and the attempt history must survive. The task
  // returns to `queued` so concurrency accounting stays honest, and
  // `launchAvailable` refuses to start it before `launchRetryAt`.
  const scheduleLaunchRetry = (task, code, signal, plan) => {
    const state = manifest.tasks[task.id];
    if (!state) return;
    active = Math.max(0, active - 1);
    children.delete(task.id);
    const forceKillTimer = forceKillTimers.get(task.id);
    if (forceKillTimer) {
      clearTimeout(forceKillTimer);
      forceKillTimers.delete(task.id);
    }
    if (timelineWatchers.has(task.id)) {
      try { timelineWatchers.get(task.id).close(); } catch {}
      timelineWatchers.delete(task.id);
    }
    const startedAtMs = parseIsoMillis(state.startedAt);
    const attempt = {
      attempt: plan.attempt,
      at: new Date().toISOString(),
      exitCode: code,
      signal,
      elapsedMs: startedAtMs == null ? null : Math.max(0, Date.now() - startedAtMs),
      backoffMs: plan.delayMs,
      cause: 'daemon_unavailable',
    };
    state.launchRetries = [...(state.launchRetries ?? []), attempt];
    notice(task, 'launch_retry', { ...attempt, maxAttempts: plan.maxAttempts });
    const resumeAt = new Date(Date.now() + plan.delayMs).toISOString();
    transition(task, 'queued', {
      pid: null,
      cause: 'daemon_unavailable',
      launchRetryAt: resumeAt,
      launchRetries: state.launchRetries,
      error: `spawn exited ${code} before a healthy daemon answered; relaunch`
        + ` ${plan.attempt}/${plan.maxAttempts} in ${plan.delayMs}ms`,
    });
    const timer = setTimeout(() => {
      launchRetryTimers.delete(task.id);
      if (settled.has(task.id)) return;
      if (manifest.tasks[task.id]?.status !== 'queued') return;
      launchAvailable();
    }, plan.delayMs);
    launchRetryTimers.set(task.id, timer);
  };

  // A cancelled group whose leader exited first still has to be forced: the
  // wrapper is not the tree. The escalation is armed on the task rather than on a
  // child handle, so it fires even though the task already settled, and it
  // reports a group that survives its own SIGKILL instead of assuming it died.
  const forceKillGroupLater = (task, graceMs) => {
    const timer = setTimeout(() => {
      forceKillTimers.delete(task.id);
      const state = manifest.tasks[task.id] ?? null;
      if (!state) return;
      signalTaskProcess(state, null, 'SIGKILL');
      const verify = setTimeout(() => {
        const survivors = survivingGroupMembers(Number(state.pgid));
        if (!survivors) return;
        state.groupSurvivors = survivors;
        notice(task, 'worker_group_alive', {
          pgid: survivors.pgid,
          aliveAfterMs: survivors.aliveAfterMs,
          forced: true,
          forcedAfterMs: graceMs,
        });
      }, GROUP_KILL_VERIFY_MS);
      if (typeof verify.unref === 'function') verify.unref();
    }, graceMs);
    if (typeof timer.unref === 'function') timer.unref();
    forceKillTimers.set(task.id, timer);
  };

  const finishTask = (task, code, signal, launchError = null) => {
    if (settled.has(task.id)) return;
    // Exit 78 is the CLI's daemon-health pre-check: the spawn never reached a
    // turn, so relaunching it is a launch repair instead of a task failure. The
    // attempt is recorded and journaled, and the task returns to the queue for
    // its backoff window rather than settling as failed.
    const launchState = manifest.tasks[task.id];
    const launchPlan = launchError || !launchState
      ? { action: 'none' }
      : planLaunchRetry({
        exitCode: code,
        startedAtMs: parseIsoMillis(launchState.startedAt),
        endedAtMs: Date.now(),
        attempts: (launchState.launchRetries ?? []).length,
        maxAttempts: autoRetry.launchMaxAttempts,
        backoffMs: autoRetry.launchBackoffMs,
      });
    if (launchPlan.action === 'retry' && launchState.cancellationRequested !== true) {
      scheduleLaunchRetry(task, code, signal, launchPlan);
      return;
    }
    settled.add(task.id);
    active -= 1;
    children.delete(task.id);
    const forceKillTimer = forceKillTimers.get(task.id);
    if (forceKillTimer) {
      clearTimeout(forceKillTimer);
      forceKillTimers.delete(task.id);
    }

    if (timelineWatchers.has(task.id)) {
      try { timelineWatchers.get(task.id).close(); } catch {}
      timelineWatchers.delete(task.id);
    }

    // An exit is not a departure. The direct child can exit while a member of its
    // process group is still alive and still attached to the session — exactly
    // the 2026-10-23 `fvm` wrapper case. Nothing is concluded from the exit
    // before the group has been verified, and a surviving group is reported
    // instead of being described as a transport that left.
    const groupSurvivors = survivingGroupMembers(manifest.tasks[task.id]?.pgid);
    if (groupSurvivors) {
      // Always recorded, so a reader can see that the tree outlived the child.
      Object.assign(manifest.tasks[task.id], { groupSurvivors });
      // A cancelled task is already being killed as a group by the force-kill
      // timer; the survivor there is expected, so only an exit nobody is chasing
      // is worth a coordinator's attention.
      if (launchState?.cancellationRequested !== true) {
        notice(task, 'worker_group_alive', {
          pgid: groupSurvivors.pgid,
          pid: launchState?.pid ?? null,
          exitCode: code,
          signal,
          aliveAfterMs: groupSurvivors.aliveAfterMs,
        });
      }
    }
    // The cancellation timer above was cleared with the child handle, so the
    // forced kill is re-armed on the task: the wrapper exiting is not the group
    // exiting, and a cancelled tree must still be brought down.
    if (groupSurvivors && launchState?.cancellationRequested === true) {
      forceKillGroupLater(task, cancelForceKillMs);
    }

    let result = null;
    // Remote tasks have no local artifact producer, so the relayed `--json`
    // envelope on stdout is materialized into the task result path first.
    if (task.remote) captureRemoteResult(task);
    if (task.resultPath && existsSync(task.resultPath)) {
      try {
        result = JSON.parse(readFileSync(task.resultPath, 'utf8'));
      } catch {
        // Preserve process outcome when a producer leaves malformed output.
      }
    }
    const reportedStatus = result?.status ?? null;
    // An operator cancellation is authoritative: a signalled child may publish
    // `interrupted` or leave a stale `failed`, and neither may mask the fact
    // that this task was cancelled.
    const cancellationRequested = manifest.tasks[task.id]?.cancellationRequested === true;
    const remoteExit = task.remote && !TERMINAL_STATUSES.has(reportedStatus)
      ? REMOTE_EXIT_STATUSES.get(code) ?? null
      : null;
    // A relay that exits 0 without publishing the `--json` envelope cannot be
    // trusted as a completed turn: the Client CLI also reports success when the
    // control socket closes without a terminal result frame.
    const remoteCaptureMissing = task.remote && !launchError && code === 0 && result == null;
    const status = cancellationRequested
      ? 'cancelled'
      : TERMINAL_STATUSES.has(reportedStatus)
        ? reportedStatus
        : remoteExit
          ? remoteExit.status
          : remoteCaptureMissing
            ? 'incomplete'
            : code === 0 && !launchError
              ? 'completed'
              : 'failed';
    const remoteDiagnostic = task.remote && (remoteExit || remoteCaptureMissing)
      ? lastDiagnosticLine(task.stderrPath)
      : null;
    const identity = result == null ? null : {
      projectId: result.projectId ?? result.project_id ?? null,
      conversationId: result.conversationId ?? result.conversation_id ?? null,
      sessionId: result.sessionId ?? result.session_id ?? null,
    };
    if (result) recordIdentity(task, result);
    const finishedAt = new Date().toISOString();
    // A Sanad worker is only the transport for one daemon turn. When it exits
    // while the daemon still owns the turn, the task is followed instead of being
    // reported as failed: that is exactly the case where the daemon later asked a
    // question nobody saw (run7, 2026-10-23). The probe below is what proves the
    // turn is still in flight; until it says otherwise the task stays live.
    // `interrupted` belongs here too: a transport killed by a signal (the
    // 2026-10-23 live check sent SIGTERM to the group) writes its own
    // `interrupted` artifact while the daemon still holds the turn and its
    // pending question. Treating it as final is the same defect as settling a
    // failed transport: the daemon decides, and a turn that is really gone is
    // still reported by `turn_not_in_flight`.
    const followCandidate = task.implementer === 'sanad'
      && !task.remote
      && !cancellationRequested
      && !launchError
      && Boolean(manifest.tasks[task.id]?.sessionId)
      && ['failed', 'timeout', 'incomplete', 'interrupted'].includes(status);
    if (followCandidate) {
      // The turn is not final: this task is followed, not settled. The worker's
      // slot is released above, and the follow poll owns the task from here.
      settled.delete(task.id);
      Object.assign(manifest.tasks[task.id], {
        exitCode: code,
        signal,
        reportedStatus,
        workerCause: result?.cause ?? null,
      });
      beginFollow(task, {
        exitCode: code,
        signal,
        status,
        cause: result?.cause ?? (status === 'timeout' ? 'timeout' : null),
        // Recorded so the follow reports a surviving group instead of claiming
        // the transport left the turn unattended.
        groupSurvivors,
      });
      // The worker's slot is free even though the task is not finished, so a
      // queued task must be able to take it right away.
      launchAvailable();
      return;
    }
    transition(task, status, {
      pid: manifest.tasks[task.id]?.pid ?? null,
      finishedAt,
      stateSince: finishedAt,
      exitCode: code,
      signal,
      reportedStatus,
      identity,
      // The status line shows one verdict. A cancellation is the operator's, so
      // the signalled child's own `interrupted` artifact is reported as
      // `later-result` instead of contradicting the task's status.
      ...(cancellationRequested
        ? {
          cause: 'cancelled',
          cancelledAt: finishedAt,
          result: {
            status: 'cancelled',
            source: 'operator',
            sessionId: manifest.tasks[task.id]?.sessionId ?? null,
            cause: 'cancelled',
            endedAt: finishedAt,
          },
        }
        : {}),
      ...(task.remote ? { resultCaptured: result != null } : {}),
      ...(remoteExit && !cancellationRequested ? { cause: remoteExit.cause } : {}),
      ...(remoteCaptureMissing && !cancellationRequested ? { cause: 'missing_result_envelope' } : {}),
      ...(remoteDiagnostic ? { error: remoteDiagnostic } : {}),
      ...(launchError ? { error: launchError.message, cause: 'spawn_failed' } : {}),
    });

    // Attempt history: a continued task keeps the outcome of every attempt, so
    // one task identity can be re-scoped without losing what happened before.
    const finishedState = manifest.tasks[task.id];
    if (finishedState) {
      const attemptNumber = finishedState.attempt ?? 1;
      const digest = readResultDigest(finishedState.resultPath);
      finishedState.attempts = [
        ...(finishedState.attempts || []).filter((entry) => entry.attempt !== attemptNumber),
        {
          attempt: attemptNumber,
          startedAt: finishedState.startedAt ?? null,
          finishedAt,
          status,
          exitCode: code,
          signal,
          cause: finishedState.cause ?? null,
          sessionId: finishedState.sessionId ?? null,
          result: digest,
        },
      ];
      persist();
    }

    checkRunCompletion();
    launchAvailable();
  };

  const recordSessionId = (task, sessionId) => {
    if (!sessionId) return;
    const state = manifest.tasks[task.id];
    if (!state || state.sessionId === sessionId) return;
    state.sessionId = sessionId;
    persist();
  };

  // One processed timeline record. Local tasks tail an artifact file and remote
  // relay tasks parse their streamed stdout, but both must produce exactly the
  // same journal transitions, so the handler is shared.
  const createTimelineHandler = (task) => {
    let lastSeenType = null;
    let lastSeenRequestId = null;

    return (line) => {
      if (!line || !line.trim() || settled.has(task.id)) return;
      let event;
      try {
        event = JSON.parse(line);
      } catch {
        return;
      }

      const type = event.type;
      const data = event.data || {};
      const sessionId = event.session_id || event.sessionId || data.session_id || data.sessionId || null;
      const requestId = data.request_id || data.requestId || null;

      // The session id can arrive on any event, and usually after the launch
      // transition already reported `running`. Recording it here is what lets
      // `cancel` stop the exact daemon session later; it persists only when the
      // id actually changes, so per-token events cost nothing.
      recordSessionId(task, sessionId);

      if (type === 'needs_input' || type === 'needs_permission') {
        if (lastSeenType === type && lastSeenRequestId === requestId) return;
        lastSeenType = type;
        lastSeenRequestId = requestId;

        // Forward only the documented G2 intervention fields. Whitelisting
        // avoids leaking future provider/tool payload fields into the shared
        // supervisor journal.
        const intervention = {
          kind: data.kind || type,
          ...(requestId ? { request_id: requestId } : {}),
          ...(typeof data.tool_name === 'string'
            ? { tool_name: data.tool_name }
            : {}),
          ...(Array.isArray(data.questions)
            ? { questions: data.questions }
            : {}),
        };

        transition(task, type, {
          sessionId,
          requestId,
          intervention,
          kind: type,
          stateSince: event.timestamp || null,
        });
      } else if (type === 'retrying') {
        // The daemon scheduled another attempt for a retryable failure. This is
        // progress, not a verdict: the turn stays live and the attempt counters
        // are recorded so a status line can say `retrying (n/N)`.
        const attempt = Number(data.retry_attempt ?? data.retryAttempt);
        const budget = Number(data.retry_budget ?? data.retryBudget);
        const noticeIdentity = requestId || `${attempt ?? '?'}/${budget ?? '?'}`;
        if (lastSeenType === type && lastSeenRequestId === noticeIdentity) return;
        lastSeenType = type;
        lastSeenRequestId = noticeIdentity;
        transition(task, 'retrying', {
          ...(sessionId ? { sessionId } : {}),
          cause: data.cause || data.code || 'unknown',
          daemonRetry: {
            ...(Number.isInteger(attempt) ? { attempt } : {}),
            ...(Number.isInteger(budget) ? { budget } : {}),
          },
          ...(retryAfterMs(data) ? { retryAfterMs: retryAfterMs(data) } : {}),
          stateSince: event.timestamp || null,
        });
      } else if (type === 'blocked' || type === 'waiting') {
        const cause = data.cause || data.code || 'unknown';
        const noticeIdentity = requestId || cause;
        if (lastSeenType === type && lastSeenRequestId === noticeIdentity) return;
        lastSeenType = type;
        lastSeenRequestId = noticeIdentity;
        // A rate-limit notice may publish its own retry-after; the policy waits
        // for it instead of retrying into a guaranteed rejection.
        const retryAfter = retryAfterMs(data);
        transition(task, type, {
          // An event without a session id must never erase the one already
          // recorded: cancel, steer, and retry all depend on it.
          ...(sessionId ? { sessionId } : {}),
          cause,
          ...(retryAfter ? { retryAfterMs: retryAfter } : {}),
          stateSince: event.timestamp || null,
        });
      } else if (type === 'resumed') {
        if (manifest.tasks[task.id]?.status === 'running') return;
        lastSeenType = 'resumed';
        transition(task, 'resuming', {
          ...(sessionId ? { sessionId } : {}),
          requestId: null,
          intervention: null,
          cause: null,
          stateSince: event.timestamp || null,
        });
      } else if (type === 'running') {
        if (manifest.tasks[task.id]?.status === 'running') return;
        lastSeenType = 'running';
        transition(task, 'running', {
          ...(sessionId ? { sessionId } : {}),
          requestId: null,
          intervention: null,
          cause: null,
          stateSince: event.timestamp || null,
        });
      }

      if (type === 'tool_use' || event.part?.type === 'tool' || event.tool_executions) {
        const taskState = manifest.tasks[task.id];
        if (taskState) {
          const progressAt = event.timestamp || null;
          if (!progressAt) return;
          if (taskState.status === 'resuming') {
            transition(task, 'running', {
              cause: null,
              stateSince: progressAt,
              lastProgressAt: progressAt,
            });
          } else {
            // Tool boundaries are meaningful progress and low-frequency.
            // Assistant text can arrive per token, so it must never trigger
            // persistent manifest writes here.
            taskState.lastProgressAt = progressAt;
            persist();
          }
        }
      }
    };
  };

  const observeTimeline = (task, child) => {
    if (!task.timelinePath) return;
    const timelinePath = task.timelinePath;
    const dir = dirname(timelinePath);
    mkdirSync(dir, { recursive: true });

    let offset = 0;
    const handleLine = createTimelineHandler(task);

    const readAvailable = () => {
      if (settled.has(task.id)) return;
      if (!existsSync(timelinePath)) return;
      let stat;
      try {
        stat = statSync(timelinePath);
      } catch {
        return;
      }
      if (stat.size <= offset) return;

      let chunk;
      try {
        const fd = openSync(timelinePath, 'r');
        const buffer = Buffer.alloc(stat.size - offset);
        readSync(fd, buffer, 0, buffer.length, offset);
        closeSync(fd);
        chunk = buffer.toString('utf8');
      } catch {
        return;
      }

      const lastNewline = chunk.lastIndexOf('\n');
      if (lastNewline === -1) return;

      const completeChunk = chunk.slice(0, lastNewline + 1);
      offset += Buffer.byteLength(completeChunk, 'utf8');

      const lines = completeChunk.split(/\r?\n/);
      for (const line of lines) {
        handleLine(line);
      }
    };

    try {
      const watcher = watch(dir, (_eventType, filename) => {
        if (!filename || String(filename) === basename(timelinePath)) {
          readAvailable();
        }
      });
      timelineWatchers.set(task.id, watcher);
    } catch {
      // If watching fails, fall back
    }

    readAvailable();
  };

  // Remote relay tasks are streamed through the worker: their lifecycle events
  // and terminal `--json` envelope share stdout, so the worker mirrors both
  // streams into the task logs and journals events as they arrive. A filesystem
  // watch over a file the worker itself opened is not reliable enough for live
  // intervention detection, and the terminal transition must wait for the pipe
  // to drain so the envelope is never truncated.
  const observeRelayStream = (task, child, stdoutFd, stderrFd) => {
    const handleLine = createTimelineHandler(task);
    let pending = '';
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (chunk) => {
      try { writeSync(stdoutFd, chunk); } catch {}
      pending += chunk;
      let index = pending.indexOf('\n');
      while (index !== -1) {
        handleLine(pending.slice(0, index));
        pending = pending.slice(index + 1);
        index = pending.indexOf('\n');
      }
    });
    child.stderr.setEncoding('utf8');
    child.stderr.on('data', (chunk) => {
      try { writeSync(stderrFd, chunk); } catch {}
    });
  };

  // Every auxiliary CLI call that targets a task's daemon session (stop, steer,
  // retry) is built here: it mirrors the task's own invocation form and pins, so
  // the call reaches the same binary, source entry, Home, and gateway the task
  // spawned with. One helper means the three commands cannot drift apart.
  const sessionInvocation = (task, sessionArgs) => {
    const pinned = [...sessionArgs];
    const gateway = getArgValue(task.args, task.id, '--gateway-url');
    if (gateway) pinned.push('--gateway-url', gateway);
    if (task.home) pinned.push('--home', task.home);
    const base = basename(task.command).toLowerCase();
    if (task.remote) {
      if (!SANAD_CLIENT_COMMAND.test(base)) return { reason: 'unsupported_remote_invocation' };
      if (!task.remoteDevice) return { reason: 'no_remote_device' };
      return {
        command: task.command,
        args: ['-d', task.remoteDevice, ...pinned],
        cwd: task.spawnCwd || task.workspace,
      };
    }
    if (task.implementer !== 'sanad') return { reason: 'not_a_sanad_task' };
    if (/^sanad(\.(exe|cmd|bat))?$/.test(base)) {
      return { command: task.command, args: pinned, cwd: task.spawnCwd || task.workspace };
    }
    if (/^fvm(\.(exe|cmd|bat))?$/.test(base)
      && task.args[0] === 'dart' && task.args[1] === 'run') {
      return {
        command: task.command,
        args: ['dart', 'run', task.args[2], ...pinned],
        cwd: task.spawnCwd || task.workspace,
      };
    }
    return { reason: 'unsupported_invocation' };
  };

  const sessionStopInvocation = (task, sessionId) => {
    if (!sessionId) return { reason: 'no_session_id' };
    if (task.remote) return { reason: 'remote_session' };
    if (task.implementer !== 'sanad') return { reason: 'not_a_sanad_task' };
    return sessionInvocation(task, ['session', 'stop', sessionId]);
  };

  // The read side of the same binding: `sanad session show <id> --json` is how a
  // follower observes a turn whose worker is gone. It inherits the task's own
  // Home, gateway, and invocation form, so the poll always reads the session the
  // worker created.
  const sessionShowInvocation = (task, sessionId) => {
    if (!sessionId) return { reason: 'no_session_id' };
    return sessionInvocation(task, ['session', 'show', sessionId, '--json']);
  };

  const requestSessionStop = (task, sessionId) => {
    const invocation = sessionStopInvocation(task, sessionId);
    if (!invocation.command) {
      return { requested: false, sessionId: sessionId ?? null, reason: invocation.reason };
    }
    let child;
    try {
      child = spawnCommand(invocation.command, invocation.args, {
        cwd: invocation.cwd,
        env: taskEnvironment(task, process.env),
        windowsHide: true,
        stdio: 'ignore',
      });
    } catch (error) {
      return { requested: false, sessionId, reason: error.message };
    }
    if (sessionId) pendingSessionStops.set(task.id, sessionId);
    child.once('error', (error) => {
      pendingSessionStops.delete(task.id);
      notice(task, 'session_stop', {
        sessionId,
        result: 'error',
        error: error.message,
      });
    });
    child.once('exit', (code, signal) => {
      pendingSessionStops.delete(task.id);
      notice(task, 'session_stop', {
        sessionId,
        result: code === 0 ? 'completed' : 'failed',
        exitCode: code,
        signal,
      });
    });
    return { requested: true, sessionId };
  };

  // Steering is the mid-turn channel into a live daemon session: the gateway
  // applies the message at the next execution boundary, so the task keeps its
  // session and its progress instead of being cancelled and re-dispatched.
  // `sessionSteerInvocation` is the single binding to the CLI contract
  // (`sanad session steer --session <id> --message-file <path> [--json]`).
  const sessionSteerInvocation = (task, sessionId, messageFile) => {
    if (!sessionId) return { reason: 'no_session_id' };
    return sessionInvocation(task, ['session', 'steer', '--session', sessionId, '--message-file', messageFile, '--json']);
  };

  // The recovery counterpart of steer: a turn the daemon left `blocked` has no
  // live owner to resume it, and a headless worker has no Client to press
  // Retry. `sanad session retry <id> [--provider <id>] [--model <id>] [--json]`
  // sends the same `session.runtime_retry` command the Client does.
  const sessionRetryInvocation = (task, sessionId, { provider = null, model = null } = {}) => {
    if (!sessionId) return { reason: 'no_session_id' };
    const args = ['session', 'retry', sessionId];
    if (provider) args.push('--provider', provider);
    if (model) args.push('--model', model);
    args.push('--json');
    return sessionInvocation(task, args);
  };

  // Bounded capture of one auxiliary CLI call (steer). The supervisor never
  // waits forever on an auxiliary command.
  const runAuxiliaryCommand = (invocation, task, timeoutMs = STEER_TIMEOUT_MS) => new Promise((resolvePromise) => {
    let child;
    try {
      child = spawnCommand(invocation.command, invocation.args, {
        cwd: invocation.cwd,
        env: taskEnvironment(task, process.env),
        windowsHide: true,
        stdio: ['ignore', 'pipe', 'pipe'],
      });
    } catch (error) {
      resolvePromise({ ok: false, error: error.message, exitCode: null, signal: null, stdout: '', stderr: '' });
      return;
    }
    let stdout = '';
    let stderr = '';
    let timedOut = false;
    child.stdout?.setEncoding('utf8');
    child.stderr?.setEncoding('utf8');
    child.stdout?.on('data', (chunk) => { stdout += chunk; });
    child.stderr?.on('data', (chunk) => { stderr += chunk; });
    const timer = setTimeout(() => {
      timedOut = true;
      try { child.kill('SIGTERM'); } catch {}
    }, timeoutMs);
    if (typeof timer.unref === 'function') timer.unref();
    const complete = (code, signal) => {
      clearTimeout(timer);
      resolvePromise({
        ok: !timedOut && code === 0,
        error: timedOut ? `command timed out after ${timeoutMs}ms` : null,
        exitCode: code,
        signal,
        stdout,
        stderr,
      });
    };
    child.once('error', (error) => {
      clearTimeout(timer);
      resolvePromise({ ok: false, error: error.message, exitCode: null, signal: null, stdout, stderr });
    });
    child.once('exit', complete);
  });

  // -------------------------------------------------------------------------
  // Following a daemon-owned turn after its worker exited
  // -------------------------------------------------------------------------
  // `sanad run` is only the transport for one daemon turn; the turn itself is
  // owned and persisted by the daemon. A worker that exits early — a transient
  // provider timeout, a daemon restart that reclaims the turn — therefore does
  // not end the work. Reporting it `failed` is exactly what left a real session
  // parked in `needs_input` with nobody watching (2026-10-23, run7).
  //
  // `following` keeps the task non-terminal and the poll below mirrors the
  // durable state into the very transitions an attached worker produces, so the
  // retry policy, the stall notices, and every watcher keep working unchanged.
  const isFollowing = (state) => state?.follow?.active === true;

  const stopFollowTimer = (id) => {
    const timer = followTimers.get(id);
    if (!timer) return;
    clearInterval(timer);
    followTimers.delete(id);
  };

  // The worker's own `result.json` can hold an early verdict the daemon later
  // contradicted. It is archived, never deleted, so a followed turn can never be
  // reported through it and the evidence stays available for triage.
  const archivePreFollowResult = (state) => {
    if (!state.resultPath || !existsSync(state.resultPath)) return [];
    const dir = join(runDir, 'follow', state.id, `attempt-${state.attempt ?? 1}`);
    mkdirSync(dir, { recursive: true });
    const target = join(dir, basename(state.resultPath));
    try {
      renameSync(state.resultPath, target);
      return [target];
    } catch {
      return [];
    }
  };

  // An artifact is the followed turn's own verdict only when it was produced
  // inside the follow window.
  const resultWrittenDuringFollow = (state) => {
    const digest = readResultDigest(state.resultPath);
    if (!digest) return null;
    const startedMs = parseIsoMillis(digest.startedAt);
    const followMs = parseIsoMillis(state.follow?.since);
    if (startedMs == null || followMs == null || startedMs < followMs) return null;
    return digest;
  };

  const settleFollow = (task, outcome) => {
    const state = manifest.tasks[task.id];
    if (!state || settled.has(task.id)) return;
    stopFollowTimer(task.id);
    followInFlight.delete(task.id);
    settled.add(task.id);
    const finishedAt = new Date().toISOString();
    // The verdict and the result shown for it are one fact. A followed turn's
    // outcome comes from the durable session, so a worker artifact on the same
    // path is triage evidence only: it is never printed as the task's result
    // (2026-10-23: a killed worker wrote `interrupted` after the follow settled
    // `completed`, and the status line showed both).
    const digest = outcome.resultDigest
      ?? (outcome.resultSource === 'worker_artifact' ? readResultDigest(state.resultPath) : null)
      ?? (outcome.resultSource === 'worker_artifact' ? null : followResultDigest(outcome, state, finishedAt));
    const follow = {
      ...(state.follow ?? {}),
      active: false,
      endedAt: finishedAt,
      reason: outcome.followReason ?? state.follow?.reason ?? null,
      resultSource: outcome.resultSource ?? 'daemon_session',
      outcome: outcome.status,
      ...(outcome.evidence ? { evidence: outcome.evidence } : {}),
    };
    transition(task, outcome.status, {
      finishedAt,
      stateSince: finishedAt,
      cause: outcome.cause ?? null,
      follow,
      resultSource: follow.resultSource,
      note: outcome.note ?? null,
      pid: null,
      // Always written, so a stale artifact-based result can never survive a
      // daemon-session verdict: the follow owns the visible result from here.
      result: digest ?? null,
      requestId: null,
      intervention: null,
      error: outcome.error ?? null,
    });
    const attemptNumber = state.attempt ?? 1;
    state.attempts = [
      ...(state.attempts ?? []).filter((entry) => entry.attempt !== attemptNumber),
      {
        attempt: attemptNumber,
        startedAt: state.startedAt ?? null,
        finishedAt,
        status: outcome.status,
        exitCode: state.exitCode ?? null,
        signal: state.signal ?? null,
        cause: outcome.cause ?? null,
        sessionId: state.sessionId ?? null,
        result: digest,
        resultSource: follow.resultSource,
        followed: true,
      },
    ];
    persist();
    checkRunCompletion();
    launchAvailable();
  };

  // One readable snapshot, applied exactly like the attached timeline handler:
  // the durable state becomes the task state, and only real transitions are
  // journaled. Polling the same block every interval writes nothing.
  const applyFollowSnapshot = (task, snapshot) => {
    const state = manifest.tasks[task.id];
    if (!state || !isFollowing(state)) return;
    const follow = state.follow;
    const nowIso = new Date().toISOString();
    const observedAt = snapshot.updatedAt ?? nowIso;

    if (snapshot.kind === 'ended') {
      settleFollow(task, followOutcome({
        lastLive: follow.lastLive ?? null,
        cause: follow.lastCause ?? state.cause ?? null,
        artifact: resultWrittenDuringFollow(state),
        // `idle` only says the session stopped publishing: the durable counts
        // decide whether the turn actually finished.
        evidence: snapshot.evidence ?? null,
        baseline: follow.turnBaseline ?? null,
      }));
      return;
    }
    if (snapshot.kind === 'stopping') {
      settleFollow(task, followOutcome({
        lastLive: 'stopping',
        cause: snapshot.cause ?? follow.lastCause ?? state.cause ?? null,
      }));
      return;
    }

    follow.lastLive = snapshot.kind;
    if (snapshot.kind === 'retrying') {
      // The daemon scheduled another automatic attempt. The task stays live and
      // says so, with the attempt counters, instead of parking as `blocked` and
      // waiting for a retry an operator was never needed for.
      const cause = snapshot.cause ?? state.cause ?? 'unknown';
      follow.lastCause = cause;
      const daemonRetry = {
        ...(typeof snapshot.retry?.attempt === 'number' ? { attempt: snapshot.retry.attempt } : {}),
        ...(typeof snapshot.retry?.budget === 'number' ? { budget: snapshot.retry.budget } : {}),
      };
      const label = snapshot.retry?.label ?? 'retrying';
      if (state.status !== 'retrying' || (state.cause ?? null) !== cause
        || JSON.stringify(state.daemonRetry ?? null) !== JSON.stringify(daemonRetry)) {
        transition(task, 'retrying', {
          sessionId: state.sessionId ?? null,
          cause,
          daemonRetry,
          retryLabel: label,
          stateSince: observedAt,
          ...(snapshot.retryAfterMs ? { retryAfterMs: snapshot.retryAfterMs } : {}),
        });
        return;
      }
      state.lastProgressAt = nowIso;
      persist();
      return;
    }
    if (snapshot.kind === 'blocked' || snapshot.kind === 'waiting') {
      const cause = snapshot.cause ?? state.cause ?? 'unknown';
      follow.lastCause = cause;
      if (state.status === snapshot.status && (state.cause ?? null) === cause) {
        // The same block, still in flight: no transition to report.
        state.lastProgressAt = nowIso;
        persist();
        return;
      }
      transition(task, snapshot.status, {
        sessionId: state.sessionId ?? null,
        cause,
        stateSince: observedAt,
        ...(snapshot.retryAfterMs ? { retryAfterMs: snapshot.retryAfterMs } : {}),
      });
      return;
    }
    if (snapshot.kind === 'resuming') {
      if (state.status !== 'resuming') {
        transition(task, 'resuming', {
          sessionId: state.sessionId ?? null,
          requestId: null,
          intervention: null,
          cause: null,
          stateSince: observedAt,
        });
      }
      state.lastProgressAt = nowIso;
      persist();
      return;
    }
    if (snapshot.kind === 'intervention') {
      const changed = state.status !== snapshot.status
        || (state.requestId ?? null) !== (snapshot.requestId ?? null);
      if (changed) {
        // The same whitelisted intervention payload the attached path forwards:
        // kind, request id, tool name, and questions. A tool input, an answer, or
        // a credential is never journaled.
        transition(task, snapshot.status, {
          sessionId: state.sessionId ?? null,
          requestId: snapshot.requestId,
          intervention: snapshot.intervention,
          kind: snapshot.status,
          stateSince: observedAt,
        });
      } else {
        state.lastProgressAt = nowIso;
        persist();
      }
      return;
    }

    // A live turn. The durable projection is the only progress evidence a
    // followed task can offer, so a readable live poll refreshes it. The task
    // stays `following` — the honest state for a turn with no worker — instead
    // of claiming a process that does not exist.
    if (state.status !== 'following') {
      transition(task, 'following', {
        kind: 'following',
        reason: 'turn_resumed_without_worker',
        sessionId: state.sessionId ?? null,
        requestId: null,
        intervention: null,
        cause: null,
        stateSince: observedAt,
      });
    }
    state.lastProgressAt = nowIso;
    persist();
  };

  const settleFollowLost = (task, reason, detail) => {
    settleFollow(task, {
      status: 'follow_lost',
      cause: reason,
      resultSource: 'daemon_session',
      note: 'the durable session could not be read any more; the turn may still be running on the daemon',
      error: detail,
    });
    const state = manifest.tasks[task.id];
    if (state) state.follow = { ...state.follow, active: false, lostReason: reason };
  };

  const pollFollow = async (task) => {
    const initial = manifest.tasks[task.id];
    if (!task || !initial || settled.has(task.id) || !isFollowing(initial)) return;
    if (followInFlight.has(task.id)) return;
    const deadlineMs = parseIsoMillis(initial.follow.deadlineAt);
    if (deadlineMs != null && Date.now() >= deadlineMs) {
      settleFollow(task, {
        status: 'timeout',
        cause: 'follow_deadline',
        resultSource: 'daemon_session',
        note: `the follow window of ${formatShortDuration(initial.follow.deadlineMs)} after the worker exited expired`,
        error: 'the daemon turn was still in flight when the follow window expired',
      });
      return;
    }
    const invocation = sessionShowInvocation(task, initial.sessionId);
    if (!invocation.command) {
      settleWorkerVerdict(task, 'follow_unsupported');
      return;
    }
    const probeTimeoutMs = initial.follow.probeTimeoutMs ?? followPolicyConfig.probeTimeoutMs;
    const lostAfterPolls = initial.follow.lostAfterPolls ?? followPolicyConfig.lostAfterPolls;
    followInFlight.add(task.id);
    try {
      const probe = await runAuxiliaryCommand(invocation, task, probeTimeoutMs);
      const current = manifest.tasks[task.id];
      if (!current || !isFollowing(current)) return;
      const parsed = probe.ok
        ? parseSessionShowOutput(probe.stdout)
        : {
          ok: false,
          error: probe.error ?? `session show exited ${probe.exitCode ?? 'unknown'}`,
        };
      current.follow.lastPollAt = new Date().toISOString();
      if (!parsed.ok) {
        current.follow.unreadablePolls = (current.follow.unreadablePolls ?? 0) + 1;
        current.follow.lastError = String(parsed.error ?? 'session show failed').slice(0, 400);
        if (current.follow.unreadablePolls >= lostAfterPolls) {
          // Before the turn was confirmed in flight the worker's own verdict is
          // the honest answer; afterwards the follow itself is what was lost.
          if (current.follow.confirmed === true) {
            settleFollowLost(
              task,
              'session_unreadable',
              `${current.follow.unreadablePolls} consecutive session reads failed: ${current.follow.lastError}`,
            );
          } else {
            settleWorkerVerdict(task, 'session_unreadable');
          }
          return;
        }
        persist();
        return;
      }
      current.follow.unreadablePolls = 0;
      current.follow.lastError = null;
      current.follow.polls = (current.follow.polls ?? 0) + 1;
      const snapshot = interpretSessionSnapshot(parsed.payload);
      current.follow.lastSnapshot = {
        kind: snapshot.kind,
        state: snapshot.state,
        requestId: snapshot.requestId,
        cause: snapshot.cause,
        updatedAt: snapshot.updatedAt,
      };
      if (current.follow.confirmed !== true) {
        // The first readable answer decides whether there is anything to follow
        // at all: a session that already reports no in-flight turn leaves the
        // worker verdict untouched.
        if (snapshot.kind === 'ended') {
          settleWorkerVerdict(task, 'turn_not_in_flight');
          return;
        }
        confirmFollow(task, snapshot);
        return;
      }
      applyFollowSnapshot(task, snapshot);
    } catch (error) {
      const current = manifest.tasks[task.id];
      if (!current || !isFollowing(current)) return;
      current.follow.unreadablePolls = (current.follow.unreadablePolls ?? 0) + 1;
      current.follow.lastError = String(error?.message ?? error).slice(0, 400);
      current.follow.lastPollAt = new Date().toISOString();
      if (current.follow.unreadablePolls >= lostAfterPolls) {
        if (current.follow.confirmed === true) {
          settleFollowLost(
            task,
            'session_unreadable',
            `${current.follow.unreadablePolls} consecutive session reads failed: ${current.follow.lastError}`,
          );
        } else {
          settleWorkerVerdict(task, 'session_unreadable');
        }
        return;
      }
      persist();
    } finally {
      followInFlight.delete(task.id);
    }
  };

  // The first readable snapshot that still shows a live turn is what promotes
  // the task to `following`: a worker that exits after a turn genuinely ended is
  // still reported with its own verdict, and only a turn nothing has finished is
  // followed.
  const confirmFollow = (task, snapshot) => {
    const state = manifest.tasks[task.id];
    if (!state || !isFollowing(state)) return;
    state.follow.confirmed = true;
    state.follow.confirmedAt = new Date().toISOString();
    // The durable counts at the moment the follow starts are the baseline a final
    // reply has to beat: a reply that appears afterwards is this turn's own.
    state.follow.turnBaseline = snapshot.evidence ?? null;
    // A group that outlived the direct child is not a departed transport, and the
    // reason says so instead of claiming the worker left a turn in flight.
    const groupAlive = state.follow.workerExit?.groupAlive === true;
    state.follow.reason = groupAlive ? 'worker_exited_group_alive' : 'worker_exited_turn_in_flight';
    transition(task, 'following', {
      pid: null,
      kind: 'following',
      reason: state.follow.reason,
      cause: state.workerCause ?? state.follow.workerExit?.cause ?? null,
      workerExit: state.follow.workerExit,
      follow: state.follow,
      lastProgressAt: state.follow.confirmedAt,
      requestId: null,
      intervention: null,
    });
    applyFollowSnapshot(task, snapshot);
    startFollowTimer(task);
  };

  // The turn is not observable at all, so the worker's own terminal verdict is
  // what the task is left with; nothing is invented from a session that could not
  // be read.
  const settleWorkerVerdict = (task, reason) => {
    const state = manifest.tasks[task.id];
    if (!state || settled.has(task.id)) return;
    const workerExit = state.follow?.workerExit ?? {};
    // The worker's own exit verdict is kept as-is when it is a real failure
    // status; `interrupted` is one of them, and it is never upgraded to
    // `completed` here.
    const status = ['failed', 'timeout', 'incomplete', 'interrupted'].includes(workerExit.status)
      ? workerExit.status
      : 'failed';
    settleFollow(task, {
      status,
      cause: state.workerCause ?? workerExit.cause ?? (status === 'timeout' ? 'timeout' : null),
      resultSource: 'worker_artifact',
      resultDigest: state.preFollowResult ?? null,
      followReason: reason,
      note: reason === 'session_unreadable'
        ? 'the daemon session could not be read, so the worker verdict stands'
        : 'the daemon session reported no in-flight turn, so the worker verdict stands',
      error: reason === 'session_unreadable'
        ? 'the daemon session could not be read after the worker exited'
        : null,
    });
  };

  const startFollowTimer = (task) => {
    const state = manifest.tasks[task.id];
    if (!state || !isFollowing(state)) return;
    stopFollowTimer(task.id);
    const timer = setInterval(() => {
      pollFollow(task).catch((error) => {
        notice(task, 'follow_poll_error', { error: String(error?.message ?? error).slice(0, 400) });
      });
    }, state.follow.pollMs ?? followPolicyConfig.pollMs);
    followTimers.set(task.id, timer);
  };

  // A worker exit that may leave a live turn behind: record the exit, archive the
  // early artifact, and probe the durable session before anything is journaled.
  const beginFollow = (task, exit) => {
    const state = manifest.tasks[task.id];
    if (!state) return;
    const since = new Date().toISOString();
    const deadlineMs = followDeadlineMsFor(task, followPolicyConfig.deadlineMs);
    const pollMs = followPollMsFor(task, followPolicyConfig.pollMs);
    const preFollow = readResultDigest(state.resultPath);
    const archived = archivePreFollowResult(state);
    if (preFollow && archived.length > 0) preFollow.path = archived[0];
    state.preFollowResult = preFollow;
    state.follow = {
      active: true,
      confirmed: false,
      reason: 'probing_turn',
      since,
      deadlineAt: new Date(Date.now() + deadlineMs).toISOString(),
      deadlineMs,
      pollMs,
      lostAfterPolls: followPolicyConfig.lostAfterPolls,
      probeTimeoutMs: followPolicyConfig.probeTimeoutMs,
      polls: 0,
      unreadablePolls: 0,
      lastPollAt: null,
      lastSnapshot: null,
      lastLive: null,
      lastCause: null,
      archived,
      workerExit: {
        at: since,
        exitCode: exit.exitCode ?? null,
        signal: exit.signal ?? null,
        status: exit.status ?? null,
        cause: exit.cause ?? null,
        // A group that outlived the direct child: the transport exited, but a
        // member of its tree is still alive and may still own the session.
        groupAlive: Boolean(exit.groupSurvivors),
        ...(exit.groupSurvivors ? { groupSurvivors: exit.groupSurvivors } : {}),
      },
    };
    persist();
    // The first probe is immediate: the turn may already be over, and making the
    // operator wait a whole interval for a fact already available helps nobody.
    pollFollow(task).catch((error) => {
      notice(task, 'follow_poll_error', { error: String(error?.message ?? error).slice(0, 400) });
    });
  };

  const cancelTask = (id) => {
    const state = manifest.tasks[id];
    if (!state) return { ok: false, error: `task not found: ${id}` };
    const task = taskMap.get(id);
    if (!task) return { ok: false, error: `task not found: ${id}` };
    if (settled.has(id) || TERMINAL_STATUSES.has(state.status)) {
      return { ok: false, error: `task ${id} is already ${state.status}` };
    }
    const from = state.status;
    if (from === 'queued' || from === 'held') {
      // A task that never started is cancelled outright: no signal, no daemon
      // session, and no later launch because settlement is already recorded.
      settled.add(id);
      transition(task, 'aborted', {
        cancellationRequested: true,
        cancelledAt: new Date().toISOString(),
        error: from === 'queued'
          ? 'cancelled while queued; the task never started'
          : 'cancelled while held; the task was never queued',
      });
      checkRunCompletion();
      return { ok: true, taskId: id, from, status: 'aborted', signalled: null, sessionStop: null };
    }

    // In-flight turns (running, blocked, waiting, resuming, intervention) share
    // one cancellation path: the relay's own timeout semantics plus an explicit
    // daemon session stop when the session id is already known.
    if (state.cancellationRequested) {
      // A repeated cancel must not signal twice or spawn a second session stop;
      // the first request is already waiting for the child to settle.
      return { ok: true, taskId: id, from, status: 'cancelling', signalled: null, sessionStop: null, alreadyRequested: true };
    }
    // A followed task has no child process to signal: the turn belongs to the
    // daemon, so the stop is sent to the session and the task settles here
    // instead of waiting for an exit that already happened.
    if (isFollowing(state)) {
      state.cancellationRequested = true;
      const sessionId = state.sessionId ?? null;
      const sessionStop = requestSessionStop(task, sessionId);
      notice(task, 'cancel_requested', {
        sessionId,
        followed: true,
        signalled: null,
        sessionStop: sessionStop.requested === true,
        ...(sessionStop.reason ? { sessionStopReason: sessionStop.reason } : {}),
      });
      settleFollow(task, {
        status: 'cancelled',
        cause: 'cancelled',
        resultSource: 'operator',
        note: 'cancelled while following the daemon session',
        error: 'the turn was cancelled by the operator',
      });
      return {
        ok: true,
        taskId: id,
        from,
        status: 'cancelled',
        signalled: null,
        sessionId,
        sessionStop,
        followed: true,
      };
    }
    state.cancellationRequested = true;
    const sessionId = state.sessionId ?? null;
    const sessionStop = requestSessionStop(task, sessionId);
    const child = children.get(id) ?? null;
    // The signal goes to the worker's whole process group: a wrapper (`fvm`,
    // `npm`, `cmd`) forwarding or ignoring a signal must never leave the real
    // worker running after the cancel was reported as delivered.
    const signalled = child ? signalTaskProcess(state, child, 'SIGTERM') : null;
    if (signalled) {
      const timer = setTimeout(() => {
        if (settled.has(id)) return;
        const current = manifest.tasks[id] ?? null;
        // Same target for the forced kill: the group, not the leader that may
        // already be gone while its members ignore SIGTERM.
        signalTaskProcess(current, children.get(id) ?? null, 'SIGKILL');
      }, cancelForceKillMs);
      if (typeof timer.unref === 'function') timer.unref();
      forceKillTimers.set(id, timer);
    }
    notice(task, 'cancel_requested', {
      sessionId,
      signalled: signalled?.signal ?? null,
      pgid: signalled?.pgid ?? null,
      group: signalled?.group === true,
      sessionStop: sessionStop.requested === true,
      ...(sessionStop.reason ? { sessionStopReason: sessionStop.reason } : {}),
    });
    return {
      ok: true,
      taskId: id,
      from,
      status: 'cancelling',
      signalled: signalled?.signal ?? null,
      pgid: signalled?.pgid ?? null,
      group: signalled?.group === true,
      sessionId,
      sessionStop,
    };
  };

  // `continue` re-dispatches a finished task as a numbered new attempt with a
  // delta brief, in the same workspace and with the same task id. One session
  // per task: a live worker process or an in-flight session stop blocks the
  // re-dispatch, so two turns can never share one task identity.
  const continueTask = (req) => {
    const id = req.taskId;
    const state = manifest.tasks[id];
    const task = taskMap.get(id);
    if (!state || !task) return { ok: false, error: `task not found: ${id}` };
    if (manifest.closed) return { ok: false, error: 'cannot continue a task in a closed run' };
    if (!TERMINAL_STATUSES.has(state.status)) {
      return {
        ok: false,
        error: `task ${id} is ${state.status}; continue needs a finished task (cancel it first)`,
      };
    }
    if (processIsAlive(state.pid) || children.has(id)) {
      return {
        ok: false,
        error: `task ${id} still has a live worker process (pid ${state.pid}); stop it before continuing`,
      };
    }
    if (pendingSessionStops.has(id)) {
      return {
        ok: false,
        error: `task ${id} daemon session ${pendingSessionStops.get(id)} is still stopping; verify it is gone before continuing`,
      };
    }

    const briefPath = resolve(req.briefPath || '');
    if (!req.briefPath || !isAbsolute(req.briefPath) || !existsSync(briefPath) || !statSync(briefPath).isFile()) {
      return { ok: false, error: `--brief-file must be an existing absolute file path: ${req.briefPath}` };
    }
    const briefContent = readFileSync(briefPath, 'utf8');
    if (!briefContent.trim()) return { ok: false, error: '--brief-file is empty' };

    const replaced = replaceBriefArgument(task.args, briefPath);
    if (!replaced) {
      return {
        ok: false,
        error: `task ${id} has no --brief-file argument to replace; enqueue a new task instead of continuing`,
      };
    }
    let nextArgs = replaced.args;
    if (req.newSession) nextArgs = stripSessionArguments(nextArgs);

    const previousAttempt = state.attempt ?? 1;
    const attemptNumber = previousAttempt + 1;
    const archive = archiveAttemptArtifacts(state, previousAttempt);
    task.args = nextArgs;
    task.effectiveArgs = task.home ? [...nextArgs, '--home', task.home] : nextArgs;
    persistTasks();

    const previousStatus = state.status;
    state.attempt = attemptNumber;
    notice(task, 'continue_requested', {
      attempt: attemptNumber,
      previousAttempt,
      previousStatus,
      briefPath,
      briefSha256: sha256(briefContent),
      briefLength: briefContent.length,
      newSession: req.newSession === true,
      archived: archive.files,
    });
    settled.delete(id);
    transition(task, 'queued', {
      pid: null,
      startedAt: null,
      finishedAt: null,
      exitCode: null,
      signal: null,
      error: null,
      cause: null,
      identity: null,
      reportedStatus: null,
      lastProgressAt: null,
      progressStall: null,
      cancellationRequested: false,
      sessionId: null,
      attempt: attemptNumber,
      briefFile: briefPath,
      previousStatus,
      continuedAt: new Date().toISOString(),
    });
    launchAvailable();
    return {
      ok: true,
      taskId: id,
      attempt: attemptNumber,
      previousAttempt,
      previousStatus,
      status: manifest.tasks[id]?.status ?? 'queued',
      briefPath,
      newSession: req.newSession === true,
      archived: archive.files,
      archiveDir: archive.dir,
      active,
      maxConcurrency,
    };
  };

  // `steer` delivers a mid-turn message to a task that is already running. The
  // message body is transient: the journal keeps only its sha256 and length.
  const steerTask = async (req) => {
    const id = req.taskId;
    const state = manifest.tasks[id];
    const task = taskMap.get(id);
    if (!state || !task) return { ok: false, error: `task not found: ${id}` };
    if (state.status !== 'running') {
      return {
        ok: false,
        error: `task ${id} is ${state.status}; steer needs a running task (use continue for a finished one)`,
      };
    }
    const sessionId = state.sessionId ?? null;
    if (!sessionId) {
      return {
        ok: false,
        error: `task ${id} has no recorded session id yet; wait until the session is observable, then steer`,
      };
    }

    let messageFile = req.messageFile ? resolve(req.messageFile) : null;
    let temporaryFile = null;
    if (messageFile) {
      if (!isAbsolute(messageFile) || !existsSync(messageFile) || !statSync(messageFile).isFile()) {
        return { ok: false, error: `--message-file must be an existing absolute file path: ${req.messageFile}` };
      }
    } else if (typeof req.message === 'string' && req.message.trim().length > 0) {
      const directory = join(runDir, 'steer');
      mkdirSync(directory, { recursive: true });
      temporaryFile = join(directory, `steer-${id}-${Date.now()}.md`);
      writeFileSync(temporaryFile, req.message, 'utf8');
      messageFile = temporaryFile;
    } else {
      return { ok: false, error: 'steer requires --message or --message-file' };
    }

    try {
      const content = readFileSync(messageFile, 'utf8');
      const messageSha256 = sha256(content);
      const messageLength = content.length;
      const invocation = sessionSteerInvocation(task, sessionId, messageFile);
      if (!invocation.command) {
        return {
          ok: false,
          error: `cannot steer task ${id}: ${invocation.reason}`,
          reason: invocation.reason,
        };
      }
      const result = await runAuxiliaryCommand(invocation, task);
      const cliRequestId = lastJsonField(result.stdout, ['request_id', 'requestId']);
      const diagnostic = result.ok
        ? null
        : (lastNonEmptyLine(result.stderr) ?? result.error ?? 'steer command failed');
      const event = notice(task, 'steer_sent', {
        sessionId,
        // The supervisor's own control-request id, plus the CLI's request id
        // when the command reports one. The message body is never journaled.
        requestId: req.id ?? null,
        ...(cliRequestId ? { cliRequestId } : {}),
        messageSha256,
        messageLength,
        transport: 'message-file',
        result: result.ok ? 'completed' : 'failed',
        exitCode: result.exitCode,
        signal: result.signal,
        ...(diagnostic ? { error: String(diagnostic).slice(0, 400) } : {}),
      });
      if (!result.ok) {
        return {
          ok: false,
          error: `steer rejected for task ${id}: ${diagnostic ?? 'command failed'}`,
          taskId: id,
          sessionId,
          requestId: req.id ?? null,
          messageSha256,
          messageLength,
          journalSeq: event.seq,
        };
      }
      return {
        ok: true,
        taskId: id,
        sessionId,
        requestId: req.id ?? null,
        cliRequestId,
        messageSha256,
        messageLength,
        journalSeq: event.seq,
        exitCode: result.exitCode,
      };
    } finally {
      if (temporaryFile) {
        try { unlinkSync(temporaryFile); } catch {}
      }
    }
  };

  // One retry send, shared by the manual `retry` command and the automatic
  // policy. Only the journal kind differs (`retry_sent` vs `auto_retry`) so a
  // coordinator can tell its own instruction from the supervisor's budget;
  // neither is a wake-up. The daemon's verdict is reported, not invented, and a
  // refused retry (`not_blocked`) is not silently counted as a success.
  const retrySession = async (task, state, options) => {
    const {
      kind,
      provider = null,
      model = null,
      automatic = false,
      attempt = null,
      maxAttempts = null,
      delayMs = null,
    } = options;
    const sessionId = state.sessionId ?? null;
    const requestedAt = new Date().toISOString();
    const episode = state.retryEpisode ?? 0;
    const invocation = sessionRetryInvocation(task, sessionId, { provider, model });
    if (!invocation.command) {
      const unsupported = notice(task, kind, {
        sessionId,
        automatic,
        result: 'unsupported',
        reason: invocation.reason,
      });
      return {
        ok: false,
        error: `cannot retry task ${task.id}: ${invocation.reason}`,
        reason: invocation.reason,
        journalSeq: unsupported.seq,
      };
    }
    const result = await runAuxiliaryCommand(invocation, task, RETRY_TIMEOUT_MS);
    const outcome = result.exitCode == null
      ? 'failed'
      : RETRY_EXIT_OUTCOMES.get(result.exitCode) ?? 'failed';
    const cliRequestId = lastJsonField(result.stdout, ['request_id', 'requestId', 'notice_request_id']);
    const diagnostic = result.ok
      ? null
      : (lastNonEmptyLine(result.stderr) ?? result.error ?? 'retry command failed');
    // The attempt is recorded against the block that caused it, with the send
    // time (not the completion time) so backoff is measured from the request.
    const entry = {
      attempt: attempt ?? attemptsForEpisode(state, episode).length + 1,
      at: requestedAt,
      episode,
      automatic: automatic === true,
      cause: state.cause ?? null,
      provider,
      model,
      exitCode: result.exitCode,
      result: outcome,
      ...(delayMs != null ? { backoffMs: delayMs } : {}),
    };
    state.retryAttempts = [...(state.retryAttempts ?? []), entry];
    state.nextRetryAt = null;
    persist();
    const event = notice(task, kind, {
      sessionId,
      automatic: automatic === true,
      attempt: entry.attempt,
      ...(maxAttempts != null ? { maxAttempts } : {}),
      cause: entry.cause,
      provider,
      model,
      requestedAt,
      ...(cliRequestId ? { cliRequestId } : {}),
      result: outcome,
      sent: result.exitCode === 0,
      exitCode: result.exitCode,
      signal: result.signal,
      ...(delayMs != null ? { backoffMs: delayMs } : {}),
      ...(diagnostic ? { error: String(diagnostic).slice(0, 400) } : {}),
    });
    const ok = result.exitCode === 0;
    return {
      ok,
      taskId: task.id,
      sessionId,
      attempt: entry.attempt,
      ...(maxAttempts != null ? { maxAttempts } : {}),
      result: outcome,
      exitCode: result.exitCode,
      signal: result.signal,
      cliRequestId,
      journalSeq: event.seq,
      ...(ok ? {} : { error: `retry ${outcome} for task ${task.id}${diagnostic ? `: ${diagnostic}` : ''}` }),
    };
  };

  // `retry` is the manual recovery path for a blocked or waiting task. It is
  // refused for a task that is running (nothing to resume) or finished (the
  // `continue` path), and the worker repeats that check authoritatively.
  const retryTask = async (req) => {
    const id = req.taskId;
    const state = manifest.tasks[id];
    const task = taskMap.get(id);
    if (!state || !task) return { ok: false, error: `task not found: ${id}` };
    if (!RETRYABLE_TASK_STATUSES.includes(state.status)) {
      return {
        ok: false,
        error: `task ${id} is ${state.status}; retry needs a blocked or waiting task`,
      };
    }
    if (!state.sessionId) {
      return { ok: false, error: `task ${id} has no recorded session id yet; nothing to retry` };
    }
    if (retryInFlight.has(id)) {
      return { ok: false, error: `a retry for task ${id} is already in flight` };
    }
    retryInFlight.add(id);
    try {
      return await retrySession(task, state, {
        kind: 'retry_sent',
        provider: normalizeRetryRoute(req.provider),
        model: normalizeRetryRoute(req.model),
      });
    } finally {
      retryInFlight.delete(id);
    }
  };

  // A run-level `--auto-retry` is the default; a task's own spec flag wins, so a
  // single task can opt in without enabling the whole run.
  const taskAutoRetry = (task) => (task.autoRetry == null ? autoRetry.enabled : task.autoRetry === true);

  // The automatic budget. The daemon spends its own automatic retry before it
  // publishes `blocked`, so a blocked worker stays blocked until something
  // outside resumes it; this is that "something", journaled attempt by attempt.
  const maybeAutoRetry = (id) => {
    const task = taskMap.get(id);
    const state = manifest.tasks[id];
    if (!task || !state || settled.has(id) || state.cancellationRequested) return;
    if (!taskAutoRetry(task)) return;
    if (retryInFlight.has(id)) return;
    const episode = state.retryEpisode ?? 0;
    const attempts = attemptsForEpisode(state, episode);
    const plan = planAutoRetry({
      status: state.status,
      cause: state.cause,
      blockedAtMs: parseIsoMillis(state.stateSince) ?? parseIsoMillis(state.blockedAt),
      lastRetryAtMs: attempts.length ? parseIsoMillis(attempts.at(-1).at) : null,
      attempts: attempts.length,
      nowMs: Date.now(),
      graceMs: autoRetry.graceMs,
      maxAttempts: autoRetry.maxAttempts,
      backoffMs: autoRetry.backoffMs,
      retryAfterMs: state.retryAfterMs ?? null,
    });
    if (plan.action === 'wait') {
      const dueAt = new Date(plan.dueAtMs).toISOString();
      if (state.nextRetryAt !== dueAt) {
        state.nextRetryAt = dueAt;
        persist();
      }
      return;
    }
    if (plan.action === 'retry') {
      retryInFlight.add(id);
      retrySession(task, state, {
        kind: 'auto_retry',
        automatic: true,
        attempt: plan.attempt,
        maxAttempts: plan.maxAttempts,
        delayMs: plan.delayMs,
      }).catch((error) => {
        notice(task, 'auto_retry', {
          automatic: true,
          attempt: plan.attempt,
          result: 'error',
          error: String(error?.message ?? error).slice(0, 400),
        });
      }).finally(() => retryInFlight.delete(id));
      return;
    }
    if (plan.reason === 'attempts_exhausted' && !state.retryExhaustedAt) {
      // Actionable: the policy is done trying, so the next decision is a
      // coordinator's (switch provider, continue with a new brief, cancel).
      state.retryExhaustedAt = new Date().toISOString();
      const last = attempts.at(-1) ?? null;
      notice(task, 'retry_exhausted', {
        attempts: plan.attempts,
        maxAttempts: plan.maxAttempts,
        cause: state.cause ?? null,
        blockedSince: state.stateSince ?? null,
        lastRetryAt: last?.at ?? null,
        lastResult: last?.result ?? null,
        lastExitCode: last?.exitCode ?? null,
      });
    }
  };

  // Attempt artifacts are archived, not deleted: the previous attempt's result
  // stays available for triage after the task is re-scoped.
  const archiveAttemptArtifacts = (state, attemptNumber) => {
    const dir = join(runDir, 'attempts', state.id, `attempt-${attemptNumber}`);
    const sources = new Set([
      state.resultPath,
      state.timelinePath,
      state.stdoutPath,
      state.stderrPath,
    ].filter(Boolean));
    mkdirSync(dir, { recursive: true });
    const files = [];
    for (const source of sources) {
      if (!existsSync(source)) continue;
      const target = join(dir, basename(source));
      try {
        renameSync(source, target);
        files.push(target);
      } catch {
        // A file another process still holds open stays where it is; the attempt
        // record keeps pointing at the original path.
      }
    }
    return { dir, files };
  };

  const launchTask = (task) => {
    active += 1;
    const stdoutFd = openSync(manifest.tasks[task.id].stdoutPath, 'a');
    const stderrFd = openSync(manifest.tasks[task.id].stderrPath, 'a');
    const effectiveArgs = task.effectiveArgs || task.args;
    const streamRelay = task.remote === true;
    let fdsClosed = false;
    const closeTaskFds = () => {
      if (fdsClosed) return;
      fdsClosed = true;
      try { closeSync(stdoutFd); } catch {}
      try { closeSync(stderrFd); } catch {}
    };
    let child;
    try {
      // Stdin is never inherited: a delegated Sanad task reads its brief from
      // `--brief-file`, and `sanad-client` blocks on piped stdin until EOF, so
      // the child receives an immediate EOF instead of the supervisor's stdin.
      const spawnOptions = {
        cwd: task.spawnCwd || task.workspace,
        env: taskEnvironment(task, process.env),
        windowsHide: true,
        // The worker leads its own process group so cancel, the forced kill, and
        // shutdown can signal the whole tree instead of the wrapper only.
        detached: GROUP_SIGNALS_SUPPORTED,
        stdio: streamRelay ? ['ignore', 'pipe', 'pipe'] : ['ignore', stdoutFd, stderrFd],
      };
      child = spawnCommand(task.command, effectiveArgs, spawnOptions);
    } catch (error) {
      closeTaskFds();
      finishTask(task, 127, null, error);
      return;
    }
    children.set(task.id, child);
    if (!streamRelay) closeTaskFds();
    const startedAt = new Date().toISOString();
    transition(task, 'running', {
      pid: child.pid,
      // The group id is the leader's pid; it is recorded so every later signal
      // and every repair read targets the same group the worker was spawned in.
      pgid: GROUP_SIGNALS_SUPPORTED ? child.pid : null,
      startedAt,
      stateSince: startedAt,
      queueStall: null,
      progressStall: null,
      lastProgressAt: startedAt,
      launchRetryAt: null,
      cancellationRequested: false,
    });

    if (streamRelay) {
      observeRelayStream(task, child, stdoutFd, stderrFd);
    } else {
      observeTimeline(task, child);
    }

    child.once('error', (error) => {
      closeTaskFds();
      finishTask(task, 127, null, error);
    });
    if (streamRelay) {
      // `close` fires after both pipes are drained, so the captured envelope is
      // complete before the terminal transition reads it.
      child.once('close', (code, signal) => {
        closeTaskFds();
        finishTask(task, code, signal);
      });
    } else {
      child.once('exit', (code, signal) => finishTask(task, code, signal));
    }
  };

  function launchAvailable() {
    for (const task of taskList) {
      if (active >= maxConcurrency) break;
      const taskState = manifest.tasks[task.id];
      if (taskState && taskState.status === 'queued' && !settled.has(task.id)) {
        // A task waiting out its launch backoff is not ready yet; starting it
        // early would turn every other settlement into a retry bypass.
        const retryAt = parseIsoMillis(taskState.launchRetryAt);
        if (retryAt != null && retryAt > Date.now()) continue;
        launchTask(task);
      }
    }
  }

  function checkRunCompletion() {
    const totalTasks = Object.keys(manifest.tasks).length;
    // `--close-when-idle` makes an otherwise open run terminate as soon as every
    // task is terminal and nothing is queued, so a coordinator is never left
    // waiting on a supervisor that has no work left.
    if (!manifest.closed && closeWhenIdle && totalTasks > 0 && settled.size >= totalTasks) {
      const nothingQueued = !Object.values(manifest.tasks).some((task) => task.status === 'queued');
      if (nothingQueued) manifest.closed = true;
    }
    if (!manifest.closed) return;
    if (settled.size >= totalTasks) {
      manifest.status = 'completed';
      manifest.finishedAt = new Date().toISOString();
      const event = {
        seq: ++seq,
        taskId: null,
        implementer: null,
        workspace: null,
        from: 'running',
        to: 'completed',
        at: manifest.finishedAt,
        kind: 'run_completed',
      };
      manifest.seq = seq;
      appendFileSync(paths.journal, `${JSON.stringify(event)}\n`, 'utf8');
      persist();
      clearInterval(keepAliveTimer);
      clearInterval(monitorTimer);
      try { reqWatcher.close(); } catch {}
      process.exit(0);
    }
  }

  function handleRequest(req) {
    if (req.type === 'add') {
      if (manifest.closed) {
        return { ok: false, error: 'cannot add tasks to closed run' };
      }
      const newTasks = req.tasks || [];
      for (const t of newTasks) {
        if (manifest.tasks[t.id]) {
          return { ok: false, error: `duplicate task id: ${t.id}` };
        }
      }
      for (const t of newTasks) {
        const task = withRunPaths(t, runDir);
        taskMap.set(task.id, task);
        taskList.push(task);
        manifest.tasks[task.id] = publicTask(task, runDir, 'held');
        transition(task, 'held');
      }
      persist();
      const addedIds = newTasks.map((t) => t.id);
      // Held tasks are reported per task too: an added task never starts until
      // it is explicitly enqueued, and the caller must see that.
      return {
        ok: true,
        taskIds: addedIds,
        active,
        maxConcurrency,
        queued: queueSnapshot(manifest).queued.length,
        tasks: queueOutcomes(manifest, addedIds),
      };
    }

    if (req.type === 'enqueue') {
      if (manifest.closed) {
        return { ok: false, error: 'cannot enqueue tasks to closed run' };
      }
      let ids;
      if (req.spec) {
        const newTasks = req.tasks || [];
        for (const t of newTasks) {
          if (manifest.tasks[t.id]) {
            return { ok: false, error: `duplicate task id: ${t.id}` };
          }
        }
        for (const t of newTasks) {
          const task = withRunPaths(t, runDir);
          taskMap.set(task.id, task);
          taskList.push(task);
          manifest.tasks[task.id] = publicTask(task, runDir, 'queued');
          transition(task, 'queued');
        }
        ids = newTasks.map((t) => t.id);
      } else {
        ids = req.taskIds || [];
        for (const id of ids) {
          const taskEntry = manifest.tasks[id];
          if (!taskEntry) {
            return { ok: false, error: `task not found: ${id}` };
          }
          if (taskEntry.status !== 'held') {
            return { ok: false, error: `task ${id} is not held (status: ${taskEntry.status})` };
          }
        }
        for (const id of ids) {
          const task = taskMap.get(id);
          transition(task, 'queued');
        }
      }
      persist();
      launchAvailable();
      // `launchAvailable` fills every free slot synchronously, so the per-task
      // outcome already reflects started-versus-queued plus the live counts.
      return {
        ok: true,
        taskIds: ids,
        active,
        maxConcurrency,
        queued: queueSnapshot(manifest).queued.length,
        tasks: queueOutcomes(manifest, ids),
      };
    }

    if (req.type === 'cancel') {
      const ids = req.taskIds || [];
      if (ids.length !== 1) {
        return { ok: false, error: 'cancel requires exactly one task id' };
      }
      return cancelTask(ids[0]);
    }

    if (req.type === 'continue') {
      return continueTask(req);
    }

    if (req.type === 'steer') {
      // Async by nature (it waits for one bounded CLI call); the request
      // processor awaits a returned promise before writing the acknowledgement.
      return steerTask(req);
    }

    if (req.type === 'retry') {
      return retryTask(req);
    }

    if (req.type === 'set-concurrency') {
      const requested = Number(req.maxConcurrency);
      if (!Number.isInteger(requested) || requested < 1) {
        return { ok: false, error: 'max concurrency must be a positive integer' };
      }
      const previous = maxConcurrency;
      maxConcurrency = requested;
      manifest.maxConcurrency = requested;
      persist();
      const queuedBefore = queueSnapshot(manifest).queued.map((entry) => entry.id);
      launchAvailable();
      const started = queuedBefore.filter((id) => manifest.tasks[id]?.status === 'running');
      return {
        ok: true,
        previous,
        maxConcurrency,
        active,
        started,
        queued: queueSnapshot(manifest).queued.length,
        tasks: queueOutcomes(manifest, started),
      };
    }

    if (req.type === 'close') {
      if (manifest.closed) {
        return { ok: true, alreadyClosed: true };
      }
      manifest.closed = true;
      const aborted = [];
      for (const [id, tEntry] of Object.entries(manifest.tasks)) {
        if (tEntry.status === 'held') {
          const task = taskMap.get(id);
          settled.add(id);
          transition(task, 'aborted', { error: 'run closed while task was held' });
          aborted.push(id);
        } else if (req.abortQueued && tEntry.status === 'queued') {
          const task = taskMap.get(id);
          settled.add(id);
          transition(task, 'aborted', {
            cancellationRequested: true,
            cancelledAt: new Date().toISOString(),
            error: 'queued task aborted by close --abort-queued',
          });
          aborted.push(id);
        }
      }
      persist();
      return { ok: true, closed: true, aborted, abortQueued: req.abortQueued === true };
    }

    return { ok: false, error: `unknown request type: ${req.type}` };
  }

  // Requests are processed once: `steer` is asynchronous, so a second watcher
  // event must not run the same request twice.
  const inFlightRequests = new Set();

  function processPendingRequests() {
    if (!existsSync(paths.requests)) return;
    let entries;
    try {
      entries = readdirSync(paths.requests);
    } catch {
      return;
    }
    for (const entry of entries) {
      if (!entry.endsWith('.req.json')) continue;
      if (inFlightRequests.has(entry)) continue;
      const reqFile = join(paths.requests, entry);
      const ackFile = join(paths.requests, entry.replace(/\.req\.json$/, '.ack.json'));
      if (existsSync(ackFile)) continue;
      let req;
      try {
        req = JSON.parse(readFileSync(reqFile, 'utf8'));
      } catch {
        continue;
      }
      inFlightRequests.add(entry);
      const complete = (ack) => {
        inFlightRequests.delete(entry);
        writeJsonAtomic(ackFile, ack);
        try { unlinkSync(reqFile); } catch {}
        if (req.type === 'close') {
          checkRunCompletion();
        }
      };
      let result;
      try {
        result = handleRequest(req);
      } catch (error) {
        complete({ ok: false, error: error.message });
        continue;
      }
      if (result && typeof result.then === 'function') {
        result.then(complete, (error) => complete({ ok: false, error: error.message }));
      } else {
        complete(result);
      }
    }
  }

  // The watcher is the fast path; the rescan is the contract. A missed filesystem
  // event (a dropped watch under load, a platform that coalesces them) must never
  // leave a control request unanswered until its deadline, so the directory is
  // re-read on a bounded interval as well.
  const reqWatcher = watch(paths.requests, () => processPendingRequests());
  const reqRescan = setInterval(() => processPendingRequests(), REQUEST_RESCAN_MS);
  if (typeof reqRescan.unref === 'function') reqRescan.unref();
  const keepAliveTimer = setInterval(() => {}, 30_000);

  // A graceful stop is a group operation too: stopping this worker must not leave
  // the trees it started running with nobody observing them. Every live task
  // group is signalled, given the same grace window a cancel uses, and then
  // force-killed. A worker killed outright (SIGKILL) cannot run this, which is
  // exactly the case the repair path reports as an orphan.
  let shuttingDown = false;
  const shutdown = () => {
    if (shuttingDown) return;
    shuttingDown = true;
    const live = [...children.keys()]
      .map((id) => manifest.tasks[id])
      .filter((state) => state && !TERMINAL_STATUSES.has(state.status));
    const signalled = live
      .map((state) => signalTaskProcess(state, children.get(state.id) ?? null, 'SIGTERM'))
      .filter(Boolean);
    if (!live.length) {
      process.exit(0);
      return;
    }
    notice(null, 'worker_shutdown', {
      tasks: live.map((state) => state.id),
      signalled: signalled.map((entry) => ({ signal: entry.signal, pgid: entry.pgid, group: entry.group })),
      forceKillMs: cancelForceKillMs,
    });
    const force = () => {
      for (const state of live) {
        signalTaskProcess(manifest.tasks[state.id] ?? state, children.get(state.id) ?? null, 'SIGKILL');
      }
      process.exit(0);
    };
    const deadline = setTimeout(force, cancelForceKillMs);
    if (typeof deadline.unref === 'function') deadline.unref();
    const poll = setInterval(() => {
      const stillRunning = live.some((state) => groupHasLiveMembers(Number(state.pgid))
        || processIsAlive(manifest.tasks[state.id]?.pid));
      if (stillRunning) return;
      clearInterval(poll);
      clearTimeout(deadline);
      process.exit(0);
    }, 50);
    if (typeof poll.unref === 'function') poll.unref();
  };
  process.on('SIGTERM', shutdown);
  process.on('SIGINT', shutdown);

  persist();
  // The monitor starts after every handler it calls is initialized, and its
  // first tick is what evaluates retry deadlines.
  armMonitor();
  launchAvailable();
  checkRunCompletion();
  processPendingRequests();
}

// ---------------------------------------------------------------------------
// Process groups.
//
// A delegated task is spawned as the leader of its own process group, so the
// whole tree behind a wrapper — `fvm` → `dart run`, `npm` → `node`, `cmd` →
// anything — can be signalled and verified as one unit. Signalling only the
// direct child is not enough, and 2026-10-23 proved it: `kill <fvm pid>` ended
// the wrapper while the real `dartvm … sanad_agent.dart run` survived,
// re-parented to pid 1 and still attached to the session. Cancel, the forced
// kill after the grace period, and shutdown therefore all signal the group, and
// an exit is not treated as a departure until the group is empty.
//
// Group signalling is a POSIX contract. Windows has no process groups, so the
// direct child is signalled there and `pgid` is recorded as `null`.
// ---------------------------------------------------------------------------
const GROUP_SIGNALS_SUPPORTED = process.platform !== 'win32';

// Bounded verification of a group after its leader exited. The `exit` event
// means the direct child is reaped, not that the group is empty, so a member
// still shutting down gets a few probes before it is reported as surviving.
const GROUP_EXIT_PROBES = 3;
const GROUP_EXIT_PROBE_MS = 40;

/**
 * Signal one process group. `pgid` is validated before it reaches the kernel:
 * `-1` would address every process this user owns, so it is never allowed.
 */
function signalProcessGroup(pgid, signal) {
  if (!GROUP_SIGNALS_SUPPORTED) return false;
  if (!Number.isInteger(pgid) || pgid <= 1) return false;
  if (pgid === process.pid) return false;
  try {
    process.kill(-pgid, signal);
    return true;
  } catch {
    return false;
  }
}

function groupHasLiveMembers(pgid) {
  if (!GROUP_SIGNALS_SUPPORTED) return false;
  if (!Number.isInteger(pgid) || pgid <= 1) return false;
  if (pgid === process.pid) return false;
  try {
    process.kill(-pgid, 0);
    return true;
  } catch (error) {
    // EPERM means the group exists and is owned by someone else; anything else
    // (ESRCH) means the last member is gone.
    return error?.code === 'EPERM';
  }
}

/**
 * Members of a task's group that outlived the direct child, or `null` when the
 * group is empty. Synchronous on purpose: it runs in the exit handler, and a
 * bounded probe there is cheaper than a new asynchronous state.
 */
function survivingGroupMembers(pgid) {
  const id = Number(pgid);
  if (!GROUP_SIGNALS_SUPPORTED || !Number.isInteger(id) || id <= 1) return null;
  for (let probe = 1; probe <= GROUP_EXIT_PROBES; probe += 1) {
    if (!groupHasLiveMembers(id)) return null;
    if (probe < GROUP_EXIT_PROBES) sleepSync(GROUP_EXIT_PROBE_MS);
  }
  return { pgid: id, aliveAfterMs: (GROUP_EXIT_PROBES - 1) * GROUP_EXIT_PROBE_MS, probes: GROUP_EXIT_PROBES };
}

/**
 * Signal the whole group of one task, falling back to the direct child when the
 * group is unavailable (Windows, or a group that is already empty).
 */
function signalTaskProcess(state, child, signal) {
  const pgid = Number(state?.pgid);
  if (signalProcessGroup(pgid, signal)) {
    return { signal, pgid, group: true };
  }
  try {
    child?.kill(signal);
    return { signal, pgid: Number.isInteger(pgid) && pgid > 1 ? pgid : null, group: false };
  } catch {
    return null;
  }
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
