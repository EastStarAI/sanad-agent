# Agent Engine Contract

## Scope
This contract applies to `agent/lib/engine/`.

## Engine Ownership
- Own provider-neutral model execution, conversation history, prompt assembly, tool-loop coordination, steering, usage, and model-step lifecycle.
- Keep provider adapters stateless and isolate provider-specific wire behavior from the runner.
- Keep capability catalog construction, interface admission, and durable table ownership outside the engine.

## Prompt Assembly
- `AgentContextAssembler` is the single owner of system-prompt construction.
- Emit one system message ordered stable identity, workspace context, then volatile memory/date/runtime metadata.
- Stable content remains fixed per session; workspace context changes with workspace; volatile content changes per turn.
- Runtime context supplied by interfaces remains ephemeral and must not be persisted into conversation history.

## History and Request Identity
- `AgentRunner` solely owns `history` and the current-turn start boundary.
- Runtime collaborators read live state through contexts and mutate through callbacks; they never retain a parallel history list.
- Persist raw interface request id on every ordinary user message for replay/edit boundaries.
- Reload persisted active history before appending a user turn so a committed replay replacement is not duplicated.
- When an existing pre-admitted user record lacks its admitted attachments, repair and persist that record in place before model execution; never append a second user turn or leave the repair only in memory.
- Preserve visible thoughts and reasoning separately from final content and opaque provider state.
- History healing must not synthesize a tool result while an unresolved suspended checkpoint or a valid requester-bound deferred result owns that tool-call id.
- Each model invocation mints one model-step id shared by its chunks, reasoning, checkpoint, and assistant message.
- Manual recovery of an ambiguous tool must reconcile the complete durable assistant tool-call batch before another model request: reuse completed results, neutralize only started unsafe calls, execute never-started calls normally, and append exactly one provider-visible result per call in original order.
- After a successfully persisted assistant message, prune canonical tool-image history by completed assistant turns: protect the current/incomplete loop and latest three completed turns, then enforce the 24-MiB retained-image cap oldest-first. Replace image blocks in place with the processed marker, preserve text/order/tool identity/error state, and persist only when the idempotent transform changes history.
- Plugin notifications for tool results receive a text-only message copy; canonical history alone retains `toolResult` blocks. Events and history queries likewise project bounded `content`, never rich blocks.
- `view_image` tool lifecycle logs, public events, and history-query projections redact the local path while preserving safe detail/status and stable tool-call identity; approval requests remain the explicit path-review surface.
- LLM request diagnostics recursively sanitize a deep copy. Typed image blocks and data URIs become MIME/decoded-size metadata with no payload sample, and the live provider request remains untouched.

## Provider-Neutral Completion
- A new user turn resets turn-scoped tool maintenance budgets before model execution; tool retries within the same turn share that bounded budget.
- Actual tool-call presence determines tool execution; adapter finish reason is a compatibility/terminal classification.
- Persist terminal classification, including state-only responses, so restart preserves continuation intent.
- Missing providers degrade to the lazy missing-provider adapter.
- When a provider answers HTTP 400 that clearly rejects the thinking/reasoning field the request actually carried (`ThinkingFieldRejection`), the runner retries that same request exactly once without the field. It records only the rejected selection value for that route+model for the rest of that session, in memory (`SessionThinkingFieldSuppression`, keyed by route, model and selection id), so later requests with that value send no field while a different selection on the same route is still sent. It logs a warning that the requested selection was not applied (the provider default answered), so the retry never passes as the user's choice. Any other 400 is unchanged, and there is never a second retry.
- Automatic failover within one model invocation must exclude every provider instance that already failed before streaming; it must never revisit an exhausted route in the same chain.
- Opt-in request dumps serialize sanitized JSON-compatible request and normalized response projections; arbitrary typed values may contribute only through `toJson`, and raw streaming transport lines never become the durable response contract. Completed or terminal normal-turn request dumps are immutable and cannot be overwritten by subsequent auxiliary or retried requests, which maintain attempt-isolated request correlation. Unknown or terminal keyed requests fail closed without mutating active dumps, and unkeyed auxiliary calls isolate to independent files rather than attaching to in-flight keyed turns.
- Internal accumulated usage remains separate from the latest immutable context-usage projection exposed to clients.
- Turn admission authoritatively freezes an immutable `RouteCapabilityProfile` for the turn before model execution; in-flight retries on the same route or config reloads do not mutate the snapshot. Profile reuse in `_requestOptionsForTurn` is route-checked (requiring matching trimmed provider instance ID and model ID) so same-route iterations preserve the admitted profile while any route transition resolves the candidate profile; only an admitted, still-running turn may store that candidate profile. When automatic failover or interrupted retry wait switches route (provider or model actually changed; a same-route wake keeps the admitted snapshot), `AgentRunner` refreshes `_turnCapabilityProfile` for the candidate/session route so candidate capabilities (image input, thinking directives, and overrides) govern subsequent dispatch while remaining frozen across multi-step iterations on that route. Outgoing wire bodies preserve the exact requested model ID and do not rewrite it to aliases. Adapters (including OpenAI-compatible and Ollama) enforce model vision capabilities against the resolved profile before HTTP dispatch; pixel-bearing turns targeted at unsupported or unknown models fail closed with `LocalImageCapabilityException` without network I/O.

