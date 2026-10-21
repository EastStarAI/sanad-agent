---
id: 120
title: OpenCode Go per-model wire protocol
status: completed
gate: accepted
created: 2026-10-21
parent_task: none (split from 106)
depends_on: [116]
delivery: own PR
---

# Task 120 — OpenCode Go Per-Model Protocol

## Goal

OpenCode Go models served on OpenAI Responses or Anthropic Messages are dispatched on their own wire, so their turns complete instead of failing with `ModelProtocolUnsupported`.

## Origin

Live round 1 of [Task 106](docs/plans/tasks/done/106-compaction-resilience-and-token-estimation-repair.md) (finding D3). The [Task 115](docs/plans/tasks/done/115-post-201-provider-thinking-route-admission-regression.md) repair gives OpenCode Go `gpt-6-luna` a truthful thinking descriptor, but Sanad still sends it to the instance's Chat Completions endpoint while OpenCode Go serves it only on Responses.

## Evidence

- OpenCode Go documentation (fetched 2026-10-21): `gpt-6-luna`, GPT 5.6 Luna, Grok 4.7 and Muse Spark use `/openai/v1/responses`; Claude Haiku 5.5, MiniMax M3 and Qwen3.7/3.8 use `/anthropic/v1/messages`; Kimi, GLM, DeepSeek and MiMo use `/openai/v1/chat/completions`.
- The models.dev `opencode-go` entries carry per-model `provider.npm` (for example `@ai-sdk/openai`). The documented base (`/inference/go/...`) differs from the template default `https://opencode.ai/zen/go/v1`.

## Scope

- Resolve a per-model wire override in `AgentRuntimeService.resolveSignature` from the hydrated models.dev entry (protocol, `apiMode`, base URL from the catalog `provider.api`, never guessed) and freeze it into `RouteSignature`.
- Consumers: `AgentRuntimeService._buildAdapter` (`agent/lib/core/agent_runtime_service.dart`), `ThinkingRoutePolicy.apiModeFor`, the adapter cache, route profile and image capability, compaction projection and measurement, request dumps and `ModelsDevThinkingWire.forRoute`.
- Validate `CodexResponsesAdapter` as a generic API-key Responses client, or add the smallest compatible path; check `BaseAnthropicAdapter` auth headers against Go's `/anthropic/v1`.
- The opencode-go template in `agent/lib/core/provider_registry.dart`.

## Boundaries

- **Issuer stability:** provider-state issuers include protocol and endpoint. Unchanged Chat routes must keep their current issuer, or this task declares an explicit issuer-equivalence set that [Task 116](docs/plans/tasks/done/116-deepseek-reasoning-replay-across-tool-history.md)'s replay policy consumes. Existing DeepSeek/GLM/Kimi history must not become foreign.
- No guessed endpoints, no per-model name tables, no provider substitution or credential copying.
- Mixed-wire history within one instance (Chat → Messages → Chat) uses 116's projection rules; do not replay foreign opaque state.

## Gates

- [x] Wire fixtures for Responses and Messages against Go-shaped endpoints, and provider-state round-trips across a same-instance protocol change.
- [x] Regression: unchanged Chat models keep the same issuer and wire.
- [x] Owning docs: `docs/technical/provider_protocol.md`, `agent/lib/engine/adapters/AGENTS.md`.
- [x] Independent review and delegated Sanad live acceptance on the Test Home: Go `gpt-6-luna` with a thinking selection, and one Messages-served model, with explicit scalar evidence.

## Dependencies

- Depends on [Task 116](docs/plans/tasks/done/116-deepseek-reasoning-replay-across-tool-history.md): 116 lands the model stamp and issuer comparison first.

## Implementation Round 1 — 2026-10-21 (writer record, unreviewed)

