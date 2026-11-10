// Incident regression suite: one named scenario per past supervisor incident.
//
// The rest of this directory tests mechanisms — `following` works, `retrying`
// works, `follow_lost` works — and passed while a live coordinator round failed
// on 2026-11-09. A mechanism suite cannot prove the composition that actually
// broke, so every scenario here is named after the incident that produced it and
// states the user-visible promise it protects:
//
//   2026-11-09/outage-block-alerts            a stopped turn wakes the watcher
//   2026-11-09/daemon-restart-survives-follow  a restart is not a lost session
//   2026-11-09/restart-window-expires          an endless outage still alerts
//   2026-11-09/follow-lost-wakes-a-watcher     a lost follow is actionable
//   2026-10-23/gone-vs-unreachable             the two failure classes differ
//   2026-11-08/scheduled-retry-not-a-stall     a served wait is not silence
//   2026-11-09/continue-session-pin            --new-session keeps its pin
//   2026-11-09/stale-supervisor-code           merged but not deployed is visible
//   2026-11-09/watcher-keeps-consuming         alerts after the first batch arrive
//   2026-11-09/block-reaches-the-journal-early  a block is recorded when it happens
//   2026-11-09/blocked-artifact-is-followed     a parked artifact is not a dead end
//
// Modules introduced by these fixes are imported dynamically inside the scenario
// that needs them, so running this file against older scripts yields a failing
// scenario per missing behaviour instead of one load error for the whole suite.

import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { appendFileSync, chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

// The only sanctioned way for a test to signal a process. Selected by a fixture
// pid, never by a name or a pattern.
import { sweepOrphanedFixtures } from './process_guard.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const SKILL = resolve(HERE, '..');
const SUPERVISOR = join(SKILL, 'scripts', 'supervisor.mjs');

const { isActionableEvent, TERMINAL_STATUSES } = await import(join(SKILL, 'scripts', 'supervisor-events.mjs'));

// ---------------------------------------------------------------------------
// Bounded teardown
//
// A supervisor worker is detached on purpose, so a failing scenario can leave it
// behind. The sweep proves ownership from the command line and the fixture
// directory name before anything is signalled.
// ---------------------------------------------------------------------------
test.after(() => {
  // Only this file's fixtures. A sweep that names a family this file does not
  // create can signal a live fixture of a test file that is still running, which
  // `node --test test/*_test.mjs` does concurrently (2026-11-10).
  const { reaped } = sweepOrphanedFixtures({ root: tmpdir(), prefixes: ['delegate-incident-'] });
  if (reaped.length > 0) {
    const detail = reaped.map((entry) => `${entry.pid}@${dirname(entry.needle)}`).join(', ');
    process.stderr.write(`[teardown] reaped ${reaped.length} leftover supervisor process(es): ${detail}\n`);
  }
});

function sleep(ms) {
  return new Promise((resolvePromise) => setTimeout(resolvePromise, ms));
}

async function waitForCondition(predicate, timeoutMs = 20_000, label = 'condition') {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const value = predicate();
    if (value) return value;
    await sleep(40);
  }
  throw new Error(`timed out after ${timeoutMs}ms waiting for ${label}`);
}

function runNode(script, args, env = process.env) {
  return execFileSync(process.execPath, [script, ...args], { env, encoding: 'utf8' });
}

function readJsonFile(path) {
  return JSON.parse(readFileSync(path, 'utf8'));
}

function readJournal(runDir) {
  const path = join(runDir, 'events.jsonl');
  if (!existsSync(path)) return [];
  return readFileSync(path, 'utf8')
    .split(/\r?\n/)
    .filter(Boolean)
    .map((line) => JSON.parse(line));
}

function writeBrief(root, name, content) {
  const path = join(root, name);
  writeFileSync(path, content, 'utf8');
  return path;
}

function writeSpec(root, tasks, name = 'tasks.json') {
  const path = join(root, name);
  writeFileSync(path, JSON.stringify({ tasks }), 'utf8');
  return path;
}

function writeSessionState(path, state) {
  writeFileSync(path, JSON.stringify(state), 'utf8');
}

