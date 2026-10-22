#!/usr/bin/env node

import { existsSync, readFileSync, watch } from 'node:fs';
import { basename, dirname, resolve } from 'node:path';

// The wake set is shared with `supervisor.mjs watch` so both readers agree on
// which journal records matter. Note that `queued_stall` and `progress_stall`
// are notices, not state changes, but they are exactly the "nothing is
// happening" signal an orchestrator waits for.
import { WATCH_STATUSES } from './supervisor-events.mjs';

const HELP = `watch-once

Usage:
  watch-once.mjs --run <absolute-run-directory> [--since <sequence>] [--all]

Waits without polling and prints exactly one event as JSON. By default terminal,
intervention, blocked, waiting, resuming, and stall notices are returned; --all
returns any next transition. This is the single-run, read-only primitive; use
\`supervisor.mjs watch\` for several runs with a durable, persisted cursor.
`;

function fail(message) {
  process.stderr.write(`watch-once: ${message}\n`);
  process.exit(2);
}

function parseOptions(argv) {
  const options = { since: 0, all: false };
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (token === '--all') {
      options.all = true;
      continue;
    }
    if (token === '--run' || token === '--since') {
      const value = argv[index + 1];
      if (value == null) fail(`missing value for ${token}`);
      options[token.slice(2)] = value;
      index += 1;
      continue;
    }
    if (token === '-h' || token === '--help') {
      process.stdout.write(HELP);
      process.exit(0);
    }
    fail(`unknown argument: ${token}`);
  }
  if (!options.run) fail('--run is required');
  options.since = Number(options.since);
  if (!Number.isInteger(options.since) || options.since < 0) {
    fail('--since must be a non-negative integer');
  }
  return options;
}

function nextEvent(journal, since, includeAll) {
  if (!existsSync(journal)) return null;
  const content = readFileSync(journal, 'utf8');
  for (const line of content.split(/\r?\n/)) {
    if (!line.trim()) continue;
    let event;
    try {
      event = JSON.parse(line);
    } catch {
      continue;
    }
    if (event.seq <= since) continue;
    if (includeAll || WATCH_STATUSES.has(event.to)) return event;
  }
  return null;
}

const options = parseOptions(process.argv.slice(2));
const runDir = resolve(options.run);
if (!existsSync(runDir)) fail(`run directory does not exist: ${runDir}`);
const journal = resolve(runDir, 'events.jsonl');
const manifestPath = resolve(runDir, 'manifest.json');
let finished = false;
let watcher;
let livenessTimer;

function staleSupervisorEvent() {
  if (!existsSync(manifestPath)) return null;
  let manifest;
  try {
    manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
  } catch {
    return null;
  }
  // A run already marked stale (for example by a repairing `status` read) is
  // just as final as one this watcher is the first to notice: never block.
  const alreadyStale = manifest.status === 'stale';
  if (!alreadyStale) {
    if (manifest.status !== 'running' || !Number.isInteger(manifest.supervisorPid)) return null;
    try {
      process.kill(manifest.supervisorPid, 0);
      return null;
    } catch {
      // fall through to the synthesized event
    }
  }
  return {
    seq: manifest.seq,
    timestamp: new Date().toISOString(),
    taskId: null,
    from: alreadyStale ? 'stale' : 'running',
    to: 'stale',
    kind: 'supervisor_stale',
    supervisorPid: manifest.supervisorPid,
  };
}

function completeIfReady() {
  if (finished) return;
  const event = nextEvent(journal, options.since, options.all) || staleSupervisorEvent();
  if (!event) return;
  finished = true;
  watcher?.close();
  clearInterval(livenessTimer);
  process.stdout.write(`${JSON.stringify(event)}\n`);
  process.exit(0);
}

// Register first and rescan second: an append before registration is found by the
// scan, while an append after registration triggers the watcher. This closes the
// common read-then-watch race without introducing a polling interval.
watcher = watch(dirname(journal), (_eventType, filename) => {
  if (!filename || [basename(journal), basename(manifestPath)].includes(String(filename))) {
    completeIfReady();
  }
});
watcher.once('error', (error) => fail(`watch failed: ${error.message}`));
// Filesystem events remain the primary wake-up path. This bounded liveness fallback
// prevents an already-dead supervisor from leaving the caller blocked forever.
livenessTimer = setInterval(completeIfReady, 1_000);
completeIfReady();
