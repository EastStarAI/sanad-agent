---
title: "Develop Sanad Agent"
description: "Set up the public repository, run the Dart agent and Flutter client, test changes, and use isolated development runtimes."
---

# Develop Sanad Agent

This guide is for contributors building Sanad from source. Users installing a
release should follow [Install and Use Sanad Agent](user_guide.md).
Source development uses `sanad-dev`; it does not require a release-installer
pairing token.

## Repository structure

- `agent/` — Dart CLI and background agent.
- `client/` — Flutter client for desktop, mobile, and web.
- `docs/` — product, technical, operations, and QA documentation.
- `scripts/` — development, documentation, and release helpers.

All commands in this guide start from the public repository root unless the
step explicitly changes directory.

## Requirements and one-command bootstrap

To run the bootstrap and build components successfully, ensure your platform meets the prerequisites:

### macOS Requirements
- **Xcode Command Line Tools:** Required to run and compile macOS desktop applications. You can install them by running:
  ```bash
  xcode-select --install
  ```
- **System tools:** `curl` is used by the bootstrap script and is pre-installed on macOS by default.

### Linux Requirements
- **System tools:** Ensure `curl` is installed (required by bootstrap to download FVM if not present on your system).
- **Flutter Linux Toolchain:** Install the prerequisites needed to compile Flutter desktop applications. On Ubuntu/Debian-based distributions, you can install all required dependencies (including the `lld` linker) with:
  ```bash
  sudo apt update && sudo apt install -y curl clang cmake ninja-build pkg-config libgtk-3-dev lld
  ```

---

From a fresh checkout, install the user command once. On macOS or Linux:

```bash
scripts/sanad-dev install
```

On Windows PowerShell:

```powershell
.\scripts\sanad-dev.ps1 install
```

After installation, the official source command is:

```bash
sanad-dev run
```

The command contract is layered and explicit:

- `sanad-dev` with no arguments displays help and performs no mutation.
- `sanad-dev install` installs or verifies FVM `4.1.2`, the Flutter version from
  `.fvmrc`, and the checkout-owned user shim, then stops.
- `sanad-dev setup` ensures the install layer, resolves the shared Release
  Contract before Agent and Client packages, then stops without a runtime.
- `sanad-dev run` ensures only missing or stale install/setup stages, then starts
  the requested runtime target.

Add `--force` to explicit `install` or `setup` only when replacing a user
command owned by another checkout. `run` accepts an already-functional shim
owned by the checkout that dispatched it, so linked worktrees do not fight over
the user command. FVM archives come from the official GitHub Release
and use pinned per-platform SHA-256 digests. No stage requests `sudo` or
administrator access. Every stage that performs work streams the child process's
real stdout/stderr, then prints its elapsed time and final result. Already-valid
stages remain silent, including the ready FVM check. The setup stamp binds the
Flutter pin and all three `pubspec.lock` digests; valid package configs allow
unchanged stages to be skipped. A failed stage blocks every dependent stage and
runtime launch.

The POSIX user bin is `${XDG_BIN_HOME:-$HOME/.local/bin}` and the Windows user
bin is `%LOCALAPPDATA%\SanadDev\bin`. PATH changes affect new terminals; follow
the printed refresh guidance for the current shell. The agent creates its user
configuration from the embedded template on first run. Never commit provider
keys, Sanad tokens, or generated user state.

## Run a matched agent and client

Use the repository launcher for normal development:

```bash
sanad-dev run
```

The default target is `all`, which starts the Agent and one Client
concurrently. From the repository root, list available Flutter targets and
select one explicitly when needed; these commands are identical on every
platform after bootstrap:

```text
fvm flutter devices
sanad-dev run all -d <device-id>
```

Add another managed Client, or inspect the complete component inventory, with:

```bash
sanad-dev run client -d <device-id>
sanad-dev status
```

The default source profile is `client/config/prod.json`, which enables direct
local communication and Sanad's public Production services. Use
`client/config/dev.json` explicitly only when testing compatible hosted-service
integration. For a local-only run:

```bash
sanad-dev run --no-cloud
```

The `scripts/sanad-dev` wrapper is the macOS/Linux bootstrap and runtime entry
point. `.\scripts\sanad-dev.ps1` provides the equivalent Windows PowerShell
path. After setup, new terminals on every platform can use the installed
`sanad-dev` shim. The tracked VS Code tasks remain available after FVM is
ready.

