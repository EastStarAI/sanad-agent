---
title: "بروتوكول مزودي نماذج اللغة"
description: "بروتوكول إعداد مزودي LLM والمصادقة والتخزين واختيار النموذج في Sanad Agent."
---

# Provider Protocol & Storage

> **Scope:** LLM provider setup, authentication, readiness, and model selection over the Sanad socket/canonical protocol.
> **Parent contract:** `sanad-agent/agent/AGENTS.md`, `sanad-agent/agent/lib/interfaces/AGENTS.md`

## Overview

The agent owns the LLM Provider Runtime. It is the single source of truth for:
- The list of supported providers (`ProviderRegistry`).
- Per-provider auth state (configured / authenticated / expired / relogin_required).
- The active provider and default model.
- Runtime readiness (can the daemon actually issue an LLM request right now).

Both the CLI setup wizard and the Flutter onboarding/settings UI consume these services through the same socket/canonical protocol commands. The client must not hardcode a provider list or fall back to legacy provider-wide aliases.

## Storage

| Store | File | Contents |
|---|---|---|
| Env file | `.env` (local or `~/.sanad/.env`) | Simple API keys, base URLs, model names, `ACTIVE_PROVIDER`, `LLM_MODEL` |
| Provider credential store | `~/.sanad/provider_auth.json` | OAuth access/refresh tokens, expiry, scope, status |
| Secret store (Plan 29) | `~/.sanad/provider_secrets.json` | Instance-keyed `SecretRecord` (API key OR OAuth bundle) + masked `SecretSummary`. Atomic temp+rename, cross-process `FileLock`, owner-only (`chmod 600` / Windows ACL). Never logged raw. |
| Provider instances tables | `~/.sanad/state.db` (or `$SANAD_STATE_HOME/state.db`) — shared with sessions | `provider_instances` metadata + revisions, `provider_model_cache`, `recent_model_selections` — **no secrets** (Plan 29). Owned by the single `AgentStateDatabase` connection. |
| Sanad auth | `~/.sanad/auth.json` | Device identity (`hardware_id`, device token) — **never** LLM provider secrets |

Rules:
- OAuth providers (`openai-codex`, `xai-oauth`, `nous`) must not store long-lived tokens in `.env`.
- `.env` may keep only the active selection and non-secret values (`ACTIVE_PROVIDER`, `LLM_MODEL`, base URL).
- Removing a provider clears only its own keys; other providers are untouched.
- When provider metadata and secrets share the same Sanad Home boundary, credential mutations reconcile stored secret ids against authoritative provider-instance UUIDs and remove orphaned records left by deleted or interrupted setup attempts. Replacement still overwrites exactly the targeted instance record and preserves every other live instance. An explicit isolated `SANAD_STATE_HOME` disables this pruning because the shared secret store may contain credentials owned by another state database.
- Changing the active provider never deletes other providers.

## Template / Instance Model (Plan 29)

The Provider Runtime separates a static **template** from dynamic, user-created **instances**:

- **`ProviderTemplate`** — an immutable [`ProviderProfile`](../../agent/lib/engine/adapters/provider_profile.dart) in `ProviderRegistry`. Describes the wire `protocol` (`openai_compatible` \| `anthropic_compatible`), advertised `auth_methods[]`, `api_key_requirement` (`required` \| `optional`), default base URL, fallback models, and model-fetch capability. It never holds a secret, a selected model, or any user state. The reserved `custom` template lets the user build an OpenAI-compatible or Anthropic-compatible instance without a hardcoded gateway name.
- **`ProviderInstance`** — a user-created connection with a stable **UUID** identity, an editable `displayName`, an independent credential and default model, and lifecycle revisions (`config_revision`, `credential_revision`). Multiple instances may share one template (e.g. `OpenAI Work` and `OpenAI Personal`). The UUID is the permanent routing identity; renaming never changes it, so routing, cache, and sessions are never broken by a rename.

Instances persist in `state.db` (three Plan 29 tables shared with sessions) via `ProviderInstanceRepository` (see [agent_database_schema.md §4](agent_database_schema.md)). The single `AgentStateDatabase` connection is shared with `SessionDB` so `state.db` is never opened twice. Display names are unique case-insensitively within the runtime. At most one instance is `is_default` at a time — enforced at the DB level by a partial unique index (`idx_provider_single_default`) and by the `setDefault()` transaction. Deleting an instance cascades to its model cache and recent selections.

The constant vocabulary (`ProviderProtocol`, `ApiKeyRequirement`, `ProviderAuthMethod`, `InstanceStatus`, `CredentialAction`, `kCustomProviderTemplateId`) lives in [`provider_protocol_constants.dart`](../../agent/lib/core/provider_runtime/provider_protocol_constants.dart) and MUST be used instead of raw literals. Instance creation validates `auth_method` against the selected template's `effectiveAuthMethods`; being globally recognized is not sufficient. Current production templates advertise exactly one method, so clients derive it rather than asking the user to choose it.

Provider-specific request metadata belongs to the owning template's `defaultHeaders` and is merged into every compatible chat-completion request path. The OpenRouter template sends its documented app-attribution pair, `HTTP-Referer: https://sanad.eaststarai.com` and `X-OpenRouter-Title: Sanad Agent`, for both synchronous and streaming requests. Other provider templates do not inherit these headers, and the legacy `X-Title` spelling is not emitted.

### Credential edit contract (Plan 29 §7.5)
Editing an instance never re-requests a credential unless explicitly asked. This applies to all auth methods: editing an existing OAuth/device-code/loopback instance saves metadata (Display Name, auto-failover) and returns to the configured list without starting a new auth session. OAuth re-authentication is triggered only during initial setup or through the explicit reconnect action. The action is one of `keep` (default) \\| `replace` \\| `remove`. An empty field never implies `remove`. `replace` without a value is rejected. The actual secret is never returned to the client or CLI; only a masked `summary` is exposed. Its canonical wire fields are `configured`, `auth_method`, `status`, optional `masked_key_hint`, optional `account_label`, optional `account_name`, optional `expires_at`, and `relogin_required`. Flutter must derive stored-credential presentation from `configured`, display the API-key hint from `masked_key_hint`, and render OAuth identity only from the optional daemon summary fields; it may accept the former client aliases `has_secret` and `masked_secret` only as read-time migration fallbacks.

For OAuth/device-code approval, the daemon derives display identity locally from the ID token when present, otherwise from a JWT-shaped access token. The account-label priority is `email`, `preferred_username`, `upn`, then `name`; `account_name` uses `name`. Blank or non-string claims and opaque/malformed tokens produce no identity metadata. Claim decoding is deliberately non-verifying because these fields are presentation hints only: OAuth approval remains the authentication authority, the values never affect readiness or routing, and raw tokens never enter the credential-summary protocol. Existing stored records are enriched lazily when read, so already-connected accounts can gain labels without reconnecting.

Replacing or adding an API key on an existing instance increments `credential_revision`, invalidating model verification tied to the previous credential. Flutter therefore follows a successful `provider.credential.update(action=replace)` with `provider.instance.test` and reports the edit as complete only after the canonical `success: true` result. A failed test leaves the daemon-owned instance non-ready and keeps the edit surface open with safe feedback that distinguishes “key saved” from “connection verified.” `keep` remains non-mutating, and `remove` intentionally leaves required-key instances in `needs_auth`.

## Services (`sanad-agent/agent/lib/core/provider_runtime/`)

| Service | Responsibility |
|---|---|
| `ProviderCatalogService` | Builds the provider list from `ProviderRegistry`. |
| `ProviderInstanceRepository` | SQLite CRUD for `ProviderInstance` rows, default constraint, name uniqueness, model cache, and recent selections (Plan 29). |
| `ProviderInstanceService` | Instance CRUD + validation + name suggestion + draft/ready/default lifecycle + rename that preserves UUID/credential/cache (Plan 29 §8.1). |
| `ProviderCredentialService` | `keep` \| `replace` \| `remove` credential edits + masked summaries + `credentialRevision` bumps + OAuth bundle writes/disconnect; keyed by instance UUID (Plan 29 §7.5, §8.1). |
| `SecretStore` / `SecureFileSecretStore` | Instance-keyed credential storage (`read`/`write`/`summary`/`remove`/`listIds`). Atomic, locked, owner-only. Returns masked `SecretSummary` to clients; raw `SecretRecord` only to the resolver (Plan 29). |
| `ProviderStateService` | Reads `.env` + credential store → `configured`, `authenticated`, `is_current`, `auth_status`. |
| `ProviderCredentialStore` | File-backed OAuth session storage (`provider_auth.json`). |
| `ProviderCredentialResolver` | Resolves a usable credential at runtime; refreshes OAuth tokens or surfaces `relogin_required`. |
| `ProviderAuthSessionService` | Drives device-code / loopback / external OAuth flows (start/poll/cancel). |
| `ProviderReadinessService` | `setup_status` (storage check) and `runtime_check` (credential resolution check). |
| `ProviderConfigService` | Saves/removes API keys and custom endpoints in `.env`. |
| `ModelOptionsService` | Fetches live model lists or falls back to registry presets. |
| `ModelSelectionService` | Persists active provider + default model. |
| `EnvFileService` | Reads/writes `.env` preserving comments. |

Model fetch contract details:
- Provider Base URLs are trimmed, trailing slashes are removed, and copied field labels (`url `, `base_url `, `base-url `, or `endpoint `) are stripped case-insensitively before persistence or use. Only absolute `http` and `https` URLs are accepted for new metadata. This read-time normalization also repairs legacy rows such as `url https://api.cursor.com/v1` without requiring a database rewrite.
- OpenAI-compatible discovery must prefer the configured base URL as-is and fetch `.../models`, but custom/local gateways may expose the catalog under `.../v1/models`; the runtime must retry that path before falling back to presets. A base URL already ending in `/v1` or `/models` produces one canonical candidate and must never become `/v1/v1/models` or `/models/models`.
- Model-cache refresh coalescing owns cleanup inside the same awaited Future; it must not create a detached error-propagating `whenComplete` Future. A failed refresh keeps a non-empty prior successful list as `cache_stale`. Without usable prior models it persists `source=failed` plus `last_error` and rethrows so `model.refresh` emits terminal `failed`, never `updated` with an empty failed row. The detached gateway workflow contains both refresh and terminal-event delivery failures so neither can terminate the daemon event loop.
- Anthropic-compatible discovery must resolve `.../v1/models` from a root base URL (or `.../models` when the configured base already ends with `/v1`). Native Anthropic Messages requests authenticate with `x-api-key` plus the required `anthropic-version` header. Some Anthropic-compatible local/proxy gateways expose the same catalog only through `Authorization: Bearer ...`; in that case model discovery must retry with bearer auth before falling back. The main Sanad Anthropic adapter should keep native request execution on `x-api-key` by default and use bearer auth only as a compatibility fallback unless the runtime later adds an explicit auth-mode contract.
- When live discovery fails, the fallback list must preserve the instance's selected/default model and merge it with the template's curated fallback models so the picker never collapses to an unrelated single model.
- Model metadata returned by discovery is runtime input, not presentation-only data. `context_window` is persisted with each `ModelOption`; `AgentRuntimeService` supplies adapters with an instance-scoped lookup that accepts only cache rows matching the route's config and credential revisions and the exact normalized model id. Context-limit precedence is explicit `config.yaml` override, matching instance catalog, adapter/provider metadata (including `models.dev` for Codex Responses), known static metadata, then the adapter fallback. Codex forward-compatible GPT-6 aliases may inherit a positive window only from the live GPT-6 template that caused the alias to be offered; absent or invalid template metadata remains unresolved so the later sources decide it. Unknown OpenAI-compatible and Ollama models retain the conservative `4000` fallback because inflating an unverified local/small model window can suppress required compaction and cause provider overflow. A model discovered after the Sanad release therefore does not require a hardcoded model-name condition to receive its advertised context window.
- `provider.instance.create` must never crash the daemon on validation failures such as duplicate display names. The response must come back on `provider.instance.created` with an `error` payload so the client can render an inline validation message.
- **Connection Test Verification**: To ensure that the connection test command (`provider.instance.test`) fails properly when endpoints are offline or misconfigured, it queries the resulting model cache metadata directly after performing the manual refresh. If `last_error` is populated, or if the cache `source` is set to `'fallback'` or `'cache_stale'` (indicating that live fetch failed and the adapter fell back to local/cached presets), the test fails with `success: false` and returns the actual connection error details to the UI/CLI.

