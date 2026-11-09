// Which code a run is executing, and whether that code is still current.
//
// This module exists because of a plain operational fact that cost a live
// coordinator round on 2026-11-09: a supervisor run executes the skill scripts
// from the worktree it was started in, for as long as the run lives. Two fixes
// that were merged to `origin/main` hours earlier were therefore absent from the
// process that was supervising four tasks (run13 started at `e7d9a155`; #372
// merged at `82b4d5c1`), and nothing in `start`, `status`, or `watch` said so.
// "Merged" read as "fixed".
//
// The answer is deliberately cheap and offline: record `git rev-parse HEAD` of
// the skill's own checkout when the run starts, and compare it with the locally
// known `origin/main` ref when someone asks. A stale local ref under-reports and
// is never fetched here, because a supervisor must not depend on the network to
// answer a health question; it just says what it knows.

import { execFileSync } from 'node:child_process';
import { dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

// The skill's own scripts directory, which is the code a run executes.
export const SKILL_SCRIPTS_DIR = dirname(fileURLToPath(import.meta.url));
// A health check may never hang the surface that reports it.
export const PROVENANCE_GIT_TIMEOUT_MS = 2_000;

function git(args, cwd) {
  try {
    const value = execFileSync('git', args, {
      cwd,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
      timeout: PROVENANCE_GIT_TIMEOUT_MS,
      windowsHide: true,
    });
    const trimmed = String(value ?? '').trim();
    return trimmed === '' ? null : trimmed;
  } catch {
    return null;
  }
}

/**
 * The checkout a run executes: its root, commit, branch, and whether tracked
 * files were modified. `null` means the answer is unavailable (no git, a copy of
 * the scripts outside a repository), which is reported as unknown instead of
 * being invented.
 */
export function codeIdentity(dir = SKILL_SCRIPTS_DIR) {
  const root = git(['rev-parse', '--show-toplevel'], dir);
  if (!root) return null;
  const commit = git(['rev-parse', 'HEAD'], root);
  if (!commit) return null;
  return {
    root,
    commit,
    shortCommit: commit.slice(0, 8),
    branch: git(['rev-parse', '--abbrev-ref', 'HEAD'], root),
    // A dirty checkout is the normal shape of a live coordinator worktree, so it
    // is reported rather than treated as an error.
    dirty: (git(['status', '--porcelain', '--untracked-files=no'], root) ?? '') !== '',
  };
}

/**
 * How far `code` is behind the locally known `origin/main`.
 *
 * Both counts are reported: a run started from a branch can be ahead and behind
 * at the same time, and only `behind > 0` is the staleness this guard exists for.
 * `null` means there is nothing to compare against, never "current".
 */
export function codeStaleness(code, dir = code?.root) {
  if (!code?.commit || !dir) return null;
  const originMain = git(['rev-parse', '--verify', '--quiet', 'origin/main'], dir);
  if (!originMain || originMain === code.commit) {
    return originMain ? { originMain, originMainShort: originMain.slice(0, 8), behind: 0, ahead: 0, stale: false } : null;
  }
  const behind = Number(git(['rev-list', '--count', `${code.commit}..${originMain}`], dir));
  const ahead = Number(git(['rev-list', '--count', `${originMain}..${code.commit}`], dir));
  if (!Number.isInteger(behind) || !Number.isInteger(ahead)) return null;
  return {
    originMain,
    originMainShort: originMain.slice(0, 8),
    behind,
    ahead,
    stale: behind > 0,
  };
}

/**
 * One line a human reads in `status`. It names the commit, and says what to do
 * about a stale one instead of leaving the reader to infer it.
 */
export function codeStalenessLine(code, staleness) {
  if (!code) return 'CODE  unknown (the run did not record its source commit)';
  const head = `CODE  ${code.shortCommit ?? '?'}${code.branch ? ` (${code.branch})` : ''}`
    + `${code.dirty ? ' dirty' : ''}`;
  if (!staleness) return `${head}  vs origin/main: unknown`;
  if (!staleness.stale) return `${head}  current with origin/main`;
  return `${head}  BEHIND origin/main (${staleness.originMainShort}) by ${staleness.behind} commit(s)`
    + '  — restart the supervisor to run the merged fixes';
}
