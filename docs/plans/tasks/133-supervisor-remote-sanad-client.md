---
title: "Task 133: Supervisor Remote Sanad Delegation via sanad-client"
description: "Extend delegate-task-supervisor with a supported remote Sanad form: sanad-client -d <device> run, strict relay validation, streamed relay observation, stdout result capture, and exit-code state mapping."
status: "in_review"
current_gate: "Writer round 1"
priority: "high"
depends_on: "Plan 102 (Remote CLI relay), Plan 126 (supervisor task Home)"
file_budget: 8
---

# Task 133: Supervisor Remote Sanad Delegation via `sanad-client`

## 1. Problem

`delegate-task-supervisor` accepted a Sanad task only as an installed `sanad run`
or as the source-development form `fvm dart run <entry>/sanad_agent.dart run`.
Both forms require `--execution-root` (or a registered `--workspace`) plus
`--out-dir`, and both derive `result.json`, `events.jsonl`, and their validation
from caller-side filesystem paths.

A remote task such as

```bash
sanad-client -d <device-id> run --workspace <remote-ws-id> \
  --brief-file <f> --session <id> --json
```

failed validation, so remote delegation had no durable manifest state, no
`watch-once` events, and no intervention detection. Operators had to run the
Client CLI by hand and observe it outside the supervisor contract.

## 2. Design

### 2.1. Accepted invocation form

`implementer: "sanad"` now accepts a third form:

| Element | Contract |
| --- | --- |
| `command` | `sanad-client` (optionally `sanad-client.exe`) or an explicit absolute path to a built binary. A command containing a path separator must be absolute. |
| Relay prefix | `-d <device-id> run` or `--device <device-id> run`, or `--device=<device-id> run`. No other subcommand is accepted. |
| Required flags | `--brief-file`, `--session`, `--events`, `--json`. |
| Target selector | `--workspace <remote-workspace-id>` or `--execution-root <remote-path>`; at least one. |
| Rejected | A second `-d`/`--device` (the Client CLI keeps the last value, which would retarget the validated device), `--out-dir`, `timelinePath`, `--home` in argv, credential flags, `sourceRoot`. |

Requiring `run` immediately after the device flag keeps the relayed argv inside
the one-shot surface, exactly like the installed `sanad run` form: a remote task
can never reach `workspace create/add/select/switch` or `session stop`.

### 2.2. Local vs remote validation boundary

- `workspace` (the task field) keeps its existing meaning: the supervisor's
  identity and spawn directory on the caller machine, and it still must exist.
- Device ids, remote workspace ids, and remote `--execution-root` values describe
  the target machine. They are never resolved, canonicalized, existence-checked,
  or compared with the local `workspace`.
- `--brief-file` is the one genuinely caller-side path, because `sanad-client`
  reads the file locally and relays only its content. It must be an absolute
  existing file, so a missing brief fails before dispatch instead of inside the
  relay.
- `home` stays supported and means the caller-side Sanad Home whose live Client
  owns the relay endpoint. It is injected as `--home` and exported as
  `SANAD_HOME` with any inherited `SANAD_STATE_HOME` removed, exactly as for a
  local task.
- Every existing local rule is untouched: `--workspace`/`--execution-root`
  requirement, execution-root/workspace equality, `--out-dir` derivation of
  `resultPath` and `timelinePath`, FVM entry-point checks, and `sourceRoot`
  ownership.

### 2.3. Process and stdin

Workers are spawned with stdin `ignore` for every implementer, so `sanad-client`
never blocks waiting for stdin EOF; the relay contract is unchanged and the
behaviour is now asserted by the fixture, which reads fd `0` synchronously and
would hang if the supervisor ever left a pipe open.

### 2.4. Observation: streamed relay, no file tail

Remote tasks carry `remote: true` and `remoteDevice` in the manifest. Their
artifact paths are derived in the run directory (`<task>.stdout.log`,
`<task>.stderr.log`, `<task>.result.json`), and their observed timeline is the
relayed stdout log.

A first implementation pointed the existing `fs.watch` timeline observer at that
stdout log. It lost every relayed event: the worker opens the log before spawn,
and macOS coalesced the file notifications of a fast relay (`needs_input` written
at `T+3 ms`, envelope at `T+403 ms`) past the terminal transition, so no
intervention was ever journaled. Remote relay tasks therefore spawn with
`stdio: ['ignore', 'pipe', 'pipe']`: the worker mirrors both streams into the
task logs and parses complete stdout lines live through the same
`createTimelineHandler` used by file-tailed local timelines, so both paths
produce identical journal transitions. The terminal transition waits for
`close` (all pipes drained) instead of `exit`, which also guarantees the envelope
is complete before capture. Local tasks keep writing straight to their log fds,
so a worker death cannot stall a local implementer.

### 2.5. Result capture

The relayed terminal `--json` envelope is captured into `resultPath` at the end
of the run: the last compact JSON object on stdout without a `type` field that
carries `exit_code` or `session_id` (relayed lifecycle events always carry
`type`), with a whole-document parse fallback for a pretty-printed envelope.
Session identity is recorded through the normal `recordIdentity` path, so
`supervisor identity` and `status` show the remote session id that
`sanad-client session answer/stop` can still address.

### 2.6. State mapping

Remote exit codes replace the generic success/failure split:

| Exit | Status | Cause |
| --- | --- | --- |
| `0` with captured envelope | `completed` | - |
| `0` without an envelope | `incomplete` | `missing_result_envelope` |
| `124` | `timeout` | `timeout` |
| `130` | `cancelled` | `cancelled` |
| `69` | `blocked` | `client_unavailable` |
| `77` | `blocked` | `client_cli_disabled` |
| other non-zero | `failed` | - |

