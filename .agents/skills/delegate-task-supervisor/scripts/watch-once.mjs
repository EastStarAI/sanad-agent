#!/usr/bin/env node

import { existsSync, readFileSync, watch } from 'node:fs';
import { basename, dirname, resolve } from 'node:path';

const TERMINAL_STATUSES = new Set([
  'completed',
  'failed',
  'blocked',
  'timeout',
  'aborted',
  'agy_unavailable',
  'opencode_unavailable',
]);
const HELP = `watch-once

Usage:
  watch-once.mjs --run <absolute-run-directory> [--since <sequence>] [--all]

Waits without polling and prints exactly one event as JSON. By default only terminal
or intervention-worthy transitions are returned; --all returns the next transition.
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
    if (includeAll || TERMINAL_STATUSES.has(event.to)) return event;
  }
  return null;
}

const options = parseOptions(process.argv.slice(2));
const runDir = resolve(options.run);
if (!existsSync(runDir)) fail(`run directory does not exist: ${runDir}`);
const journal = resolve(runDir, 'events.jsonl');
let finished = false;
let watcher;

function completeIfReady() {
  if (finished) return;
  const event = nextEvent(journal, options.since, options.all);
  if (!event) return;
  finished = true;
  watcher?.close();
  process.stdout.write(`${JSON.stringify(event)}\n`);
  process.exit(0);
}

// Register first and rescan second: an append before registration is found by the
// scan, while an append after registration triggers the watcher. This closes the
// common read-then-watch race without introducing a polling interval.
watcher = watch(dirname(journal), (_eventType, filename) => {
  if (!filename || String(filename) === basename(journal)) completeIfReady();
});
watcher.once('error', (error) => fail(`watch failed: ${error.message}`));
completeIfReady();
