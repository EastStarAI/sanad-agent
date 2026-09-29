---
title: "Remote CLI Relay Protocol"
description: "Typed protocol commands, streamed output, execution seam, and boundaries for remote Sanad CLI relay."
---

# Remote CLI Relay Protocol

Owning plan: `docs/plans/102-client-cli-remote-relay-and-desktop-tray.md`
Owning task: `docs/plans/tasks/102a-remote-cli-relay.md`

## 1. Overview

The Remote CLI Relay enables an authenticated Sanad Client (`sanad-client`) or automation orchestrator to invoke the canonical Sanad CLI command surface on a selected remote Agent.

Key architectural properties:
- **No shell evaluation:** The Agent never passes commands to `/bin/sh`, `bash`, `cmd.exe`, or `powershell`. Requests enter the existing `SanadCommandRunner` directly via an in-memory argument vector (`argv`).
- **No command reimplementation:** The Agent executes its existing command handlers (`RunCommand`, `WorkspaceCommand`, etc.) using injected standard I/O sinks.
- **Relay-only transport:** The Gateway acts as a message router without persisting command payloads. The Client retains account and device authority; the target Agent retains runtime and command execution authority.
- **Privacy & safety boundaries:** Command payloads, standard input, and sensitive arguments are never written to transport or application logs.

```text
sanad-client command
  -> matched running Client selected by Sanad Home
  -> authenticated device routing
  -> hosted Gateway or local daemon command relay
  -> selected remote Agent existing SanadCommandRunner
  -> streamed stdout/stderr/events + terminal result
```

---

## 2. Command Runner Surface Inventory

The remote relay executes against `SanadCommandRunner`, which registers the following command surface:

| Command | Subcommands | Purpose |
|---|---|---|
| `run` | None | One-shot execution with prompt or stdin, tool execution, and artifact generation. |
| `workspace` (`ws`) | `list`, `current`, `switch`, `select`, `add`, `create`, `tree`, `policy` | Workspace discovery, registration, directory structure, and permission mode. |
| `session` | `list`, `show`, `stop`, `answer`, `permission` (`permit`, `decide`), `new`, `delete` | Session inspection, interruption, clarification answering, and tool approvals. |
| `models` | None | Listing available LLM models on the target Agent. |
| `providers` | None | Listing and inspecting configured LLM providers. |
| `skills` | None | Listing installed and bundled capabilities. |
| `mcp` | None | Inspecting configured Model Context Protocol servers. |
| `memory` | None | Querying and managing durable memories. |
| `schedule` | None | Inspecting background scheduled tasks. |
| `doctor` | None | Running local diagnostics and environment checks. |
| `version` (`-v`) | None | Printing agent version, platform, and architecture. |
| `chat` (`cli`) | None | Interactive REPL (runs non-interactively or exits cleanly when no TTY is available). |
| `daemon` (`start`) | None | Daemon lifecycle commands (prints usage / status when invoked). |
| `service` | `install`, `uninstall`, `start`, `stop`, `status` | System service lifecycle management. |
| `restart` | None | Triggering supervised daemon restart. |
| `setup` | None | Guided onboarding setup. |
| `login` / `logout` | None | Agent credential management. |

### Global Options Forwarding
All global options supported by `SanadCommand` and `SanadCommandRunner` are parsed on the target Agent:
- `--workspace` (`-w`), `--session` (`-s`), `--model` (`-m`), `--provider`, `--thinking`, `--thinking-mode`, `--quiet` (`-q`), `--json`, `--timeout`, `--account`, `--standalone`, `--home`, `--gateway-url`, `--version` (`-v`), `--help` (`-h`).

---

## 3. Remote Execution Seam

The remote execution seam bridges the daemon's protocol dispatch to `SanadCommandRunner`:

1. **Injected I/O Sinks:**
   - `stdoutSink`: Injected `StringSink` that intercepts standard output lines and dispatches `device.cli.stdout` events.
   - `stderrSink`: Injected `StringSink` that intercepts diagnostic/error output lines and dispatches `device.cli.stderr` events.
   - `stdinReader`: Injected `StdinReader` function that returns the materialized `stdin` payload from the request.
   - `eventSink`: Optional callback for structured events emitted during execution (e.g. `RunLifecycleEvent`).

2. **Runner Construction:**
   ```dart
   final runner = SanadCommandRunner(
     stdoutSink: streamingStdoutSink,
     stderrSink: streamingStderrSink,
     stdinReader: () async => request.stdin,
     workspaceService: workspaceServiceOverride,
   );
   final exitCode = await runner.run(request.argv);
   ```

3. **Isolated Correlation:**
   Every execution is assigned a unique `request_id`. Concurrent executions maintain isolated stream sequence counters (`seq`) and independent cancellation scopes.

---

## 4. Protocol Specification (v1)

### 4.1. Execution Command: `device.cli.execute`

Sent inside the standard `execute_command` envelope:

```json
{
  "type": "execute_command",
  "command": "device.cli.execute",
  "request_id": "b3e0c067-15fa-4c4f-9e73-057d1f5cf2a1",
  "device_id": "target-device-id",
  "payload": {
    "request_id": "b3e0c067-15fa-4c4f-9e73-057d1f5cf2a1",
    "argv": ["ws", "list", "--json"],
    "stdin": null,
    "brief_content": null,
    "timeout_seconds": 300
  }
}
```

#### Fields:
- `request_id` (String, required): Unique UUID for this execution request.
- `argv` (List<String>, required): Argument list to pass to the CLI parser.
- `stdin` (String, optional): Standard input content (e.g. piped text or materialized file content).
- `brief_content` (String, optional): Task brief markdown content to materialize on the remote Agent when executing commands with `--brief-file` (`-b`).
- `timeout_seconds` (int, optional): Execution timeout in seconds (1 to 86400, default 300).

### 4.2. Cancellation Command: `device.cli.cancel`

Sent to abort an in-flight remote CLI execution:

```json
{
  "type": "execute_command",
  "command": "device.cli.cancel",
  "request_id": "c9284102-48df-4a92-9118-2e0f09d84e1b",
  "device_id": "target-device-id",
  "payload": {
    "request_id": "c9284102-48df-4a92-9118-2e0f09d84e1b",
    "target_request_id": "b3e0c067-15fa-4c4f-9e73-057d1f5cf2a1"
  }
}
```

#### Fields:
- `request_id` (String, required): UUID for the cancellation command.
- `target_request_id` (String, required): The `request_id` of the `device.cli.execute` request to terminate.

### 4.3. Streamed Output Events

Events are emitted back to the caller through the standard agent event envelope:

#### Standard Output: `device.cli.stdout`
```json
{
  "type": "event",
  "event": "device.cli.stdout",
  "request_id": "b3e0c067-15fa-4c4f-9e73-057d1f5cf2a1",
  "device_id": "target-device-id",
  "payload": {
    "request_id": "b3e0c067-15fa-4c4f-9e73-057d1f5cf2a1",
    "stream": "stdout",
    "seq": 1,
    "text": "Registered Workspaces:\n"
  }
}
```

#### Standard Error: `device.cli.stderr`
```json
{
  "type": "event",
  "event": "device.cli.stderr",
  "request_id": "b3e0c067-15fa-4c4f-9e73-057d1f5cf2a1",
  "device_id": "target-device-id",
  "payload": {
    "request_id": "b3e0c067-15fa-4c4f-9e73-057d1f5cf2a1",
    "stream": "stderr",
    "seq": 2,
    "text": "[notice] Using default workspace\n"
  }
}
```

#### Structured Events: `device.cli.event`
Emitted when machine-readable lifecycle events are produced:
```json
{
  "type": "event",
  "event": "device.cli.event",
  "request_id": "b3e0c067-15fa-4c4f-9e73-057d1f5cf2a1",
  "device_id": "target-device-id",
  "payload": {
    "request_id": "b3e0c067-15fa-4c4f-9e73-057d1f5cf2a1",
    "seq": 3,
    "event": {
      "type": "running",
      "timestamp": "2026-09-25T08:00:00.000Z",
      "session_id": "..."
    }
  }
}
```

### 4.4. Terminal Result: `device.cli.result`

Exactly one terminal result is emitted per request when execution finishes:

```json
{
  "type": "event",
  "event": "device.cli.result",
  "request_id": "b3e0c067-15fa-4c4f-9e73-057d1f5cf2a1",
  "device_id": "target-device-id",
  "payload": {
    "request_id": "b3e0c067-15fa-4c4f-9e73-057d1f5cf2a1",
    "seq": 4,
    "exit_code": 0,
    "duration_ms": 1420,
    "cancelled": false,
    "timed_out": false,
    "error": null
  }
}
```

### 4.5. Terminal Error Envelope

If request validation or admission fails prior to execution, or if an unexpected fatal error occurs:

```json
{
  "type": "error",
  "request_id": "b3e0c067-15fa-4c4f-9e73-057d1f5cf2a1",
  "device_id": "target-device-id",
  "payload": {
    "request_id": "b3e0c067-15fa-4c4f-9e73-057d1f5cf2a1",
    "code": "duplicate_request",
    "message": "Request b3e0c067-15fa-4c4f-9e73-057d1f5cf2a1 is already active or recently completed."
  }
}
```

---

## 5. Error Codes

| Code | Cause |
|---|---|
| `invalid_request` | Missing or empty `request_id`, empty `argv`, non-string arguments, or invalid timeout value. |
| `duplicate_request` | A request with the same `request_id` is currently executing or completed within the deduplication window. |
| `payload_too_large` | An argument exceeds 1 MB, argument count exceeds 256, stdin exceeds 10 MB, brief content exceeds 512 KB, or total payload exceeds 12 MB. |
| `timeout` | Execution exceeded the specified or default timeout limit. |
| `cancelled` | Execution was explicitly aborted via `device.cli.cancel`. |
| `not_found` | For `device.cli.cancel`, the specified `target_request_id` does not match an active execution. |
| `wrong_device` | Envelope `device_id` does not match the target agent's identity. |

---

## 6. Boundaries & Invariants

