# Agent Core Contract

## Scope
This contract applies to `agent/lib/core/`.

## Core Ownership
- Own configuration, environment paths, identity/auth persistence, provider runtime, shared request/message models, and dependency-composition primitives.
- `core/update/` owns verified standalone-agent replacement. CLI, local daemon, and client requests must delegate to it; source/FVM execution must never pull Git or replace a checkout.
- Do not absorb engine loops, interface protocols, capability catalogs, or evolution database workflows.
- Keep shared models transport-neutral and JSON-safe where they cross persistence or protocol boundaries.

## Environment and Identity
- Resolve runtime environment from process variables before the global `SANAD_HOME` environment file.
- `AuthManager` owns persistent `hardware_id`; create it locally when absent and keep it distinct from backend-assigned device ids.
- Persist Sanad auth in `SANAD_HOME/auth.json` with owner-only Unix permissions or equivalent Windows ACL.
- A UI-issued device token is initial pairing authority only. Before the first
  cloud registration, generate and persist a distinct durable device token
  locally; send both for the atomic claim, then remove the pairing token only
  after `register_success`. Retry the same pair after a lost response.
- Refresh Sanad access through the portal lifecycle, send refresh tokens in request bodies, and never log raw credentials.
- `AuthManager` publishes a credential-free process-local change signal only after a successful auth write or a meaningful external reload; credentials never enter that signal.
- Provider credentials must never share Sanad identity storage.

## Provider Runtime
- `ProviderRegistry` is the source of supported provider templates; `ProviderInstance` UUID is routing identity and display name is presentation metadata.
- `core/provider_usage/` owns the unified account-usage models, per-template usage adapters, and the usage adapter registry (Task 55). The registry is the single authority for whether an instance supports usage queries; clients must not hardcode a provider list. Adapters are auth-method-independent and read-only in v1; ChatGPT (`openai-codex`) maps `primary_window`/`secondary_window` to Session/Weekly and never synthesises a placeholder. Snapshots never carry credentials, account ids, or raw provider payloads.
- Provider setup is instance-first. Templates are immutable capability definitions; instances own editable metadata, credential revision, model choice, rate limit, and failover policy.
- Keep constants for protocol, auth method, credential action, requirement, and status centralized; do not branch on duplicate raw literals.
- Separate configured state from runtime readiness. Only a successfully verified current metadata/credential revision may become ready or default.
- Metadata or credential changes that invalidate verification must demote readiness.
- Provider-specific model discovery and generic model options must reuse one provider-owned implementation.
- Model discovery follows the instance protocol and retains selected/default plus curated fallback models when live discovery fails.
- Missing provider resolution returns a lazy error adapter rather than failing dependency composition or daemon startup.
- The dependency-composition default-adapter binding resolves the current runtime default on each lookup; it must never retain a missing-provider adapter across onboarding.
- Shared context services remain provider-neutral; each model turn supplies its live routed adapter explicitly.
- When a session/turn supplies no model, resolve the configured default dynamically; isolated tests without registered configuration may use the established safe placeholder fallback rather than crashing.

## Credential and State Storage
- Keep instance metadata/model cache/recent selections in the shared agent state database through the owning repositories.
- Open the agent state database through one shared connection; do not create a second handle for provider repositories.
- Keep provider secrets in the secret store keyed by instance UUID and expose only masked summaries outside the resolver. OAuth summaries may include display-only `account_label` and `account_name` derived locally from token claims; these values never become authorization state and raw tokens never cross the summary boundary.
- Credential mutation uses explicit keep, replace, or remove semantics; empty input never implies removal.
- When provider metadata and secrets share one Sanad Home boundary, mutating credentials must reconcile the secret store against authoritative instance UUIDs so replacement cannot preserve orphaned records; never prune across an explicit isolated state-home boundary.
- OAuth session storage remains separate from simple API-key configuration and Sanad auth.

## Message and Continuation Models
- Separate visible `Message.thought`, `Message.reasoning`, final `Message.content`, and opaque typed provider continuation state.
- Provider state carries namespace and optional issuer, survives persistence, and may be cleared only explicitly for the matching owner.
- Preserve state-only assistant messages and typed terminal finish reason across restart.
- Turn-bounded semantic continuation remains distinct from network/runtime recovery retry.
