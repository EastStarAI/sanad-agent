import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, watch, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const SKILL = resolve(HERE, '..');
const SUPERVISOR = join(SKILL, 'scripts', 'supervisor.mjs');
const WATCH_ONCE = join(SKILL, 'scripts', 'watch-once.mjs');

function waitForFileChange(directory, predicate, timeoutMs = 5_000) {
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
    watcher = watch(directory, check);
    timer = setTimeout(() => {
      watcher.close();
      reject(new Error(`condition not met within ${timeoutMs}ms`));
    }, timeoutMs);
    check();
  });
}

function runNode(script, args, env) {
  return execFileSync(process.execPath, [script, ...args], {
    encoding: 'utf8',
    env,
  }).trim();
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
  `);

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
  ] }));

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

  const finalManifest = await waitForFileChange(runDir, () => {
    const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
    return manifest.status === 'completed' ? manifest : null;
  });
  assert.equal(finalManifest.seq, 6);

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