1. **Size Limits:**
   - Single argument maximum length: 1,048,576 bytes (1 MB).
   - Maximum argument count (`argv.length`): 256.
   - Maximum standard input (`stdin`) length: 10,485,760 bytes (10 MB).
   - Maximum brief content (`brief_content`) length: 524,288 bytes (512 KB).
   - Maximum total envelope payload: 12 MB.

2. **Timeout Boundaries:**
   - Minimum timeout: 1 second.
   - Default timeout: 300 seconds (5 minutes).
   - Maximum timeout: 86,400 seconds (24 hours).
   - When a timeout fires, execution is interrupted, and `device.cli.result` is emitted with `exit_code: 124` and `timed_out: true`.

3. **Cancellation Boundaries:**
   - Cancellation requires an explicit `device.cli.cancel` referencing `target_request_id`.
   - Cancellation affects **only** the target CLI execution. It cannot stop other CLI sessions, background tasks, or active conversational turns.
   - On cancellation, `device.cli.result` is emitted with `exit_code: 130` (or `143`) and `cancelled: true`.

4. **Redaction & Logging Invariants:**
   - Command arguments (`argv`), standard input (`stdin`), prompts, and tool arguments **MUST NEVER** appear in transport logs (`_logger.info`, `_logger.fine`, etc.).
   - Log statements record only metadata: `request_id`, argument count, stdin byte length, and sanitized subcommand name.
   - Credentials (e.g. `--account`, token options) are never logged.

---

## 7. Client CLI Host (`sanad-client` Local Interface)

The desktop Sanad Client optionally exposes a loopback HTTP and WebSocket host to serve invocations from the `sanad-client` command line tool.

### 7.1. Endpoint Ownership and Discovery

- **Runtime Record:** Saved to `<SANAD_HOME>/runtime/client_cli.json` with permissions `0600` on POSIX systems (`CurrentUser:FullControl` on Windows).
- **Schema:**
  ```json
  {
    "version": 1,
    "pid": 48192,
    "port": 54321,
    "token": "469175e-ephemeral-secret-token",
    "sanad_home": "/Users/alice/.sanad",
    "client_version": "1.0.15",
    "enabled": true,
    "permission_mode": "default",
    "updated_at": "2026-09-25T09:00:00.000Z"
  }
  ```
- **Lifecycle Cleanliness:**
  - One live Client owns the endpoint per Sanad Home.
  - Stale endpoint records are automatically detected and replaced if the recorded PID is dead or non-responsive.
  - Ownership is cleanly removed when the Client CLI is disabled in settings, on user logout, or upon Client process shutdown.

### 7.2. Authentication

Requests must supply the ephemeral secret token via either:
1. HTTP header: `x-sanad-client-token: <token>`
2. Standard Authorization header: `Authorization: Bearer <token>`
3. WebSocket query parameter: `ws://127.0.0.1:<port>/ws?token=<token>`

### 7.3. HTTP Endpoints

- `GET /health`: Returns `{ "status": "ok", "version": "1.0.15", "enabled": true, "permission_mode": "default" }`.
- `GET /devices`: Returns list of remote online devices connected to the Client's account (local inventory device is excluded):
  ```json
  {
    "devices": [
      {
        "id": "dev-linux-build-node",
        "name": "Linux Build Node",
        "platform": "linux",
        "status": "online",
        "is_current": false
      }
    ]
  }
  ```
  Returns `403 Forbidden` if Client CLI is disabled.

### 7.4. WebSocket Relay Protocol (`/ws`)

Clients initiate execution by opening `ws://127.0.0.1:<port>/ws?token=<token>`.

#### Client-to-Host Messages

- **Execute Command (`type: execute`):**
  ```json
  {
    "type": "execute",
    "request_id": "req-uuid-1",
    "device_id": "dev-linux-build-node",
    "argv": ["run", "--workspace", "ws-core", "--brief-file", "..."],
    "stdin": null,
    "brief_content": "# Task brief\n...",
    "timeout_seconds": 300
  }
  ```
- **Cancel Command (`type: cancel`):**
  ```json
  {
    "type": "cancel",
    "request_id": "req-uuid-1"
  }
  ```
  *(Note: Accepts either `request_id` or `target_request_id` identifying the execution to cancel.)*

#### Host-to-Client Messages

- **Streamed Standard Output (`type: stdout`):**
  ```json
  { "type": "stdout", "text": "Starting task execution...\n" }
  ```
- **Streamed Standard Error (`type: stderr`):**
  ```json
  { "type": "stderr", "text": "Warning: workspace fallback\n" }
  ```
- **Streamed NDJSON Event (`type: event`):**
  ```json
  { "type": "event", "data": { "type": "tool_start", "tool": "file_write" } }
  ```
- **Terminal Execution Result (`type: result`):**
  ```json
  {
    "type": "result",
    "request_id": "req-uuid-1",
    "exit_code": 0,
    "cancelled": false,
    "timed_out": false,
    "error": null
  }
  ```
- **Fatal Error (`type: error`):**
  ```json
  {
    "type": "error",
    "request_id": "req-uuid-1",
    "code": "device_offline",
    "message": "Target device \"Linux Build Node\" is currently unreachable."
  }
  ```
