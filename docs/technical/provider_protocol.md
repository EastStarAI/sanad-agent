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
- OpenAI-compatible discovery must prefer the configured base URL as-is and fetch `.../models`, but custom/local gateways may expose the catalog under `.../v1/models`; the runtime must retry that path before falling back to presets.
- Anthropic-compatible discovery must resolve `.../v1/models` from a root base URL (or `.../models` when the configured base already ends with `/v1`). Native Anthropic Messages requests authenticate with `x-api-key` plus the required `anthropic-version` header. Some Anthropic-compatible local/proxy gateways expose the same catalog only through `Authorization: Bearer ...`; in that case model discovery must retry with bearer auth before falling back. The main Sanad Anthropic adapter should keep native request execution on `x-api-key` by default and use bearer auth only as a compatibility fallback unless the runtime later adds an explicit auth-mode contract.
- When live discovery fails, the fallback list must preserve the instance's selected/default model and merge it with the template's curated fallback models so the picker never collapses to an unrelated single model.
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
| `model.snapshot` | `model.snapshot_result` | Returns cached models per instance (stale-while-revalidate), including `status` so clients can render true runtime readiness from the instance lifecycle instead of inferring it from cache presence. Model ids are instance-local: redundant `<template>/` prefixes and Gemini's `models/` transport prefix must already be stripped. |
| `model.refresh` | `model.cache_updated` | Refreshes models for an instance; **all events (started/updated/failed) carry the original `request_id`** and clients must complete the request only on `updated`/`failed`, never on `started`. |
| `model.recent.list` | `model.recent.recent_result` | Returns last 5 selections with current display names, using the same normalized instance-local model ids as `model.snapshot`. |
| `model.recent.record` | `model.recent.recent_recorded` | Records a model selection (upsert, moves to top). |

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

The shared `ContextEngine` is provider-neutral. `AgentRunner._streamNextResponse`
and `_generateResponse` resolve the current turn route and pass its adapter to
`contextEngine.compressIfNeeded(history, adapter: …)` before every model call.
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
