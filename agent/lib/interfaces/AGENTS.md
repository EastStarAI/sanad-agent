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
- Runtime-rich turn metadata enters through typed interface models, not scattered map parsing.

## Runtime Query Boundary
- The daemon owns workspace browsing/creation, MCP management, skill inventory/load, slash commands, device settings, provider runtime, and conversation history/list queries.
- Query responses must remain transport-neutral and usable over both local and cloud Sanad transports.
- Cloud filesystem navigation and workspace-path mutation are disabled at the
  cloud adapter boundary. Transport-neutral handlers may expose daemon-provided
  roots and parent metadata only to an admitted local caller.
- MCP configuration listing, inspection, and mutation are disabled at the cloud
  adapter boundary. MCP servers configured locally remain available to the
  per-turn capability runtime for both local and cloud-origin turns.

## Run Cancellation
- `requestStop` terminalizes executing tools through `ToolTerminalizationService` before emitting `stopped`.
- Canonical `tool_result` events expose `status: cancelled` for durable terminal parity with history hydration.