The application can start without a model provider. Configure a local or
hosted provider before sending a model-backed request.

## Use the tracked VS Code workflow

The repository tracks a small, portable `.vscode/` allowlist. Install the
recommended Dart and Flutter extensions, then run one of these tasks from
**Terminal → Run Task**:

- `Sanad: Run Managed Full Pair` — start the managed local and cloud
  development pair;
- `Sanad: Run Managed Full Pair (Local Only)` — start the managed pair with
  cloud disabled;
- `Sanad: Status` — read the runtime selected for this workspace;
- `Sanad: Doctor` — diagnose ownership without mutating live processes;
- `Sanad: Analyze Agent` and `Sanad: Analyze Client` — run the owning FVM
  analyzers.

The run tasks call the repository's Dart entry point through FVM and preserve
the opened repository as `SANAD_DEV_CALLER_DIR`. This avoids shell-specific
launch wrappers and keeps clone/worktree detection identical on macOS, Linux,
and Windows. They intentionally do not provide shortcuts for source switch,
stop, restart, takeover, orphan cleanup, or any other ownership-sensitive
mutation.

For breakpoint debugging, open **Run and Debug** and choose one of the tracked
launch configurations:

- `Sanad: Launch Agent (Manual Debug)`;
- `Sanad: Launch Client (Manual Debug)`;
- `Sanad: Launch Full Pair (Manual Debug)` — a compound that starts both and
  stops both when the debug session ends;
- `Sanad: Attach to Running Client` — attach to an existing Flutter VM service.

The launch and compound configurations are intentionally manual runtimes. They
are useful for breakpoints and IDE lifecycle control, while the tasks above are
the normal managed path. A complete manual Agent/client pair may later be
converted through `sanad-dev doctor` followed by an explicitly authorized
`sanad-dev takeover`; takeover performs a controlled relaunch rather than
silently claiming IDE processes.

When driver instrumentation is required, start the managed pair from a terminal
and attach to its VM-service endpoint:

```bash
sanad-dev run --driver
sanad-dev status
```

A standalone clone still fails closed if another workspace owns the primary
Home or endpoint. Linked worktrees and conflicting clones should use the
managed tasks or an explicit absolute `--home`, not the manual compound with
primary defaults. Never place credentials, provider configuration, machine
paths, or personal task overrides in tracked `.vscode` files.

## Run one component manually

Use manual component commands when diagnosing the launcher or a single
process.

Agent daemon:

```bash
cd agent
fvm dart run bin/sanad_agent.dart daemon
```

Interactive agent CLI:

```bash
cd agent
fvm dart run bin/sanad_agent.dart chat
```

Flutter client on macOS:

```bash
cd client
fvm flutter run --dart-define-from-file=config/prod.json -d macos
```

Replace `macos` with another configured Flutter device when working on
Windows, Linux, Android, iOS, or web.

### Check the local daemon

The normal local endpoint starts at port `58085`. Development worktrees may
receive another port, so prefer `sanad-dev status` when the matched
runtime was started through the launcher.

For a manually started daemon, inspect the health response directly:

```bash
curl http://127.0.0.1:58085/health
```

The response identifies the runtime version, local endpoint, and whether the
agent is running from source. This is useful when the client finds an existing
process or reports an endpoint mismatch.

### Avoid a service/source port conflict

An installed background service and a manually started source daemon must not
claim the same local port. Use the agent CLI to inspect and stop the installed
service before source debugging:

```bash
sanad service status
sanad service stop
```

Restore it after the source run:

```bash
sanad service start
```

The service command owns the platform-specific launchd, systemd, or Windows
Scheduled Task integration. Direct operating-system commands are useful only
when diagnosing a broken service registration.

## Source-build authentication

`sanad-dev run` uses the public Production Portal and Gateway by default. Sign
in with your Sanad account when testing connected features. Local-only
development does not require hosted-service source code or authentication.

To start agent login directly:

```bash
cd agent
fvm dart run bin/sanad_agent.dart login
```

Authentication and provider credentials belong to the selected Sanad Home and
must remain outside Git and logs.

