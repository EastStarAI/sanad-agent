---
id: 120
title: OpenCode Go per-model wire protocol
status: planned
gate: blocked-on-116
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

- **Issuer stability:** provider-state issuers include protocol and endpoint. Unchanged Chat routes must keep their current issuer, or this task declares an explicit issuer-equivalence set that [Task 116](docs/plans/tasks/116-deepseek-reasoning-replay-across-tool-history.md)'s replay policy consumes. Existing DeepSeek/GLM/Kimi history must not become foreign.
- No guessed endpoints, no per-model name tables, no provider substitution or credential copying.
- Mixed-wire history within one instance (Chat → Messages → Chat) uses 116's projection rules; do not replay foreign opaque state.

## Gates

- [ ] Wire fixtures for Responses and Messages against Go-shaped endpoints, and provider-state round-trips across a same-instance protocol change.
- [ ] Regression: unchanged Chat models keep the same issuer and wire.
- [ ] Owning docs: `docs/technical/provider_protocol.md`, `agent/lib/engine/adapters/AGENTS.md`.
- [ ] Independent review and delegated Sanad live acceptance on the Test Home: Go `gpt-6-luna` with a thinking selection, and one Messages-served model, with explicit scalar evidence.

## Dependencies

- Depends on [Task 116](docs/plans/tasks/116-deepseek-reasoning-replay-across-tool-history.md): 116 lands the model stamp and issuer comparison first.
