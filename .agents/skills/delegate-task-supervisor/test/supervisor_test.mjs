import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { chmodSync, mkdtempSync, mkdirSync, readFileSync, watch, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join, resolve } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const SKILL = resolve(HERE, '..');
const SUPERVISOR = join(SKILL, 'scripts', 'supervisor.mjs');
const WATCH_ONCE = join(SKILL, 'scripts', 'watch-once.mjs');

function waitForFileChange(directory, predicate, timeoutMs = 8_000) {
  return new Promise((resolvePromise, reject) => {
    let watcher;
    let timer;
    const check = () => {
      try {
        const value = predicate();
        if (!value) return;
        clearTimeout(timer);
        watcher?.close();
        resolvePromise(value);
      } catch {
        // The writer may be between atomic rename operations; the next event retries.
      }
    };
    try {
      watcher = watch(directory, check);
    } catch {}
    timer = setInterval(check, 100);
    setTimeout(() => {
      clearInterval(timer);
      watcher?.close();
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
    task('middle', 1_050, 'blocked'),
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

  const first = JSON.parse(runNode(WATCH_ONCE, ['--run', runDir, '--since', '3'], env));
  assert.equal(first.taskId, 'fast');
  assert.equal(first.to, 'completed');

  const second = JSON.parse(runNode(WATCH_ONCE, [
    '--run', runDir, '--since', String(first.seq),
  ], env));
  assert.equal(second.taskId, 'middle');
  assert.equal(second.to, 'blocked');

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

test('Sanad fixture writing G2 events: needs_input and needs_permission wake default watch-once, resumed is non-terminal, session identity recorded', async () => {
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

  // 2. watch-once ignores intermediate 'resumed' and wakes up on needs_permission
  const event2 = JSON.parse(runNode(WATCH_ONCE, ['--run', runDir, '--since', String(event1.seq)], env));
  assert.equal(event2.taskId, 'sanad-task-1');
  assert.equal(event2.to, 'needs_permission');
  assert.equal(event2.sessionId, 'ses_sanad_42');
  assert.equal(event2.requestId, 'req-perm-1');

  // 3. watch-once ignores intermediate 'resumed' and wakes up on completed
  const event3 = JSON.parse(runNode(WATCH_ONCE, ['--run', runDir, '--since', String(event2.seq)], env));
  assert.equal(event3.taskId, 'sanad-task-1');
  assert.equal(event3.to, 'completed');

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
  const root = mkdtempSync(join(tmpdir(), 'delegate-collision-test-'));
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

  // 7. Workspace mode does not inspect an otherwise invalid execution root
  assert.match(validate({
    args: ['run', '--brief-file', brief, '--workspace', 'ws', '--execution-root', 'relative-ignored-root', '--out-dir', outDir],
    resultPath: join(root, 'other', 'result.json'),
  }), /resultPath must match/);

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
