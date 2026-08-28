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