// ---------------------------------------------------------------------------
// The fixture implementer
//
// One `sanad` stand-in that answers the two calls the supervisor makes into a
// session (`show`, `stop`) and the one call it makes to run a turn (`run`). The
// session file is the whole daemon: a test rewrites it to move the durable turn
// through a restart, a recovery, or a completion, and `__unreadable` selects the
// CLI's two failure shapes:
//
// - `__unreadable: true`      the daemon says it does not know the session
//                             (`session_not_found`, exit 1, JSON payload);
// - `__unreadable: 'transient'` the daemon cannot be reached at all (a restart).
//
// Nothing here can fail a specific number of times: the test owns the timing, so
// a scenario states "the daemon is down, then it is back" explicitly instead of
// hiding it in a counter.
// ---------------------------------------------------------------------------
function writeFixtureImplementer(root) {
  const scriptPath = join(root, 'fixture_sanad.mjs');
  writeFileSync(scriptPath, `
    import {appendFileSync, mkdirSync, readFileSync, writeFileSync} from 'node:fs';
    import {join} from 'node:path';

    const args = process.argv.slice(2);
    const sessionFile = process.env.MOCK_SESSION_FILE;
    const log = process.env.MOCK_LOG;
    const record = (entry) => {
      if (log) appendFileSync(log, JSON.stringify({...entry, time: Date.now()}) + '\\n');
    };
    const readFlag = (flag) => {
      const index = args.indexOf(flag);
      return index === -1 ? null : args[index + 1];
    };

    if (args[0] === 'session' && args[1] === 'show') {
      record({kind: 'show', session: args[2], home: readFlag('--home')});
      let body = null;
      try { body = JSON.parse(readFileSync(sessionFile, 'utf8')); } catch {}
      if (!body || body.__unreadable) {
        const transient = body && body.__unreadable === 'transient';
        const sessionId = (body && body.session_id) || 'ses_mock_1';
        const error = transient
          ? 'SocketException: Connection refused (OS Error: Connection refused, errno = 61)'
          : 'Session ' + sessionId + ' was not found on this daemon.';
        process.stderr.write('Error: ' + (transient ? 'Failed to show session: ' : '') + error);
        process.stdout.write(JSON.stringify(transient
          ? {exit_code: 1, error}
          : {exit_code: 1, error_code: 'session_not_found', session_id: sessionId, error}));
        process.exit(1);
      }
      process.stdout.write(JSON.stringify(body));
      process.exit(Number(body.__exit || 0));
    }
    if (args[0] === 'session' && (args[1] === 'stop' || args[1] === 'retry')) {
      record({kind: args[1]});
      process.exit(0);
    }

    // One turn. The default shape is the 2026-11-09 outage: the provider fails,
    // the daemon schedules a retry, the budget is spent, and the transport exits
    // 1 with cause blocked while the daemon still owns the turn.
    const outDir = readFlag('--out-dir');
    const briefFile = readFlag('--brief-file');
    const pinned = readFlag('--session');
    const priorRuns = (() => {
      if (!log) return 0;
      try {
        return readFileSync(log, 'utf8').split('\\n').filter(Boolean)
          .map((line) => JSON.parse(line)).filter((entry) => entry.kind === 'run').length;
      } catch { return 0; }
    })();
    const sessionId = pinned || 'ses_mock_' + (priorRuns + 1);
    record({
      kind: 'run',
      session: sessionId,
      pinned,
      brief: briefFile ? readFileSync(briefFile, 'utf8') : null,
      argv: args,
    });
    mkdirSync(outDir, {recursive: true});
    const startedAt = new Date(Date.now() - 1000).toISOString();
    const emit = (entry) => appendFileSync(
      join(outDir, 'events.jsonl'),
      JSON.stringify({timestamp: new Date().toISOString(), ...entry}) + '\\n',
    );
    emit({type: 'running', session_id: sessionId});
    if (process.env.MOCK_RUN_RESULT === 'completed') {      writeFileSync(join(outDir, 'result.json'), JSON.stringify({
        status: 'completed',
        exit_code: 0,
        session_id: sessionId,
        started_at: startedAt,
        ended_at: new Date().toISOString(),
        text: 'done',
      }));
      emit({type: 'completed', session_id: sessionId});
      process.exit(0);
    }
    if (process.env.MOCK_RUN_RESULT === 'blocked-artifact') {
      // A transport killed between the parked record and its terminal write: the
      // artifact is blocked, which the daemon still owns. The supervisor must
      // follow it instead of leaving a non-terminal task with no process.
      emit({type: 'blocked', session_id: sessionId, data: {cause: 'network_error'}});
      writeFileSync(join(outDir, 'result.json'), JSON.stringify({
        status: 'blocked',
        exit_code: 1,
        cause: 'network_error',
        session_id: sessionId,
        started_at: startedAt,
        ended_at: new Date().toISOString(),
        text: '',
        error: 'blocked: the provider is unreachable',
      }));
      process.exit(1);
    }
    emit({type: 'retrying', session_id: sessionId, data: {cause: 'network_error'}});
    if (process.env.MOCK_BLOCK_NOTICE === '1') {
      // What sanad run publishes when the daemon states it will not continue,
      // emitted while the transport is still attached. The hold is what lets a
      // test prove the supervisor journaled the block before the exit instead of
      // inferring it from a follow probe afterwards.
      emit({type: 'blocked', session_id: sessionId, data: {
        status: 'blocked',
        code: 'network_error',
        cause: 'network_error',
        message: 'Automatic retry gave up after 2 attempts',
        session_id: sessionId,
        retry_after_ms: 120000,
      }});
      await new Promise((resolveHold) => setTimeout(resolveHold, 1500));
    }
    writeFileSync(join(outDir, 'result.json'), JSON.stringify({
      status: 'failed',
      exit_code: 1,
      cause: 'blocked',
      session_id: sessionId,
      started_at: startedAt,
      ended_at: new Date().toISOString(),
      text: '',
      error: 'blocked: the provider is unreachable',
    }));
    emit({type: 'failed', session_id: sessionId, data: {cause: 'blocked'}});
    process.exit(1);
  `, 'utf8');

  const wrapperPath = join(root, process.platform === 'win32' ? 'sanad.cmd' : 'sanad');
  if (process.platform === 'win32') {
    writeFileSync(wrapperPath, `@echo off\r\n"${process.execPath}" "${scriptPath}" %*\r\n`, 'utf8');
  } else {
    writeFileSync(wrapperPath, `#!/bin/sh\nexec "${process.execPath}" "${scriptPath}" "$@"\n`, 'utf8');
    chmodSync(wrapperPath, 0o755);
  }
  return wrapperPath;
}

function incidentRoot(prefix) {
  return realpathSync(mkdtempSync(join(tmpdir(), prefix)));
}