Blocked tasks also record the last stderr line (bounded to 400 characters) as
`error`, so the operator sees the Client's own diagnostic
(`No active Sanad Client found ...`, `Client CLI is disabled ...`). A local
`result.json` status always wins when present, so a future remote artifact
producer is not overridden.

`watch-once` now also wakes on the terminal `incomplete` and `needs_review`
statuses it already recorded; without that, the new `incomplete` mapping (and
the pre-existing local `missing_final` state) could only be observed by polling.

## 3. Files Changed

- `.agents/skills/delegate-task-supervisor/scripts/supervisor.mjs`: remote form
  detection and validation, `taskRunPaths`/`withRunPaths`, streamed relay
  observation, shared `createTimelineHandler`, envelope capture, exit-code
  mapping, stdin comment.
- `.agents/skills/delegate-task-supervisor/scripts/watch-once.mjs`: `incomplete`
  and `needs_review` wake statuses.
- `.agents/skills/delegate-task-supervisor/SKILL.md`: remote specification
  example, contract, mapping, and wake statuses; version `0.3.0`.
- `.agents/skills/sanad-delegate/SKILL.md`: section 6.8 supervised remote
  delegation.
- `.agents/skills/delegate-task-supervisor/test/supervisor_test.mjs`: remote
  validation, streamed run/capture/identity, exit-code mapping, and watch-once
  terminal wake tests.
- `docs/technical/remote_cli_relay_protocol.md`: observed relay limits (fixed
  300-second request timeout, zero exit without a result frame).
- `docs/llms.txt`: index entry for this task.
- `docs/plans/tasks/133-supervisor-remote-sanad-client.md`: this record.

No product code changed: `agent/` and `client/` are untouched.

## 4. Definition of Done

- [x] (a) A `sanad-client -d <id> run ...` spec validates, records `remote` and
  `remoteDevice`, and derives its result and timeline paths in the run directory.
- [x] (b) Malformed remote forms fail closed: wrong subcommand, missing device,
  duplicate device, relative binary path, missing `--workspace`/`--execution-root`,
  missing or non-existing brief, missing `--session`/`--json`/`--events`,
  `--out-dir`, declared `timelinePath`, `sourceRoot`, `--home` in argv,
  credentials, relative `home`.
- [x] (c) Relay validation still accepts an opaque remote workspace id and a
  non-existent remote `--execution-root`, proving no local path validation.
- [x] (d) A relayed `needs_input` event wakes `watch-once` before completion, and
  the captured envelope, session identity, `resultCaptured`, and completion state
  are asserted end to end.
- [x] (e) Exit codes `124`/`130`/`69`/`77` and a silent zero exit map to
  `timeout`/`cancelled`/`blocked (client_unavailable)`/`blocked
  (client_cli_disabled)`/`incomplete (missing_result_envelope)` with the Client
  diagnostic preserved.
- [x] (f) `watch-once` wakes on journaled `incomplete` and `needs_review`.
- [x] (g) The skill's Node test suite passes with no new failures against the
  recorded `origin/main` baseline.

## 5. Known Limits

- The Client CLI currently sends a fixed `timeout_seconds: 300` per execution
  request, so a remote run longer than five minutes settles as `timeout` even
  when the remote Agent would continue. Documented in the relay protocol and both
  skills; lifting it is product work outside this task.
- A remote task cannot produce local `--out-dir` artifacts; results are the
  captured `--json` envelope plus the mirrored logs and the journal.
- Windows `.cmd` relay wrappers still go through the existing shell-mode path;
  the remote form was verified with a POSIX wrapper in the suite.

## 6. Round Log

### Round 1 - writer

- Red baseline (skill suite from `origin/main` `182d6a40`, unchanged scripts):
  `18` tests, `15` pass, `3` fail. All three failures are the pre-existing macOS
  `/var` -> `/private/var` canonicalization assertions (`isolated workspaces do
  not collide ...`, `sanad sourceRoot separates ...`, `sanad root-only
  targeting ...`), matching the known baseline recorded in Task 126.
- Implemented the remote form, derived artifact paths, streamed relay
  observation, envelope capture, and exit-code mapping.
- First attempt reused the file-tailing observer against the task stdout log and
  lost every relayed event (journal showed only `running` -> `completed`). Root
  cause reproduced with a standalone `fs.watch` probe: macOS coalesced the
  notifications of a file the worker itself had opened, and the terminal
  transition closed the watcher before delivery. Switched remote tasks to piped
  `stdio`, mirrored streams plus a shared per-line handler, and `close`-driven
  termination. The relay test then observed `needs_input` before completion.
- Green: skill suite `22` tests, `19` pass, same `3` pre-existing macOS failures,
  all four new tests passing. No new failure introduced. Repeated three times for
  stability: `19`/`3` each run.
- Live checks with a scratch orchestration root outside the repository: a relayed
  `needs_permission` woke `watch-once` (`seq 2`), the task then settled
  `completed` with `Observation Source: result.json`, and `timeline` showed the
  relayed events; a mock Client exiting `77` settled `blocked`,
  `cause: client_cli_disabled`, with the Client's own stderr line as `error`.
- Product-code reading that shaped the contract (no product edits): the Client
  CLI hardcodes `timeout_seconds: 300`, resolves `--brief-file` locally, prints
  relayed events on stdout only when `--events` is present, and completes `0`
  when the control socket closes without a result frame.
- Deliverable: one commit on `feat/supervisor-remote-sanad-client`; no push, no
  runtime restart, no `sanad-dev` action, and no `~/.sanad` access.
