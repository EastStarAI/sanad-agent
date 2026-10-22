---
id: 130
title: Client CLI relay reliability (release blocker)
status: in_review
gate: coordinator review open
created: 2026-10-22
parent_task: docs/plans/102-client-cli-remote-relay-and-desktop-tray.md
depends_on: []
delivery: own PR
---

# Task 130 — Client CLI Relay Reliability

## Goal

Remove five defects found live on 2026-10-22 while relaying `sanad-client`
commands from a macOS Client to a Windows Agent. Every defect is in the relay
pair: the caller (`client/lib/features/client_cli/cli/sanad_client_runner.dart`),
the Client CLI host (`client/lib/features/client_cli/data/client_cli_host.dart`),
or the contract that ties them together
(`docs/technical/remote_cli_relay_protocol.md`). The Agent's remote CLI handler
needed no behavior change; it gained one contract test.

Dashboard:

| # | Severity | Defect | Status |
|---|---|---|---|
| RD7 | High | The caller hard-codes `timeout_seconds: 300`, so every relayed command is killed after five minutes with exit `124`, including `run --timeout 5400` | fixed |
| RD2 | Medium | With a non-TTY standard input that never reaches EOF, `run --brief-file` blocks reading stdin and sends nothing | fixed |
| RD1 | Medium | While a Default-mode approval is pending the caller prints nothing | fixed |
| RD3 | Medium | After a terminal `blocked` run (provider HTTP 410) `run --events` never produced a caller exit | fixed (terminal-result guarantee) |
| RD4 | Medium | An unknown/extra remote subcommand (`providers list`) appeared to hang instead of returning promptly | fixed (same stdin root cause as RD2) |

## Shared owner

`client/lib/features/client_cli/domain/models/client_cli_relay_policy.dart` is the
new single owner for the two caller decisions that must agree with the protocol:

- `clientCliRelayTimeoutSecondsFor(argv)` — the relay window;
- `clientCliRelayConsumesStdin(argv)` — whether standard input is the prompt;
- `clientCliForwardStdinFlag` / `clientCliStripHostFlags` — the host-local
  `--stdin` opt-in;
- `clientCliApprovalPendingStatus` / `clientCliApprovalPendingMessage` — the
  approval-pending status code and text shared by the caller and the host.

## RD7 — The relay window ignored the command's own timeout (High)

### Root cause

`sanad_client_runner.dart` sent a literal `'timeout_seconds': 300`. The protocol
gives that field the meaning "this execution may run for N seconds" (1..86400,
default 300), and the Agent's `RemoteCliCommandHandler` enforces it with its own
timer. A forwarded `run --timeout 5400` therefore declared a 90-minute command
runtime and a 5-minute relay window; the relay timer fired first, signalled the
in-process CLI with SIGINT, and emitted `device.cli.result` with `exit_code: 124`
and `timed_out: true`. The Agent then wrote a `timeout` status artifact for a run
that was still inside its negotiated runtime, and the caller reported a false
timeout.

### Fix

- The caller derives the window from the forwarded command's own `--timeout`
  (last occurrence wins, `--` ends option scanning) plus a 30-second grace, so the
  command's scoped stop, artifact write, and terminal result finish before the
  relay window closes.
- Without a usable `--timeout` the protocol default (300 s) stays in force; a
  value the command itself rejects (`0`, `-30`, `forever`, a trailing
  `--timeout`) falls back to the default or to the bounded grace window, so the
  Agent's own usage error is relayed instead of being masked by a relay timeout.
- The result is always clamped to 1..86400.
- The Agent keeps its own validation of the received value; the host keeps
  forwarding it unchanged.

### Tests

`client/test/unit/client_cli/client_cli_relay_policy_test.dart` (window
derivation, default, last-wins, `--` terminator, rejected values, clamping) and
`client/test/unit/client_cli/sanad_client_relay_caller_test.dart`
("forwards the command timeout as the relay window" asserts `5430` for
`--timeout 5400`; "keeps the protocol default window without a command timeout").

