import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { execFileSync, spawn, spawnSync } from 'node:child_process';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, watch, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join, resolve } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const SKILL = resolve(HERE, '..');
const SUPERVISOR = join(SKILL, 'scripts', 'supervisor.mjs');
const WATCH_ONCE = join(SKILL, 'scripts', 'watch-once.mjs');
// The shared journal vocabulary is the same module the scripts use, so a test can
// assert what a coordinator would consider actionable.
const { isActionableEvent } = await import(join(SKILL, 'scripts', 'supervisor-events.mjs'));

// ---------------------------------------------------------------------------
// Bounded teardown (W10).
//
// A supervisor worker is detached on purpose: it must outlive the CLI call that
// started it. That also means a test that fails before `close` leaves the worker
// (and its children) behind forever. The teardown below finds every supervisor
// manifest under the test temp root, confirms the pid still belongs to *this* run
// (never kill a reused pid), and terminates it with a bounded grace period.
// ---------------------------------------------------------------------------
function processCommand(pid) {
  if (process.platform === 'win32') return '';
  const result = spawnSync('ps', ['-p', String(pid), '-o', 'command='], { encoding: 'utf8' });
  return result.status === 0 ? (result.stdout || '').trim() : '';
}

function terminateIfOwned(pid, needle) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  const command = processCommand(pid);
  if (!command || !command.includes(needle)) return false;
  try {
    process.kill(pid, 'SIGTERM');
  } catch {
    return false;
  }
  const deadline = Date.now() + 1_500;
  while (Date.now() < deadline) {
    try {
      process.kill(pid, 0);
    } catch {
      return true;
    }
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 50);
  }
  try {
    process.kill(pid, 'SIGKILL');
  } catch {
    // Already gone.
  }
  return true;
}

function collectManifests(directory, depth = 0) {
  const found = [];
  let entries;
  try {
    entries = readdirSync(directory, { withFileTypes: true });
  } catch {
    return found;
  }
  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    const child = join(directory, entry.name);
    const manifestPath = join(child, 'manifest.json');
    if (existsSync(manifestPath)) found.push(manifestPath);
    if (depth < 2) found.push(...collectManifests(child, depth + 1));
  }
  return found;
}

test.after(() => {
  const root = tmpdir();
  let candidates = [];
  try {
    candidates = readdirSync(root).filter((entry) => entry.startsWith('delegate-'));
  } catch {
    return;
  }
  let reaped = 0;
  for (const entry of candidates) {
    const directory = join(root, entry);
    for (const manifestPath of collectManifests(directory)) {
      let manifest;
      try {
        manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
      } catch {
        continue;
      }
      // Ownership is proven by the command line naming this temp tree: a
      // supervisor worker names its `--run <dir>` and a task names its fixture
      // paths. A reused pid that happens to match is never killed blindly.
      if (terminateIfOwned(manifest.supervisorPid, directory)) reaped += 1;
      for (const task of Object.values(manifest.tasks || {})) {
        if (terminateIfOwned(task?.pid, directory)) reaped += 1;
      }
    }
  }
  if (reaped > 0) process.stderr.write(`[teardown] reaped ${reaped} leftover supervisor process(es)\n`);
});

function waitForFileChange(directory, predicate, timeoutMs = 8_000) {
  return new Promise((resolvePromise, reject) => {
    let watcher;
    let timer;
    let watchdog;
    // The watchdog is cleared on success: a pending timeout would otherwise keep
    // the test process alive for its whole duration and inflate suite timing.
    const cleanup = () => {
      clearInterval(timer);
      clearTimeout(watchdog);
      try { watcher?.close(); } catch {}
    };
    const check = () => {
      try {
        const value = predicate();
        if (!value) return;
        cleanup();
        resolvePromise(value);
      } catch {
        // The writer may be between atomic rename operations; the next event retries.
      }
    };
    try {
      watcher = watch(directory, check);
    } catch {}
    timer = setInterval(check, 100);
    watchdog = setTimeout(() => {
      cleanup();
      reject(new Error(`condition not met within ${timeoutMs}ms`));
    }, timeoutMs);
    check();
  });
}

function runNode(script, args, env = process.env) {
  return execFileSync(process.execPath, [script, ...args], {
    encoding: 'utf8',
    env,
  }).trim();
}

