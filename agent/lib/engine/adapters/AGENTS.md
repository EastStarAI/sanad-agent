# Engine Adapters Contract

## Scope
This contract applies to `agent/lib/engine/adapters/`.

## Adapter Boundary
- Every adapter implements sync, stream, available-model, tools, model override, and immutable request-options contracts without retaining session state.
- Wrappers forward the exact request-options object and must not drop session, request, provider, model, or thinking context.
- Keep provider-specific endpoint, header, request, stream, and normalization behavior inside the adapter/codec/policy owner.
- Provider-neutral runner code must not branch on endpoint quirks.

## Reasoning and Provider State
- Visible reasoning deltas use the reasoning callback and never contaminate final-content chunks.
- Opaque continuation state uses a typed namespace and issuer; replay only when both match the current instance/protocol/normalized endpoint owner.
- State rejection may clear only matching keys and may trigger one bounded persisted fallback.
- Never replay local reasoning ids as provider wire state.
- Malformed tool arguments fail before execution and must not become an empty object.

## Request Consistency
- Sync and stream for one protocol reuse the same request builder and final normalization.
- Structured reasoning fields take precedence over textual thought tags.
- Codex Responses transport reuses its codec, SSE accumulator, policy, and model service; do not implement parallel contracts in the adapter.
- Adapter-owned wire measurement fingerprints instructions, tools, and ordered input items. When a later request is a strict wire extension, provider-confirmed input remains authoritative and only the appended wire suffix is estimated.
- Codex Responses API requires `stream: true` on every request; the sync `generateResponse` path sends a streaming request and consumes the SSE events internally, returning one complete `AgentResponse` — callers see no difference.
- Responses requests keep server storage disabled and encrypted reasoning replay explicitly scoped.
- Anthropic, OpenAI-compatible, Ollama, and other protocols keep translation isolated in their owning adapters.

## Model Discovery
- Provider/template aliases stay aligned with registry identities.
- Family-level metadata may cover newly introduced model variants when exact catalog metadata lags.
- Provider model discovery and core model options reuse one provider-owned service.
- Codex model discovery uses the shared versioned service, hidden-entry filtering, priority ordering, and curated forward-compatible aliases.
- Dynamic model ids normalize transport-only prefixes before reaching provider-neutral layers.
- Generic model resolution strips an optional provider prefix and falls back to configured model when no override is supplied.

## Rate Limits and Retry
- Apply rate limiting per provider instance; zero means unlimited, and provider-side 429 cooldown affects every session using that instance.
- A 5xx response is a rate limit only when body/header evidence explicitly signals throttling or a trusted reset; connection resets remain network failures.
- Resolve trusted retry timing in order: retry-after milliseconds, standard Retry-After, provider reset headers tied to zero remaining, then explicit reset timestamps in the response body.
- Preserve trusted long-duration resets; quota-style throttling without a trusted reset remains blocked for manual recovery.
- Transparent network retry is allowed only before the first provider event and permits at most two automatic retries.
- Any reasoning, metadata, content, tool, or state event closes the transparent-retry window.
- Deterministic E2E adapter selection requires explicit E2E mode and isolated mutable state, and still traverses runner, persistence, and canonical delivery.
