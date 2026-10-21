# Engine Runtime Contract

## Scope
This contract applies to `agent/lib/engine/runtime/`.

## Collaborator Boundary
- Runtime collaborators own one cohesive responsibility and delegate history mutation to `AgentRunner` callback contracts.
- They must not retain a history list, current-turn index, interface orchestrator, or table-owning repository as a competing authority.
- The runner remains owner of model-loop progression, metrics, plugin hooks, memory snapshot injection, and final history.

## Tool Execution
- `ToolExecutionCoordinator` executes batches, records per-tool completion, and delegates checkpoint persistence.
- `ToolExecutionCallbacks.currentImageSupport()` provides the turn's frozen `RouteImageSupport` capability tri-state, passed through to `ToolContext.imageSupport` for early tool-level capability gating.
- Parallelize only compatible independent tools.
- Interactive tools, shell execution, and overlapping file paths force sequential execution.
- Persist completion checkpoint after each tool needed for restart safety.
- Consume `ToolExecutionResult` from tools for sequential and parallel execution. Bound text blocks before completion events, checkpoint persistence, or history insertion, and enforce an aggregate text budget across each tool-call batch; image blocks retain order and never enter character counting or text previews.
- Append one typed `Message.toolResult` for each tool-call id through rich runner callbacks. Events, plugins, legacy callbacks, and checkpoint previews receive bounded `displayText` and, where applicable, a byte-free media descriptor only; never binary blocks.
- Publish media-bearing tool completion descriptors (`view_image`, `system_screenshot`) only after the final batch-guarded typed result is durable and the owning run still permits publication, using one shared predicate for both batch and single-tool paths. Single-tool resumed media completion preserves the same persistence-before-publication boundary.
- Preserve typed `isError` classification across completion events, checkpoint output records, and history metadata. Do not parse typed output strings or use implicit `toString()` to infer status; only explicitly normalized legacy recovery records may use their persisted error metadata.

## Continuation Checkpoints
- `ContinuationCheckpointCoordinator` owns checkpoint schema and read/write orchestration for the active work item.
- Receive history/current-turn values through an immutable context and return restored values; do not own them.
- Persist checkpoint kind, completed results, executing tools, replay safety, model step, and owner identity. A provider invocation is durably marked `model_request_in_flight` until its response is saved or the live process receives a definitive request failure. Startup and known failures restore a recognized `checkpoint_before_model_request` and resume under the same owner; missing or unknown predecessors remain blocked without a provider call.
- Provider admission during a controlled restart is an atomic gate: checking that no drain owns the runner and committing both durable and in-memory provider-in-flight markers must contain no await boundary. A runner that reaches a safe post-tool or continuation boundary while drain is active remains parked and consumes no additional provider request until drain cancellation or process replacement.
- A missing checkpoint may be repaired as `initial_model_request` only when the owned user message is durable and there is no provider-in-flight, executing-tool, completed-result, or deferred-result evidence. Persist the repair marker so retry cannot reinterpret an ambiguous boundary repeatedly.
- Tools that support crash diagnostics may persist bounded, redacted execution progress under the active checkpoint. Progress is evidence for terminal recovery, never permission to replay an unsafe tool.
- Persist sequential tool completion and executing-marker removal together.
- Owner-bound rich completions use `completed_tool_results_v2` envelopes containing schema version plus session/work/run/generation/tool identity. Save the individually guarded typed result immediately, then replace it with the aggregate-guarded typed result before canonical history promotion.
- Restore v2 snapshots without reopening tool source paths. Reject stale ownership; degrade a structurally corrupt rich payload to the deterministic text-only unavailable terminal instead of replaying the tool. Legacy/non-owned checkpoints remain text-only compatible.
- Promote a v2 result through `SessionExecutionStateCoordinator` before the runner history callback; never append an owner-bound rich result only to volatile history.
- A completed checkpoint tool result is reused only when its causal model step,
  tool name, and structured arguments match the invocation that recorded it (each
  persisted output record carries its owning `model_step_id`); a genuinely new
  call that reuses a provider tool-call id across model steps or turns executes once. Legacy untagged durable records fall back to
  durable id-based reuse. A freshly re-executed id purges its prior-step result at
  the moment it is marked executing so a crash is never masked by an older outcome.
- A typed deferred tool result may keep one non-idempotent tool executing only
  when its requester-bound descriptor is durable. Startup resolves that
  descriptor exactly once into the original tool result; it never replays the
  external mutation.