## Worktree isolation

Each linked worktree run receives:

- its own local daemon and Flutter VM-service ports;
- its own Sanad Home for identity, providers, databases, memory, and dumps;
- its own runtime metadata, logs, and client preferences.

An independent clone is not a Git linked worktree. If another workspace already
owns the primary local endpoint, the clone fails closed instead of sharing that
runtime or the primary Sanad Home. Supply an explicit absolute `--home` to give
the clone a Home-derived preferences namespace and workspace-hashed agent and
VM-service ports. The conflict check also applies to dry-run and does not mutate
process state.

Do not edit tracked environment or Flutter configuration files to allocate
worktree ports.

Useful commands:

```bash
sanad-dev status
sanad-dev logs agent -n 50
sanad-dev logs client -n 50
sanad-dev restart agent
sanad-dev restart client
sanad-dev reload client
sanad-dev doctor
sanad-dev switch --runtime current
sanad-dev stop client -d macos
sanad-dev stop agent
sanad-dev stop all
```

`sanad-dev status` distinguishes the command worktree from the selected runtime
source and lists every client attached to the agent, including device id,
VM-service port, PID, source path, worktree marker, and switch capability.
`sanad-dev status --port <agent-port>` inspects that runtime even when invoked
from a different worktree.

Client discovery distinguishes managed, manual, orphaned, cross-owned,
unverifiable, and ambiguous runtime groups.
A source-matched client connected to another workspace agent is cross-owned;
a missing or contradictory launch profile is unverifiable. Status marks both
classes with `stop refused`, run never recommends `sanad-dev stop` for them, and
stop performs no child signals when ownership is not proven. A repeated `run`
is a successful no-op only for a healthy managed group. Managed `stop` writes a
nonce-bound request to the verified launcher and mutates only the selected
component target; omitting the target means `all`. Stop a manual process only
from its owning runtime or IDE session, or use the explicit takeover flow after
diagnosis. See
[sanad-dev Runtime Ownership](../technical/sanad_dev_runtime_ownership.md) and
[sanad-dev Runtime Ownership QA](../qa_maintenance/sanad_dev_runtime_ownership_qa.md)
for the identity model and hermetic regression matrix.

A primary-checkout Flutter client launched from an IDE may omit explicit local
gateway, Sanad Home, and preferences defines when it uses the application's
canonical defaults. `sanad-dev restart client` and `reload client` accept that
profile only when native process discovery ties it to the primary source tree,
the matched daemon is on the canonical primary port, and the runtime uses the
canonical primary Sanad Home. Explicit conflicts and every incomplete linked-
worktree profile still fail before attach.

### Command reference

The launcher supports:

```text
sanad-dev [command] [target] [options]

(no arguments)             Show help without changing the environment.
install [--force]          Install FVM, pinned Flutter, and the user command.
setup [--force]            Ensure install and resolve all package dependencies.
run [all|agent|client]     Ensure setup, then launch all (default) or one component.
status                    Show this worktree runtime and component status.
stop [all|agent|client]   Stop all components (default) or one component.
doctor [--fix]            Diagnose ownership; remove only proven stale records.
takeover                  Relaunch one complete manual pair under sanad-dev.
cleanup-target-orphans    Remove proven stale target clients only.
switch --runtime current  Move one active runtime group to the invoking worktree.
logs [client|agent]       Show client or agent logs.
restart [client|agent]    Restart the client or agent.
reload [client]           Hot reload the Flutter client.
inspect [client]          Open Flutter DevTools / Inspector.
```

Common options:

- `-f`, `--follow` — continue streaming logs in a human-owned terminal. AI agent tool calls must never use follow mode because it blocks until interrupted and otherwise returns only by timeout.
- `-n`, `--tail <lines>` — limit the log history; this terminating form is required for AI agent tool calls.
- `-p`, `--port <port>` — select a specific running instance.
- `--driver` — run the client driver entry point for interactive inspection.
- `--cloud` — explicitly enable the hosted connection, which is already the
  development default.
- `--no-cloud` — disable hosted connections.
- `--home <user|absolute-path>` — use the primary Sanad Home or an explicit
  isolated home.
- `-d`, `--device <id>` — select the Flutter target for `run client/all`, or
  select the exact owned Client for `stop client`.
