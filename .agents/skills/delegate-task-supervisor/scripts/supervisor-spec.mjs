// Task specification validation.
//
// A spec is untrusted input: it decides what runs, where, with which arguments,
// and under which home. Validation is the one place that decides whether a
// submission is acceptable, so `add`, `enqueue`, and `start` all call it and
// none of them re-checks a field afterwards.
//
// The rules are deliberately strict about paths (absolute workspace, execution
// root inside the workspace, source checkout only for the FVM form) and about
// the argument surface each implementer owns.

import { existsSync, statSync } from 'node:fs';
import { basename, isAbsolute, resolve } from 'node:path';

import { fail, getArgValue } from './supervisor-core.mjs';
import { canonicalWorkspace, identityFor } from './supervisor-registry.mjs';

const SUPPORTED_IMPLEMENTERS = new Set(['opencode', 'agy', 'antigravity', 'sanad']);
export const SANAD_CLIENT_COMMAND = /^sanad-client(\.(exe|cmd|bat))?$/;
const TASK_ID = /^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$/;
const SHELL_META = /[|;&<>$`]/;
const WINDOWS_BATCH_META = /[|;&<>$`%^!]/;
function validateTask(item, existingIds = new Set()) {
  if (!item || typeof item !== 'object') fail('each task must be an object');
  if (!TASK_ID.test(item.id || '')) fail(`invalid task id: ${item.id}`);
  if (existingIds.has(item.id)) fail(`duplicate task id: ${item.id}`);
  if (!SUPPORTED_IMPLEMENTERS.has(item.implementer)) {
    fail(`unsupported implementer: ${item.implementer}`);
  }
  if (typeof item.command !== 'string' || item.command.length === 0) {
    fail(`task ${item.id} requires command`);
  }
  if (!Array.isArray(item.args) || item.args.some((arg) => typeof arg !== 'string')) {
    fail(`task ${item.id} args must be an array of strings`);
  }
  if (SHELL_META.test(item.command) || item.args.some((arg) => SHELL_META.test(arg))) {
    fail(`task ${item.id} command and args must not contain shell metacharacters`);
  }
  const isWindowsBatchCommand = process.platform === 'win32' && /\.(cmd|bat)$/i.test(item.command);
  if (isWindowsBatchCommand && (
    WINDOWS_BATCH_META.test(item.command) ||
    item.args.some((arg) => WINDOWS_BATCH_META.test(arg)) ||
    (typeof item.home === 'string' && WINDOWS_BATCH_META.test(item.home))
  )) {
    fail(`task ${item.id} Windows batch command, args, and home must not contain cmd metacharacters`);
  }

  const workspace = canonicalWorkspace(item.workspace);
  const normalizeOptionalPath = (value, field) => {
    if (value == null) return null;
    if (typeof value !== 'string' || !isAbsolute(value)) {
      fail(`task ${item.id} ${field} must be an absolute path`);
    }
    return resolve(value);
  };
  let spawnCwd = workspace;

  // Per-task opt-in/opt-out of the run's automatic retry policy. A task that
  // says nothing inherits the run default; `null` is what records that.
  let autoRetry = null;
  if (item.autoRetry != null) {
    if (typeof item.autoRetry !== 'boolean') fail(`task ${item.id} autoRetry must be a boolean`);
    autoRetry = item.autoRetry;
  }

  // `sourceRoot` is the Sanad source/spawn-root contract: it separates the
  // source checkout that provides the development CLI from the delegated
  // execution root (task.workspace / --execution-root). It is valid only for
  // the fvm source-development invocation and never changes the logical task
  // workspace or CLI targeting mode.
  if (item.sourceRoot != null && item.implementer !== 'sanad') {
    fail(`task ${item.id} sourceRoot is only valid for sanad source-development invocations`);
  }

  // `home` is the explicit custom Sanad Home contract. A detached Sanad worker
  // must never fall back to a default Home (observed standalone/exit 78 when
  // the managed custom Home was not reachable). Valid only for sanad tasks;
  // the value is injected as `--home` and duplicate/malformed declarations
  // fail closed. Credentials never belong in this field.
  const customHome = item.home ?? null;
  if (customHome != null && item.implementer !== 'sanad') {
    fail(`task ${item.id} home is only valid for sanad tasks`);
  }

  let resultPath = normalizeOptionalPath(item.resultPath, 'resultPath');
  let timelinePath = normalizeOptionalPath(item.timelinePath, 'timelinePath');
  let timelineFormat = item.timelineFormat ?? (item.implementer === 'sanad' ? 'jsonl' : 'text');
  // Per-task silence threshold. The run default comes from
  // `start --progress-stall-sec`; a spec may override it for one task.
  let progressStallMs = null;
  if (item.progressStallSec != null || item.progressStallMs != null) {
    const requested = Number(item.progressStallMs ?? Number(item.progressStallSec) * 1000);
    if (!Number.isFinite(requested) || requested <= 0) {
      fail(`task ${item.id} progressStallSec must be a positive number`);
    }
    progressStallMs = Math.round(requested);
  }
  // Remote `sanad-client` tasks record the validated target device so the run
  // manifest shows which device a task was dispatched to.
  let remoteDevice = null;

  if (!['text', 'jsonl'].includes(timelineFormat)) {
    fail(`task ${item.id} timelineFormat must be text or jsonl`);
  }

  if (item.implementer === 'sanad') {
    const cmdBase = basename(item.command).toLowerCase();
    const isInstalledSanad = /^(sanad)(\.(exe|cmd|bat))?$/.test(cmdBase) && item.args[0] === 'run';
    // The source-development entry may live under nested/private-consumer
    // layouts (e.g. `sanad-agent/agent/bin/sanad_agent.dart`), so match the
    // entry suffix rather than a fixed relative path while still requiring
    // `dart run <entry> run` and the fvm executable.
    const isFvmSanad = /^(fvm)(\.(exe|cmd|bat))?$/.test(cmdBase)
      && item.args[0] === 'dart'
      && item.args[1] === 'run'
      && item.args[3] === 'run'
      && typeof item.args[2] === 'string'
      && /sanad_agent\.dart$/.test(item.args[2]);
    // Remote delegation drives the `sanad-client` relay at the live Client of a
    // Sanad Home. A built binary may be addressed by an explicit absolute path.
    const isRemoteClient = SANAD_CLIENT_COMMAND.test(cmdBase);
    if (!isInstalledSanad && !isFvmSanad && !isRemoteClient) {
      fail(`task ${item.id} sanad invocation must be 'sanad run', 'fvm dart run <entry>/sanad_agent.dart run', or 'sanad-client -d <device-id> run'`);
    }

    if (isRemoteClient) {
      if (/[\\/]/.test(item.command) && !isAbsolute(item.command)) {
        fail(`task ${item.id} sanad-client command path must be absolute: ${item.command}`);
      }
      // Accept only the documented prefix `-d|--device <device-id> run` (or the
      // `--device=<id>` form). Requiring `run` as the relayed subcommand keeps
      // the target inside the one-shot surface, exactly like `sanad run`.
      const [first] = item.args;
      let device = null;
      let runIndex = -1;
      if (first === '-d' || first === '--device') {
        const value = item.args[1];
        if (!value || value.startsWith('-')) fail(`task ${item.id} ${first} requires a value`);
        device = value;
        runIndex = 2;
      } else if (typeof first === 'string' && first.startsWith('--device=')) {
        device = first.slice('--device='.length);
        if (!device) fail(`task ${item.id} --device requires a value`);
        runIndex = 1;
      }
      if (runIndex === -1 || item.args[runIndex] !== 'run') {
        fail(`task ${item.id} sanad-client invocation must be 'sanad-client -d <device-id> run ...'`);
      }
      // A later device flag would silently retarget the relayed command away
      // from the device this task validated (the Client CLI keeps the last one).
      if (item.args.slice(runIndex + 1).some(
        (arg) => arg === '-d' || arg === '--device' || (typeof arg === 'string' && arg.startsWith('--device=')),
      )) {
        fail(`task ${item.id} contains duplicate --device values`);
      }
      remoteDevice = device;
    }

    if (item.sourceRoot != null) {
      if (!isFvmSanad) {
        fail(`task ${item.id} sourceRoot is only valid for the fvm source-development invocation`);
      }
      if (typeof item.sourceRoot !== 'string' || !isAbsolute(item.sourceRoot)) {
        fail(`task ${item.id} sourceRoot must be an absolute path`);
      }
      if (!existsSync(item.sourceRoot) || !statSync(item.sourceRoot).isDirectory()) {
        fail(`task ${item.id} sourceRoot must be an existing directory: ${item.sourceRoot}`);
      }
      spawnCwd = resolve(item.sourceRoot);
    }

    if (isFvmSanad) {
      // Fail closed when the spawn root does not contain the requested source
      // entry point; this replaces the external batch-wrapper workaround that
      // previously hid which checkout provided the CLI.
      const entryPath = resolve(spawnCwd, item.args[2]);
      if (!existsSync(entryPath) || !statSync(entryPath).isFile()) {
        fail(`task ${item.id} source entry point not found: ${item.args[2]} (relative to ${spawnCwd})`);
      }
    }

    // Requiring `run` as the first Sanad subcommand structurally prevents this
    // invocation from reaching any `workspace create/add/select/switch` command.
    // Do not scan flag values for those words: they are valid workspace IDs.
    if (item.args.some((a) => /^--(api-key|secret|token|password)/i.test(a))) {
      fail(`task ${item.id} must not pass credentials via command args`);
    }

    // Explicit custom-Home propagation (97x): a detached worker must attach to
    // the declared managed Home instead of falling back to a default that may
    // conflict with an active daemon (observed standalone/exit 78). The value
    // is injected as `--home`; a relative, missing, or duplicated declaration
    // fails closed so delegation never runs against the wrong Home.
    const hasHomeArg = item.args.some(
      (arg) => arg === '--home' || (typeof arg === 'string' && arg.startsWith('--home=')),
    );
    if (hasHomeArg) {
      fail(`task ${item.id} declare the custom Home via task.home, not a --home argument`);
    }
    if (customHome != null) {
      if (typeof customHome !== 'string' || !isAbsolute(customHome)) {
        fail(`task ${item.id} home must be an absolute path`);
      }
      if (!existsSync(customHome) || !statSync(customHome).isDirectory()) {
        fail(`task ${item.id} home must be an existing directory: ${customHome}`);
      }
    }

    if (isRemoteClient) {
      // Remote delegation: the brief file is the only caller-side path. Device
      // ids, remote workspace ids, and remote execution roots describe the
      // target machine, so they are never resolved, canonicalized, or compared
      // with the local workspace here.
      const remoteWorkspace = getArgValue(item.args, item.id, '--workspace', '-w');
      const remoteExecutionRoot = getArgValue(item.args, item.id, '--execution-root');
      if (!remoteWorkspace && !remoteExecutionRoot) {
        fail(`task ${item.id} sanad-client task requires --workspace (remote workspace id) or --execution-root`);
      }
      const remoteBriefFile = getArgValue(item.args, item.id, '--brief-file', '-b');
      if (!remoteBriefFile) {
        fail(`task ${item.id} sanad-client task requires --brief-file`);
      }
      // `sanad-client` reads the brief locally and relays only its content, so
      // this path is genuinely caller-side and must exist before dispatch.
      if (!isAbsolute(remoteBriefFile) || !existsSync(remoteBriefFile) || !statSync(remoteBriefFile).isFile()) {
        fail(`task ${item.id} --brief-file must be an existing absolute file path`);
      }
      if (!getArgValue(item.args, item.id, '--session', '-s')) {
        fail(`task ${item.id} sanad-client task requires --session`);
      }
      if (!item.args.includes('--json')) {
        fail(`task ${item.id} sanad-client task requires --json so the result envelope can be captured`);
      }
      if (!item.args.includes('--events')) {
        fail(`task ${item.id} sanad-client task requires --events so relayed lifecycle events stay observable`);
      }
      if (getArgValue(item.args, item.id, '--out-dir', '-o')) {
        fail(`task ${item.id} sanad-client task must not pass --out-dir; remote artifacts are written on the target device`);
      }
      if (item.timelinePath != null) {
        fail(`task ${item.id} sanad-client task relays its timeline on stdout; do not declare timelinePath`);
      }
      // The relayed stdout carries the NDJSON lifecycle events, so it becomes
      // the observed timeline, and the terminal `--json` envelope captured from
      // that same stream becomes the task result.
      timelinePath = null;
      timelineFormat = 'jsonl';
    } else {
      const logicalWorkspace = getArgValue(item.args, item.id, '--workspace', '-w');

      const execRoot = getArgValue(item.args, item.id, '--execution-root');
      if (!logicalWorkspace && !execRoot) {
        fail(`task ${item.id} sanad task requires --workspace or --execution-root`);
      }
      // A logical workspace may own the conversation while an explicit
      // execution root targets this task's isolated worktree. Whenever present,
      // validate that filesystem boundary even when --workspace is also present.
      if (execRoot) {
        if (!isAbsolute(execRoot)) {
          fail(`task ${item.id} --execution-root must be an absolute path`);
        }
        if (canonicalWorkspace(execRoot) !== workspace) {
          fail(`task ${item.id} --execution-root must match task workspace`);
        }
      }

      const briefFile = getArgValue(item.args, item.id, '--brief-file', '-b');
      if (!briefFile) {
        fail(`task ${item.id} sanad task requires --brief-file`);
      }
      if (!isAbsolute(briefFile) || !existsSync(briefFile) || !statSync(briefFile).isFile()) {
        fail(`task ${item.id} --brief-file must be an existing absolute file path`);
      }

      const outDir = getArgValue(item.args, item.id, '--out-dir', '-o');
      if (!outDir) {
        fail(`task ${item.id} sanad task requires --out-dir`);
      }
      if (!isAbsolute(outDir)) {
        fail(`task ${item.id} --out-dir must be an absolute path`);
      }

      const expectedResultPath = resolve(outDir, 'result.json');
      const expectedTimelinePath = resolve(outDir, 'events.jsonl');
      if (resultPath && resolve(resultPath) !== expectedResultPath) {
        fail(`task ${item.id} resultPath must match --out-dir result.json`);
      }
      if (timelinePath && resolve(timelinePath) !== expectedTimelinePath) {
        fail(`task ${item.id} timelinePath must match --out-dir events.jsonl`);
      }
      resultPath = expectedResultPath;
      timelinePath = expectedTimelinePath;
      timelineFormat = 'jsonl';
    }
  }

  return {
    id: item.id,
    implementer: item.implementer,
    workspace,
    sourceRoot: item.sourceRoot != null ? resolve(item.sourceRoot) : null,
    home: customHome != null ? resolve(customHome) : null,
    spawnCwd,
    command: item.command,
    args: item.args,
    // The task's declared Home is injected once, after validation, so the
    // worker always attaches to the managed custom Home. Nothing else may
    // pass --home (duplicates fail closed during validation).
    effectiveArgs: customHome != null ? [...item.args, '--home', resolve(customHome)] : item.args,
    resultPath,
    timelinePath,
    timelineFormat,
    // A per-task silence threshold overrides the run default. `progressStallMs`
    // is accepted directly so compressed-time tests do not need fractional
    // seconds.
    progressStallMs,
    // `null` inherits the run's auto-retry default; `false` opts one task out
    // of a run that enabled it.
    autoRetry,
    // Remote `sanad-client` tasks capture their result envelope from the relayed
    // stdout and derive both artifact paths inside the run directory.
    remote: remoteDevice != null,
    remoteDevice,
    knownIdentity: identityFor(workspace),
  };
}

export function validateSpec(raw, existingIds = new Set()) {
  if (!raw || !Array.isArray(raw.tasks)) {
    fail('spec must contain a tasks array');
  }
  const ids = new Set(existingIds);
  return raw.tasks.map((item) => {
    const task = validateTask(item, ids);
    ids.add(task.id);
    return task;
  });
}
