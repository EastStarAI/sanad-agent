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
- Adding or replacing an API key must complete canonical connection verification before the edit reports success, and a new instance may never advance to model selection with a rejected key; failed verification keeps the credential form visible with its typed, localized cause instead of a generic sentence, plus a stable `provider_form_back_to_list` action that returns to the configured list without deleting the persisted instance.
- Connection verification and Test consume one daemon verdict (`provider.instance.test`). Setup gates send `probe: false` and block only on a definitive discovery failure, so a probe can never reject a valid credential; the Test action sends the default `probe: true` and renders four distinct shapes — proven route (models plus round-trip), partial success (`probe_state: skipped`, no model selected), non-blocking probe warning (`probe_state: warning`), and a definitive failure. A probe `403` is a warning (`providerProbeForbidden`), never a rejected credential. The Client never presents a `fallback`/preset list as verified.
- Instance cards render the daemon's typed connection projection (`discovery_error`, `model_cache`): the localized category message, the sanitized endpoint, and the "unverified fallback list" label. The Client never invents a status from cache presence and never echoes the daemon's English summary for any category. A non-definitive cause keeps the card's status and renders in warning style with `providerLastCheckFailed(<cause>)`, so a `READY` badge and a failed last check never contradict each other.
- Interactive acceptance of a provider card is key-addressed, never coordinate-guessed or text-matched. Every key is `provider_<area>_<instanceId>` and stays identical in `en` and `ar`: the persisted projection notice owns `provider_discovery_{notice,message,endpoint,fallback}_<id>`, the transient Test failure owns `provider_test_failure_{notice,message,endpoint}_<id>` (a distinct prefix because both notices can render in one card, so a key lookup is unique), the Test summary owns `provider_test_result_<id>`, and the `Usage & limits` section owns `provider_usage_section_<id>`, `provider_usage_message_<id>`, `provider_usage_reconnect_<id>` or `provider_usage_retry_<id>` (the action names the behavior, not the status word), `provider_usage_plan_<id>`, `provider_usage_window_<id>_<window type>` for each reported window, and `provider_usage_reset_credit_<id>_<index>` / `provider_usage_reset_credit_expiry_<id>_<index>` for each reset credit.
- OAuth account identity is an optional daemon summary projection: render `account_label` and a distinct `account_name` when supplied, never decode tokens or infer identity in the client, and preserve a safe Connected fallback when claims are unavailable.
- Custom providers must collect the canonical protocol before save.
- Keep the legacy request-limit DTO/protocol field for compatibility, but do not expose or send it from provider forms while local rate limiting is dormant; continue forwarding auto-failover settings without provider-wide fallbacks.

## Models and Refresh
- Treat live model discovery as an explicit loading, loaded, failed, or manual-entry lifecycle; cached suggestions must never turn a failed live fetch into apparent success.
- A discovery failure keeps Retry, Add Model, and Back available. Manual model input is saved only by explicit confirmation and remains visible after save failure.
- Drive readiness badges from authoritative model snapshot instance status.
- Complete manual refresh only on terminal updated or failed status under the matching request id.
- Expose a user-triggered manual refresh from conversation model selection.
- Project model-cache terminal notifications through the existing feature client with strict provider/device identity and finite status validation. Observation is consumer-lazy and shares source subscriptions; malformed/foreign notifications and raw socket errors cannot clear valid authority or leak raw diagnostics.
- Recently Used rows must not truncate configured provider groups.
- Keep temporary provider-name lookup misses from degrading the UI to raw instance UUIDs.

## Provider Account Usage
- `ProviderUsageCubit` owns the per-device provider display-name catalog used by the composer; catalog generations are separate from usage/support request generations.
- Publish instance names only when `ProviderSetupCubit.snapshotGeneration` advances after a successful snapshot load or mutation. Navigation, auth cancellation, readiness error text, and failed loads are not snapshot authority; a successful empty snapshot may clear the catalog.
- Preserve catalog invalidation generations across device clears until cubit disposal so late pre-clear responses cannot repopulate names. An authoritative unchanged snapshot must still neutralize pending stale catalog loads; quiescent identical snapshots remain no-ops.
- Scope usage state by target device and provider instance; late capability or snapshot responses must not restore deleted instances or cross a device change.
- Discover usage support from the daemon rather than provider names or authentication methods.
- Keep successful snapshots visible for one minute and use stale-while-revalidate after expiry without polling or blocking provider cards.
- Preserve a stale snapshot when its background refresh fails, and render only windows supplied by the daemon with remaining percentage first.
- When a snapshot carries reset credits, render each available credit as its own localized row with its local expiration date/time. The combined `N resets available` line is only the no-detail fallback, and the single shared Reset action remains unchanged. Provider titles and identifiers are never shown.
- The usage attention body localizes every message and never echoes the daemon's English text. `auth_required` renders `Reconnect`, which calls the owner's shared `ProviderSetupCubit.reconnectInstance` (the same account re-authentication as the instance form); any other failure renders `Retry` as a usage refresh. Usage status never mutates an instance card status.

## Presentation
- Localize user-visible copy through the Client localization owner with equivalent English/Arabic meaning; do not introduce hard-coded language-specific UI strings.
- The setup flow is reachable from a conversation even when the device has no provider: the composer's model/provider picker is always available and its Settings action opens this feature's providers section for the selected device. A device with no configured provider therefore has one in-conversation path into setup, not none.
- The instance form's footer carries up to three actions (Cancel, back to providers, Continue). Below an iPhone-class width it stacks them instead of sharing one row, because a 338 px dialog cannot fit them side by side; wider dialogs keep the single row with the primary action on the right.
- Keep widgets reusable and controller-driven; they must not own polling, transport, or provider state.
- The shared flow must support both bounded overlays and unbounded page embeddings: bounded hosts scroll inside the flow, while Settings retains ownership of its page-level scroll.
- Details, OAuth, and model steps keep their current actions in a fixed footer for bounded hosts and let only the body scroll; unbounded Settings embedding keeps normal document flow.
- Instance-card mutations remain scoped to the targeted card and must not replace or reload-hide the configured list.
- OAuth polling belongs to the cubit and must stop on completion, cancellation, navigation away, or disposal.
- Concurrent `model.snapshot` requests for the same target device share one in-flight request in `ProviderSetupClientImpl`; consumers must not issue their own parallel snapshot loads to work around it.
- Provider-picker search is presentation-only. `ProviderSearchFilter` (`presentation/utils/provider_search_filter.dart`) is the single owner of the trim, case-fold, and display-name/template-id/alias match rules, and it preserves the registry order it is given. The picker holds the query in its own widget state: no cubit field, no protocol change, and no extra daemon request. An empty or whitespace-only query returns the authoritative catalog unchanged, no match renders the localized empty state instead of a blank list, and the stable keys `provider_picker_search_field`, `provider_picker_search_clear`, and `provider_picker_empty_results` remain the interactive-acceptance contract. The field never autofocuses, and the picker adds no keyboard-selection shortcut of its own.
