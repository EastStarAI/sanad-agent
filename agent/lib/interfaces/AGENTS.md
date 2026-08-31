# Agent Interfaces Contract

## Scope
This contract applies to `agent/lib/interfaces/`.

## Interface Ownership
- Connect runtime execution to external platforms through typed, asynchronous, non-blocking boundaries.
- Keep platform transport, runtime admission, canonical protocol translation, and durable domain state in separate owners.
- `GatewayManager` routes responses; it must not classify runtime work or inspect event names to infer delivery.
- `SessionRunOrchestrator` admits and coordinates work; it must not own provider adapters, protocol parsing, or table-specific SQL.
- Platform adapters translate transport lifecycle only; they must not duplicate shared Sanad protocol or runtime workflows.

## Failure Isolation
- Isolate platform initialization, command, and delivery failures so one adapter cannot terminate the daemon event loop or prevent other interfaces from starting.
- Keep streaming default and high-frequency logging at debug/fine level while preserving concise lifecycle and terminal-event logs.
- Unknown origins, invalid delivery policy, malformed command identity, and unsupported query combinations fail closed.

## Identity
- Preserve device, hardware, session, request, work-item, run, generation, model-step, tool-call, origin, and event identities without substituting one for another.
- `run_id` is immutable execution ownership, `model_step_id` identifies one model invocation, `tool_call_id` pairs tool use/result, and `event_id` is opaque canonical event identity.
- Compaction lifecycle transitions share one logical `compaction_id` but use distinct deterministic `event_id` values that remain identical across live delivery and history hydration.
- Hydrated compaction lifecycle placement follows the durable logical tail-end anchor when edit/recovery rewrites its database row id; synthetic display timestamps never decide causal order.
- Runtime-rich turn metadata enters through typed interface models, not scattered map parsing.

## Runtime Query Boundary
- The daemon owns workspace browsing/creation, MCP management, skill inventory/load, slash commands, device settings, provider runtime, and conversation history/list queries.
- Query responses must remain transport-neutral and usable over both local and cloud Sanad transports.
- Cloud `device_id` that does not match the registered device fails closed as
  `wrong_device` before session registration. Remote update, restart, managed
  workspace, and MCP management commands are admitted without new capability
  flags. Root-document `replace_mcp_config` remains rejected on cloud.
- Authenticated Local Gateway health exposes only non-secret runtime facts needed for lifecycle verification, including binary version and whether the cloud adapter has completed authoritative registration; socket connection alone is not registration.
- Cloud filesystem navigation is managed-remote: name-based create under
  `SANAD_HOME/workspaces`, browse limited to that root and registered workspace
  roots, and preview tokens for recursive delete and relocate.
- Cloud MCP configuration listing, inspection, import/export, Advanced JSON,
  OAuth, and reviewed mutations use the same daemon handlers as local. Secret
  values stay out of snapshots, logs, and events. Cloud-origin turns still
  execute configured MCP tools through `PermissionManager`.

## Run Cancellation
- `requestStop` terminalizes executing tools through an owner-validated durable transaction before emitting `stopped`.
- Stop delivery order is cancelled tool terminals, `stopped`, then the final idle/queued execution snapshot; durable work cancellation is already committed before `stopped` is delivered.
- Canonical cancelled `tool_result` events and history hydration expose the same run/generation/revision, reason, cleanup outcome, and start/terminal timestamps.
