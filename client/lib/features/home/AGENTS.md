# Home and Gateway Bootstrap Contract

## Scope
This contract applies to `client/lib/features/home/`.

## Bootstrap Ownership
- `GatewayConnectionCubit` is the feature-level owner of gateway status and first-route resolution.
- Complete first-launch gateway and registered-device routing before rendering `/home`; `HomeScreen` must not repeat bootstrap redirects after it renders.
- Count offline cloud devices as registered devices. Connectivity affects presentation, not device-registration routing.
- `HomeScreen` may reconcile the typed destination and active device before conversation providers exist, but session selection must run below the `SessionCubit` provider.

## Active Device Integration
- Re-check provider runtime readiness when the active Home device changes.
- Open a provider-setup gate only after a successful authoritative readiness response says the selected connected device is not ready.
- Initialize an empty or partial conversation provider/model selection from the authoritative ready response without replacing a complete existing user route. Provider and model are one pair; either value alone must not block initialization.
- When the forced first-provider gate completes, replace any stale client provider/model route with the authoritative ready pair before dismissing the gate.
- Persist an accepted empty-state provider/model initialization before depending on the current Home widget lifecycle; route replacement must not discard a late authoritative readiness response.
- Preserve the current Home UI when readiness checks fail or time out during disconnect or restart.
- Forced provider-setup gates must remain dismissible so users cannot be trapped outside Home.
- Show the injected readable worktree label only for linked worktrees launched through the development runtime; normal and main-checkout runs must not show an isolation badge.
- Render the bottom Home status bar only on native desktop platforms. Responsive width is a layout decision and must never make the status bar appear on Web or mobile.

## Navigation Integration
- Use the shared conversation history controller and typed destinations as the navigation authority.
- Route listeners must avoid update loops by comparing the requested route with the current history destination before navigation.
- Do not create Home-local copies of conversation, device, provider, or gateway state.
