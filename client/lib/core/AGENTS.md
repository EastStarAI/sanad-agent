# Core Domain Contract

## Scope
This contract applies strictly to the `sanad-client/lib/core/` directory.

## Core Ownership
* Use `core/` for app-wide composition only:
  - Dependency Injection (DI) and service composition.
  - Application bootstrap.
  - Global navigation and route guards.
  - App-level layout shell (`app_shell.dart`).
  - App-level global state holders such as `AppState`.
* **DO NOT** place feature-specific business logic or screens inside `core/`.

## App Composition Entry Points
The canonical app composition flow must only go through:
- `lib/app.dart`
- `lib/core/presentation/app/app_providers.dart`
- `lib/core/presentation/app/app_shell.dart`
- `lib/core/navigation/app_router.dart`
- App-wide overlays that coordinate cross-route UX, such as the device-code login challenge overlay, belong in `app_shell.dart` composition and should wrap the routed child rather than being duplicated in individual screens.

## Routing Rules
- Canonical routing configurations must live under `core/navigation/`.
- Always define route configurations inside `AppRoutes` and routing logical handlers/redirects inside `AppRouter`.
- Keep authentication-aware redirects and guards strictly centralized in `AppRouter`.
- Treat `/` as the app bootstrap gate. It must render the bootstrap/loading screen and defer gateway/device readiness decisions to the centralized gateway state flow before `/home` is shown.
- Full logout must clear app-wide, user-scoped ephemeral transport state such as cross-transport event deduplication before the next authenticated session starts.
- **DO NOT** hardcode route strings in features or presentations. Use strongly-typed routes or constants.
- Navigation transitions must be executed using `context.go` or `context.push`.

## Navigation History and Deletion Contract (Plan 32e)

### Typed Destination
Every conversation route resolves to a `ConversationDestination` (defined in `core/navigation/conversation_destination.dart`). This typed model carries:
- `deviceId` — The target device.
- `sessionId` or New Conversation sentinel — Use `destination.isNewConversation` to check.
- `workspaceId` — Optional preselection for New Conversation.
- Stable equality for route identity comparison and deduplication.

### Route Identity
Route identity is based on `(kind, deviceId, sessionId, workspaceId)`. Two destinations with the same identity represent the same logical location. This is used for:
- Preventing duplicate history entries (re-selecting current is a no-op).
- History pruning after deletion.
- URL/destination reconciliation across devices.

### New Conversation Marker
New Conversation is NOT represented by a null/empty sessionId on an existing session route. Instead, it has its own route path `/conversations/:deviceId/new` and its own `ConversationDestinationKind.newConversation`. The route string `new` is the sentinel path segment.

### URL / Deep-Link / Device Reconciliation Rules
1. **URL → Destination**: `ConversationDestination.fromRouteParams()` parses GoRouter path/query params into a typed destination. The `new` path segment maps to `newConversation`; a non-`new` sessionId maps to `session`; no sessionId maps to `conversationsList`.
2. **Deep-link → Device resolution**: The `deviceId` from the URL is authoritative. If the device is not available or has been removed, the redirect guard falls back to the first available device, then to onboarding if no devices exist.
3. **Device-native navigation**: UI intents (sidebar tap, New Conversation button) construct a `ConversationDestination` directly and navigate via `context.go(destination.routePath)`.
4. **Browser synchronization**: History changes from GoRouter pop/forward are reconciled with `NavigationHistoryController` snapshots to prevent update loops between route parsing and state emission.
5. **Session restoration after restart**: The typed `ConversationDestination` per device from `ConversationCacheStore` is the sole restart source. A `session` destination is reopened when valid; a `newConversation` destination reopens New Conversation with its nullable workspace preselection. `lastSelectedSessionId` is context inheritance only and must never infer a restart destination. A missing destination defaults to New Conversation. If the session was deleted while offline, the fallback in rule 6 applies.

### Pruning / Fallback (Deletion or Lost Destination)
1. **Non-current session deleted**: Removed from history back/forward stacks via `NavigationHistoryController.removeFromHistory()`. Current destination unchanged.
2. **Current session deleted**:
   a. Remove from back/forward stacks.
   b. Cancel or reject all in-flight requests for that session.
   c. Determine fallback: walk back stack for the last valid same-device destination (session or New Conversation). If none found in back stack, walk forward stack. If still none, use New Conversation for that device.
   d. Apply `NavigationHistoryController.replaceCurrent(fallback)` — prevents `goBack()` from returning to the deleted URL.
   e. Navigate to the fallback destination via GoRouter path replacement.
3. **External delete event** (`session_deleted` from another device): Same logic as local deletion, without the transport confirmation step.
4. **Deleted destination during fallback**: The consuming same-device fallback helpers prune invalid candidates and remove the selected fallback from its source stack, preventing duplicate Back entries.
5. **New Conversation in history**: Never pruned (always reachable). If New Conversation has a `workspaceId` and the workspace is gone, the workspace preselection is silently dropped.

### Navigation History Controller
Defined in `core/navigation/navigation_history_controller.dart`. The controller:
- Manages back/current/forward stacks of `ConversationDestination`.
- Exposes `navigateTo()`, `goBack()`, `goForward()`, `replaceCurrent()`, `removeFromHistory()`, `clear()`.
- Emits `NavigationHistorySnapshot` changes via a broadcast stream.
- Synchronizes with GoRouter without creating update loops.

## State Management Rules
- Use `flutter_bloc` (`Cubit` or `Bloc`) for feature-specific interactive states and UI screen orchestration.
- Use `provider` only for exposing pre-instantiated infrastructure services, dependency injection, and app-level service composition. Do not use it for complex UI state management.

## Development Runtime Configuration

- Public source launch profiles use Production hosted endpoints with Local+Cloud enabled by default; automated tests must not contact Production.
- Public source must not own hosted Development or Staging endpoint values. Non-local profiles default to Production, while private deployment owners inject `BACKEND_URL` and `PORTAL_URL` explicitly at build time.
- Keep worktree identity compile-time and optional. `sanad-dev` may inject a readable linked-worktree name, branch, absolute Sanad Home, and home-derived SharedPreferences prefix through `AppConfig`; ordinary, primary-user, and packaged runs retain the default preference namespace.
