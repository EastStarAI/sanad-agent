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
- Preserve visible thoughts and reasoning separately from final content and opaque provider state.
- History healing must not synthesize a tool result while an unresolved suspended checkpoint or a valid requester-bound deferred result owns that tool-call id.
- Each model invocation mints one model-step id shared by its chunks, reasoning, checkpoint, and assistant message.
- Manual recovery of an ambiguous tool must reconcile the complete durable assistant tool-call batch before another model request: reuse completed results, neutralize only started unsafe calls, execute never-started calls normally, and append exactly one provider-visible result per call in original order.

## Provider-Neutral Completion
- A new user turn resets turn-scoped tool maintenance budgets before model execution; tool retries within the same turn share that bounded budget.
- Actual tool-call presence determines tool execution; adapter finish reason is a compatibility/terminal classification.
- Persist terminal classification, including state-only responses, so restart preserves continuation intent.
- Missing providers degrade to the lazy missing-provider adapter.
- Automatic failover within one model invocation must exclude every provider instance that already failed before streaming; it must never revisit an exhausted route in the same chain.
- Internal accumulated usage remains separate from the latest immutable context-usage projection exposed to clients.

## Run Cancellation
- `RunCancellationScope` is the run-owned cancellation primitive keyed by `runId`; provider, tool, and wait layers register bounded cleanup callbacks on it.
- `AgentRunner` attaches to the active scope for the authoritative turn and must not publish run-scoped output after scope invalidation.
- `release()` on a registration handle is idempotent and removes a resource from future cleanup without cancelling it.
- Stop acceptance invalidates publication synchronously; cleanup is parallel, bounded, and reports a typed terminal outcome.
- Provider turns register request-owned HTTP transport on `RunCancellationScope`; shared adapter clients must not be closed by another run's cancellation.
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
- Summarizer prompts are redacted, tool-free, and split into a bounded number of passes when source material exceeds the summarizer window.
- The coordinator prepares immutable source/tail ranges, persists the exclusive started claim, and publishes the compacting barrier before awaiting any summarizer pass; every post-claim error must close that row as a typed terminal failure.
- Oversized retained-tail tool/media payloads may be pruned in projection-only copies for re-measurement; canonical history is never mutated.
- Design detail: `docs/agent_engine/context_compaction_design.md`.