## RD2 — A never-closing standard input blocked the relay (Medium)

### Root cause

The caller read piped standard input whenever `stdin.hasTerminal == false`, with
no regard for whether the forwarded command consumes it:

```dart
if (effectiveStdin == null && !stdin.hasTerminal) {
  effectiveStdin = await stdin.transform(utf8.decoder).join();
}
```

A background job (supervisor, CI, an agent tool call) owns a pipe that stays
open, so `join()` never completed. The request was never sent, so
`run --brief-file` produced no output and the remote session stayed idle.

### Fix

- Standard input is read only when the command can consume it:
  `run`/`chat`/`cli` with no `--brief-file`, no `--prompt`, and no positional
  prompt.
- Everything else forwards `stdin: null` and sends immediately.
- `--stdin` forces the read for a command that already carries its prompt. It is
  host-local and stripped before forwarding, because the Agent CLI does not
  define that option.
- The read is now behind an injectable `ClientCliStdinReader` seam, so a unit
  test can prove the caller never waits on it.

### Tests

`client_cli_relay_policy_test.dart` (`clientCliRelayConsumesStdin`, flag
stripping) and `sanad_client_relay_caller_test.dart`:

- "a brief-file run never waits for standard input" — brief content is relayed,
  `stdin` is null, the reader is never called;
- "a command that takes no prompt never waits for standard input" — a reader
  that never completes does not prevent the request from being forwarded;
- "a run without a prompt still forwards piped standard input" — the piped text
  is relayed once, so real piping keeps working;
- "an explicit --stdin forces forwarding and is not relayed as argv".

## RD1 — The approval wait was invisible to the caller (Medium)

### Root cause

In `default` permission mode the host awaited
`ClientCliApprovalCoordinator.requestApproval` before it forwarded anything, and
sent no frame while it waited. A headless caller therefore printed nothing until
the user answered, which reads as a hang.

### Fix

- The host emits one host-to-caller `status` frame with
  `code: approval_pending` immediately before it asks for approval, and skips it
  when the session is already approved.
- The caller prints that message once on standard error. It never writes it to
  standard output, so `--json` output stays parseable, and it honours `--quiet`.

### Tests

- Host: `client/test/unit/client_cli/client_cli_host_test.dart`, "default mode
  announces the pending approval before it prompts" (a `status` frame arrives
  before the result, and the overlay is still requested).
- Caller: `sanad_client_relay_caller_test.dart`, "announces a pending approval
  once on stderr, never on stdout" (exactly one stderr line, clean `--json`
  stdout).

## RD3 — A relayed run could end without a caller exit (Medium)

### Root cause

The caller had two ways to finish without knowing the outcome:

1. `onDone` completed the process with `0`, so a relay that closed without a
   terminal frame reported success;
2. nothing on the host side noticed that the device event stream — the only
   delivery path for `device.cli.result` — had ended before the Agent reported an
   outcome. The caller then waited for a result that could never arrive.

Both are reachable in the live shape reported here. A provider HTTP 410 is
classified as `RuntimeFailureReason.unknown`, whose decision is
`RuntimeNoticeStatus.blocked`; the Agent deliberately treats `blocked` as
non-terminal (`CliRuntimeNoticeEvent.isRecovering`, `recordRuntimeNotice`) because
a user can retry the session from the Client. A relayed run has no intervention
channel of its own, so the outcome can only be reported when the run ends, and
the delivery path must therefore be fail-closed. Changing `blocked` to terminal
for every CLI would rewrite the documented resumption contract for local `sanad
run` and the delegation supervisor, which is out of scope here and is recorded as
a follow-up decision instead.

### Fix

- Host: exactly one terminal frame per request. If the device event stream ends
  or fails before the Agent reports an outcome, the host emits a terminal
  `result` with `exit_code: 1` and an explanatory error, then closes the caller
  socket. All host terminal paths (result, error, denial, missing/unknown device,
  offline device, lost stream) now go through one `sendTerminalFrame` guard, so a
  late or duplicate frame can never be sent.
