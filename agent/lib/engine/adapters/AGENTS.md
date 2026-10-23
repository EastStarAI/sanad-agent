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
- Opaque continuation state uses a typed namespace and issuer; replay only when both match the current instance/protocol/normalized endpoint owner and the recorded producing model equals the destination model. Missing model provenance is foreign.
- Projection is per request and never rewrites canonical history. Provenance keys are additive inside adapter-owned state data; issuer strings stay stable.
- Never copy, pad, relabel or synthesize reasoning for foreign or unrecorded turns. Echo semantics come only from the destination's exact models.dev `interleaved.field` and the data-driven `ChatReasoningReplayPolicy` table; same-route assistant tool turns on echo-required thinking routes replay the provider's zero-reasoning shape (`""`) for absent or null reasoning to satisfy thinking-mode protocol without fabricating reasoning text. Probe outcomes change data, not logic.
- History with no truthful wire representation fails before HTTP with `ProviderHistoryProjectionException` carrying only route, closed reason code and count. Wire measurement never raises it; dispatch and the summarizer always enforce.
- Anthropic signed or redacted thinking replays only to the same issuer and model; unpaired `tool_use` fails closed rather than being stripped.
- State rejection may clear only matching keys and may trigger one bounded persisted fallback.
- Never replay local reasoning ids as provider wire state.
- Malformed tool arguments fail before execution and must not become an empty object.

## Request Consistency
- Sync and stream for one protocol reuse the same request builder and final normalization.
- Diagnostic response dumps use the same aggregated normalized assistant message, tool calls, finish reason, and usage exposed by the adapter; interrupted streams may record a bounded partial projection plus the error, never raw SSE lines.
- Request dumps never contain any part of a credential: credential-bearing headers and fields (`Authorization`, `x-api-key`, `api-key`, `api_key`, tokens) are masked by name at the dumper boundary, and the top-level key records presence only.
- Structured reasoning fields take precedence over textual thought tags.
- Codex Responses transport reuses its codec, SSE accumulator, policy, and model service; do not implement parallel contracts in the adapter.
- Per-model catalog wire: only a template with `catalogModelWire` may dispatch a model on the wire its exact models.dev entry declares (`provider.npm` `@ai-sdk/openai` → Responses, `@ai-sdk/anthropic` → Messages) at that entry's https `provider.api`. Resolve it once into `RouteSignature` (`protocol`, `normalizedBaseUrl`, `apiMode`) and derive the adapter profile with `ProviderProfile.withRouteWire`; never guess an endpoint, use a model-name table, substitute a provider or copy credentials. A missing package or `provider.api` keeps the configured wire, and unchanged Chat routes keep their exact issuer string.
- `CodexResponsesAdapter` is a generic API-key Responses client (bearer key, `{base}/responses`, `store: false`). Codex-only behavior such as model discovery stays gated on the `openai-codex` profile.
- Adapter-owned wire measurement fingerprints instructions, tools, and ordered input items. When a later request is a strict wire extension, provider-confirmed input remains authoritative and only the appended wire suffix is estimated.
- Codex Responses API requires `stream: true` on every request; the sync `generateResponse` path sends a streaming request and consumes the SSE events internally, returning one complete `AgentResponse` — callers see no difference.
- Responses requests keep server storage disabled and encrypted reasoning replay explicitly scoped.
- Anthropic, OpenAI-compatible, Ollama, and other protocols keep translation isolated in their owning adapters.
- Exact model thinking facts never override the active serializer: aggregators retain their reasoning envelope, native finite values retain their wire types, and provider Default is omission rather than a guessed effort.

## Rich Tool-Result Translation
- Rich tool results are validated and mapped from canonical ordered blocks by the shared provider-neutral wire codec; adapters must not read paths, process image bytes, or mutate canonical messages.
- Codex Responses emits ordered `input_text`/`input_image` function outputs, preserves `call_id`, and maps canonical `original` detail to wire `high`.
- Anthropic emits nested text/image `tool_result` content, preserves `tool_use_id`, omits detail, and emits `is_error: true` only for typed failures. Legacy text-only output remains a wire string.
- Native tool-result media capability is a closed protocol declaration: Responses and Anthropic opt into `imageToolResults`; transparent wrappers delegate exactly and fixtures choose explicitly. OpenAI-compatible Chat and native Ollama retain scalar tool content but may project images as outbound-only user context after a complete, correctly paired tool-result batch using the immutable admitted model capability. Ollama uses ordered native `images` arrays and native tool names; direct user attachments use the same verified attachment reader. Incomplete, orphaned, duplicate or mismatched image-bearing tool batches fail before HTTP dispatch. Never infer image capability from model names or provider failures.
- Unknown and unsupported image-bearing requests fail closed before dispatch; generic tool support does not veto valid image input. Legacy text-only projection retains scalar tool identity and one omission marker only for explicitly non-dispatch compatibility projections. It never authorizes lossy live dispatch, canonical history mutation or retry/failover.