- `--force` — for `stop agent/all`, cancel active and queued Agent work before
  shutdown instead of preserving it for resume. Client-only stop rejects it.
- `--config <path>` — select the client compile-time configuration; the default is `config/prod.json`, while `config/dev.json` is an explicit hosted-service integration profile.
- `--dry-run` — resolve and print runtime settings without launching.
- `--fix` — with `doctor`, remove a stale/invalid launcher record only when the
  launcher, Agent endpoint, and matching clients are all absent.

Examples:

```bash
sanad-dev run agent
sanad-dev run client -d macos
sanad-dev stop client -d macos
sanad-dev stop agent
sanad-dev stop all --force
sanad-dev logs client -n 50
sanad-dev logs agent -n 20
sanad-dev restart agent -p 58086
sanad-dev inspect client
sanad-dev run --home user --no-cloud
sanad-dev run --dry-run
```

`run all` spawns Agent and Client concurrently and verifies their health and VM
identities independently. The current launcher terminal owns and prints complete
Agent stdout/stderr. A separate Client terminal follows each Client journal,
including Flutter tool/build output before VM readiness. In that Client terminal,
Flutter's complete interactive set is available: `r` reloads, `R` restarts, `h`
shows help, `d` detaches, `c` clears, and `q` quits the Client. In the Agent
terminal `r`/`R` request a supervised restart while `s`/`q` request a resumable
Agent-only stop that leaves sibling Clients running. macOS uses Terminal; Linux
selects a declared supported terminal; Windows uses Windows Terminal or
PowerShell with quoted arguments. Headless/CI execution never opens a GUI and
prints a bounded copyable `logs` command instead. `run agent` and `run client`
keep their single component and controls in the invoking terminal; `run client`
never opens an additional terminal. Automatically opened Client terminals show
only the latest 50 retained lines and remain attached throughout the full cold-
build startup window before following current output.

Bootstrap readiness checks are silent. Output such as `Installing Flutter
<version>` appears only when that SDK is actually unavailable and installation
work begins; an already-ready SDK produces no verification or installation
banner. A command received through another checkout's user shim is redispatched
to the invoking Git worktree before bootstrap and runtime execution.

Managed component journals begin at `Process.start`, preserve stdout/stderr
ordering and ANSI bytes, mark process generations, rotate through four 2 MiB
segments per component, use user-only permissions, redact recognized credential
shapes, and remove files older than 14 days when a runtime starts. `logs -n`
reads the retained complete history; `logs -f` takes one atomic snapshot and
continues from its byte offsets without replay. Agent restart and source handoff
append generation boundaries to the same component surface. For manual runtimes,
`logs` explicitly falls back to the Agent logger or VM service and warns that
pre-health/pre-VM process and build output cannot be reconstructed.

The launcher remains alive while any owned component is active. Stopping or
naturally exiting one Client does not stop the Agent or sibling Clients.
`stop client -d <id>` requires one exact owned device match; duplicate device ids
require `-p <vm-service-port>`. Normal `stop agent` waits for a durable checkpoint
and leaves Clients disconnected but running. A rejected checkpoint leaves the
complete runtime unchanged. Starting the Agent again restores checkpoint-safe
work and FIFO input. `stop agent/all --force` is the explicit destructive path.

When several compatible processes are running, ordinary discovery selects the
live process whose workspace hash, gateway, source path, Home, preferences, and
launch markers consistently match the caller. Inherited requester gateway
variables cannot redirect status, stop, or developer actions. An explicit port
may select a diagnostic endpoint but does not grant mutation ownership. Client
restart/reload preserves the exact `flutter run` config and `dart-define`
arguments. If the live process lacks a verifiable launch profile or its gateway
points at another worktree, the command fails without restarting the client.
Use `--port` only for an explicit diagnostic target; identity validation still
applies.

Use `sanad-dev doctor` before reconciling a Terminal/IDE launch. A complete
single manual pair may be converted with `sanad-dev takeover`; it passes through
the daemon's safe restart boundary and refuses Agent-tool-origin takeover.
`cleanup-target-orphans` is narrower: it can remove only clients from the
invoking target source when their recorded launcher and Agent are absent. It
refuses requester/source-attached, live IDE-owned, cross-owned, or incomplete
groups. There is no generic replace option.

