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
} from 'node:fs';
import { homedir } from 'node:os';
import { basename, dirname, isAbsolute, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const SCRIPT_PATH = fileURLToPath(import.meta.url);
const SUPPORTED_IMPLEMENTERS = new Set(['opencode', 'agy', 'antigravity', 'sanad']);
const TERMINAL_STATUSES = new Set([
  'completed',
  'failed',
  'blocked',
  'timeout',
  'aborted',
  'interrupted',
  'cancelled',
  'agy_unavailable',
  'opencode_unavailable',
]);
const TASK_ID = /^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$/;
const SHELL_META = /[|;&<>$`]/;
const HELP = `delegate-task-supervisor

Usage:
  supervisor.mjs start --spec <tasks.json> --run-dir <absolute-dir> [--max-concurrency <n>]
  supervisor.mjs add --run <dir> --spec <tasks.json> [--json]
  supervisor.mjs enqueue --run <dir> (--task <id> | --tasks <id1,id2> | --spec <tasks.json>) [--json]
  supervisor.mjs close --run <dir> [--wait] [--json]
  supervisor.mjs status --run <dir> [--json]
  supervisor.mjs inspect --run <dir> --task <id>
  supervisor.mjs timeline --run <dir> --task <id> [--follow]
  supervisor.mjs logs --run <dir> --task <id> [--stream stdout|stderr|both] [--tail <n>] [--follow]
  supervisor.mjs view --run <dir> --task <id>
  supervisor.mjs identity --workspace <absolute-path>
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
    if (['follow', 'json', 'wait'].includes(key)) {
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

  const workspace = canonicalWorkspace(item.workspace);
  const normalizeOptionalPath = (value, field) => {
    if (value == null) return null;
    if (typeof value !== 'string' || !isAbsolute(value)) {
      fail(`task ${item.id} ${field} must be an absolute path`);
    }
    return resolve(value);
  };

  let resultPath = normalizeOptionalPath(item.resultPath, 'resultPath');
  let timelinePath = normalizeOptionalPath(item.timelinePath, 'timelinePath');
  let timelineFormat = item.timelineFormat ?? (item.implementer === 'sanad' ? 'jsonl' : 'text');

  if (!['text', 'jsonl'].includes(timelineFormat)) {
    fail(`task ${item.id} timelineFormat must be text or jsonl`);
  }

  if (item.implementer === 'sanad') {
    const cmdBase = basename(item.command).toLowerCase();
    const isInstalledSanad = /^(sanad)(\.(exe|cmd|bat))?$/.test(cmdBase) && item.args[0] === 'run';
    const isFvmSanad = /^(fvm)(\.(exe|cmd|bat))?$/.test(cmdBase)
      && item.args.slice(0, 4).join(' ') === 'dart run agent/bin/sanad_agent.dart run';
    if (!isInstalledSanad && !isFvmSanad) {
      fail(`task ${item.id} sanad invocation must be 'sanad run' or 'fvm dart run agent/bin/sanad_agent.dart run'`);
    }

    // Requiring `run` as the first Sanad subcommand structurally prevents this
    // invocation from reaching any `workspace create/add/select/switch` command.
    // Do not scan flag values for those words: they are valid workspace IDs.
    if (item.args.some((a) => /^--(api-key|secret|token|password)/i.test(a))) {
      fail(`task ${item.id} must not pass credentials via command args`);
    }

    const logicalWorkspace = getArgValue(item.args, item.id, '--workspace', '-w');

    // A registered workspace is authoritative. execution-root is not parsed
    // or validated unless it is the task's sole targeting mode.
    if (!logicalWorkspace) {
      const execRoot = getArgValue(item.args, item.id, '--execution-root');
      if (!execRoot) {
        fail(`task ${item.id} sanad task requires --workspace or --execution-root`);
      }
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

  return {
    id: item.id,
    implementer: item.implementer,
    workspace,
    command: item.command,
    args: item.args,
    resultPath,
    timelinePath,
    timelineFormat,
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

function publicTask(task, runDir, initialStatus = 'queued') {
  return {
    id: task.id,
    implementer: task.implementer,
    workspace: task.workspace,
    status: initialStatus,
    pid: null,
    startedAt: null,
    finishedAt: null,
    exitCode: null,
    signal: null,
    resultPath: task.resultPath,
    timelinePath: task.timelinePath,
    timelineFormat: task.timelineFormat,
    stdoutPath: join(runDir, `${task.id}.stdout.log`),
    stderrPath: join(runDir, `${task.id}.stderr.log`),
    knownIdentity: task.knownIdentity,
    identity: null,
  };
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
}

function writeWindowsWorkerBroker(runDir, paths, maxConcurrency) {
  const workerPath = join(runDir, 'start-supervisor.cmd');
  const brokerPath = join(runDir, 'start-supervisor.vbs');
  const command = [
    process.execPath,
    SCRIPT_PATH,
    '__worker',
    '--run', runDir,
    '--max-concurrency', String(maxConcurrency),
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
  const maxConcurrency = options['max-concurrency'] == null
    ? Math.max(1, tasks.length)
    : Number(options['max-concurrency']);
  if (!Number.isInteger(maxConcurrency) || maxConcurrency < 1) {
    fail('--max-concurrency must be a positive integer');
  }
  writeJsonAtomic(paths.tasks, { version: 'delegate-task-spec.v1', tasks });
  writeJsonAtomic(paths.manifest, {
    version: 'delegate-supervisor.v1',
    runDir,
    supervisorPid: null,
    status: 'starting',
    closed: false,
    seq: 0,
    startedAt: new Date().toISOString(),
    finishedAt: null,
    maxConcurrency,
    tasks: Object.fromEntries(tasks.map((task) => [task.id, publicTask(task, runDir, 'queued')])),
  });

  if (process.platform === 'win32') {
    try {
      const brokerPath = writeWindowsWorkerBroker(runDir, paths, maxConcurrency);
      launchThroughWindowsExplorer(brokerPath);
      const running = waitForWindowsWorkerHandshake(paths);
      process.stdout.write(`${JSON.stringify({
        runDir,
        supervisorPid: running.supervisorPid,
        cursor: 0,
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
  ], {
    detached: true,
    windowsHide: true,
    stdio: ['ignore', logFd, logFd],
  });
  closeSync(logFd);
  child.unref();
  process.stdout.write(`${JSON.stringify({ runDir, supervisorPid: child.pid, cursor: 0 })}\n`);
}

function workerCommand(options) {
  const runDir = resolve(options.run || '');
  const maxConcurrency = Number(options['max-concurrency']);
  if (!runDir || !Number.isInteger(maxConcurrency) || maxConcurrency < 1) {
    fail('invalid internal worker invocation');
  }
  const paths = runPaths(runDir);
  mkdirSync(paths.requests, { recursive: true });
  const initialTasks = readJson(paths.tasks, 'normalized tasks').tasks;
  const taskMap = new Map(initialTasks.map((task) => [task.id, task]));
  const taskList = [...initialTasks];

  let seq = 0;
  let active = 0;
  const settled = new Set();
  const timelineWatchers = new Map();

  const manifest = {
    version: 'delegate-supervisor.v1',
    runDir,
    supervisorPid: process.pid,
    status: 'running',
    closed: false,
    seq,
    startedAt: new Date().toISOString(),
    finishedAt: null,
    maxConcurrency,
    tasks: Object.fromEntries(initialTasks.map((task) => [task.id, publicTask(task, runDir, 'queued')])),
  };

  const persist = () => writeJsonAtomic(paths.manifest, manifest);

  const transition = (task, to, extra = {}) => {
    const state = manifest.tasks[task.id];
    if (!state) return;
    const from = state.status;
    Object.assign(state, extra, { status: to });
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

  const finishTask = (task, code, signal, launchError = null) => {
    if (settled.has(task.id)) return;
    settled.add(task.id);
    active -= 1;

    if (timelineWatchers.has(task.id)) {
      try { timelineWatchers.get(task.id).close(); } catch {}
      timelineWatchers.delete(task.id);
    }

    let result = null;
    if (task.resultPath && existsSync(task.resultPath)) {
      try {
        result = JSON.parse(readFileSync(task.resultPath, 'utf8'));
      } catch {
        // Preserve process outcome when a producer leaves malformed output.
      }
    }
    const reportedStatus = result?.status ?? null;
    const status = TERMINAL_STATUSES.has(reportedStatus)
      ? reportedStatus
      : code === 0 && !launchError
        ? 'completed'
        : 'failed';
    const identity = result == null ? null : {
      projectId: result.projectId ?? result.project_id ?? null,
      conversationId: result.conversationId ?? result.conversation_id ?? null,
      sessionId: result.sessionId ?? result.session_id ?? null,
    };
    if (result) recordIdentity(task, result);
    transition(task, status, {
      pid: manifest.tasks[task.id]?.pid ?? null,
      finishedAt: new Date().toISOString(),
      exitCode: code,
      signal,
      reportedStatus,
      identity,
      ...(launchError ? { error: launchError.message } : {}),
    });

    checkRunCompletion();
    launchAvailable();
  };

  const observeTimeline = (task, child) => {
    if (!task.timelinePath) return;
    const timelinePath = task.timelinePath;
    const dir = dirname(timelinePath);
    mkdirSync(dir, { recursive: true });

    let offset = 0;
    let lastSeenType = null;
    let lastSeenRequestId = null;

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
        if (!line.trim() || settled.has(task.id)) continue;
        let event;
        try {
          event = JSON.parse(line);
        } catch {
          continue;
        }

        const type = event.type;
        const data = event.data || {};
        const sessionId = event.session_id || event.sessionId || data.session_id || data.sessionId || null;
        const requestId = data.request_id || data.requestId || null;

        if (type === 'needs_input' || type === 'needs_permission') {
          if (lastSeenType === type && lastSeenRequestId === requestId) continue;
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
          });
        } else if (type === 'resumed') {
          if (manifest.tasks[task.id]?.status === 'running') continue;
          lastSeenType = 'resumed';
          transition(task, 'running', {
            sessionId,
            requestId: null,
            intervention: null,
          });
        }
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

  const launchTask = (task) => {
    active += 1;
    const stdoutFd = openSync(manifest.tasks[task.id].stdoutPath, 'a');
    const stderrFd = openSync(manifest.tasks[task.id].stderrPath, 'a');
    const isBatch = process.platform === 'win32' && /\.(cmd|bat)$/i.test(task.command);
    let child;
    try {
      child = spawn(task.command, task.args, {
        cwd: task.workspace,
        env: process.env,
        windowsHide: true,
        stdio: ['ignore', stdoutFd, stderrFd],
        shell: isBatch,
      });
    } catch (error) {
      closeSync(stdoutFd);
      closeSync(stderrFd);
      finishTask(task, 127, null, error);
      return;
    }
    closeSync(stdoutFd);
    closeSync(stderrFd);
    transition(task, 'running', {
      pid: child.pid,
      startedAt: new Date().toISOString(),
    });

    observeTimeline(task, child);

    child.once('error', (error) => finishTask(task, 127, null, error));
    child.once('exit', (code, signal) => finishTask(task, code, signal));
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
        taskMap.set(t.id, t);
        taskList.push(t);
        manifest.tasks[t.id] = publicTask(t, runDir, 'held');
        transition(t, 'held');
      }
      persist();
      return { ok: true, taskIds: newTasks.map((t) => t.id) };
    }

    if (req.type === 'enqueue') {
      if (manifest.closed) {
        return { ok: false, error: 'cannot enqueue tasks to closed run' };
      }
      if (req.spec) {
        const newTasks = req.tasks || [];
        for (const t of newTasks) {
          if (manifest.tasks[t.id]) {
            return { ok: false, error: `duplicate task id: ${t.id}` };
          }
        }
        for (const t of newTasks) {
          taskMap.set(t.id, t);
          taskList.push(t);
          manifest.tasks[t.id] = publicTask(t, runDir, 'queued');
          transition(t, 'queued');
        }
        persist();
        launchAvailable();
        return { ok: true, taskIds: newTasks.map((t) => t.id) };
      }

      const ids = req.taskIds || [];
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
      persist();
      launchAvailable();
      return { ok: true, taskIds: ids };
    }

    if (req.type === 'close') {
      if (manifest.closed) {
        return { ok: true, alreadyClosed: true };
      }
      manifest.closed = true;
      for (const [id, tEntry] of Object.entries(manifest.tasks)) {
        if (tEntry.status === 'held') {
          const task = taskMap.get(id);
          settled.add(id);
          transition(task, 'aborted', { error: 'run closed while task was held' });
        }
      }
      persist();
      return { ok: true, closed: true };
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
      process.stdout.write(`${JSON.stringify({ runDir, added: true, taskIds: ack.taskIds }, null, 2)}\n`);
    } else {
      process.stdout.write(`Added ${ack.taskIds.length} task(s) to run: ${ack.taskIds.join(', ')}\n`);
    }
  } catch (error) {
    fail(error.message, 1);
  }
}

async function enqueueCommand(options) {
  if (!options.run) fail('enqueue requires --run');
  const runDir = resolve(options.run);
  if (options.spec) {
    const manifest = loadManifest(runDir);
    const existingIds = new Set(Object.keys(manifest.tasks || {}));
    const tasks = validateSpec(readJson(resolve(options.spec), 'task spec'), existingIds);
    try {
      const ack = await sendControlRequest(runDir, {
        type: 'enqueue',
        spec: true,
        tasks,
      });
      if (options.json) {
        process.stdout.write(`${JSON.stringify({ runDir, enqueued: true, taskIds: ack.taskIds }, null, 2)}\n`);
      } else {
        process.stdout.write(`Enqueued ${ack.taskIds.length} task(s) from spec: ${ack.taskIds.join(', ')}\n`);
      }
    } catch (error) {
      fail(error.message, 1);
    }
    return;
  }

  let taskIds = [];
  if (options.task) {
    taskIds = [options.task];
  } else if (options.tasks) {
    taskIds = options.tasks.split(',').map((s) => s.trim()).filter(Boolean);
  } else {
    fail('enqueue requires --spec, --task <id>, or --tasks <id1,id2>');
  }

  try {
    const ack = await sendControlRequest(runDir, {
      type: 'enqueue',
      spec: false,
      taskIds,
    });
    if (options.json) {
      process.stdout.write(`${JSON.stringify({ runDir, enqueued: true, taskIds: ack.taskIds }, null, 2)}\n`);
    } else {
      process.stdout.write(`Enqueued task(s): ${ack.taskIds.join(', ')}\n`);
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
  try {
    await sendControlRequest(runDir, { type: 'close' });
    if (options.wait) await waitForRunCompletion(runDir);
    const finalManifest = loadManifest(runDir);
    if (options.json) {
      process.stdout.write(`${JSON.stringify({
        runDir,
        closed: true,
        status: finalManifest.status,
      }, null, 2)}\n`);
    } else {
      process.stdout.write(`Closed run ${runDir} (status: ${finalManifest.status})\n`);
    }
  } catch (error) {
    fail(error.message, 1);
  }
}

function statusCommand(options) {
  if (!options.run) fail('status requires --run');
  const manifest = loadManifest(options.run);
  if (manifest.status === 'running' && !processIsAlive(manifest.supervisorPid)) {
    manifest.status = 'stale';
    manifest.staleReason = 'Supervisor process is not running.';
  }
  if (options.json) {
    process.stdout.write(`${JSON.stringify(manifest, null, 2)}\n`);
    return;
  }
  const closedIndicator = manifest.closed ? ' (closed)' : '';
  process.stdout.write(`RUN ${manifest.status}${closedIndicator}  seq=${manifest.seq}  supervisor=${manifest.supervisorPid}\n`);
  process.stdout.write('TASK\tIMPLEMENTER\tSTATUS\tPID\tWORKSPACE\n');
  for (const task of Object.values(manifest.tasks)) {
    process.stdout.write(`${task.id}\t${task.implementer}\t${task.status}\t${task.pid ?? '-'}\t${task.workspace}\n`);
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
  return `${lines.slice(-count).join('\n')}${lines.length ? '\n' : ''}`;
}

function followFiles(entries) {
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
    entry.consume(content);
  };

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
  const close = () => {
    for (const watcher of watchers) watcher.close();
    process.exit(0);
  };
  process.on('SIGINT', close);
  process.on('SIGTERM', close);
  if (watchers.length === 0) fail('no observable files exist yet');
}

function formatTimelineLine(line) {
  if (!line.trim()) return null;
  let event;
  try {
    event = JSON.parse(line);
  } catch {
    return line;
  }
  const time = event.timestamp
    ? new Date(event.timestamp).toISOString()
    : event.at || '';
  if (event.taskId && event.to) {
    return `${time}  ${event.taskId}  ${event.from} -> ${event.to}`;
  }
  const type = event.type || event.part?.type || 'event';
  if (type === 'tool_use' || event.part?.type === 'tool') {
    const part = event.part || {};
    const state = part.state || {};
    const input = state.input || {};
    const detail = input.filePath || input.path || input.pattern || input.command || '';
    return `${time}  tool:${part.tool || 'unknown'}  ${state.status || ''}  ${String(detail).slice(0, 240)}`.trimEnd();
  }
  if (type === 'text') {
    return `${time}  text  ${String(event.part?.text || event.text || '').replace(/\s+/g, ' ').slice(0, 500)}`;
  }
  const reason = event.part?.reason ? ` reason=${event.part.reason}` : '';
  return `${time}  ${type}${reason}`.trimEnd();
}

function timelineCommand(options) {
  if (!options.run || !options.task) fail('timeline requires --run and --task');
  const manifest = loadManifest(options.run);
  const task = requireTask(manifest, options.task);
  const journalPath = runPaths(resolve(options.run)).journal;

  const printSupervisorEvents = (content) => {
    for (const line of content.split(/\r?\n/)) {
      if (!line.trim()) continue;
      try {
        const event = JSON.parse(line);
        if (event.taskId === task.id) process.stdout.write(`${formatTimelineLine(line)}\n`);
      } catch {
        // Ignore malformed partial lines; atomic append records are newline terminated.
      }
    }
  };
  const printTaskEvents = (content) => {
    for (const line of content.split(/\r?\n/)) {
      if (!line.trim()) continue;
      process.stdout.write(`${task.timelineFormat === 'jsonl' ? formatTimelineLine(line) : line}\n`);
    }
  };

  if (existsSync(journalPath)) printSupervisorEvents(readFileSync(journalPath, 'utf8'));
  if (task.timelinePath && existsSync(task.timelinePath)) {
    printTaskEvents(readFileSync(task.timelinePath, 'utf8'));
  }
  if (options.follow) {
    followFiles([
      { path: journalPath, consume: printSupervisorEvents },
      { path: task.timelinePath, consume: printTaskEvents },
    ]);
  }
}

function logsCommand(options) {
  if (!options.run || !options.task) fail('logs requires --run and --task');
  const manifest = loadManifest(options.run);
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
  if (options.follow) {
    followFiles(entries.map((entry) => ({
      path: entry.path,
      consume: (content) => process.stdout.write(`[${entry.label}] ${content}`),
    })));
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