function fixtureEnv(root, extra = {}) {
  const sessionFile = join(root, 'session.json');
  return {
    ...process.env,
    MOCK_SESSION_FILE: sessionFile,
    MOCK_LOG: join(root, 'mock.log'),
    ...extra,
  };
}

function outageTask(root, id, command) {
  return {
    id,
    implementer: 'sanad',
    workspace: root,
    command,
    args: [
      'run',
      '--brief-file', writeBrief(root, `brief-${id}.md`, 'brief'),
      '--workspace', 'ws-brief',
      '--execution-root', root,
      '--out-dir', join(root, `out-${id}`),
      '--events',
    ],
  };
}

function startRun(runDir, specPath, env, extraArgs = []) {
  return JSON.parse(runNode(SUPERVISOR, [
    'start', '--spec', specPath, '--run-dir', runDir, '--max-concurrency', '1',
    '--verify-ms', '0', '--follow-poll-ms', '100', '--follow-probe-timeout-ms', '5000',
    ...extraArgs,
  ], env));
}

function closeRun(runDir, env) {
  try {
    runNode(SUPERVISOR, ['close', '--run', runDir, '--wait'], env);
  } catch {
    // A scenario that already settled a run may have nothing left to close.
  }
}

// ===========================================================================
// 2026-11-09 — provider outage (run13)
//
// Four tasks were stopped by a network outage. The daemon published `blocked`,
// and the supervisor had to turn that into a wake-up a coordinator reads. The
// promise: a stopped turn is an alerting transition, and its line names no file
// that does not exist.
// ===========================================================================
test('2026-11-09/outage-block-alerts: a stopped turn wakes the watcher with a usable line', async () => {
  const root = incidentRoot('delegate-incident-outage-');
  const runDir = join(root, 'run');
  const env = fixtureEnv(root);
  const command = writeFixtureImplementer(root);
  writeSessionState(env.MOCK_SESSION_FILE, {
    session_id: 'ses_mock_1',
    status: 'blocked',
    updated_at: new Date().toISOString(),
    execution_snapshot: { state: 'blocked', updated_at: new Date().toISOString(), cause: 'network_error' },
    summary: { message_count: 3, user_messages: 1, final_answers: 0, tool_calls: 1, tool_results: 1 },
  });
  const spec = writeSpec(root, [outageTask(root, 'stopped', command)]);

  startRun(runDir, spec, env);
  const blocked = await waitForCondition(
    () => readJournal(runDir).find((event) => event.to === 'blocked'),
    20_000,
    'a blocked transition',
  );
  assert.equal(blocked.cause, 'network_error');
  assert.equal(isActionableEvent(blocked), true, 'a stopped turn is a coordinator decision');
  // It is not a stall: the daemon stated the reason, and a stall notice would be
  // a different (false) claim about the same task.
  assert.equal(readJournal(runDir).some((event) => event.kind === 'progress_stall'), false);

  // The wake-up a coordinator actually reads. Before the fix this printed
  // `result-file undefined`, because a followed verdict has no artifact path.
  const cursor = join(root, 'cursor.json');
  const printed = runNode(SUPERVISOR, ['watch', '--run', runDir, '--cursor', cursor, '--once'], env);
  assert.match(printed, /stopped\s+following -> blocked/);
  assert.equal(printed.includes('undefined'), false, 'no line may name an artifact that does not exist');
  // The turn is still the daemon's, so ending it is a coordinator action: cancel
  // stops the session (the fixture answers `session stop`), which settles the task
  // and keeps the teardown bounded instead of waiting out the follow window.
  runNode(SUPERVISOR, ['cancel', '--run', runDir, '--task', 'stopped', '--json'], env);
  await waitForCondition(
    () => TERMINAL_STATUSES.has(readJsonFile(join(runDir, 'manifest.json')).tasks.stopped?.status),
    20_000,
    'the cancelled task',
  );
  closeRun(runDir, env);
});

