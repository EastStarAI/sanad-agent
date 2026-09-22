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
  realpathSync,
  renameSync,
  statSync,
  watch,
  writeFileSync,
} from 'node:fs';
import { homedir } from 'node:os';
import { basename, dirname, isAbsolute, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const SCRIPT_PATH = fileURLToPath(import.meta.url);
const TERMINAL_STATUSES = new Set([
  'completed',
  'failed',
  'blocked',
  'timeout',
  'aborted',
  'agy_unavailable',
  'opencode_unavailable',
]);
const TASK_ID = /^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$/;
const HELP = `delegate-task-supervisor

Usage:
  supervisor.mjs start --spec <tasks.json> --run-dir <absolute-dir> [--max-concurrency <n>]
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
    if (['follow', 'json'].includes(key)) {
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
  };
}

function recordIdentity(task, result) {
  const projectId = result?.projectId ?? null;
  const conversationId = result?.conversationId ?? null;
  const sessionId = result?.sessionId ?? null;
  if (!projectId && !conversationId && !sessionId) return;

  const registry = loadRegistry();
  const key = workspaceKey(task.workspace);
  const entry = registry.workspaces[key] || {
    path: task.workspace,
    antigravity: null,
    opencode: null,
  };
  const now = new Date().toISOString();
  if (task.implementer === 'antigravity' || task.implementer === 'agy') {
    entry.antigravity = { projectId, conversationId, updatedAt: now };
  } else if (task.implementer === 'opencode') {
    entry.opencode = { sessionId, updatedAt: now };
  }
  registry.workspaces[key] = entry;
  writeJsonAtomic(registryPath(), registry);
}

function validateSpec(raw) {
  if (!raw || !Array.isArray(raw.tasks) || raw.tasks.length === 0) {
    fail('spec must contain a non-empty tasks array');
  }
  const ids = new Set();
  return raw.tasks.map((item) => {
    if (!item || typeof item !== 'object') fail('each task must be an object');
    if (!TASK_ID.test(item.id || '')) fail(`invalid task id: ${item.id}`);
    if (ids.has(item.id)) fail(`duplicate task id: ${item.id}`);
    ids.add(item.id);
    if (typeof item.command !== 'string' || item.command.length === 0) {
      fail(`task ${item.id} requires command`);
    }
    if (!Array.isArray(item.args) || item.args.some((arg) => typeof arg !== 'string')) {
      fail(`task ${item.id} args must be an array of strings`);
    }
    if (typeof item.implementer !== 'string' || item.implementer.length === 0) {
      fail(`task ${item.id} requires implementer`);
    }
    const workspace = canonicalWorkspace(item.workspace);
    const normalizeOptionalPath = (value, field) => {
      if (value == null) return null;
      if (typeof value !== 'string' || !isAbsolute(value)) {
        fail(`task ${item.id} ${field} must be an absolute path`);
      }
      return resolve(value);
    };
    const timelineFormat = item.timelineFormat ?? 'text';
    if (!['text', 'jsonl'].includes(timelineFormat)) {
      fail(`task ${item.id} timelineFormat must be text or jsonl`);
    }
    return {
      id: item.id,
      implementer: item.implementer,
      workspace,
      command: item.command,
      args: item.args,
      resultPath: normalizeOptionalPath(item.resultPath, 'resultPath'),
      timelinePath: normalizeOptionalPath(item.timelinePath, 'timelinePath'),
      timelineFormat,
      knownIdentity: identityFor(workspace),
    };
  });
}

function runPaths(runDir) {
  return {
    manifest: join(runDir, 'manifest.json'),
    journal: join(runDir, 'events.jsonl'),
    tasks: join(runDir, 'tasks.json'),
    supervisorLog: join(runDir, 'supervisor.log'),
  };
}

function publicTask(task, runDir) {
  return {
    id: task.id,
    implementer: task.implementer,
    workspace: task.workspace,
    status: 'queued',
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
  // Explorer commonly returns 1 after handing the file to the existing shell.
  // The caller verifies the requested effect instead of trusting that status.
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
  if (existsSync(paths.manifest) || existsSync(paths.journal)) {
    fail(`run directory already contains supervisor state: ${runDir}`);
  }
  const tasks = validateSpec(readJson(resolve(options.spec), 'task spec'));
  const maxConcurrency = options['max-concurrency'] == null
    ? tasks.length
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
    seq: 0,
    startedAt: new Date().toISOString(),
    finishedAt: null,
    maxConcurrency,
    tasks: Object.fromEntries(tasks.map((task) => [task.id, publicTask(task, runDir)])),
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
  const tasks = readJson(paths.tasks, 'normalized tasks').tasks;
  let seq = 0;
  let active = 0;
  let nextIndex = 0;
  let terminalCount = 0;
  const settled = new Set();
  const manifest = {
    version: 'delegate-supervisor.v1',
    runDir,
    supervisorPid: process.pid,
    status: 'running',
    seq,
    startedAt: new Date().toISOString(),
    finishedAt: null,
    maxConcurrency,
    tasks: Object.fromEntries(tasks.map((task) => [task.id, publicTask(task, runDir)])),
  };

  const persist = () => writeJsonAtomic(paths.manifest, manifest);
  const transition = (task, to, extra = {}) => {
    const state = manifest.tasks[task.id];
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
    terminalCount += 1;
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
      projectId: result.projectId ?? null,
      conversationId: result.conversationId ?? null,
      sessionId: result.sessionId ?? null,
    };
    if (result) recordIdentity(task, result);
    transition(task, status, {
      pid: manifest.tasks[task.id].pid,
      finishedAt: new Date().toISOString(),
      exitCode: code,
      signal,
      reportedStatus,
      identity,
      ...(launchError ? { error: launchError.message } : {}),
    });
    if (terminalCount === tasks.length) {
      manifest.status = 'completed';
      manifest.finishedAt = new Date().toISOString();
      persist();
      process.exit(0);
    }
    launchAvailable();
  };

  const launchTask = (task) => {
    active += 1;
    const stdoutFd = openSync(manifest.tasks[task.id].stdoutPath, 'a');
    const stderrFd = openSync(manifest.tasks[task.id].stderrPath, 'a');
    let child;
    try {
      child = spawn(task.command, task.args, {
        cwd: task.workspace,
        env: process.env,
        windowsHide: true,
        stdio: ['ignore', stdoutFd, stderrFd],
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
    child.once('error', (error) => finishTask(task, 127, null, error));
    child.once('exit', (code, signal) => finishTask(task, code, signal));
  };

  function launchAvailable() {
    while (active < maxConcurrency && nextIndex < tasks.length) {
      const task = tasks[nextIndex];
      nextIndex += 1;
      launchTask(task);
    }
  }

  persist();
  launchAvailable();
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
  process.stdout.write(`RUN ${manifest.status}  seq=${manifest.seq}  supervisor=${manifest.supervisorPid}\n`);
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
  // Register watchers first, then rescan to close the read/watch race.
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

function main() {
  const [command, ...rest] = process.argv.slice(2);
  if (!command || command === '-h' || command === '--help') {
    process.stdout.write(HELP);
    return;
  }
  const options = parseOptions(rest);
  switch (command) {
    case 'start': startCommand(options); break;
    case '__worker': workerCommand(options); break;
    case 'status': statusCommand(options); break;
    case 'inspect': inspectCommand(options); break;
    case 'timeline': timelineCommand(options); break;
    case 'logs': logsCommand(options); break;
    case 'view': viewCommand(options); break;
    case 'identity': identityCommand(options); break;
    default: fail(`unknown command: ${command}\n${HELP}`);
  }
}

main();