- Caller: a socket that ends without a terminal frame prints
  `The relay ended without a terminal result ...` on standard error and exits
  non-zero. A terminal result still wins with its own exit code.

### Tests

- Host: "a relay whose device event stream ends still returns one terminal result"
  (the fake device transport is disposed after the command is dispatched; the
  caller receives exactly one result with a non-zero code and the explanatory
  error).
- Caller: "fails closed when the relay ends without a terminal result".

## RD4 — An extra subcommand token appeared to hang (Medium)

### Root cause

The live symptom was the RD2 stdin block, not the Agent's command parser: the
caller never forwarded `providers list`, so no result could come back. The
Agent's own behavior is deterministic and fast:

| Forwarded argv | Local CLI result |
|---|---|
| `providers list` | runs `providers` and exits `0` (a token after a command that declares no subcommands is accepted) |
| `nope` | usage error, exit `64` |
| `ws nope` | runs the workspace list, exit `0` |
| `session nope` | error listing sessions, exit `1` |

Measured with an isolated `SANAD_HOME`: 6–7 s per invocation including process
startup, no hang.

### Fix

- No Agent change. The caller-side stdin gate from RD2 removes the hang, and the
  caller exits with whatever code the terminal result carries.
- Documentation records that a token after a subcommand-less command is accepted
  and exits `0`, so an orchestrator does not wait for a usage error that the CLI
  never produced.

### Tests

- Caller: "a command that takes no prompt never waits for standard input" —
  `providers list` is forwarded while a never-completing stdin read is pending,
  and the caller exits with the relayed code (`64` in the test).
- Agent: `agent/test/interfaces/platforms/sanad_gateway/handlers/remote_cli_command_handler_test.dart`,
  "returns the CLI usage exit code as one terminal result for a rejected argv" —
  exactly one terminal result with `exit_code: 64` and non-empty stderr usage
  text.

## Untouched boundaries

- The Agent's `blocked`/`waiting`/`resuming` runtime-notice contract, its
  intervention and retry flow, and the delegation supervisor's waker states are
  unchanged.
- Provider, permission, session, and workspace authority stay Agent-owned. The
  Client still relays without persisting command payloads, and no argv, stdin,
  brief content, or token is logged.
- The relay payload schema is unchanged except for the new host-to-caller
  `status` frame and the caller-side `--stdin` opt-in.

## Verification

| Gate | Result | Log |
|---|---|---|
| `fvm flutter analyze` (client) | no issues | `temp/130/client-analyze.log` |
| `fvm dart analyze` (agent) | no issues | `temp/130/agent-analyze.log` |
| Client CLI unit tests (`test/unit/client_cli/`) | 57 passed | `temp/130/client-cli-unit-green.log` |
| Client CLI widget tests (`test/widget/client_cli/`) | 8 passed | `temp/130/client-cli-widget-green.log` |
| Client full suite | 2,029 passed | `temp/130/client-suite.log` |
| Agent relay handler tests | 26 passed | `temp/130/agent-relay-green.log` |
| Red evidence before the fixes | 8 failed, 24 passed | `temp/130/red.log` |
| `fvm dart scripts/lint_wiki.dart` | success | — |

Red-first sequence for the code fixes: the injectable `ClientCliStdinReader` seam
landed first with the old behavior intact, then the eight new behavior tests were
run against that state and failed (relay window, brief-file stdin, no-prompt
stdin, `--stdin`, approval notice on both sides, caller fail-closed, host
liveness). Applying the fixes turned the same suite green. The policy unit tests
are specification coverage for the new owner, not red-first evidence.

Red failures (`temp/130/red.log`):