Use `--driver` when the client must expose its test driver and VM service for
interactive UI verification:

```bash
sanad-dev run --driver
```

### Installed user command

`setup` installs the user-scoped `sanad-dev` shim. It refuses an existing shim
owned by another checkout unless `setup --force` is explicit. Calls made inside
a Git checkout preserve caller-worktree discovery; calls made elsewhere use the
checkout that owns the shim. Re-run setup from the intended checkout to repair
the command after moving or deleting source.

### Isolation and conflict detection

The primary checkout prefers local daemon port `58085`. Linked worktrees use
deterministic candidates in the reserved development range and probe for
availability. Their Flutter VM-service ports are isolated as well.

Runtime metadata records the worktree, process IDs, endpoints, logs, and Sanad
Home. Before starting Flutter, the launcher verifies that the daemon health
response belongs to the expected agent source directory. An unrelated process
already using the selected port is therefore reported instead of silently
being treated as the requested daemon.

The client receives a readable worktree label and branch for development
diagnostics. Packaged runs and the primary checkout do not present that
worktree badge.

### Move an active runtime to another worktree

Before leaving the source worktree, inspect and record the selected runtime:

```bash
sanad-dev status
```

Then, from the target worktree, run the switch and its required post-handoff
verification:

```bash
sanad-dev switch --runtime current
sanad-dev status
```

This command changes the source used by every conversation sharing the selected
agent/client pair. An agent may invoke it only after a direct user instruction
explicitly identifies the intended runtime and target worktree. A request to
implement, test, debug, verify, restart, or deploy a change does not authorize a
source switch. If another session may be using the pair, the agent must disclose
the shared impact and obtain fresh confirmation before execution.

Requester identity selects and recovers only that agent/client pair; it does not
prove user consent. With several runtimes and no requester identity, specify the
agent endpoint using `--port`; ambiguous selection fails without changing any
process. A target worktree that already has a runtime is also rejected.

The owning launcher drains the selected daemon through the normal safe-restart
checkpoint, then relaunches the Agent and every attached switch-capable Client
from the target source. The selected runtime group keeps its Sanad Home, local
endpoint, every Client VM-service port and launch profile, cloud mode, and
client preference namespace. Other runtimes are untouched. If any target group
member cannot become healthy, the launcher restores the complete previous
source group. This command applies only when the live versioned launcher lease,
Agent identity, and exact Client nonce/PID/VM set agree; a switch-capable flag
alone is insufficient. It does not adopt packaged services or arbitrary IDE
processes.

When the command originates from an Agent tool call, acceptance is persisted as
a deferred result rather than returned as completion. After target verification
or rollback, the same original tool call returns `complete`, `rolled_back`,
`failed`, or `recovery_failed`; that result remains authoritative. The required
post-handoff `status` call must run from the target worktree to verify the active
source, branch, agent, and clients. Because status is caller-worktree scoped, a
status call from the old source can report that source as stopped even while the
target runtime is healthy.

## Agent configuration template

When changing `agent/.env.example`, regenerate the template compiled into the
native executable:

```bash
cd agent
fvm dart run scripts/generate_env_template.dart
```

Review the generated Dart source in the same change.

## Analysis and tests

Agent:

```bash
cd agent
fvm dart analyze
fvm dart test
```

Client:

```bash
cd client
fvm flutter analyze
fvm flutter test
```

Run focused tests for the changed behavior before broad suites. E2E or
integration tests that bind shared ports run sequentially; normal unit and
widget tests do not require forced sequential execution.

## Documentation

Behavior changes must update their owning page under `docs/` and the closest
runtime contract when a durable ownership rule changes.

Regenerate the machine-readable indexes:

```bash
fvm dart run scripts/generate_llms_txt.dart
```

Validate links and documentation ownership:

```bash
fvm dart run scripts/lint_wiki.dart
```

## Local binary testing

Compile a native agent into a temporary or dedicated test location rather than
overwriting a production installation:

```bash
cd agent
fvm dart compile exe bin/sanad_agent.dart -o build/sanad
```

The built-in service manager exposes:

```bash
sanad service install
sanad service status
sanad service start
sanad service stop
sanad service uninstall
```

