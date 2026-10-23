#!/usr/bin/env node

import { spawn, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import {
  appendFileSync,
  closeSync,
  existsSync,
  mkdirSync,
  openSync,
  readFileSync,
  readSync,
  readdirSync,
  realpathSync,
  renameSync,
  statSync,
  unlinkSync,
  watch,
  writeFileSync,
  writeSync,
} from 'node:fs';
import { homedir } from 'node:os';
import { basename, dirname, isAbsolute, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

// Journal vocabulary is shared with `watch-once.mjs` so both readers agree on
// which records deserve an orchestrator wake-up.
import {
  ACTIONABLE_STATUSES,
  TERMINAL_STATUSES,
  isActionableEvent,
} from './supervisor-events.mjs';
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

const SCRIPT_PATH = fileURLToPath(import.meta.url);
const SUPPORTED_IMPLEMENTERS = new Set(['opencode', 'agy', 'antigravity', 'sanad']);
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
const SANAD_CLIENT_COMMAND = /^sanad-client(\.(exe|cmd|bat))?$/;
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
const TASK_ID = /^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$/;
const SHELL_META = /[|;&<>$`]/;
const WINDOWS_BATCH_META = /[|;&<>$`%^!]/;
// A task that waits for a slot while every slot is busy is normal; a task that
// stays invisible in the queue for minutes is the silent stall live rounds
// reported. The worker journals one `queued_stall` notice per task per queue
// episode after this default, and `status` recomputes the same condition on
// read so a caller that never watched still sees it.
const DEFAULT_QUEUED_STALL_MS = 120_000;
const STALL_CHECK_MIN_MS = 200;
const STALL_CHECK_MAX_MS = 15_000;
// A running task that publishes no progress for this long is silent, not busy.
// The worker journals one `progress_stall` notice per stall episode and a
// `progress_resumed` notice when progress returns.
const DEFAULT_PROGRESS_STALL_MS = 900_000;
// `start`/`enqueue`/`continue` verify that every submitted task actually left
// the queue instead of reporting an optimistic launch.
const DEFAULT_VERIFY_MS = 15_000;
const VERIFY_MIN_INTERVAL_MS = 50;
// A steering message, a retry, or a follow probe is relayed to a live daemon
// session; a hung CLI must not hold the supervisor's control-request path open
// indefinitely.
const STEER_TIMEOUT_MS = 30_000;
const RETRY_TIMEOUT_MS = 45_000;
const WATCH_EVENT_VERSION = 'delegate-watch-event.v1';
const CURSOR_VERSION = 'delegate-watch-cursor.v1';
// Cancellation is cooperative first: SIGTERM follows the relay's own timeout
// path. A child that ignores it is force-killed after this grace period so a
// cancelled task can never block run completion.
const CANCEL_FORCE_KILL_MS = 10_000;
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

function fail(message, code = 2) {
  process.stderr.write(`supervisor: ${message}\n`);
  process.exit(code);
}

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

function singleRun(options, command) {
  if (options.runs.length > 1) fail(`${command} accepts a single --run`);
  if (!options.run) fail(`${command} requires --run`);
  return resolve(options.run);
}

// Fractional seconds are only useful for compressed-time tests; a run that
// wants the documented default simply omits the flag.
function secondsOption(options, key, defaultMs, label) {
  if (options[key] == null) return defaultMs;
  const seconds = Number(options[key]);
  if (!Number.isFinite(seconds) || seconds < 0) fail(`${label} must be a non-negative number`);
  return Math.round(seconds * 1000);
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

// One translation of the retry policy into worker arguments, shared by the
// POSIX spawn and the Windows broker so both start the same worker.
function workerRetryArgs(policy) {
  return [
    ...(policy.enabled ? ['--auto-retry'] : []),
    '--auto-retry-grace-ms', String(policy.graceMs),
    '--auto-retry-backoff-ms', String(policy.backoffMs),
    '--auto-retry-max-attempts', String(policy.maxAttempts),
    '--launch-retry-backoff-ms', String(policy.launchBackoffMs),
    '--launch-retry-max-attempts', String(policy.launchMaxAttempts),
  ];
}

// The follow policy travels with the worker for the same reason: the worker is
// the only process that can poll a session it owns, and it must never re-derive
// a default the handshake did not report.
function workerFollowArgs(policy) {
  return [
    '--follow-poll-ms', String(policy.pollMs),
    '--follow-deadline-ms', String(policy.deadlineMs),
    '--follow-lost-polls', String(policy.lostAfterPolls),
    '--follow-probe-timeout-ms', String(policy.probeTimeoutMs),
  ];
}

function readJson(path, label = path) {
  try {
    return JSON.parse(readFileSync(path, 'utf8'));
  } catch (error) {
    fail(`cannot read ${label}: ${error.message}`);
  }
}

function sleepSync(milliseconds) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, milliseconds);
}

function writeJsonAtomic(path, value) {
  mkdirSync(dirname(path), { recursive: true });
  const temporary = `${path}.${process.pid}.tmp`;
  writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
  const deadline = Date.now() + 2_000;
  while (true) {
    try {
      renameSync(temporary, path);
      return;
    } catch (error) {
      const transientWindowsContention = process.platform === 'win32'
        && ['EPERM', 'EACCES', 'EBUSY'].includes(error.code);
      if (!transientWindowsContention || Date.now() >= deadline) throw error;
      sleepSync(25);
    }
  }
}

function canonicalWorkspace(path) {
  if (!isAbsolute(path)) fail(`workspace must be absolute: ${path}`);
  const normalized = resolve(path);
  try {
    return realpathSync(normalized);
  } catch {
    fail(`workspace does not exist: ${path}`);
  }
}

function configRoot() {
  if (process.platform === 'win32') {
    return process.env.APPDATA || join(homedir(), 'AppData', 'Roaming');
  }
  return process.env.XDG_CONFIG_HOME || join(homedir(), '.config');
}

function registryPath() {
  return join(configRoot(), 'delegate-task-supervisor', 'workspaces.json');
}

function workspaceKey(path) {
  return createHash('sha256').update(path).digest('hex').slice(0, 24);
}

function loadRegistry() {
  const path = registryPath();
  if (!existsSync(path)) return { version: 'delegate-workspaces.v1', workspaces: {} };
  const value = readJson(path, 'workspace registry');
  if (value.version !== 'delegate-workspaces.v1' || typeof value.workspaces !== 'object') {
    fail(`unsupported workspace registry at ${path}`);
  }
  return value;
}

function identityFor(workspace) {
  const canonical = canonicalWorkspace(workspace);
  const registry = loadRegistry();
  return registry.workspaces[workspaceKey(canonical)] || {
    path: canonical,
    antigravity: null,
    opencode: null,
    sanad: null,
  };
}

function recordIdentity(task, result) {
  const projectId = result?.projectId ?? result?.project_id ?? null;
  const conversationId = result?.conversationId ?? result?.conversation_id ?? null;
  const sessionId = result?.sessionId ?? result?.session_id ?? null;
  if (!projectId && !conversationId && !sessionId) return;

  const registry = loadRegistry();
  const key = workspaceKey(task.workspace);
  const entry = registry.workspaces[key] || {
    path: task.workspace,
    antigravity: null,
    opencode: null,
    sanad: null,
  };
  const now = new Date().toISOString();
  if (task.implementer === 'antigravity' || task.implementer === 'agy') {
    entry.antigravity = { projectId, conversationId, updatedAt: now };
  } else if (task.implementer === 'opencode') {
    entry.opencode = { sessionId, updatedAt: now };
  } else if (task.implementer === 'sanad') {
    entry.sanad = { sessionId, updatedAt: now };
  }
  registry.workspaces[key] = entry;
  writeJsonAtomic(registryPath(), registry);
}

function getArgValue(args, taskId, ...flags) {
  const values = [];
  for (let i = 0; i < args.length; i += 1) {
    for (const flag of flags) {
      if (args[i] === flag) {
        const value = args[i + 1];
        if (!value || value.startsWith('-')) {
          fail(`task ${taskId} ${flag} requires a value`);
        }
        values.push(value);
      } else if (args[i].startsWith(`${flag}=`)) {
        const value = args[i].slice(flag.length + 1);
        if (!value) fail(`task ${taskId} ${flag} requires a value`);
        values.push(value);
      }
    }
  }
  if (values.length > 1) {
    fail(`task ${taskId} contains duplicate ${flags[0]} values`);
  }
  return values[0] ?? null;
}

function validateTask(item, existingIds = new Set()) {
  if (!item || typeof item !== 'object') fail('each task must be an object');
  if (!TASK_ID.test(item.id || '')) fail(`invalid task id: ${item.id}`);
  if (existingIds.has(item.id)) fail(`duplicate task id: ${item.id}`);
  if (!SUPPORTED_IMPLEMENTERS.has(item.implementer)) {
    fail(`unsupported implementer: ${item.implementer}`);
  }
  if (typeof item.command !== 'string' || item.command.length === 0) {
    fail(`task ${item.id} requires command`);
  }
  if (!Array.isArray(item.args) || item.args.some((arg) => typeof arg !== 'string')) {
    fail(`task ${item.id} args must be an array of strings`);
  }
  if (SHELL_META.test(item.command) || item.args.some((arg) => SHELL_META.test(arg))) {
    fail(`task ${item.id} command and args must not contain shell metacharacters`);
  }
  const isWindowsBatchCommand = process.platform === 'win32' && /\.(cmd|bat)$/i.test(item.command);
  if (isWindowsBatchCommand && (
    WINDOWS_BATCH_META.test(item.command) ||
    item.args.some((arg) => WINDOWS_BATCH_META.test(arg)) ||
    (typeof item.home === 'string' && WINDOWS_BATCH_META.test(item.home))
  )) {
    fail(`task ${item.id} Windows batch command, args, and home must not contain cmd metacharacters`);
  }

  const workspace = canonicalWorkspace(item.workspace);
  const normalizeOptionalPath = (value, field) => {
    if (value == null) return null;
    if (typeof value !== 'string' || !isAbsolute(value)) {
      fail(`task ${item.id} ${field} must be an absolute path`);
    }
    return resolve(value);
  };
  let spawnCwd = workspace;

  // Per-task opt-in/opt-out of the run's automatic retry policy. A task that
  // says nothing inherits the run default; `null` is what records that.
  let autoRetry = null;
  if (item.autoRetry != null) {
    if (typeof item.autoRetry !== 'boolean') fail(`task ${item.id} autoRetry must be a boolean`);
    autoRetry = item.autoRetry;
  }

  // `sourceRoot` is the Sanad source/spawn-root contract: it separates the
  // source checkout that provides the development CLI from the delegated
  // execution root (task.workspace / --execution-root). It is valid only for
  // the fvm source-development invocation and never changes the logical task
  // workspace or CLI targeting mode.
  if (item.sourceRoot != null && item.implementer !== 'sanad') {
    fail(`task ${item.id} sourceRoot is only valid for sanad source-development invocations`);
  }

  // `home` is the explicit custom Sanad Home contract. A detached Sanad worker
  // must never fall back to a default Home (observed standalone/exit 78 when
  // the managed custom Home was not reachable). Valid only for sanad tasks;
  // the value is injected as `--home` and duplicate/malformed declarations
  // fail closed. Credentials never belong in this field.
  const customHome = item.home ?? null;
  if (customHome != null && item.implementer !== 'sanad') {
    fail(`task ${item.id} home is only valid for sanad tasks`);
  }

  let resultPath = normalizeOptionalPath(item.resultPath, 'resultPath');
  let timelinePath = normalizeOptionalPath(item.timelinePath, 'timelinePath');
  let timelineFormat = item.timelineFormat ?? (item.implementer === 'sanad' ? 'jsonl' : 'text');
  // Per-task silence threshold. The run default comes from
  // `start --progress-stall-sec`; a spec may override it for one task.
  let progressStallMs = null;
  if (item.progressStallSec != null || item.progressStallMs != null) {
    const requested = Number(item.progressStallMs ?? Number(item.progressStallSec) * 1000);
    if (!Number.isFinite(requested) || requested <= 0) {
      fail(`task ${item.id} progressStallSec must be a positive number`);
    }
    progressStallMs = Math.round(requested);
  }
  // Remote `sanad-client` tasks record the validated target device so the run
  // manifest shows which device a task was dispatched to.
  let remoteDevice = null;

  if (!['text', 'jsonl'].includes(timelineFormat)) {
    fail(`task ${item.id} timelineFormat must be text or jsonl`);
  }

  if (item.implementer === 'sanad') {
    const cmdBase = basename(item.command).toLowerCase();
    const isInstalledSanad = /^(sanad)(\.(exe|cmd|bat))?$/.test(cmdBase) && item.args[0] === 'run';
    // The source-development entry may live under nested/private-consumer
    // layouts (e.g. `sanad-agent/agent/bin/sanad_agent.dart`), so match the
    // entry suffix rather than a fixed relative path while still requiring
    // `dart run <entry> run` and the fvm executable.
    const isFvmSanad = /^(fvm)(\.(exe|cmd|bat))?$/.test(cmdBase)
      && item.args[0] === 'dart'
      && item.args[1] === 'run'
      && item.args[3] === 'run'
      && typeof item.args[2] === 'string'
      && /sanad_agent\.dart$/.test(item.args[2]);
    // Remote delegation drives the `sanad-client` relay at the live Client of a
    // Sanad Home. A built binary may be addressed by an explicit absolute path.
    const isRemoteClient = SANAD_CLIENT_COMMAND.test(cmdBase);
    if (!isInstalledSanad && !isFvmSanad && !isRemoteClient) {
      fail(`task ${item.id} sanad invocation must be 'sanad run', 'fvm dart run <entry>/sanad_agent.dart run', or 'sanad-client -d <device-id> run'`);
    }

    if (isRemoteClient) {
      if (/[\\/]/.test(item.command) && !isAbsolute(item.command)) {
        fail(`task ${item.id} sanad-client command path must be absolute: ${item.command}`);
      }
      // Accept only the documented prefix `-d|--device <device-id> run` (or the
      // `--device=<id>` form). Requiring `run` as the relayed subcommand keeps
      // the target inside the one-shot surface, exactly like `sanad run`.
      const [first] = item.args;
      let device = null;
      let runIndex = -1;
      if (first === '-d' || first === '--device') {
        const value = item.args[1];
        if (!value || value.startsWith('-')) fail(`task ${item.id} ${first} requires a value`);
        device = value;
        runIndex = 2;
      } else if (typeof first === 'string' && first.startsWith('--device=')) {
        device = first.slice('--device='.length);
        if (!device) fail(`task ${item.id} --device requires a value`);
        runIndex = 1;
      }
      if (runIndex === -1 || item.args[runIndex] !== 'run') {
        fail(`task ${item.id} sanad-client invocation must be 'sanad-client -d <device-id> run ...'`);
      }
      // A later device flag would silently retarget the relayed command away
      // from the device this task validated (the Client CLI keeps the last one).
      if (item.args.slice(runIndex + 1).some(
        (arg) => arg === '-d' || arg === '--device' || (typeof arg === 'string' && arg.startsWith('--device=')),
      )) {
        fail(`task ${item.id} contains duplicate --device values`);
      }
      remoteDevice = device;
    }

    if (item.sourceRoot != null) {
      if (!isFvmSanad) {
        fail(`task ${item.id} sourceRoot is only valid for the fvm source-development invocation`);
      }
      if (typeof item.sourceRoot !== 'string' || !isAbsolute(item.sourceRoot)) {
        fail(`task ${item.id} sourceRoot must be an absolute path`);
      }
      if (!existsSync(item.sourceRoot) || !statSync(item.sourceRoot).isDirectory()) {
        fail(`task ${item.id} sourceRoot must be an existing directory: ${item.sourceRoot}`);
      }
      spawnCwd = resolve(item.sourceRoot);
    }

    if (isFvmSanad) {
      // Fail closed when the spawn root does not contain the requested source
      // entry point; this replaces the external batch-wrapper workaround that
      // previously hid which checkout provided the CLI.
      const entryPath = resolve(spawnCwd, item.args[2]);
      if (!existsSync(entryPath) || !statSync(entryPath).isFile()) {
        fail(`task ${item.id} source entry point not found: ${item.args[2]} (relative to ${spawnCwd})`);
      }
    }

    // Requiring `run` as the first Sanad subcommand structurally prevents this
    // invocation from reaching any `workspace create/add/select/switch` command.
    // Do not scan flag values for those words: they are valid workspace IDs.
    if (item.args.some((a) => /^--(api-key|secret|token|password)/i.test(a))) {
      fail(`task ${item.id} must not pass credentials via command args`);
    }

    // Explicit custom-Home propagation (97x): a detached worker must attach to
    // the declared managed Home instead of falling back to a default that may
    // conflict with an active daemon (observed standalone/exit 78). The value
    // is injected as `--home`; a relative, missing, or duplicated declaration
    // fails closed so delegation never runs against the wrong Home.
    const hasHomeArg = item.args.some(
      (arg) => arg === '--home' || (typeof arg === 'string' && arg.startsWith('--home=')),
    );
    if (hasHomeArg) {
      fail(`task ${item.id} declare the custom Home via task.home, not a --home argument`);
    }
    if (customHome != null) {
      if (typeof customHome !== 'string' || !isAbsolute(customHome)) {
        fail(`task ${item.id} home must be an absolute path`);
      }
      if (!existsSync(customHome) || !statSync(customHome).isDirectory()) {
        fail(`task ${item.id} home must be an existing directory: ${customHome}`);
      }
    }

    if (isRemoteClient) {
      // Remote delegation: the brief file is the only caller-side path. Device
      // ids, remote workspace ids, and remote execution roots describe the
      // target machine, so they are never resolved, canonicalized, or compared
      // with the local workspace here.
      const remoteWorkspace = getArgValue(item.args, item.id, '--workspace', '-w');
      const remoteExecutionRoot = getArgValue(item.args, item.id, '--execution-root');
      if (!remoteWorkspace && !remoteExecutionRoot) {
        fail(`task ${item.id} sanad-client task requires --workspace (remote workspace id) or --execution-root`);
      }
      const remoteBriefFile = getArgValue(item.args, item.id, '--brief-file', '-b');
      if (!remoteBriefFile) {
        fail(`task ${item.id} sanad-client task requires --brief-file`);
      }
      // `sanad-client` reads the brief locally and relays only its content, so
      // this path is genuinely caller-side and must exist before dispatch.
      if (!isAbsolute(remoteBriefFile) || !existsSync(remoteBriefFile) || !statSync(remoteBriefFile).isFile()) {
        fail(`task ${item.id} --brief-file must be an existing absolute file path`);
      }
      if (!getArgValue(item.args, item.id, '--session', '-s')) {
        fail(`task ${item.id} sanad-client task requires --session`);
      }
      if (!item.args.includes('--json')) {
        fail(`task ${item.id} sanad-client task requires --json so the result envelope can be captured`);
      }
      if (!item.args.includes('--events')) {
        fail(`task ${item.id} sanad-client task requires --events so relayed lifecycle events stay observable`);
      }
      if (getArgValue(item.args, item.id, '--out-dir', '-o')) {
        fail(`task ${item.id} sanad-client task must not pass --out-dir; remote artifacts are written on the target device`);
      }
      if (item.timelinePath != null) {
        fail(`task ${item.id} sanad-client task relays its timeline on stdout; do not declare timelinePath`);
      }
      // The relayed stdout carries the NDJSON lifecycle events, so it becomes
      // the observed timeline, and the terminal `--json` envelope captured from
      // that same stream becomes the task result.
      timelinePath = null;
      timelineFormat = 'jsonl';
    } else {
      const logicalWorkspace = getArgValue(item.args, item.id, '--workspace', '-w');

      const execRoot = getArgValue(item.args, item.id, '--execution-root');
      if (!logicalWorkspace && !execRoot) {
        fail(`task ${item.id} sanad task requires --workspace or --execution-root`);
      }
      // A logical workspace may own the conversation while an explicit
      // execution root targets this task's isolated worktree. Whenever present,
      // validate that filesystem boundary even when --workspace is also present.
      if (execRoot) {
        if (!isAbsolute(execRoot)) {
          fail(`task ${item.id} --execution-root must be an absolute path`);
        }
        if (canonicalWorkspace(execRoot) !== workspace) {
          fail(`task ${item.id} --execution-root must match task workspace`);
        }
      }

      const briefFile = getArgValue(item.args, item.id, '--brief-file', '-b');
      if (!briefFile) {
        fail(`task ${item.id} sanad task requires --brief-file`);
      }
      if (!isAbsolute(briefFile) || !existsSync(briefFile) || !statSync(briefFile).isFile()) {
        fail(`task ${item.id} --brief-file must be an existing absolute file path`);
      }

      const outDir = getArgValue(item.args, item.id, '--out-dir', '-o');
      if (!outDir) {
        fail(`task ${item.id} sanad task requires --out-dir`);
      }
      if (!isAbsolute(outDir)) {
        fail(`task ${item.id} --out-dir must be an absolute path`);
      }

      const expectedResultPath = resolve(outDir, 'result.json');
      const expectedTimelinePath = resolve(outDir, 'events.jsonl');
      if (resultPath && resolve(resultPath) !== expectedResultPath) {
        fail(`task ${item.id} resultPath must match --out-dir result.json`);
      }
      if (timelinePath && resolve(timelinePath) !== expectedTimelinePath) {
        fail(`task ${item.id} timelinePath must match --out-dir events.jsonl`);
      }
      resultPath = expectedResultPath;
      timelinePath = expectedTimelinePath;
      timelineFormat = 'jsonl';
    }
  }

  return {
    id: item.id,
    implementer: item.implementer,
    workspace,
    sourceRoot: item.sourceRoot != null ? resolve(item.sourceRoot) : null,
    home: customHome != null ? resolve(customHome) : null,
    spawnCwd,
    command: item.command,
    args: item.args,
    // The task's declared Home is injected once, after validation, so the
    // worker always attaches to the managed custom Home. Nothing else may
    // pass --home (duplicates fail closed during validation).
    effectiveArgs: customHome != null ? [...item.args, '--home', resolve(customHome)] : item.args,
    resultPath,
    timelinePath,
    timelineFormat,
    // A per-task silence threshold overrides the run default. `progressStallMs`
    // is accepted directly so compressed-time tests do not need fractional
    // seconds.
    progressStallMs,
    // `null` inherits the run's auto-retry default; `false` opts one task out
    // of a run that enabled it.
    autoRetry,
    // Remote `sanad-client` tasks capture their result envelope from the relayed
    // stdout and derive both artifact paths inside the run directory.
    remote: remoteDevice != null,
    remoteDevice,
    knownIdentity: identityFor(workspace),
  };
}

function validateSpec(raw, existingIds = new Set()) {
  if (!raw || !Array.isArray(raw.tasks)) {
    fail('spec must contain a tasks array');
  }
  const ids = new Set(existingIds);
  return raw.tasks.map((item) => {
    const task = validateTask(item, ids);
    ids.add(task.id);
    return task;
  });
}

function runPaths(runDir) {
  return {
    manifest: join(runDir, 'manifest.json'),
    journal: join(runDir, 'events.jsonl'),
    tasks: join(runDir, 'tasks.json'),
    requests: join(runDir, 'requests'),
    supervisorLog: join(runDir, 'supervisor.log'),
  };
}

// Task artifacts live in the run directory. A remote `sanad-client` task
// streams its NDJSON lifecycle events and terminal `--json` envelope over
// stdout, so the relayed stdout log is both the observed timeline and the
// source of the captured result; `--out-dir` would only create remote files.
function taskRunPaths(task, runDir) {
  const stdoutPath = join(runDir, `${task.id}.stdout.log`);
  const stderrPath = join(runDir, `${task.id}.stderr.log`);
  if (!task.remote) {
    return { stdoutPath, stderrPath, timelinePath: task.timelinePath, resultPath: task.resultPath };
  }
  return {
    stdoutPath,
    stderrPath,
    timelinePath: stdoutPath,
    resultPath: task.resultPath ?? join(runDir, `${task.id}.result.json`),
  };
}

function withRunPaths(task, runDir) {
  return { ...task, ...taskRunPaths(task, runDir) };
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

function firstNonEmptyLine(value) {
  if (typeof value !== 'string') return null;
  for (const line of value.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (trimmed) return trimmed;
  }
  return null;
}

function lastNonEmptyLine(value) {
  if (typeof value !== 'string') return null;
  const lines = value.split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
  return lines.length ? lines.at(-1) : null;
}

// A provider instance id or model id is passed through verbatim; only an empty
// or non-string value is dropped, so a blank flag never becomes `--provider ""`.
function normalizeRetryRoute(value) {
  if (value == null) return null;
  const text = String(value).trim();
  return text.length ? text : null;
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
function readResultDigest(resultPath) {
  if (!resultPath || !existsSync(resultPath)) return null;
  let result;
  try {
    result = JSON.parse(readFileSync(resultPath, 'utf8'));
  } catch {
    return null;
  }
  if (!result || typeof result !== 'object') return null;
  const pick = (...keys) => {
    for (const key of keys) {
      const value = result[key];
      if (typeof value === 'string' && value.trim()) return value.trim();
    }
    return null;
  };
  const summarySource = pick('summary', 'final_summary', 'finalSummary') ?? firstNonEmptyLine(result.text);
  const summary = summarySource
    ? (summarySource.replace(/\s+/g, ' ').trim().slice(0, 200) || null)
    : null;
  return {
    path: resultPath,
    status: typeof result.status === 'string' ? result.status : null,
    branch: pick('branch', 'git_branch'),
    headSha: pick('head_sha', 'headSha', 'sha'),
    prUrl: pick('pr_url', 'prUrl', 'pull_request_url'),
    summary,
    // The attempt window is what tells a result of *this* task from a later
    // attempt that reused the same `--out-dir`.
    startedAt: pick('started_at', 'startedAt'),
    endedAt: pick('ended_at', 'endedAt'),
    exitCode: typeof result.exit_code === 'number'
      ? result.exit_code
      : (typeof result.exitCode === 'number' ? result.exitCode : null),
    // A worker that exits without writing a verdict still leaves its cause, and a
    // followed turn reuses it when the durable session does not report one.
    cause: pick('cause', 'error_cause', 'block_cause'),
    error: pick('error', 'error_message'),
  };
}

function sha256(value) {
  return createHash('sha256').update(value).digest('hex');
}

/**
 * Whether a `result.json` artifact belongs to this task's attempt.
 *
 * `continue` archives an attempt's artifacts, but two tasks may also be declared
 * with the same `--out-dir` (the live run4 evidence did exactly that). An
 * artifact that started after the task settled was produced by a later attempt,
 * so it is neither adopted as this task's outcome nor printed as its result.
 */
function resultBelongsToTask(task, digest) {
  if (!digest) return false;
  const startedMs = parseIsoMillis(digest.startedAt);
  const finishedMs = parseIsoMillis(task?.finishedAt);
  if (startedMs == null || finishedMs == null) return true;
  return startedMs <= finishedMs;
}

/**
 * The result a followed task publishes for its own verdict.
 *
 * A followed turn has no worker artifact of its own: its outcome comes from the
 * durable session or from the operator, including the reason it is not a
 * completion. Recording one result object keeps the status line, `status
 * --json`, and the journal agreeing on the same status — a late worker artifact
 * can never be printed next to it as if the two described the same thing.
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
function applyVisibleResult(task, artifact) {
  if (!task) return 'none';
  if (task.follow?.resultSource === 'daemon_session' && task.resultSource === 'daemon_session') {
    if (artifact && artifact.status !== task.result?.status) {
      const changed = task.laterResult?.status !== artifact.status;
      task.laterResult = artifact;
      return changed ? 'later' : 'none';
    }
    return 'none';
  }
  if (!artifact) {
    // A resolved follow owns its visible result even when it has none to show.
    return 'none';
  }
  if (!resultBelongsToTask(task, artifact)) {
    task.laterResult = artifact;
    if (task.result) delete task.result;
    return 'later';
  }
  // An operator cancellation is authoritative, so a worker artifact that reports
  // its own `interrupted`/`failed` exit is triage evidence, never the task's
  // result: `cancelled` and `result interrupted` on one line is the same
  // contradiction a followed completion must not show.
  if (task.cancellationRequested === true && artifact.status !== task.status) {
    task.laterResult = artifact;
    return 'later';
  }
  if (TERMINAL_STATUSES.has(task.status) || task.recovered) {
    task.result = artifact;
    return 'adopted';
  }
  return 'none';
}

/**
 * The result a reader should show for one task: the recorded one when the task
 * has one (a follow verdict is one), else the artifact on its path when that
 * artifact belongs to this attempt.
 */
function taskResultForView(task) {
  const recorded = task && Object.hasOwn(task, 'result') ? task.result : null;
  if (recorded) {
    const digest = recorded;
    return resultBelongsToTask(task, digest) ? digest : null;
  }
  const digest = readResultDigest(task?.resultPath);
  if (!digest) return null;
  return resultBelongsToTask(task, digest) ? digest : null;
}

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

// Reading the whole journal is deliberate: run journals are small (one record
// per state change), and a single read gives the watcher a consistent snapshot
// instead of a race between separate seeks.
function readJournalEvents(journalPath) {
  if (!existsSync(journalPath)) return [];
  let content;
  try {
    content = readFileSync(journalPath, 'utf8');
  } catch {
    return [];
  }
  const events = [];
  for (const line of content.split(/\r?\n/)) {
    if (!line.trim()) continue;
    let event;
    try {
      event = JSON.parse(line);
    } catch {
      // A partially flushed trailing line is re-read on the next scan.
      continue;
    }
    if (event && Number.isInteger(event.seq)) events.push(event);
  }
  return events;
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

function windowsBatchQuote(value) {
  return `"${String(value).replaceAll('"', '""')}"`;
}

function launchThroughWindowsExplorer(scriptPath) {
  const result = spawnSync('explorer.exe', [scriptPath], {
    windowsHide: true,
    stdio: 'ignore',
  });
  if (result.error) {
    throw new Error(`Windows Explorer broker failed: ${result.error.message}`);
  }
  // Explorer commonly returns 1 after handing the file to the existing shell.
  // The caller verifies the requested effect instead of trusting that status.
}

function writeWindowsWorkerBroker(runDir, paths, maxConcurrency, queuedStallMs, progressStallMs, autoRetry, follow, closeWhenIdle = false, cancelForceKillMs = CANCEL_FORCE_KILL_MS) {
  const workerPath = join(runDir, 'start-supervisor.cmd');
  const brokerPath = join(runDir, 'start-supervisor.vbs');
  const command = [
    process.execPath,
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
  ].map(windowsBatchQuote).join(' ');
  writeFileSync(
    workerPath,
    `@echo off\r\n${command} >> ${windowsBatchQuote(paths.supervisorLog)} 2>&1\r\n`,
    'utf8',
  );
  const escapedWorkerPath = workerPath.replaceAll('"', '""');
  writeFileSync(
    brokerPath,
    `CreateObject("WScript.Shell").Run Chr(34) & "${escapedWorkerPath}" & Chr(34), 0, False\r\n`,
    'utf8',
  );
  return brokerPath;
}

function waitForWindowsWorkerHandshake(paths, timeoutMs = 10_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const manifest = JSON.parse(readFileSync(paths.manifest, 'utf8'));
      if (manifest.status !== 'starting' && Number.isInteger(manifest.supervisorPid)) {
        return manifest;
      }
    } catch {
      // Atomic manifest replacement can briefly race this read.
    }
    sleepSync(50);
  }
  const manifest = JSON.parse(readFileSync(paths.manifest, 'utf8'));
  manifest.status = 'failed';
  manifest.finishedAt = new Date().toISOString();
  manifest.error = 'Windows supervisor broker did not publish its startup handshake.';
  writeJsonAtomic(paths.manifest, manifest);
  throw new Error(manifest.error);
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
    if (!['blocked', 'waiting'].includes(state.status)) {
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

function loadManifest(runDir) {
  const path = runPaths(resolve(runDir)).manifest;
  if (!existsSync(path)) fail(`manifest not found: ${path}`);
  return readJson(path, 'run manifest');
}

function requireTask(manifest, id) {
  const task = manifest.tasks?.[id];
  if (!task) fail(`task not found: ${id}`);
  return task;
}

function processIsAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
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

function sendControlRequest(runDir, requestData, timeoutMs = 15_000) {
  const paths = runPaths(runDir);
  const manifest = loadManifest(runDir);
  if (manifest.status === 'stale' || (manifest.status === 'running' && !processIsAlive(manifest.supervisorPid))) {
    fail('supervisor process is not running');
  }
  if (manifest.status === 'completed') {
    fail('run is already completed');
  }
  if (manifest.closed && ['add', 'enqueue'].includes(requestData.type)) {
    fail(`cannot ${requestData.type} tasks to closed run`);
  }
  mkdirSync(paths.requests, { recursive: true });

  const reqId = `req-${Date.now()}-${process.pid}-${Math.random().toString(36).slice(2, 8)}`;
  const reqFile = join(paths.requests, `${reqId}.req.json`);
  const ackFile = join(paths.requests, `${reqId}.ack.json`);

  writeJsonAtomic(reqFile, { id: reqId, ...requestData });

  let watcher = null;

  return new Promise((resolvePromise, reject) => {
    let deadlineTimer = null;
    const cleanup = () => {
      if (deadlineTimer) clearTimeout(deadlineTimer);
      if (watcher) {
        try { watcher.close(); } catch {}
      }
      try { unlinkSync(ackFile); } catch {}
      try { unlinkSync(reqFile); } catch {}
    };

    const check = () => {
      if (!existsSync(ackFile)) return;
      let ack;
      try {
        ack = JSON.parse(readFileSync(ackFile, 'utf8'));
      } catch {
        return;
      }
      cleanup();
      if (ack.ok) {
        resolvePromise(ack);
      } else {
        reject(new Error(ack.error || 'request rejected by supervisor'));
      }
    };

    try {
      watcher = watch(paths.requests, (_eventType, filename) => {
        if (!filename || String(filename) === basename(ackFile)) check();
      });
      watcher.once('error', (error) => {
        cleanup();
        reject(new Error(`request acknowledgement watch failed: ${error.message}`));
      });
    } catch (error) {
      cleanup();
      reject(new Error(`request acknowledgement watch failed: ${error.message}`));
      return;
    }

    deadlineTimer = setTimeout(() => {
      const supervisorAlive = processIsAlive(manifest.supervisorPid);
      cleanup();
      reject(new Error(supervisorAlive
        ? `request timed out after ${timeoutMs}ms`
        : 'supervisor process died before acknowledging request'));
    }, timeoutMs);

    // Register first and rescan second so an acknowledgement written during
    // watcher setup is still consumed without an interval-based polling loop.
    check();
  });
}

async function addCommand(options) {
  const runDir = singleRun(options, 'add');
  if (!options.spec) fail('add requires --spec');
  const manifest = loadManifest(runDir);
  const existingIds = new Set(Object.keys(manifest.tasks || {}));
  const tasks = validateSpec(readJson(resolve(options.spec), 'task spec'), existingIds);
  try {
    const ack = await sendControlRequest(runDir, {
      type: 'add',
      tasks,
    });
    if (options.json) {
      process.stdout.write(`${JSON.stringify({
        runDir,
        added: true,
        taskIds: ack.taskIds,
        active: ack.active,
        maxConcurrency: ack.maxConcurrency,
        tasks: ack.tasks,
      }, null, 2)}\n`);
    } else {
      process.stdout.write(`Added ${ack.taskIds.length} held task(s) to run: ${ack.taskIds.join(', ')}\n`);
      for (const outcome of ack.tasks || []) {
        process.stdout.write(`  ${formatQueueOutcome(outcome)}\n`);
      }
    }
  } catch (error) {
    fail(error.message, 1);
  }
}

async function enqueueCommand(options) {
  const runDir = singleRun(options, 'enqueue');
  const verifyMs = verifyOption(options);
  let request;
  if (options.spec) {
    const manifest = loadManifest(runDir);
    const existingIds = new Set(Object.keys(manifest.tasks || {}));
    const tasks = validateSpec(readJson(resolve(options.spec), 'task spec'), existingIds);
    request = { type: 'enqueue', spec: true, tasks };
  } else {
    let taskIds = [];
    if (options.task) {
      taskIds = [options.task];
    } else if (options.tasks) {
      taskIds = options.tasks.split(',').map((s) => s.trim()).filter(Boolean);
    } else {
      fail('enqueue requires --spec, --task <id>, or --tasks <id1,id2>');
    }
    request = { type: 'enqueue', spec: false, taskIds };
  }

  try {
    const ack = await sendControlRequest(runDir, request);
    // The acknowledgement says what the worker decided; verification says what
    // is actually observable afterwards (started, honestly queued, or failed to
    // spawn), so a reported launch is never merely assumed.
    const verification = await observeLaunch(runDir, ack.taskIds || [], { verifyMs });
    if (options.json) {
      process.stdout.write(`${JSON.stringify({
        runDir,
        enqueued: true,
        taskIds: ack.taskIds,
        active: ack.active,
        maxConcurrency: ack.maxConcurrency,
        queued: ack.queued,
        tasks: ack.tasks,
        verification,
      }, null, 2)}\n`);
    } else {
      process.stdout.write(`Enqueued ${ack.taskIds.length} task(s): ${ack.taskIds.join(', ')}\n`);
      for (const line of verification.summary) {
        process.stdout.write(`  ${line}\n`);
      }
      if (verification.timedOut) {
        process.stdout.write(`  (verification timed out after ${verification.timeoutMs}ms)\n`);
      }
    }
    if (verification.spawnFailed.length) process.exit(1);
  } catch (error) {
    fail(error.message, 1);
  }
}

async function continueCommand(options) {
  const runDir = singleRun(options, 'continue');
  if (!options.task) fail('continue requires --task <id>');
  if (!options['brief-file']) fail('continue requires --brief-file <path>');
  const briefPath = options['brief-file'];
  if (!isAbsolute(briefPath)) fail('--brief-file must be an absolute path');
  if (!existsSync(briefPath) || !statSync(briefPath).isFile()) {
    fail(`--brief-file does not exist: ${briefPath}`);
  }
  const verifyMs = verifyOption(options);
  const manifest = loadManifest(runDir);
  const state = requireTask(manifest, options.task);

  // Pre-flight so an obviously unsafe re-dispatch never reaches the worker; the
  // worker repeats every check authoritatively.
  if (!TERMINAL_STATUSES.has(state.status)) {
    fail(`task ${options.task} is ${state.status}; continue needs a finished task (cancel it first)`);
  }
  if (processIsAlive(state.pid)) {
    fail(`task ${options.task} still has a live worker process (pid ${state.pid}); stop it and verify it is gone before continuing`);
  }

  try {
    const ack = await sendControlRequest(runDir, {
      type: 'continue',
      taskId: options.task,
      briefPath: resolve(briefPath),
      newSession: options['new-session'] === true,
    });
    const verification = await observeLaunch(runDir, [options.task], { verifyMs });
    if (options.json) {
      process.stdout.write(`${JSON.stringify({
        runDir,
        continued: true,
        taskId: ack.taskId,
        attempt: ack.attempt,
        previousAttempt: ack.previousAttempt,
        previousStatus: ack.previousStatus,
        status: ack.status,
        briefPath: ack.briefPath,
        newSession: ack.newSession,
        archived: ack.archived,
        archiveDir: ack.archiveDir,
        active: ack.active,
        maxConcurrency: ack.maxConcurrency,
        verification,
      }, null, 2)}\n`);
    } else {
      process.stdout.write(
        `Continued task ${ack.taskId} as attempt ${ack.attempt} (previous: ${ack.previousStatus}).`
        + ` Brief: ${ack.briefPath}${ack.newSession ? ' (new session)' : ''}\n`,
      );
      if (ack.archived?.length) {
        process.stdout.write(`  archived attempt ${ack.previousAttempt}: ${ack.archiveDir}\n`);
      }
      for (const line of verification.summary) process.stdout.write(`  ${line}\n`);
    }
    if (verification.spawnFailed.length) process.exit(1);
  } catch (error) {
    fail(error.message, 1);
  }
}

async function steerCommand(options) {
  const runDir = singleRun(options, 'steer');
  if (!options.task) fail('steer requires --task <id>');
  const hasMessage = typeof options.message === 'string';
  const hasMessageFile = typeof options['message-file'] === 'string';
  if (hasMessage === hasMessageFile) {
    fail('steer requires exactly one of --message or --message-file');
  }
  if (hasMessageFile) {
    const messageFile = options['message-file'];
    if (!isAbsolute(messageFile)) fail('--message-file must be an absolute path');
    if (!existsSync(messageFile) || !statSync(messageFile).isFile()) {
      fail(`--message-file does not exist: ${messageFile}`);
    }
    if (!readFileSync(messageFile, 'utf8').trim()) fail('--message-file is empty');
  } else if (!String(options.message).trim()) {
    fail('--message must not be empty');
  }

  const manifest = loadManifest(runDir);
  const state = requireTask(manifest, options.task);
  if (state.status !== 'running') {
    fail(`task ${options.task} is ${state.status}; steer needs a running task (use continue for a finished one)`);
  }
  if (!state.sessionId) {
    fail(`task ${options.task} has no recorded session id yet; wait until the session is observable, then steer`);
  }

  try {
    const ack = await sendControlRequest(runDir, {
      type: 'steer',
      taskId: options.task,
      message: hasMessage ? options.message : null,
      messageFile: hasMessageFile ? resolve(options['message-file']) : null,
    }, STEER_TIMEOUT_MS + 15_000);
    if (options.json) {
      process.stdout.write(`${JSON.stringify({
        runDir,
        steered: true,
        taskId: ack.taskId,
        sessionId: ack.sessionId,
        requestId: ack.requestId,
        cliRequestId: ack.cliRequestId ?? null,
        messageSha256: ack.messageSha256,
        messageLength: ack.messageLength,
        journalSeq: ack.journalSeq,
        exitCode: ack.exitCode,
      }, null, 2)}\n`);
      return;
    }
    process.stdout.write(
      `Steered task ${ack.taskId} (session ${ack.sessionId}): request ${ack.requestId}`
      + ` journaled at seq ${ack.journalSeq}; message sha256 ${String(ack.messageSha256).slice(0, 12)}…`
      + ` (${ack.messageLength} bytes, body not journaled).\n`,
    );
  } catch (error) {
    fail(error.message, 1);
  }
}

async function retryCommand(options) {
  const runDir = singleRun(options, 'retry');
  if (!options.task) fail('retry requires --task <id>');
  const provider = normalizeRetryRoute(options.provider);
  const model = normalizeRetryRoute(options.model);
  if (options.provider != null && !provider) fail('--provider must not be empty');
  if (options.model != null && !model) fail('--model must not be empty');

  const manifest = loadManifest(runDir);
  const state = requireTask(manifest, options.task);
  // A retry resumes an existing turn; it can never start one. A running task
  // has nothing to resume and a finished task is the `continue` path.
  if (!['blocked', 'waiting'].includes(state.status)) {
    fail(`task ${options.task} is ${state.status}; retry needs a blocked or waiting task (use continue for a finished one)`);
  }
  if (!state.sessionId) {
    fail(`task ${options.task} has no recorded session id yet; wait until the session is observable, then retry`);
  }

  try {
    const ack = await sendControlRequest(runDir, {
      type: 'retry',
      taskId: options.task,
      provider,
      model,
    }, RETRY_TIMEOUT_MS + 15_000);
    if (options.json) {
      process.stdout.write(`${JSON.stringify({
        runDir,
        retried: ack.ok === true,
        taskId: ack.taskId,
        sessionId: ack.sessionId,
        attempt: ack.attempt ?? null,
        result: ack.result ?? null,
        exitCode: ack.exitCode ?? null,
        cliRequestId: ack.cliRequestId ?? null,
        journalSeq: ack.journalSeq ?? null,
        provider,
        model,
      }, null, 2)}\n`);
      return;
    }
    process.stdout.write(
      `Retried task ${ack.taskId} (session ${ack.sessionId}): ${ack.result ?? 'sent'}`
      + ` attempt ${ack.attempt ?? '?'} journaled at seq ${ack.journalSeq ?? '?'}`
      + `${ack.cliRequestId ? ` (cli request ${ack.cliRequestId})` : ''}.\n`,
    );
  } catch (error) {
    fail(error.message, 1);
  }
}

async function cancelCommand(options) {
  const runDir = singleRun(options, 'cancel');
  if (!options.task) fail('cancel requires --task <id>');
  try {
    const ack = await sendControlRequest(runDir, { type: 'cancel', taskIds: [options.task] });
    if (options.json) {
      process.stdout.write(`${JSON.stringify({
        runDir,
        cancelled: true,
        taskId: ack.taskId,
        from: ack.from,
        status: ack.status,
        signalled: ack.signalled,
        // The group is what was signalled, and the group id is what an operator
        // (or a repair) has to address if the tree outlives the leader.
        pgid: ack.pgid ?? null,
        group: ack.group === true,
        sessionId: ack.sessionId ?? null,
        sessionStop: ack.sessionStop ?? null,
        followed: ack.followed === true,
        alreadyRequested: ack.alreadyRequested === true,
      }, null, 2)}\n`);
      return;
    }
    if (ack.alreadyRequested) {
      process.stdout.write(`Cancellation for task ${ack.taskId} was already requested; waiting for it to settle.\n`);
      return;
    }
    if (ack.status === 'aborted') {
      process.stdout.write(`Cancelled task ${ack.taskId} (${ack.from} -> aborted); it will never start.\n`);
      return;
    }
    const signalText = ack.followed
      ? 'no worker process; the turn is followed through the daemon session'
      : (ack.signalled
        ? `signalled ${ack.signalled}${ack.group === true ? ` to process group ${ack.pgid}` : ''}`
        : 'no live process to signal');
    const sessionText = ack.sessionStop?.requested
      ? `session ${ack.sessionStop.sessionId} stop requested`
      : `daemon session stop not requested (${ack.sessionStop?.reason || 'unknown'})`;
    process.stdout.write(
      `Cancelling task ${ack.taskId} (${ack.from}): ${signalText}; ${sessionText}. `
      + `The terminal state is recorded as cancelled.\n`,
    );
  } catch (error) {
    fail(error.message, 1);
  }
}

async function setConcurrencyCommand(options) {
  const runDir = singleRun(options, 'set-concurrency');
  if (options.max == null) fail('set-concurrency requires --max <n>');
  const requested = Number(options.max);
  if (!Number.isInteger(requested) || requested < 1) {
    fail('--max must be a positive integer');
  }
  try {
    const ack = await sendControlRequest(runDir, {
      type: 'set-concurrency',
      maxConcurrency: requested,
    });
    if (options.json) {
      process.stdout.write(`${JSON.stringify({
        runDir,
        previous: ack.previous,
        maxConcurrency: ack.maxConcurrency,
        active: ack.active,
        queued: ack.queued,
        started: ack.started,
        tasks: ack.tasks,
      }, null, 2)}\n`);
      return;
    }
    process.stdout.write(
      `Concurrency ${ack.previous} -> ${ack.maxConcurrency} (${ack.active}/${ack.maxConcurrency} active, ${ack.queued} queued)\n`,
    );
    for (const outcome of ack.tasks || []) {
      process.stdout.write(`  ${formatQueueOutcome(outcome)}\n`);
    }
  } catch (error) {
    fail(error.message, 1);
  }
}

function verifyOption(options) {
  if (options['verify-ms'] != null) {
    const requested = Number(options['verify-ms']);
    if (!Number.isInteger(requested) || requested < 0) fail('--verify-ms must be a non-negative integer');
    return requested;
  }
  return secondsOption(options, 'verify-sec', DEFAULT_VERIFY_MS, '--verify-sec');
}

// One task's launch state as a caller can observe it. A queued task counts as
// resolved only when the queue is the honest reason (every slot is busy); a
// task that is merely "launch pending" is still unresolved, because that is
// exactly the state that produced a reported launch that never ran.
function observeTaskState(runDir, id) {
  const manifestPath = runPaths(runDir).manifest;
  let manifest;
  try {
    manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
  } catch {
    return null;
  }
  const state = manifest?.tasks?.[id];
  if (!state) return { id, status: 'unknown', settled: false, spawnFailed: false, runStatus: manifest?.status ?? null };
  const snapshot = queueSnapshot(manifest);
  const queued = state.status === 'queued';
  const queue = queued ? describeQueuedTask(manifest, id) : null;
  const originalStatus = ['blocked', 'needs_input', 'needs_permission', 'waiting', 'resuming', 'following'].includes(state.status);
  // A `running` observation is only a launch once a pid exists: a spawn that is
  // about to fail passes through `running` with no pid for one tick, and counting
  // that as an observed launch reported a failed spawn as a success.
  const settled = (state.status === 'running' && Number.isInteger(state.pid))
    || TERMINAL_STATUSES.has(state.status)
    || originalStatus
    || (queued && queue?.reason === 'awaiting_slot');
  const observation = {
    id,
    status: state.status,
    pid: state.pid ?? null,
    attempt: state.attempt ?? 1,
    cause: state.cause ?? null,
    error: state.error ?? null,
    sessionId: state.sessionId ?? null,
    spawnFailed: state.status === 'failed' && state.cause === 'spawn_failed',
    settled,
    queue: queue ? {
      position: queue.position,
      queuedTotal: queue.queuedTotal,
      reason: queue.reason,
      reasonText: queue.reasonText,
    } : null,
    active: snapshot.active,
    maxConcurrency: snapshot.maxConcurrency,
    runStatus: manifest?.status ?? null,
  };
  observation.line = formatObservationLine(observation);
  return observation;
}

function formatObservationLine(observation) {
  const counts = `${observation.active ?? '?'}/${observation.maxConcurrency ?? '?'} active`;
  if (observation.status === 'running') {
    return `${observation.id}: running (pid ${observation.pid ?? '?'}, ${counts})`;
  }
  if (observation.status === 'queued') {
    const reason = observation.queue?.reasonText ?? 'queued';
    return `${observation.id}: queued at position ${observation.queue?.position ?? '?'} of ${observation.queue?.queuedTotal ?? '?'} — ${reason}`;
  }
  if (observation.spawnFailed) {
    return `${observation.id}: failed to spawn — ${observation.error ?? 'no diagnostic'}`;
  }
  if (TERMINAL_STATUSES.has(observation.status)) {
    const cause = observation.cause ? ` (${observation.cause})` : '';
    const error = observation.error ? ` — ${observation.error}` : '';
    return `${observation.id}: ${observation.status}${cause}${error}`;
  }
  if (observation.status === 'unknown') {
    return `${observation.id}: not present in the run manifest`;
  }
  if (observation.status === 'following') {
    return `${observation.id}: following the daemon turn — the worker exited, the session is still in flight`;
  }
  return `${observation.id}: ${observation.status}${observation.error ? ` — ${observation.error}` : ''}`;
}

/**
 * Waits until every submitted task is observably resolved, then reports what
 * was seen. Resolution is event-first (a directory watcher on the run) with a
 * bounded rescan, never a scheduled poll loop.
 */
function observeLaunch(runDir, taskIds, { verifyMs = DEFAULT_VERIFY_MS } = {}) {
  const ids = [...new Set((taskIds || []).filter(Boolean))];
  const startedAt = Date.now();
  if (verifyMs <= 0 || ids.length === 0) {
    const observed = ids.map((id) => observeTaskState(runDir, id)
      ?? { id, status: 'unknown', settled: false, spawnFailed: false });
    return Promise.resolve({
      verified: false,
      waitedMs: 0,
      timeoutMs: verifyMs,
      timedOut: false,
      observed,
      spawnFailed: observed.filter((entry) => entry.spawnFailed).map((entry) => entry.id),
      summary: observed.map((entry) => entry.line ?? formatObservationLine(entry)),
    });
  }

  const manifestPath = runPaths(runDir).manifest;
  const observations = new Map();
  return new Promise((resolvePromise) => {
    let watcher = null;
    let rescan = null;
    let deadline = null;
    let done = false;
    const finish = (timedOut) => {
      if (done) return;
      done = true;
      clearInterval(rescan);
      clearTimeout(deadline);
      try { watcher?.close(); } catch {}
      const observed = ids.map((id) => observations.get(id) ?? {
        id,
        status: 'unknown',
        settled: false,
        spawnFailed: false,
        line: `${id}: not present in the run manifest`,
      });
      resolvePromise({
        verified: true,
        waitedMs: Date.now() - startedAt,
        timeoutMs: verifyMs,
        timedOut,
        observed,
        spawnFailed: observed.filter((entry) => entry.spawnFailed).map((entry) => entry.id),
        summary: observed.map((entry) => entry.line ?? formatObservationLine(entry)),
      });
    };
    const check = () => {
      let allSettled = true;
      let runStale = false;
      for (const id of ids) {
        const observation = observeTaskState(runDir, id);
        if (observation) {
          observations.set(id, observation);
          if (observation.runStatus === 'stale') runStale = true;
        }
        if (!observations.get(id)?.settled) allSettled = false;
      }
      if (allSettled) finish(false);
      else if (runStale) finish(false);
    };
    try {
      watcher = watch(dirname(manifestPath), (_eventType, filename) => {
        if (!filename || String(filename) === basename(manifestPath)) check();
      });
      watcher.once('error', () => {});
    } catch {
      // The bounded rescan below keeps verification working without a watcher.
    }
    rescan = setInterval(check, Math.max(VERIFY_MIN_INTERVAL_MS, Math.min(250, Math.floor(verifyMs / 8) || 50)));
    deadline = setTimeout(() => finish(true), verifyMs);
    // Register first and rescan second so a state that already changed is seen.
    check();
  });
}

function waitForRunCompletion(runDir, timeoutMs = 60_000) {
  const manifestPath = runPaths(runDir).manifest;
  return new Promise((resolvePromise, reject) => {
    let watcher;
    let deadlineTimer;
    const cleanup = () => {
      if (deadlineTimer) clearTimeout(deadlineTimer);
      try { watcher?.close(); } catch {}
    };
    const check = () => {
      let manifest;
      try {
        manifest = loadManifest(runDir);
      } catch {
        return;
      }
      if (manifest.status === 'running' && !processIsAlive(manifest.supervisorPid)) {
        // The worker writes its terminal state before it exits, so a reader can
        // observe "running" from a read that happened just before that write and a
        // dead pid from a check that happened just after the exit. The status is
        // re-read before a death is concluded, because a completion that this
        // window hides must never be reported as a lost supervisor.
        let latest = null;
        try {
          latest = loadManifest(runDir);
        } catch {
          latest = null;
        }
        cleanup();
        if (latest && ['completed', 'stale'].includes(latest.status)) {
          resolvePromise(latest);
          return;
        }
        reject(new Error('supervisor process died before the run completed'));
        return;
      }
      if (!['completed', 'stale'].includes(manifest.status)) return;
      cleanup();
      resolvePromise(manifest);
    };
    try {
      watcher = watch(dirname(manifestPath), (_eventType, filename) => {
        if (!filename || String(filename) === basename(manifestPath)) check();
      });
      watcher.once('error', (error) => {
        cleanup();
        reject(new Error(`run completion watch failed: ${error.message}`));
      });
    } catch (error) {
      reject(new Error(`run completion watch failed: ${error.message}`));
      return;
    }
    deadlineTimer = setTimeout(() => {
      cleanup();
      reject(new Error(`run did not complete within ${timeoutMs}ms`));
    }, timeoutMs);
    // Register first and rescan second to close the read/watch race.
    check();
  });
}

async function closeCommand(options) {
  const runDir = singleRun(options, 'close');
  const abortQueued = options['abort-queued'] === true;
  try {
    const ack = await sendControlRequest(runDir, { type: 'close', abortQueued });
    if (options.wait) await waitForRunCompletion(runDir);
    const finalManifest = loadManifest(runDir);
    const aborted = ack.aborted || [];
    if (options.json) {
      process.stdout.write(`${JSON.stringify({
        runDir,
        closed: true,
        status: finalManifest.status,
        abortQueued,
        aborted,
      }, null, 2)}\n`);
    } else {
      process.stdout.write(`Closed run ${runDir} (status: ${finalManifest.status})\n`);
      if (aborted.length) {
        process.stdout.write(`  aborted ${aborted.length} task(s): ${aborted.join(', ')}\n`);
      } else if (abortQueued) {
        process.stdout.write('  no queued or held tasks needed aborting\n');
      }
    }
  } catch (error) {
    fail(error.message, 1);
  }
}

function formatDuration(ms) {
  if (ms == null || isNaN(ms) || ms < 0) return 'unknown';
  const totalSeconds = Math.floor(ms / 1000);
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = totalSeconds % 60;
  if (hours > 0) return `${hours}h ${minutes}m ${seconds}s`;
  if (minutes > 0) return `${minutes}m ${seconds}s`;
  return `${seconds}s`;
}

function parseIsoMillis(value) {
  if (!value) return null;
  const parsed = new Date(value).getTime();
  return Number.isNaN(parsed) ? null : parsed;
}

// Queue ages and stall thresholds are often sub-second during a live
// investigation; printing `0s` for a configured 600ms limit hides the setting.
function formatShortDuration(ms) {
  if (ms == null || isNaN(ms) || ms < 0) return 'unknown';
  return ms < 1000 ? `${Math.round(ms)}ms` : formatDuration(ms);
}

function queuedStallThreshold(manifest) {
  const configured = Number(manifest?.queuedStallMs);
  return Number.isFinite(configured) && configured > 0 ? configured : DEFAULT_QUEUED_STALL_MS;
}

function progressThresholdMs(manifest, taskState = null) {
  const perTask = Number(taskState?.progressStallMs);
  if (Number.isFinite(perTask) && perTask > 0) return perTask;
  const configured = Number(manifest?.progressStallMs);
  return Number.isFinite(configured) && configured > 0 ? configured : DEFAULT_PROGRESS_STALL_MS;
}

/**
 * Progress age for one task: how long since the last observable progress.
 *
 * `status` recomputes this on read (a caller that never watched must still see
 * a silent turn), and the same computation drives the worker's stall notices.
 */
function describeProgress(manifest, task, now = Date.now()) {
  const thresholdMs = progressThresholdMs(manifest, task);
  const reference = task.lastProgressAt ?? task.startedAt ?? task.stateSince ?? null;
  const referenceMs = reference ? parseIsoMillis(reference) : null;
  const silentForMs = referenceMs == null ? null : Math.max(0, now - referenceMs);
  const live = ['running', 'resuming'].includes(task.status);
  return {
    lastProgressAt: task.lastProgressAt ?? null,
    silentForMs,
    thresholdMs,
    // `blocked`, `waiting`, and intervention states are already actionable
    // transitions; only a live turn can be silent.
    stalled: live && silentForMs != null && silentForMs >= thresholdMs,
    noticed: task.progressStall ?? null,
  };
}

// Queue order is FIFO by the moment a task entered `queued`: the worker stamps
// `queuedSeq` on every transition, so a read-only `status` reproduces exactly
// the positions the worker uses when it fills slots.
function queueSnapshot(manifest) {
  const active = Number.isInteger(manifest?.active) ? manifest.active : 0;
  const maxConcurrency = Number.isInteger(manifest?.maxConcurrency) ? manifest.maxConcurrency : null;
  const entries = Object.entries(manifest?.tasks || {});
  const queued = entries
    .filter(([, state]) => state?.status === 'queued')
    .map(([id, state], index) => ({
      id,
      state,
      order: Number.isInteger(state.queuedSeq)
        ? state.queuedSeq
        : Number.MAX_SAFE_INTEGER - entries.length + index,
    }))
    .sort((left, right) => left.order - right.order)
    .map((entry, index) => ({ id: entry.id, state: entry.state, position: index + 1 }));
  return { active, maxConcurrency, queued };
}

// Why a task is still waiting: a full slot is the honest answer, and a task
// that outlives the stall threshold while slots are occupied is flagged so a
// silent queue can never be mistaken for progress.
function describeQueuedTask(manifest, id, now = Date.now()) {
  const snapshot = queueSnapshot(manifest);
  const entry = snapshot.queued.find((item) => item.id === id);
  if (!entry) return null;
  const counts = `${snapshot.active}/${snapshot.maxConcurrency ?? '?'} active`;
  const queuedAt = entry.state.queuedAt ?? null;
  const queuedForMs = queuedAt == null ? null : Math.max(0, now - (parseIsoMillis(queuedAt) ?? now));
  const awaitingSlot = snapshot.maxConcurrency != null && snapshot.active >= snapshot.maxConcurrency;
  return {
    position: entry.position,
    queuedTotal: snapshot.queued.length,
    active: snapshot.active,
    maxConcurrency: snapshot.maxConcurrency,
    queuedAt,
    queuedForMs,
    stallThresholdMs: queuedStallThreshold(manifest),
    stalled: entry.state.queueStall != null
      || (awaitingSlot && queuedForMs != null && queuedForMs >= queuedStallThreshold(manifest)),
    reason: awaitingSlot ? 'awaiting_slot' : 'launch_pending',
    reasonText: awaitingSlot
      ? `waiting for a concurrency slot (${counts})`
      : `slot is free but the task is not launched yet (${counts})`,
  };
}

function queueOutcomes(manifest, ids) {
  const snapshot = queueSnapshot(manifest);
  return ids.map((id) => {
    const state = manifest?.tasks?.[id];
    if (state?.status === 'queued') {
      return { id, status: 'queued', ...describeQueuedTask(manifest, id) };
    }
    return {
      id,
      // A launched task is reported as `started`, the operator-facing word for
      // "it left the queue and is now occupying a slot".
      status: state?.status === 'running' ? 'started' : (state?.status ?? 'unknown'),
      position: null,
      queuedTotal: snapshot.queued.length,
      active: snapshot.active,
      maxConcurrency: snapshot.maxConcurrency,
    };
  });
}

function formatQueueOutcome(outcome) {
  const counts = `${outcome.active}/${outcome.maxConcurrency ?? '?'} active`;
  if (outcome.status === 'started') return `${outcome.id}: started (${counts})`;
  if (outcome.status === 'queued') {
    return `${outcome.id}: queued at position ${outcome.position} of ${outcome.queuedTotal}`
      + ` — ${outcome.reasonText}, queued for ${formatShortDuration(outcome.queuedForMs)}`;
  }
  if (outcome.status === 'held') {
    return `${outcome.id}: held — not queued until enqueue --task ${outcome.id} (${counts})`;
  }
  return `${outcome.id}: ${outcome.status} (${counts})`;
}

function resolveSessionDetails(task, manifest) {
  let result = null;
  if (task.resultPath && existsSync(task.resultPath)) {
    try {
      result = JSON.parse(readFileSync(task.resultPath, 'utf8'));
    } catch {}
  }

  const pid = task.pid ?? manifest?.tasks?.[task.id]?.pid ?? null;
  const isAlive = pid ? processIsAlive(pid) : false;
  const terminalStates = new Set(['completed', 'failed', 'timeout', 'cancelled', 'aborted', 'interrupted', 'incomplete', 'needs_review', 'follow_lost']);
  // Once the supervisor observes process exit, its terminal transition wins
  // over a stale nonterminal result artifact.
  const rawStatus = terminalStates.has(task.status)
    ? task.status
    : (result?.status || task.status);
  const cause = result?.cause || task.cause || (rawStatus === 'timeout' ? 'timeout' : null);
  let stateSince = result?.state_since || result?.stateSince || null;
  if (!stateSince && task.status === rawStatus) stateSince = task.stateSince || null;
  if (!stateSince && terminalStates.has(rawStatus)) {
    stateSince = task.finishedAt || result?.ended_at || result?.endedAt || null;
  }
  const lastProgressAt = result?.last_progress_at || result?.lastProgressAt || task.lastProgressAt || null;

  let sessionState = 'unknown';
  if (rawStatus === 'completed') {
    sessionState = 'completed';
  } else if (rawStatus === 'incomplete') {
    sessionState = 'incomplete';
  } else if (rawStatus === 'needs_review') {
    sessionState = 'needs review';
  } else if (terminalStates.has(rawStatus)) {
    sessionState = 'stopped';
  } else if (rawStatus === 'needs_input') {
    sessionState = 'waiting for input';
  } else if (rawStatus === 'needs_permission') {
    sessionState = 'waiting for permission';
  } else if (rawStatus === 'waiting') {
    sessionState = 'waiting';
  } else if (rawStatus === 'blocked') {
    sessionState = 'blocked';
  } else if (rawStatus === 'resuming') {
    sessionState = 'resuming';
  } else if (rawStatus === 'following') {
    // The worker is gone but the daemon still owns the turn: walking away here is
    // exactly the failure this state was added to prevent.
    sessionState = 'following the daemon turn';
  } else if (rawStatus === 'follow_lost') {
    sessionState = 'follow lost';
  } else if (rawStatus === 'running') {
    // PID liveness proves only that a process exists. Report working only when
    // the runtime or supervisor recorded actual progress.
    sessionState = lastProgressAt ? 'working' : 'unknown';
  } else if (rawStatus === 'queued') {
    sessionState = 'queued';
  } else if (rawStatus === 'held') {
    sessionState = 'held';
  }

  const parseMillis = (value) => {
    if (!value) return null;
    const parsed = new Date(value).getTime();
    return Number.isNaN(parsed) ? null : parsed;
  };
  const explicitDuration = result?.duration_ms ?? result?.durationMs ?? null;
  const startTime = parseMillis(task.startedAt || result?.started_at || result?.startedAt);
  const endTime = parseMillis(task.finishedAt || result?.ended_at || result?.endedAt)
    ?? (terminalStates.has(rawStatus) ? null : Date.now());
  const elapsedMs = Number.isFinite(explicitDuration)
    ? explicitDuration
    : (startTime != null && endTime != null ? Math.max(0, endTime - startTime) : null);

  let observationSource = result ? 'result.json' : 'manifest';
  if (task.follow) {
    // A followed task is observed through the daemon, not through a process: say
    // so instead of implying that a pid proves the turn is working.
    observationSource = `daemon session (followed, ${task.follow.lastPollAt ? `last poll ${task.follow.lastPollAt}` : 'no poll yet'})`;
  } else if (pid) {
    observationSource += isAlive ? ` (process alive: ${pid})` : ' (process not running)';
  }

  const formatIso = (value, fallback) => {
    if (!value) return fallback;
    const parsed = new Date(value);
    return Number.isNaN(parsed.getTime()) ? fallback : parsed.toISOString();
  };

  return {
    taskId: task.id,
    sessionState,
    cause: cause || '-',
    stateSince: formatIso(stateSince, '[unknown time]'),
    lastProgressAt: formatIso(lastProgressAt, '-'),
    elapsed: formatDuration(elapsedMs),
    elapsedMs,
    observationSource,
    // Follow facts ride with the observation instead of being inferred by a
    // reader from a pid that no longer exists.
    follow: task.follow
      ? {
        active: task.follow.active === true,
        reason: task.follow.reason ?? null,
        since: formatIso(task.follow.since, '[unknown time]'),
        deadlineAt: formatIso(task.follow.deadlineAt, '-'),
        lastPollAt: formatIso(task.follow.lastPollAt, 'never'),
        polls: Number(task.follow.polls) || 0,
        resultSource: task.follow.resultSource ?? null,
      }
      : null,
    currentTime: new Date().toISOString(),
  };
}

function formatSessionFooter(details) {
  return [
    '--- Session Observability ---',
    `Task ID:            ${details.taskId}`,
    `Session State:      ${details.sessionState}`,
    `Cause:              ${details.cause}`,
    `State Since:        ${details.stateSince}`,
    `Last Progress:      ${details.lastProgressAt}`,
    `Elapsed:            ${details.elapsed}`,
    `Observation Source: ${details.observationSource}`,
    ...(details.follow
      ? [`Follow:             ${details.follow.active ? 'active' : 'ended'}`
        + ` since ${details.follow.since}`
        + `, deadline ${details.follow.deadlineAt}`
        + `, polls ${details.follow.polls}`
        + `, last poll ${details.follow.lastPollAt}`
        + `${details.follow.resultSource ? `, result from ${details.follow.resultSource}` : ''}`]
      : []),
    `Current Time:       ${details.currentTime}`,
    '-----------------------------',
  ].join('\n');
}

function readManifestQuiet(runDir) {
  const path = runPaths(runDir).manifest;
  if (!existsSync(path)) return null;
  try {
    return JSON.parse(readFileSync(path, 'utf8'));
  } catch {
    return null;
  }
}

function loadCursor(cursorPath) {
  if (!existsSync(cursorPath)) return { version: CURSOR_VERSION, updatedAt: null, runs: {} };
  let value;
  try {
    value = JSON.parse(readFileSync(cursorPath, 'utf8'));
  } catch (error) {
    fail(`cannot read watch cursor ${cursorPath}: ${error.message}`);
  }
  if (value?.version !== CURSOR_VERSION || value.runs === null || typeof value.runs !== 'object') {
    fail(`unsupported watch cursor at ${cursorPath}`);
  }
  return value;
}

function cursorSeq(cursor, runDir) {
  const seq = Number(cursor.runs?.[runDir]?.seq);
  return Number.isInteger(seq) && seq >= 0 ? seq : 0;
}

// Cursor writes are atomic (temp file + rename), so a watcher that is killed
// mid-write can never leave a truncated cursor that replays or skips events.
function saveCursor(cursorPath, cursor) {
  cursor.updatedAt = new Date().toISOString();
  writeJsonAtomic(cursorPath, cursor);
}

function runIsFinished(runDir) {
  const manifest = readManifestQuiet(runDir);
  if (!manifest) return true;
  if (['completed', 'stale', 'failed'].includes(manifest.status)) return true;
  if (manifest.closed) {
    const tasks = Object.values(manifest.tasks || {});
    if (tasks.every((task) => TERMINAL_STATUSES.has(task?.status))) return true;
  }
  return false;
}

/**
 * Repairs a run whose supervisor is gone.
 *
 * A dead supervisor leaves tasks parked in a live-looking state forever, which
 * is how a coordinator ends up believing five sessions are running when only
 * four are. Nothing else can write this run, so the repair is performed here
 * (and journaled exactly like a worker transition). A live run is never
 * touched: its worker owns task state.
 */
function reconcileRun(runDir) {
  const paths = runPaths(runDir);
  const manifest = readManifestQuiet(runDir);
  if (!manifest) return { runDir, manifest: null, changed: false, lost: [], recovered: [], orphaned: [] };
  let changed = false;
  let supervisorDied = false;
  if (manifest.status === 'running' && !processIsAlive(manifest.supervisorPid)) {
    supervisorDied = true;
    manifest.status = 'stale';
    manifest.staleReason = 'Supervisor process is not running.';
    manifest.supervisorDeadAt = new Date().toISOString();
    changed = true;
  }
  const outcome = { runDir, manifest, changed, lost: [], recovered: [], orphaned: [] };
  if (manifest.status !== 'stale') return outcome;

  let seq = Number.isInteger(manifest.seq) ? manifest.seq : 0;
  const records = [];
  // A dead supervisor with work still non-terminal is its own, actionable fact:
  // nothing will ever advance those tasks again. It is reported once, at the
  // moment the run is repaired, and it is deliberately not a `progress_stall` —
  // that one only says a single task went quiet while its supervisor is alive.
  if (supervisorDied && manifest.supervisorDeadNoticed !== true) {
    const nonTerminal = Object.entries(manifest.tasks || {})
      .filter(([, task]) => task && !TERMINAL_STATUSES.has(task.status))
      .map(([id]) => id);
    if (nonTerminal.length > 0) {
      seq += 1;
      records.push({
        seq,
        taskId: null,
        implementer: null,
        workspace: null,
        from: 'running',
        to: 'supervisor_dead',
        at: manifest.supervisorDeadAt,
        kind: 'supervisor_dead',
        supervisorPid: manifest.supervisorPid ?? null,
        nonTerminal,
      });
      manifest.supervisorDeadNoticed = true;
    }
  }
  for (const [id, task] of Object.entries(manifest.tasks || {})) {
    if (!task) continue;
    if (TERMINAL_STATUSES.has(task.status)) {
      // A completion that landed after the supervisor died must still be
      // reported: an already-repaired `failed/worker_lost` task upgrades to the
      // task's own terminal artifact instead of staying wrong forever.
      if (task.cause === 'worker_lost') {
        const late = readResultDigest(task.resultPath);
        if (late?.status && TERMINAL_STATUSES.has(late.status) && resultBelongsToTask(task, late)) {
          seq += 1;
          task.status = late.status;
          task.cause = 'result_recorded_after_exit';
          task.error = null;
          task.result = late;
          task.laterResult = null;
          records.push({
            seq,
            taskId: id,
            implementer: task.implementer ?? null,
            workspace: task.workspace ?? null,
            from: 'failed',
            to: late.status,
            at: new Date().toISOString(),
            kind: 'recovered',
            cause: 'result_recorded_after_exit',
            recovered: true,
          });
          outcome.recovered.push(id);
          changed = true;
        }
      } else {
        // A terminal task keeps its own outcome. If the artifact on its path was
        // produced after it settled (a later attempt reused the same --out-dir),
        // it is reported as `later-result` for triage instead of being adopted or
        // printed as this task's result. A followed task is the same case with a
        // stronger reason: its verdict came from the durable session.
        if (applyVisibleResult(task, readResultDigest(task.resultPath)) === 'later') changed = true;
      }
      continue;
    }
    if (['queued', 'held'].includes(task.status)) continue;
    const from = task.status;
    // A followed task has no worker to lose: the supervisor died while polling a
    // daemon-owned turn, so nothing here can observe that turn again. A terminal
    // artifact written during the follow is still adopted; otherwise the honest
    // report is that the outcome is unknown, not that the worker vanished.
    if (task.follow?.active === true) {
      const lateFollow = readResultDigest(task.resultPath);
      const adoptFollow = lateFollow?.status && TERMINAL_STATUSES.has(lateFollow.status)
        && resultBelongsToTask(task, lateFollow);
      const followStatus = adoptFollow ? lateFollow.status : 'failed';
      const followFinishedAt = new Date().toISOString();
      Object.assign(task, {
        status: followStatus,
        finishedAt: followFinishedAt,
        stateSince: followFinishedAt,
        cause: adoptFollow ? 'result_recorded_after_exit' : 'follow_abandoned',
        recovered: true,
        follow: { ...task.follow, active: false, endedAt: followFinishedAt },
        ...(adoptFollow ? { result: lateFollow } : {}),
      });
      if (!adoptFollow) {
        task.error = 'the supervisor died while following the daemon session; the turn outcome is unknown';
      }
      seq += 1;
      records.push({
        seq,
        taskId: id,
        implementer: task.implementer ?? null,
        workspace: task.workspace ?? null,
        from,
        to: followStatus,
        at: followFinishedAt,
        kind: adoptFollow ? 'recovered' : 'follow_abandoned',
        cause: task.cause,
        recovered: true,
      });
      if (adoptFollow) outcome.recovered.push(id);
      else outcome.lost.push(id);
      changed = true;
      continue;
    }
    // A process that is still alive is still running, even though its
    // supervisor is gone. Failing it would be as wrong as claiming it is
    // healthy, so the run reports it as orphaned and journals that once; the
    // next read after the process exits records the real `worker_lost` outcome.
    if (processIsAlive(task.pid)) {
      const orphanFields = {
        orphaned: true,
        orphanPid: task.pid,
        orphanNote: 'process outlived its supervisor and is unmanaged',
        orphanSince: task.orphanSince ?? new Date().toISOString(),
      };
      const needsNotice = task.orphanNoticed !== true;
      Object.assign(task, orphanFields, needsNotice ? { orphanNoticed: true } : {});
      if (needsNotice) {
        seq += 1;
        records.push({
          seq,
          taskId: id,
          implementer: task.implementer ?? null,
          workspace: task.workspace ?? null,
          from,
          to: from,
          at: new Date().toISOString(),
          kind: 'worker_orphaned',
          cause: 'supervisor_stale',
          orphanPid: task.pid,
        });
      }
      outcome.orphaned.push(id);
      changed = true;
      continue;
    }
    const digest = readResultDigest(task.resultPath);
    const terminalFromResult = digest?.status && TERMINAL_STATUSES.has(digest.status)
      && resultBelongsToTask(task, digest);
    const status = terminalFromResult ? digest.status : 'failed';
    const cause = terminalFromResult ? 'result_recorded_after_exit' : 'worker_lost';
    const finishedAt = new Date().toISOString();
    Object.assign(task, {
      status,
      finishedAt,
      stateSince: finishedAt,
      cause,
      recovered: true,
      orphaned: false,
      ...(digest ? { result: digest } : {}),
    });
    if (!terminalFromResult) {
      task.error = 'task process is no longer running and no terminal result was recorded';
    }
    seq += 1;
    records.push({
      seq,
      taskId: id,
      implementer: task.implementer ?? null,
      workspace: task.workspace ?? null,
      from,
      to: status,
      at: finishedAt,
      kind: terminalFromResult ? 'recovered' : 'worker_lost',
      cause,
      recovered: true,
    });
    if (terminalFromResult) outcome.recovered.push(id);
    else outcome.lost.push(id);
    changed = true;
  }
  if (records.length) {
    appendFileSync(paths.journal, records.map((record) => `${JSON.stringify(record)}\n`).join(''), 'utf8');
  }
  if (changed) {
    // Live counters belong to the dead worker, so they are recomputed here
    // instead of being carried over into a repaired manifest.
    manifest.active = Object.values(manifest.tasks || {})
      .filter((task) => task && !TERMINAL_STATUSES.has(task.status) && !['queued', 'held'].includes(task.status))
      .length;
    manifest.seq = seq;
    writeJsonAtomic(paths.manifest, manifest);
  }
  outcome.changed = changed;
  return outcome;
}

/**
 * Renders one journal record for a coordinator: the transition, its elapsed
 * time, and — for a terminal outcome — the result status, artifact path, and
 * any branch/SHA/PR the task published. No second call is needed to triage.
 */
function enrichWatchEvent(runDir, event) {
  const actionable = isActionableEvent(event);
  const manifest = readManifestQuiet(runDir);
  const task = event.taskId ? manifest?.tasks?.[event.taskId] ?? null : null;
  const at = event.at ?? event.timestamp ?? null;
  const enriched = {
    version: WATCH_EVENT_VERSION,
    run: runDir,
    ...event,
    actionable,
  };
  if (!event.taskId) {
    // A dead supervisor is a run-level fact, so the line names the lost pid and
    // the tasks it left non-terminal instead of pretending a task stalled.
    const detail = event.kind === 'supervisor_dead'
      ? ` (supervisor pid ${event.supervisorPid ?? '?'} is gone;`
        + ` ${(event.nonTerminal ?? []).length} non-terminal task(s): ${(event.nonTerminal ?? []).join(', ')})`
      : (event.cause ? ` (${event.cause})` : '');
    enriched.line = `${at ?? '[unknown time]'}  RUN ${event.to}${detail}`;
    return enriched;
  }
  const terminal = TERMINAL_STATUSES.has(event.to);
  const startedAt = task?.startedAt ?? null;
  const finishedAt = task?.finishedAt ?? at;
  const elapsedMs = startedAt
    ? Math.max(0, (parseIsoMillis(finishedAt) ?? Date.now()) - (parseIsoMillis(startedAt) ?? 0))
    : null;
  const result = terminal ? taskResultForView(task) : null;
  enriched.elapsedMs = elapsedMs;
  enriched.elapsed = elapsedMs == null ? null : formatDuration(elapsedMs);
  enriched.attempt = task?.attempt ?? 1;
  if (result) enriched.result = result;

  const parts = [
    `${at ?? '[unknown time]'}`,
    event.taskId,
    `${event.from ?? '?'} -> ${event.to}${event.cause ? ` (${event.cause})` : ''}`,
  ];
  if (enriched.elapsed) parts.push(`elapsed ${enriched.elapsed}`);
  if (enriched.attempt > 1) parts.push(`attempt ${enriched.attempt}`);
  if (result) {
    if (result.status) parts.push(`result ${result.status}`);
    if (result.prUrl) parts.push(`pr ${result.prUrl}`);
    if (result.headSha) parts.push(`sha ${result.headSha}`);
    if (result.branch) parts.push(`branch ${result.branch}`);
    if (result.summary) parts.push(`summary ${result.summary}`);
    parts.push(`result-file ${result.path}`);
  }
  enriched.line = parts.join('  ');
  return enriched;
}

/**
 * `watch` is the coordinator interface: several runs, a durable cursor, and one
 * line per actionable event. Nothing that happened while no watcher ran is
 * lost, and nothing already handled is printed twice.
 */
async function watchCommand(options) {
  const runDirs = [...new Set(options.runs.map((entry) => resolve(entry)))];
  if (!runDirs.length) fail('watch requires at least one --run');
  for (const runDir of runDirs) {
    if (!existsSync(runDir)) fail(`run directory does not exist: ${runDir}`);
  }
  if (!options.cursor) fail('watch requires --cursor <file>');
  const cursorPath = resolve(options.cursor);
  const once = options.once === true;
  const includeAll = options.all === true;
  const timeoutMs = secondsOption(options, 'timeout-sec', 0, '--timeout-sec');

  const cursor = loadCursor(cursorPath);
  const runs = runDirs.map((runDir) => ({
    runDir,
    journal: runPaths(runDir).journal,
    manifest: runPaths(runDir).manifest,
    handled: cursorSeq(cursor, runDir),
  }));

  const pendingCursor = new Map();
  let inFlight = 0;
  let drained = null;
  let wake = null;
  let stopped = false;
  const watchers = [];

  const flushCursor = () => {
    let changed = false;
    for (const [runDir, seq] of pendingCursor) {
      if (seq > cursorSeq(cursor, runDir)) {
        cursor.runs[runDir] = { seq, updatedAt: new Date().toISOString() };
        changed = true;
      }
    }
    pendingCursor.clear();
    if (changed) saveCursor(cursorPath, cursor);
  };

  const whenDrained = () => {
    if (inFlight === 0) return Promise.resolve();
    return new Promise((resolvePromise) => { drained = resolvePromise; });
  };

  const emit = (entry) => {
    const line = options.json
      ? `${JSON.stringify(entry)}\n`
      : `${entry.line}\n`;
    inFlight += 1;
    // The cursor advances only after this line is flushed, so a watcher that
    // dies mid-print replays the event instead of losing it.
    process.stdout.write(line, () => {
      inFlight -= 1;
      if (inFlight === 0) {
        flushCursor();
        const resolver = drained;
        drained = null;
        resolver?.();
      }
    });
  };

  const scan = () => {
    const batch = [];
    for (const run of runs) {
      const events = readJournalEvents(run.journal);
      let boundary = run.handled;
      for (const event of events) {
        if (event.seq > boundary) boundary = event.seq;
        if (event.seq <= run.handled) continue;
        const enriched = enrichWatchEvent(run.runDir, event);
        if (includeAll || enriched.actionable) batch.push(enriched);
      }
      if (boundary > (pendingCursor.get(run.runDir) ?? 0)) pendingCursor.set(run.runDir, boundary);
    }
    batch.sort((left, right) => {
      const leftAt = parseIsoMillis(left.at ?? left.timestamp) ?? 0;
      const rightAt = parseIsoMillis(right.at ?? right.timestamp) ?? 0;
      if (leftAt !== rightAt) return leftAt - rightAt;
      return left.seq - right.seq;
    });
    return batch;
  };

  const cycle = async () => {
    for (const runDir of runDirs) reconcileRun(runDir);
    const batch = scan();
    for (const entry of batch) emit(entry);
    for (const run of runs) {
      run.handled = Math.max(run.handled, pendingCursor.get(run.runDir) ?? 0);
    }
    await whenDrained();
    flushCursor();
    return batch.length;
  };

  const announce = () => {
    const resolver = wake;
    wake = null;
    resolver?.();
  };
  const waitForWake = () => new Promise((resolvePromise) => { wake = resolvePromise; });

  for (const dir of new Set(runs.map((run) => dirname(run.journal)))) {
    try {
      const watcher = watch(dir, (_eventType, filename) => {
        if (!filename) {
          announce();
          return;
        }
        const name = String(filename);
        if (runs.some((run) => name === basename(run.journal) || name === basename(run.manifest))) {
          announce();
        }
      });
      watcher.once('error', () => {});
      watchers.push(watcher);
    } catch {
      // The bounded liveness rescan below keeps the watcher working.
    }
  }
  // Filesystem events are the primary wake-up path; this bounded rescan also
  // repairs a run whose supervisor died while no watcher was listening.
  const liveness = setInterval(announce, 500);
  const stop = () => {
    if (stopped) return;
    stopped = true;
    clearInterval(liveness);
    for (const watcher of watchers) {
      try { watcher.close(); } catch {}
    }
  };

  const deadline = timeoutMs > 0
    ? setTimeout(() => {
      stop();
      process.stderr.write(`supervisor: watch timed out after ${timeoutMs}ms with no new actionable event\n`);
      process.exit(4);
    }, timeoutMs)
    : null;
  if (deadline && typeof deadline.unref === 'function') deadline.unref();

  const finishIfAllRunsEnded = () => {
    if (!runDirs.every((runDir) => runIsFinished(runDir))) return false;
    stop();
    return true;
  };

  try {
    while (!stopped) {
      const printed = await cycle();
      if (once && printed > 0) {
        stop();
        return;
      }
      if (finishIfAllRunsEnded()) return;
      if (once && printed === 0) {
        // Nothing actionable yet: wait for the next wake-up instead of
        // re-invoking the caller with an empty batch.
        await waitForWake();
        continue;
      }
      await waitForWake();
    }
  } finally {
    stop();
  }
}

// One run's read view. `status` repairs a run whose supervisor is gone (that is
// the only writer left) and never mutates a live run.
function statusSnapshot(runDir) {
  const manifest = loadManifest(runDir);
  if (manifest.status === 'running' && !processIsAlive(manifest.supervisorPid)) {
    manifest.status = 'stale';
    manifest.staleReason = 'Supervisor process is not running.';
  }
  const snapshot = queueSnapshot(manifest);
  for (const task of Object.values(manifest.tasks || {})) {
    const details = resolveSessionDetails(task, manifest);
    task.sessionState = details.sessionState;
    task.sessionCause = details.cause;
    task.lastProgressAt = details.lastProgressAt !== '-' ? details.lastProgressAt : null;
    task.stateSince = details.stateSince !== '[unknown time]' ? details.stateSince : null;
    // A queued task always carries its position, the live counts, the reason
    // it is waiting, and whether it already exceeded the stall threshold.
    const queue = task.status === 'queued' ? describeQueuedTask(manifest, task.id) : null;
    if (queue) task.queue = queue;
    // Progress age is recomputed on read: a caller that never watched still
    // sees a silent turn instead of an apparently busy one.
    task.progress = describeProgress(manifest, task);
    // The visible result of this task, decided once for every reader: a followed
    // task keeps the verdict it earned from the durable session, and a worker
    // artifact that disagrees with it is reported as `later-result` instead of
    // replacing it.
    applyVisibleResult(task, readResultDigest(task.resultPath));
  }
  manifest.active = snapshot.active;
  manifest.queuedStallMs = queuedStallThreshold(manifest);
  manifest.progressStallMs = progressThresholdMs(manifest);
  manifest.queue = {
    active: snapshot.active,
    maxConcurrency: snapshot.maxConcurrency,
    queued: snapshot.queued.map((entry) => ({
      id: entry.id,
      ...describeQueuedTask(manifest, entry.id),
    })),
  };
  // A run whose supervisor is alive but has nothing left to run is idle, not
  // running: the distinction is what tells a coordinator no progress is coming.
  // A followed task is still in flight even though it holds no worker slot, so a
  // run that only follows is never reported as idle.
  const following = Object.values(manifest.tasks || {})
    .some((task) => task?.follow?.active === true);
  manifest.idle = manifest.status === 'running'
    && snapshot.active === 0
    && snapshot.queued.length === 0
    && !following
    && !manifest.closed;
  return manifest;
}

/**
 * Retry facts for one task, computed the same way the worker does so a caller
 * that only reads the manifest sees the budget, the attempts already spent on
 * the current block, and the next deadline.
 */
function retryFacts(manifest, task) {
  const policy = manifest?.autoRetry ?? {};
  const episode = Number.isInteger(task?.retryEpisode) ? task.retryEpisode : 0;
  const entries = Array.isArray(task?.retryAttempts) ? task.retryAttempts : [];
  const attempts = entries.filter((entry) => entry && entry.episode === episode);
  return {
    enabled: task?.autoRetry == null ? policy.enabled === true : task.autoRetry === true,
    attempts: attempts.length,
    maxAttempts: Number.isInteger(policy.maxAttempts) ? policy.maxAttempts : DEFAULT_AUTO_RETRY_MAX_ATTEMPTS,
    nextRetryAt: task?.nextRetryAt ?? null,
    exhausted: Boolean(task?.retryExhaustedAt),
    lastResult: attempts.at(-1)?.result ?? null,
    lastExitCode: attempts.at(-1)?.exitCode ?? null,
    launchAttempts: Array.isArray(task?.launchRetries) ? task.launchRetries.length : 0,
    launchMaxAttempts: Number.isInteger(policy.launchMaxAttempts)
      ? policy.launchMaxAttempts
      : DEFAULT_LAUNCH_RETRY_MAX_ATTEMPTS,
  };
}

function briefTaskLine(manifest, task) {
  const details = resolveSessionDetails(task, manifest);
  const progress = task.progress ?? describeProgress(manifest, task);
  const parts = [task.id, task.status, `elapsed ${details.elapsed}`];
  // Progress age is only meaningful while a turn is live; a terminal task
  // showing "progress 3s ago" reads like activity that is not happening.
  const liveTask = ['running', 'resuming'].includes(task.status);
  parts.push(`progress ${!liveTask || progress.silentForMs == null
    ? '-'
    : `${formatShortDuration(progress.silentForMs)} ago`}`);
  if (task.status === 'queued' && task.queue) {
    parts.push(`queue #${task.queue.position}/${task.queue.queuedTotal} ${task.queue.reason}`);
  }
  if (progress.stalled) parts.push('PROGRESS_STALL');
  if (task.queueStall) parts.push('QUEUED_STALL');
  if ((task.attempt ?? 1) > 1) parts.push(`attempt ${task.attempt}`);
  // Retry facts belong on the task line: a blocked task without them looks like
  // a permanent stop, and an exhausted one looks identical to a fresh block.
  const retry = retryFacts(manifest, task);
  if (retry.attempts > 0) parts.push(`retries ${retry.attempts}/${retry.maxAttempts}`);
  if (retry.nextRetryAt) parts.push(`next-retry ${retry.nextRetryAt}`);
  if (retry.exhausted) parts.push('RETRY_EXHAUSTED');
  if (retry.launchAttempts > 0) parts.push(`launch-retries ${retry.launchAttempts}`);
  const result = taskResultForView(task);
  if (TERMINAL_STATUSES.has(task.status) || result) {
    parts.push(`result ${result?.status ?? task.status}`);
    if (result?.prUrl) parts.push(`pr ${result.prUrl}`);
    if (result?.headSha) parts.push(`sha ${result.headSha}`);
    if (result?.branch) parts.push(`branch ${result.branch}`);
    if (result?.summary) parts.push(`summary ${result.summary}`);
  }
  // A followed task reads like any other live task, so the line says where the
  // observation comes from and when the next probe is due.
  if (task.follow) {
    parts.push(`followed ${task.follow.active ? 'since' : 'until'} ${task.follow.since ?? '-'}`);
    parts.push(`polls ${Number(task.follow.polls) || 0}`);
    if (task.follow.active && task.follow.deadlineAt) parts.push(`follow-deadline ${task.follow.deadlineAt}`);
    if (task.follow.resultSource) parts.push(`result-source ${task.follow.resultSource}`);
  }
  if (task.laterResult) parts.push(`later-result ${task.laterResult.status}`);
  if (task.error) parts.push(`error ${String(task.error).slice(0, 160)}`);
  return `  ${parts.join('  ')}`;
}

function briefRunHeader(runDir, manifest) {
  const snapshot = queueSnapshot(manifest);
  const closedIndicator = manifest.closed ? ' (closed)' : '';
  const idleIndicator = manifest.idle ? ' (idle)' : '';
  return `RUN ${runDir}  ${manifest.status}${closedIndicator}${idleIndicator}`
    + `  active=${snapshot.active}/${snapshot.maxConcurrency ?? '?'}`
    + `  queued=${snapshot.queued.length}`
    + `  tasks=${Object.keys(manifest.tasks || {}).length}`
    + `  seq=${manifest.seq}`
    + `  supervisor=${manifest.supervisorPid}`;
}

function briefView(runDir, manifest) {
  return {
    runDir,
    status: manifest.status,
    closed: manifest.closed === true,
    idle: manifest.idle === true,
    active: manifest.active,
    maxConcurrency: manifest.maxConcurrency ?? null,
    seq: manifest.seq,
    supervisorPid: manifest.supervisorPid ?? null,
    tasks: Object.values(manifest.tasks || {}).map((task) => {
      const details = resolveSessionDetails(task, manifest);
      const progress = task.progress ?? describeProgress(manifest, task);
      const result = taskResultForView(task);
      return {
        id: task.id,
        status: task.status,
        attempt: task.attempt ?? 1,
        elapsed: details.elapsed,
        progressAgeMs: progress.silentForMs,
        progressStalled: progress.stalled,
        queue: task.queue
          ? { position: task.queue.position, queuedTotal: task.queue.queuedTotal, reason: task.queue.reason }
          : null,
        resultStatus: result?.status ?? (TERMINAL_STATUSES.has(task.status) ? task.status : null),
        resultPath: result?.path ?? task.resultPath ?? null,
        branch: result?.branch ?? null,
        headSha: result?.headSha ?? null,
        prUrl: result?.prUrl ?? null,
        summary: result?.summary ?? null,
        follow: task.follow
          ? {
            active: task.follow.active === true,
            reason: task.follow.reason ?? null,
            since: task.follow.since ?? null,
            deadlineAt: task.follow.deadlineAt ?? null,
            pollMs: task.follow.pollMs ?? null,
            polls: Number(task.follow.polls) || 0,
            lastPollAt: task.follow.lastPollAt ?? null,
            lastSnapshot: task.follow.lastSnapshot ?? null,
            resultSource: task.follow.resultSource ?? null,
            note: task.note ?? null,
          }
          : null,
        retry: retryFacts(manifest, task),
        laterResult: task.laterResult
          ? { status: task.laterResult.status, path: task.laterResult.path, startedAt: task.laterResult.startedAt ?? null }
          : null,
        error: task.error ?? null,
      };
    }),
  };
}

function statusCommand(options) {
  const runDirs = [...new Set(options.runs.map((entry) => resolve(entry)))];
  if (!runDirs.length) fail('status requires --run');
  const brief = options.brief === true;
  const snapshots = runDirs.map((runDir) => {
    reconcileRun(runDir);
    return { runDir, manifest: statusSnapshot(runDir) };
  });

  if (brief) {
    if (options.json) {
      const payload = {
        version: 'delegate-status-brief.v1',
        runs: snapshots.map(({ runDir, manifest }) => briefView(runDir, manifest)),
      };
      process.stdout.write(`${JSON.stringify(payload, null, 2)}\n`);
      return;
    }
    for (const { runDir, manifest } of snapshots) {
      process.stdout.write(`${briefRunHeader(runDir, manifest)}\n`);
      for (const task of Object.values(manifest.tasks || {})) {
        process.stdout.write(`${briefTaskLine(manifest, task)}\n`);
      }
    }
    return;
  }

  if (options.json) {
    if (snapshots.length === 1) {
      // A single run keeps its manifest shape, which existing callers parse.
      process.stdout.write(`${JSON.stringify(snapshots[0].manifest, null, 2)}\n`);
      return;
    }
    process.stdout.write(`${JSON.stringify({
      version: 'delegate-status.v1',
      runs: snapshots.map(({ runDir, manifest }) => ({ runDir, ...manifest })),
    }, null, 2)}\n`);
    return;
  }

  snapshots.forEach(({ runDir, manifest }, index) => {
    if (index > 0) process.stdout.write('\n');
    if (snapshots.length > 1) process.stdout.write(`${runDir}\n`);
    printVerboseStatus(manifest, options, snapshots.length);
  });
}

function printVerboseStatus(manifest, options, runCount = 1) {
  const closedIndicator = manifest.closed ? ' (closed)' : '';
  const idleIndicator = manifest.idle ? ' (idle)' : '';
  process.stdout.write(`RUN ${manifest.status}${closedIndicator}${idleIndicator}  seq=${manifest.seq}  supervisor=${manifest.supervisorPid}\n`);
  process.stdout.write('TASK\tIMPLEMENTER\tSTATUS\tPID\tWORKSPACE\n');
  for (const task of Object.values(manifest.tasks)) {
    process.stdout.write(`${task.id}\t${task.implementer}\t${task.status}\t${task.pid ?? '-'}\t${task.workspace}\n`);
  }

  const snapshot = queueSnapshot(manifest);
  if (snapshot.queued.length > 0) {
    process.stdout.write(
      `\nQUEUE active=${snapshot.active}/${snapshot.maxConcurrency ?? '?'}`
      + `  queued=${snapshot.queued.length}  stall-after=${formatShortDuration(queuedStallThreshold(manifest))}\n`,
    );
    for (const entry of snapshot.queued) {
      const description = describeQueuedTask(manifest, entry.id);
      process.stdout.write(
        `  ${entry.id}\tposition ${description.position} of ${description.queuedTotal}`
        + `\tqueued ${formatShortDuration(description.queuedForMs)}`
        + `\t${description.reason}: ${description.reasonText}`
        + `${description.stalled ? '  QUEUED_STALL' : ''}\n`,
      );
    }
  }

  const stalled = Object.values(manifest.tasks).filter((task) => task.progress?.stalled);
  if (stalled.length > 0) {
    process.stdout.write(
      `\nPROGRESS silent past ${formatShortDuration(progressThresholdMs(manifest))}:\n`,
    );
    for (const task of stalled) {
      process.stdout.write(
        `  ${task.id}\tno progress for ${formatShortDuration(task.progress.silentForMs)}`
        + `\t(last: ${task.progress.lastProgressAt ?? 'unknown'})\n`,
      );
    }
  }

  // Severed transport is its own section: a task whose worker exited is still
  // in flight, and an operator reading status must not mistake the missing pid
  // for a missing turn.
  const followed = Object.values(manifest.tasks).filter((task) => task.follow);
  if (followed.length > 0) {
    process.stdout.write('\nFOLLOW (worker exited, daemon turn in flight):\n');
    for (const task of followed) {
      const follow = task.follow;
      process.stdout.write(
        `  ${task.id}\t${follow.active ? 'following' : 'ended'}`
        + `\tsince ${follow.since ?? '-'}`
        + `\tdeadline ${follow.active ? follow.deadlineAt ?? '-' : '-'}`
        + `\tpolls ${Number(follow.polls) || 0}`
        + `\tlast poll ${follow.lastPollAt ?? 'never'}`
        + `${follow.resultSource ? `\tresult from ${follow.resultSource}` : ''}`
        + `${follow.lastSnapshot ? `\tlast seen ${follow.lastSnapshot.kind}` : ''}\n`,
      );
    }
  }

  const target = options.task && runCount === 1 ? requireTask(manifest, options.task) : null;
  if (target) {
    const details = resolveSessionDetails(target, manifest);
    process.stdout.write(`\n${formatSessionFooter(details)}\n`);
  } else if (runCount === 1 && !options.task) {
    for (const task of Object.values(manifest.tasks)) {
      const details = resolveSessionDetails(task, manifest);
      process.stdout.write(`\n${formatSessionFooter(details)}\n`);
    }
  }
}

function inspectCommand(options) {
  const runDir = singleRun(options, 'inspect');
  if (!options.task) fail('inspect requires --task <id>');
  const manifest = loadManifest(runDir);
  const task = requireTask(manifest, options.task);
  let result = null;
  if (task.resultPath && existsSync(task.resultPath)) {
    result = readJson(task.resultPath, `result for ${task.id}`);
  }
  process.stdout.write(`${JSON.stringify({ task, result }, null, 2)}\n`);
}

function readLastLines(path, count) {
  if (!existsSync(path)) return '';
  const lines = readFileSync(path, 'utf8').split(/\r?\n/);
  if (lines.at(-1) === '') lines.pop();
  const observed = lines.slice(-count).map((line) => formatTimelineLine(line));
  return `${observed.join('\n')}${observed.length ? '\n' : ''}`;
}

function formatObservedLogContent(content, receiptTime) {
  const lines = content.split(/\r?\n/);
  const trailingNewline = lines.at(-1) === '';
  if (trailingNewline) lines.pop();
  const observed = lines.map((line) => formatTimelineLine(line, receiptTime));
  return `${observed.join('\n')}${trailingNewline && observed.length ? '\n' : ''}`;
}

function followFiles(entries, options = {}) {
  const offsets = new Map();
  const watchers = [];
  const drain = (entry) => {
    if (!entry.path || !existsSync(entry.path)) return;
    const size = statSync(entry.path).size;
    const offset = offsets.get(entry.path) ?? 0;
    if (size < offset) offsets.set(entry.path, 0);
    const nextOffset = offsets.get(entry.path) ?? 0;
    if (size === nextOffset) return;
    const content = readFileSync(entry.path, 'utf8').slice(nextOffset);
    offsets.set(entry.path, size);
    const now = new Date().toISOString();
    entry.consume(content, now);
  };

  const runDir = options.runDir || null;
  const observerFile = runDir ? join(runDir, 'observers', `${process.pid}.json`) : null;
  const observerRecord = {
    pid: process.pid,
    command: options.command || 'follow',
    taskId: options.taskId || null,
    startedAt: new Date().toISOString(),
    endedAt: null,
    status: 'active',
    cancellationSignal: null,
  };

  if (observerFile) {
    try {
      mkdirSync(dirname(observerFile), { recursive: true });
      writeJsonAtomic(observerFile, observerRecord);
    } catch {}
  }

  for (const entry of entries) {
    if (entry.path && existsSync(entry.path)) offsets.set(entry.path, statSync(entry.path).size);
  }
  const directories = new Map();
  for (const entry of entries) {
    if (!entry.path) continue;
    const dir = dirname(entry.path);
    if (!existsSync(dir)) continue;
    if (!directories.has(dir)) directories.set(dir, []);
    directories.get(dir).push(entry);
  }
  for (const [dir, dirEntries] of directories) {
    const watcher = watch(dir, (_event, filename) => {
      for (const entry of dirEntries) {
        if (!filename || String(filename) === basename(entry.path)) drain(entry);
      }
    });
    watchers.push(watcher);
  }
  for (const entry of entries) drain(entry);

  const close = (signal = null) => {
    const endedAt = new Date().toISOString();
    for (const watcher of watchers) watcher.close();
    if (observerFile) {
      try {
        observerRecord.endedAt = endedAt;
        observerRecord.status = signal ? 'cancelled' : 'completed';
        observerRecord.cancellationSignal = signal;
        writeJsonAtomic(observerFile, observerRecord);
      } catch {}
    }
    if (signal) {
      process.stderr.write(`[observer cancelled by ${signal} at ${endedAt}]\n`);
    }
    process.exit(0);
  };
  process.on('SIGINT', () => close('SIGINT'));
  process.on('SIGTERM', () => close('SIGTERM'));
  if (watchers.length === 0) fail('no observable files exist yet');
}

function formatTimelineLine(line, receiptTime = null) {
  if (!line || !line.trim()) return null;
  let event;
  let isJson = true;
  try {
    event = JSON.parse(line);
  } catch {
    isJson = false;
  }

  let sourceTime = null;
  if (isJson) {
    const rawTime = event.timestamp ?? event.at ?? null;
    if (rawTime != null) {
      try {
        const d = new Date(rawTime);
        if (!isNaN(d.getTime())) sourceTime = d.toISOString();
      } catch {}
    }
  }

  const effectiveReceipt = receiptTime || (isJson ? (event.received_at || event.receivedAt || null) : null);
  let receiptIso = null;
  if (effectiveReceipt) {
    try {
      const d = new Date(effectiveReceipt);
      if (!isNaN(d.getTime())) receiptIso = d.toISOString();
    } catch {}
  }

  let timeLabel;
  if (sourceTime) {
    timeLabel = receiptIso ? `${sourceTime} (received: ${receiptIso})` : sourceTime;
  } else {
    timeLabel = receiptIso ? `[unknown time] (received: ${receiptIso})` : '[unknown time]';
  }

  if (!isJson) {
    const leadingIso = line.match(/^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2}))(?:\s+|$)(.*)$/);
    if (leadingIso) {
      const parsed = new Date(leadingIso[1]);
      if (!Number.isNaN(parsed.getTime())) {
        const sourceLabel = parsed.toISOString();
        const label = receiptIso ? `${sourceLabel} (received: ${receiptIso})` : sourceLabel;
        return `${label}  ${leadingIso[2]}`.trimEnd();
      }
    }
    return `${timeLabel}  ${line}`;
  }

  if (event.taskId && event.to) {
    const causeStr = event.cause ? ` (${event.cause})` : '';
    return `${timeLabel}  ${event.taskId}  ${event.from} -> ${event.to}${causeStr}`;
  }

  const type = event.type || event.part?.type || 'event';
  if (type === 'tool_use' || event.part?.type === 'tool') {
    const part = event.part || {};
    const state = part.state || {};
    const input = state.input || {};
    const detail = input.filePath || input.path || input.pattern || input.command || '';
    return `${timeLabel}  tool:${part.tool || 'unknown'}  ${state.status || ''}  ${String(detail).slice(0, 240)}`.trimEnd();
  }
  if (type === 'text') {
    return `${timeLabel}  text  ${String(event.part?.text || event.text || '').replace(/\s+/g, ' ').slice(0, 500)}`;
  }
  if (type === 'notice') {
    const code = event.code || event.data?.code || 'notice';
    const message = event.message || event.data?.message || '';
    return `${timeLabel}  notice:${code}  ${message}`.trimEnd();
  }
  if (type === 'blocked' || type === 'waiting') {
    const cause = event.cause || event.data?.cause || event.code || event.data?.code || 'unknown';
    const message = event.message || event.data?.message || '';
    return `${timeLabel}  ${type} (${cause})  ${message}`.trimEnd();
  }
  if (type === 'resumed' || type === 'resuming') {
    return `${timeLabel}  resuming`.trimEnd();
  }
  if (type === 'needs_input' || type === 'needs_permission') {
    const tool = event.data?.tool_name ? ` tool=${event.data.tool_name}` : '';
    return `${timeLabel}  ${type}${tool}`.trimEnd();
  }
  const reason = event.part?.reason ? ` reason=${event.part.reason}` : '';
  return `${timeLabel}  ${type}${reason}`.trimEnd();
}

function timelineCommand(options) {
  const runDir = singleRun(options, 'timeline');
  if (!options.task) fail('timeline requires --task <id>');
  const manifest = loadManifest(runDir);
  const task = requireTask(manifest, options.task);
  const journalPath = runPaths(runDir).journal;

  const printSupervisorEvents = (content, receiptTime = null) => {
    for (const line of content.split(/\r?\n/)) {
      if (!line.trim()) continue;
      try {
        const event = JSON.parse(line);
        if (event.taskId === task.id) process.stdout.write(`${formatTimelineLine(line, receiptTime)}\n`);
      } catch {
        // Ignore malformed partial lines; atomic append records are newline terminated.
      }
    }
  };
  const printTaskEvents = (content, receiptTime = null) => {
    for (const line of content.split(/\r?\n/)) {
      if (!line.trim()) continue;
      process.stdout.write(`${formatTimelineLine(line, receiptTime)}\n`);
    }
  };

  if (existsSync(journalPath)) printSupervisorEvents(readFileSync(journalPath, 'utf8'));
  if (task.timelinePath && existsSync(task.timelinePath)) {
    printTaskEvents(readFileSync(task.timelinePath, 'utf8'));
  }
  const details = resolveSessionDetails(task, manifest);
  process.stdout.write(`\n${formatSessionFooter(details)}\n`);

  if (options.follow) {
    followFiles([
      { path: journalPath, consume: printSupervisorEvents },
      { path: task.timelinePath, consume: printTaskEvents },
    ], { runDir, command: 'timeline', taskId: task.id });
  }
}

function logsCommand(options) {
  const runDir = singleRun(options, 'logs');
  if (!options.task) fail('logs requires --task <id>');
  const manifest = loadManifest(runDir);
  const task = requireTask(manifest, options.task);
  const stream = options.stream || 'both';
  if (!['stdout', 'stderr', 'both'].includes(stream)) fail('--stream must be stdout, stderr, or both');
  const tail = options.tail == null ? 100 : Number(options.tail);
  if (!Number.isInteger(tail) || tail < 1) fail('--tail must be a positive integer');
  const entries = [];
  if (stream === 'stdout' || stream === 'both') entries.push({ label: 'stdout', path: task.stdoutPath });
  if (stream === 'stderr' || stream === 'both') entries.push({ label: 'stderr', path: task.stderrPath });
  for (const entry of entries) {
    process.stdout.write(`--- ${entry.label} ---\n${readLastLines(entry.path, tail)}`);
  }
  const details = resolveSessionDetails(task, manifest);
  process.stdout.write(`\n${formatSessionFooter(details)}\n`);

  if (options.follow) {
    followFiles(entries.map((entry) => ({
      path: entry.path,
      consume: (content, receiptTime) => process.stdout.write(
        `[${entry.label}] ${formatObservedLogContent(content, receiptTime)}`,
      ),
    })), { runDir, command: 'logs', taskId: task.id });
  }
}

function posixQuote(value) {
  return `'${String(value).replaceAll("'", `'"'"'`)}'`;
}

function viewCommand(options) {
  const runDir = singleRun(options, 'view');
  if (!options.task) fail('view requires --task <id>');
  const args = [SCRIPT_PATH, 'timeline', '--run', runDir, '--task', options.task, '--follow'];
  if (process.platform === 'darwin') {
    const command = [process.execPath, ...args].map(posixQuote).join(' ');
    const script = `tell application "Terminal"\nactivate\ndo script ${JSON.stringify(command)}\nend tell`;
    const child = spawn('osascript', ['-e', script], { detached: true, stdio: 'ignore' });
    child.unref();
  } else if (process.platform === 'win32') {
    const viewerPath = join(runDir, `view-${options.task}.cmd`);
    const command = [process.execPath, ...args].map(windowsBatchQuote).join(' ');
    writeFileSync(
      viewerPath,
      [
        '@echo off',
        `title Delegate Task Timeline - ${options.task}`,
        command,
        'echo.',
        'echo Timeline viewer exited with code %ERRORLEVEL%.',
        'pause',
        '',
      ].join('\r\n'),
      'utf8',
    );
    try {
      launchThroughWindowsExplorer(viewerPath);
    } catch (error) {
      fail(error.message, 1);
    }
  } else {
    const candidates = [
      ['x-terminal-emulator', ['-e', process.execPath, ...args]],
      ['gnome-terminal', ['--', process.execPath, ...args]],
      ['konsole', ['-e', process.execPath, ...args]],
      ['xfce4-terminal', ['-e', [process.execPath, ...args].map(posixQuote).join(' ')]],
    ];
    let launched = false;
    for (const [command, terminalArgs] of candidates) {
      const available = spawnSync('sh', ['-c', `command -v ${posixQuote(command)}`], { stdio: 'ignore' });
      if (available.status !== 0) continue;
      const terminal = spawn(command, terminalArgs, { detached: true, stdio: 'ignore' });
      terminal.unref();
      launched = true;
      break;
    }
    if (!launched) fail('no supported terminal launcher found');
  }
  process.stdout.write(`${JSON.stringify({ opened: true, taskId: options.task, runDir })}\n`);
}

function identityCommand(options) {
  if (!options.workspace) fail('identity requires --workspace');
  process.stdout.write(`${JSON.stringify(identityFor(options.workspace), null, 2)}\n`);
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
