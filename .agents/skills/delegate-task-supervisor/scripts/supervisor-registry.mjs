// Run identity and the workspace registry.
//
// The coordinator remembers a project/session per workspace across runs, so a
// continuation can name the exact conversation instead of guessing it. The
// registry lives under the user config directory, keyed by a hash of the
// canonical workspace path; `identityFor` is the only reader a command needs,
// and `recordIdentity` writes what a completed relay reported.
//
// Run paths and the run manifest are deliberately not here: they are addressing
// primitives that every module below the command layer needs, so they live in
// `supervisor-core.mjs` with the rest of the shared layer.

import { createHash } from 'node:crypto';
import { existsSync, realpathSync } from 'node:fs';
import { homedir } from 'node:os';
import { isAbsolute, join, resolve } from 'node:path';

import { fail, readJson, sha256, writeJsonAtomic } from './supervisor-core.mjs';

export function canonicalWorkspace(path) {
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

export function identityFor(workspace) {
  const canonical = canonicalWorkspace(workspace);
  const registry = loadRegistry();
  return registry.workspaces[workspaceKey(canonical)] || {
    path: canonical,
    antigravity: null,
    opencode: null,
    sanad: null,
  };
}

export function recordIdentity(task, result) {
  const projectId = result?.projectId ?? result?.project_id ?? null;
  const conversationId = result?.conversationId ?? result?.conversation_id ?? null;
  const sessionId = result?.sessionId ?? result?.session_id ?? null;
  if (!projectId && !conversationId && !sessionId) return;

  const registry = loadRegistry();
  const key = workspaceKey(task.workspace);
  const entry = registry.workspaces[key] || {
    path: task.workspace,
    antigravity: null,
    opencode: null,
    sanad: null,
  };
  const now = new Date().toISOString();
  if (task.implementer === 'antigravity' || task.implementer === 'agy') {
    entry.antigravity = { projectId, conversationId, updatedAt: now };
  } else if (task.implementer === 'opencode') {
    entry.opencode = { sessionId, updatedAt: now };
  } else if (task.implementer === 'sanad') {
    entry.sanad = { sessionId, updatedAt: now };
  }
  registry.workspaces[key] = entry;
  writeJsonAtomic(registryPath(), registry);
}

export function identityCommand(options) {
  if (!options.workspace) fail('identity requires --workspace');
  process.stdout.write(`${JSON.stringify(identityFor(options.workspace), null, 2)}\n`);
}
