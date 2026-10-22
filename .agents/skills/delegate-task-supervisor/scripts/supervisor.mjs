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

const SCRIPT_PATH = fileURLToPath(import.meta.url);
const SUPPORTED_IMPLEMENTERS = new Set(['opencode', 'agy', 'antigravity', 'sanad']);
const TERMINAL_STATUSES = new Set([
  'completed',
  'failed',
  'timeout',
  'aborted',
  'interrupted',
  'cancelled',
  'incomplete',
  'needs_review',
  'agy_unavailable',
  'opencode_unavailable',
]);
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
// Cancellation is cooperative first: SIGTERM follows the relay's own timeout
// path. A child that ignores it is force-killed after this grace period so a
// cancelled task can never block run completion.
const CANCEL_FORCE_KILL_MS = 10_000;
const HELP = `delegate-task-supervisor

Usage:
  supervisor.mjs start --spec <tasks.json> --run-dir <absolute-dir> [--max-concurrency <n>] [--queued-stall-ms <n>]
  supervisor.mjs add --run <dir> --spec <tasks.json> [--json]
  supervisor.mjs enqueue --run <dir> (--task <id> | --tasks <id1,id2> | --spec <tasks.json>) [--json]
  supervisor.mjs cancel --run <dir> --task <id> [--json]
  supervisor.mjs set-concurrency --run <dir> --max <n> [--json]
  supervisor.mjs close --run <dir> [--abort-queued] [--wait] [--json]
  supervisor.mjs status --run <dir> [--json]
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
`;

function fail(message, code = 2) {
  process.stderr.write(`supervisor: ${message}\n`);
  process.exit(code);
}

function parseOptions(argv) {
  const options = { _: [] };
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (!token.startsWith('--')) {
      options._.push(token);
      continue;
    }
    const key = token.slice(2);
    if (['follow', 'json', 'wait', 'abort-queued'].includes(key)) {
      options[key] = true;
      continue;
    }
    const value = argv[index + 1];
    if (value == null || value.startsWith('--')) fail(`missing value for ${token}`);
    options[key] = value;
    index += 1;
  }
  return options;
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

