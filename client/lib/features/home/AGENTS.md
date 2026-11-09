# Home and Gateway Bootstrap Contract

## Scope
This contract applies to `client/lib/features/home/`.

## Bootstrap Ownership
- `GatewayConnectionCubit` is the feature-level owner of gateway status and first-route resolution.
- `AccountLanding` (`lib/core/navigation/account_landing.dart`) owns the one landing-eligibility rule: a non-desktop account with no registered device belongs on the zero-device onboarding surface, desktop keeps its local-first Home, and an account with a device keeps the location it asked for. Cold-start bootstrap, the Settings back action, and Home itself all resolve through it; never re-derive the rule at a call site.
- Complete first-launch gateway and registered-device routing before rendering `/home`; `HomeScreen` must not repeat bootstrap redirects after it renders, with one exception: an account that becomes ineligible for Home (no registered device, authoritative empty inventory) yields to the zero-device surface instead of rendering a device-less composer that has no route back to adding a device. A pending inventory is never ineligible.
- Count offline cloud devices as registered devices. Connectivity affects presentation, not device-registration routing.
- `HomeScreen` may reconcile the typed destination and active device before conversation providers exist, but session selection must run below the `SessionCubit` provider.

## Shell Chrome Ownership
- `HomeShellScaffold` owns the shell chrome for every surface that must offer the side menu: the optional side drawer, the drawer menu affordance, and the desktop-only bottom status bar. `HomeScreen` renders it for wide and compact layouts alike, and the mobile zero-device surface (`OnboardingSetupScreen`) renders it too, so a brand-new account with no devices still reaches Settings, Profile, and Sign out through the same drawer instead of a second menu implementation.
- `ConversationSidebarScope` owns the three cubits that drawer reads (`SessionSidebarCubit`, `SessionSearchCubit`, `SessionCubit`). It sits above the responsive layout, so crossing a breakpoint keeps the same cubit instances and never drops the selected session; a surface that hosts the drawer reuses that scope instead of re-creating conversation state.
- The zero-device surface carries the menu button itself (`showMenuButton`), because it renders no conversation header to host one. Home keeps its own in-content button.

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
- The sidebar-header compact-window action is native-desktop-only and delegates all resize/restore state to `WindowManagerService`; Home presentation must not call `window_manager` directly or retain competing window bounds.

## Navigation Integration
- Use the shared conversation history controller and typed destinations as the navigation authority.
- Route listeners must avoid update loops by comparing the requested route with the current history destination before navigation.
- A route Home navigates to on its own (no-route restore, New Conversation alignment, missing-device fallback, first-send promotion) is not a device pick: applying it must not call `DeviceCubit.setActiveAgent`, so it neither persists the device nor ends a remembered-device fallback. Only a user-opened route persists its device.
- Do not create Home-local copies of conversation, device, provider, or gateway state.
