import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, watch, writeFileSync } from 'node:fs';
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
        clearInterval(timer);
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
  const root = mkdtempSync(join(tmpdir(), 'delegate-sourceroot-test-'));
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
  const root = mkdtempSync(join(tmpdir(), 'delegate-rootonly-test-'));
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
  const root = mkdtempSync(join(tmpdir(), 'delegate-home-test-'));
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
    writeFileSync(resPath, JSON.stringify({status: 'completed', exit_code: 0, home, argv: args}));
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

  runNode(SUPERVISOR, ['start', '--spec', spec, '--run-dir', runDir, '--max-concurrency', '1']);

  const event = JSON.parse(runNode(WATCH_ONCE, ['--run', runDir, '--since', '0']));
  assert.equal(event.to, 'completed');

  const result = JSON.parse(readFileSync(join(outDir, 'result.json'), 'utf8'));
  assert.equal(result.status, 'completed');
  assert.equal(result.home, customHome);
  assert.equal(result.argv.filter((value) => value === '--home').length, 1);

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