- Automatic crash recovery of an owned recognized checkpoint records a neutral unknown-outcome result for every started tool without a durable result, never replays that tool, and continues the model loop; malformed or ownerless checkpoints remain blocked.
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
- Automatic compaction means both Auto preflight and Overflow compaction. A failed attempt of either opens one breaker for the active run; while it is open neither runs again in that run (a later model step or provider overflow falls through to the ordinary path), while a new run and manual `/compact` remain eligible.
- Manual compaction resolves the active model context window through the same precedence as normal provider execution: explicit request override, YAML exact-model override, adapter/provider model metadata, then a bounded last-resort estimate.

## Runner SRP Coordinators
- `AgentRunner` is the composition and run-lifecycle host: it owns runtime state, wires collaborators, keeps the non-stream dispatch loop, request options and the thinking-field suppression, and implements the `Runner*Host` interfaces its coordinators require. Provider failure classification, context assembly, streaming, checkpoint restoration, compaction, and admission live in their own owners; do not move them back into the host. Extracted owners log under the `AgentRunner` logger.
- `RunnerRecoveryCoordinator` owns provider HTTP exception classification, retry budgets and delays, automatic failover candidates, secret-redacted error notices, rejected provider-state clearing, local image-capability, provider-history-projection and thinking-wire rejection notices, and thinking-route revalidation on failover.
  - A `ProviderHistoryProjectionException` is decided before the thinking-wire branch as one blocked invalid-request notice; it never fails over, retries, changes thinking, or mutates history.
  - Auto-failover re-resolves the turn capability profile for the candidate through the host. A retry wake keeps the frozen profile on the same route, revalidates thinking and re-resolves on a changed route, and clears it when no route remains.
  - Overflow compaction is contained: a thrown pass falls through to the recovery notice. Its request carries `targetRatio`, and its last-resort policy fallback is `0.90`, the same as preflight. Overflow compaction reads the per-run automatic-compaction breaker through `RunnerRecoveryHost.autoCompactionBlockedForRun` and opens it with `markCompactionFailure` when its pass fails or throws (Task 118a).
- `RunnerCompactionOrchestrator` owns preflight compaction (threshold, timeline, seed, cooldown, and the per-run breaker, which a failed or thrown pass opens), the pending and confirmed provider input baselines, and the wire proof.
  - A staged pending baseline stays staged until a response carries input tokens, so a stream whose usage arrives only in its last chunk still confirms it.
  - Post-boundary usage reconciles through the boundary-scoped `reconcilePostBoundaryUsage`. Dispatch reservations and typed missing-usage finalization are owned here.
  - Restore requires a versioned wire proof that matches remeasurement. Adapters without a measurer fail closed to an explicit estimate.
  - Every automatic and overflow compaction request takes its provider options from `CompactionRequestFactory.buildCompactionRequestOptions` through the host.
- `RunnerResumeCoordinator` owns checkpoint restoration upon resume, resolving interrupted ambiguous tools, automatic unknown-outcome neutralization for an owned recovery checkpoint, and replaying pending assistant tool batches. The one-shot manual recovery policy is consumed after the active work item is read.
- `RunnerAdmissionGate` owns provider request admission, in-flight state tracking, atomic restart drain gates, stop-request state, and cancellation scope lifecycle. The durable in-flight checkpoint is written through a callback evaluated after any drain wait, with no await between it and the in-memory marker. Capability-profile admission is frozen per turn through the host before the provider request is built, so a later configuration change cannot affect the admitted turn.
- `RunnerContextProjector` owns multi-tier system context assembly (stable identity, memory tiers, volatile session context, model/provider templates), pre-execution plugins, effective history projection with its active compaction boundary (cleared on fallback to canonical history), and agent-local image attachment projection into provider-visible text for routes without image input; non-image and non-provider-safe files stay on the message for the shared adapter wire discloser, so each attachment has exactly one model-facing disclosure path.
- `RunnerStreamCoordinator` owns the streaming turn: the cancellable turn stream and its detached unwind, the provider stream loop, token, reasoning and thought deltas, the in-stream tool loop, live steering continuation, the per-turn capability admission call and its reset when the turn ends, and post-commit image-history pruning.
  - Each provider attempt carries its own request id (`turn` or `turn:retry_N`) and post-boundary reservation. The reservation is threaded through every continuation in the shared `post_boundary_usage_reservation.dart` types and finalized on every exit.
  - A rejected thinking field gets exactly one retry before the stream starts. A handled retry re-prepares provider history.
- `ToolEventCallback` is the single tool-event contract; timing fields are carried as optional named parameters and every tool-event caller and coordinator must use that typedef rather than an inline function type.
