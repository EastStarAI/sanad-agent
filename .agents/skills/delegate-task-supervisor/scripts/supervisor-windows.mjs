// Windows launch path: the broker script and its handshake.
//
// Windows cannot spawn a detached POSIX-style worker group, so `start` writes a
// small broker (`.vbs` wrapper plus a `.cmd` launcher) and waits for it to
// report the effective concurrency it picked up. The quoting helpers live here
// too, because a batch command line and a POSIX shell quote differently and a
// path with a space must survive both.
//
// `SCRIPT_PATH` names the CLI entrypoint, which lives beside this module: a
// broker and the viewer terminal re-enter `supervisor.mjs`, never this file.

import { spawnSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { sleepSync, writeJsonAtomic } from './supervisor-core.mjs';

export const SCRIPT_PATH = fileURLToPath(new URL('./supervisor.mjs', import.meta.url));
// Cancellation is cooperative first: SIGTERM follows the relay's own timeout
// path. A child that ignores it is force-killed after this grace period so a
// cancelled task can never block run completion.
export const CANCEL_FORCE_KILL_MS = 10_000;
// One translation of the retry policy into worker arguments, shared by the
// POSIX spawn and the Windows broker so both start the same worker.
export function workerRetryArgs(policy) {
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
export function workerFollowArgs(policy) {
  return [
    '--follow-poll-ms', String(policy.pollMs),
    '--follow-deadline-ms', String(policy.deadlineMs),
    '--follow-lost-polls', String(policy.lostAfterPolls),
    '--follow-probe-timeout-ms', String(policy.probeTimeoutMs),
  ];
}

export function windowsBatchQuote(value) {
  return `"${String(value).replaceAll('"', '""')}"`;
}

export function launchThroughWindowsExplorer(scriptPath) {
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

export function writeWindowsWorkerBroker(runDir, paths, maxConcurrency, queuedStallMs, progressStallMs, autoRetry, follow, closeWhenIdle = false, cancelForceKillMs = CANCEL_FORCE_KILL_MS) {
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

export function waitForWindowsWorkerHandshake(paths, timeoutMs = 10_000) {
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