function writeWindowsWorkerBroker(runDir, paths, maxConcurrency, queuedStallMs) {
  const workerPath = join(runDir, 'start-supervisor.cmd');
  const brokerPath = join(runDir, 'start-supervisor.vbs');
  const command = [
    process.execPath,
    SCRIPT_PATH,
    '__worker',
    '--run', runDir,
    '--max-concurrency', String(maxConcurrency),
    '--queued-stall-ms', String(queuedStallMs),
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

function startCommand(options) {
  if (!options.spec || !options['run-dir']) fail('start requires --spec and --run-dir');
  if (!isAbsolute(options['run-dir'])) fail('--run-dir must be absolute');
  const runDir = resolve(options['run-dir']);
  const paths = runPaths(runDir);
  mkdirSync(runDir, { recursive: true });
  mkdirSync(paths.requests, { recursive: true });
  if (existsSync(paths.manifest) || existsSync(paths.journal)) {
    fail(`run directory already contains supervisor state: ${runDir}`);
  }
  const tasks = validateSpec(readJson(resolve(options.spec), 'task spec'));
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
  const startedAt = new Date().toISOString();
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
    queueSeq: tasks.length,
    tasks: Object.fromEntries(tasks.map((task, index) => [task.id, {
      ...publicTask(task, runDir, 'queued'),
      queuedAt: startedAt,
      queuedSeq: index + 1,
    }])),
  });

  if (process.platform === 'win32') {
    try {
      const brokerPath = writeWindowsWorkerBroker(runDir, paths, maxConcurrency, queuedStallMs);
      launchThroughWindowsExplorer(brokerPath);
      const running = waitForWindowsWorkerHandshake(paths);
      process.stdout.write(`${JSON.stringify({
        runDir,
        supervisorPid: running.supervisorPid,
        cursor: 0,
        maxConcurrency,
        queuedStallMs,
        tasks: tasks.length,
      })}\n`);
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
  ], {
    detached: true,
    windowsHide: true,
    stdio: ['ignore', logFd, logFd],
  });
  closeSync(logFd);
  child.unref();
  process.stdout.write(`${JSON.stringify({
    runDir,
    supervisorPid: child.pid,
    cursor: 0,
    maxConcurrency,
    queuedStallMs,
    tasks: tasks.length,
  })}\n`);
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
  if (!runDir
    || !Number.isInteger(maxConcurrency) || maxConcurrency < 1
    || !Number.isInteger(queuedStallMs) || queuedStallMs < 1) {
    fail('invalid internal worker invocation');
  }
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

  const transition = (task, to, extra = {}) => {
    const state = manifest.tasks[task.id];
    if (!state) return;
    const from = state.status;
    // Entering the queue stamps FIFO order and start time; entering a running
    // state clears any stall flag from the previous queue episode.
    const queueFields = to === 'queued'
      ? { queuedAt: new Date().toISOString(), queuedSeq: ++queueSeq, queueStall: null }
      : (to === 'running' ? { queueStall: null } : {});
    Object.assign(state, queueFields, extra, { status: to });
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

  const stallCheckMs = Math.max(
    STALL_CHECK_MIN_MS,
    Math.min(STALL_CHECK_MAX_MS, Math.floor(queuedStallMs / 4)),
  );
  const stallTimer = setInterval(() => {
    for (const [id, state] of Object.entries(manifest.tasks)) {
      if (state.status === 'queued' && !state.queueStall) flagQueueStall(id);
    }
  }, stallCheckMs);

  const finishTask = (task, code, signal, launchError = null) => {
    if (settled.has(task.id)) return;
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
    transition(task, status, {
      pid: manifest.tasks[task.id]?.pid ?? null,
      finishedAt,
      stateSince: finishedAt,
      exitCode: code,
      signal,
      reportedStatus,
      identity,
      ...(cancellationRequested ? { cause: 'cancelled', cancelledAt: finishedAt } : {}),
      ...(task.remote ? { resultCaptured: result != null } : {}),
      ...(remoteExit && !cancellationRequested ? { cause: remoteExit.cause } : {}),
      ...(remoteCaptureMissing && !cancellationRequested ? { cause: 'missing_result_envelope' } : {}),
      ...(remoteDiagnostic ? { error: remoteDiagnostic } : {}),
      ...(launchError ? { error: launchError.message } : {}),
    });

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
        transition(task, type, {
          sessionId,
          cause,
          stateSince: event.timestamp || null,
        });
      } else if (type === 'resumed') {
        if (manifest.tasks[task.id]?.status === 'running') return;
        lastSeenType = 'resumed';
        transition(task, 'resuming', {
          sessionId,
          requestId: null,
          intervention: null,
          cause: null,
          stateSince: event.timestamp || null,
        });
      } else if (type === 'running') {
        if (manifest.tasks[task.id]?.status === 'running') return;
        lastSeenType = 'running';
        transition(task, 'running', {
          sessionId,
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

  // Cancelling a Sanad task must also stop its daemon session: SIGTERM can land
  // after the CLI already published a session id, and a lost signal would leave
  // the daemon turn running. The stop command mirrors the task's own invocation
  // form so it targets the same binary, source entry, and Home as the task did.
  const sessionStopInvocation = (task, sessionId) => {
    if (!sessionId) return { reason: 'no_session_id' };
    if (task.remote) return { reason: 'remote_session' };
    if (task.implementer !== 'sanad') return { reason: 'not_a_sanad_task' };
    const base = basename(task.command).toLowerCase();
    let args;
    if (/^sanad(\.(exe|cmd|bat))?$/.test(base)) {
      args = ['session', 'stop', sessionId];
    } else if (/^fvm(\.(exe|cmd|bat))?$/.test(base)
      && task.args[0] === 'dart' && task.args[1] === 'run') {
      args = ['dart', 'run', task.args[2], 'session', 'stop', sessionId];
    } else {
      return { reason: 'unsupported_invocation' };
    }
    if (task.home) args.push('--home', task.home);
    return { command: task.command, args, cwd: task.spawnCwd || task.workspace };
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
    child.once('error', (error) => notice(task, 'session_stop', {
      sessionId,
      result: 'error',
      error: error.message,
    }));
    child.once('exit', (code, signal) => notice(task, 'session_stop', {
      sessionId,
      result: code === 0 ? 'completed' : 'failed',
      exitCode: code,
      signal,
    }));
    return { requested: true, sessionId };
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
    state.cancellationRequested = true;
    const sessionId = state.sessionId ?? null;
    const sessionStop = requestSessionStop(task, sessionId);
    const child = children.get(id) ?? null;
    let signalled = null;
    if (child) {
      try {
        child.kill('SIGTERM');
        signalled = 'SIGTERM';
      } catch {
        signalled = null;
      }
    }
    if (signalled) {
      const timer = setTimeout(() => {
        if (settled.has(id)) return;
        try { child.kill('SIGKILL'); } catch {}
      }, CANCEL_FORCE_KILL_MS);
      if (typeof timer.unref === 'function') timer.unref();
      forceKillTimers.set(id, timer);
    }
    notice(task, 'cancel_requested', {
      sessionId,
      signalled,
      sessionStop: sessionStop.requested === true,
      ...(sessionStop.reason ? { sessionStopReason: sessionStop.reason } : {}),
    });
    return {
      ok: true,
      taskId: id,
      from,
      status: 'cancelling',
      signalled,
      sessionId,
      sessionStop,
    };
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
      startedAt,
      stateSince: startedAt,
      queueStall: null,
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
        launchTask(task);
      }
    }
  }

  function checkRunCompletion() {
    if (!manifest.closed) return;
    const totalTasks = Object.keys(manifest.tasks).length;
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
      clearInterval(stallTimer);
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
      const reqFile = join(paths.requests, entry);
      const ackFile = join(paths.requests, entry.replace(/\.req\.json$/, '.ack.json'));
      if (existsSync(ackFile)) continue;
      let req;
      try {
        req = JSON.parse(readFileSync(reqFile, 'utf8'));
      } catch {
        continue;
      }
      const ack = handleRequest(req);
      writeJsonAtomic(ackFile, ack);
      try { unlinkSync(reqFile); } catch {}
      if (req.type === 'close') {
        checkRunCompletion();
      }
    }
  }

  const reqWatcher = watch(paths.requests, () => processPendingRequests());
  const keepAliveTimer = setInterval(() => {}, 30_000);

  persist();
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
  if (!options.run || !options.spec) fail('add requires --run and --spec');
  const runDir = resolve(options.run);
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
  if (!options.run) fail('enqueue requires --run');
  const runDir = resolve(options.run);
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
    if (options.json) {
      process.stdout.write(`${JSON.stringify({
        runDir,
        enqueued: true,
        taskIds: ack.taskIds,
        active: ack.active,
        maxConcurrency: ack.maxConcurrency,
        queued: ack.queued,
        tasks: ack.tasks,
      }, null, 2)}\n`);
    } else {
      process.stdout.write(`Enqueued ${ack.taskIds.length} task(s): ${ack.taskIds.join(', ')}\n`);
      for (const outcome of ack.tasks || []) {
        process.stdout.write(`  ${formatQueueOutcome(outcome)}\n`);
      }
    }
  } catch (error) {
    fail(error.message, 1);
  }
}

