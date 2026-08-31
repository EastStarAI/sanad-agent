# Engine Runtime Contract

## Scope
This contract applies to `agent/lib/engine/runtime/`.

## Collaborator Boundary
- Runtime collaborators own one cohesive responsibility and delegate history mutation to `AgentRunner` callback contracts.
- They must not retain a history list, current-turn index, interface orchestrator, or table-owning repository as a competing authority.
- The runner remains owner of model-loop progression, metrics, plugin hooks, memory snapshot injection, and final history.

## Tool Execution
- `ToolExecutionCoordinator` executes batches, records per-tool completion, and delegates checkpoint persistence.
- Parallelize only compatible independent tools.
- Interactive tools, shell execution, and overlapping file paths force sequential execution.
- Persist completion checkpoint after each tool needed for restart safety.
- Bound every tool result before completion events, checkpoint persistence, or history insertion, and enforce an aggregate budget across each tool-call batch; this boundary includes built-in, workspace, MCP, platform, resumed, and future registered tools.
- Preserve a structured tool result's `isError` or `is_error` classification across its completion event, checkpoint output record, and history metadata. A non-`Error` text prefix does not override an explicit structured failure.

## Continuation Checkpoints
- `ContinuationCheckpointCoordinator` owns checkpoint schema and read/write orchestration for the active work item.
- Receive history/current-turn values through an immutable context and return restored values; do not own them.
- Persist checkpoint kind, completed results, executing tools, replay safety, model step, and owner identity. A provider invocation is durably marked `model_request_in_flight` until its response is saved or the live process receives a definitive request failure; known failures restore the previous safe checkpoint, while startup blocks a genuinely interrupted unknown outcome instead of replaying it automatically.
- A missing checkpoint may be repaired as `initial_model_request` only when the owned user message is durable and there is no provider-in-flight, executing-tool, completed-result, or deferred-result evidence. Persist the repair marker so retry cannot reinterpret an ambiguous boundary repeatedly.
- Tools that support crash diagnostics may persist bounded, redacted execution progress under the active checkpoint. Progress is evidence for terminal recovery, never permission to replay an unsafe tool.
- Persist sequential tool completion and executing-marker removal together.
- A typed deferred tool result may keep one non-idempotent tool executing only
  when its requester-bound descriptor is durable. Startup resolves that
  descriptor exactly once into the original tool result; it never replays the
  external mutation.
- Automatic resume fails closed on ambiguous unsafe tools; explicit manual continuation records a neutral unknown-outcome result without replaying the side effect.
- A tool terminalized during startup remains a recovery batch member until its original assistant call and completed result have been restored with the same tool-call id before the next provider invocation.
- Resume only through the interface runtime's claimed owner.

## Semantic Continuation
- `ResponseContinuationCoordinator` owns turn-bounded continuation and one-shot provider-state fallback budgets.
- Keep semantic continuation counters independent from network retry and runtime recovery counters.
- Persist provider-state removal before retry and clear only matching namespace/issuer keys.

## Turn Route
- `TurnRouteState` owns volatile per-turn provider/model intent; `SessionManager` owns session-persisted preference.
- Every follow-up model call in one turn uses the same resolved route unless an authoritative recovery route change succeeds.
- Capture the exact last successful adapter, provider instance, and model without completed-turn recovery/rate-limit wrappers.
- Title generation and post-turn metadata consume that immutable successful route rather than rediscover mutable defaults.

## Steering
- `SteerCoordinator` reserves and tracks steer text by raw request id and receipt order.
- Only durably reserved steer enters history.
- Tool-batch steer is inserted after the complete batch and before the next model invocation.
- Late terminal-response steer supersedes pre-steer terminal content and continues within the same active run.
- Failed persistence rolls back volatile mutation and releases reservation without losing text.
- Never log pending steer text or internal model-only steer markers.

## Usage and Model Steps
- Mint a new model-step id before every provider invocation and checkpoint it.
- Latest provider usage replaces the presentation snapshot; normalize aliases, clear absent fields, and do not infer missing totals.
- Internal accumulated usage may aggregate for accounting but never becomes the client context-usage projection.
- Cached input remains an independent provider value; cache-write usage is excluded from client projection.
- One failed automatic compaction opens a breaker for the active run; later model steps in that run must not repeat the attempt, while a new run and manual `/compact` remain eligible.
- Manual compaction resolves the active model context window through the same precedence as normal provider execution: explicit request override, YAML exact-model override, adapter/provider model metadata, then a bounded last-resort estimate.
