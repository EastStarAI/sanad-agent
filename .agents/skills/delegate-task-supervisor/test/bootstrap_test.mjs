import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { chmodSync, mkdtempSync, mkdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { delimiter, dirname, join, resolve } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const SKILL = resolve(HERE, '..');
const BOOTSTRAP = join(SKILL, 'scripts', 'bootstrap.mjs');

function runBootstrap(args, env = process.env) {
  return execFileSync(process.execPath, [BOOTSTRAP, ...args], {
    encoding: 'utf8',
    env,
  });
}

test('bootstrap distinguishes a missing installed CLI from a validated source-development fallback', () => {
  const isolatedPath = mkdtempSync(join(tmpdir(), 'delegate-bootstrap-path-'));
  // Points out to a dir with no implementer CLIs. Prerequisite probes will
  // report missing, which is informational state, not a failure.
  const emptyDir = join(isolatedPath, 'empty');
  mkdirSync(emptyDir, { recursive: true });
  const env = { ...process.env, SANAD_DELEGATE_BOOTSTRAP_PATH: emptyDir };

  const state = JSON.parse(runBootstrap(['check', '--json'], env)).state;
  const sanad = state.implementers.sanad;

  assert.equal(sanad.installed, false);
  // The repo checkout itself is the validated source-development fallback.
  assert.equal(sanad.sourceFallback.entryFound, true);
  assert.equal(
    resolve(sanad.sourceFallback.entryPath),
    resolve(SKILL, '..', '..', '..', 'agent', 'bin', 'sanad_agent.dart'),
  );
  assert.ok(sanad.sourceFallback.available === (sanad.sourceFallback.launcher != null),
    'fallback availability must match launcher resolution on the real PATH');

  const text = runBootstrap(['check'], env);
  if (sanad.sourceFallback.available) {
    assert.match(text, /validated source-development fallback/);
    assert.doesNotMatch(text, /sanad: missing \(install with install-sanad skill\)/);
  } else {
    // Honest fallback: actionable guidance instead of a false blocker claim.
    assert.match(text, /missing/);
  }
});

test('bootstrap reports an installed sanad CLI found on the scanned path', () => {
  const isolatedPath = mkdtempSync(join(tmpdir(), 'delegate-bootstrap-fake-'));
  const isWin = process.platform === 'win32';
  const fakeName = isWin ? 'sanad.cmd' : 'sanad';
  const fakePath = join(isolatedPath, fakeName);
  if (isWin) {
    writeFileSync(fakePath, '@echo off\r\necho 1.2.3-test\r\n', 'utf8');
  } else {
    writeFileSync(fakePath, '#!/bin/sh\necho 1.2.3-test\n', 'utf8');
    chmodSync(fakePath, 0o755);
  }
  const env = { ...process.env, SANAD_DELEGATE_BOOTSTRAP_PATH: isolatedPath };

  const state = JSON.parse(runBootstrap(['check', '--json'], env)).state;
  const sanad = state.implementers.sanad;
  assert.equal(sanad.installed, true);
  assert.equal(sanad.version, '1.2.3-test');
  // The source fallback remains reported but an installed CLI is preferred.
  assert.equal(typeof sanad.sourceFallback.available, 'boolean');
  assert.equal(typeof sanad.sourceFallback.entryFound, 'boolean');
});