async function cancelCommand(options) {
  if (!options.run) fail('cancel requires --run');
  if (!options.task) fail('cancel requires --task <id>');
  const runDir = resolve(options.run);
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
        sessionId: ack.sessionId ?? null,
        sessionStop: ack.sessionStop ?? null,
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
    const signalText = ack.signalled ? `signalled ${ack.signalled}` : 'no live process to signal';
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
  if (!options.run) fail('set-concurrency requires --run');
  if (options.max == null) fail('set-concurrency requires --max <n>');
  const runDir = resolve(options.run);
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
        cleanup();
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
  if (!options.run) fail('close requires --run');
  const runDir = resolve(options.run);
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
  const terminalStates = new Set(['completed', 'failed', 'timeout', 'cancelled', 'aborted', 'interrupted', 'incomplete', 'needs_review']);
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
  if (pid) observationSource += isAlive ? ` (process alive: ${pid})` : ' (process not running)';

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
    `Current Time:       ${details.currentTime}`,
    '-----------------------------',
  ].join('\n');
}

function statusCommand(options) {
  if (!options.run) fail('status requires --run');
  const manifest = loadManifest(options.run);
  if (manifest.status === 'running' && !processIsAlive(manifest.supervisorPid)) {
    manifest.status = 'stale';
    manifest.staleReason = 'Supervisor process is not running.';
  }
  if (options.json) {
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
    }
    manifest.active = snapshot.active;
    manifest.queuedStallMs = queuedStallThreshold(manifest);
    manifest.queue = {
      active: snapshot.active,
      maxConcurrency: snapshot.maxConcurrency,
      queued: snapshot.queued.map((entry) => ({
        id: entry.id,
        ...describeQueuedTask(manifest, entry.id),
      })),
    };
    process.stdout.write(`${JSON.stringify(manifest, null, 2)}\n`);
    return;
  }
  const closedIndicator = manifest.closed ? ' (closed)' : '';
  process.stdout.write(`RUN ${manifest.status}${closedIndicator}  seq=${manifest.seq}  supervisor=${manifest.supervisorPid}\n`);
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

  if (options.task) {
    const task = requireTask(manifest, options.task);
    const details = resolveSessionDetails(task, manifest);
    process.stdout.write(`\n${formatSessionFooter(details)}\n`);
  } else {
    for (const task of Object.values(manifest.tasks)) {
      const details = resolveSessionDetails(task, manifest);
      process.stdout.write(`\n${formatSessionFooter(details)}\n`);
    }
  }
}

function inspectCommand(options) {
  if (!options.run || !options.task) fail('inspect requires --run and --task');
  const manifest = loadManifest(options.run);
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
  if (!options.run || !options.task) fail('timeline requires --run and --task');
  const runDir = resolve(options.run);
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
  if (!options.run || !options.task) fail('logs requires --run and --task');
  const runDir = resolve(options.run);
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
  if (!options.run || !options.task) fail('view requires --run and --task');
  const args = [SCRIPT_PATH, 'timeline', '--run', resolve(options.run), '--task', options.task, '--follow'];
  if (process.platform === 'darwin') {
    const command = [process.execPath, ...args].map(posixQuote).join(' ');
    const script = `tell application "Terminal"\nactivate\ndo script ${JSON.stringify(command)}\nend tell`;
    const child = spawn('osascript', ['-e', script], { detached: true, stdio: 'ignore' });
    child.unref();
  } else if (process.platform === 'win32') {
    const runDir = resolve(options.run);
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
  process.stdout.write(`${JSON.stringify({ opened: true, taskId: options.task, runDir: resolve(options.run) })}\n`);
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
    case 'start': startCommand(options); break;
    case '__worker': workerCommand(options); break;
    case 'add': await addCommand(options); break;
    case 'enqueue': await enqueueCommand(options); break;
    case 'cancel': await cancelCommand(options); break;
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