// ===========================================================================
// 2026-11-09 — the daemon restart that ended four follows
//
// While the owner restarted the primary daemon, `sanad session show` failed for
// every followed task. Three failures ended the follow for good, although the
// sessions were alive and `resuming` minutes later. The promise: a transport
// outage is survived, and the same follow resumes the same session.
// ===========================================================================
test('2026-11-09/daemon-restart-survives-follow: an unreachable daemon never ends a live follow', async () => {
  const root = incidentRoot('delegate-incident-restart-');
  const runDir = join(root, 'run');
  const env = fixtureEnv(root);
  const command = writeFixtureImplementer(root);
  writeSessionState(env.MOCK_SESSION_FILE, {
    session_id: 'ses_mock_1',
    status: 'running',
    execution_snapshot: { state: 'running', updated_at: new Date().toISOString() },
    summary: { message_count: 3, user_messages: 1, final_answers: 0, tool_calls: 1, tool_results: 1 },
  });
  const spec = writeSpec(root, [outageTask(root, 'followed', command)]);
  const started = startRun(runDir, spec, env, [
    '--follow-lost-polls', '2',
    '--follow-unreadable-grace-ms', '60000',
  ]);
  // The restart window travels with the run and is reported by the handshake.
  assert.equal(started.follow.unreadableGraceMs, 60_000);

  const manifestPath = join(runDir, 'manifest.json');
  await waitForCondition(
    () => readJsonFile(manifestPath).tasks.followed?.follow?.confirmed === true,
    20_000,
    'the follow to be confirmed',
  );

  // The daemon goes away: the CLI answers a transport failure, not "not found".
  writeSessionState(env.MOCK_SESSION_FILE, { __unreadable: 'transient', session_id: 'ses_mock_1' });
  const firstFailure = await waitForCondition(
    () => readJsonFile(manifestPath).tasks.followed?.follow?.firstFailureAt,
    20_000,
    'the first unreadable read',
  );
  assert.ok(firstFailure);
  // More failed reads than the poll floor: three is already past `lostAfterPolls`.
  await waitForCondition(
    () => readJsonFile(manifestPath).tasks.followed?.follow?.unreadablePolls >= 3,
    20_000,
    'three unreadable reads',
  );
  const degraded = readJsonFile(manifestPath).tasks.followed;
  assert.notEqual(degraded.status, 'follow_lost', 'a restart must not end the follow');
  assert.equal(degraded.follow.active, true);
  // The degradation is journaled once, and it is not a wake-up: the task is alive.
  const notices = readJournal(runDir).filter((event) => event.kind === 'follow_unreadable');
  assert.equal(notices.length, 1, 'one record per outage, not one per poll');
  assert.equal(isActionableEvent(notices[0]), false);
  assert.equal(notices[0].failures, 1);

  // The daemon comes back. The same follow picks it up: no re-follow command, no
  // new attempt, and the outage window is cleared.
  writeSessionState(env.MOCK_SESSION_FILE, {
    session_id: 'ses_mock_1',
    status: 'resuming',
    execution_snapshot: { state: 'resuming', updated_at: new Date().toISOString() },
    summary: { message_count: 3, user_messages: 1, final_answers: 0, tool_calls: 1, tool_results: 1 },
  });
  const recovered = await waitForCondition(() => {
    const task = readJsonFile(manifestPath).tasks.followed;
    return task?.follow?.unreadablePolls === 0 ? task : null;
  }, 20_000, 'the follow to recover');
  assert.equal(recovered.follow.firstFailureAt, null);
  assert.equal(recovered.follow.degradedAt, null);
  assert.equal(readJsonFile(manifestPath).tasks.followed.attempt, 1);

  // And the turn's real outcome still settles the task from the durable session.
  writeSessionState(env.MOCK_SESSION_FILE, {
    session_id: 'ses_mock_1',
    status: 'idle',
    execution_snapshot: { state: 'idle', updated_at: new Date().toISOString() },
    summary: { message_count: 4, user_messages: 1, final_answers: 1, tool_calls: 1, tool_results: 1 },
  });
  const settled = await waitForCondition(() => {
    const task = readJsonFile(manifestPath).tasks.followed;
    return TERMINAL_STATUSES.has(task?.status) ? task : null;
  }, 20_000, 'the durable outcome');
  assert.equal(settled.status, 'completed');
  assert.equal(settled.result.source, 'daemon_session');
  closeRun(runDir, env);
});

// ===========================================================================
// 2026-11-09 — an outage that never ends
//
// Patience is bounded. When the window expires the task must end in a state a
// coordinator can act on, with the reason the wait failed, and the wait itself
// must be described instead of the old "session show exited 1".
// ===========================================================================
test('2026-11-09/restart-window-expires: an endless outage still alerts, with a cause worth reading', async () => {
  const root = incidentRoot('delegate-incident-window-');
  const runDir = join(root, 'run');
  const env = fixtureEnv(root);
  const command = writeFixtureImplementer(root);
  writeSessionState(env.MOCK_SESSION_FILE, {
    session_id: 'ses_mock_1',
    status: 'running',
    execution_snapshot: { state: 'running', updated_at: new Date().toISOString() },
    summary: { message_count: 3, user_messages: 1, final_answers: 0, tool_calls: 1, tool_results: 1 },
  });
  const spec = writeSpec(root, [outageTask(root, 'gone', command)]);
  startRun(runDir, spec, env, ['--follow-lost-polls', '2', '--follow-unreadable-grace-ms', '400']);

  const manifestPath = join(runDir, 'manifest.json');
  await waitForCondition(
    () => readJsonFile(manifestPath).tasks.gone?.follow?.confirmed === true,
    20_000,
    'the follow to be confirmed',
  );
  // An unreachable daemon, forever.
  writeSessionState(env.MOCK_SESSION_FILE, { __unreadable: 'transient', session_id: 'ses_mock_1' });

  const lost = await waitForCondition(() => {
    const task = readJsonFile(manifestPath).tasks.gone;
    return task?.status === 'follow_lost' ? task : null;
  }, 20_000, 'the expired restart window');
  assert.equal(lost.cause, 'session_unreadable');
  assert.equal(lost.follow.active, false);
  assert.match(lost.error, /consecutive session reads failed over/);
  // The CLI's own diagnosis survives into the report instead of "exited 1".
  assert.match(lost.error, /Connection refused|SocketException/);

  const lostEvent = readJournal(runDir).find((event) => event.to === 'follow_lost');
  assert.equal(isActionableEvent(lostEvent), true);

  const cursor = join(root, 'cursor.json');
  const printed = runNode(SUPERVISOR, ['watch', '--run', runDir, '--cursor', cursor, '--once'], env);
  assert.match(printed, /follow_lost/);
  assert.equal(printed.includes('undefined'), false);
  closeRun(runDir, env);
});

