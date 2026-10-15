#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import { chmodSync, existsSync, mkdtempSync, statSync, writeFileSync } from 'node:fs';
import { homedir, platform, tmpdir } from 'node:os';
import { delimiter, dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const SCRIPT_PATH = fileURLToPath(import.meta.url);
const SKILLS_ROOT = resolve(dirname(SCRIPT_PATH), '..', '..');
// The source-development checkout is two levels above the skills directory in
// this repository. Installed (user-global) copies resolve to a profile root
// where the entry point does not exist, so the fallback stays unclaimed.
const REPOSITORY_ROOT = resolve(SKILLS_ROOT, '..', '..');
const SANAD_SOURCE_ENTRY = join(REPOSITORY_ROOT, 'agent', 'bin', 'sanad_agent.dart');
const DELEGATE_SOURCE = 'amElnagdy/delegate-skills';
const REQUIRED_SKILLS = ['delegate-setup', 'agy-delegate', 'opencode-delegate'];
const HELP = `delegate-task-supervisor bootstrap

Usage:
  bootstrap.mjs check [--json]
  bootstrap.mjs install --yes [--json]

Install changes user-level state. The command refuses installation without --yes.
It installs missing delegate skills, OpenCode, and Antigravity from their published sources.
Authentication remains interactive and user-owned.
`;

function fail(message, code = 2) {
  process.stderr.write(`bootstrap: ${message}\n`);
  process.exit(code);
}

function parse(argv) {
  const [command, ...rest] = argv;
  if (!command || command === '-h' || command === '--help') {
    process.stdout.write(HELP);
    process.exit(0);
  }
  if (!['check', 'install'].includes(command)) fail(`unknown command: ${command}`);
  const options = { command, yes: false, json: false };
  for (const token of rest) {
    if (token === '--yes') options.yes = true;
    else if (token === '--json') options.json = true;
    else fail(`unknown argument: ${token}`);
  }
  return options;
}

function scanPath() {
  // Overridable for deterministic tests and non-interactive environments.
  return process.env.SANAD_DELEGATE_BOOTSTRAP_PATH || process.env.PATH || '';
}

function pathCandidates(binary, basePath = scanPath()) {
  const entries = basePath.split(delimiter).filter(Boolean);
  if (binary === 'agy') entries.unshift(join(homedir(), '.local', 'bin'));
  const extensions = platform() === 'win32'
    ? (process.env.PATHEXT || '.COM;.EXE;.BAT;.CMD').split(';')
    : [''];
  const candidates = [];
  for (const entry of entries) {
    for (const extension of extensions) candidates.push(join(entry, `${binary}${extension}`));
  }
  return candidates;
}

function findBinary(binary, basePath = scanPath()) {
  return pathCandidates(binary, basePath).find((candidate) => existsSync(candidate)) || null;
}

function validatedSourceFallback() {
  // A source-development fallback is validated by the checkout actually
  // containing the delegated entry point. The launcher is resolved on the real
  // PATH (never the test scan override) and reported separately.
  const entryFound = existsSync(SANAD_SOURCE_ENTRY) && statSync(SANAD_SOURCE_ENTRY).isFile();
  const launcher = findBinary('fvm', process.env.PATH || '')
    ? 'fvm'
    : findBinary('dart', process.env.PATH || '')
      ? 'dart'
      : null;
  return {
    available: entryFound && launcher != null,
    entryFound,
    entryPath: SANAD_SOURCE_ENTRY,
    launcher,
  };
}

function windowsBatchQuote(value) {
  return `"${String(value).replaceAll('"', '""')}"`;
}

function run(binary, args, options = {}) {
  const resolved = findBinary(binary) || binary;
  const spawnOptions = {
    encoding: 'utf8',
    timeout: options.timeout ?? 30_000,
    stdio: options.inherit ? 'inherit' : ['ignore', 'pipe', 'pipe'],
    env: {
      ...process.env,
      PATH: [join(homedir(), '.local', 'bin'), process.env.PATH || ''].join(delimiter),
    },
  };
  const isWindowsBatch = platform() === 'win32' && /\.(cmd|bat)$/i.test(resolved);
  if (!isWindowsBatch) return spawnSync(resolved, args, spawnOptions);

  // Modern Node rejects direct .cmd/.bat spawning. Invoke the trusted bootstrap
  // command through cmd.exe with explicit quoting instead of shell:true, which
  // concatenates argv unsafely and emits DEP0190.
  const batchCommand = [
    windowsBatchQuote(resolved),
    ...args.map(windowsBatchQuote),
  ].join(' ');
  return spawnSync(
    process.env.ComSpec || 'cmd.exe',
    ['/d', '/s', '/c', `"${batchCommand}"`],
    { ...spawnOptions, windowsVerbatimArguments: true },
  );
}

function versionOf(binary, args = ['--version']) {
  if (!findBinary(binary)) return null;
  const result = run(binary, args, { timeout: 10_000 });
  if (result.status !== 0) return 'installed (version probe failed)';
  return `${result.stdout || result.stderr}`.trim().split(/\r?\n/).find(Boolean) || 'installed';
}

function skillPath(name) {
  return join(homedir(), '.agents', 'skills', name, 'SKILL.md');
}

function collectState() {
  const nodeMajor = Number(process.versions.node.split('.')[0]);
  const opencodePath = findBinary('opencode');
  const agyPath = findBinary('agy');
  const sanadPath = findBinary('sanad');
  const repositorySanadSkill = join(SKILLS_ROOT, 'sanad-delegate', 'SKILL.md');
  const sanadSkillPath = existsSync(skillPath('sanad-delegate'))
    ? skillPath('sanad-delegate')
    : existsSync(repositorySanadSkill)
      ? repositorySanadSkill
      : null;

  let opencodeAuthenticated = false;
  let agyAuthenticated = false;
  if (opencodePath) {
    const result = run('opencode', ['auth', 'list'], { timeout: 15_000 });
    opencodeAuthenticated = result.status === 0 && /credential|oauth|api/i.test(`${result.stdout}${result.stderr}`);
  }
  if (agyPath) {
    const result = run('agy', ['models'], { timeout: 20_000 });
    agyAuthenticated = result.status === 0 && result.stdout.trim().length > 0;
  }
  return {
    platform: process.platform,
    prerequisites: {
      node: { ok: nodeMajor >= 18, version: process.versions.node },
      git: { ok: Boolean(findBinary('git')), version: versionOf('git') },
      npm: { ok: Boolean(findBinary('npm')), version: versionOf('npm') },
      npx: { ok: Boolean(findBinary('npx')), version: versionOf('npx') },
    },
    skills: Object.fromEntries(REQUIRED_SKILLS.map((name) => [name, {
      installed: existsSync(skillPath(name)),
      path: skillPath(name),
    }])),
    implementers: {
      opencode: {
        installed: Boolean(opencodePath),
        path: opencodePath,
        version: versionOf('opencode'),
        authenticated: opencodeAuthenticated,
      },
      antigravity: {
        installed: Boolean(agyPath),
        path: agyPath,
        version: versionOf('agy'),
        authenticated: agyAuthenticated,
      },
      sanad: {
        installed: Boolean(sanadPath),
        path: sanadPath,
        version: versionOf('sanad'),
        skillInstalled: Boolean(sanadSkillPath),
        skillPath: sanadSkillPath,
        // A missing installed CLI is NOT a blocker when a validated
        // source-development fallback is available and its launcher resolves.
        sourceFallback: validatedSourceFallback(),
      },
    },
  };
}

function installPlan(state) {
  const actions = [];
  for (const [name, details] of Object.entries(state.skills)) {
    if (!details.installed) actions.push({ type: 'skill', name, source: `${DELEGATE_SOURCE}@${name}` });
  }
  if (!state.implementers.opencode.installed) {
    actions.push({ type: 'cli', name: 'opencode', source: 'npm package opencode-ai' });
  }
  if (!state.implementers.antigravity.installed) {
    actions.push({
      type: 'cli',
      name: 'antigravity',
      source: platform() === 'win32'
        ? 'https://antigravity.google/cli/install.ps1'
        : 'https://antigravity.google/cli/install.sh',
    });
  }
  return actions;
}

function printState(state, actions, json) {
  if (json) {
    process.stdout.write(`${JSON.stringify({ state, actions }, null, 2)}\n`);
    return;
  }
  process.stdout.write(`Node ${state.prerequisites.node.version}: ${state.prerequisites.node.ok ? 'ok' : 'requires 18+'}\n`);
  for (const [name, details] of Object.entries(state.skills)) {
    process.stdout.write(`skill ${name}: ${details.installed ? 'installed' : 'missing'}\n`);
  }
  for (const [name, details] of Object.entries(state.implementers)) {
    if (name === 'sanad') {
      const skillStatus = details.skillInstalled ? 'installed' : 'missing (see .agents/skills/sanad-delegate)';
      if (details.installed) {
        process.stdout.write(`${name}: ${details.version}; skill=${skillStatus}\n`);
      } else if (details.sourceFallback.available) {
        // Distinct state: the installed CLI is absent, but the checkout is a
        // validated source-development fallback, so this is not a blocker.
        process.stdout.write(
          `${name}: installed CLI missing; validated source-development fallback at ${details.sourceFallback.entryPath} via ${details.sourceFallback.launcher}; skill=${skillStatus}; install the packaged CLI with install-sanad only when a release binary is required\n`,
        );
      } else {
        const guidance = details.sourceFallback.entryFound
          ? '; source entry found but no fvm/dart launcher on PATH — install fvm for the source workflow'
          : ' (install with install-sanad skill)';
        process.stdout.write(`${name}: missing${guidance}; skill=${skillStatus}\n`);
      }
    } else {
      process.stdout.write(`${name}: ${details.installed ? details.version : 'missing'}; auth=${details.authenticated}\n`);
    }
  }
  if (actions.length === 0) process.stdout.write('No installations required.\n');
  else {
    process.stdout.write('Planned user-level changes:\n');
    for (const action of actions) process.stdout.write(`- install ${action.type} ${action.name} from ${action.source}\n`);
  }
}

async function download(url, suffix) {
  const response = await fetch(url, { redirect: 'follow' });
  if (!response.ok) fail(`download failed (${response.status}): ${url}`, 1);
  const directory = mkdtempSync(join(tmpdir(), 'delegate-bootstrap-'));
  const path = join(directory, `installer${suffix}`);
  writeFileSync(path, Buffer.from(await response.arrayBuffer()));
  if (platform() !== 'win32') chmodSync(path, 0o700);
  return path;
}

function requireSuccessful(result, description) {
  if (result.error) fail(`${description} failed: ${result.error.message}`, 1);
  if (result.status !== 0) fail(`${description} failed with exit ${result.status}`, 1);
}

async function install(actions) {
  for (const action of actions) {
    process.stdout.write(`Installing ${action.name}...\n`);
    if (action.type === 'skill') {
      requireSuccessful(
        run('npx', ['--yes', 'skills', 'add', action.source, '-g', '-y'], { inherit: true, timeout: 180_000 }),
        `install ${action.name}`,
      );
    } else if (action.name === 'opencode') {
      requireSuccessful(
        run('npm', ['install', '-g', 'opencode-ai'], { inherit: true, timeout: 180_000 }),
        'install OpenCode',
      );
    } else if (action.name === 'antigravity') {
      if (platform() === 'win32') {
        const script = await download(action.source, '.ps1');
        requireSuccessful(
          run('powershell', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script], { inherit: true, timeout: 180_000 }),
          'install Antigravity',
        );
      } else {
        const script = await download(action.source, '.sh');
        requireSuccessful(
          run('bash', [script], { inherit: true, timeout: 180_000 }),
          'install Antigravity',
        );
      }
    }
  }
}

const options = parse(process.argv.slice(2));
const before = collectState();
const actions = installPlan(before);
printState(before, actions, options.json);
if (options.command === 'install') {
  if (!before.prerequisites.node.ok || !before.prerequisites.git.ok || !before.prerequisites.npm.ok || !before.prerequisites.npx.ok) {
    fail('Node 18+, git, npm, and npx are required before automatic installation', 1);
  }
  if (!options.yes) fail('refusing user-level installation without --yes');
  await install(actions);
  const after = collectState();
  process.stdout.write(options.json
    ? `${JSON.stringify({ after }, null, 2)}\n`
    : 'Installation pass complete. Rerun `check` after completing any required authentication.\n');
}