## Model Discovery
- `OpenAiCompatibleModelDiscovery` (`agent/lib/engine/adapters/openai_compatible/model_discovery.dart`) owns the OpenAI-compatible identity normalization, fallback catalog, endpoint candidates, label formatting, and the agentic/reasoning/context heuristics as pure static rules; the adapter keeps transport, mutable discovery outcome state, and the `models.dev` service. `OpenAiCompatibleThinkingDiscovery` (`agent/lib/engine/adapters/openai_compatible/thinking_control_discovery.dart`) owns the Kimi, native LM Studio, and OpenRouter control declarations and their mapping onto the owned wire; transport, headers, and logging stay with the adapter and reach it only as typed callbacks.
- Provider/template aliases stay aligned with registry identities.
- Selectable thinking controls/defaults come only from the five-layer authority in `agent/lib/core/AGENTS.md`: settings, provider-reported metadata, shipped defaults data, models.dev vendor entry, then the models.dev canonical entry. Model names appear only in that data, never in adapter or policy logic; family names, output-reasoning flags, and speculative future variants never authorize controls.
- Kimi reasoning discovery consumes only the registered `kimi` template's per-item `supports_reasoning`, thinking type and finite effort declaration (`think_efforts` and/or `reasoning.effort`, which must agree). It writes an owned `openai_chat_effort` declaration only for the always-on `only` type with a complete, consistent positive effort set, and otherwise leaves discovery untouched.
- `ModelsDevService.modelEntrySync` reads only the serving vendor's exact model key from the hydrated cache, with no network, aliasing or cross-vendor inference.
- A local native model-list probe may enrich a compatible route only from a single exact model-identity match, may advertise only values declared by that endpoint that also have an evidenced wire equivalent for the route's actual protocol, and must leave discovery untouched when the probe fails or its evidence is malformed or ambiguous; native-only values and unmappable defaults stay unadvertised. Repeated aliases of one native entry count once; distinct matching entries remain ambiguous. Native discovery reuses the configured discovery authentication and never replaces an existing compatibility-endpoint declaration.
- Aggregator reasoning discovery consumes only its registered wire's per-item documented finite effort declaration for the exact model identity, and raw evidence stays the verbatim discovery member separate from the enriched declaration. Admissibility comes from the shared `ThinkingWireVocabulary`, so every documented canonical effort value (`max`, `xhigh`, `high`, `medium`, `low`, `minimal`, `none`) is declared with its own exact value: no documented set is reduced, clamped, promoted or aliased, and an explicit `null` documents all of them in documented descending order. A names-only or no-`reasoning` identity publishes nothing and never vetoes intrinsic model knowledge. A present-but-unusable `reasoning` declaration — no documented effort selector, a malformed value or flag, a default inconsistent with the documented set, or a conflicting or mixed missing/present duplicate claim for one exact identity — publishes explicit `unknown` route-control evidence for that exact route instead of adopting an unrelated intrinsic ladder, while model-owned image, reasoning-output, context and other discovery facts stay untouched. An omitted effort member, an explicit null set and an empty set stay distinct; a documented mandatory route advertises no disable and refuses a stale disable; an off-by-default model preselects nothing; provider default is always request-field omission; budget support creates no choice, default or bound.
- Provider model discovery and core model options reuse one provider-owned service.
- Codex model discovery uses the shared versioned service, hidden-entry filtering, priority ordering, and curated forward-compatible aliases.
- Dynamic model ids normalize transport-only prefixes before reaching provider-neutral layers.
- Generic model resolution strips only an explicitly owned transport provider prefix, preserving catalog namespaces, casing and variant markers; it falls back to the configured model only when no override is supplied.

## Rate Limits and Retry
- Apply rate limiting per provider instance; zero means unlimited, and provider-side 429 cooldown affects every session using that instance.
- A 5xx response is a rate limit only when body/header evidence explicitly signals throttling or a trusted reset; connection resets remain network failures.
- Resolve trusted retry timing in order: retry-after milliseconds, standard Retry-After, provider reset headers tied to zero remaining, then explicit reset timestamps in the response body.
- Preserve trusted long-duration resets; quota-style throttling without a trusted reset remains blocked for manual recovery.
- Transparent network retry is allowed only before the first provider event and permits at most two automatic retries.
- Any reasoning, metadata, content, tool, or state event closes the transparent-retry window.
- Deterministic E2E adapter selection requires explicit E2E mode and isolated mutable state, and still traverses runner, persistence, and canonical delivery. Image fixtures declare model capability through isolated configuration, resolve attachment references only through the supplied session-scoped store, and derive pixel answers only from completed typed tool results.