- `ClientCliHost a relay whose device event stream ends still returns one terminal result`
- `ClientCliHost default mode announces the pending approval before it prompts`
- `SanadClientRunner remote relay a brief-file run never waits for standard input`
- `SanadClientRunner remote relay a command that takes no prompt never waits for standard input`
- `SanadClientRunner remote relay an explicit --stdin forces forwarding and is not relayed as argv`
- `SanadClientRunner remote relay announces a pending approval once on stderr, never on stdout`
- `SanadClientRunner remote relay fails closed when the relay ends without a terminal result`
- `SanadClientRunner remote relay forwards the command timeout as the relay window`

Every test run used a temporary `SANAD_HOME`/`SANAD_STATE_HOME`; the live
`~/.sanad` Home and the running Client were never touched. `HOME` is preserved
for FVM's SDK resolution, which is why the Home override is applied through
`SANAD_HOME` rather than `HOME`. No runtime, daemon, or Client process was
started, restarted, or stopped.

Graphify: this linked worktree has no `graphify-out/` corpus (the project corpus
lives only in the primary checkout, which this task must not modify), so there is
no graph to update for these paths.

## Round Log

| Round | Candidate | Result |
|---|---|---|
| r1 | `182d6a40` + this branch | Five defects fixed red-first. 8 failing behavior tests before the fixes; Client CLI unit/widget suites, the full Client suite, and the Agent relay tests green after them. |
| r1 review | same branch | Full-diff review kept every hunk: they are the Task 130 design. Three corrections applied — the host keeps the original `protocolError` close codes for rejected targets, the unused `clientCliExecutionStartedStatus`/`clientCliStripHostFlags` helpers were dropped, and the QA exit-code row for `124` was reworded. Live re-verification on macOS → Windows was still pending at that point; r2 covers the caller half. |
| r2 | `4c7abab1` (caller built once) | Live caller-side check macOS → Windows: RD7 PASS (410 s, one 404 s command, exit 0, `RD7-OK`), RD2 PASS (`running` at +0 s, `RD2-OK`, exit 0, 3 s), RD4 PASS (1 s exit 0; 1 s exit 64 for a rejected argv), RD3 caller half PASS by controlled reproduction (exit 1 plus diagnostic). RD1 and the RD3 host guarantee NOT RUN — the live Client's host code is main. |
| r3 | `96fa4074` (host: TH2, Client CLI enabled in Default mode) | Live host-side check macOS Client → Windows device. RD1 PASS: exactly one `Waiting for approval in Sanad Client...` on stderr while pending (+4 s), clean `--json` stdout, exit 0 (+8 s) after hotkey 1. RD1 deny PASS: exit 1, 0 bytes on stdout, `Command rejected by user in Sanad Client.`, and no remote execution (device `session list` 10 → 10, no new id, no probe text). RD3 host guarantee NOT RUN (no lever ends the device stream without touching another runtime). Duplicate `--events --json` lines REPRODUCE with the branch host; narrowed to missing `event_id` on run lifecycle events, upstream of the relay pair. |

### Live re-verification — caller side (2026-10-22)

Ran the branch's `sanad-client` (built once from `4c7abab1`) against the user's running main Client (default
Home, Settings > Client CLI = Full Access) and the Windows device `22dbc6cd-f1cb-4849-b9f8-83c732be0fcd`,
workspace `5e01ed0a-8af0-4fa5-b3cd-3753d9cf4aca`, with `--thinking-mode max` on every run. Artifacts live in
`/Users/ahmedattia/.sanad-delegate/runs/release-gate/live-130/` and `RESULT.md` there holds the per-scenario
evidence.

