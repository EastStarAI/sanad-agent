# Capability Tools Contract

## Scope
This contract applies to `agent/lib/capabilities/tools/`.

## Tool Implementation
- Every production tool explicitly implements typed `executeResult` as the authoritative common boundary and exposes a valid JSON-schema parameter contract. No default string-to-typed bridge exists; missing typed implementations fail closed. Concrete `execute` methods are compatibility projections only and engine code must not call them.
- Accept optional `ToolContext` and preserve session/workspace/tool-call identity where required.
- Keep execution logic out of registries, protocol handlers, and presentation-facing clients.
- Register one canonical implementation and reuse it across direct runtime and query surfaces.
- `CallbackTool` normalizes string-owned MCP/platform callback outputs into typed text without changing either bridge protocol or callback context; rich callback results require an explicit future protocol cutover.

## Replay Safety
- `restartReplaySafe` remains false unless re-execution after an unknown crash boundary is provably harmless.
- File writes/edits, shell commands, scheduling, delegation, external mutation, and permissioned platform actions remain unsafe by default.
- Read-only file/glob/grep queries may be replay-safe when they have no external mutation.
- Persist replay metadata with continuation checkpoints; runtime recovery must not infer safety.

## Shell Execution
- Enforce workspace/path and permission policy before execution.
- Use native Windows command/PATHEXT behavior on Windows and shell behavior on Unix-like systems.
- Apply `timeout_ms` with a 60-second default and terminate the wrapper plus process group where supported.
- Preserve bounded stdout/stderr on timeout and non-user interruption. Only an explicit user Stop may report `cancelled_by_user`; timeout reports `timed_out`, while daemon shutdown/crash recovery reports `agent_interrupted` with outcome and cleanup metadata.
- Persist a redacted shell process fingerprint and bounded output progress while the command runs so startup can verify and reclaim the exact orphan containment without signaling a reused PID.
- Propagate session and tool-call identity to child processes through the reserved restart-request environment boundary; never expose message content or tool arguments there.
- Build the child environment only through `ProcessEnvironmentPolicy` and spawn with `includeParentEnvironment: false`; Dart otherwise merges the daemon environment back in.
- `ShellExecuteTool` owns schema, workspace boundary, and permission checks, then delegates to the `ExecutionBackend` chosen from daemon policy at each execution. A backend never grants approval. The backend is resolved before approval and a refusing backend (`runsCommands: false`) answers without a prompt or durable grant. Protected execution and an unreadable policy fail closed and never fall back to the host.
- The working directory must equal the canonical workspace root or lie within it; prefix matching is not containment.
- Stored user secrets reach a command only when its `secrets` argument names them on an `owner` turn; unknown names fail before approval and the command never runs. The backend redacts every injected value from all reported output.

## Host Capability Discovery
- `host_capability_discovery` never executes a binary, starts a shell, lists directories, or returns `PATH` or other environment values.
- Its presence is decided by the runtime catalog from daemon policy and stamped authority; the tool itself never decides visibility and no prompt text may announce it.
- Keep command output bounded and free of injected operational instructions.
- Shell typed error status comes from terminal execution state, never output-string parsing; preserve the legacy encoded payload as the text projection.

## User Secret Tools
- Secret tools return names and outcomes only and refuse non-owner turns. `system_request_secret` never stores values itself; it trusts only the bridge-sanitized decision. `system_delete_secret` is sensitive and asks every time.

## Workspace Search
- `search_glob` and `search_grep` execute through focused workspace handlers.
- Glob matching supports full relative path and basename semantics plus brace alternatives.
- Grep normalizes escaped/raw alternation pipes, surrounding whitespace, and duplicate pipes before regex compilation.
- Malformed regex falls back to literal search rather than failing the entire tool request.

## Built-In Memory Tool
- The built-in persistent tool is named `memory`.
- Its fixed targets map to `MEMORY.md` and `USER.md` through the evolution memory owner.
- Single mutations and one-target atomic `operations` batches share the same store authority; runtime validation owns per-action required fields.
- Return compact terminal mutation success, bounded correction context for recoverable failures, and full entries only for explicit read.