## Socket Commands

All commands are transport-agnostic (work over local daemon WebSocket and cloud Sanad Gateway). Every response carries `request_id`.

### Readiness

| Command | Response event | Description |
|---|---|---|
| `provider.setup_status` | `provider_readiness_result` | Storage-only check: is there a configured provider + model? |
| `provider.runtime_check` | `provider_readiness_result` | Deeper check: can the runtime resolve credentials + model? |

### OAuth Sessions

| Command | Response event | Description |
|---|---|---|
| `provider.auth.start` | `provider_auth_started` | Starts a device-code/loopback flow; returns `session_id`, `user_code`, `verification_uri`. |
| `provider.auth.poll` | `provider_auth_polled` | Polls an in-flight session: `pending`, `approved`, `expired`, `error`. |
| `provider.auth.submit` | `provider_auth_polled` | Submits a manual code. |
| `provider.auth.cancel` | `provider_auth_cancelled` | Cancels and cleans up a session. |
| `provider.auth.status` | `provider_auth_status_result` | Returns `authenticated`, `expired`, `relogin_required`, or `missing`. |

### Model Selection

| Command | Response event | Description |
|---|---|---|
| `model.options` | `model_options_result` | Returns per-provider model lists with auth state and warnings. |

### Plan 29 — Instance & Model Cache Commands

These commands supersede the legacy provider commands for multi-instance support.
All responses carry `request_id`. Instance mutations broadcast
`provider_instances_changed` to the sanad_client family after the response.

| Command | Response event | Description |
|---|---|---|
| `provider.templates.list` | `provider.templates.result` | Returns all templates with `protocol`, `api_key_requirement`, `auth_methods[]`. |
| `provider.instances.list` | `provider.instances.result` | Returns all instances with credential summaries (no secrets). |
| `provider.instance.create` | `provider.instance.created` | Creates a draft instance (UUID, displayName, templateId, authMethod, protocol, baseUrl). |
| `provider.instance.update` | `provider.instance.updated` | Updates metadata (displayName, baseUrl, defaultModel, protocol). |
| `provider.instance.rename` | `provider.instance.renamed` | Renames an instance (UUID stable). |
| `provider.instance.remove` | `provider.instance.removed` | Deletes an instance + cascades cache/recent/secret. |
| `provider.instance.set_default` | `provider.instance.default_changed` | Promotes one instance to default. |
| `provider.instance.test` | `provider.instance.test_result` | Tests endpoint/model connectivity without making it default. The result carries canonical Boolean `success`; clients must not infer success from an absent `status` string. |
| `provider.credential.update` | `provider.credential.updated` | `keep` \| `replace` \| `remove` for API-key instances. |
| `provider.auth.reconnect` | `provider_auth_started` | Re-runs OAuth for an existing instance. |
| `provider.auth.disconnect` | `provider.credential.updated` | Deletes OAuth tokens; instance metadata stays. |
| `model.snapshot` | `model.snapshot_result` | Returns cached models per instance (stale-while-revalidate), including `status` so clients can render true runtime readiness from the instance lifecycle instead of inferring it from cache presence. Model ids are instance-local: redundant `<template>/` prefixes and Gemini's `models/` transport prefix must already be stripped. Each model entry may include `supports_reasoning_output` and a per-model `thinking_control` descriptor (Task 43). |
| `model.refresh` | `model.cache_updated` | Refreshes models for an instance; **all events (started/updated/failed) carry the original `request_id`** and clients must complete the request only on `updated`/`failed`, never on `started`. |
| `model.recent.list` | `model.recent.recent_result` | Returns last 5 selections with current display names, using the same normalized instance-local model ids as `model.snapshot`. |
| `model.recent.record` | `model.recent.recent_recorded` | Records a model selection (upsert, moves to top). |

### Client Provider Catalog Freshness & Composer Synchronization

Composer components (`_ModelChip`, `ConversationBottomActions`) display the active model along with its provider's friendly name (e.g., `Custom Provider | llama-3`). The client manages provider display names centrally in `ProviderUsageCubit`:
- **Shared Per-Device Resource**: Display-name catalogs are keyed strictly per device (`_catalogRevisions[deviceId]`), preventing cross-device leakage and decoupling catalog invalidation from per-instance usage/support request generations (`_deviceRevisions`).
- **Immediate Mutation Sync**: When provider instances are created, renamed, or deleted within `ProviderSetupFlow`, the flow publishes updated names directly to `ProviderUsageCubit.updateProviderDisplayNames` strictly from authoritative snapshot generation boundaries (`snapshotGeneration > 0`) emitted by successful cubit loads or mutations. The composer reflects the updated name immediately without requiring an application restart.
- **Publication Boundary Safety**: UI navigation (e.g. `backToPicker`, `backToInstances`), error clearing, auth cancellations, and load errors never advance `snapshotGeneration` and never publish or wipe the existing catalog. Cached names are preserved across failures and transitions; only authoritative successful removal of an instance clears its display name.
- **Race Condition Guard**: A monotonic per-device catalog revision counter bails out any delayed, in-flight pre-mutation responses from reinstalling stale display names. Generation authority persists across device clears to eliminate ABA races where pre-clear requests match generation 0, and authoritative mutation snapshots (including empty removals) neutralize in-flight loads.
- **Unrelated Resource Isolation**: Updating or invalidating the display-name catalog never aborts or drops in-flight usage/support fetches, ensuring seamless UI operations. Quiescent identical name updates with no in-flight fetch are strict no-ops.

### Client Route Thinking Control Refresh Lifecycle

Mounted composer controls (`RouteThinkingModeSelector`) display model-scoped thinking mode options, labels, and defaults. The client synchronizes these controls with daemon model updates without requiring route transitions or application restart:
- **Authoritative Stream Projection**: `ProviderSetupClient.modelUpdates` projects incoming `model.cache_updated` socket events into typed `ModelCacheUpdateEvent` models carrying `providerInstanceId`, `status`, `deviceId`, and optional error details.
- **Terminal Event Admission**: `RouteThinkingModeSelector` subscribes to `modelUpdates` and triggers snapshot revalidation strictly on terminal `updated` events for the active route's provider instance and matching device.
- **Freshness Arbitration**: `RouteThinkingControl.resolveDescriptor` arbitrates between session-stored descriptors and authoritative model snapshots. When an authoritative snapshot provides a differing `capabilityRevision`, reflects control removal (`null`), or reports `unsupported`, the snapshot descriptor takes precedence over same-route session cache.
- **Selection Safety & Invalidation**: When refreshed options invalidate the current selection, selection is repaired visibly to the provider default (`null`); when the selection remains supported, it is retained.
- **Failure & Cross-Scope Isolation**: Terminal `failed` refresh events retain prior validated authority rather than resetting or clearing mounted controls. Events targeting other provider instances or foreign devices are safely ignored.

### Task 55 — Provider account usage limits (Gates A–C)

Provider account limits are instance-scoped account data, separate from both
per-turn token usage and runtime rate-limit recovery. The daemon resolves the
credential owned by the requested `provider_instance_id`; neither Flutter nor
the protocol payload receives an access token, account id, or raw provider
response.

| Command | Response event | Description |
|---|---|---|
| `provider.usage.support` | `provider.usage.support_result` | Returns a Boolean support map for requested instance ids so the client does not hardcode provider capabilities. |
| `provider.usage.get` | `provider.usage.result` | Returns `available`, `unsupported`, `unavailable`, `auth_required`, or `failed` plus a snapshot when available. |

A snapshot carries `provider_instance_id`, `provider_template_id`, `source`,
`fetched_at`, optional plan and safe details, non-negative `available_resets`,
and only the windows returned by the adapter. Version 1 window types are
`session`, `weekly`, and `monthly`. Percentages are normalized to `[0, 100]`,
and one side is derived when only used or remaining is supplied. Missing
windows never create placeholders.

The first adapter is ChatGPT account usage for `openai-codex`. It reads the
account backend with the selected instance's bearer credential and optional
account id. Adapter, service, and protocol failures do not mutate provider
readiness or prevent model execution.

Flutter owns a projection keyed by `device id + provider_instance_id`. Provider
cards render before capability or usage requests finish. Successful snapshots
are fresh for one minute; after that the existing snapshot remains visible
while a single background refresh runs. There is no polling. Manual Refresh
targets one instance, and device changes, deletion, disposal, superseding
requests, or mismatched instance responses cannot restore stale data. A failed
background refresh preserves the prior snapshot and adds an inline Retry or
sign-in message.

The `Usage & limits` disclosure is absent for unsupported instances. It renders
only returned windows, with remaining percentage first, used percentage second,
a local relative reset time with a full local timestamp tooltip, and an Updated
footer. Positive reset-credit counts expose the daemon-owned reset flow; zero or
unknown counts do not render a reset action.

Legacy provider-wide commands (`provider.list`, `provider.list_configured`,
`provider.save_api_key`, `provider.save_custom_endpoint`, `provider.remove`,
`provider.configured_options`, `model.recommended_default`, and
`model.set_default`) are removed from the transport contract in the Plan 29
runtime. New work must use the instance-first commands above.

Additional contract rules:
- The visible client flow is `template -> provider.instance.create -> provider.auth.start/provider.credential.update -> model.refresh/model.snapshot -> provider.runtime_check`. OAuth must not start before the instance UUID exists.
- `provider.auth.start` must reject requests that omit `provider_instance_id`; there is no compatibility fallback to template-keyed OAuth storage.
- `provider.instance.set_default` must reject any instance whose `status` is not `ready`.
- If a base URL, protocol, or credential revision changes, the instance must demote out of `ready` until a successful cache refresh verifies the current revisions again. For optional-key templates, removing the key demotes to `draft`, not `needs_auth`.
- Templates whose account-auth flow is not implemented yet must be omitted by `ProviderCatalogService` itself so CLI and client stay consistent.
- `get_capabilities` must not double as provider-model discovery. A fresh install with no provider instances must still answer `capabilities` successfully; model catalogs come only from `model.snapshot`, `model.refresh`, `model.options`, and readiness/setup commands.

### Task 43 — Provider-aware thinking controls (Gates A–C)

Device capabilities advertise whether the client understands model-scoped thinking
controls, not the selectable values themselves:

