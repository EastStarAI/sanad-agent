# Provider Setup Feature Contract

## Scope
This contract applies to `client/lib/features/provider_setup/`.

## Runtime Authority
- The daemon's provider registry is the sole source of templates, instances, authentication status, model options, readiness, defaults, limits, and failover settings.
- Do not hardcode provider catalogs or synthesize instances from templates.
- Query and mutate provider state through the feature client with explicit target-device context; presentation must not call sockets directly.
- Runtime readiness comes from authoritative instance status, not cache presence or a populated model list.

## Reusable Flow
- `ProviderSetupFlow` is the public reusable entry point for onboarding and Settings.
- Keep its cubit and state independent from host navigation and dismissal chrome.
- The embedding host owns close/dismiss behavior.
- Settings embeddings start from configured instances when any exist, disable the terminal ready screen, and remain on the configured list after readiness succeeds.
- Onboarding may show completion and invoke its ready callback only after authoritative runtime readiness.
- Invoke the ready callback on the first authoritative ready transition even when the embedding disables the terminal ready screen; display policy must not suppress host completion behavior.
- Ready callbacks carry the authoritative readiness snapshot, including the active provider instance and model.

## Instance-First Setup
- Always create or select an instance identity and unique display name before credential or OAuth operations.
- Suggest a unique display name for new instances and reject duplicates before dispatch.
- OAuth starts only after instance creation and carries `provider_instance_id`.
- Provider-visible names resolve from the selected instance first, then the selected template; do not depend on legacy provider-wide selection state.
- The first onboarding instance becomes default unless the user explicitly chose another default.
- A new-flow provisional instance id belongs only to that setup attempt: Back reuses it, confirmed Discard may remove only it, and editing an existing instance never assigns provisional ownership.
- Keep unsaved wizard input in controller-owned memory across requests and Back; provider secrets must not enter logs or stringified Equatable state.
- `Make Default` remains disabled for non-ready instances.

## Credentials and Metadata
- API-key edits default to a non-mutating keep action.
- Metadata-only edits must succeed without a stored or newly entered secret.
- Send credential replacement only after explicit user choice with a non-empty key.
- Adding or replacing an API key on an existing instance must complete canonical connection verification before the edit reports success; failed verification keeps the instance non-ready with accurate recovery feedback.
- OAuth account identity is an optional daemon summary projection: render `account_label` and a distinct `account_name` when supplied, never decode tokens or infer identity in the client, and preserve a safe Connected fallback when claims are unavailable.
- Custom providers must collect the canonical protocol before save.
- Keep the legacy request-limit DTO/protocol field for compatibility, but do not expose or send it from provider forms while local rate limiting is dormant; continue forwarding auto-failover settings without provider-wide fallbacks.

## Models and Refresh
- Treat live model discovery as an explicit loading, loaded, failed, or manual-entry lifecycle; cached suggestions must never turn a failed live fetch into apparent success.
- A discovery failure keeps Retry, Add Model, and Back available. Manual model input is saved only by explicit confirmation and remains visible after save failure.
- Drive readiness badges from authoritative model snapshot instance status.
- Complete manual refresh only on terminal updated or failed status under the matching request id.
- Expose a user-triggered manual refresh from conversation model selection.
- Recently Used rows must not truncate configured provider groups.
- Keep temporary provider-name lookup misses from degrading the UI to raw instance UUIDs.

## Provider Account Usage
- Scope usage state by target device and provider instance; late capability or snapshot responses must not restore deleted instances or cross a device change.
- Discover usage support from the daemon rather than provider names or authentication methods.
- Keep successful snapshots visible for one minute and use stale-while-revalidate after expiry without polling or blocking provider cards.
- Preserve a stale snapshot when its background refresh fails, and render only windows supplied by the daemon with remaining percentage first.

## Presentation
- Keep all visible text in English.
- Keep widgets reusable and controller-driven; they must not own polling, transport, or provider state.
- The shared flow must support both bounded overlays and unbounded page embeddings: bounded hosts scroll inside the flow, while Settings retains ownership of its page-level scroll.
- Details, OAuth, and model steps keep their current actions in a fixed footer for bounded hosts and let only the body scroll; unbounded Settings embedding keeps normal document flow.
- Instance-card mutations remain scoped to the targeted card and must not replace or reload-hide the configured list.
- OAuth polling belongs to the cubit and must stop on completion, cancellation, navigation away, or disposal.