- **RD7 PASS** — `--timeout 900` with a brief that made the Agent run one `ping -n 400 127.0.0.1 >nul`. The
tool's own result reports `duration_ms: 404120`; the run completed at caller +410 s with exit `0` and text
`RD7-OK`. It outlived the old 300 s window by 110 s instead of being cut with `124`.
- **RD2 PASS** — with the caller's standard input a FIFO that never reaches EOF, the device started the run at
+0 s and returned `RD2-OK` with exit `0` at +3 s; no stdin wait.
- **RD4 PASS** — `providers list` returned exit `0` in 1 s (the remote command itself prints nothing; `ws list`
returns real output through the same path), and a rejected trailing flag returned exit `64` in 1 s with the
remote usage text relayed.
- **RD3 caller half PASS** — against an isolated stub endpoint under an isolated Home, a relay that closed
after the `execute` frame made the caller print `Error: The relay ended without a terminal result …` on
standard error and exit `1`. This is a controlled reproduction, not a real device relay.
- **RD1 and the RD3 host-side terminal-frame guarantee: NOT RUN.** Both live in host code and the running
Client is main (and in Full Access, so no approval wait exists). They need a Client built from this branch.

Hygiene: nothing was written to `~/.sanad`, no Client, daemon, runtime, or process was started or stopped, and
a concurrent session's caller relaying to the same Windows device was left untouched. One observation for
triage, unrelated to the five defects: under `--events --json` each event line is printed twice (identical in
RD2 and RD7) while the final JSON envelope appears once, so an NDJSON consumer sees duplicates.

### Live re-verification — host side (r3, 2026-10-22)

The branch client was loaded into Test Home TH2 (`.agent/worktrees/test-home-2`, branch `test/test-home-2`,
Home `~/.sanad-test-2`, port 58124, cloud) with `git reset --hard 96fa4074` on the branch, its Client was
restarted, Settings > Client CLI was enabled in **Default** mode (previous state: disabled), and the caller was
built once from the same commit. Artifacts: `/Users/ahmedattia/.sanad-delegate/runs/release-gate/live-130h/`.

- **RD1 PASS.** `ws list --json` against the Windows device announced `Waiting for approval in Sanad Client...`
  on stderr **exactly once** (+4 s, while the overlay was still pending), then after hotkey 1 returned clean
  `--json` stdout and exit `0` (+8 s). Nothing from the notice reached standard output.
- **RD1 deny PASS.** A relayed `run` denied with hotkey 3 exited `1` with **no stdout bytes** and
  `Command rejected by user in Sanad Client.` No remote execution was proved on the device: `session list`
  returned 10 sessions before and after with no new id, and no session contains the probe text.
- **RD3 host guarantee NOT RUN.** Nothing in the product can end the device event stream while the host stays
  alive: the Client has no cloud on/off control (only sign-out, which testers must not use), restarting or
  killing the Client removes the host that must emit the terminal frame, and taking the Windows device offline
  would disrupt a shared device that was in active use during the round. A network-level drop would affect
  `main`, TH1, TH3, and the running session. The guarantee therefore keeps only its
  `client_cli_host_test.dart` coverage; a product "disconnect cloud" action or a QA-only stream-drop extension
  would make it live-testable.
- **Duplicate `--events --json` lines REPRODUCE with the branch host** (`running` ×2, `completed` ×2, envelope
  ×1) and are **not** a Task 130 regression: the caller prints one line per frame, the host forwards each
  matching device event once, and the socket deduplicator keys on `event_id` while run lifecycle events carry
  none — so the duplicate arrives over two delivery paths upstream of the relay pair. Left as an unrelated Low
  for its own triage entry.

Teardown: Client CLI restored to disabled, TH2 reset to `dc7ee42f` on `test/test-home-2`, Client restarted and
verified healthy, worktree unlocked. `~/.sanad`, port 58085, and every other runtime were untouched.

### Worktree overlap (2026-10-22 00:54–00:59 UTC)

A second, now-stopped session (`oneshot-4511a2d2`) was editing this same worktree
by mistake during that window. Recovery: `git status` and the complete `git diff`
were reviewed hunk by hunk against this task's design before anything else was
written. Every hunk in the working tree belongs to the design below (caller
policy owner, runner seam and gates, host status/liveness frames, tests, docs);
no foreign hunk, stray file, or partial edit was found, and nothing was reverted.
The review pass above then applied the three corrections. The red-first evidence
in `temp/130/red.log` and every gate log were produced after that review, from
this single coherent working tree.