- `supports_thinking_mode_change`: device understands the thinking selector contract.
- `thinking_mode_source`: `model` when options come from the active model snapshot; legacy agents omit this field and clients treat `thinking_modes_list` as authoritative.
- `thinking_modes_list`: retained for backward compatibility only. Current agents emit an empty list when `thinking_mode_source` is `model`.

Each model entry in `model.snapshot_result.instances[].models[]` may include:

- `supports_reasoning_output`: whether the model may emit reasoning output.
- `thinking_control`: descriptor with `status` (`supported` | `unsupported` | `unknown`), optional `kind`, ordered `options[]` (`id`, English `label`, `is_off`, `is_provider_default`, optional `budget_tokens`), `default_option_id`, `capability_revision`, and `source`.
  - `budget_tokens` is an optional positive integer carried only by an option that is genuinely a token budget; it states the effective token count the exact route resolves for that option and is absent for Off, for effort/level/toggle options, and whenever the count is unknown. It is additive and independent of selection identity, so clients may disclose an effective budget without inventing one. Anthropic and Gemini budget options take it from the owning catalog's own budget resolution, and a declared `anthropic_budget` or `google_thinking` endpoint option takes it from its validated declared value. A disclosed count is a whole positive integer: a fractional, non-finite or otherwise malformed value is treated as unavailable rather than truncated, rounded or allowed to fail the metadata round-trip, so a malformed peer value never becomes a fabricated budget.
  - `default_option_id` and `is_provider_default` are native-default metadata only. An omitted, cleared or whitespace-only selection stays provider default by omission and emits no request field; a documented default is dispatched only when it is actually selected, and an unknown native default stays unknown.

Session payloads may also include `thinking_control` for the active route when the daemon can resolve it from the current model cache revision. Clients must ignore a route descriptor when its `capability_revision` or `route_revision` does not match the active route (Gate D).

Aggregator templates such as OpenRouter use `aggregator_upstream` thinking policy: capability follows the upstream vendor prefix in the model id (`anthropic/...`, `google/...`, `deepseek/...`, `openai/...`, etc.), and the chat-completions adapter emits OpenRouter's nested `reasoning` object instead of top-level `reasoning_effort`. A finite effort set declared by the gateway's own model metadata is authoritative for that exact route; an unusable declaration publishes explicit `unknown` route-control evidence instead of adopting an unrelated ladder, and no budget choice or default is invented. See [OpenRouter Reasoning Discovery QA](../qa_maintenance/openrouter_reasoning_discovery_qa.md).

Gemini templates use `google_thinking`: budget models map to `extra_body.google.thinking_config.thinking_budget`, level models map to `thinking_level`, and the adapter never mixes those shapes with top-level `reasoning_effort`. A documented `0` budget remains Off and carries no `budget_tokens`.

DeepSeek's evidenced native Chat dialect uses `deepseek_thinking`: grounded in official documentation ([api-docs.deepseek.com/guides/thinking_mode](https://api-docs.deepseek.com/guides/thinking_mode)), `deepseek-chat` supports thinking toggle (`on`/`off`), distinguishing toggle from fine-grained effort tiers; `deepseek-reasoner` has intrinsic reasoning and evaluates to `unsupported` for runtime adjustment. The current V4.1-Flash id `deepseek-v4.1-flash` — listed by both the [DeepSeek V4.1-Flash launch page](https://www.deepseek.com/en/news/deepseek-v4-1-flash/) and [OpenCode Go](https://opencode.ai/docs/go/) — resolves that documented toggle/effort contract on a first-party or verified partner native Chat route: `off` disables thinking, `low`/`high`/`max` enable thinking with the exact requested effort, and thinking is enabled by default at default effort `high`. That native envelope, its Off and its default are transport evidence for those routes only: a generic/local/custom compatible Chat route derives just the exact model's documented positive effort subset and infers no native `thinking.type`, no Off and no default (§2.3); the hosted NIM route keeps its separately evidenced serving contract. Documented request remaps (`minimal`→`low`, `medium`/`xhigh`→`high`, `ultra`→`max`) are never exposed as distinct options, and near-IDs remain unevidenced.

Kimi Moonshot's evidenced native Chat dialect uses `kimi_thinking`: grounded in official documentation ([platform.kimi.ai/docs/guide/use-thinking-models](https://platform.kimi.ai/docs/guide/use-thinking-models)), on that route `kimi-k3` exposes `reasoning_effort` (`low`, `high`, `max` with the native/serving default `max`, no `off`), `kimi-k2.6` exposes thinking toggle (`on`/`off`), `kimi-k2.7-code` is always-on (unsupported for runtime toggle), and legacy `moonshot-v1` models evaluate to `unsupported`. Its wire codec emits `reasoning_effort` for effort directives and `thinking: {'type': 'enabled'/'disabled'}` for toggle directives via `ToggleEffortThinkingWireCodec`. On a generic/local/custom compatible Chat route only exact-model positive effort facts survive — `kimi-k3`'s documented efforts as standard `reasoning_effort` with provider-managed omission — while a toggle-only family such as `kimi-k2.6` stays `unknown` because that wire evidences no such envelope and requires an explicit validated declaration (§2.3).

OpenCode Go's registered Chat policy does not override exact compatible model-owned controls. `supports_reasoning_output` alone never proves request-time control support. Selectable tiers and defaults come from the finite exact-model authority or validated native discovery described in §2.3, not blanket family defaults. Missing native defaults remain unassigned rather than guessing `medium` or the first tier; an unselected or cleared choice resolves to `UseProviderDefault()` and omits effort parameters on the wire.

`update_session_preferences` may update provider/model and `thinking_mode` together or update thinking alone. New clients send the canonical `provider_instance_id`; the daemon also accepts legacy `provider_id` input for compatibility but does not require both. Presence of `thinking_mode` is significant: a non-empty value persists the normalized selection, while an empty or null value clears it and the resulting session event includes `thinking_mode: null`. Omitting the key leaves the stored thinking selection unchanged.

### Provider Thinking Controls Coverage Matrix

The static 16-template coverage table and four-tier propagation hierarchy from Task 43 are superseded by the exact-model and native-discovery architecture introduced in Plan 77. Thinking controls, wire serialization, and capability boundaries are governed per exact evidenced model identity and route API mode rather than static template-level tiers.