function runNodeThrows(script, args, env = process.env) {
  try {
    execFileSync(process.execPath, [script, ...args], {
      encoding: 'utf8',
      env,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    assert.fail('command expected to fail');
  } catch (error) {
    return `${error.stdout || ''}\n${error.stderr || ''}\n${error.message || ''}`;
  }
}

function collectProcess(child) {
  return new Promise((resolvePromise, reject) => {
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (chunk) => { stdout += chunk; });
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    child.once('error', reject);
    child.once('exit', (code, signal) => resolvePromise({ code, signal, stdout, stderr }));
  });
}

function createNamedWrapper(directory, name, scriptPath) {
  const isWin = process.platform === 'win32';
  const wrapperName = isWin ? `${name}.cmd` : name;
  const wrapperPath = join(directory, wrapperName);
  if (isWin) {
    writeFileSync(
      wrapperPath,
      `@echo off\r\n"${process.execPath}" "${scriptPath}" %*\r\n`,
      'utf8',
    );
  } else {
    writeFileSync(
      wrapperPath,
      `#!/bin/sh\nexec "${process.execPath}" "${scriptPath}" "$@"\n`,
      'utf8',
    );
    chmodSync(wrapperPath, 0o755);
  }
  return wrapperPath;
}

function createSanadWrapper(directory, scriptPath) {
  return createNamedWrapper(directory, 'sanad', scriptPath);
}

function createFvmWrapper(directory, scriptPath) {
  return createNamedWrapper(directory, 'fvm', scriptPath);
}

test('supervises out-of-order tasks and watch-once survives watcher replacement', async () => {
  const root = mkdtempSync(join(tmpdir(), 'delegate-supervisor-test-'));
  const workspace = join(root, 'workspace with spaces');
  const runDir = join(root, 'run');
  const results = join(root, 'results');
  const config = join(root, 'config');
  mkdirSync(workspace, { recursive: true });
  mkdirSync(results, { recursive: true });
  mkdirSync(config, { recursive: true });

  const fixture = join(root, 'fixture.mjs');
  writeFileSync(fixture, `
    import {mkdirSync, writeFileSync, appendFileSync} from 'node:fs';
    import {dirname} from 'node:path';
    const [delay, status, resultPath, timelinePath, identity] = process.argv.slice(2);
    mkdirSync(dirname(resultPath), {recursive:true});
    appendFileSync(timelinePath, JSON.stringify({type:'tool_use', timestamp:Date.now(), part:{type:'tool', tool:'read', state:{status:'completed', input:{filePath:'fixture.txt'}}}})+'\\n');
    setTimeout(() => {
      writeFileSync(resultPath, JSON.stringify({status, exitCode: status === 'failed' ? 7 : 0, sessionId: identity || null}));
      process.exit(status === 'failed' ? 7 : 0);
    }, Number(delay));
  `, 'utf8');

  const task = (id, delay, status, identity = '') => {
    const out = join(results, id);
    return {
      id,
      implementer: 'opencode',
      workspace,
      command: process.execPath,
      args: [fixture, String(delay), status, join(out, 'result.json'), join(out, 'events.jsonl'), identity],
      resultPath: join(out, 'result.json'),
      timelinePath: join(out, 'events.jsonl'),
      timelineFormat: 'jsonl',
    };
  };
  const specPath = join(root, 'tasks.json');
  writeFileSync(specPath, JSON.stringify({ tasks: [
    task('slow', 1_300, 'failed'),
    task('fast', 800, 'completed', 'ses_test_fast'),
    task('middle', 1_050, 'timeout'),
  ] }), 'utf8');

  const env = { ...process.env, XDG_CONFIG_HOME: config };
  const started = JSON.parse(runNode(SUPERVISOR, [
    'start', '--spec', specPath, '--run-dir', runDir, '--max-concurrency', '3',
  ], env));
  assert.equal(started.cursor, 0);

  const manifestPath = join(runDir, 'manifest.json');
  const running = await waitForFileChange(runDir, () => {
    const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
    return manifest.seq >= 3 ? manifest : null;
  });
  assert.deepEqual(Object.values(running.tasks).map((entry) => entry.status), [
    'running', 'running', 'running',
  ]);

  const interrupted = spawn(process.execPath, [WATCH_ONCE, '--run', runDir, '--since', '3'], {
    env,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  await new Promise((resolvePromise) => setTimeout(resolvePromise, 100));
  interrupted.kill('SIGTERM');
  const interruptedResult = await collectProcess(interrupted);
  assert.notEqual(interruptedResult.code, 0);

  // A watcher timeout/interruption never stops the worker: the run is still
  // running and unfinished work keeps progressing. Re-entry uses a bounded
  // status read plus the cursor, never scheduled polling.
  const midStatus = JSON.parse(runNode(SUPERVISOR, ['status', '--run', runDir, '--json'], env));
  assert.equal(midStatus.status, 'running');
  assert.equal(midStatus.tasks.slow.status, 'running');

  const first = JSON.parse(runNode(WATCH_ONCE, ['--run', runDir, '--since', '3'], env));
  assert.equal(first.taskId, 'fast');
  assert.equal(first.to, 'completed');

  const second = JSON.parse(runNode(WATCH_ONCE, [
    '--run', runDir, '--since', String(first.seq),
  ], env));
  assert.equal(second.taskId, 'middle');
  assert.equal(second.to, 'timeout');

  const third = JSON.parse(runNode(WATCH_ONCE, [
    '--run', runDir, '--since', String(second.seq),
  ], env));
  assert.equal(third.taskId, 'slow');
  assert.equal(third.to, 'failed');

  runNode(SUPERVISOR, ['close', '--run', runDir], env);

  const finalManifest = await waitForFileChange(runDir, () => {
    const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
    return manifest.status === 'completed' ? manifest : null;
  });
  assert.equal(finalManifest.status, 'completed');

  const timeline = runNode(SUPERVISOR, [
    'timeline', '--run', runDir, '--task', 'fast',
  ], env);
  assert.match(timeline, /queued -> running/);
  assert.match(timeline, /tool:read/);
  assert.match(timeline, /running -> completed/);

  const identity = JSON.parse(runNode(SUPERVISOR, [
    'identity', '--workspace', workspace,
  ], env));
  assert.equal(identity.opencode.sessionId, 'ses_test_fast');
});

test('reports a dead running supervisor as stale instead of blocking', () => {
  const runDir = mkdtempSync(join(tmpdir(), 'delegate-supervisor-stale-test-'));
  const deadPid = 2_147_483_647;
  writeFileSync(join(runDir, 'events.jsonl'), '', 'utf8');
  writeFileSync(join(runDir, 'manifest.json'), `${JSON.stringify({
    version: 'delegate-supervisor.v1',
    runDir,
    supervisorPid: deadPid,
    status: 'running',
    seq: 4,
    startedAt: new Date().toISOString(),
    finishedAt: null,
    maxConcurrency: 1,
    tasks: {},
  }, null, 2)}\n`, 'utf8');

  const status = JSON.parse(runNode(SUPERVISOR, [
    'status', '--run', runDir, '--json',
  ]));
  assert.equal(status.status, 'stale');
  assert.match(status.staleReason, /not running/);

  const event = JSON.parse(runNode(WATCH_ONCE, [
    '--run', runDir, '--since', '4',
  ]));
  assert.equal(event.kind, 'supervisor_stale');
  assert.equal(event.to, 'stale');
  assert.equal(event.supervisorPid, deadPid);
});
test('one open run stays alive after initial tasks settle and later enqueue launches in same run', async () => {
  const root = mkdtempSync(join(tmpdir(), 'delegate-longlived-test-'));
  const workspace = join(root, 'workspace');
  const runDir = join(root, 'run');
  const results = join(root, 'results');
  mkdirSync(workspace, { recursive: true });
  mkdirSync(results, { recursive: true });

  const fixture = join(root, 'quick_task.mjs');
  writeFileSync(fixture, `
    import {mkdirSync, writeFileSync} from 'node:fs';
    import {dirname} from 'node:path';
    const [resultPath] = process.argv.slice(2);
    mkdirSync(dirname(resultPath), {recursive:true});
    writeFileSync(resultPath, JSON.stringify({status:'completed', exitCode:0}));
    process.exit(0);
  `, 'utf8');

  const task = (id) => ({
    id,
    implementer: 'opencode',
    workspace,
    command: process.execPath,
    args: [fixture, join(results, id, 'result.json')],
    resultPath: join(results, id, 'result.json'),
  });

  const spec1 = join(root, 'spec1.json');
  writeFileSync(spec1, JSON.stringify({ tasks: [task('initial-1')] }), 'utf8');

  runNode(SUPERVISOR, ['start', '--spec', spec1, '--run-dir', runDir, '--max-concurrency', '2']);

  const event1 = JSON.parse(runNode(WATCH_ONCE, ['--run', runDir, '--since', '0']));
  assert.equal(event1.taskId, 'initial-1');
  assert.equal(event1.to, 'completed');

  // Verify run is still running even though all tasks have settled
  const statusMid = JSON.parse(runNode(SUPERVISOR, ['status', '--run', runDir, '--json']));
  assert.equal(statusMid.status, 'running');
  assert.equal(statusMid.tasks['initial-1'].status, 'completed');

  // Enqueue a new spec into the same run
  const spec2 = join(root, 'spec2.json');
  writeFileSync(spec2, JSON.stringify({ tasks: [task('dynamic-2')] }), 'utf8');

  const enqueueOut = JSON.parse(runNode(SUPERVISOR, [
    'enqueue', '--run', runDir, '--spec', spec2, '--json',
  ]));
  assert.equal(enqueueOut.enqueued, true);
  assert.deepEqual(enqueueOut.taskIds, ['dynamic-2']);

  const event2 = JSON.parse(runNode(WATCH_ONCE, ['--run', runDir, '--since', String(event1.seq)]));
  assert.equal(event2.taskId, 'dynamic-2');
  assert.equal(event2.to, 'completed');
  assert.ok(event2.seq > event1.seq, 'monotonic journal sequence');

  // Close the run and verify completion
  runNode(SUPERVISOR, ['close', '--run', runDir]);
  const manifestPath = join(runDir, 'manifest.json');
  const finalManifest = await waitForFileChange(runDir, () => {
    const m = JSON.parse(readFileSync(manifestPath, 'utf8'));
    return m.status === 'completed' ? m : null;
  });
  assert.equal(finalManifest.status, 'completed');
});

test('add, enqueue, and close semantics, duplicate ID rejection, and post-close rejection', async () => {
  const root = mkdtempSync(join(tmpdir(), 'delegate-add-enqueue-test-'));
  const workspace = join(root, 'workspace');
  const runDir = join(root, 'run');
  const results = join(root, 'results');
  mkdirSync(workspace, { recursive: true });
  mkdirSync(results, { recursive: true });

  const fixture = join(root, 'task_runner.mjs');
  writeFileSync(fixture, `
    import {mkdirSync, writeFileSync} from 'node:fs';
    import {dirname} from 'node:path';
    const [resultPath] = process.argv.slice(2);
    mkdirSync(dirname(resultPath), {recursive:true});
    writeFileSync(resultPath, JSON.stringify({status:'completed', exitCode:0}));
    process.exit(0);
  `, 'utf8');

  const task = (id) => ({
    id,
    implementer: 'opencode',
    workspace,
    command: process.execPath,
    args: [fixture, join(results, id, 'result.json')],
    resultPath: join(results, id, 'result.json'),
  });

  // Start with empty spec
  const emptySpec = join(root, 'empty.json');
  writeFileSync(emptySpec, JSON.stringify({ tasks: [] }), 'utf8');
  runNode(SUPERVISOR, ['start', '--spec', emptySpec, '--run-dir', runDir, '--max-concurrency', '2']);

  // Add task in held state
  const heldSpec = join(root, 'held.json');
  writeFileSync(heldSpec, JSON.stringify({ tasks: [task('task-held')] }), 'utf8');
  const addResult = JSON.parse(runNode(SUPERVISOR, ['add', '--run', runDir, '--spec', heldSpec, '--json']));
  assert.equal(addResult.added, true);

  const statusHeld = JSON.parse(runNode(SUPERVISOR, ['status', '--run', runDir, '--json']));
  assert.equal(statusHeld.tasks['task-held'].status, 'held');

  // Reject duplicate task ID
  const dupError = runNodeThrows(SUPERVISOR, ['add', '--run', runDir, '--spec', heldSpec]);
  assert.match(dupError, /duplicate task id/);

  // Reject non-existent enqueue
  const nonExistentError = runNodeThrows(SUPERVISOR, ['enqueue', '--run', runDir, '--task', 'no-such-task']);
  assert.match(nonExistentError, /task not found/);

  // Enqueue the held task
  const enqueueResult = JSON.parse(runNode(SUPERVISOR, [
    'enqueue', '--run', runDir, '--task', 'task-held', '--json',
  ]));
  assert.equal(enqueueResult.enqueued, true);

  // Close the run
  runNode(SUPERVISOR, ['close', '--run', runDir]);

  // Reject additions after close
  const afterCloseSpec = join(root, 'after_close.json');
  writeFileSync(afterCloseSpec, JSON.stringify({ tasks: [task('late-task')] }), 'utf8');
  const addAfterCloseError = runNodeThrows(SUPERVISOR, ['add', '--run', runDir, '--spec', afterCloseSpec]);
  assert.match(addAfterCloseError, /closed run|already completed/);

  const enqueueAfterCloseError = runNodeThrows(SUPERVISOR, ['enqueue', '--run', runDir, '--spec', afterCloseSpec]);
  assert.match(enqueueAfterCloseError, /closed run|already completed/);

  // Wait for run to drain and complete
  const manifestPath = join(runDir, 'manifest.json');
  const completed = await waitForFileChange(runDir, () => {
    const m = JSON.parse(readFileSync(manifestPath, 'utf8'));
    return m.status === 'completed' ? m : null;
  });
  assert.equal(completed.status, 'completed');
  assert.equal(completed.tasks['task-held'].status, 'completed');
});

test('Sanad fixture writing G2 events: intervention and resuming states wake default watch-once, session identity recorded', async () => {
  const root = mkdtempSync(join(tmpdir(), 'delegate-sanad-fixture-test-'));
  const workspace = join(root, 'worktree');
  const runDir = join(root, 'run');
  const outDir = join(root, 'task_out');
  const briefFile = join(root, 'brief.txt');
  const config = join(root, 'config');
  mkdirSync(workspace, { recursive: true });
  mkdirSync(outDir, { recursive: true });
  mkdirSync(config, { recursive: true });
  writeFileSync(briefFile, 'Test Sanad brief', 'utf8');

  const mockSanad = join(root, 'mock_sanad.mjs');
  writeFileSync(mockSanad, `
    import {appendFileSync, mkdirSync, writeFileSync} from 'node:fs';
    import {dirname, resolve} from 'node:path';

    const args = process.argv.slice(2);
    let outDir = '';
    let execRoot = '';
    for (let i = 0; i < args.length; i++) {
      if (args[i] === '--out-dir' || args[i] === '-o') outDir = args[i + 1];
      if (args[i] === '--execution-root') execRoot = args[i + 1];
    }
    const eventsPath = resolve(outDir, 'events.jsonl');
    const resultPath = resolve(outDir, 'result.json');
    mkdirSync(dirname(eventsPath), {recursive:true});

    // 1. Initial running event
    appendFileSync(eventsPath, JSON.stringify({
      timestamp: new Date().toISOString(),
      type: 'running',
      session_id: 'ses_sanad_42',
      data: { workspace_id: 'ws_logical', execution_root: execRoot }
    }) + '\\n');

    setTimeout(() => {
      // 2. Needs input event
      appendFileSync(eventsPath, JSON.stringify({
        timestamp: new Date().toISOString(),
        type: 'needs_input',
        session_id: 'ses_sanad_42',
        data: {
          kind: 'needs_input',
          request_id: 'req-input-1',
          questions: [{ question: 'Confirm?' }],
          secret: 'must-not-reach-supervisor-journal',
          provider_payload: { internal: true }
        }
      }) + '\\n');

      setTimeout(() => {
        // 3. Resumed event
        appendFileSync(eventsPath, JSON.stringify({
          timestamp: new Date().toISOString(),
          type: 'resumed',
          session_id: 'ses_sanad_42',
          data: { status: 'running' }
        }) + '\\n');

        setTimeout(() => {
          // 4. Needs permission event
          appendFileSync(eventsPath, JSON.stringify({
            timestamp: new Date().toISOString(),
            type: 'needs_permission',
            session_id: 'ses_sanad_42',
            data: { kind: 'needs_permission', request_id: 'req-perm-1', tool: 'shell_execute' }
          }) + '\\n');

          setTimeout(() => {
            // 5. Second resumed event
            appendFileSync(eventsPath, JSON.stringify({
              timestamp: new Date().toISOString(),
              type: 'resumed',
              session_id: 'ses_sanad_42',
              data: { status: 'running' }
            }) + '\\n');

            setTimeout(() => {
              // 6. Terminal result and completed event
              writeFileSync(resultPath, JSON.stringify({
                "$schema": "https://sanad.dev/schemas/run-result-v1.json",
                "version": "1.0.0",
                "session_id": "ses_sanad_42",
                "workspace_id": "ws_logical",
                "execution_root": execRoot,
                "status": "completed",
                "exit_code": 0
              }));
              appendFileSync(eventsPath, JSON.stringify({
                timestamp: new Date().toISOString(),
                type: 'completed',
                session_id: 'ses_sanad_42',
                data: { session_id: 'ses_sanad_42', status: 'completed', exit_code: 0 }
              }) + '\\n');
              process.exit(0);
            }, 100);
          }, 100);
        }, 100);
      }, 100);
    }, 100);
  `, 'utf8');

  const sanadBinary = createSanadWrapper(root, mockSanad);

  const spec = join(root, 'tasks.json');
  writeFileSync(spec, JSON.stringify({
    tasks: [{
      id: 'sanad-task-1',
      implementer: 'sanad',
      workspace,
      command: sanadBinary,
      args: [
        'run',
        '--brief-file', briefFile,
        '--workspace', 'ws_logical',
        '--out-dir', outDir,
        '--events',
      ],
      resultPath: join(outDir, 'result.json'),
      timelinePath: join(outDir, 'events.jsonl'),
      timelineFormat: 'jsonl',
    }],
  }), 'utf8');

  const env = { ...process.env, XDG_CONFIG_HOME: config };
  runNode(SUPERVISOR, ['start', '--spec', spec, '--run-dir', runDir, '--max-concurrency', '1'], env);

  // 1. watch-once wakes up on needs_input
  const event1 = JSON.parse(runNode(WATCH_ONCE, ['--run', runDir, '--since', '0'], env));
  assert.equal(event1.taskId, 'sanad-task-1');
  assert.equal(event1.to, 'needs_input');
  assert.equal(event1.sessionId, 'ses_sanad_42');
  assert.equal(event1.requestId, 'req-input-1');
  assert.deepEqual(event1.intervention, {
    kind: 'needs_input',
    request_id: 'req-input-1',
    questions: [{ question: 'Confirm?' }],
  });
  assert.equal(JSON.stringify(event1).includes('must-not-reach'), false);
  assert.equal(JSON.stringify(event1).includes('provider_payload'), false);

  // 2. watch-once surfaces the meaningful resuming transition.
  const event2 = JSON.parse(runNode(WATCH_ONCE, ['--run', runDir, '--since', String(event1.seq)], env));
  assert.equal(event2.taskId, 'sanad-task-1');
  assert.equal(event2.to, 'resuming');

  // 3. The next intervention remains observable.
  const event3 = JSON.parse(runNode(WATCH_ONCE, ['--run', runDir, '--since', String(event2.seq)], env));
  assert.equal(event3.taskId, 'sanad-task-1');
  assert.equal(event3.to, 'needs_permission');
  assert.equal(event3.sessionId, 'ses_sanad_42');
  assert.equal(event3.requestId, 'req-perm-1');

  // 4. A second resume and the eventual terminal state are distinct wakes.
  const event4 = JSON.parse(runNode(WATCH_ONCE, ['--run', runDir, '--since', String(event3.seq)], env));
  assert.equal(event4.to, 'resuming');
  const event5 = JSON.parse(runNode(WATCH_ONCE, ['--run', runDir, '--since', String(event4.seq)], env));
  assert.equal(event5.taskId, 'sanad-task-1');
  assert.equal(event5.to, 'completed');

  const supervisorEvents = readFileSync(join(runDir, 'events.jsonl'), 'utf8')
    .trim()
    .split(/\r?\n/)
    .map((line) => JSON.parse(line));
  assert.equal(supervisorEvents.filter((event) => event.to === 'needs_input').length, 1);
  assert.equal(supervisorEvents.filter((event) => event.to === 'needs_permission').length, 1);

  runNode(SUPERVISOR, ['close', '--run', runDir, '--wait'], env);

  // Verify identity registry recorded Sanad session_id
  const identity = JSON.parse(runNode(SUPERVISOR, ['identity', '--workspace', workspace], env));
  assert.equal(identity.sanad.sessionId, 'ses_sanad_42');
});

test('isolated workspaces do not collide across concurrent Sanad tasks', async () => {
  const root = realpathSync(mkdtempSync(join(tmpdir(), 'delegate-collision-test-')));
  const worktreeA = join(root, 'worktree-a');
  const worktreeB = join(root, 'worktree-b');
  const outA = join(root, 'out-a');
  const outB = join(root, 'out-b');
  const briefA = join(root, 'brief-a.txt');
  const briefB = join(root, 'brief-b.txt');
  const runDir = join(root, 'run');
  mkdirSync(worktreeA, { recursive: true });
  mkdirSync(worktreeB, { recursive: true });
  mkdirSync(outA, { recursive: true });
  mkdirSync(outB, { recursive: true });
  writeFileSync(briefA, 'Brief A', 'utf8');
  writeFileSync(briefB, 'Brief B', 'utf8');
  // The same-root fvm source-development task validates its source entry
  // point relative to the spawn working directory (task workspace here).
  mkdirSync(join(worktreeA, 'agent', 'bin'), { recursive: true });
  writeFileSync(
    join(worktreeA, 'agent', 'bin', 'sanad_agent.dart'),
    '// fixture entry point\n',
    'utf8',
  );

  const mockScript = join(root, 'mock_fast.mjs');
  writeFileSync(mockScript, `
    import {appendFileSync, mkdirSync, writeFileSync} from 'node:fs';
    import {dirname, resolve} from 'node:path';
    const args = process.argv.slice(2);
    let outDir = '';
    let execRoot = '';
    for (let i = 0; i < args.length; i++) {
      if (args[i] === '--out-dir') outDir = args[i + 1];
      if (args[i] === '--execution-root') execRoot = args[i + 1];
    }
    const resPath = resolve(outDir, 'result.json');
    const evPath = resolve(outDir, 'events.jsonl');
    mkdirSync(dirname(resPath), {recursive:true});
    writeFileSync(resPath, JSON.stringify({
      status: 'completed',
      exit_code: 0,
      execution_root: execRoot,
      spawned_cwd: process.cwd(),
    }));
    appendFileSync(evPath, JSON.stringify({type: 'completed', status: 'completed'}) + '\\n');
    process.exit(0);
  `, 'utf8');

  const sanadBin = createSanadWrapper(root, mockScript);
  const fvmBin = createFvmWrapper(root, mockScript);

  const spec = join(root, 'tasks.json');
  writeFileSync(spec, JSON.stringify({
    tasks: [
      {
        id: 'task-a',
        implementer: 'sanad',
        workspace: worktreeA,
        command: fvmBin,
        args: ['dart', 'run', 'agent/bin/sanad_agent.dart', 'run', '--brief-file', briefA, '--workspace', 'create', '--execution-root', worktreeA, '--out-dir', outA, '--events'],
      },
      {
        id: 'task-b',
        implementer: 'sanad',
        workspace: worktreeB,
        command: sanadBin,
        args: ['run', '--brief-file', briefB, '--workspace', 'ws-shared-logical', '--execution-root', worktreeB, '--out-dir', outB, '--events'],
      },
    ],
  }), 'utf8');

  runNode(SUPERVISOR, ['start', '--spec', spec, '--run-dir', runDir, '--max-concurrency', '2']);

  const ev1 = JSON.parse(runNode(WATCH_ONCE, ['--run', runDir, '--since', '0']));
  assert.equal(ev1.to, 'completed');
  const ev2 = JSON.parse(runNode(WATCH_ONCE, ['--run', runDir, '--since', String(ev1.seq)]));
  assert.equal(ev2.to, 'completed');

  const resA = JSON.parse(readFileSync(join(outA, 'result.json'), 'utf8'));
  const resB = JSON.parse(readFileSync(join(outB, 'result.json'), 'utf8'));
  assert.equal(resA.execution_root, worktreeA);
  assert.equal(resB.execution_root, worktreeB);
  // Normal same-root compatibility: without sourceRoot the fvm task spawns
  // from its task workspace, which is also where its source entry lives.
  assert.equal(resolve(resA.spawned_cwd), resolve(worktreeA));

  runNode(SUPERVISOR, ['close', '--run', runDir]);
});

test('validation rejects malformed Sanad specs without confusing workspace IDs for commands', () => {
  const root = mkdtempSync(join(tmpdir(), 'delegate-val-test-'));
  const workspace = join(root, 'workspace');
  const outDir = join(root, 'out');
  const brief = join(root, 'brief.txt');
  mkdirSync(workspace, { recursive: true });
  mkdirSync(outDir, { recursive: true });
  writeFileSync(brief, 'Brief', 'utf8');

  const sanadBin = createSanadWrapper(root, join(root, 'mock.mjs'));

  const validate = (taskOverrides) => {
    const spec = join(root, `spec_${Math.random().toString(36).slice(2)}.json`);
    const runDir = join(root, `run_${Math.random().toString(36).slice(2)}`);
    writeFileSync(spec, JSON.stringify({
      tasks: [{
        id: 'val-task',
        implementer: 'sanad',
        workspace,
        command: sanadBin,
        args: ['run', '--brief-file', brief, '--workspace', 'ws-valid', '--execution-root', workspace, '--out-dir', outDir, '--events'],
        resultPath: join(outDir, 'result.json'),
        timelinePath: join(outDir, 'events.jsonl'),
        timelineFormat: 'jsonl',
        ...taskOverrides,
      }],
    }), 'utf8');
    return runNodeThrows(SUPERVISOR, ['start', '--spec', spec, '--run-dir', runDir]);
  };

  // 1. Unknown implementer
  assert.match(validate({ implementer: 'unknown' }), /unsupported implementer/);

  // 2. Shell metacharacters
  assert.match(validate({ command: `${sanadBin}; rm -rf` }), /shell metacharacters/);

  // 3. Credentials in argv
  assert.match(validate({ args: ['run', '--brief-file', brief, '--workspace', 'ws', '--execution-root', workspace, '--out-dir', outDir, '--api-key=secret123'] }), /credentials/);

  // 4. Missing both targeting modes
  assert.match(validate({ args: ['run', '--brief-file', brief, '--out-dir', outDir] }), /requires --workspace or --execution-root/);

  // 5. execution-root-only mode requires an absolute path
  assert.match(validate({ args: ['run', '--brief-file', brief, '--execution-root', 'relative-root', '--out-dir', outDir] }), /must be an absolute path/);

  // 6. execution-root-only mode must match task.workspace
  assert.match(validate({ args: ['run', '--brief-file', brief, '--execution-root', root, '--out-dir', outDir] }), /must match task workspace/);

  // 7. Workspace identity does not weaken the execution-root boundary
  assert.match(validate({
    args: ['run', '--brief-file', brief, '--workspace', 'ws', '--execution-root', 'relative-root', '--out-dir', outDir],
    resultPath: join(root, 'other', 'result.json'),
  }), /--execution-root must be an absolute path/);

  // 8. Result path mismatch
  assert.match(validate({ resultPath: join(root, 'other', 'result.json') }), /resultPath must match/);

  // 9. Duplicate semantic flags are ambiguous and fail closed
  assert.match(validate({
    args: ['run', '--brief-file', brief, '--workspace', 'ws-a', '-w', 'ws-b', '--execution-root', workspace, '--out-dir', outDir],
  }), /duplicate --workspace/);

  // 10. A following option is not accepted as a missing semantic value
  assert.match(validate({
    args: ['run', '--brief-file', brief, '--workspace', '--execution-root', workspace, '--out-dir', outDir],
  }), /--workspace requires a value/);
});

test('sanad sourceRoot separates the source checkout from the delegated execution root', async () => {
  const root = realpathSync(mkdtempSync(join(tmpdir(), 'delegate-sourceroot-test-')));
  const sourceCheckout = join(root, 'source-checkout');
  const worktree = join(root, 'target-worktree');
  const outDir = join(root, 'task-out');
  const briefFile = join(root, 'brief.txt');
  const runDir = join(root, 'run');
  mkdirSync(join(sourceCheckout, 'agent', 'bin'), { recursive: true });
  mkdirSync(worktree, { recursive: true });
  mkdirSync(outDir, { recursive: true });
  writeFileSync(briefFile, 'Brief', 'utf8');
  writeFileSync(
    join(sourceCheckout, 'agent', 'bin', 'sanad_agent.dart'),
    '// fixture entry point\n',
    'utf8',
  );

  const mockScript = join(root, 'mock_fvm.mjs');
  writeFileSync(mockScript, `
    import {mkdirSync, writeFileSync} from 'node:fs';
    import {dirname, resolve} from 'node:path';
    const args = process.argv.slice(2);
    let outDir = '';
    let execRoot = '';
    for (let i = 0; i < args.length; i++) {
      if (args[i] === '--out-dir') outDir = args[i + 1];
      if (args[i] === '--execution-root') execRoot = args[i + 1];
    }
    const resPath = resolve(outDir, 'result.json');
    mkdirSync(dirname(resPath), {recursive:true});
    writeFileSync(resPath, JSON.stringify({
      status: 'completed',
      exit_code: 0,
      execution_root: execRoot,
      spawned_cwd: process.cwd(),
    }));
    process.exit(0);
  `, 'utf8');
  const fvmBin = createFvmWrapper(root, mockScript);

  const spec = join(root, 'tasks.json');
  writeFileSync(spec, JSON.stringify({
    tasks: [{
      id: 'source-root-task',
      implementer: 'sanad',
      workspace: worktree,
      sourceRoot: sourceCheckout,
      command: fvmBin,
      args: [
        'dart', 'run', 'agent/bin/sanad_agent.dart', 'run',
        '--brief-file', briefFile,
        '--workspace', 'ws-logical',
        '--execution-root', worktree,
        '--out-dir', outDir,
        '--events',
      ],
      resultPath: join(outDir, 'result.json'),
      timelinePath: join(outDir, 'events.jsonl'),
      timelineFormat: 'jsonl',
    }],
  }), 'utf8');

  runNode(SUPERVISOR, ['start', '--spec', spec, '--run-dir', runDir, '--max-concurrency', '1']);

  const event = JSON.parse(runNode(WATCH_ONCE, ['--run', runDir, '--since', '0']));
  assert.equal(event.to, 'completed');

  const result = JSON.parse(readFileSync(join(outDir, 'result.json'), 'utf8'));
  assert.equal(result.execution_root, worktree);
  // The CLI process is spawned from the source checkout, not the execution root.
  assert.equal(resolve(result.spawned_cwd), resolve(sourceCheckout));

  const manifest = JSON.parse(readFileSync(join(runDir, 'manifest.json'), 'utf8'));
  // The logical workspace and execution root stay untouched while the spawn
  // root is decoupled and observable.
  assert.equal(manifest.tasks['source-root-task'].workspace, worktree);
  assert.equal(resolve(manifest.tasks['source-root-task'].spawnCwd), resolve(sourceCheckout));
  assert.equal(manifest.tasks['source-root-task'].sourceRoot, sourceCheckout);

  runNode(SUPERVISOR, ['close', '--run', runDir]);
});

test('sanad root-only targeting with a separate sourceRoot validates the execution root', async () => {
  const root = realpathSync(mkdtempSync(join(tmpdir(), 'delegate-rootonly-test-')));
  const sourceCheckout = join(root, 'source-checkout');
  const worktree = join(root, 'target-worktree');
  const outDir = join(root, 'task-out');
  const briefFile = join(root, 'brief.txt');
  const runDir = join(root, 'run');
  mkdirSync(join(sourceCheckout, 'agent', 'bin'), { recursive: true });
  mkdirSync(worktree, { recursive: true });
  mkdirSync(outDir, { recursive: true });
  writeFileSync(briefFile, 'Brief', 'utf8');
  writeFileSync(
    join(sourceCheckout, 'agent', 'bin', 'sanad_agent.dart'),
    '// fixture entry point\n',
    'utf8',
  );

  const mockScript = join(root, 'mock_root_only.mjs');
  writeFileSync(mockScript, `
    import {mkdirSync, writeFileSync} from 'node:fs';
    import {dirname, resolve} from 'node:path';
    const args = process.argv.slice(2);
    let outDir = '';
    let execRoot = '';
    for (let i = 0; i < args.length; i++) {
      if (args[i] === '--out-dir') outDir = args[i + 1];
      if (args[i] === '--execution-root') execRoot = args[i + 1];
    }
    const resPath = resolve(outDir, 'result.json');
    mkdirSync(dirname(resPath), {recursive:true});
    writeFileSync(resPath, JSON.stringify({
      status: 'completed',
      exit_code: 0,
      execution_root: execRoot,
      spawned_cwd: process.cwd(),
    }));
    process.exit(0);
  `, 'utf8');
  const fvmBin = createFvmWrapper(root, mockScript);

  const spec = join(root, 'tasks.json');
  writeFileSync(spec, JSON.stringify({
    tasks: [{
      id: 'root-only-task',
      implementer: 'sanad',
      workspace: worktree,
      sourceRoot: sourceCheckout,
      command: fvmBin,
      args: [
        'dart', 'run', 'agent/bin/sanad_agent.dart', 'run',
        '--brief-file', briefFile,
        '--execution-root', worktree,
        '--out-dir', outDir,
        '--events',
      ],
      resultPath: join(outDir, 'result.json'),
      timelinePath: join(outDir, 'events.jsonl'),
      timelineFormat: 'jsonl',
    }],
  }), 'utf8');

  runNode(SUPERVISOR, ['start', '--spec', spec, '--run-dir', runDir, '--max-concurrency', '1']);

  const event = JSON.parse(runNode(WATCH_ONCE, ['--run', runDir, '--since', '0']));
  assert.equal(event.to, 'completed');

  const result = JSON.parse(readFileSync(join(outDir, 'result.json'), 'utf8'));
  assert.equal(result.execution_root, worktree);
  assert.equal(resolve(result.spawned_cwd), resolve(sourceCheckout));

  runNode(SUPERVISOR, ['close', '--run', runDir]);
});

test('sanad sourceRoot validation fails closed on missing roots, entries, and wrong invocation forms', () => {
  const root = mkdtempSync(join(tmpdir(), 'delegate-sourceval-test-'));
  const worktree = join(root, 'workspace');
  const outDir = join(root, 'out');
  const brief = join(root, 'brief.txt');
  const emptySource = join(root, 'empty-source');
  mkdirSync(worktree, { recursive: true });
  mkdirSync(outDir, { recursive: true });
  mkdirSync(emptySource, { recursive: true });
  writeFileSync(brief, 'Brief', 'utf8');

  const sanadBin = createSanadWrapper(root, join(root, 'mock.mjs'));
  const fvmBin = createFvmWrapper(root, join(root, 'mock.mjs'));

  const validate = (taskOverrides) => {
    const spec = join(root, `spec_${Math.random().toString(36).slice(2)}.json`);
    const runDir = join(root, `run_${Math.random().toString(36).slice(2)}`);
    writeFileSync(spec, JSON.stringify({
      tasks: [{
        id: 'src-val-task',
        implementer: 'sanad',
        workspace: worktree,
        command: sanadBin,
        args: ['run', '--brief-file', brief, '--workspace', 'ws-valid', '--execution-root', worktree, '--out-dir', outDir, '--events'],
        resultPath: join(outDir, 'result.json'),
        timelinePath: join(outDir, 'events.jsonl'),
        timelineFormat: 'jsonl',
        ...taskOverrides,
      }],
    }), 'utf8');
    return runNodeThrows(SUPERVISOR, ['start', '--spec', spec, '--run-dir', runDir]);
  };

  // 1. sourceRoot must be an existing directory
  assert.match(validate({
    sourceRoot: join(root, 'missing-source'),
    command: fvmBin,
    args: ['dart', 'run', 'agent/bin/sanad_agent.dart', 'run', '--brief-file', brief, '--execution-root', worktree, '--out-dir', outDir],
  }), /sourceRoot must be an existing directory/);

  // 2. sourceRoot must contain the requested source entry point
  assert.match(validate({
    sourceRoot: emptySource,
    command: fvmBin,
    args: ['dart', 'run', 'agent/bin/sanad_agent.dart', 'run', '--brief-file', brief, '--execution-root', worktree, '--out-dir', outDir],
  }), /source entry point not found/);

  // 3. Same-root fvm invocation fails closed when the workspace lacks the entry point
  assert.match(validate({
    command: fvmBin,
    args: ['dart', 'run', 'agent/bin/sanad_agent.dart', 'run', '--brief-file', brief, '--execution-root', worktree, '--out-dir', outDir],
  }), /source entry point not found/);

  // 4. sourceRoot is rejected for the installed sanad binary
  assert.match(validate({ sourceRoot: emptySource }), /sourceRoot is only valid for the fvm/);

  // 5. sourceRoot is rejected for non-sanad implementers
  assert.match(validate({
    implementer: 'opencode',
    sourceRoot: emptySource,
    workspace: worktree,
    command: process.execPath,
    args: ['-e', 'process.exit(0)'],
    resultPath: join(outDir, 'result.json'),
    timelinePath: join(outDir, 'events.jsonl'),
    timelineFormat: 'jsonl',
  }), /sourceRoot is only valid for sanad/);

  // 6. Nested consumer entry layout resolves relative to the sourceRoot
  const nestedSource = join(root, 'vendor', 'sanad-agent');
  mkdirSync(join(nestedSource, 'agent', 'bin'), { recursive: true });
  writeFileSync(
    join(nestedSource, 'agent', 'bin', 'sanad_agent.dart'),
    '// fixture entry point\n',
    'utf8',
  );
  const nestedMock = join(root, 'nested_ok.mjs');
  writeFileSync(nestedMock, `
    import {mkdirSync, writeFileSync} from 'node:fs';
    import {dirname, resolve} from 'node:path';
    const args = process.argv.slice(2);
    let outDir = '';
    for (let i = 0; i < args.length; i++) {
      if (args[i] === '--out-dir') outDir = args[i + 1];
    }
    const resPath = resolve(outDir, 'result.json');
    mkdirSync(dirname(resPath), {recursive:true});
    writeFileSync(resPath, JSON.stringify({status: 'completed', exit_code: 0}));
    process.exit(0);
  `, 'utf8');
  const nestedFvm = createFvmWrapper(root, nestedMock);
  const nestedSpec = join(root, 'nested_ok_spec.json');
  const nestedRun = join(root, 'nested_run');
  writeFileSync(
    nestedSpec,
    JSON.stringify({
      tasks: [{
        id: 'nested-ok',
        implementer: 'sanad',
        workspace: worktree,
        sourceRoot: nestedSource,
        command: nestedFvm,
        args: ['dart', 'run', 'agent/bin/sanad_agent.dart', 'run', '--brief-file', brief, '--execution-root', worktree, '--out-dir', outDir, '--events'],
        resultPath: join(outDir, 'result.json'),
        timelinePath: join(outDir, 'events.jsonl'),
        timelineFormat: 'jsonl',
      }],
    }),
    'utf8',
  );
  runNode(SUPERVISOR, ['start', '--spec', nestedSpec, '--run-dir', nestedRun, '--max-concurrency', '1']);
  const nestedEvent = JSON.parse(runNode(WATCH_ONCE, ['--run', nestedRun, '--since', '0']));
  assert.equal(nestedEvent.to, 'completed');
  const nestedResult = JSON.parse(readFileSync(join(outDir, 'result.json'), 'utf8'));
  assert.equal(nestedResult.status, 'completed');
  runNode(SUPERVISOR, ['close', '--run', nestedRun]);
});

test('sanad custom Home propagation injects --home and fails closed on ambiguity', async () => {
  // Canonical root: macOS tmpdir is a /var -> /private/var symlink and the
  // supervisor records canonical workspaces.
  const root = realpathSync(mkdtempSync(join(tmpdir(), 'delegate-home-test-')));
  const worktree = join(root, 'target-worktree');
  const customHome = join(root, 'managed-home');
  const outDir = join(root, 'task-out');
  const briefFile = join(root, 'brief.txt');
  const runDir = join(root, 'run');
  mkdirSync(worktree, { recursive: true });
  mkdirSync(customHome, { recursive: true });
  mkdirSync(outDir, { recursive: true });
  writeFileSync(briefFile, 'Brief', 'utf8');

  // Mock sanad records the full argument vector it received. No token is ever
  // part of the spec; this proves the detached worker attached to the declared
  // custom Home without starting a second runtime.
  const mockScript = join(root, 'mock_home.mjs');
  writeFileSync(mockScript, `
    import {appendFileSync, mkdirSync, writeFileSync} from 'node:fs';
    import {dirname, resolve} from 'node:path';
    const args = process.argv.slice(2);
    let outDir = '';
    let home = null;
    for (let i = 0; i < args.length; i++) {
      if (args[i] === '--out-dir') outDir = args[i + 1];
      if (args[i] === '--home') home = args[i + 1];
    }
    const resPath = resolve(outDir, 'result.json');
    const evPath = resolve(outDir, 'events.jsonl');
    mkdirSync(dirname(resPath), {recursive:true});
    writeFileSync(resPath, JSON.stringify({
      status: 'completed', exit_code: 0, home, argv: args,
      envHome: process.env.SANAD_HOME ?? null,
      envStateHome: process.env.SANAD_STATE_HOME ?? null,
    }));
    appendFileSync(evPath, JSON.stringify({type: 'completed', status: 'completed'}) + '\\n');
    process.exit(0);
  `, 'utf8');
  const sanadBin = createSanadWrapper(root, mockScript);

  const spec = join(root, 'tasks.json');
  writeFileSync(spec, JSON.stringify({
    tasks: [{
      id: 'home-task',
      implementer: 'sanad',
      workspace: worktree,
      home: customHome,
      command: sanadBin,
      args: [
        'run',
        '--brief-file', briefFile,
        '--workspace', 'ws-logical',
        '--execution-root', worktree,
        '--out-dir', outDir,
        '--events',
      ],
      resultPath: join(outDir, 'result.json'),
      timelinePath: join(outDir, 'events.jsonl'),
      timelineFormat: 'jsonl',
    }],
  }), 'utf8');

  // The caller's own Home and state root must never reach the worker (G0).
  runNode(SUPERVISOR, ['start', '--spec', spec, '--run-dir', runDir, '--max-concurrency', '1'], {
    ...process.env,
    SANAD_HOME: join(root, 'caller-home'),
    SANAD_STATE_HOME: join(root, 'caller-state'),
  });

  const event = JSON.parse(runNode(WATCH_ONCE, ['--run', runDir, '--since', '0']));
  assert.equal(event.to, 'completed');

  const result = JSON.parse(readFileSync(join(outDir, 'result.json'), 'utf8'));
  assert.equal(result.status, 'completed');
  assert.equal(result.home, customHome);
  assert.equal(result.argv.filter((value) => value === '--home').length, 1);
  assert.equal(result.envHome, customHome);
  assert.equal(result.envStateHome, null);

  const manifest = JSON.parse(readFileSync(join(runDir, 'manifest.json'), 'utf8'));
  assert.equal(manifest.tasks['home-task'].home, customHome);
  assert.equal(manifest.tasks['home-task'].workspace, worktree);
  assert.equal(JSON.stringify(result).includes('secret'), false);

  runNode(SUPERVISOR, ['close', '--run', runDir]);
});

test('sanad home validation fails closed on relative, missing, or duplicate declarations', () => {
  const root = mkdtempSync(join(tmpdir(), 'delegate-homeval-test-'));
  const worktree = join(root, 'workspace');
  const outDir = join(root, 'out');
  const brief = join(root, 'brief.txt');
  mkdirSync(worktree, { recursive: true });
  mkdirSync(outDir, { recursive: true });
  writeFileSync(brief, 'Brief', 'utf8');
  const missingHome = join(root, 'no-such-home');

  const sanadBin = createSanadWrapper(root, join(root, 'mock.mjs'));
  const fvmBin = createFvmWrapper(root, join(root, 'mock.mjs'));

  const validate = (taskOverrides) => {
    const spec = join(root, `spec_${Math.random().toString(36).slice(2)}.json`);
    const runDir = join(root, `run_${Math.random().toString(36).slice(2)}`);
    writeFileSync(spec, JSON.stringify({
      tasks: [{
        id: 'home-val-task',
        implementer: 'sanad',
        workspace: worktree,
        command: sanadBin,
        args: ['run', '--brief-file', brief, '--workspace', 'ws-valid', '--execution-root', worktree, '--out-dir', outDir, '--events'],
        resultPath: join(outDir, 'result.json'),
        timelinePath: join(outDir, 'events.jsonl'),
        timelineFormat: 'jsonl',
        ...taskOverrides,
      }],
    }), 'utf8');
    return runNodeThrows(SUPERVISOR, ['start', '--spec', spec, '--run-dir', runDir]);
  };

  // 1. Relative home is rejected (a detached worker must never guess a Home).
  assert.match(validate({ home: 'relative-home' }), /home must be an absolute path/);

  // 2. Missing home directory fails closed before any worker spawns.
  assert.match(validate({ home: missingHome }), /home must be an existing directory/);

  // 3. Declaring --home inside args is ambiguous and rejected; task.home owns it.
  assert.match(validate({
    home: worktree,
    args: ['run', '--brief-file', brief, '--workspace', 'ws-valid', '--execution-root', worktree, '--out-dir', outDir, '--home', worktree, '--events'],
  }), /declare the custom Home via task.home/);
  assert.match(validate({
    args: ['run', '--brief-file', brief, '--workspace', 'ws-valid', '--execution-root', worktree, '--out-dir', outDir, `--home=${worktree}`, '--events'],
  }), /declare the custom Home via task.home/);

  // 4. home is valid only for sanad tasks.
  assert.match(validate({
    implementer: 'opencode',
    home: worktree,
    command: process.execPath,
    args: ['-e', 'process.exit(0)'],
  }), /home is only valid for sanad tasks/);

  // 5. The fvm source-development form accepts an explicit custom Home too,
  //    with the same injection guarantees (no standalone fallback path).
  const fvmSpec = join(root, 'fvm_home_ok.json');
  const fvmRun = join(root, 'fvm_home_run');
  const fvmOut = join(root, 'fvm_home_out');
  mkdirSync(join(worktree, 'agent', 'bin'), { recursive: true });
  writeFileSync(join(worktree, 'agent', 'bin', 'sanad_agent.dart'), '// fixture entry\n', 'utf8');
  const fvmHomeMock = join(root, 'fvm_home_ok.mjs');
  writeFileSync(fvmHomeMock, `
    import {mkdirSync, writeFileSync} from 'node:fs';
    import {dirname, resolve} from 'node:path';
    const args = process.argv.slice(2);
    let outDir = '';
    let home = null;
    for (let i = 0; i < args.length; i++) {
      if (args[i] === '--out-dir') outDir = args[i + 1];
      if (args[i] === '--home') home = args[i + 1];
    }
    const resPath = resolve(outDir, 'result.json');
    mkdirSync(dirname(resPath), {recursive:true});
    writeFileSync(resPath, JSON.stringify({status: 'completed', exit_code: 0, home}));
    process.exit(0);
  `, 'utf8');
  const fvmHomeBin = createFvmWrapper(root, fvmHomeMock);
  writeFileSync(fvmSpec, JSON.stringify({
    tasks: [{
      id: 'fvm-home-ok',
      implementer: 'sanad',
      workspace: worktree,
      home: worktree,
      command: fvmHomeBin,
      args: ['dart', 'run', 'agent/bin/sanad_agent.dart', 'run', '--brief-file', brief, '--execution-root', worktree, '--out-dir', fvmOut, '--events'],
      resultPath: join(fvmOut, 'result.json'),
      timelinePath: join(fvmOut, 'events.jsonl'),
      timelineFormat: 'jsonl',
    }],
  }), 'utf8');
  runNode(SUPERVISOR, ['start', '--spec', fvmSpec, '--run-dir', fvmRun, '--max-concurrency', '1']);
  const fvmEvent = JSON.parse(runNode(WATCH_ONCE, ['--run', fvmRun, '--since', '0']));
  assert.equal(fvmEvent.to, 'completed');
  const fvmResult = JSON.parse(readFileSync(join(fvmOut, 'result.json'), 'utf8'));
  assert.equal(fvmResult.home, worktree);
  runNode(SUPERVISOR, ['close', '--run', fvmRun]);
});

test('timeline formatting distinguishes source timestamp, receipt timestamp, and unknown time', () => {
  const root = mkdtempSync(join(tmpdir(), 'timeline-format-test-'));
  const runDir = join(root, 'run');
  const out = join(root, 'out');
  mkdirSync(runDir, { recursive: true });
  mkdirSync(out, { recursive: true });

  const eventsPath = join(out, 'events.jsonl');
  writeFileSync(eventsPath, [
    JSON.stringify({ type: 'session_started', timestamp: '2026-09-23T01:00:00.000Z' }),
    JSON.stringify({ type: 'notice', timestamp: '2026-09-23T01:01:00.000Z', code: 'provider_timeout', message: 'upstream timed out' }),
    JSON.stringify({ type: 'blocked', timestamp: '2026-09-23T01:01:05.000Z', data: { cause: 'provider_timeout' } }),
    JSON.stringify({ type: 'resumed', timestamp: '2026-09-23T01:02:00.000Z' }),
    JSON.stringify({ type: 'tool_use', timestamp: '2026-09-23T01:02:30.000Z', part: { tool: 'view_file', state: { status: 'running', input: { path: 'lib/test.dart' } } } }),
    JSON.stringify({ type: 'plain_event' }),
    'raw unparseable text without date',
  ].join('\n') + '\n', 'utf8');

  const manifest = {
    version: 'delegate-supervisor.v1',
    runDir,
    supervisorPid: process.pid,
    status: 'running',
    closed: false,
    seq: 1,
    startedAt: '2026-09-23T01:00:00.000Z',
    finishedAt: null,
    maxConcurrency: 1,
    tasks: {
      t1: {
        id: 't1',
        implementer: 'sanad',
        workspace: root,
        status: 'running',
        timelinePath: eventsPath,
        timelineFormat: 'jsonl',
        stdoutPath: join(runDir, 't1.stdout.log'),
        stderrPath: join(runDir, 't1.stderr.log'),
        resultPath: join(out, 'result.json'),
        pid: process.pid,
        startedAt: '2026-09-23T01:00:00.000Z',
        finishedAt: null,
        exitCode: null,
        signal: null,
        error: null,
        cause: null,
        stateSince: null,
        lastProgressAt: null,
      },
    },
  };
  writeFileSync(join(runDir, 'manifest.json'), JSON.stringify(manifest, null, 2), 'utf8');
  writeFileSync(join(runDir, 'events.jsonl'), JSON.stringify({
    seq: 1,
    taskId: 't1',
    implementer: 'sanad',
    workspace: root,
    from: 'queued',
    to: 'running',
    at: '2026-09-23T01:00:00.000Z',
  }) + '\n', 'utf8');

  const timelineOutput = runNode(SUPERVISOR, ['timeline', '--run', runDir, '--task', 't1']);
  assert.match(timelineOutput, /2026-09-23T01:00:00\.000Z\s+t1\s+queued -> running/);
  assert.match(timelineOutput, /2026-09-23T01:01:00\.000Z\s+notice:provider_timeout\s+upstream timed out/);
  assert.match(timelineOutput, /2026-09-23T01:01:05\.000Z\s+blocked \(provider_timeout\)/);
  assert.match(timelineOutput, /2026-09-23T01:02:00\.000Z\s+resuming/);
  assert.match(timelineOutput, /2026-09-23T01:02:30\.000Z\s+tool:view_file/);
  assert.match(timelineOutput, /\[unknown time\]\s+plain_event/);
  assert.match(timelineOutput, /\[unknown time\]\s+raw unparseable text without date/);

  // Footer verification
  assert.match(timelineOutput, /--- Session Observability ---/);
  // A live PID without an authoritative persisted progress timestamp is not
  // evidence that the session is actively working.
  assert.match(timelineOutput, /Session State:\s+unknown/);
  assert.match(timelineOutput, /Current Time:\s+\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/);
});

test('session footer derives blocked state, cause, progress, and preserves json compatibility', () => {
  const root = mkdtempSync(join(tmpdir(), 'session-footer-test-'));
  const runDir = join(root, 'run');
  const out = join(root, 'out');
  mkdirSync(runDir, { recursive: true });
  mkdirSync(out, { recursive: true });

  const resultPath = join(out, 'result.json');
  writeFileSync(resultPath, JSON.stringify({
    status: 'blocked',
    cause: 'provider_timeout',
    state_since: '2026-09-23T01:10:00.000Z',
    last_progress_at: '2026-09-23T01:08:00.000Z',
    started_at: '2026-09-23T01:00:00.000Z',
  }), 'utf8');

  const manifest = {
    version: 'delegate-supervisor.v1',
    runDir,
    supervisorPid: process.pid,
    status: 'running',
    closed: false,
    seq: 2,
    startedAt: '2026-09-23T01:00:00.000Z',
    finishedAt: null,
    maxConcurrency: 1,
    tasks: {
      stalled_task: {
        id: 'stalled_task',
        implementer: 'sanad',
        workspace: root,
        status: 'running',
        timelinePath: null,
        stdoutPath: join(runDir, 'stalled.stdout.log'),
        stderrPath: join(runDir, 'stalled.stderr.log'),
        resultPath,
        pid: process.pid,
        startedAt: '2026-09-23T01:00:00.000Z',
        finishedAt: null,
        cause: 'provider_timeout',
        stateSince: '2026-09-23T01:10:00.000Z',
        lastProgressAt: '2026-09-23T01:08:00.000Z',
      },
    },
  };
  writeFileSync(join(runDir, 'manifest.json'), JSON.stringify(manifest, null, 2), 'utf8');
  writeFileSync(join(runDir, 'events.jsonl'), '', 'utf8');

  const humanStatus = runNode(SUPERVISOR, ['status', '--run', runDir]);
  assert.match(humanStatus, /--- Session Observability ---/);
  assert.match(humanStatus, /Task ID:\s+stalled_task/);
  assert.match(humanStatus, /Session State:\s+blocked/);
  assert.match(humanStatus, /Cause:\s+provider_timeout/);
  assert.match(humanStatus, /State Since:\s+2026-09-23T01:10:00\.000Z/);
  assert.match(humanStatus, /Last Progress:\s+2026-09-23T01:08:00\.000Z/);
  assert.match(humanStatus, /Observation Source:\s+result\.json \(process alive: \d+\)/);

  const jsonStatus = JSON.parse(runNode(SUPERVISOR, ['status', '--run', runDir, '--json']));
  assert.equal(jsonStatus.status, 'running');
  assert.equal(jsonStatus.tasks.stalled_task.sessionState, 'blocked');
  assert.equal(jsonStatus.tasks.stalled_task.sessionCause, 'provider_timeout');
  assert.equal(jsonStatus.tasks.stalled_task.stateSince, '2026-09-23T01:10:00.000Z');
  assert.equal(jsonStatus.tasks.stalled_task.lastProgressAt, '2026-09-23T01:08:00.000Z');
});

test('default watch-once surfaces blocked and resuming transitions', () => {
  const runDir = mkdtempSync(join(tmpdir(), 'watch-state-test-'));
  writeFileSync(join(runDir, 'manifest.json'), JSON.stringify({
    status: 'running',
    supervisorPid: process.pid,
    seq: 2,
  }), 'utf8');
  writeFileSync(join(runDir, 'events.jsonl'), [
    JSON.stringify({ seq: 1, taskId: 'task-1', from: 'running', to: 'blocked', cause: 'provider_timeout' }),
    JSON.stringify({ seq: 2, taskId: 'task-1', from: 'blocked', to: 'resuming' }),
  ].join('\n') + '\n', 'utf8');

  const blocked = JSON.parse(runNode(WATCH_ONCE, ['--run', runDir, '--since', '0']));
  assert.equal(blocked.to, 'blocked');
  assert.equal(blocked.cause, 'provider_timeout');
  const resuming = JSON.parse(runNode(WATCH_ONCE, ['--run', runDir, '--since', '1']));
  assert.equal(resuming.to, 'resuming');
});

test('legacy timeout footer and logs use honest causes and timestamps', () => {
  const root = mkdtempSync(join(tmpdir(), 'legacy-observability-test-'));
  const runDir = join(root, 'run');
  const out = join(root, 'out');
  mkdirSync(runDir, { recursive: true });
  mkdirSync(out, { recursive: true });
  const resultPath = join(out, 'result.json');
  const stdoutPath = join(runDir, 'legacy.stdout.log');
  const stderrPath = join(runDir, 'legacy.stderr.log');
  writeFileSync(resultPath, JSON.stringify({ status: 'timeout', exit_code: 124 }), 'utf8');
  writeFileSync(stdoutPath, '2026-09-23T03:30:00+02:00 source event\nlegacy line without time\n', 'utf8');
  writeFileSync(stderrPath, '', 'utf8');
  writeFileSync(join(runDir, 'events.jsonl'), '', 'utf8');
  writeFileSync(join(runDir, 'manifest.json'), JSON.stringify({
    version: 'delegate-supervisor.v1',
    runDir,
    supervisorPid: process.pid,
    status: 'running',
    closed: false,
    seq: 1,
    tasks: {
      legacy: {
        id: 'legacy',
        implementer: 'sanad',
        workspace: root,
        status: 'timeout',
        pid: 2147483647,
        startedAt: '2026-09-23T01:00:00.000Z',
        finishedAt: '2026-09-23T01:15:00.000Z',
        resultPath,
        timelinePath: null,
        stdoutPath,
        stderrPath,
      },
    },
  }), 'utf8');

  const status = runNode(SUPERVISOR, ['status', '--run', runDir, '--task', 'legacy']);
  assert.match(status, /Session State:\s+stopped/);
  assert.match(status, /Cause:\s+timeout/);
  assert.match(status, /State Since:\s+2026-09-23T01:15:00\.000Z/);
  assert.doesNotMatch(status, /State Since:\s+2026-09-23T01:00:00\.000Z/);

  const logs = runNode(SUPERVISOR, ['logs', '--run', runDir, '--task', 'legacy']);
  assert.match(logs, /2026-09-23T01:30:00\.000Z\s+source event/);
  assert.match(logs, /\[unknown time\]\s+legacy line without time/);
});

test('supervisor preserves incomplete status and missing_final cause from result.json without false completion', () => {
  const root = mkdtempSync(join(tmpdir(), 'incomplete-observability-test-'));
  const runDir = join(root, 'run');
  const out = join(root, 'out');
  mkdirSync(runDir, { recursive: true });
  mkdirSync(out, { recursive: true });
  const resultPath = join(out, 'result.json');
  const stdoutPath = join(runDir, 'inc.stdout.log');
  const stderrPath = join(runDir, 'inc.stderr.log');
  writeFileSync(resultPath, JSON.stringify({
    status: 'incomplete',
    exit_code: 1,
    cause: 'missing_final',
    error: 'Execution finished without a final summary (missing final).',
    state_since: '2026-09-24T04:00:00.000Z',
  }), 'utf8');
  writeFileSync(stdoutPath, 'running/...\n', 'utf8');
  writeFileSync(stderrPath, 'Error: Turn execution completed without a final summary (missing final).\n', 'utf8');
  writeFileSync(join(runDir, 'events.jsonl'), '', 'utf8');
  writeFileSync(join(runDir, 'manifest.json'), JSON.stringify({
    version: 'delegate-supervisor.v1',
    runDir,
    supervisorPid: process.pid,
    status: 'running',
    closed: false,
    seq: 1,
    tasks: {
      task97f: {
        id: 'task97f',
        implementer: 'sanad',
        workspace: root,
        status: 'incomplete',
        cause: 'missing_final',
        pid: 2147483647,
        startedAt: '2026-09-24T03:50:00.000Z',
        finishedAt: '2026-09-24T04:00:00.000Z',
        resultPath,
        timelinePath: null,
        stdoutPath,
        stderrPath,
      },
    },
  }), 'utf8');

  const status = runNode(SUPERVISOR, ['status', '--run', runDir, '--task', 'task97f']);
  assert.match(status, /Session State:\s+incomplete/);
  assert.match(status, /Cause:\s+missing_final/);
  assert.doesNotMatch(status, /Session State:\s+completed/);
});

test('observer records start timing and cancellation without manufacturing durations', async () => {
  const root = mkdtempSync(join(tmpdir(), 'observer-timing-test-'));
  const runDir = join(root, 'run');
  const out = join(root, 'out');
  const observersDir = join(runDir, 'observers');
  mkdirSync(runDir, { recursive: true });
  mkdirSync(out, { recursive: true });
  mkdirSync(observersDir, { recursive: true });

  const timelinePath = join(out, 'events.jsonl');
  writeFileSync(timelinePath, JSON.stringify({ type: 'start', timestamp: new Date().toISOString() }) + '\n', 'utf8');

  const manifest = {
    version: 'delegate-supervisor.v1',
    runDir,
    supervisorPid: process.pid,
    status: 'running',
    closed: false,
    seq: 1,
    startedAt: new Date().toISOString(),
    finishedAt: null,
    maxConcurrency: 1,
    tasks: {
      obs_task: {
        id: 'obs_task',
        implementer: 'sanad',
        workspace: root,
        status: 'running',
        timelinePath,
        timelineFormat: 'jsonl',
        stdoutPath: join(runDir, 'obs.stdout.log'),
        stderrPath: join(runDir, 'obs.stderr.log'),
        resultPath: null,
        pid: process.pid,
        startedAt: new Date().toISOString(),
      },
    },
  };
  writeFileSync(join(runDir, 'manifest.json'), JSON.stringify(manifest, null, 2), 'utf8');
  writeFileSync(join(runDir, 'events.jsonl'), '', 'utf8');

  const child = spawn(process.execPath, [
    SUPERVISOR,
    'timeline',
    '--run', runDir,
    '--task', 'obs_task',
    '--follow',
  ], { stdio: ['ignore', 'pipe', 'pipe'] });
  let childStderr = '';
  let childStdout = '';
  child.stderr.on('data', (d) => { childStderr += d.toString(); });
  child.stdout.on('data', (d) => { childStdout += d.toString(); });

  const observerFile = join(observersDir, `${child.pid}.json`);

  const record = await waitForFileChange(observersDir, () => {
    if (!existsSync(observerFile)) return null;
    return JSON.parse(readFileSync(observerFile, 'utf8'));
  });
  assert.equal(record.pid, child.pid);
  assert.equal(record.command, 'timeline');
  assert.equal(record.status, 'active');
  assert.ok(record.startedAt, 'startedAt is set');
  assert.equal(record.endedAt, null, 'endedAt is initially null');

  child.kill();
  await new Promise((res) => {
    child.once('exit', res);
    setTimeout(res, 1000);
  });

  const finalRecord = JSON.parse(readFileSync(observerFile, 'utf8'));
  assert.ok(finalRecord.startedAt, 'startedAt is preserved');
  if (finalRecord.status === 'cancelled') {
    assert.ok(finalRecord.endedAt, 'endedAt set on graceful cancellation');
  } else {
    assert.equal(finalRecord.endedAt, null, 'endedAt remains null on hard kill');
  }
});

// Remote `sanad-client` delegation: the supervisor drives the loopback Client
// CLI instead of a local `sanad run`. The fixture stands in for that client:
// it reads the local brief, requires immediate stdin EOF, relays NDJSON
// lifecycle events plus the terminal `--json` envelope on stdout, and exits
// with the documented Client CLI codes.
function writeRemoteSanadClientFixture(root) {
  const fixture = join(root, 'mock_sanad_client.mjs');
  writeFileSync(fixture, `
    import {readFileSync} from 'node:fs';

    const args = process.argv.slice(2);
    const deviceFlagIndex = args.findIndex((arg) => arg === '-d' || arg === '--device');
    const device = deviceFlagIndex >= 0
      ? args[deviceFlagIndex + 1]
      : (args[0]?.startsWith('--device=') ? args[0].slice('--device='.length) : null);
    const valueOf = (flag) => {
      const index = args.indexOf(flag);
      return index >= 0 ? args[index + 1] : null;
    };
    const session = valueOf('--session');
    const briefPath = valueOf('--brief-file');

    // A supervised child must observe immediate stdin EOF. An inherited pipe
    // that the supervisor never closes blocks this read forever.
    const stdinText = readFileSync(0, 'utf8');
    const brief = readFileSync(briefPath, 'utf8');
    const envelope = (exitCode) => JSON.stringify({
      session_id: session,
      text: brief.trim(),
      tool_executions: [],
      exit_code: exitCode,
      remote_argv: args,
      stdin_bytes: stdinText.length,
    });

    if (device === 'dev-ok') {
      process.stdout.write(JSON.stringify({
        type: 'running',
        timestamp: new Date().toISOString(),
        session_id: session,
        data: {},
      }) + '\\n');
      process.stdout.write(JSON.stringify({
        type: 'needs_input',
        timestamp: new Date().toISOString(),
        session_id: session,
        data: { request_id: 'req-remote-1', kind: 'question', questions: [{ text: 'Which branch?' }] },
      }) + '\\n');
      setTimeout(() => {
        process.stdout.write(envelope(0) + '\\n');
        process.exit(0);
      }, 400);
    } else if (device === 'silent-0') {
      // A control socket that closes without a terminal result frame.
      process.exit(0);
    } else {
      const code = Number(String(device).replace('code-', ''));
      if (code === 69) {
        process.stderr.write('Error: No active Sanad Client found for Sanad Home: /tmp/remote-home.\\n');
      }
      if (code === 77) {
        process.stderr.write('Error: Client CLI is disabled in Sanad Client settings for Sanad Home: /tmp/remote-home.\\n');
      }
      if (code === 124 || code === 130) {
        process.stdout.write(envelope(code) + '\\n');
      }
      process.exit(code);
    }
  `, 'utf8');
  return createNamedWrapper(root, 'sanad-client', fixture);
}

test('sanad-client remote validation requires the relay contract and rejects malformed forms', () => {
  const root = mkdtempSync(join(tmpdir(), 'delegate-remote-val-test-'));
  const workspace = join(root, 'workspace');
  const brief = join(root, 'brief.md');
  mkdirSync(workspace, { recursive: true });
  writeFileSync(brief, 'Remote brief\n', 'utf8');

  const remoteBin = writeRemoteSanadClientFixture(root);
  const baseArgs = (extra = []) => [
    '-d', 'dev-linux-build-node', 'run',
    '--workspace', 'ws-remote-01',
    '--brief-file', brief,
    '--session', 'session-remote-01',
    '--events', '--json',
    ...extra,
  ];

  const validate = (taskOverrides) => {
    const spec = join(root, `spec_${Math.random().toString(36).slice(2)}.json`);
    const runDir = join(root, `run_${Math.random().toString(36).slice(2)}`);
    writeFileSync(spec, JSON.stringify({
      tasks: [{
        id: 'remote-val-task',
        implementer: 'sanad',
        workspace,
        command: remoteBin,
        args: baseArgs(),
        ...taskOverrides,
      }],
    }), 'utf8');
    return runNodeThrows(SUPERVISOR, ['start', '--spec', spec, '--run-dir', runDir]);
  };

  // 1. The canonical form is accepted and derives its own artifact paths.
  const acceptedSpec = join(root, 'spec_ok.json');
  const acceptedRun = join(root, 'run_ok');
  writeFileSync(acceptedSpec, JSON.stringify({
    tasks: [{
      id: 'remote-accepted',
      implementer: 'sanad',
      workspace,
      command: remoteBin,
      args: baseArgs(),
    }],
  }), 'utf8');
  runNode(SUPERVISOR, ['start', '--spec', acceptedSpec, '--run-dir', acceptedRun]);
  const acceptedManifest = JSON.parse(readFileSync(join(acceptedRun, 'manifest.json'), 'utf8'));
  const accepted = acceptedManifest.tasks['remote-accepted'];
  assert.equal(accepted.remote, true);
  assert.equal(accepted.remoteDevice, 'dev-linux-build-node');
  assert.equal(resolve(accepted.timelinePath), resolve(accepted.stdoutPath));
  assert.equal(resolve(accepted.resultPath), resolve(acceptedRun, 'remote-accepted.result.json'));
  runNode(SUPERVISOR, ['close', '--run', acceptedRun]);

  // 2. Only `-d <device> run` may be relayed: no other Sanad subcommand.
  assert.match(validate({ args: ['-d', 'dev-a', 'session', 'stop', 'sess-1', '--json'] }), /sanad-client invocation must be/);
  assert.match(validate({ args: ['run', '--workspace', 'ws', '--brief-file', brief, '--session', 's', '--events', '--json'] }), /sanad-client invocation must be/);

  // 3. The device is mandatory, needs a value, and cannot be re-targeted later.
  assert.match(validate({ args: ['--json', 'run'] }), /sanad-client invocation must be/);
  assert.match(validate({ args: ['-d', '--json', 'run', '--workspace', 'ws', '--brief-file', brief, '--session', 's', '--events'] }), /-d requires a value/);
  assert.match(validate({ args: baseArgs(['-d', 'dev-other']) }), /duplicate --device/);

  // 4. A built binary path must be absolute when it names a location.
  assert.match(validate({ command: 'bin/sanad-client' }), /sanad-client command path must be absolute/);

  // 5. Remote targeting: one of --workspace/--execution-root, brief, session.
  assert.match(validate({ args: ['-d', 'dev-a', 'run', '--brief-file', brief, '--session', 's', '--events', '--json'] }), /requires --workspace \(remote workspace id\) or --execution-root/);
  assert.match(validate({ args: ['-d', 'dev-a', 'run', '--workspace', 'ws', '--session', 's', '--events', '--json'] }), /requires --brief-file/);
  assert.match(validate({ args: ['-d', 'dev-a', 'run', '--workspace', 'ws', '--brief-file', join(root, 'missing.md'), '--session', 's', '--events', '--json'] }), /--brief-file must be an existing absolute file path/);
  assert.match(validate({ args: ['-d', 'dev-a', 'run', '--workspace', 'ws', '--brief-file', brief, '--events', '--json'] }), /requires --session/);

  // 6. Machine-readable artifacts are mandatory and caller-owned.
  assert.match(validate({ args: ['-d', 'dev-a', 'run', '--workspace', 'ws', '--brief-file', brief, '--session', 's', '--events'] }), /requires --json/);
  assert.match(validate({ args: ['-d', 'dev-a', 'run', '--workspace', 'ws', '--brief-file', brief, '--session', 's', '--json'] }), /requires --events/);
  assert.match(validate({ args: baseArgs(['--out-dir', join(root, 'out')]) }), /must not pass --out-dir/);
  assert.match(validate({ timelinePath: join(root, 'events.jsonl') }), /do not declare timelinePath/);

  // 7. Shared Sanad guards still apply to the remote form.
  assert.match(validate({ sourceRoot: root }), /sourceRoot is only valid for the fvm/);
  assert.match(validate({ args: baseArgs(['--home', root]) }), /declare the custom Home via task.home/);
  assert.match(validate({ args: baseArgs(['--api-key=secret']) }), /must not pass credentials/);
  assert.match(validate({ home: 'relative-home' }), /home must be an absolute path/);
});

test('sanad-client remote task streams relayed events, captures the envelope, and preserves identity', async () => {
  const root = mkdtempSync(join(tmpdir(), 'delegate-remote-run-test-'));
  const workspace = join(root, 'workspace');
  const brief = join(root, 'brief.md');
  const runDir = join(root, 'run');
  mkdirSync(workspace, { recursive: true });
  writeFileSync(brief, 'Remote brief body\n', 'utf8');

  const remoteBin = writeRemoteSanadClientFixture(root);
  const spec = join(root, 'tasks.json');
  writeFileSync(spec, JSON.stringify({
    tasks: [{
      id: 'remote-run',
      implementer: 'sanad',
      workspace,
      command: remoteBin,
      args: [
        '-d', 'dev-ok', 'run',
        '--workspace', 'ws-remote-01',
        // A remote execution root is a target-side path: it must never be
        // validated or canonicalized against the local workspace.
        '--execution-root', '/srv/remote/worktree',
        '--brief-file', brief,
        '--session', 'session-remote-1',
        '--events', '--json',
      ],
    }],
  }), 'utf8');

  runNode(SUPERVISOR, ['start', '--spec', spec, '--run-dir', runDir, '--max-concurrency', '1']);

  const intervention = JSON.parse(runNode(WATCH_ONCE, ['--run', runDir, '--since', '0']));
  assert.equal(intervention.to, 'needs_input');
  assert.equal(intervention.requestId, 'req-remote-1');
  assert.equal(intervention.intervention.kind, 'question');

  const completion = JSON.parse(runNode(WATCH_ONCE, ['--run', runDir, '--since', String(intervention.seq)]));
  assert.equal(completion.to, 'completed');

  const manifest = JSON.parse(readFileSync(join(runDir, 'manifest.json'), 'utf8'));
  const task = manifest.tasks['remote-run'];
  assert.equal(task.status, 'completed');
  assert.equal(task.exitCode, 0);
  assert.equal(task.resultCaptured, true);
  assert.equal(task.remoteDevice, 'dev-ok');
  assert.equal(task.identity.sessionId, 'session-remote-1');
  assert.equal(resolve(task.timelinePath), resolve(task.stdoutPath));

  const envelope = JSON.parse(readFileSync(task.resultPath, 'utf8'));
  assert.equal(envelope.exit_code, 0);
  assert.equal(envelope.session_id, 'session-remote-1');
  assert.equal(envelope.text, 'Remote brief body');
  // The brief was read locally and stdin reached EOF; the relayed argv kept the
  // remote workspace id and remote execution root verbatim.
  assert.equal(envelope.stdin_bytes, 0);
  assert.match(envelope.remote_argv.join(' '), /--workspace ws-remote-01/);
  assert.match(envelope.remote_argv.join(' '), /--execution-root \/srv\/remote\/worktree/);

  const status = runNode(SUPERVISOR, ['status', '--run', runDir, '--task', 'remote-run']);
  assert.match(status, /Session State:\s+completed/);
  assert.match(status, /Observation Source:\s+result\.json/);

  runNode(SUPERVISOR, ['close', '--run', runDir]);
});

test('sanad-client remote exit codes map to timeout, cancelled, blocked, and incomplete', async () => {
  const root = mkdtempSync(join(tmpdir(), 'delegate-remote-exit-test-'));
  const workspace = join(root, 'workspace');
  const brief = join(root, 'brief.md');
  const runDir = join(root, 'run');
  mkdirSync(workspace, { recursive: true });
  writeFileSync(brief, 'Remote brief body\n', 'utf8');

  const remoteBin = writeRemoteSanadClientFixture(root);
  const devices = [
    ['remote-timeout', 'code-124'],
    ['remote-cancelled', 'code-130'],
    ['remote-client-down', 'code-69'],
    ['remote-cli-disabled', 'code-77'],
    ['remote-silent-success', 'silent-0'],
  ];
  const spec = join(root, 'tasks.json');
  writeFileSync(spec, JSON.stringify({
    tasks: devices.map(([id, device]) => ({
      id,
      implementer: 'sanad',
      workspace,
      command: remoteBin,
      args: [
        '-d', device, 'run',
        '--workspace', 'ws-remote-01',
        '--brief-file', brief,
        '--session', `session-${id}`,
        '--events', '--json',
      ],
    })),
  }), 'utf8');

  runNode(SUPERVISOR, ['start', '--spec', spec, '--run-dir', runDir, '--max-concurrency', '1']);
  runNode(SUPERVISOR, ['close', '--run', runDir, '--wait']);

  const manifest = JSON.parse(readFileSync(join(runDir, 'manifest.json'), 'utf8'));
  const timeout = manifest.tasks['remote-timeout'];
  assert.equal(timeout.status, 'timeout');
  assert.equal(timeout.cause, 'timeout');
  assert.equal(timeout.exitCode, 124);

  const cancelled = manifest.tasks['remote-cancelled'];
  assert.equal(cancelled.status, 'cancelled');
  assert.equal(cancelled.exitCode, 130);

  const clientDown = manifest.tasks['remote-client-down'];
  assert.equal(clientDown.status, 'blocked');
  assert.equal(clientDown.cause, 'client_unavailable');
  assert.equal(clientDown.exitCode, 69);
  assert.match(clientDown.error, /No active Sanad Client/);

  const disabled = manifest.tasks['remote-cli-disabled'];
  assert.equal(disabled.status, 'blocked');
  assert.equal(disabled.cause, 'client_cli_disabled');
  assert.match(disabled.error, /Client CLI is disabled/);

  // Exit 0 without a relayed envelope is not a completed turn.
  const silent = manifest.tasks['remote-silent-success'];
  assert.equal(silent.status, 'incomplete');
  assert.equal(silent.cause, 'missing_result_envelope');
  assert.equal(silent.resultCaptured, false);
  assert.equal(existsSync(silent.resultPath), false);
});

test('watch-once wakes on journaled incomplete and needs_review terminals', () => {
  const root = mkdtempSync(join(tmpdir(), 'watch-incomplete-test-'));
  const runDir = join(root, 'run');
  mkdirSync(runDir, { recursive: true });
  writeFileSync(join(runDir, 'manifest.json'), JSON.stringify({
    version: 'delegate-supervisor.v1',
    runDir,
    supervisorPid: process.pid,
    status: 'running',
    closed: false,
    seq: 2,
    tasks: {},
  }), 'utf8');
  writeFileSync(join(runDir, 'events.jsonl'), [
    JSON.stringify({ seq: 1, taskId: 'remote-silent', to: 'running', at: '2026-10-22T00:00:00.000Z' }),
    JSON.stringify({ seq: 2, taskId: 'remote-silent', to: 'incomplete', at: '2026-10-22T00:00:01.000Z' }),
    JSON.stringify({ seq: 3, taskId: 'review', to: 'needs_review', at: '2026-10-22T00:00:02.000Z' }),
  ].join('\n') + '\n', 'utf8');

  const first = JSON.parse(runNode(WATCH_ONCE, ['--run', runDir, '--since', '0']));
  assert.equal(first.to, 'incomplete');
  const second = JSON.parse(runNode(WATCH_ONCE, ['--run', runDir, '--since', String(first.seq)]));
  assert.equal(second.to, 'needs_review');
});

// --- Queue controls (S1-S5) -------------------------------------------------

// Shared fixture: a task records that it actually started (so a cancelled or
// aborted task can be proven never to have run) and settles after its delay.
function writePacedFixture(root) {
  const fixture = join(root, 'paced_task.mjs');
  writeFileSync(fixture, `
    import {mkdirSync, writeFileSync} from 'node:fs';
    import {dirname} from 'node:path';
    const [delay, resultPath, markerPath] = process.argv.slice(2);
    mkdirSync(dirname(markerPath), {recursive:true});
    writeFileSync(markerPath, 'started');
    setTimeout(() => {
      mkdirSync(dirname(resultPath), {recursive:true});
      writeFileSync(resultPath, JSON.stringify({status:'completed', exitCode:0}));
      process.exit(0);
    }, Number(delay));
  `, 'utf8');
  return fixture;
}

function pacedTask(fixture, workspace, results, id, delay) {
  const out = join(results, id);
  return {
    id,
    implementer: 'opencode',
    workspace,
    command: process.execPath,
    args: [fixture, String(delay), join(out, 'result.json'), taskMarker(results, id)],
    resultPath: join(out, 'result.json'),
  };
}

function taskMarker(results, id) {
  return join(results, id, 'started.marker');
}

function readJournal(runDir) {
  const path = join(runDir, 'events.jsonl');
  if (!existsSync(path)) return [];
  return readFileSync(path, 'utf8')
    .split(/\r?\n/)
    .filter((line) => line.trim())
    .map((line) => {
      try {
        return JSON.parse(line);
      } catch {
        return null;
      }
    })
    .filter(Boolean);
}

function queueFixture(root, name) {
  const workspace = join(root, `${name}-workspace`);
  const results = join(root, `${name}-results`);
  mkdirSync(workspace, { recursive: true });
  mkdirSync(results, { recursive: true });
  return { workspace, results };
}

test('start reports the effective concurrency and enqueue reports per-task position and counts', async () => {
  const root = mkdtempSync(join(tmpdir(), 'delegate-queue-report-test-'));
  const fixture = writePacedFixture(root);
  const config = join(root, 'config');
  mkdirSync(config, { recursive: true });
  const env = { ...process.env, XDG_CONFIG_HOME: config };

  // S1: omitting the flag is not a hidden single slot. One slot per spec task
  // is the documented default and the handshake states it.
  const defaultRun = join(root, 'run-default');
  const defaultTasks = queueFixture(root, 'default');
  const defaultSpec = join(root, 'default.json');
  writeFileSync(defaultSpec, JSON.stringify({ tasks: [
    pacedTask(fixture, defaultTasks.workspace, defaultTasks.results, 'auto-1', 150),
    pacedTask(fixture, defaultTasks.workspace, defaultTasks.results, 'auto-2', 150),
  ] }), 'utf8');
  const handshake = JSON.parse(runNode(SUPERVISOR, [
    'start', '--spec', defaultSpec, '--run-dir', defaultRun,
  ], env));
  assert.equal(handshake.maxConcurrency, 2);
  assert.equal(handshake.tasks, 2);
  assert.equal(handshake.queuedStallMs, 120000);
  runNode(SUPERVISOR, ['close', '--run', defaultRun, '--wait'], env);

  // S2: every enqueued task reports started-or-queued, its position, and the
  // live active/max counts, in text and in JSON.
  const runDir = join(root, 'run-limited');
  const tasks = queueFixture(root, 'limited');
  const limitedSpec = join(root, 'limited.json');
  writeFileSync(limitedSpec, JSON.stringify({ tasks: [
    pacedTask(fixture, tasks.workspace, tasks.results, 'runner', 2_000),
  ] }), 'utf8');
  const limited = JSON.parse(runNode(SUPERVISOR, [
    'start', '--spec', limitedSpec, '--run-dir', runDir, '--max-concurrency', '1',
  ], env));
  assert.equal(limited.maxConcurrency, 1);
  // Wait until the worker is provably live and draining before queueing, so the
  // positions below describe a real running slot rather than a startup race.
  await waitForFileChange(runDir, () => {
    const manifest = JSON.parse(readFileSync(join(runDir, 'manifest.json'), 'utf8'));
    return manifest.tasks.runner?.status === 'running' ? manifest : null;
  }, 15_000);

  const extraSpec = join(root, 'extra.json');
  writeFileSync(extraSpec, JSON.stringify({ tasks: [
    pacedTask(fixture, tasks.workspace, tasks.results, 'wait-1', 10),
    pacedTask(fixture, tasks.workspace, tasks.results, 'wait-2', 10),
  ] }), 'utf8');
  const enqueueText = runNode(SUPERVISOR, ['enqueue', '--run', runDir, '--spec', extraSpec], env);
  assert.match(enqueueText, /Enqueued 2 task\(s\): wait-1, wait-2/);
  assert.match(enqueueText, /wait-1: queued at position 1 of 2/);
  assert.match(enqueueText, /wait-2: queued at position 2 of 2/);
  assert.match(enqueueText, /waiting for a concurrency slot \(1\/1 active\)/);

  const thirdSpec = join(root, 'third.json');
  writeFileSync(thirdSpec, JSON.stringify({ tasks: [
    pacedTask(fixture, tasks.workspace, tasks.results, 'wait-3', 10),
  ] }), 'utf8');
  const enqueued = JSON.parse(runNode(SUPERVISOR, [
    'enqueue', '--run', runDir, '--spec', thirdSpec, '--json',
  ], env));
  assert.equal(enqueued.enqueued, true);
  assert.equal(enqueued.active, 1);
  assert.equal(enqueued.maxConcurrency, 1);
  assert.equal(enqueued.queued, 3);
  assert.equal(enqueued.tasks[0].status, 'queued');
  assert.equal(enqueued.tasks[0].position, 3);
  assert.equal(enqueued.tasks[0].queuedTotal, 3);
  assert.equal(enqueued.tasks[0].reason, 'awaiting_slot');
  assert.equal(enqueued.tasks[0].stalled, false);

  // `add` reports held tasks per task as well; they never start on `add`.
  const heldSpec = join(root, 'held.json');
  writeFileSync(heldSpec, JSON.stringify({ tasks: [
    pacedTask(fixture, tasks.workspace, tasks.results, 'hold-1', 10),
  ] }), 'utf8');
  const addText = runNode(SUPERVISOR, ['add', '--run', runDir, '--spec', heldSpec], env);
  assert.match(addText, /hold-1: held — not queued until enqueue --task hold-1 \(1\/1 active\)/);

  // S5 prelude + "status shows the queue reason per queued task".
  const statusText = runNode(SUPERVISOR, ['status', '--run', runDir], env);
  assert.match(statusText, /QUEUE active=1\/1\s+queued=3\s+stall-after=2m 0s/);
  assert.match(statusText, /wait-1\s+position 1 of 3/);
  assert.match(statusText, /wait-2\s+position 2 of 3/);
  assert.match(statusText, /awaiting_slot: waiting for a concurrency slot \(1\/1 active\)/);

  const statusJson = JSON.parse(runNode(SUPERVISOR, ['status', '--run', runDir, '--json'], env));
  assert.equal(statusJson.active, 1);
  assert.equal(statusJson.queue.maxConcurrency, 1);
  assert.deepEqual(statusJson.queue.queued.map((entry) => entry.id), ['wait-1', 'wait-2', 'wait-3']);
  assert.equal(statusJson.queue.queued[0].position, 1);
  assert.equal(statusJson.tasks['wait-2'].queue.reason, 'awaiting_slot');
  assert.equal(statusJson.tasks['wait-2'].queue.stalled, false);
  assert.equal(statusJson.tasks['hold-1'].status, 'held');

  // `close --abort-queued` clears queued and held tasks; the running task is
  // left to finish, and aborted tasks never launched.
  const closed = JSON.parse(runNode(SUPERVISOR, [
    'close', '--run', runDir, '--abort-queued', '--json',
  ], env));
  assert.deepEqual(closed.aborted.sort(), ['hold-1', 'wait-1', 'wait-2', 'wait-3']);

  const completed = await waitForFileChange(runDir, () => {
    const manifest = JSON.parse(readFileSync(join(runDir, 'manifest.json'), 'utf8'));
    return manifest.status === 'completed' ? manifest : null;
  }, 15_000);
  assert.equal(completed.tasks['wait-1'].status, 'aborted');
  assert.equal(completed.tasks['hold-1'].status, 'aborted');
  assert.equal(completed.tasks.runner.status, 'completed');
  assert.equal(existsSync(taskMarker(tasks.results, 'wait-1')), false);
  assert.equal(existsSync(taskMarker(tasks.results, 'wait-3')), false);
  assert.equal(existsSync(taskMarker(tasks.results, 'hold-1')), false);
  assert.equal(existsSync(taskMarker(tasks.results, 'runner')), true);
  const aborted = readJournal(runDir).filter((event) => event.to === 'aborted');
  assert.ok(aborted
    .filter((event) => event.taskId !== 'hold-1')
    .every((event) => event.cancellationRequested === true));
});

test('cancel aborts a queued task before it can start and wakes a watcher', async () => {
  const root = mkdtempSync(join(tmpdir(), 'delegate-cancel-queued-test-'));
  const fixture = writePacedFixture(root);
  const { workspace, results } = queueFixture(root, 'cancel');
  const runDir = join(root, 'run');
  const config = join(root, 'config');
  mkdirSync(config, { recursive: true });
  const env = { ...process.env, XDG_CONFIG_HOME: config };

  const specPath = join(root, 'tasks.json');
  writeFileSync(specPath, JSON.stringify({ tasks: [
    pacedTask(fixture, workspace, results, 'runner', 1_800),
    pacedTask(fixture, workspace, results, 'wait-1', 10),
  ] }), 'utf8');
  runNode(SUPERVISOR, ['start', '--spec', specPath, '--run-dir', runDir, '--max-concurrency', '1'], env);

  await waitForFileChange(runDir, () => {
    const manifest = JSON.parse(readFileSync(join(runDir, 'manifest.json'), 'utf8'));
    const runner = manifest.tasks.runner;
    const waiting = manifest.tasks['wait-1'];
    return runner?.status === 'running' && waiting?.status === 'queued' ? manifest : null;
  }, 15_000);

  const cancelText = runNode(SUPERVISOR, ['cancel', '--run', runDir, '--task', 'wait-1'], env);
  assert.match(cancelText, /Cancelled task wait-1 \(queued -> aborted\); it will never start\./);

  const statusJson = JSON.parse(runNode(SUPERVISOR, ['status', '--run', runDir, '--json'], env));
  assert.equal(statusJson.tasks['wait-1'].status, 'aborted');
  assert.equal(statusJson.queue.queued.length, 0);

  const abortedEvent = readJournal(runDir).find((event) => event.taskId === 'wait-1' && event.to === 'aborted');
  assert.ok(abortedEvent, 'queued cancel journals an aborted transition');
  assert.equal(abortedEvent.from, 'queued');
  assert.equal(abortedEvent.cancellationRequested, true);
  assert.match(abortedEvent.error, /never started/);

  const watched = JSON.parse(runNode(WATCH_ONCE, [
    '--run', runDir, '--since', String(abortedEvent.seq - 1),
  ], env));
  assert.equal(watched.taskId, 'wait-1');
  assert.equal(watched.to, 'aborted');

  const repeatError = runNodeThrows(SUPERVISOR, ['cancel', '--run', runDir, '--task', 'wait-1'], env);
  assert.match(repeatError, /already aborted/);
  const missingError = runNodeThrows(SUPERVISOR, ['cancel', '--run', runDir, '--task', 'no-such-task'], env);
  assert.match(missingError, /task not found/);

  runNode(SUPERVISOR, ['close', '--run', runDir, '--wait'], env);
  assert.equal(existsSync(taskMarker(results, 'wait-1')), false);
  assert.equal(existsSync(taskMarker(results, 'runner')), true);
});

test('cancel signals a running task, stops its daemon session by id, and records cancelled', async () => {
  const root = mkdtempSync(join(tmpdir(), 'delegate-cancel-running-test-'));
  const workspace = join(root, 'worktree');
  const runDir = join(root, 'run');
  const outDir = join(root, 'task_out');
  const binDir = join(root, 'bin');
  const config = join(root, 'config');
  mkdirSync(workspace, { recursive: true });
  mkdirSync(outDir, { recursive: true });
  mkdirSync(binDir, { recursive: true });
  mkdirSync(config, { recursive: true });
  const briefFile = join(root, 'brief.txt');
  writeFileSync(briefFile, 'Cancel brief', 'utf8');
  const env = { ...process.env, XDG_CONFIG_HOME: config };

  // The mock publishes its session id and then stays alive until signalled;
  // `session stop <id>` is recorded so the stop can be proven by session id.
  const stopLog = join(root, 'session-stop.log');
  const mockSanad = join(root, 'mock_sanad.mjs');
  writeFileSync(mockSanad, `
    import {appendFileSync, mkdirSync} from 'node:fs';
    import {dirname, resolve} from 'node:path';
    const NL = String.fromCharCode(10);
    const args = process.argv.slice(2);
    if (args[0] === 'session' && args[1] === 'stop') {
      appendFileSync(${JSON.stringify(stopLog)}, args[2] + NL);
      process.exit(0);
    }
    let outDir = '';
    for (let i = 0; i < args.length; i++) {
      if (args[i] === '--out-dir' || args[i] === '-o') outDir = args[i + 1];
    }
    const eventsPath = resolve(outDir, 'events.jsonl');
    mkdirSync(dirname(eventsPath), {recursive:true});
    appendFileSync(eventsPath, JSON.stringify({
      timestamp: new Date().toISOString(),
      type: 'running',
      session_id: 'ses_cancel_1',
      data: {},
    }) + NL);
    setInterval(() => {}, 1000);
  `, 'utf8');
  const sanadCommand = createSanadWrapper(binDir, mockSanad);

  const specPath = join(root, 'tasks.json');
  writeFileSync(specPath, JSON.stringify({ tasks: [{
    id: 'sanad-cancel',
    implementer: 'sanad',
    workspace,
    command: sanadCommand,
    args: [
      'run',
      '--brief-file', briefFile,
      '--workspace', 'ws_logical',
      '--out-dir', outDir,
      '--events',
    ],
  }] }), 'utf8');
  runNode(SUPERVISOR, ['start', '--spec', specPath, '--run-dir', runDir, '--max-concurrency', '1'], env);

  const running = await waitForFileChange(runDir, () => {
    const manifest = JSON.parse(readFileSync(join(runDir, 'manifest.json'), 'utf8'));
    const task = manifest.tasks['sanad-cancel'];
    return task.status === 'running' && task.sessionId === 'ses_cancel_1' ? manifest : null;
  }, 15_000);
  assert.equal(running.active, 1);

  const cancelled = JSON.parse(runNode(SUPERVISOR, [
    'cancel', '--run', runDir, '--task', 'sanad-cancel', '--json',
  ], env));
  assert.equal(cancelled.from, 'running');
  assert.equal(cancelled.status, 'cancelling');
  assert.equal(cancelled.signalled, 'SIGTERM');
  assert.equal(cancelled.sessionId, 'ses_cancel_1');
  assert.equal(cancelled.sessionStop.requested, true);

  const terminal = await waitForFileChange(runDir, () => {
    const manifest = JSON.parse(readFileSync(join(runDir, 'manifest.json'), 'utf8'));
    const task = manifest.tasks['sanad-cancel'];
    return task.status === 'cancelled' ? manifest : null;
  }, 15_000);
  assert.equal(terminal.tasks['sanad-cancel'].cause, 'cancelled');
  assert.equal(terminal.active, 0);

  await waitForFileChange(root, () => (
    existsSync(stopLog) && readFileSync(stopLog, 'utf8').includes('ses_cancel_1') ? true : null
  ), 15_000);

  const journal = readJournal(runDir);
  assert.ok(journal.some((event) => event.kind === 'cancel_requested' && event.signalled === 'SIGTERM'));
  assert.ok(journal.some((event) => event.taskId === 'sanad-cancel' && event.to === 'cancelled'));

  runNode(SUPERVISOR, ['close', '--run', runDir, '--wait'], env);
});

test('set-concurrency raises live slots and lowering never kills running tasks', async () => {
  const root = mkdtempSync(join(tmpdir(), 'delegate-concurrency-test-'));
  const fixture = writePacedFixture(root);
  const { workspace, results } = queueFixture(root, 'concurrency');
  const runDir = join(root, 'run');
  const config = join(root, 'config');
  mkdirSync(config, { recursive: true });
  const env = { ...process.env, XDG_CONFIG_HOME: config };

  const specPath = join(root, 'tasks.json');
  writeFileSync(specPath, JSON.stringify({ tasks: [
    pacedTask(fixture, workspace, results, 'runner', 2_000),
    pacedTask(fixture, workspace, results, 'slot-1', 1_200),
    pacedTask(fixture, workspace, results, 'slot-2', 1_200),
  ] }), 'utf8');
  runNode(SUPERVISOR, ['start', '--spec', specPath, '--run-dir', runDir, '--max-concurrency', '1'], env);

  await waitForFileChange(runDir, () => {
    const manifest = JSON.parse(readFileSync(join(runDir, 'manifest.json'), 'utf8'));
    const runner = manifest.tasks.runner;
    const waiting = manifest.tasks['slot-1'];
    return runner?.status === 'running' && waiting?.status === 'queued' ? manifest : null;
  }, 15_000);

  const raised = JSON.parse(runNode(SUPERVISOR, [
    'set-concurrency', '--run', runDir, '--max', '3', '--json',
  ], env));
  assert.equal(raised.previous, 1);
  assert.equal(raised.maxConcurrency, 3);
  assert.equal(raised.active, 3);
  assert.equal(raised.queued, 0);
  assert.deepEqual(raised.started.sort(), ['slot-1', 'slot-2']);
  assert.ok(raised.tasks.every((task) => task.status === 'started'));

  // Lowering the ceiling applies to future fills only: nothing running is
  // signalled or aborted, and the counts stay honest.
  const lowered = JSON.parse(runNode(SUPERVISOR, [
    'set-concurrency', '--run', runDir, '--max', '2', '--json',
  ], env));
  assert.equal(lowered.previous, 3);
  assert.equal(lowered.maxConcurrency, 2);
  assert.equal(lowered.active, 3);
  assert.deepEqual(lowered.started, []);

  const statusJson = JSON.parse(runNode(SUPERVISOR, ['status', '--run', runDir, '--json'], env));
  assert.equal(statusJson.maxConcurrency, 2);
  assert.equal(statusJson.active, 3);
  for (const id of ['runner', 'slot-1', 'slot-2']) {
    assert.equal(statusJson.tasks[id].status, 'running');
  }

  const invalid = runNodeThrows(SUPERVISOR, ['set-concurrency', '--run', runDir, '--max', '0'], env);
  assert.match(invalid, /--max must be a positive integer/);

  runNode(SUPERVISOR, ['close', '--run', runDir, '--wait'], env);
  const finalManifest = JSON.parse(readFileSync(join(runDir, 'manifest.json'), 'utf8'));
  assert.equal(finalManifest.status, 'completed');
  for (const id of ['runner', 'slot-1', 'slot-2']) {
    assert.equal(finalManifest.tasks[id].status, 'completed');
  }
});

test('a task queued past the stall threshold journals one queued_stall visible in watch-once and status', async () => {
  const root = mkdtempSync(join(tmpdir(), 'delegate-queued-stall-test-'));
  const fixture = writePacedFixture(root);
  const { workspace, results } = queueFixture(root, 'stall');
  const runDir = join(root, 'run');
  const config = join(root, 'config');
  mkdirSync(config, { recursive: true });
  const env = { ...process.env, XDG_CONFIG_HOME: config };

  const specPath = join(root, 'tasks.json');
  writeFileSync(specPath, JSON.stringify({ tasks: [
    pacedTask(fixture, workspace, results, 'runner', 2_500),
    pacedTask(fixture, workspace, results, 'wait-1', 10),
  ] }), 'utf8');
  const started = JSON.parse(runNode(SUPERVISOR, [
    'start', '--spec', specPath, '--run-dir', runDir,
    '--max-concurrency', '1', '--queued-stall-ms', '400',
  ], env));
  assert.equal(started.queuedStallMs, 400);

  const stallEvent = await waitForFileChange(runDir, () => (
    readJournal(runDir).find((event) => event.to === 'queued_stall') ?? null
  ), 15_000);
  assert.equal(stallEvent.taskId, 'wait-1');
  assert.equal(stallEvent.kind, 'queued_stall');
  assert.equal(stallEvent.active, 1);
  assert.equal(stallEvent.maxConcurrency, 1);
  assert.equal(stallEvent.position, 1);
  assert.equal(stallEvent.reason, 'awaiting_slot');
  assert.ok(stallEvent.queuedForMs >= 400, `stall age ${stallEvent.queuedForMs}ms`);

  const watched = JSON.parse(runNode(WATCH_ONCE, [
    '--run', runDir, '--since', String(stallEvent.seq - 1),
  ], env));
  assert.equal(watched.seq, stallEvent.seq);
  assert.equal(watched.taskId, 'wait-1');
  assert.equal(watched.to, 'queued_stall');

  const statusText = runNode(SUPERVISOR, ['status', '--run', runDir], env);
  assert.match(statusText, /QUEUED_STALL/);
  assert.match(statusText, /stall-after=400ms/);
  const statusJson = JSON.parse(runNode(SUPERVISOR, ['status', '--run', runDir, '--json'], env));
  assert.equal(statusJson.tasks['wait-1'].queue.stalled, true);
  assert.equal(statusJson.queue.queued[0].stalled, true);
  assert.equal(statusJson.queuedStallMs, 400);

  runNode(SUPERVISOR, ['close', '--run', runDir, '--wait'], env);
  const finalManifest = JSON.parse(readFileSync(join(runDir, 'manifest.json'), 'utf8'));
  assert.equal(finalManifest.status, 'completed');
  assert.equal(finalManifest.tasks['wait-1'].status, 'completed');
  assert.equal(finalManifest.tasks['wait-1'].queueStall, null);
  // One notice per queue episode, never a stream of duplicates.
  assert.equal(readJournal(runDir).filter((event) => event.to === 'queued_stall').length, 1);
});

// ---------------------------------------------------------------------------
// Coordinator-facing supervisor gaps (W1-W8).
//
// Every test here uses fake processes (a scripted `sanad` mock) and compressed
// time (millisecond thresholds, so a 15-minute silence or a 15-second launch
// verification is exercised in milliseconds) instead of sleeping for real.
// ---------------------------------------------------------------------------

// A scripted `sanad` CLI: it answers `run`, `session stop`, and
// `session steer`, and records every invocation so a test can assert the exact
// argv the supervisor produced. Behaviour is driven by MOCK_* environment
// variables that the supervisor passes through to the task process.
function writeSanadMock(root) {
  const scriptPath = join(root, 'mock_sanad.mjs');
  writeFileSync(scriptPath, `
    import {appendFileSync, mkdirSync, readFileSync, writeFileSync} from 'node:fs';
    const args = process.argv.slice(2);
    const log = process.env.MOCK_LOG;
    const record = (entry) => { if (log) appendFileSync(log, JSON.stringify(entry) + '\\n'); };
    const readFlag = (flag) => { const i = args.indexOf(flag); return i === -1 ? null : args[i + 1]; };

    if (args[0] === 'session' && args[1] === 'steer') {
      const messageFile = readFlag('--message-file');
      record({
        kind: 'steer',
        argv: args,
        session: readFlag('--session'),
        gateway: readFlag('--gateway-url'),
        home: readFlag('--home'),
        body: messageFile ? readFileSync(messageFile, 'utf8') : null,
      });
      if (args.includes('--json')) process.stdout.write(JSON.stringify({request_id: 'req_cli_steer_1'}) + '\\n');
      process.exit(Number(process.env.MOCK_STEER_EXIT || 0));
    }
    if (args[0] === 'session' && args[1] === 'stop') {
      record({kind: 'stop', argv: args});
      process.exit(0);
    }

    const outDir = readFlag('--out-dir');
    const brief = readFlag('--brief-file');
    record({
      kind: 'run',
      argv: args,
      brief,
      briefBody: brief ? readFileSync(brief, 'utf8') : null,
    });
    mkdirSync(outDir, {recursive: true});
    const timeline = outDir + '/events.jsonl';
    const emit = (entry) => appendFileSync(timeline, JSON.stringify({timestamp: new Date().toISOString(), ...entry}) + '\\n');

    const sessionId = process.env.MOCK_SESSION === '' ? null : (process.env.MOCK_SESSION || 'ses_mock_1');
    emit({type: 'running', session_id: sessionId});
    emit({type: 'tool_use', part: {type: 'tool', tool: 'read', state: {status: 'completed', input: {filePath: 'a'}}}});

    const progressAt = Number(process.env.MOCK_PROGRESS_AT || 0);
    if (progressAt > 0) {
      setTimeout(() => emit({type: 'tool_use', part: {type: 'tool', tool: 'edit', state: {status: 'completed', input: {filePath: 'b'}}}}), progressAt);
    }
    const progressAgain = Number(process.env.MOCK_PROGRESS_AGAIN_AT || 0);
    if (progressAgain > 0) {
      setTimeout(() => emit({type: 'tool_use', part: {type: 'tool', tool: 'edit', state: {status: 'completed', input: {filePath: 'c'}}}}), progressAgain);
    }

    // A brief whose whole content is a number is a compressed-time duration for
    // this task, so one run can hold tasks with different lengths.
    const briefText = brief ? readFileSync(brief, 'utf8').trim() : '';
    const runMs = /^\\d+$/.test(briefText) ? Number(briefText) : Number(process.env.MOCK_RUN_MS || 400);
    setTimeout(() => {
      writeFileSync(outDir + '/result.json', JSON.stringify({
        status: process.env.MOCK_STATUS || 'completed',
        exit_code: 0,
        branch: process.env.MOCK_BRANCH || null,
        head_sha: process.env.MOCK_SHA || null,
        pr_url: process.env.MOCK_PR || null,
        text: process.env.MOCK_TEXT || 'Mock summary line.',
      }));
      emit({type: 'completed'});
      process.exit(0);
    }, runMs);
  `, 'utf8');
  return createSanadWrapper(root, scriptPath);
}

function sanadTask(root, id, overrides = {}) {
  const outDir = join(root, `out-${id}`);
  return {
    id,
    implementer: 'sanad',
    workspace: root,
    command: overrides.command || writeSanadMock(root),
    args: [
      'run',
      '--brief-file', overrides.briefFile || join(root, 'brief.md'),
      '--workspace', 'ws-brief',
      '--execution-root', root,
      '--out-dir', outDir,
      '--events',
    ],
    ...(overrides.task || {}),
  };
}

function writeSpec(root, tasks, name = 'tasks.json') {
  const specPath = join(root, name);
  writeFileSync(specPath, JSON.stringify({ tasks }), 'utf8');
  return specPath;
}

function writeBrief(root, name, content) {
  const path = join(root, name);
  writeFileSync(path, content, 'utf8');
  return path;
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

function readJsonFile(path) {
  return JSON.parse(readFileSync(path, 'utf8'));
}

function waitForCondition(predicate, timeoutMs = 10_000, intervalMs = 50) {
  return new Promise((resolvePromise, reject) => {
    const deadline = Date.now() + timeoutMs;
    const check = () => {
      try {
        const value = predicate();
        if (value) {
          resolvePromise(value);
          return;
        }
      } catch {
        // Keep polling until the deadline; a partially written file is transient.
      }
      if (Date.now() >= deadline) {
        reject(new Error(`condition not met within ${timeoutMs}ms`));
        return;
      }
      setTimeout(check, intervalMs);
    };
    check();
  });
}

test('watch replays actionable events across a restart without loss or duplication', async () => {
  const root = realpathSync(mkdtempSync(join(tmpdir(), 'delegate-watch-replay-test-')));
  const runDir = join(root, 'run');
  const cursorPath = join(root, 'cursor.json');
  const logPath = join(root, 'mock.log');
  const env = {
    ...process.env,
    MOCK_LOG: logPath,
    MOCK_RUN_MS: '400',
  };
  // Staggered durations: the first task settles long before the second, so each
  // watcher batch is deterministic.
  const tasks = [
    sanadTask(root, 'first', { briefFile: writeBrief(root, 'brief.md', '600') }),
    sanadTask(root, 'second', { briefFile: writeBrief(root, 'brief2.md', '3000') }),
  ];
  const specPath = writeSpec(root, tasks);

  runNode(SUPERVISOR, ['start', '--spec', specPath, '--run-dir', runDir, '--max-concurrency', '2'], env);

  // One completion is handled, then the watcher disappears (the coordinator is
  // re-invoked per batch, so a restart is the normal case).
  const firstEvent = JSON.parse(runNode(SUPERVISOR, [
    'watch', '--run', runDir, '--cursor', cursorPath, '--once', '--json', '--timeout-sec', '10',
  ], env));
  assert.equal(firstEvent.taskId, 'first');
  assert.equal(firstEvent.to, 'completed');
  assert.equal(firstEvent.actionable, true);
  assert.equal(firstEvent.result.status, 'completed');
  assert.equal(firstEvent.result.path, join(root, 'out-first', 'result.json'));
  assert.ok(firstEvent.elapsedMs >= 0);

  // The cursor is durable state, not a process-local counter.
  const cursorAfterFirst = readJsonFile(cursorPath);
  assert.equal(cursorAfterFirst.version, 'delegate-watch-cursor.v1');
  assert.ok(cursorAfterFirst.runs[runDir].seq >= firstEvent.seq);

  const secondEvent = JSON.parse(runNode(SUPERVISOR, [
    'watch', '--run', runDir, '--cursor', cursorPath, '--once', '--json', '--timeout-sec', '10',
  ], env));
  assert.equal(secondEvent.taskId, 'second');
  assert.equal(secondEvent.to, 'completed');
  assert.notEqual(secondEvent.seq, firstEvent.seq);

  // Nothing is replayed twice: the same cursor, now that both tasks are done.
  runNode(SUPERVISOR, ['close', '--run', runDir, '--wait'], env);
  const replay = execFileSync(process.execPath, [
    SUPERVISOR, 'watch', '--run', runDir, '--cursor', cursorPath, '--once', '--timeout-sec', '2',
  ], { encoding: 'utf8', env, stdio: ['ignore', 'pipe', 'pipe'] });
  assert.equal(replay.trim(), '');

  // Nothing is lost either: a fresh cursor (a watcher that never ran before)
  // replays every actionable event of the whole run.
  const freshCursor = join(root, 'cursor-fresh.json');
  const batch = runNode(SUPERVISOR, [
    'watch', '--run', runDir, '--cursor', freshCursor, '--once', '--json', '--timeout-sec', '5',
  ], env).trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
  assert.deepEqual(batch.map((entry) => entry.taskId).sort(), ['first', 'second']);
  assert.ok(batch.every((entry) => entry.to === 'completed'));
});

test('the watch cursor is written atomically and never observed half-written', async () => {
  const root = realpathSync(mkdtempSync(join(tmpdir(), 'delegate-watch-cursor-test-')));
  const runDir = join(root, 'run');
  const cursorPath = join(root, 'cursor.json');
  const env = {
    ...process.env,
    MOCK_LOG: join(root, 'mock.log'),
    MOCK_RUN_MS: '1200',
  };
  const specPath = writeSpec(root, [sanadTask(root, 'one'), sanadTask(root, 'two')]);
  writeBrief(root, 'brief.md', 'brief');
  runNode(SUPERVISOR, ['start', '--spec', specPath, '--run-dir', runDir, '--max-concurrency', '2'], env);

  const watcher = spawn(process.execPath, [
    SUPERVISOR, 'watch', '--run', runDir, '--cursor', cursorPath, '--timeout-sec', '6',
  ], { env, stdio: ['ignore', 'pipe', 'pipe'] });
  let observed = '';
  watcher.stdout.setEncoding('utf8');
  watcher.stdout.on('data', (chunk) => { observed += chunk; });

  // Read the cursor repeatedly while the watcher advances it: a temp-file +
  // rename write can never expose a partial document.
  const reads = [];
  const deadline = Date.now() + 2_500;
  while (Date.now() < deadline) {
    if (existsSync(cursorPath)) reads.push(readJsonFile(cursorPath));
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 25));
  }
  assert.ok(reads.length > 5, 'expected the cursor to be readable while watching');
  for (const cursor of reads) {
    assert.equal(cursor.version, 'delegate-watch-cursor.v1');
    assert.ok(Number.isInteger(cursor.runs[runDir].seq));
  }
  watcher.kill('SIGTERM');
  await collectProcess(watcher);
  assert.match(observed, /one/);

  // The atomic write leaves no temporary sibling behind.
  const leftovers = readdirSync(root).filter((entry) => entry.startsWith('cursor.json.') && entry.endsWith('.tmp'));
  assert.deepEqual(leftovers, []);
  const finalCursor = readJsonFile(cursorPath);
  assert.ok(finalCursor.runs[runDir].seq >= 1);
});

test('progress_stall is journaled once per stall and progress_resumed clears it', async () => {
  const root = realpathSync(mkdtempSync(join(tmpdir(), 'delegate-progress-stall-test-')));
  const runDir = join(root, 'run');
  const env = {
    ...process.env,
    MOCK_LOG: join(root, 'mock.log'),
    // Compressed time: silence past 400ms, one progress burst at 900ms, then a
    // second silent stretch before the task finishes.
    MOCK_PROGRESS_AT: '900',
    MOCK_RUN_MS: '1800',
  };
  writeBrief(root, 'brief.md', 'brief');
  const specPath = writeSpec(root, [
    sanadTask(root, 'silent', { task: { progressStallMs: 400 } }),
  ]);
  runNode(SUPERVISOR, ['start', '--spec', specPath, '--run-dir', runDir, '--max-concurrency', '1'], env);

  await waitForCondition(
    () => readJournal(runDir).some((event) => event.kind === 'progress_stall'),
    8_000,
  );
  const midStatus = JSON.parse(runNode(SUPERVISOR, ['status', '--run', runDir, '--json'], env));
  assert.equal(midStatus.tasks.silent.progress.stalled, true);
  assert.equal(midStatus.tasks.silent.progress.thresholdMs, 400);
  assert.ok(midStatus.tasks.silent.progressStall !== null);

  await waitForCondition(
    () => readJournal(runDir).some((event) => event.to === 'completed'),
    10_000,
  );

  const journal = readJournal(runDir);
  const stalls = journal.filter((event) => event.kind === 'progress_stall');
  const resumes = journal.filter((event) => event.kind === 'progress_resumed');
  // One stall before the progress burst, one after: never a stream of repeats.
  assert.equal(stalls.length, 2);
  assert.ok(resumes.length >= 1);
  assert.equal(stalls[0].thresholdMs, 400);
  assert.ok(stalls[0].silentForMs >= 400);
  assert.equal(stalls[1].taskId, 'silent');

  // A stall notice is actionable for a coordinator; the resume is not.
  const watchBatch = runNode(SUPERVISOR, [
    'watch', '--run', runDir, '--cursor', join(root, 'cursor.json'), '--once', '--json', '--timeout-sec', '5',
  ], env).trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
  const watched = watchBatch[0];
  assert.equal(watched.to, 'progress_stall');
  assert.equal(watched.actionable, true);
  const stalledKinds = journal.filter((event) => ['progress_stall', 'progress_resumed'].includes(event.kind))
    .map((event) => event.kind);
  assert.equal(stalledKinds[0], 'progress_stall');
  assert.equal(stalledKinds[1], 'progress_resumed');
});

test('a task left running by a dead supervisor is repaired to failed/worker_lost', async () => {
  const root = realpathSync(mkdtempSync(join(tmpdir(), 'delegate-worker-lost-test-')));
  const runDir = join(root, 'run');
  const env = {
    ...process.env,
    MOCK_LOG: join(root, 'mock.log'),
    MOCK_RUN_MS: '60000',
  };
  writeBrief(root, 'brief.md', 'brief');
  const specPath = writeSpec(root, [sanadTask(root, 'stuck')]);
  const started = JSON.parse(runNode(SUPERVISOR, [
    'start', '--spec', specPath, '--run-dir', runDir, '--max-concurrency', '1',
  ], env));

  const manifestPath = join(runDir, 'manifest.json');
  const running = await waitForCondition(() => {
    const manifest = readJsonFile(manifestPath);
    return manifest.tasks.stuck.status === 'running' ? manifest : null;
  });
  const taskPid = running.tasks.stuck.pid;
  assert.ok(Number.isInteger(taskPid));

  // The supervisor dies while its task process keeps running. A live orphan is
  // still running, so it is reported as orphaned rather than failed - and the
  // coordinator is woken once to decide what to do with it.
  process.kill(started.supervisorPid, 'SIGKILL');
  try {
    const orphaned = JSON.parse(runNode(SUPERVISOR, ['status', '--run', runDir, '--json'], env));
    assert.equal(orphaned.status, 'stale');
    assert.equal(orphaned.tasks.stuck.status, 'running');
    assert.equal(orphaned.tasks.stuck.orphaned, true);
    assert.equal(orphaned.tasks.stuck.orphanPid, taskPid);
    const orphanNotice = readJournal(runDir).find((event) => event.kind === 'worker_orphaned');
    assert.ok(orphanNotice, 'the orphan must be journaled once');
    assert.equal(orphanNotice.orphanPid, taskPid);
    const orphanWatch = JSON.parse(runNode(SUPERVISOR, [
      'watch', '--run', runDir, '--cursor', join(root, 'cursor-orphan.json'), '--once', '--json', '--timeout-sec', '5',
    ], env).trim().split('\n').filter(Boolean)[0]);
    assert.equal(orphanWatch.kind, 'worker_orphaned');
    assert.equal(orphanWatch.actionable, true);
    // A second read must not repeat the notice.
    runNode(SUPERVISOR, ['status', '--run', runDir, '--json'], env);
    assert.equal(readJournal(runDir).filter((event) => event.kind === 'worker_orphaned').length, 1);

    // Once the process is gone with no terminal artifact, the task is a lost
    // worker: it is never left running forever.
    process.kill(taskPid, 'SIGKILL');
    await waitForCondition(() => !processIsAlive(taskPid), 5_000);
    const status = JSON.parse(runNode(SUPERVISOR, ['status', '--run', runDir, '--json'], env));
    assert.equal(status.status, 'stale');
    assert.equal(status.tasks.stuck.status, 'failed');
    assert.equal(status.tasks.stuck.cause, 'worker_lost');
    assert.equal(status.tasks.stuck.recovered, true);
    assert.equal(status.active, 0);
    const repair = readJournal(runDir).find((event) => event.kind === 'worker_lost');
    assert.ok(repair, 'worker_lost must be journaled');
    assert.equal(repair.to, 'failed');
    assert.equal(repair.from, 'running');

    // A fresh cursor replays the whole story of the run: the orphan notice and
    // then the lost-worker failure, in order.
    const repairBatch = runNode(SUPERVISOR, [
      'watch', '--run', runDir, '--cursor', join(root, 'cursor.json'), '--once', '--json', '--timeout-sec', '5',
    ], env).trim().split('\n').filter(Boolean).map((line) => JSON.parse(line));
    assert.deepEqual(repairBatch.map((entry) => entry.kind), ['worker_orphaned', 'worker_lost']);
    assert.ok(repairBatch.every((entry) => entry.actionable === true && entry.taskId === 'stuck'));
    const watched = repairBatch[1];
    assert.equal(watched.to, 'failed');

    // A completion that lands after the supervisor died is still adopted: a
    // missed completion must never stay missed.
    writeFileSync(join(root, 'out-stuck', 'result.json'), JSON.stringify({
      status: 'completed',
      text: 'finished after the supervisor died',
    }), 'utf8');
    const repaired = JSON.parse(runNode(SUPERVISOR, ['status', '--run', runDir, '--json'], env));
    assert.equal(repaired.tasks.stuck.status, 'completed');
    assert.equal(repaired.tasks.stuck.cause, 'result_recorded_after_exit');
    assert.equal(readJournal(runDir).filter((event) => event.kind === 'recovered').length, 1);
  } finally {
    try { process.kill(taskPid, 'SIGKILL'); } catch {}
  }
});

test('status --brief summarises several runs with queue, progress, and result facts', async () => {
  const root = realpathSync(mkdtempSync(join(tmpdir(), 'delegate-brief-test-')));
  const runA = join(root, 'run-a');
  const runB = join(root, 'run-b');
  const env = {
    ...process.env,
    MOCK_LOG: join(root, 'mock.log'),
    MOCK_RUN_MS: '400',
    MOCK_BRANCH: 'fix/supervisor-queue-controls',
    MOCK_SHA: '0e0c7fb0deadbeef',
    MOCK_PR: 'https://example.test/pr/267',
    MOCK_TEXT: 'W7 rich completion line\nsecond line',
  };
  writeBrief(root, 'brief.md', 'brief');

  // Run A: one slot, so the second task is honestly queued behind it.
  const slowEnv = { ...env, MOCK_RUN_MS: '1500' };
  const specA = writeSpec(root, [
    sanadTask(root, 'active'),
    sanadTask(root, 'waiting', { briefFile: writeBrief(root, 'brief-waiting.md', 'waiting brief') }),
  ], 'tasks-a.json');
  runNode(SUPERVISOR, ['start', '--spec', specA, '--run-dir', runA, '--max-concurrency', '1'], slowEnv);

  // Run B: finished, with result facts.
  const specB = writeSpec(root, [sanadTask(root, 'done')], 'tasks-b.json');
  runNode(SUPERVISOR, ['start', '--spec', specB, '--run-dir', runB, '--max-concurrency', '1'], env);
  runNode(SUPERVISOR, ['close', '--run', runB, '--wait'], env);

  const brief = runNode(SUPERVISOR, ['status', '--run', runA, '--run', runB, '--brief'], env);
  assert.match(brief, new RegExp(`RUN ${runA.replace(/[/\\]/g, '.')}`));
  assert.match(brief, new RegExp(`RUN ${runB.replace(/[/\\]/g, '.')}`));
  assert.match(brief, /active {2}running {2}elapsed /);
  assert.match(brief, /waiting {2}queued {2}elapsed .*queue #1\/1 awaiting_slot/);
  assert.match(brief, /done {2}completed .*result completed {2}pr https:\/\/example\.test\/pr\/267/);
  assert.match(brief, /sha 0e0c7fb0deadbeef/);
  assert.match(brief, /branch fix\/supervisor-queue-controls/);
  // Only the first line of the final summary is carried: the completion line
  // stays one line per task.
  assert.match(brief, /summary W7 rich completion line( {2}|$)/);

  const json = JSON.parse(runNode(SUPERVISOR, ['status', '--run', runA, '--run', runB, '--brief', '--json'], env));
  assert.equal(json.version, 'delegate-status-brief.v1');
  assert.equal(json.runs.length, 2);
  const runAView = json.runs.find((entry) => entry.runDir === runA);
  assert.equal(runAView.tasks.find((task) => task.id === 'waiting').queue.reason, 'awaiting_slot');
  const runBView = json.runs.find((entry) => entry.runDir === runB);
  assert.equal(runBView.tasks[0].resultStatus, 'completed');
  assert.equal(runBView.tasks[0].prUrl, 'https://example.test/pr/267');
  assert.equal(runBView.tasks[0].headSha, '0e0c7fb0deadbeef');

  // The default output is unchanged (verbose), so existing callers keep working.
  const verbose = runNode(SUPERVISOR, ['status', '--run', runB], env);
  assert.match(verbose, /TASK\tIMPLEMENTER\tSTATUS\tPID\tWORKSPACE/);
  runNode(SUPERVISOR, ['close', '--run', runA, '--abort-queued', '--wait'], slowEnv);
});

test('start and enqueue verify the observed launch and fail on a spawn error', async () => {
  const root = realpathSync(mkdtempSync(join(tmpdir(), 'delegate-verify-test-')));
  const runDir = join(root, 'run');
  const env = { ...process.env, MOCK_LOG: join(root, 'mock.log'), MOCK_RUN_MS: '400' };
  writeBrief(root, 'brief.md', 'brief');

  const ghost = {
    id: 'ghost',
    implementer: 'opencode',
    workspace: root,
    command: join(root, 'missing-binary'),
    args: ['--noop'],
    resultPath: join(root, 'out-ghost', 'result.json'),
    timelinePath: join(root, 'out-ghost', 'events.jsonl'),
    timelineFormat: 'jsonl',
  };
  const specPath = writeSpec(root, [ghost, sanadTask(root, 'real')]);
  const failure = runNodeThrows(SUPERVISOR, [
    'start', '--spec', specPath, '--run-dir', runDir, '--verify-sec', '5',
  ], env);
  assert.match(failure, /failed to spawn/);
  assert.match(failure, /ENOENT/);

  const verification = JSON.parse(runNode(SUPERVISOR, [
    'status', '--run', runDir, '--json',
  ], env));
  assert.equal(verification.tasks.ghost.status, 'failed');
  assert.equal(verification.tasks.ghost.cause, 'spawn_failed');
  assert.equal(verification.tasks.real.status, 'running');

  // A queued task is reported as queued with its reason, and that is a success:
  // the launch is not silently claimed.
  const queuedRun = join(root, 'run-queued');
  const queuedEnv = { ...env, MOCK_RUN_MS: '1500' };
  const queuedSpec = writeSpec(root, [
    sanadTask(root, 'slot'),
    sanadTask(root, 'behind', { briefFile: writeBrief(root, 'brief-behind.md', 'behind') }),
  ], 'tasks-queued.json');
  const started = JSON.parse(runNode(SUPERVISOR, [
    'start', '--spec', queuedSpec, '--run-dir', queuedRun, '--max-concurrency', '1', '--verify-sec', '5',
  ], queuedEnv));
  const summary = started.verification.summary.join('\n');
  assert.match(summary, /slot: running/);
  assert.match(summary, /behind: queued at position 1 of 1 — waiting for a concurrency slot/);
  assert.deepEqual(started.verification.spawnFailed, []);
  assert.equal(started.verification.timedOut, false);

  // `enqueue` verifies too: the observation follows the acknowledgement.
  const heldSpec = writeSpec(root, [
    sanadTask(root, 'later', { briefFile: writeBrief(root, 'brief-later.md', 'later') }),
  ], 'tasks-later.json');
  runNode(SUPERVISOR, ['add', '--run', queuedRun, '--spec', heldSpec], queuedEnv);
  const enqueued = JSON.parse(runNode(SUPERVISOR, [
    'enqueue', '--run', queuedRun, '--task', 'later', '--json', '--verify-sec', '5',
  ], queuedEnv));
  assert.equal(enqueued.verification.verified, true);
  assert.ok(enqueued.verification.summary.some((line) => line.startsWith('later: queued at position')));

  runNode(SUPERVISOR, ['close', '--run', runDir, '--abort-queued', '--wait'], env);
  runNode(SUPERVISOR, ['close', '--run', queuedRun, '--abort-queued', '--wait'], queuedEnv);
});

test('continue re-dispatches a finished task as a numbered attempt and refuses a live worker', async () => {
  const root = realpathSync(mkdtempSync(join(tmpdir(), 'delegate-continue-test-')));
  const runDir = join(root, 'run');
  const logPath = join(root, 'mock.log');
  const env = { ...process.env, MOCK_LOG: logPath, MOCK_RUN_MS: '300' };
  writeBrief(root, 'brief.md', 'original brief');
  const specPath = writeSpec(root, [sanadTask(root, 'scope')]);
  runNode(SUPERVISOR, ['start', '--spec', specPath, '--run-dir', runDir, '--max-concurrency', '1'], env);

  const manifestPath = join(runDir, 'manifest.json');
  await waitForCondition(() => {
    const manifest = readJsonFile(manifestPath);
    return manifest.tasks.scope.status === 'completed' ? manifest : null;
  });

  const deltaBrief = writeBrief(root, 'delta.md', 'Delta: also cover the queue reason.');
  const continued = JSON.parse(runNode(SUPERVISOR, [
    'continue', '--run', runDir, '--task', 'scope', '--brief-file', deltaBrief, '--json', '--verify-sec', '5',
  ], env));
  assert.equal(continued.attempt, 2);
  assert.equal(continued.previousStatus, 'completed');
  assert.ok(continued.archived.some((path) => path.endsWith('result.json')));

  const manifest = await waitForCondition(() => {
    const current = readJsonFile(manifestPath);
    return current.tasks.scope.status === 'completed' && current.tasks.scope.attempt === 2 ? current : null;
  });
  // History is kept and numbered; the artifact of attempt 1 is archived.
  assert.equal(manifest.tasks.scope.attempts.length, 2);
  assert.deepEqual(manifest.tasks.scope.attempts.map((entry) => entry.attempt), [1, 2]);
  assert.ok(existsSync(join(runDir, 'attempts', 'scope', 'attempt-1', 'result.json')));
  assert.equal(manifest.tasks.scope.briefFile, deltaBrief);

  // The new attempt really ran with the delta brief, in the same workspace.
  const runs = readFileSync(logPath, 'utf8').split(/\r?\n/).filter(Boolean)
    .map((line) => JSON.parse(line)).filter((entry) => entry.kind === 'run');
  assert.equal(runs.length, 2);
  assert.equal(runs[1].briefBody, 'Delta: also cover the queue reason.');
  assert.equal(runs[1].argv[runs[1].argv.indexOf('--execution-root') + 1], root);

  // A live worker blocks a re-dispatch: one session per task.
  const liveEnv = { ...env, MOCK_RUN_MS: '30000' };
  const liveRun = join(root, 'run-live');
  const liveSpec = writeSpec(root, [sanadTask(root, 'busy')], 'tasks-live.json');
  runNode(SUPERVISOR, ['start', '--spec', liveSpec, '--run-dir', liveRun, '--max-concurrency', '1'], liveEnv);
  const liveRefusal = runNodeThrows(SUPERVISOR, [
    'continue', '--run', liveRun, '--task', 'busy', '--brief-file', deltaBrief,
  ], liveEnv);
  assert.match(liveRefusal, /is running; continue needs a finished task/);

  runNode(SUPERVISOR, ['cancel', '--run', liveRun, '--task', 'busy'], liveEnv);
  runNode(SUPERVISOR, ['close', '--run', liveRun, '--abort-queued', '--wait'], liveEnv);

  // Even a terminal task is refused while its worker process is still alive.
  // The run is stopped first so nothing else can rewrite the manifest while the
  // guard is under test.
  const pidRun = join(root, 'run-pid');
  const pidSpec = writeSpec(root, [sanadTask(root, 'orphan')], 'tasks-pid.json');
  const pidStarted = JSON.parse(runNode(SUPERVISOR, [
    'start', '--spec', pidSpec, '--run-dir', pidRun, '--max-concurrency', '1',
  ], liveEnv));
  const pidManifestPath = join(pidRun, 'manifest.json');
  const pidManifest = await waitForCondition(() => {
    const current = readJsonFile(pidManifestPath);
    return current.tasks.orphan.status === 'running' ? current : null;
  });
  process.kill(pidStarted.supervisorPid, 'SIGKILL');
  await waitForCondition(() => !processIsAlive(pidStarted.supervisorPid), 5_000);
  const taskPid = pidManifest.tasks.orphan.pid;
  try {
    pidManifest.tasks.orphan.status = 'completed';
    pidManifest.tasks.orphan.pid = process.pid;
    writeFileSync(pidManifestPath, JSON.stringify(pidManifest, null, 2), 'utf8');
    const pidRefusal = runNodeThrows(SUPERVISOR, [
      'continue', '--run', pidRun, '--task', 'orphan', '--brief-file', deltaBrief,
    ], liveEnv);
    assert.match(pidRefusal, /still has a live worker process/);
  } finally {
    try { process.kill(taskPid, 'SIGKILL'); } catch {}
  }
  runNode(SUPERVISOR, ['close', '--run', runDir, '--wait'], env);
});

test('steer relays a mid-turn message through the CLI contract and journals only its digest', async () => {
  const root = realpathSync(mkdtempSync(join(tmpdir(), 'delegate-steer-test-')));
  const runDir = join(root, 'run');
  const logPath = join(root, 'mock.log');
  const env = { ...process.env, MOCK_LOG: logPath, MOCK_RUN_MS: '60000' };
  writeBrief(root, 'brief.md', 'brief');
  const specPath = writeSpec(root, [sanadTask(root, 'running')]);
  runNode(SUPERVISOR, ['start', '--spec', specPath, '--run-dir', runDir, '--max-concurrency', '1'], env);

  const manifestPath = join(runDir, 'manifest.json');
  await waitForCondition(() => {
    const manifest = readJsonFile(manifestPath);
    return manifest.tasks.running.sessionId ? manifest : null;
  });

  const message = 'Also update the docs page for the new command.';
  const steered = JSON.parse(runNode(SUPERVISOR, [
    'steer', '--run', runDir, '--task', 'running', '--message', message, '--json',
  ], env));
  assert.equal(steered.steered, true);
  assert.equal(steered.sessionId, 'ses_mock_1');
  assert.equal(steered.cliRequestId, 'req_cli_steer_1');
  assert.equal(steered.messageLength, message.length);
  assert.equal(
    steered.messageSha256,
    createHash('sha256').update(message).digest('hex'),
  );

  const journalEvent = readJournal(runDir).find((event) => event.kind === 'steer_sent');
  assert.ok(journalEvent, 'steer_sent must be journaled');
  // A steer notice never wakes a coordinator by itself.
  assert.equal(isActionableEvent(journalEvent), false);
  assert.equal(journalEvent.sessionId, 'ses_mock_1');
  assert.equal(journalEvent.messageLength, message.length);
  assert.equal(journalEvent.messageSha256, steered.messageSha256);
  assert.equal(journalEvent.result, 'completed');
  // The body itself is never persisted anywhere in the run.
  assert.doesNotMatch(readFileSync(join(runDir, 'events.jsonl'), 'utf8'), /update the docs page/);

  // The CLI contract: the same invocation form and pins as the task spawn.
  const steerCall = readFileSync(logPath, 'utf8').split(/\r?\n/).filter(Boolean)
    .map((line) => JSON.parse(line)).find((entry) => entry.kind === 'steer');
  assert.deepEqual(steerCall.argv.slice(0, 4), ['session', 'steer', '--session', 'ses_mock_1']);
  assert.equal(steerCall.body, message);
  assert.equal(steerCall.session, 'ses_mock_1');

  // Refusals: no recorded session id, and not running.
  const noSessionRun = join(root, 'run-nosession');
  const noSessionEnv = { ...env, MOCK_SESSION: '', MOCK_RUN_MS: '20000' };
  const noSessionSpec = writeSpec(root, [sanadTask(root, 'anonymous')], 'tasks-nosession.json');
  runNode(SUPERVISOR, ['start', '--spec', noSessionSpec, '--run-dir', noSessionRun, '--max-concurrency', '1'], noSessionEnv);
  const noSession = runNodeThrows(SUPERVISOR, [
    'steer', '--run', noSessionRun, '--task', 'anonymous', '--message', 'hello',
  ], noSessionEnv);
  assert.match(noSession, /no recorded session id yet/);
  runNode(SUPERVISOR, ['cancel', '--run', noSessionRun, '--task', 'anonymous'], noSessionEnv);

  runNode(SUPERVISOR, ['cancel', '--run', runDir, '--task', 'running'], env);
  runNode(SUPERVISOR, ['close', '--run', runDir, '--wait'], env);
  const finished = runNodeThrows(SUPERVISOR, [
    'steer', '--run', runDir, '--task', 'running', '--message', 'too late',
  ], env);
  assert.match(finished, /steer needs a running task/);
  runNode(SUPERVISOR, ['close', '--run', noSessionRun, '--abort-queued', '--wait'], noSessionEnv);
});

test('a run with no live tasks reports idle and can close itself when idle', async () => {
  const root = realpathSync(mkdtempSync(join(tmpdir(), 'delegate-idle-test-')));
  const runDir = join(root, 'run');
  const env = { ...process.env, MOCK_LOG: join(root, 'mock.log'), MOCK_RUN_MS: '200' };
  writeBrief(root, 'brief.md', 'brief');
  const specPath = writeSpec(root, [sanadTask(root, 'quick')]);
  runNode(SUPERVISOR, [
    'start', '--spec', specPath, '--run-dir', runDir, '--max-concurrency', '1', '--close-when-idle',
  ], env);

  const manifestPath = join(runDir, 'manifest.json');
  const completed = await waitForCondition(() => {
    const manifest = readJsonFile(manifestPath);
    return manifest.status === 'completed' ? manifest : null;
  });
  assert.equal(completed.closed, true);
  assert.equal(completed.tasks.quick.status, 'completed');

  // An open run with nothing left to do is idle, not running.
  const openRun = join(root, 'run-open');
  const openSpec = writeSpec(root, [sanadTask(root, 'idle')], 'tasks-open.json');
  runNode(SUPERVISOR, ['start', '--spec', openSpec, '--run-dir', openRun, '--max-concurrency', '1'], env);
  await waitForCondition(() => readJsonFile(join(openRun, 'manifest.json')).tasks.idle.status === 'completed');
  const brief = runNode(SUPERVISOR, ['status', '--run', openRun, '--brief'], env);
  assert.match(brief, /running \(idle\)/);
  const json = JSON.parse(runNode(SUPERVISOR, ['status', '--run', openRun, '--brief', '--json'], env));
  assert.equal(json.runs[0].idle, true);
  runNode(SUPERVISOR, ['close', '--run', openRun, '--wait'], env);
});