- Base `0a6d85ae`, branch `fix/120-opencode-go-per-model-protocol`. No commit, push, live call or runtime action.
- **Resolution.** `ProviderModelWire` (`agent/lib/core/provider_runtime/provider_model_wire.dart`) maps the serving vendor's exact models.dev entry: `provider.npm` `@ai-sdk/openai` → Responses (`codex_responses`), `@ai-sdk/anthropic` → Messages. The base URL is the entry's own https `provider.api`. It applies only to templates with the new `ProviderProfile.catalogModelWire` flag (`opencode-go`). A missing package or `provider.api`, a Google or openai-compatible package, a custom instance or a non-opted template keeps the configured wire.
- **Freeze.** `resolveSignature` writes the wire into `RouteSignature` (`protocol`, `normalizedBaseUrl`, and an additive `apiMode` included in equality). `_buildAdapter` derives the profile with `ProviderProfile.withRouteWire`. The compaction route persists `api_mode` in an additive nullable column, including on fork copy. The wire proof adds `api_mode` only when it is set.
- **Thinking.** `ThinkingCapabilityAssembler.routeInstance` gives a transient per-model instance view (`ProviderInstance.routeTemplate`). It is applied in `resolveLayer`/`assemble` and in `ThinkingSelectionResolver.resolve`, so `apiModeFor`, `policyIdFor`, `isWireCompatible` and `ModelsDevThinkingWire.forRoute` all see the dispatched wire.
- **Issuer stability.** Chat models keep the template base `https://opencode.ai/zen/go/v1` and the issuer `<id>|openai_compatible|<base>` byte-for-byte; no equivalence set is needed. New issuers are `<id>|codex_responses|https://opencode.ai/inference/go/openai/v1` and `<id>|anthropic_compatible|https://opencode.ai/inference/go/anthropic/v1`.
- **Auth.** `CodexResponsesAdapter` already works as a generic API-key Responses client (bearer key, `{base}/responses`, `store: false`); Codex discovery stays gated on `openai-codex`. `BaseAnthropicAdapter` sends `x-api-key` plus `anthropic-version` to `{base}/messages`. That matches the `@ai-sdk/anthropic` default the Go docs name, but it has no live evidence yet.
- **Tests.** `agent/test/core/provider_runtime/opencode_go_model_wire_routing_test.dart` (runtime routing plus the Chat issuer regression) and `agent/test/engine/adapters/opencode_go_model_wire_test.dart` (wire fixtures, Chat → Responses → Messages → Responses → Messages → Chat round-trip, signature, thinking, compaction persistence). `layered_thinking_authority_test.dart` now dispatches on the routed wire, so Go `gpt-6-luna` asserts `reasoning.effort`.
- **Recorded gap (not changed).** Responses `reasoning_items` are still not model-stamped (Task 116 D6). Go Responses models such as `gpt-6-luna` and `grok-4.7` share one issuer, so a cross-model encrypted replay is possible; it relies on the bounded `invalid_encrypted_content` recovery.
- Remaining: independent review and delegated live acceptance on the Test Home.


## Acceptance — 2026-10-21

- **Coordinator review.** `fvm dart analyze` clean. Focused tests: 295 passed (the two new wire test files, layered thinking authority, adapters). Writer full suite: +2915 ~14.
- **Live acceptance on a Test Home (OpenCode Go).**
  - `gpt-6-luna` on Responses with thinking High: URL `/inference/go/openai/v1/responses`, `reasoning.effort=high`, `store=false`, HTTP 200. Encrypted reasoning replayed on the follow-up with no `invalid_encrypted_content`. Issuer `<id>|codex_responses|https://opencode.ai/inference/go/openai/v1`.
  - `claude-haiku-5-5` on Messages: `x-api-key` and `anthropic-version` headers, adaptive thinking with effort high, HTTP 200 (no 401). Signed thinking replayed first.
  - Switch to `deepseek-v4.1-flash`: unchanged Chat URL and issuer, with no foreign opaque state replayed.
  - A compaction on the Responses route persisted `api_mode=codex_responses`. The compaction itself failed with `projection_still_over_budget` on a very small session. This predates Task 120 (the same failure occurred on DeepSeek before 120) and is moved to [Task 118](docs/plans/tasks/118-compaction-accuracy-and-target.md) for review.
- **Residual risks.**
  - Codex/Responses reasoning is not model-stamped across Go Responses models that share one issuer (follow-up task).
  - A catalog `provider.api` overrides a user-custom base URL for opted-in templates.
  - Chat models stay on the legacy `zen/go/v1` base for issuer stability.