## Run Cancellation
- `RunCancellationScope` is the run-owned cancellation primitive keyed by `runId`; provider, tool, and wait layers register bounded cleanup callbacks on it.
- `AgentRunner` attaches to the active scope for the authoritative turn and must not publish run-scoped output after scope invalidation.
- `release()` on a registration handle is idempotent and removes a resource from future cleanup without cancelling it.
- Stop acceptance invalidates publication synchronously; cleanup is parallel, bounded, and reports a typed terminal outcome.
- Provider turns register request-owned HTTP transport on `RunCancellationScope`. When `requestClientFactory` is provided (e.g., in isolated tests), it creates fresh request-owned clients closed upon request completion or cancellation. In production, scoped requests create per-request owned HTTP clients closed upon completion/cancellation, while `adapterSharedClient` is used unowned only outside cancellation scopes. Explicit `requestClient` retains its original ownership contract.
- `ToolExecutionCoordinator` passes the active scope through `ToolContext` and gates tool start/complete events on `isPublicationOpen`.
- `ToolTerminalizationService` emits one durable `cancelled` terminal per executing tool before `stopped`; late completions must not replace locked terminals.
- Shell execution uses `ProcessTreeController` for owned containment and bounded tree termination; tools opt into cooperative cancellation explicitly.

## Context Compaction Types (Plan 53a)
- Provider-neutral compaction vocabulary lives under `engine/compaction/` and is shared by persistence (53b) and the compaction engine (53c).
- `CompactionInternalSummary` is not a `Message` and must never appear as a historical system or user-visible transcript row.
- Compaction ranges use durable `messages.id` identities via `CompactionMessageIdentity`, never transient in-memory list indices.
- Pressure evaluation, engine transformation, boundary persistence, orchestration, and protocol mapping remain separate owners; see `docs/technical/context_compaction.md`.

## Context Compaction Engine (Plan 53c)
- Goal-preserving engine code lives under `engine/context/` (`ContextCompactionEngine`, pressure evaluator, tail selector, tool pruner, summary prompt/parser, continuity validator).
- The engine must not import SessionDB, protocol translators, or Flutter. It returns a typed `CompactionCandidate` or `CompactionEngineFailure` only.
- Provider-confirmed input usage for the same route and measured request material is the preflight baseline; only a newly appended suffix is estimated. Route, prompt, schema, or measured-prefix changes invalidate the baseline and fall back to an explicitly estimated projection.
- When confirmed usage is absent, a provider adapter may measure its actual wire projection; the Codex Responses path must not count visible content plus replay alternatives or visible reasoning that the codec omits.
- Automatic compaction triggers at the model policy ratio of the effective input window (default `0.80`) and budgets the connected retained suffix independently (default `0.10`).
- Preflight pressure measures the active model projection, not the full canonical transcript behind an eligible compaction boundary; repeated compaction summarizes only rows after the previous source range while carrying the previous summary as an anchor.
- Semantic continuity labels such as goals, blockers, decisions, paths, and pending asks are user-intent anchors only when authored in a user message. Assistant text and tool output may quote arbitrary source/log labels and must not promote those strings into critical intent; tool side effects use typed tool-call identity instead.
- Production compaction invokes the exact active provider/model route over the current provider-visible projection, appending one ephemeral user instruction while preserving the ordinary tool list and request settings. The instruction forbids tool calls; any returned tool call is never executed and permits only one corrective retry from the immutable base.
- Provider-backed summaries use a strict versioned JSON contract, are redacted before persistence, and inherit the ordinary provider output limit. A valid JSON result is not rejected by a compaction-only token, byte, or field-length cap.
- When the ordinary provider request itself overflows, recovery uses at most four contiguous source chunks plus one typed reduce pass and preserves tool-call/result groups.
- The coordinator prepares immutable source/tail ranges, persists the exclusive started claim, and publishes the compacting barrier before awaiting any summarizer pass; every post-claim error must close that row as a typed terminal failure.
- Post-compaction usage reconciliation reserves the exact first dispatched model step against the active boundary; trailing streaming chunks or completion errors reconcile or finalize missing usage once, rejecting out-of-order, later-grown, or route-mismatched requests. Same-route retries (such as 429) keep the post-boundary reservation intact and reconcile on retry success as long as the boundary identity is unchanged; if a retry iteration activates a newer compaction boundary (or the live boundary identity changes), the abandoned boundary reservation is captured and finalized as missing with reason 'no_provider_usage'. Handled route-changing failovers explicitly finalize the abandoned route reservation as missing with reason 'route_failover' immediately upon recovery, before history preparation, preventing indefinite reservation lock without fabricating token attribution on the new route. Subscription cancellations (including client disconnects and executor stop requests cancelling the stream), history preparation failures, restart-drain aborts, and unhandled runner errors are guarded via finally blocks, stream cancellation hooks, and error handlers to finalize unfinalized reservations with 'no_provider_usage'. Stop acknowledgement no longer waits for generator unwind (cleanup is deadline-bounded by `RunCancellationScope`). Because the cancelled generator may still be suspended at an await (for example a 429 `waitForRetry`) and unwind after acknowledgement, the detached unwind is contained at the stream boundary (`AgentRunner._cancellableTurnStream`): cancellation signals (`RuntimeRecoveryCancelled`, `RateLimitCancelled`, `ProviderRequestCancelledException`) end quietly, any other unwind failure is logged `SEVERE` by error type only, and nothing escapes to the zone as an uncaught error. The streaming reservation holder is stream-scoped per `streamMessage`/`resumeStream` invocation, ensuring cancellation of one stream never cross-finalizes a concurrent or subsequent stream's reservation on the same runner (while production runners remain factory-scoped per event). Both streaming and non-streaming execution paths adhere to this rule.
- Oversized retained-tail tool/media payloads may be pruned in projection-only copies for re-measurement; canonical history is never mutated.
- Design detail: `docs/agent_engine/context_compaction_design.md`.