// ===========================================================================
// 2026-10-23 — the transport death that started all of this
//
// `follow_lost` is the one state where nothing can report the turn's outcome any
// more, so it must wake a coordinator rather than wait for one.
// ===========================================================================
test('2026-11-09/follow-lost-wakes-a-watcher: a lost follow is an alerting transition', async () => {
  const root = incidentRoot('delegate-incident-lost-alert-');
  const runDir = join(root, 'run');
  mkdirSync(runDir, { recursive: true });
  // A journal-only fixture: the contract under test is the watch vocabulary, not
  // a live daemon.
  writeFileSync(join(runDir, 'manifest.json'), JSON.stringify({
    version: 'delegate-supervisor.v1',
    runDir,
    supervisorPid: process.pid,
    status: 'running',
    closed: false,
    seq: 1,
    startedAt: new Date().toISOString(),
    tasks: {
      'lost-task': {
        id: 'lost-task',
        implementer: 'sanad',
        workspace: root,
        status: 'follow_lost',
        cause: 'session_unreadable',
        sessionId: 'ses_1',
        // A followed verdict is not a file: this digest has no `path`, which is
        // exactly the shape that printed `result-file undefined`.
        result: { status: 'follow_lost', source: 'daemon_session', cause: 'session_unreadable' },
      },
    },
  }), 'utf8');
  appendFileSync(join(runDir, 'events.jsonl'), `${JSON.stringify({
    seq: 1,
    taskId: 'lost-task',
    implementer: 'sanad',
    workspace: root,
    from: 'blocked',
    to: 'follow_lost',
    cause: 'session_unreadable',
    at: new Date().toISOString(),
  })}\n`, 'utf8');

  const printed = runNode(SUPERVISOR, ['watch', '--run', runDir, '--cursor', join(root, 'cursor.json'), '--once']);
  assert.match(printed, /lost-task\s+blocked -> follow_lost \(session_unreadable\)/);
  assert.equal(printed.includes('undefined'), false, 'a followed verdict names no artifact');
});

// ===========================================================================
// 2026-10-23 — "the session is gone" and "the daemon is not answering" are
// different facts. Only one of them may end a follow.
// ===========================================================================
test('2026-10-23/gone-vs-unreachable: the two failure classes are classified differently', async () => {
  const { parseSessionShowOutput } = await import(join(SKILL, 'scripts', 'supervisor-follow.mjs'));
  const { followReadFailure } = await import(join(SKILL, 'scripts', 'supervisor-follow.mjs'));

  const gone = parseSessionShowOutput(JSON.stringify({
    session_id: 'ses_1',
    exit_code: 1,
    error_code: 'session_not_found',
    error: 'Session ses_1 was not found on this daemon.',
  }));
  assert.equal(gone.ok, false);
  assert.equal(gone.errorCode, 'session_not_found');

  const unreachable = parseSessionShowOutput(JSON.stringify({
    exit_code: 1,
    error: 'SocketException: Connection refused (errno = 61)',
  }));
  assert.equal(unreachable.ok, false);
  assert.equal(unreachable.errorCode, null, 'a transport failure is not a verdict');

  // Definitive: the poll floor is the only bound, a large grace changes nothing.
  const definitive = followReadFailure({
    failures: 3,
    firstFailureAtMs: 0,
    nowMs: 1,
    minPolls: 3,
    graceMs: 300_000,
    definitive: true,
  });
  assert.equal(definitive.lost, true);
  assert.equal(definitive.cause, 'session_not_found');

  // Transient: not lost until the window has actually elapsed, whatever the count.
  const justAfter = followReadFailure({
    failures: 3,
    firstFailureAtMs: 1_000,
    nowMs: 1_500,
    minPolls: 3,
    graceMs: 300_000,
  });
  assert.equal(justAfter.lost, false);
  assert.equal(justAfter.cause, 'session_unreadable');
  const afterWindow = followReadFailure({
    failures: 12,
    firstFailureAtMs: 1_000,
    nowMs: 301_000,
    minPolls: 3,
    graceMs: 300_000,
  });
  assert.equal(afterWindow.lost, true);
});

// ===========================================================================
// 2026-11-08 — `progress_stall` fired on a wait the daemon was serving
//
// A scheduled retry is progress: the stream is silent for exactly as long as the
// daemon waits. The rule is `max(last signal, stated retry deadline)`.
// ===========================================================================
test('2026-11-08/scheduled-retry-not-a-stall: a served wait is not silence, an overdue promise is', async () => {
  const { evaluateProgress } = await import(join(SKILL, 'scripts', 'supervisor-stalls.mjs'));
  const manifest = { progressStallMs: 900_000 };
  const now = Date.parse('2026-11-09T05:40:00.000Z');
  const state = {
    status: 'running',
    startedAt: '2026-11-09T05:00:00.000Z',
    stateSince: '2026-11-09T05:25:00.000Z',
    lastProgressAt: '2026-11-09T05:25:00.000Z',
    daemonRetry: { attempt: 1, budget: 3, resumeAt: '2026-11-09T05:41:00.000Z' },
  };
  // Guard the premise: without the stated deadline this task looks silent.
  const withoutDeadline = evaluateProgress({ state: { ...state, daemonRetry: {} }, manifest, now });
  assert.equal(withoutDeadline.stalled, true, 'silence alone would be reported');
  assert.equal(evaluateProgress({ state, manifest, now }).stalled, false);

  // A deadline that came and went is exactly what a coordinator must hear: once
  // the silence measured from that deadline passes the threshold, it stalls.
  const overdue = evaluateProgress({
    state: { ...state, daemonRetry: { attempt: 1, budget: 3, resumeAt: '2026-11-09T05:20:00.000Z' } },
    manifest,
    now,
  });
  assert.equal(overdue.stalled, true);
  assert.equal(overdue.retryDeadlineAt, '2026-11-09T05:20:00.000Z');
});