Keep source-mode and installed-service runs on separate runtime endpoints when
testing them concurrently.

### Supervised source restart

The `daemon` and `start` commands run under a supervisor in both source and
compiled execution. During a foreground source run:

- type `r` and press Enter to request a controlled restart;
- or send `POST /restart` to the active local endpoint;
- or use `sanad-dev restart agent` for a matched development runtime.

For the default manual endpoint:

```bash
curl -X POST 'http://127.0.0.1:58085/restart?timeout_seconds=60&force=false'
```

The daemon enters a global restart drain, queues new work, and waits for every
active session to reach a restart-safe checkpoint. The default timeout is 60
seconds. A normal timeout returns a failure with the blocking session/tool
identities and leaves the daemon running. `force=true` deliberately exits after
the timeout even when unsafe tools remain, but only after the single HTTP
response has been flushed.

The supervisor replaces a child only after an accepted restart exits. It never
turns a rejected safe restart into an implicit process kill. Unexpected process
failures are restarted within a bounded failure window; the supervisor stops
after repeated rapid failures instead of creating an infinite restart loop.

### Live self-development of the active source runtime

A source-mode Sanad agent can update the same checkout from which its current
child process is running; launching a second copy is not required for a focused,
verified change. The agent can inspect live or bounded logs, edit its source,
run analysis and focused tests, and invoke `sanad-dev restart agent` from its own
active tool turn.

For a restart invoked by `shell_execute`, `sanad-dev` forwards the requesting
session and tool-call identity. Before the one HTTP response, the coordinator
may exclude only that exact requester while every other active session must be
safe. After flushing the response, it waits for the requester result and
`after_tool_result` checkpoint, then exits. This avoids the self-deadlock where
the restart tool cannot complete until its HTTP call returns without weakening
the all-session safety boundary.

The supervisor then starts the updated source, startup recovery reclaims the
same durable turn, and execution continues against the new child. The restored
runtime rebuilds its tool catalog and implementations from the updated source.
Consequently, a turn can observe a tool failure, repair that tool, restart
itself, and retry the repaired tool without creating a new session or a second
daemon. For a stubborn bug, the same turn can add a temporary structured log,
restart, reproduce the issue, read a bounded post-restart log window, repair the
owning boundary, remove the instrumentation, and verify again.

A human-owned terminal can keep the live agent log stream attached because it
reconnects across restart. AI agent tool calls must always use bounded log
reads and must never invoke `logs` with `-f` or `--follow`: follow mode blocks
until interrupted, normally returns to the tool only by timeout, and leaves a
tool marked as executing while controlled restart is trying to reach a safe
checkpoint.

Use this path only after analyzer, focused startup/recovery tests, and diff
review pass. Broad bootstrap, supervisor, dependency-injection, migration, or
other changes that could prevent the daemon from returning or the turn from
being reclaimed should be developed and exercised in an isolated worktree
runtime first.

`sanad service restart` is different: it restarts the registered operating
system service rather than the foreground supervisor child.

### Platform service diagnostics

Prefer `sanad service` for normal management. If registration itself is
broken, inspect the owning platform integration:

- macOS: a user LaunchAgent managed through `launchctl`;
- Linux: a user service managed through `systemctl --user`;
- Windows: a Scheduled Task managed through PowerShell.

Do not document or depend on a hard-coded service file location in contributor
automation; the service manager owns those paths and identifiers.

## Release development

The stable release contract is `release/release-contract.json`. It fixes the
version, build, tag, public repository, and exact artifact names shared by the
workflow, manifest generator, updater, Appcast, installers, and documentation.
The release workflow builds native agent binaries and Flutter client packages,
then publishes immutable GitHub Release assets. Signing keys and deployment
credentials are provided only through protected CI environments.

Release changes must verify:

- platform and architecture;
- final asset name and package format;
- version output;
- checksum/signature;
- clean install and service lifecycle;
- client and standalone-agent update;
- rollback and uninstall.

The generated Appcast is published after signed assets exist and is not tracked
as a source file. Source/FVM runs are developer-managed: neither `sanad update`
nor client self-update changes a checkout. See
[Release, Signing, and Deployment Architecture](release_and_signing.md),
[Release and Update Architecture](../technical/update_architecture.md), and the
component release guides for platform-specific ownership.
