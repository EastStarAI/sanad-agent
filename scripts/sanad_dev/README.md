# sanad-dev CLI Reference & Usage

`sanad-dev` is the canonical developer DX utility for running, observing, and debugging the open-source components of the SanadAgent system (Dart background daemon & Flutter client).

## Running and bootstrapping

From a fresh macOS/Linux checkout, install the user command once:

```bash
scripts/sanad-dev install
```

Use `scripts/sanad-dev.ps1 install` in Windows PowerShell. No arguments display
help without mutation. `install` owns verified FVM `4.1.2`, pinned Flutter, and
the user shim; `setup` ensures install and resolves Release Contract, Agent, and
Client packages without launching; `run` ensures stale or missing stages and
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

### 2. `status`
Displays runtime status and metadata for the current Git worktree in real-time. Reports whether the agent and client are running, their PIDs, VM service ports, and active configuration modes.
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

`doctor` is read-only. `doctor --fix` removes only a proven stale lease and
never signals a live process. `takeover` converts exactly one complete manual
pair into a managed runtime after a safe Agent checkpoint.

### 9. Source handoff

```bash
sanad-dev switch --runtime current --target-worktree <path>
```

An explicitly authorized handoff keeps the same launcher, Home, endpoints, and
active session while changing source roots. The original Agent tool call
returns the terminal `complete`, `rolled_back`, `failed`, or
`recovery_failed` result; `status` shows the same outcome as historical
diagnostics.