// ===========================================================================
// 2026-11-09 — `continue --new-session` lost the conversation
//
// The fresh session an attempt opened was never written back, so the next plain
// `continue` opened yet another one. The promise: the pin follows the attempt.
// ===========================================================================
test('2026-11-09/continue-session-pin: a new session becomes the task pin a plain continue reuses', async () => {
  const root = incidentRoot('delegate-incident-pin-');
  const runDir = join(root, 'run');
  const env = { ...fixtureEnv(root), MOCK_RUN_RESULT: 'completed' };
  const command = writeFixtureImplementer(root);
  const spec = writeSpec(root, [outageTask(root, 'pinned', command)]);
  runNode(SUPERVISOR, ['start', '--spec', spec, '--run-dir', runDir, '--max-concurrency', '1'], env);

  const manifestPath = join(runDir, 'manifest.json');
  const tasksPath = join(runDir, 'tasks.json');
  const pinOf = () => {
    const args = readJsonFile(tasksPath).tasks.find((task) => task.id === 'pinned').args;
    const index = args.indexOf('--session');
    return index === -1 ? null : args[index + 1];
  };
  await waitForCondition(() => (readJsonFile(manifestPath).tasks.pinned.status === 'completed' ? true : null));
  assert.equal(readJsonFile(manifestPath).tasks.pinned.pinnedSessionId, 'ses_mock_1');
  assert.equal(pinOf(), 'ses_mock_1');

  const delta = writeBrief(root, 'delta.md', 'Delta: also cover the pin.');
  runNode(SUPERVISOR, [
    'continue', '--run', runDir, '--task', 'pinned', '--brief-file', delta,
    '--new-session', '--json', '--verify-sec', '5',
  ], env);
  await waitForCondition(() => {
    const task = readJsonFile(manifestPath).tasks.pinned;
    return task.attempt === 2 && task.status === 'completed' ? task : null;
  });
  // The fresh session is now the pin, and a later plain continue resumes it.
  assert.equal(readJsonFile(manifestPath).tasks.pinned.pinnedSessionId, 'ses_mock_2');
  assert.equal(pinOf(), 'ses_mock_2');
  runNode(SUPERVISOR, [
    'continue', '--run', runDir, '--task', 'pinned', '--brief-file', delta,
    '--json', '--verify-sec', '5',
  ], env);
  await waitForCondition(() => (readJsonFile(manifestPath).tasks.pinned.attempt === 3 ? true : null));
  // The third attempt's own invocation, not just the manifest's attempt counter:
  // the mock writes that record as the process starts, so the assertion waits for
  // the log line instead of assuming the manifest beat the fixture to it (the
  // Linux runner lost that race).
  const runs = await waitForCondition(() => {
    const entries = readFileSync(env.MOCK_LOG, 'utf8').split('\n').filter(Boolean)
      .flatMap((line) => {
        try { return [JSON.parse(line)]; } catch { return []; }
      })
      .filter((entry) => entry.kind === 'run');
    return entries.length >= 3 ? entries : null;
  }, 20_000, 'the third attempt invocation');
  assert.equal(runs[2].pinned, 'ses_mock_2', 'the third attempt resumes the pinned session');
  closeRun(runDir, env);
});

// ===========================================================================
// 2026-11-09 — "merged but not deployed"
//
// run13 executed code two merged fixes behind, and nothing said so. The promise:
// a run records the commit it executes, and `status` says when it is behind.
// ===========================================================================
test('2026-11-09/stale-supervisor-code: a run names its commit and status reports staleness', async () => {
  const { codeIdentity, codeStaleness, codeStalenessLine } = await import(
    join(SKILL, 'scripts', 'supervisor-provenance.mjs')
  );
  const repo = incidentRoot('delegate-incident-provenance-');
  const git = (...args) => execFileSync('git', ['-c', 'user.email=test@example.com', '-c', 'user.name=test', ...args], {
    cwd: repo,
    encoding: 'utf8',
  }).trim();
  git('init', '-q');
  writeFileSync(join(repo, 'a.txt'), 'a', 'utf8');
  git('add', '.');
  git('commit', '-q', '-m', 'first');
  const first = git('rev-parse', 'HEAD');
  writeFileSync(join(repo, 'b.txt'), 'b', 'utf8');
  git('add', '.');
  git('commit', '-q', '-m', 'second');
  const second = git('rev-parse', 'HEAD');
  // The checkout runs the first commit; origin/main already has the second.
  git('update-ref', 'refs/remotes/origin/main', second);
  git('checkout', '-q', '--detach', first);

  const code = codeIdentity(repo);
  assert.equal(code.commit, first);
  assert.equal(code.shortCommit, first.slice(0, 8));
  const staleness = codeStaleness(code);
  assert.equal(staleness.behind, 1);
  assert.equal(staleness.stale, true);
  assert.match(codeStalenessLine(code, staleness), /BEHIND origin\/main .* by 1 commit/);

  // A run on origin/main is current, and says only that.
  git('checkout', '-q', '--detach', second);
  const current = codeIdentity(repo);
  const currentStaleness = codeStaleness(current);
  assert.equal(currentStaleness.stale, false);
  assert.match(codeStalenessLine(current, currentStaleness), /current with origin\/main/);

  // The run records the code it executes, and `status` reports it.
  const runRoot = incidentRoot('delegate-incident-stale-run-');
  const runDir = join(runRoot, 'run');
  const env = fixtureEnv(runRoot);
  const command = writeFixtureImplementer(runRoot);
  writeSessionState(env.MOCK_SESSION_FILE, { session_id: 'ses_mock_1', status: 'idle', execution_snapshot: { state: 'idle' } });
  const spec = writeSpec(runRoot, [outageTask(runRoot, 'probe', command)]);
  const started = JSON.parse(runNode(SUPERVISOR, [
    'start', '--spec', spec, '--run-dir', runDir, '--max-concurrency', '1', '--verify-ms', '0',
    '--follow-poll-ms', '100',
  ], env));
  assert.ok(started.code?.commit, 'the handshake names the code being executed');
  const status = runNode(SUPERVISOR, ['status', '--run', runDir], env);
  assert.match(status, /^CODE\s+\w+\s/m);
  const brief = runNode(SUPERVISOR, ['status', '--run', runDir, '--brief'], env);
  assert.match(brief, new RegExp(`code=${started.code.shortCommit}`));
  closeRun(runDir, env);
});