For the active, registry-derived coverage matrix across all 16 shipped provider kinds—including native discovery schemas, exact model catalogs, and route serialization boundaries—see [§2.3 Exact Evidenced Model Thinking Policy & Wire Authority](#23-exact-evidenced-model-thinking-policy--wire-authority) and its [Registry-derived coverage matrix](#registry-derived-coverage-matrix).

### Provisional setup ownership (Task 57)

The client wizard records the UUID returned by the first `provider.instance.create` as `provisionalInstanceId`. Back keeps that identity and local details, including the in-memory credential input, and a later Continue updates the same row rather than creating another instance. The credential input remains controller-owned memory and must not enter logs or Equatable string output.

Cancel after creation requires explicit `Discard provider setup?` confirmation. Confirmation cancels any active auth session and sends `provider.instance.remove` only for `provisionalInstanceId`; an instance selected for Edit can never become the discard target. If removal fails, the client reloads authoritative instances and presents the draft in the configured list with a safe error rather than hiding the orphan. Successful readiness clears provisional ownership and local draft input.

### Client mutation and model-discovery projection (Task 57)

Provider metadata, credential, default-model, Test, Make Default, Delete, and reconnect requests retain their owning screen or provider card while pending. The client tracks the operation against the selected step or `provider_instance_id`; it does not use a global saving state that temporarily hides configured instances. Editing an existing instance sends mutable metadata only: Display Name and auto-failover plus an explicit credential action. Base URL and Protocol remain visible connection identity but are omitted from Edit mutations. Flutter formats canonical protocol ids for display in both Add and Edit (`openai_compatible` → `OpenAI API Compatible`, `anthropic_compatible` → `Anthropic API Compatible`) without changing the wire value.

Model discovery is projected as `loading`, `loaded`, `failed`, or `manual`. A successful `model.refresh` followed by an instance snapshot with discovered models enters `loaded`. Refresh failure or an empty instance result enters `failed` with user-safe text. Template fallback names may be presented as `Cached suggestions` but do not change the failed status, select a model, or satisfy readiness. `Retry` refreshes the same instance UUID. `Add Model` enters manual mode, and only `Confirm Model` sends `provider.instance.update(default_model)` followed by `model.recent.record`; a failed save preserves the manual identifier for correction or retry.

OAuth browser-launch truth is client-owned presentation state. Device Code attempts one automatic external launch after the auth session arrives and records the launcher's boolean result. The canonical `user_code` is always accompanied by a copy action that copies the exact value and reports success or failure through the client's global Toast system; provider setup must not introduce a SnackBar. Only a successful launch result enables copy stating that the page opened and changes the action to `Re-open verification page`; absent, invalid, failed, or throwing launchers retain `Open verification page` with recovery text. OAuth Back cancels polling/session but retains the provisional instance, while confirmed Cancel also applies provisional discard. Reconnect of an existing instance never assigns provisional ownership.

### Fail-closed routing

Implicit routing (no `provider_instance_id` in the turn/session) resolves the
**default instance only**. There is **no fallback to the first instance** when no
default is set — the runtime throws a clear error instead. A missing or deleted
default never silently routes a request through an unrelated account (Plan 29
§3.10, criterion 13/24).

### Live default adapter resolution

On a fresh install with no provider configured, default adapter resolution
returns a `MissingProviderAdapter`. This safe fallback fails lazily on an LLM
operation instead of preventing daemon startup. Dependency composition registers
this compatibility binding as a factory backed by
`AgentRuntimeService.defaultAdapter()`, so resolving it before onboarding cannot
freeze the missing adapter for the rest of the process.

`AgentRuntimeService` remains the adapter cache owner. Real provider adapters are
still reused by route signature, while each dependency lookup re-evaluates the
current default instance. Provider mutations clear that runtime-owned cache
through the explicitly injected service; protocol handlers do not inspect or
reset the dependency container.

Shared context services remain provider-neutral. `AgentRunner._streamNextResponse`
and `_generateResponse` resolve the current turn route for each model call.
Title generation likewise resolves its fallback route from `AgentRuntimeService`
at call time. Together these boundaries allow the first post-onboarding turn and
background title work to use the newly configured provider without a daemon
restart.

## configured vs runtime_ready

- `configured`: Setup data exists (a key, a token, or a local endpoint).
- `runtime_ready`: The resolver can produce a usable credential + model right now.

This separation catches: expired OAuth tokens, missing model selection, active provider pointing to a removed provider, and legacy `.env`-only tokens that never completed OAuth.

## openai-codex Migration

The legacy `CHATGPT_SESSION_TOKEN` in `.env` is no longer treated as a complete OAuth session. The `ProviderAuthSessionService` runs the device-code flow and stores access + refresh token + expiry in `provider_auth.json`. The `ProviderCredentialResolver` refreshes expired tokens or surfaces `relogin_required`. `CodexResponsesAdapter` remains reusable, but its credential source is the resolver, not raw `.env`.

### Responses continuity

Responses-compatible adapters use `store: false` and preserve only the opaque
provider state required to continue a turn, separately from user-visible
reasoning. Requests explicitly include encrypted reasoning output. Encrypted
reasoning and safe assistant message items are replayed from durable message
history only by the adapter that owns their namespace, and endpoint-sealed
state must not be sent to a different issuer. Reasoning item IDs are retained
only for local deduplication and are omitted from wire input under `store:false`.
The runtime does not use
`previous_response_id` as its continuity contract; adding server-side response
threading requires a separate endpoint-compatibility decision and tests.

Sync responses and terminal SSE responses pass through the same normalizer.
The stream accumulator handles typed text, reasoning, output-item, function
argument, usage, completed, incomplete, failed, and cancelled events without
assuming that network chunks align with SSE lines.

Visible reasoning summary deltas are projected to canonical `thought_stream`
events independently from final-answer text. A tool-loop response may contain
reasoning plus structured tool calls and no ordinary commentary text; clients
must still receive the reasoning progress, while the terminal `final_answer`
contains only accumulated output text.

The same reasoning remains on persisted assistant messages. Session-history
reconstruction projects it back to canonical `thought` events before the
matching tool calls or final answer, so reopening a session preserves the
reasoning timeline without duplicating identical assistant content.

An `incomplete` terminal classification triggers at most three semantic
continuations inside the same turn. This budget is separate from HTTP/network
retries and remains shared across tool-loop calls in that turn. If the limit is
exhausted, the last durable assistant message remains explicitly incomplete.

If an endpoint rejects replayed reasoning with `invalid_encrypted_content`, the
adapter marks it as provider-state rejection only when encrypted replay was
present on the failed wire request. The runtime may then remove only the
rejected reasoning key for the matching namespace and issuer, persist the
sanitized history, and retry once. Safe assistant items and state belonging to
another endpoint remain untouched. Endpoint-specific schema transformations,
including xAI slash-enum sanitization, stay inside the Responses provider
policy rather than the shared OpenAI adapter.

HTTP 500/502/503 responses are not rate limits merely because their body names
an upstream or gateway. Connection-reset signals such as `upstream connect
error`, `disconnect/reset`, or `remote connection failure` classify as
`networkError`. `upstreamRateLimit` requires an explicit throttling signal such
as `rate limit`, `too many requests`, `request limit`, or a trusted reset hint.

Before the first provider stream event, a transient `networkError` permits two
automatic retries after the initial request. Recovery applies short exponential
backoff plus jitter, and each Codex transport attempt owns a fresh HTTP client.
Any reasoning, metadata, content, or tool event closes this transparent-retry
window. If the three total attempts fail, the runtime emits the normal blocked
network notice; it does not reinterpret the failure as a rate limit.

### Chat Completions reasoning continuity

OpenAI-compatible Chat Completions endpoints may return structured
`reasoning_details` needed across a tool loop. Sanad persists those details as
opaque provider state, separately from user-visible reasoning, and replays
them only when the issuer composed from provider instance, protocol, and
normalized endpoint matches the active connection. A provider or endpoint
switch drops this wire state from the next payload while retaining the ordinary assistant text.
Chat Completions sync and stream share the same request fields and terminal
classification; stream-only flags are the only payload difference.

Terminal classification is persisted on assistant history together with
opaque provider state. A state-only assistant response remains durable even
without visible content or reasoning, and recovery code removes replay state
through an explicit clear operation rather than a null/unchanged ambiguity.

## Client Integration (Plan 19 Phases C–E)

The Flutter client consumes these commands through `ProviderSetupClient` (`sanad-client/lib/features/provider_setup/`), a transport-agnostic data-layer client that resolves the socket via `DeviceConnectionCoordinator` (local daemon when `agent` is null, cloud device otherwise).

- **Onboarding gate:** `OnboardingSetupScreen` calls `provider.runtime_check` after the local daemon connects. If not ready, it shows `ProviderSetupFlow` instead of navigating home. Only when the agent reports `runtime_ready` does the user reach the chat screen. The ready result carries the authoritative active provider-instance id and model into Home.
- **Selected-device gate:** after `/home` is already open, switching the active device must re-run `provider.runtime_check` against that selected device. If the device is connected but not ready, the client must block normal chat usage with a reusable provider setup gate for that device.
- **Composer initialization:** a successful readiness result initializes the composer from `active_provider` plus `active_model` only when both client selections are empty. Existing or partial user intent is not replaced during ordinary startup. Completing the forced first-provider setup gate replaces any stale client route with the authoritative ready provider/model pair. The client persists the pair under stable device-scoped route keys and in the New Conversation draft before relying on the current Home widget lifecycle, so route replacement cannot discard a late readiness response. An empty draft snapshot is absence of saved context and must not clear an initialized route.
- **Dismiss affordance:** forced provider-setup gates may expose a close/dismiss control so users can continue to Home without getting trapped. Dismissing is a UI affordance only; normal composer submission remains blocked until both provider and model are selected.
- **Reusable flow:** `ProviderSetupFlow` is the public entry point (accepts `device`, `onReady`, `client`). It is reusable from onboarding and future settings without rewriting the controller/state (`ProviderSetupCubit` / `ProviderSetupState`).
- **Responsive embedding:** when a host gives the reusable flow a bounded height, the flow supplies its own vertical scrolling and fills the available viewport. In an unbounded Settings page, the outer page scroll remains the scroll owner so the provider content does not impose a fixed height or create a competing nested scroll area.
- **Dismiss ownership:** host overlays/dialogs own the close button placement. The reusable provider setup content should not place modal-close chrome inside the flow body itself.
- **No hardcoded providers:** the picker renders whatever `provider.templates.list` and `provider.instances.list` return from the agent.

## Missing Provider Runtime Fallback

The daemon must not crash during startup, DI resolution, or route bootstrap when no default/ready provider instance exists. `AgentRuntimeService` now degrades to a lazy error adapter in that state:

- startup succeeds even with zero providers
- capability/readiness queries continue to work
- the first real LLM call fails with a normal request error carrying the missing-provider message

This keeps non-composer callers safe at the runtime boundary. In the Flutter composer, a skipped setup is rejected before session creation with an actionable provider/model selection message.

## CLI Integration (Plan 19 Phase D)

`sanad setup` is now an interface over the same provider runtime services (`CliProviderSetup` in `sanad-agent/agent/lib/core/setup/cli_provider_setup.dart`), so the CLI and the Flutter UI share one source of truth. CLI model discovery must write through `ProviderModelCacheService`, and CLI model picks must record through `RecentModelSelectionService`, so cached models and recent picks are shared with the Flutter client.

| Subcommand | Behavior |
|---|---|
| `sanad setup` | Interactive wizard: catalog → authenticate (API key / custom endpoint / device-code OAuth) → model selection → readiness check. |
| `sanad setup list` | Lists every supported provider with its auth flow and state; marks the active provider. |
| `sanad setup status` | Prints `setup_status` and `runtime_check` results. |
| `sanad setup remove <id>` | Removes a single provider's settings and credentials. |

The legacy `runCodexDeviceCodeFlow` and `fetchModelsFromApi` helpers remain for backward compatibility, but the wizard now uses `ProviderAuthSessionService` and `ModelOptionsService`.

## Runtime Recovery & Provider Rate Limits (Plan 30)

The agent owns a general recovery layer that surfaces runtime problems (rate
limits, network errors, billing, provider overload) to every open client on a
session instead of failing silently or scattering raw error text into the
conversation. The agent is the single source of truth: the UI sends commands
and waits for a fresh event before changing its visual state.

### Provider request interruption (Plan 50b)

Each provider turn receives the active `RunCancellationScope` through
`LLMRequestOptions`. Production adapters (`BaseOpenAIAdapter`,
`BaseAnthropicAdapter`, `CodexResponsesAdapter`, `OllamaAdapter`) issue HTTP
through `ProviderRequestTransport`:

- When a cancellation scope is attached, the transport owns a request-scoped
  HTTP client and registers cleanup on that scope. Closing the client aborts
  connect/send and ends SSE reads without closing an adapter-shared client used
  by another run.
- `ProviderRequestCancelledException` is typed separately from network/HTTP
  failures. `AgentRunner` maps it to `RuntimeRecoveryCancelled` and must not
  start retry/failover.
- Watchdog defaults live in `ProviderWatchdogConfig` (connect, first-byte, and
  stream-idle bounds, plus an optional total bound). First-byte and idle
  expiry fail the stream with `TimeoutException` and cancel its upstream
  subscription; they never masquerade as a successful end-of-stream. The
  optional total deadline spans connect and streaming rather than restarting
  for each phase. A timeout is not treated as proof of cleanup by itself.
- Rate-limit waits observe `RunCancellationScope.whenCancelled` in addition to
  the recovery cancel token, so Stop aborts a wait without inventing a network
  notice.

See also `docs/technical/run_cancellation_and_process_ownership.md`.

### Per-instance rate limit

Every `ProviderInstance` carries two Plan 30 fields:

| Field | Type | Default | Meaning |
|---|---|---|---|
| `requests_per_minute` | int | `0` | Compatibility field retained in storage and protocol; `0` = unlimited. |
| `allow_auto_failover` | bool | `true` | Whether this instance may be selected automatically when another fails. |

Task 57 makes local provider rate limiting dormant without deleting its schema,
DTOs, notices, or limiter implementation. Every template advertises
`defaultRequestsPerMinute = 0`; instance creation and metadata updates normalize
legacy `requests_per_minute` input to `0`, and database initialization upgrades
existing non-zero rows to `0`. Flutter does not expose or send this field. This
preserves wire/storage compatibility while ensuring no hidden throttling is
applied.

`allow_auto_failover` remains editable through the existing
`provider.instance.create` and `provider.instance.update` commands. Flutter
shows this control continuously in Add and Edit rather than hiding it behind an
Advanced disclosure, warns that enabling it allows automatic selection after
another provider fails, and colors the enabled switch with the warning/error
color. It does not bump `config_revision` because it does not invalidate adapter
or model caches.

### Runtime notice events (agent → clients)

| Event | Payload highlights | When |
|---|---|---|
| `session.runtime_notice` | `status` (`waiting` \| `blocked` \| `resuming` \| `cleared` \| `fatal`), `reason` (snake_case), `title`, `message`, `provider_instance_id?`, `resume_at?`, `retry_after_ms?`, `limit?`, `actions[]` | Recovery state active or transitioning. |
| `session.runtime_notice_cleared` | `session_id`, `status: cleared` | Recovery resolved (stop / cleared). |

`status` meanings:
- `waiting`: automatic resume at a known time (`resume_at` / `retry_after_ms`).
- `blocked`: needs user action (`retry` / `change_provider` / `open_provider_settings`).
- `resuming`: recovery cleared, execution restarting (transient).
- `cleared`: fully resolved.
- `fatal`: not recoverable within the current session.

Client processing contract:
- `blocked`, `waiting`, `fatal`, and `cleared` end the active in-flight turn from the conversation UI perspective; the composer must not remain in a perpetual "processing" state after these notices.
- `resuming` is transient and may re-enter the processing state while the daemon retries or resumes the suspended turn.
- If a `get_session_history` response returns after the user already switched to another session, the client must ignore that stale snapshot instead of overwriting the newer session's history, queue, or runtime notice.
- **Durable State and Restart Restoration**: The daemon persists all active notices, queued messages, and work items to `state.db`. Upon restart, the daemon restores these active states: waiting notices recalculate timers from `resume_at`, while blocked notices are fully re-hydrated. If a crash occurred during tool execution, idempotent tool calls are safely re-queued, while non-idempotent tool calls transition the work item to `blocked` to protect user system integrity.

### Runtime commands (clients → agent)

| Command | Payload | Behavior |
|---|---|---|
| `session.runtime_retry` | `session_id`, `request_id?`, `provider_instance_id?`, `model_id?` | Claims the suspended work item first, then broadcasts `resuming`/`cleared` and replays that exact work item. If a real `waiting` notice owns an active retry loop, the command reroutes that runner and aborts its old wait. A stale Retry during a normal busy turn is a no-op. If no work exists, the session remains in a controllable `blocked` state. If only `provider_instance_id` is supplied, the runtime may use only that instance's own `defaultModel`; if none exists it must stay blocked and ask the user to choose a model. |
| `session.runtime_stop` | `session_id`, `request_id?` | Aborts any active wait/retry, cancels the in-flight run, drops suspended work and queued turns for that session, emits exactly one `session.runtime_notice_cleared` transition and one `stopped` transition per client, and returns the session to idle immediately. |
| `session.runtime_continue_with_provider` | `session_id`, `request_id?`, `provider_instance_id`, `model_id?` | Claims suspended work and atomically applies the selected route to runner, session, and queued work before emitting `resuming`/`cleared`. A real active `waiting` loop is rerouted and its old wait is aborted, including when that loop still owns an in-flight resume claim; the same owner reloads the confirmed route and continues. A genuinely progressing concurrent recovery command remains an idempotent no-op and cannot overwrite the winning route. If no work exists, the selected route becomes the session default while recovery stays blocked. If `model_id` is omitted, only the selected provider's own `defaultModel` may be used. |

Every user, recovery, or automatic provider/model route change passes through
one authoritative mutation owner. It updates the session route and every
non-terminal work item (`queued`, `running`, `waiting`, `blocked`, `resuming`)
inside one `AgentStateDatabase` transaction. A real tuple change increments the
session-local `route_revision` once; an identical provider/model request is an
idempotent no-op and emits no confirmation.

After commit, the agent broadcasts `session_preferences_updated` to the
`sanad_client` platform family. Its authoritative payload is:

```text
session_id
source: user | recovery | auto_failover
previous_provider_instance_id: nullable
provider_instance_id
model
reason: nullable
request_id: nullable
route_revision
updated_at
```

The event uses one canonical `event_id` across local/cloud fan-out. Clients may
keep a temporary pending selection, but persist and synchronize the model chip
only from this confirmation and only when its independent `route_revision` is
newer. Execution-state revisions must never be compared with route revisions.

Concurrent recovery commands use first-claimant-wins semantics. The claimant's
route is the only route written to the active runner, session, durable queue,
and `session_preferences_updated`; later `alreadyResuming` commands emit no
competing route. Active-run handoff requires an authoritative `waiting` notice,
not merely a generic busy session flag.

### Restart recovery contract (Gate F)

Restart recovery is now a production contract:

- Daemon startup restores durable runtime state before `GatewayManager.start()`
  accepts new gateway events.
- The gateway/orchestrator delivery bridge must be attached before restore so
  restored notices and queue-drain responses travel through the same canonical
  protocol path seen by real clients.
- A recreated client after restart hydrates the restored `runtime_notice` and
  `queued_messages` through the normal `get_session_history` snapshot path.
- `session.runtime_retry` after restart resumes the suspended work item and
  starts a real turn; it must not synthesize a magic success response.
- A failed retry/change-provider/auto-resume attempt must keep the same
  durable work item and a controllable blocked notice so a second retry does
  not need a brand new user message.
- `session.runtime_continue_with_provider` after restart rewrites the resumed
  route atomically (`provider_instance_id + model_id/defaultModel`) and then
  rebroadcasts `session_preferences_updated` as the confirmed route.
- `session.runtime_stop` after restart clears in-memory recovery state, durable
  notice rows, active work, and queued work atomically, then emits exactly one
  `session.runtime_notice_cleared` and `stopped`.
- Queue-only sessions restored from SQL must immediately claim and drain the
  oldest queued work item so restart cannot strand FIFO work until a newer
  message arrives.
- If startup restore throws, the daemon must not continue with a silent unknown
  state; it converts affected sessions into a controllable `blocked` notice so
  clients can `Retry`, `Change Provider`, or `Stop`.

### Error classification

`RuntimeFailureReason` (in `runtime_failure_reason.dart`) is the central
classifier. It maps HTTP status + body patterns to a structured reason and a
`FailureDecision` (notice status, retryable, allow auto failover, UI actions).
Key distinctions (Plan 30 §7.2):

- `rate_limit` (429 account/key): waiting + retryable + allows failover.
- `upstream_rate_limit` (aggregator hit limit): does not exhaust the current credential; prefers failover.
- `overloaded` (503/overload): waiting + retryable, does **not** mark the account consumed.
- `billing` (402/insufficient credits): blocked, **not** retried on the same instance; failover allowed.
- `auth` (401/403): blocked with `open_provider_settings`.
- `network_error`: up to two bounded automatic retries before the first stream
  event, then blocked with manual retry. `timeout` keeps its smaller bounded
  retry budget before becoming blocked.
- `context_overflow` / `content_policy_blocked`: fatal.

### Auto failover

Controlled by the `PROVIDER_AUTO_FAILOVER` env flag (default `true`). When
enabled and the active instance fails with a failover-eligible reason, the
agent searches for a qualified candidate:
1. Same `templateId`, same model, `status=ready`, `allow_auto_failover=true`, not excluded.
2. Any template, exact same model id, ready, allowed, not excluded.

No fuzzy/semantic model matching is allowed. A selected candidate keeps the
exact requested model id. The authoritative route transaction updates the
session and all non-terminal same-session work before retrying. If no qualified
candidate exists, no route revision or route event is created and normal
controllable recovery remains active.

Every successful automatic switch also persists a route transition keyed by
`(session_id, route_revision)` with the same canonical `event_id` used live.
Session history returns automatic transitions as English informational items,
not recovery blocks, so reconnecting clients can show the switch and dedupe it
against the live event by route identity.

When a provider returns a real 429, the agent records a provider-instance
cooldown inside the local rate limiter. This blocks every session using that
instance before another upstream request is sent. The HTTP layer resolves the
resume time before the runtime sees the failure, in this precedence order:

1. `retry-after-ms`
2. standard `Retry-After` (seconds or HTTP-date)
3. provider reset headers tied to `remaining=0`
   - OpenAI-compatible: `x-ratelimit-remaining-*` + `x-ratelimit-reset-*`
   - Anthropic-compatible: `anthropic-ratelimit-*-remaining` + `anthropic-ratelimit-*-reset`
4. explicit reset timestamps in the response body such as
   `Usage limit reached ... Your limit will reset at 2026-07-11 04:21:28`
5. one-minute fallback cooldown for plain `429` without a valid hint

Reset headers are used only when the matching `remaining` dimension is exactly
`0`; if multiple dimensions are exhausted, the agent waits for the farthest
required reset so all exhausted dimensions recover. Supported reset value forms
are explicit durations (`ms`, `s`, `m`, `h`), absolute epoch timestamps,
HTTP-date, ISO-8601, and provider body timestamps without timezone, which are
treated as UTC.

Classification depends on whether that resolved reset is trustworthy:
- temporary usage/reset limits with a future reset become `waiting` and emit
  `resume_at` / `retry_after_ms`
- quota / insufficient-credit style `429` responses without a trusted future
  reset stay `blocked` and are not auto-retried on the same instance
- plain `429` without any valid hint still uses the one-minute cooldown

### Auto-failover durable resume claim

After a failover-eligible failure creates a waiting notice, continuing on a candidate provider is one owned transaction. It validates the active `session_id`, `work_item_id`, owner `run_id`, generation, request, waiting notice, and expected current provider. The transaction then performs `waiting -> resuming`, updates the session route and every non-terminal work route, records the route transition, and updates the execution snapshot. Only after commit is the route event published and the replacement request allowed.

A failed or stale claim performs no replacement request and emits no final answer. Recovery remains visible for Retry or Stop. Success retains the same run owner and completes only through the existing terminal `resuming -> completed` commit; first real progress clears the resuming notice. Startup never infers completion from partial assistant text, and legacy waiting work without a provable notice/owner/request tuple becomes blocked recovery.

### Same-route automatic retry claim

A bounded retry on the current provider follows the same durable ownership boundary without mutating the route. Once the retry delay completes, the runtime validates `session_id`, `work_item_id`, owner `run_id`, generation, and request, then commits `waiting|blocked -> resuming` and publishes the execution snapshot before issuing the next provider request. If the claim fails, the provider is not called and recovery stays authoritative. The `resuming` notice is cleared by the first provider event or terminal completion, never immediately after it is emitted.

### Provider usage reset

`provider.usage.reset` requires `request_id`, `provider_instance_id`, and a daemon-owned `idempotency_key`. The response event is `provider.usage.reset_result` with one of `reset`, `confirmation_required`, `nothing_to_reset`, `no_credit`, `already_redeemed`, `auth_required`, `unsupported`, or `failed`.

The daemon always performs a fresh usage preflight. If no window is exhausted, it returns a short-lived `confirmation_token` bound to the exact account and preflight snapshot. A subsequent confirmation uses a new transport `request_id`, reuses the logical operation's `idempotency_key`, and includes that token. Changed or expired snapshots require confirmation again. Concurrent or replayed requests for the same instance-scoped key share the same daemon operation, and the client retains that key across ambiguous failures so a retry cannot create a second mutation. Successful, already-processed, and nothing-to-reset outcomes trigger a provider refresh; `refresh_failed: true` distinguishes a completed mutation from reconciliation failure. Credentials and raw provider responses never cross the protocol.

## Exact-Route Model Capabilities & Thinking Controls (Plan 77 / Task 77i5)

Intrinsic capability declarations and catalog lookup are keyed by exact model identity, not provider UUID, template, or endpoint. The daemon freezes their resolved result into an exact-route execution snapshot; route identity and revisions isolate endpoint metadata and Client selections, while the actual protocol/API mode owns serialization.

### 1. Precedence Order
Capability resolution for each field proceeds in strict priority:
1. **Explicit Home Configuration Override** (`config.yaml` under `model_capabilities`, keyed directly by exact model identity).
2. **Authoritative Endpoint Metadata** (e.g. from `/models` when supported by the provider, bound to config/credential revisions).
3. **Curated Catalog Data** (`models.dev` universal model knowledge, resolving across custom endpoints and official routes).
4. **Unknown** (fails closed for images; renders `Default` provider-managed for thinking).

### 2. Configuration Schema (`SANAD_HOME/config.yaml`)
Custom capability overrides are declared in `config.yaml` using exact model identity keys directly under `model_capabilities` (case-sensitive, preserving colons in URN-style IDs). Provider instance IDs are excluded from capability keys so a single declaration applies across multiple providers, custom/native routes, renames, and deletions/re-creations. Unlanded nested provider schemas (`model_capabilities.<provider-id>.<model-id>`) are rejected at parse time with an actionable `FormatException`.

```yaml
model_capabilities:
  "<exact-model-id>":
    supports_image_input: true
    thinking_control:
      status: supported # supported | unsupported | unknown
      wire: openai_chat_effort # openai_chat_effort | codex_responses_effort | anthropic_adaptive | anthropic_budget
      options:
        low: low
        medium: medium
        high: high
```

Rules:
- `supports_image_input`: Boolean. Absence/null means unconfigured.
- `thinking_control.status`: `supported`, `unsupported`, or `unknown`.
- `wire`: Typed wire protocol, checked for wire compatibility against provider protocol and `apiMode`:
  - `openai_chat_effort`: Compatible with `openai_compatible` protocol and `chat_completions`/`chat` API mode.
  - `codex_responses_effort`: Compatible with `openai_compatible` protocol and `codex_responses` API mode.
  - `anthropic_adaptive` / `anthropic_budget`: Strictly requires `anthropic_compatible` protocol and `anthropic_messages` API mode.
  - Wire incompatibility fails closed: the descriptor is downgraded to unsupported/unknown.
- Option validation and wire mappings:
  - The typed Chat/Responses effort vocabulary is `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`, centralized in `ThinkingWireVocabulary`; model/endpoint declarations still authorize only their own finite subset, never every value for every model.
  - Canonical effort/level IDs retain their exact semantic value; no remap/elevation or effort label hiding a Boolean enable/disable. Opaque option IDs may map to explicit valid finite values, and legitimate numeric budget tiers remain budgets. Fake-Off/fake-On is rejected at parse time.
  - `anthropic_adaptive`: Allowed efforts are `none`, `off`, `low`, `medium`, `high`, `max`. Declared disable maps to typed false toggle, producing `thinking: {type: disabled}` rather than `adaptive + effort: off`; active tiers use `AnthropicAdaptiveDirective` and `output_config.effort` on Messages.
  - `toggle_effort`: Validated Boolean or `true`/`false`/`on`/`off` strings resolve through the typed toggle; false uses the owning route's genuine disable, not an effort parameter guessed from the option label.
  - `google_thinking`: Accepts validated non-negative integer budgets or canonical levels `minimal`, `low`, `medium`, `high`. A declared disable (`0` or its validated `none`/`off` alias) resolves to `GoogleBudgetDirective(0)`, producing `extra_body.google.thinking_config.thinking_budget: 0`, **never** an invented `thinking_level: off`. Positive budgets and active levels retain their exact typed values. Native model facts decide whether a real model permits disable.
  - `nim_kimi_thinking` / `nim_qwen_thinking`: Finite typed `chat_template_kwargs.thinking` / `chat_template_kwargs.enable_thinking` Boolean declarations; self-hosted Qwen additionally admits exact `low`, `medium`, `xhigh` efforts. These declarations are selectable only on generic/custom compatible Chat or NIM Chat serializers; aggregator/Responses/Messages/native Ollama reject incompatible controls before dispatch. Hosted model facts and self-hosted declarations remain distinct; see [NVIDIA Thinking Wire QA](../qa_maintenance/nvidia_thinking_wire_qa.md).
  - `anthropic_budget`: Disabling options are prohibited; budgets must be integers >= 1024. A non-positive Anthropic budget is not a disable. Each budget option publishes its `budget_tokens`. On the Messages wire an explicitly selected budget is emitted verbatim when it fits below the request's `max_tokens`; a request that cannot honour it fails actionably while the body is built, before dispatch, instead of silently sending a smaller budget than the one selected. Since no positive budget can fit below a ceiling that leaves it no room, a declared `max_tokens` of `1`, `0` or a negative value is likewise unhonourable and rejected; only an absent `max_tokens` — no declared ceiling to compare against — leaves the selected budget unchanged.
  - Provider Default: null, empty or whitespace-only selection resolves to `UseProviderDefault()` for configuration and endpoint declarations even with `default_option`. A known default remains `defaultOptionId` descriptor metadata; it dispatches only when explicitly selected.
  - `isOff` identifies an actual admitted disable, never Default omission. Explicit declaration options remain separate from provider-managed omission.

### 2.1 Declared Endpoint Thinking Controls & Cache Isolation
Endpoints that discover model capabilities dynamically may provide raw `thinking_control` metadata within `model_metadata`:
- **Canonical Parse Validation:** Declared endpoint controls must parse through canonical `ThinkingControlOverride.tryParse` / `parse`. Invented budgets (e.g., `int.tryParse ?? 1024`), guessed effort tiers, or guessed toggles are strictly rejected.
- **Shared Finite Vocabulary & Discovery Outcomes:** A declared endpoint control validates its option values against the shared finite vocabulary of its wire — the typed Chat/Responses effort vocabulary `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max` — so declaration validation and serialization cannot drift. A documented finite list is declared exactly as documented and in documented order, and an explicit all-values declaration is declared as those seven values. An unusable `reasoning`-style member (a present member whose effort selector is omitted, an empty list, malformed values, or a default outside the documented set) publishes explicit `unknown` route-control evidence for that exact route instead of silently adopting an unrelated intrinsic ladder of options, and no budget choice or default is invented. A names-only model list remains absence of new evidence: nothing is published, so existing authority and intrinsic model knowledge stay in force. See [OpenRouter Reasoning Discovery QA](../qa_maintenance/openrouter_reasoning_discovery_qa.md).
- **Option Value Fidelity:** Declared option mappings are honored without modification: opaque option IDs map directly to declared wire values, and budget options map to exact declared integer values.
- **Wire Codec Serialization:** HTTP request serializers map opaque option IDs to declared wire values, selected budgets to exact integer `budget_tokens`, and `off` or provider default selections to explicit wire disable directives or complete wire absence.
- **DTO Cache & Metadata Isolation:** Top-level enriched DTO descriptors (`ModelOption.thinkingControl`) are strictly isolated from raw endpoint metadata (`ModelOption.modelMetadata`). Cache round-trips (`toJson`/`fromJson`) maintain structural stability without recursive nesting. When a configuration override is removed, the route immediately falls back to the raw declared original or `unknown` without requiring a cache refetch.

### 2.2 Exact Route & Endpoint Capability Binding
- **Universal Model Catalog Resolution (`ModelsDevService`):** Curated model knowledge in `ModelsDevService` acts as intrinsic model intelligence. Known canonical models and explicit grounded aliases (e.g. `claude-haiku-4.5`) resolve image support across custom endpoints, proxies, and official routes without requiring provider UUID matching, template membership, or official base URL equality. Genuinely unknown models on names-only custom endpoints or conflicting vendor entries fail closed to `unknown` unless explicitly declared via `model_capabilities` in `config.yaml`.
- **Grounded Exact Aliases & Consensus:** `ModelsDevService.groundedModelAliases` maintains strictly same-generation aliases only (e.g., `claude-haiku-4.5`, `claude-haiku-4-5`, `claude-haiku-4-5-20251001`); cross-generation fallbacks and speculative names are prohibited. When exact selected model ID is present in a vendor entry, it is authoritative; when missing, contradictory candidate aliases within any reporting vendor fail closed (`null`) and propagate across all vendor aggregation so another publisher cannot erase ambiguity, while missing metadata in another vendor does not veto unambiguous known facts.
- **Startup Catalog Hydration:** Catalog hydration (`ModelsDevService.ensureLoaded()`) is wired into the daemon and standalone CLI startup lifecycles prior to turn admission. Turn admission resolves capabilities synchronously with zero HTTP calls.
- **Forced Catalog Reload on Manual Refresh:** Explicit provider model refresh (`ProviderModelCacheService.refresh(manual: true)`) threads `forceRefresh: true` into `ModelsDevService.ensureLoaded()`, forcing a fresh catalog reload, while normal background/startup refreshes respect the cache TTL.
- **Mode-Owned Wire Serialization & Wire Model Preservation:** The active API mode and provider protocol govern wire translation; model identity never implies wire format. A Claude model routed via an OpenAI-compatible endpoint serializes as OpenAI Chat completions, never Anthropic Messages. Wire requests sent to endpoints preserve the exact relay selected model ID (e.g., `claude-haiku-4.5`), never rewriting the wire body model to catalog aliases.
- **Zero Hot-Path Network:** Request payload serialization and measurement execute synchronously against the admitted `RouteCapabilityProfile` or in-memory cached capabilities. Asynchronous catalog lookups during body assembly are strictly prohibited.
- **Exact Model Identity:** Daemon route lookup (`ProviderModelId.normalize`) and client descriptor resolution/session matching (`RouteThinkingControl.normalizeModelId`) preserve case, catalog namespaces, and variant symbols (e.g., `~`, `:`) without lowercasing custom model IDs or stripping catalog identifiers, stripping only transport-owned provider instance prefixes with exact boundaries. Every vendor catalog — including Gemini — matches exact grounded ids plus the single documented catalog namespace; no catalog may use substring, prefix, wildcard or case-folding promotion.
- **Tri-State Honesty & No Silent Remap:** An id that is not grounded stays `unknown`, never a fabricated `unsupported`. Only an exact grounded model whose native contract has no request-time control (for example `gemini-1.5-pro`, `kimi-k2.7-code`, `deepseek-reasoner`, `gpt-4o`) is `unsupported`. Both values advertise no options and emit no wire parameter, but `unknown` keeps the route declinable through `model_capabilities` instead of claiming a proven absence of controls. A selection id the route actually advertises is a current option id and is never rewritten by legacy-alias migration: the documented Gemini `minimal` level must reach the wire as `minimal`, never silently as `low`.

### 2.3 Exact Evidenced Model Thinking Policy & Wire Authority
- **Actual Route Dialect:** Native extension envelopes are evidenced transport properties, never inferred from a model name. First-party templates and the verified partner Chat route keep their native contracts. Generic/local/custom Chat retains documented standard positive effort facts without an invented native envelope, disable or family default; explicit validated declarations may evidence compatible extensions. Hosted NVIDIA NIM uses its own per-model policy before first-party shortcuts; self-hosted-only facts require a declaration. [NVIDIA Thinking Wire QA](../qa_maintenance/nvidia_thinking_wire_qa.md) owns that finite serving matrix.
- **Model Facts, Route-Owned Wire:** Exact evidenced model facts take precedence over generic template guesses only on compatible active API modes. For example, `kimi-k3` retains its documented `low, high, max` positive effort set; its known default belongs to the evidenced native/serving contract, while generic compatible Chat keeps provider-managed omission. OpenRouter is a deliberate serialization boundary: its `aggregator_upstream` policy delegates model capability resolution but retains the aggregator `reasoning` envelope. Intrinsic knowledge never licenses bypassing the actual route serializer or switching endpoint/protocol.
- **Toggle & Unsupported Precedence:** On an evidenced native Kimi dialect, `kimi-k2.6` resolves to its documented toggle (`on, off`; default `on`). Its envelope is not inferred on a generic/local/custom route; an explicit compatible declaration is required there. Documented always-on models where runtime adjustment is rejected upstream (`kimi-k2.7-code`, `kimi-k2.7-code-highspeed`) and legacy models (`moonshot-v1-*`) resolve strictly to `unsupported`.
- **Bare ID Grounding & Negative Namespace Rejection:** Official Kimi documentation establishes bare model IDs (`kimi-k3`, `kimi-k2.6`, `kimi-k2.7-code`, `kimi-k2.7-code-highspeed`, `moonshot-v1-8k`, `moonshot-v1-32k`, `moonshot-v1-128k`). Ungrounded vendor-prefixed namespaces (e.g. `moonshotai/...`), casing variations (`KIMI-K3`), or custom extensions (`kimi-k3-custom`) are not accepted as intrinsic Kimi models and fail closed to `unknown` on custom/unconfigured routes.
- **HTTP Body Wire Authority:** Admitted typed directives serialize through the actual route codec: Chat effort uses `reasoning_effort`; Responses uses `reasoning.effort`; OpenRouter retains its `reasoning` envelope; Anthropic uses manual budget or adaptive effort, never both; native Ollama uses its typed `think` field. `UseProviderDefault` omits the thinking field rather than substituting a selected tier. Invalid selections are rejected before HTTP dispatch with `ThinkingSelectionErrorCode.optionUnavailable`. The OpenRouter aggregator keeps its own `reasoning` envelope: positive effort tiers and positive budgets serialize as `reasoning.enabled = true` with `reasoning.effort` or `reasoning.max_tokens`, while admitted disable — zero Google budget, typed false toggle or canonical effort `none` — serializes as `reasoning.effort = "none"` without `enabled: true`. Google level `off` — an invalid `GoogleLevelDirective('off')`, since Google's documented level enum has no `off` — malformed effort/level, negative Google budget, non-positive Anthropic budget and unsupported typed directives reject before dispatch rather than silently becoming omission; an explicitly enabled zero budget is never emitted.
- **Native Finite Evidence:** Codex discovery retains each exact model entry's `supported_reasoning_levels` (`effort` strings) and optional `default_reasoning_level`. One strict parser validates membership, types and model identity. Unknown raw metadata synonyms are not evidence, and a missing native default never licenses choosing the first tier or guessing `medium`. Static exact-model facts remain finite and source-backed: `gpt-5.6-sol` permits `none, low, medium, high, xhigh, max`; `gpt-6-astra` permits `low, medium, high, xhigh, max` but not `none`. A documented `none` is Off, not provider Default.
- **Native Ollama Evidence:** A strict live capability list and native `thinking.values`/`thinking.default` declaration determine controls. Boolean choices are exactly the declared booleans, with a member Boolean default; no unavailable Off is invented. Level choices/defaults retain string type and membership, including a native string token named `off` rather than substituting Boolean `false`. Malformed/mixed declarations remain unknown; absent `thinking` in a valid probed capability list is unsupported. Model names alone never produce levels or defaults.
- **Live Evidence Freshness & Authority:** `source: live` evidence is time-bounded; older than `ThinkingControlStaleEvidence.liveEvidenceTtl` (5 minutes) resolution normally fails closed to unknown. The one exception retains a descriptor only when it was produced from a validated native declaration for the exact model route and its fresh rebuild under the same config/credential/policy revision still resolves `supported`, so model-owned On/Off/default facts survive elapsed wall-clock time instead of silently resetting the composer to unknown. Failure and invalidation evidence always stays authoritative: `live_probe_failed`, `cache_stale`, and `stale_live_evidence` resolve unknown until a live probe succeeds again, and malformed, unknown, unsupported, or revision-changed evidence is never retained. A config or credential revision change alone neither clears failure provenance nor rebuilds success from persisted metadata; a successful live probe under the new revision is what drops that provenance and restores the model-owned facts.
- **Rejected Selection Lifecycle:** A selection the active route cannot honor is rejected during turn admission before any provider request and emitted as a terminal error response carrying the typed `ThinkingSelectionErrorCode`. The rejected turn's own durable work item is terminalized as `cancelled` through the owner-scoped durable transition, and that response is delivered only after the transition applies — durable ownership, never the in-memory projection, decides delivery. A rejection whose work item was already released, replaced, or cancelled stays silent: it delivers no stale terminal answer, clears no in-flight state, signals no turn completion (so it releases neither busy ownership nor the queued-work drain), and leaves the newer durable owner and its queued work untouched. A turn admitted without a durable work item (no persisted state) keeps its in-memory rejection and still completes normally.
- **ZAI Hybrid Versus Forced Thinking:** Exact `glm-4.5` / `glm-4.5-air` support On/Off but retain provider-managed hybrid default rather than inventing a selected On/Off member. Exact `glm-5.3` permits only `low, high, max`, defaults to `max` and rejects Off. DeepSeek/ZAI share the existing toggle/effort codec's explicit enabled-plus-effort mode; its default XOR behavior for Kimi is unchanged. Grounding: [GLM-4.5](https://docs.z.ai/guides/llm/glm-4.5), [GLM-5.3](https://docs.z.ai/guides/llm/glm-5.3), [ZAI thinking modes](https://docs.z.ai/guides/capabilities/thinking-mode).
- **Exact DeepSeek V4.1 Flash Grounding & Generic-Policy Precedence:** The exact id `deepseek-v4.1-flash` is a model-owned DeepSeek fact, so on an evidenced first-party/partner native Chat dialect it resolves `deepseek_thinking` instead of falling through to generic OpenAI tiers. Generic/local/custom Chat derives only its documented positive effort subset, with no native disable/envelope/default; the hosted NIM route keeps its separately evidenced serving contract. Its finite controls are exactly `off`, `low`, `high`, `max` with default `high`, matching the documented Chat contract (`thinking.type: enabled/disabled` plus `reasoning_effort: low/high/max`, enabled by default at default effort `high`). Documented request remaps (`minimal`, `medium`, `xhigh`, `ultra`) are remaps, not distinct selectable tiers, and must never be displayed as separate options. Grounding: [DeepSeek V4.1-Flash](https://www.deepseek.com/en/news/deepseek-v4-1-flash/), [DeepSeek thinking mode](https://api-docs.deepseek.com/guides/thinking_mode), [OpenCode Go](https://opencode.ai/docs/go/).
- **Generic Policy Must Not Hide Exact DeepSeek Models:** When a host template's registered policy is a generic OpenAI effort policy (for example OpenCode Go), an exact DeepSeek model id must still be recognized by its own facts. If it is not, the generic policy returns `unsupported`, which correctly hides the composer selector and converts an existing saved selection into a capability failure even though the upstream model does support controls. This is an exact-model coverage obligation, not evidence of upstream inability, and never a license to restore guessed family tiers or to infer controllability from `supports_reasoning_output`.
- **Near-ID Fails-Closed Without Family Rules:** Only exact, grounded ids are evidenced. Near-IDs such as `deepseek-v4.1-flash-x`, `deepseek-v4.1-flash-thinking`, `deepseek-v41-flash`, `deepseek-v4-1-flash`, `deepseek-v4.1`, and casing variations stay unevidenced, keep the host template's generic result, and keep the selector hidden. No vendor-prefix, generation-family, substring, or wildcard rule may promote them, and no vendor-namespaced form is added without its own grounding.
- **Grounded Gemini Facts (per model):** every retained Gemini id carries its own documented finite option set and default from Google's official thinking table; there is no shared family set. `gemini-4-argon` exposes `low`/`medium`/`high` (default `medium`); `gemini-3.8-flash` exposes `low`/`medium`/`high` (default `medium`, and documents that `minimal` returns an error); `gemini-3.6-flash` exposes `minimal`/`low`/`medium`/`high` (default `medium`); `gemini-3.5-flash-lite` exposes `minimal`/`low`/`medium`/`high` (default `minimal`); `gemini-3-flash-preview` exposes `minimal`/`low`/`medium`/`high` (default `high`); `gemini-3.1-pro-preview` exposes `low`/`medium`/`high` (default `high`); `gemini-3-pro-preview` exposes `low`/`high` only (default `high`). Gemini 2.5 models stay budget-based: only `gemini-2.5-flash` documents an explicit disable (`reasoning_effort: "none"`), `gemini-2.5-pro` is always-on, and both delegate an omitted budget to their model-managed dynamic default, so neither advertises a default option. Reasoning cannot be turned off for Gemini 3/4, so no `Off` option is advertised for them. Ids without an obtained per-model finite set/default — `gemini-3-flash`, `gemini-3.1-flash`, `gemini-3.1-flash-lite`, `gemini-3.5-flash` (deprecated, auto-routed), `gemini-pro-latest`, `gemini-3.8-pro` — stay `unknown` and are declinable through `model_capabilities` instead of inheriting a neighbouring model's tiers.
- **Grounded xAI Grok Facts:** `grok-4.5`, `grok-4.6` and `grok-4.7` expose the documented Chat `reasoning_effort` values — `low`/`medium`/`high` for 4.5 and additionally `xhigh` for 4.6 and later, with documented default `high` — on Chat-compatible modes only. Reasoning cannot be disabled, so no `Off` option is advertised, and `xhigh` is never advertised for `grok-4.5`, where it maps to `high`. Reasoning-output-only ids (`grok-4.20-0309-reasoning`) and nearby or differently cased names stay unresolved.
- **Grounded `gpt-oss` Facts:** the open-weight `gpt-oss-120b`/`gpt-oss-20b` family documents three reasoning efforts (`low`, `medium`, `high`). These are intrinsic model facts keyed by the exact model id (including NVIDIA NIM's namespaced `openai/gpt-oss-*` ids) with no provider-kind allowlist, so a custom or proxy route with an identical compatible Chat mode exposes the same finite options instead of being blocked. Wire compatibility stays in the existing route/policy/API-mode boundary: the options are advertised only where the active mode carries the Chat `reasoning_effort` field, and an incompatible mode advertises nothing. The family documentation does not prove that any particular hosted endpoint serves these models, and llama.cpp's server documents that a request `reasoning_effort` is disabled for `none` and otherwise forwarded to the Jinja chat template, so no route is claimed or denied by name. No family default is advertised, so omission stays provider-managed.
- **Failed Refresh Reconstructs From Current Authority:** A failed model-list refresh never hands a cached descriptor straight back to the route. Each cached model is re-derived from the current authority — active Home configuration, the instance's config/credential revision, the route protocol, the actual API mode and the model's own persisted discovery metadata. A descriptor survives only when the persisted one was `supported` and not already invalidated, the reconstruction is `supported` from inherent model-owned evidence (`profile` catalog facts or a model-only `config_override`), and the reconstruction carries the same capability revision. Endpoint declarations are deliberately excluded: they are route-owned evidence that only a successful discovery can revalidate, so a model-list failure must not silently reclassify them as intrinsic support. A removed or changed override, an incompatible route/API mode, or a config/credential revision change therefore fails closed instead of resurrecting stale controls; live probe/discovery evidence keeps its `live_probe_failed` invalidation, and every other model stays unknown until a successful refresh rebuilds it.

#### Registry-derived coverage matrix

`agent/test/core/provider_thinking/project_thinking_coverage_test.dart` derives its inventory from `ProviderRegistry.profiles`; it checks both explicit finite declarations and automatic native/unknown cases for all 16 shipped kinds. Registry coverage is not a claim that every model on every endpoint supports configurable thinking.

| Shipped kind | Automatic evidence / representative behavior | Active serialization boundary |
|---|---|---|
| `openai` | Exact OpenAI catalog facts, including the `gpt-oss-120b`/`gpt-oss-20b` model-owned effort facts; unevidenced non-control models do not inherit effort tiers | Chat `reasoning_effort` |
| `openai-codex` | Valid exact native Codex levels/default, or grounded static model facts | Responses `reasoning.effort` |
| `anthropic` | Exact supported Claude model: manual budget or adaptive effort; older non-thinking models unsupported | Anthropic Messages |
| `gemini` | Exact grounded ids only, `google/` namespace grounded, each with its own documented finite set and default (`gemini-2.5-flash` budget with `Off`, always-on `gemini-2.5-pro` without `Off`, `gemini-4-argon`/`gemini-3.8-flash` `low`…`high` default `medium`, `gemini-3.6-flash`/`gemini-3.5-flash-lite`/`gemini-3-flash-preview` with `minimal`, `gemini-3.1-pro-preview` `low`…`high` default `high`, `gemini-3-pro-preview` `low`/`high` default `high`); grounded non-control models unsupported; ids without an obtained per-model set/default stay unknown | Active Gemini-compatible route codec |
| `deepseek` | Exact toggle/effort models; fixed reasoners unsupported for runtime selection | DeepSeek Chat thinking/effort codec |
| `kimi` | Exact K3 effort or K2.6 toggle; fixed/code models unsupported for runtime selection | Kimi-compatible Chat codec |
| `zai` | Exact GLM policy; unevidenced/non-control models do not receive generic effort | ZAI Chat toggle/effort codec |
| `zai-coding` | Same model-owned GLM facts, distinct configured route | ZAI Chat toggle/effort codec |
| `openrouter` | Delegated exact upstream model facts; unknown/non-control models fail closed | Aggregator `reasoning` envelope, not native upstream extensions |
| `ollama` | Strict live capability/declaration; no probe means unknown | Native `/api/chat` typed `think` |
| `opencode-go` | Exact evidenced compatible model controls (e.g. exact DeepSeek V4.1 Flash overrides the generic effort policy); reasoning output alone insufficient | Active Chat codec |
| `nvidia` | Hosted NIM per-model contracts take precedence over first-party extensions: exact documented effort subsets/defaults or finite Boolean kwargs, with unknown controls remaining unknown. Exact compatible `gpt-oss` efforts remain model-owned; no hosted availability is inferred for self-hosted-only models. See [NVIDIA QA](../qa_maintenance/nvidia_thinking_wire_qa.md) | Chat `reasoning_effort` or typed `chat_template_kwargs`, never an inferred first-party envelope |
| `lm-studio` | Exact compatible model knowledge (including the `gpt-oss` intrinsic facts) or explicit finite declaration; unevidenced models unknown | Configured compatible Chat codec |
| `llama-cpp` | Exact compatible model knowledge (including the `gpt-oss` intrinsic facts) or explicit finite declaration; the server forwards a request `reasoning_effort` to its Jinja chat template, so the compatible Chat wire is used and no provider-kind allowlist applies | Configured compatible Chat codec (`reasoning_effort`) |
| `xai` | Exact grounded Grok facts (`grok-4.5` `low/medium/high`, `grok-4.6`/`grok-4.7` plus `xhigh`, default `high`, no `Off`) on the documented Chat effort wire; reasoning-only and nearby ids unknown | Configured compatible Chat codec (`reasoning_effort`) |
| `custom` | Exact model facts with compatible actual protocol, otherwise explicit validated declaration or unknown | Actual configured Chat/Messages mode; incompatible declaration rejected |

Grounding: [OpenAI reasoning guide](https://developers.openai.com/api/docs/guides/reasoning), [gpt-oss (open weights)](https://openai.com/index/introducing-gpt-oss/), [NVIDIA NIM gpt-oss-120b](https://docs.api.nvidia.com/nim/reference/openai-gpt-oss-120b), [llama.cpp server](https://raw.githubusercontent.com/ggml-org/llama.cpp/master/tools/server/README.md), [xAI reasoning](https://docs.x.ai/developers/model-capabilities/text/reasoning.md), [Gemini thinking](https://ai.google.dev/gemini-api/docs/thinking), [Gemini OpenAI compatibility](https://ai.google.dev/gemini-api/docs/openai), [Gemini models](https://ai.google.dev/gemini-api/docs/models), [GPT-5.6 Sol](https://developers.openai.com/api/docs/models/gpt-5.6-sol), [GPT-6 Astra](https://developers.openai.com/api/docs/models/gpt-6-astra), [GPT-5.2 Codex](https://developers.openai.com/api/docs/models/gpt-5.2-codex), [Claude thinking](https://platform.claude.com/docs/en/build-with-claude/thinking), [DeepSeek thinking](https://api-docs.deepseek.com/guides/thinking_mode/), [DeepSeek V4.1-Flash](https://www.deepseek.com/en/news/deepseek-v4-1-flash/), [OpenCode Go](https://opencode.ai/docs/go/), [Kimi thinking](https://platform.kimi.ai/docs/guide/use-thinking-models), and the exact native discovery schemas retained by the owning adapters. These sources do not imply blanket support for undocumented aliases or future models.

### 3. Image Capabilities: Actual Pixels or Honest Failure
For supported routes, user attachments and tool image results reach the LLM wire request as actual base64 image data:
- OpenAI Chat: Attached user images as `image_url` parts (`data:<mime>;base64,<data>`); tool image results projected as detached user context following contiguous result batches.
- Codex Responses: User image attachments and tool results mapped to `input_image` items with data URLs.
- Anthropic Messages: User image attachments and tool results mapped to `image` content blocks with base64 source.

**Recoverable Tool Capability Check:**
`ToolExecutionCallbacks.currentImageSupport()` reads the active turn's frozen admission, and the coordinator copies only its `supported | unsupported | unknown` value into each request-owned `ToolContext`. No provider identity or mutable configuration lookup is needed by the image handler. Missing context/capability remains `unknown`.

`ViewImageHandler.executeResult` checks this capability before resolving/reading/processing the file. Supported execution retains verified image blocks. Unsupported and unknown return distinct actionable text-only error results with no image blocks. The normal paired tool result reaches the next model continuation, allowing an honest explanation without poisoning history or creating a provider/contact failure. Non-visual user-attachment projection retains source attachments but no longer instructs unsupported/unknown models to inspect pixels with `view_image`.

**Fail-Closed Adapter Preflight:**
If adapter-facing history still contains image payloads (including previously persisted tool images) on an unsupported or unresolved route, Chat, Responses, and Anthropic adapters throw the typed local `LocalImageCapabilityException` before HTTP:
- **Unsupported:** `The selected model "<model>" does not support image input.`
- **Unknown:** `Image input capability is unknown for model "<model>". Specify supports_image_input in config.yaml under model_capabilities.`

The Runner handles this specific local exception as an actionable blocked invalid request without automatic failover, provider UUID exposure, a misleading contact-failure description, or a `Provider response` prefix. Unrelated `UnsupportedError` and actual HTTP/network/provider errors retain their existing classification. Canonical pixel history is not rewritten or silently stripped; genuinely pixel-bearing unsupported dispatch remains blocked. This adapter rule is distinct from intentional non-visual user-attachment projection and recoverable text-only tool errors.

**Verified Attachment Storage & Integrity:**
User attachments are strictly validated by `AttachmentStore.readVerifiedAttachment` prior to payload serialization:
- Binds private store references within the jail root (`${SANAD_STATE_HOME}/attachments`).
- Validates attachment lifecycle status (`available`).
- Confirms actual file size and SHA-256 digest match stored database metadata.
- Validates magic bytes for image payloads:
  - PNG: `0x89 0x50 0x4E 0x47`
  - JPEG: `0xFF 0xD8 0xFF`
  - GIF: `0x47 0x49 0x46 0x38`
  - WEBP: `RIFF....WEBP`
- Missing, corrupted, unavailable, or tampered images halt actionably before HTTP with `StateError` or `FormatException`. Synchronous file reads, CWD fallbacks, and global `getSanadHome()` paths are strictly prohibited.

**Turn Admission & Capability Snapshot Freezing:**
- The capability profile (`RouteCapabilityProfile`) is authoritatively resolved and frozen at turn admission (`AgentRunner.sendMessage`, `streamMessage`, `resumeStream`).
- The admitted profile remains immutable across all turn iterations, tool calls, measurements, and mid-turn `config.yaml` reloads.
- Mid-flight route overrides (`AgentRunner.updateTurnRoute`) explicitly re-resolve and update the profile for the target route before the next retry iteration.

### 4. Client Thinking Control Lifecycle
- **Transient Loading State:** When route metadata is being fetched, the selector renders a distinct `Loading...` chip (`route_thinking_mode_loading`), never premature `Unavailable`.
- **Authoritative Unknown:** An authoritative `unknown` status resolves to a `Default` chip (`route_thinking_mode_provider_managed`) representing provider-managed thinking.
- **Cache Reuse Without Flicker:** When returning to a previously loaded route on the same provider instance and agent, the cached descriptor is displayed immediately without flicker.
- **Route & Device Isolation:** Identical model IDs across different provider instances or different agents are strictly isolated; snapshots are invalidated on device/agent change.
- **Superseded Requests & Race Protection:** In-flight snapshot responses for superseded route selections are dropped. Revalidation captures session ID and ensures no silent selection reset occurs on superseded sessions.

### 5. Attachment Replay Admission & Early Turn Blocked Notification
- **Replay Admission Query:** During replay edit or retry turns, `commitSoftRewindAdmission` commits the replacement root user message inside a transaction and associates retained attachments with `status = 'attached'`. `AttachmentStore.resolveAdmissionPaths` and `loadAdmission` permit attachments with `status = 'staged' OR (status = 'attached' AND EXISTS (SELECT 1 FROM messages WHERE session_id = user_attachments.session_id AND message_id = user_attachments.message_id AND request_id = user_attachments.admission_id AND history_status = 'active'))`. The queued turn executor (`LocalRuntimeCatalog.buildTools`) reliably resolves disk paths for retained attachments while cross-request, cross-session, superseded, or corrupted attachments remain fail-closed.
- **Early Failure Notice Reporting:** When an early error occurs before or during turn preparation (e.g. tool resolution, catalog build, or model adapter initialization), `SessionTurnExecutor.runTurn` catches the exception, transitions the active work item to `SessionWorkState.blocked`, and invokes `RuntimeRecoveryService.reportFailure(..., forceBlocked: true)`. An actionable runtime notice is recorded in `session_runtime_notices` and broadcast to all connected clients via `session.runtime_notice`, preventing client 90-second timeouts or UI hangs and enabling immediate user retry or route correction.
- **Replay Execution Pipeline & Transport Isolation:** Replay turn execution exercises the full queued `SessionTurnExecutor` -> `AgentRunner` -> provider serialization adapter pipeline (`BaseOpenAIAdapter` / `BaseAnthropicAdapter`). `ProviderRequestTransport` enforces clear ownership boundaries: scoped requests create per-request owned HTTP clients closed upon request completion or cancellation (`_ownsClient = true`). For isolated test environments, `requestClientFactory` injects fresh request-owned clients per call. Unscoped operations (such as model catalog discovery) reuse `adapterSharedClient` unowned (`_ownsClient = false`), preserving shared client instances without accidental closure.
- **Client Replay Error Guidance & Lost-ACK Reconciliation:** On the client side, inline replay turn dispatches wrap execution in bounded exception handling (`try / catch / finally`). The client distinguishes confirmed rejections from unconfirmed transport drops (`disconnected`, `invalid_response`, `timeout`, `unconfirmed`). When delivery outcome cannot be confirmed, the UI surfaces honest unconfirmed-outcome guidance (`"Replay outcome could not be confirmed. Check conversation history before retrying."` or `"Disconnected from agent. Reconnect and check conversation history before retrying."`) rather than generic failure messages encouraging blind resend. Editor text and attachments are preserved with zero automatic resend, allowing manual user retry after checking history. In the event of a dropped transport acknowledgement where the backend accepted the turn, reconciliation occurs authoritatively through backend history updates and revision advancement, dismissing the superseded inline editor without duplicate client commits. Test coverage validates this presentation and state reconciliation seam at the cubit/repository boundary; daemon transaction rollback and socket reconnection remain governed at the gateway integration boundary.
