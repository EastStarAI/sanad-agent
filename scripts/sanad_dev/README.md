# sanad-dev CLI Reference & Usage

`sanad-dev` is the canonical developer DX utility for running, observing, and debugging the open-source components of the SanadAgent system (Dart background daemon & Flutter client).

## Package and tests

The CLI implementation is a standalone Pure-Dart package. Production source is
under `lib/`, tests are under `test/`, and `scripts/sanad_dev.dart` remains a
compatibility forwarder. From `scripts/sanad_dev/`, use `fvm dart analyze` and
`fvm dart test`; these tests are intentionally excluded from the Flutter Client
suite. Bootstrap resolves this package before entering the runtime CLI.

## Running and bootstrapping

From a fresh macOS/Linux checkout, install the user command once:

```bash
scripts/sanad-dev install
```

Use `scripts/sanad-dev.ps1 install` in Windows PowerShell. No arguments display
help without mutation. `install` owns verified FVM `4.1.2`, pinned Flutter, and
the user shim; `setup` ensures install and resolves Release Contract, `sanad-dev`,
Agent, and Client packages without launching; `run` ensures stale or missing stages and
then launches. Work-performing stages stream real stdout/stderr and finish with
duration plus outcome. The official source command is:

```bash
sanad-dev run
```

The launcher resolves the invoking Git worktree. Outside Git, the installed shim
uses its owning checkout.

---

## Requirements

Git and the target platform's Flutter toolchain must be available. The wrapper
bootstraps FVM, Flutter, Dart, and package dependencies without elevated
privileges. Downloads fail closed on checksum mismatch.

---

## Runtime Discovery and Ownership

`sanad-dev` combines live network/process discovery with a small, versioned
launcher lease under the selected Sanad Home. The lease contains runtime
identity and exact process ownership; it contains no secrets or captured logs.
Mutating commands validate the lease against the live launcher, Agent, and
clients before acting.

### 1. Workspace Matching via Cryptographic Hash
To distinguish between concurrent running instances of different Git worktrees without exposing absolute paths or system usernames over the network:
* The agent daemon computes a deterministic FNV-1a hash of the Git repository root path and returns it as `workspace_hash` in its `/health` payload.
* The `sanad-dev` tool hashes its current workspace directory and compares it with the `workspace_hash` returned by the agent. If they match, it associates the port with the current worktree.

### 2. Runtime Isolation
* The primary checkout keeps the normal Sanad Home and canonical ports.
* Linked worktrees use a worktree-scoped Home, Agent port, VM-service port, and
  preferences namespace.
* An independent clone must select an absolute `--home` when primary resources
  are already owned by another workspace.

---

## Command Reference

### `install` and `setup`

```bash
sanad-dev install [--force]
sanad-dev setup [--force]
```

`install` stops after tools and the user shim. `setup` stops after all package
graphs are ready. `--force` permits explicit replacement of another checkout's
user shim.

### 1. `run`
Launches the background Dart agent daemon and the Flutter client simultaneously.
```bash
sanad-dev run [options]
```
*Options:*
* `--driver`: Runs the UI client using `lib/driver_main.dart` for automated driving.
* `--cloud` / `--no-cloud`: Restates the default hosted connection or selects explicit local-only mode.
* `--device <id>`: Specifies the target Flutter device (defaults to desktop host: `macos`, `windows`, or `linux`).
* `--config <path>`: Specifies client config JSON file (defaults to `config/prod.json`; `config/dev.json` is explicit internal integration only).
* `--home <user|absolute>`: Selects the primary user Home or an isolated absolute Home.
* `--dry-run`: Resolves and prints all candidate ports and paths without launching.
* `--background`: Starts a detached launcher and waits through a bounded handshake until the requested components are managed or startup publishes a staged failure. The user does not need `nohup`, `screen`, or another shell wrapper. `--background` and `--dry-run` are mutually exclusive.

### 2. `status`
Displays runtime status and metadata for the current Git worktree in real-time. Reports whether the agent and client are running, their PIDs, VM service ports, and active configuration modes, plus the runtime source commit and product version from the launcher lease. It also reports the latest validated startup attempt, including requested versus resolved Home, startup stage, outcome, and bounded failure reason; this diagnostic record never grants runtime ownership. `status` is strictly read-only: it never prepares, repairs, starts, or stops anything, and a stale prepared runtime CLI fails with the `sanad-dev setup` recovery command.
```bash
sanad-dev status
```

### 3. `stop`
Requests the verified owning launcher to stop its complete Agent/client group.
Manual, foreign, incomplete, and unverifiable groups fail closed.
```bash
sanad-dev stop
```

### 4. `logs`
Reads launcher-owned bounded process journals for managed Agent and Client processes. Journals include stdout/stderr from spawn through exit, Flutter tool/build output, generation boundaries, rotation, redaction, and historical crash output. History-to-follow uses byte cursors without replay. Manual runtimes fall back to app logger endpoints with an explicit completeness warning.
```bash
sanad-dev logs [client|agent] [options]
```
*Options:*
* `-f, --follow`: Streams logs live in real-time.
* `-n, --tail <lines>`: Outputs only the last `<lines>` log entries.
* `-p, --port <port>`: Bypasses current worktree lookups to inspect logs for a specific instance port.