// ===========================================================================
// 2026-11-09 — the watcher that stopped consuming
//
// `watch --once` printed the first alert and exited, so three more `blocked`
// transitions and four `follow_lost` records sat unread until a human re-ran it.
// The promise: one invocation can consume every later alert too.
// ===========================================================================
test('2026-11-09/watcher-keeps-consuming: an alert arriving after the first batch is still printed', async () => {
  const root = incidentRoot('delegate-incident-linger-');
  const runDir = join(root, 'run');
  mkdirSync(runDir, { recursive: true });
  const journal = join(runDir, 'events.jsonl');
  writeFileSync(join(runDir, 'manifest.json'), JSON.stringify({
    version: 'delegate-supervisor.v1',
    runDir,
    supervisorPid: process.pid,
    status: 'running',
    closed: false,
    seq: 1,
    startedAt: new Date().toISOString(),
    tasks: {},
  }), 'utf8');
  const append = (seq, taskId, from, to) => appendFileSync(journal, `${JSON.stringify({
    seq,
    taskId,
    implementer: 'sanad',
    workspace: root,
    from,
    to,
    at: new Date().toISOString(),
  })}\n`, 'utf8');
  append(1, 'first-task', 'following', 'blocked');

  const watcher = spawn(process.execPath, [
    SUPERVISOR, 'watch', '--run', runDir, '--cursor', join(root, 'cursor.json'),
    '--once', '--linger-sec', '5',
  ], { env: process.env, stdio: ['ignore', 'pipe', 'pipe'] });
  let printed = '';
  watcher.stdout.setEncoding('utf8');
  watcher.stdout.on('data', (chunk) => { printed += chunk; });
  const exited = new Promise((resolvePromise) => watcher.once('exit', resolvePromise));

  await waitForCondition(() => (printed.includes('first-task') ? true : null), 20_000, 'the first batch');
  // The alert that the one-shot watcher never saw, because it had already exited.
  append(2, 'second-task', 'following', 'blocked');
  await waitForCondition(() => (printed.includes('second-task') ? true : null), 20_000, 'the later alert');
  assert.match(printed, /first-task\s+following -> blocked/);
  assert.match(printed, /second-task\s+following -> blocked/);
  const cursor = readJsonFile(join(root, 'cursor.json'));
  assert.equal(cursor.runs[runDir].seq, 2, 'the cursor advanced only for what was printed');
  watcher.kill('SIGTERM');
  await exited;
});

