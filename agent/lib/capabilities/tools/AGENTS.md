# Capability Tools Contract

## Scope
This contract applies to `agent/lib/capabilities/tools/`.

## Tool Implementation
- Every tool implements the common tool boundary, exposes a valid JSON-schema parameter contract, and returns an asynchronous textual result.
- Accept optional `ToolContext` and preserve session/workspace/tool-call identity where required.
- Keep execution logic out of registries, protocol handlers, and presentation-facing clients.
- Register one canonical implementation and reuse it across direct runtime and query surfaces.

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
- Keep command output bounded and free of injected operational instructions.

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
