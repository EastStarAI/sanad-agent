// The child-process boundary of a delegated worker.
//
// Two rules live here and nowhere else, so a task launch and an auxiliary session
// call can never disagree about them:
//
// 1. How a task is spawned: the Home a task declares is exported into its
//    environment as well as passed as `--home`, and Windows `.cmd`/`.bat`
//    wrappers go through Node's shell mode after validation rejected the shell
//    metacharacters.
// 2. How a task's process tree is signalled and verified: POSIX group first,
//    the direct child as the Windows fallback, and "the group is gone" only after
//    bounded probes say so.

import { spawn } from 'node:child_process';

import { sleepSync } from '../supervisor-core.mjs';
import { windowsBatchQuote } from '../supervisor-windows.mjs';

// A worker with a declared task Home receives that Home in its environment as
// well as through `--home`: `SANAD_HOME` names it, and an inherited
// `SANAD_STATE_HOME` is removed so runtime state resolves inside the same Home
// (the worktree Home model). Nothing the worker starts can then fall back to
// the caller's Home, even before it parses `--home`.
export function taskEnvironment(task, baseEnv) {
  if (!task.home) return baseEnv;
  const env = { ...baseEnv, SANAD_HOME: task.home };
  delete env.SANAD_STATE_HOME;
  return env;
}
// Commands are spawned directly except Windows `.cmd`/`.bat` wrappers, which
// need Node's shell mode after shell metacharacters have been rejected at
// validation time. Both task launches and session-stop requests share it.
export function spawnCommand(command, args, spawnOptions) {
  const isBatch = process.platform === 'win32' && /\.(cmd|bat)$/i.test(command);
  if (!isBatch) return spawn(command, args, spawnOptions);
  const batchCommand = [command, ...args].map(windowsBatchQuote).join(' ');
  return spawn(
    process.env.ComSpec || 'cmd.exe',
    ['/d', '/s', '/c', `"${batchCommand}"`],
    { ...spawnOptions, windowsVerbatimArguments: true },
  );
}
// ---------------------------------------------------------------------------
// Process groups.
//
// A delegated task is spawned as the leader of its own process group, so the
// whole tree behind a wrapper — `fvm` → `dart run`, `npm` → `node`, `cmd` →
// anything — can be signalled and verified as one unit. Signalling only the
// direct child is not enough, and 2026-10-23 proved it: `kill <fvm pid>` ended
// the wrapper while the real `dartvm … sanad_agent.dart run` survived,
// re-parented to pid 1 and still attached to the session. Cancel, the forced
// kill after the grace period, and shutdown therefore all signal the group, and
// an exit is not treated as a departure until the group is empty.
//
// Group signalling is a POSIX contract. Windows has no process groups, so the
// direct child is signalled there and `pgid` is recorded as `null`.
// ---------------------------------------------------------------------------
export const GROUP_SIGNALS_SUPPORTED = process.platform !== 'win32';

// Bounded verification of a group after its leader exited. The `exit` event
// means the direct child is reaped, not that the group is empty, so a member
// still shutting down gets a few probes before it is reported as surviving.
export const GROUP_EXIT_PROBES = 3;
export const GROUP_EXIT_PROBE_MS = 40;

/**
 * Signal one process group. `pgid` is validated before it reaches the kernel:
 * `-1` would address every process this user owns, so it is never allowed.
 */
export function signalProcessGroup(pgid, signal) {
  if (!GROUP_SIGNALS_SUPPORTED) return false;
  if (!Number.isInteger(pgid) || pgid <= 1) return false;
  if (pgid === process.pid) return false;
  try {
    process.kill(-pgid, signal);
    return true;
  } catch {
    return false;
  }
}

export function groupHasLiveMembers(pgid) {
  if (!GROUP_SIGNALS_SUPPORTED) return false;
  if (!Number.isInteger(pgid) || pgid <= 1) return false;
  if (pgid === process.pid) return false;
  try {
    process.kill(-pgid, 0);
    return true;
  } catch (error) {
    // EPERM means the group exists and is owned by someone else; anything else
    // (ESRCH) means the last member is gone.
    return error?.code === 'EPERM';
  }
}

/**
 * Members of a task's group that outlived the direct child, or `null` when the
 * group is empty. Synchronous on purpose: it runs in the exit handler, and a
 * bounded probe there is cheaper than a new asynchronous state.
 */
export function survivingGroupMembers(pgid) {
  const id = Number(pgid);
  if (!GROUP_SIGNALS_SUPPORTED || !Number.isInteger(id) || id <= 1) return null;
  for (let probe = 1; probe <= GROUP_EXIT_PROBES; probe += 1) {
    if (!groupHasLiveMembers(id)) return null;
    if (probe < GROUP_EXIT_PROBES) sleepSync(GROUP_EXIT_PROBE_MS);
  }
  return { pgid: id, aliveAfterMs: (GROUP_EXIT_PROBES - 1) * GROUP_EXIT_PROBE_MS, probes: GROUP_EXIT_PROBES };
}

/**
 * Signal the whole group of one task, falling back to the direct child when the
 * group is unavailable (Windows, or a group that is already empty).
 */
export function signalTaskProcess(state, child, signal) {
  const pgid = Number(state?.pgid);
  if (signalProcessGroup(pgid, signal)) {
    return { signal, pgid, group: true };
  }
  try {
    child?.kill(signal);
    return { signal, pgid: Number.isInteger(pgid) && pgid > 1 ? pgid : null, group: false };
  } catch {
    return null;
  }
}