Managed Client log terminals accept Flutter `r`, `R`, `h`, `d`, `c`, and `q`.
Managed Agent terminals accept `r`/`R` for restart and `s`/`q` for resumable
Agent-only stop.

### 5. `restart`
Restarts the target component.
```bash
sanad-dev restart [client|agent] [options]
```
* Target `client`: Triggers a hot restart via the VM service.
* Target `agent`: Restarts the background daemon process. This performs a complete process restart, causing the Dart VM to re-compile and load any modified source files from disk.

### 6. `reload`
Hot reloads the Flutter client.
```bash
sanad-dev reload [client] [options]
```

### 7. `inspect`
Opens the Flutter DevTools / Widget Inspector inside a browser for the running client.
```bash
sanad-dev inspect [client] [options]
```

### 8. Ownership diagnostics and reconciliation

```bash
sanad-dev doctor
sanad-dev doctor --fix
sanad-dev takeover
sanad-dev cleanup-target-orphans
```

`doctor` is read-only. Alongside the ownership class it reports the driver entry
point, how many lease-owned Clients were started from `lib/driver_main.dart`, the
Agent and VM-service ports selected for this worktree, the Home and whether it is
worktree-scoped, and — on macOS — the Accessibility and Screen Recording grants
that `sanad-dev ui` needs. `doctor --fix` removes only a proven stale lease and
never signals a live process. `takeover` converts exactly one complete manual
pair into a managed runtime after a safe Agent checkpoint.

### 10. Reset with Home fixtures

```bash
sanad-dev reset [--fixture <name>] [--save-fixture <name>] [--keep-data] [--dry-run]
```

One command replaces the stop → restore → run sequence: it stops this worktree's
Agent and Client, proves the ports are free, optionally saves and/or restores a
Home fixture, then launches a driver-enabled pair and prints one `reset:` line
with the ports, commit, state, and Home. It refuses any Home other than this
worktree's own Test Home (`<user home>/.sanad/dev/homes/<worktree id>`), so the
primary `~/.sanad` and shared `~/.sanad-test*` homes can never be reset from here.

Fixtures live in `<worktree>/.sanad-dev/fixtures/<name>/` (gitignored) and hold
only `state.db` plus its SQLite sidecars, `config.yaml`, `models_dev_cache.json`,
`mcp_config.json`, and the `skills/`, `memories/`, and `workspaces/` trees. Every
secret is excluded: `.env`, `.local_token`, credential JSON files, OS-vault
material, private keys, and any file whose name looks like a token, secret,
credential, or key. Restores are staged inside the Home and committed with
same-filesystem renames, and they never read, replace, or delete an excluded
path.

### 11. Apply: pick the lightest correct action

```bash
sanad-dev apply [--dry-run]
```

`apply` diffs the working tree and every commit since the runtime's recorded
start commit, prints the action and its reason, then executes it:

| Changed path | Action |
|---|---|
| docs, tests, `.github/**`, `**.md` | none |
| `scripts/sanad_dev/**`, `scripts/sanad-dev*` | `stop` + `run` |
| `agent/**` | `restart agent` |
| `client/pubspec.*`, assets, native/Web directories, `client/lib/main.dart`, startup/DI files | `restart client` |
| other `client/lib/**.dart` | `reload client` |
| `shared/**`, `release/contract/**`, or anything unclassified | `restart agent` + `restart client` |

A driver-mode change also selects `stop` + `run`. Before any restart, `apply`
refuses when another build or test is running in the same worktree and names the
matching PIDs; `--force` overrides that guard.

### 12. Compiled CLI cache

```bash
sanad-dev cli path agent|client
sanad-dev cli agent|client -- <args>
```

The Agent CLI (`agent/bin/sanad_agent.dart`) and the Client CLI
(`client/bin/sanad_client.dart`) are compiled once per runtime commit into
`<worktree>/.sanad-dev/bin/<sha>/` and reused until their sources, path
dependencies, pubspecs, or the Flutter pin change. The first form prints the
artifact path and whether it was built or reused; the second runs it with
inherited stdio, prints the per-call duration, and returns the child exit status.
This replaces the 4–6 s `fvm dart run` bootstrap on every call.

### 13. Scheduled out-of-tree refresh

```bash
sanad-dev refresh --at +2m
```

Schedules a fast-forward `git pull`, `sanad-dev setup`, and an Agent plus Client
restart through a one-shot self-deleting OS mechanism: a detached `sh` child on
macOS (never launchd), `systemd-run --user --on-active` on Linux, and a
self-deleting `schtasks /SC ONCE` task on Windows. The command prints the task
name, fire time, script path, log path, and the exact commands to verify the
result.

### 14. Source handoff

```bash
sanad-dev switch --runtime current --target-worktree <path>
```

An explicitly authorized handoff keeps the same launcher, Home, endpoints, and
active session while changing source roots. The original Agent tool call
returns the terminal `complete`, `rolled_back`, `failed`, or
`recovery_failed` result; `status` shows the same outcome as historical
diagnostics.