// ===========================================================================
// 2026-11-09 — the block that arrived one CLI exit late
//
// `sanad run` exited on a parked turn without publishing it, so the only
// observer of the block was the supervisor's probe after the worker left: the
// alert arrived one transport-exit late (1–7 s on the observable tasks, and
// never at all when the probe itself failed during a daemon restart, where the
// block was then reported as `failed`). The promise: a block reaches the journal
// when it happens, from the task's own timeline, while the worker is attached.
// ===========================================================================
test('2026-11-09/block-reaches-the-journal-early: a block is journaled before the worker exits', async () => {
  const root = incidentRoot('delegate-incident-block-early-');
  const runDir = join(root, 'run');
  const env = fixtureEnv(root, { MOCK_BLOCK_NOTICE: '1' });
  const command = writeFixtureImplementer(root);
  writeSessionState(env.MOCK_SESSION_FILE, {
    session_id: 'ses_mock_1',
    status: 'blocked',
    updated_at: new Date().toISOString(),
    execution_snapshot: { state: 'blocked', updated_at: new Date().toISOString(), cause: 'network_error' },
    summary: { message_count: 3, user_messages: 1, final_answers: 0, tool_calls: 1, tool_results: 1 },
  });
  const spec = writeSpec(root, [outageTask(root, 'parked', command)]);

  startRun(runDir, spec, env);
  // The block is journaled while the transport is still attached. Waiting on the
  // manifest condition (blocked **and** still owning a pid) is what proves the
  // record came from the task's own timeline: a probe after the exit can only
  // ever report the block for a task that no longer has a process.
  await waitForCondition(() => {
    const parked = readJsonFile(join(runDir, 'manifest.json')).tasks.parked;
    return parked?.status === 'blocked' && parked.pid ? true : null;
  }, 20_000, 'a block recorded while the worker is still attached');
  const blocked = readJournal(runDir).find((event) => event.taskId === 'parked' && event.to === 'blocked');
  assert.equal(blocked.cause, 'network_error');
  assert.equal(blocked.retryAfterMs, 120_000, 'the wait the daemon stated travels with the block');
  assert.equal(isActionableEvent(blocked), true, 'a parked turn is a coordinator decision');

  // The wake-up a coordinator reads, printed by the watcher with the transition
  // that actually happened: the daemon scheduled a retry, spent its budget, and
  // parked the turn — never a synthetic `following` invented after the exit.
  const cursor = join(root, 'cursor.json');
  const printed = runNode(SUPERVISOR, ['watch', '--run', runDir, '--cursor', cursor, '--once'], env);
  assert.match(printed, /parked\s+retrying -> blocked/);

  // Once the worker exits, the follow mirrors the same block. The entry record
  // carries the durable cause the probe just read — never the transport's own
  // terminal `blocked` — so the entry transition (`following`) sits between two
  // records that make one claim about the same parked turn, and the early record
  // is what a coordinator acts on.
  const following = await waitForCondition(
    () => readJournal(runDir).find((event) => event.taskId === 'parked' && event.kind === 'following'),
    20_000,
    'the follow of the parked turn',
  );
  assert.equal(following.cause, 'network_error', 'the entry record names the durable cause');

  // The mirror is a second write of the same composition, so its record and the
  // manifest it persists are awaited rather than assumed: reading between the two
  // writes is what a preempted worker turned into a `blocked` cause on the merge
  // queue (2026-11-10, 1 of 134). A transition journals before it persists, so a
  // manifest that already says `network_error` proves the mirrored record is on
  // disk too.
  await waitForCondition(() => {
    const mirrored = readJournal(runDir)
      .filter((event) => event.taskId === 'parked' && event.to === 'blocked')
      .find((event) => event.seq > following.seq);
    const manifestCause = readJsonFile(join(runDir, 'manifest.json')).tasks.parked.cause;
    return mirrored && manifestCause === 'network_error' ? mirrored : null;
  }, 20_000, 'the mirrored block the follow applies after its entry record');

  const blockedRecords = readJournal(runDir).filter((event) => event.taskId === 'parked' && event.to === 'blocked');
  assert.ok(blockedRecords.length >= 1, 'the block must stay journaled');
  assert.ok(
    blockedRecords[0].seq < following.seq,
    'the first block record precedes the follow, so it came from the timeline and not from a probe',
  );
  for (const record of blockedRecords) {
    assert.equal(record.cause, 'network_error', 'one block, one cause');
  }
  assert.equal(readJsonFile(join(runDir, 'manifest.json')).tasks.parked.cause, 'network_error');

  // The turn is still the daemon's, so ending it is a coordinator action.
  runNode(SUPERVISOR, ['cancel', '--run', runDir, '--task', 'parked', '--json'], env);
  await waitForCondition(
    () => TERMINAL_STATUSES.has(readJsonFile(join(runDir, 'manifest.json')).tasks.parked?.status),
    20_000,
    'the cancelled task',
  );
  closeRun(runDir, env);
});

// ===========================================================================
// 2026-11-09 — the parked artifact that must not become a dead end
//
// Once the block is published before the exit, a transport killed between that
// record and its terminal write leaves `result.json` at `blocked`. The launcher
// never takes a non-terminal artifact as its verdict (it normalizes it to
// `failed` for a non-zero exit), which is what makes such an exit a follow
// candidate at all. The promise: a parked artifact is followed like any other
// unfinished turn, so the durable state — including a later Retry in a client —
// stays observable. Nothing here needs a new follow-candidate entry; the
// scenario guards the composition, not a list.
// ===========================================================================
test('2026-11-09/blocked-artifact-is-followed: a parked artifact is still followed', async () => {
  const root = incidentRoot('delegate-incident-blocked-artifact-');
  const runDir = join(root, 'run');
  const env = fixtureEnv(root, { MOCK_RUN_RESULT: 'blocked-artifact' });
  const command = writeFixtureImplementer(root);
  writeSessionState(env.MOCK_SESSION_FILE, {
    session_id: 'ses_mock_1',
    status: 'blocked',
    updated_at: new Date().toISOString(),
    execution_snapshot: { state: 'blocked', updated_at: new Date().toISOString(), cause: 'network_error' },
    summary: { message_count: 3, user_messages: 1, final_answers: 0, tool_calls: 1, tool_results: 1 },
  });
  const spec = writeSpec(root, [outageTask(root, 'parked-exit', command)]);

  startRun(runDir, spec, env);
  const following = await waitForCondition(
    () => readJournal(runDir).find((event) => event.taskId === 'parked-exit' && event.kind === 'following'),
    10_000,
    'a follow for the parked artifact',
  );
  assert.equal(following.to, 'following');
  assert.equal(following.pid, null, 'no process is left to own the turn');
  // The durable state is still mirrored, so the task keeps reporting the block a
  // coordinator must act on rather than a status nobody can explain.
  const blocked = await waitForCondition(
    () => readJournal(runDir).find((event) => event.taskId === 'parked-exit' && event.to === 'blocked'),
    10_000,
    'the mirrored block',
  );
  assert.equal(blocked.cause, 'network_error');
  runNode(SUPERVISOR, ['cancel', '--run', runDir, '--task', 'parked-exit', '--json'], env);
  await waitForCondition(
    () => TERMINAL_STATUSES.has(readJsonFile(join(runDir, 'manifest.json')).tasks['parked-exit']?.status),
    20_000,
    'the cancelled task',
  );
  closeRun(runDir, env);
});
