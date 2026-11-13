---
title: "Desktop Background Lifecycle, System Tray, and OS Notifications"
description: "Close-to-hide background persistence, macOS/Windows system tray projection, recent conversations, Agent/CLI lifecycle controls, and local desktop OS notifications."
---

# Desktop Background Lifecycle and System Tray

This document specifies the background execution lifecycle and system tray integration for the Sanad Flutter Desktop Client on macOS and Windows (Plan 102c).

---

## 1. Overview

By default on desktop platforms, closing the main window in standard desktop applications terminates the process. For Sanad Client, background persistence is critical:
- The Client acts as an authenticated routing relay and host for local command-line tools (`sanad-client`), executing commands against remote connected agents.
- Sockets and push subscriptions (gateway connection, device presence, remote command relay) must remain operational even when the UI window is dismissed.

Under the background lifecycle model:
- Closing the window **hides** the UI rather than destroying the process or terminating connections.
- The system tray icon (macOS menu bar / Windows notification area) provides continuous status visibility and quick access to common actions.
- An explicit **Quit** action owned by the application lifecycle is the sole path for application termination.

---

## 2. Platform Scope and Support Boundaries

| Platform | System Tray Support | Background Close-to-Hide | Notes |
| :--- | :---: | :---: | :--- |
| **macOS** | Supported | Supported | `NSStatusItem` menu in top system bar; click opens menu or restores window. |
| **Windows** | Supported | Supported | `Shell_NotifyIcon` in taskbar tray; right-click context menu, left-click restores window. |
| **Linux** | Supported | Supported | `StatusNotifierItem` over D-Bus; the panel hosts the icon and opens the menu, so click events stay with the panel. On GNOME this requires the AppIndicator extension (Ubuntu ships and enables it). |
| **Web / Mobile** | N/A | N/A | Background lifecycle and system tray are native desktop only. The Web build resolves the no-op tray backend at compile time and never links the native tray library (see 5.1). |

---

## 3. Background Lifecycle Model

### 3.1 Window Close Interception (`WindowManagerService`)

On every desktop platform:
1. During application bootstrap, `WindowManagerService.initialize()` sets `setPreventClose(true)`.
2. When the user clicks the window close button:
   - The native platform event is intercepted by `WindowListener.onWindowClose()`.
   - `WindowManagerService` delegates to `DesktopLifecycleManager.handleWindowClose()`.
   - `DesktopLifecycleManager` invokes `hideWindow()`, which calls `windowManager.hide()`.
   - The Flutter process, event loop, sockets, `ClientCliHost`, and in-memory caches remain fully active.
3. During an explicit quit the manager already released `setPreventClose(false)` and destroys the window itself, so a close request that arrives while shutting down never hides the window again.

Both hide and show go through `DesktopLifecycleManager`, which owns
`isWindowVisible` and publishes every change on `windowVisibilityChanges`. That
record is the Client's deterministic answer to "is the window on screen?" and it
is what notification presence reads (see 7.4). It does not depend on the platform
emitting a lifecycle transition for the hide, which not every desktop platform
does.

### 3.2 Restoring the Window (`Show`)

The main application window is restored and focused whenever:
- The user clicks "Show" in the system tray menu.
- The user left-clicks the tray icon.
- The user selects any conversation from the "Recent Conversations" submenu/list in the tray.
- macOS asks the running app to reopen it (a Dock-icon click, a Finder/Spotlight open, or `open -a` on the bundle). The Runner's `applicationShouldHandleReopen` forwards that request to Dart over `com.eaststarai.sanad/windowLifecycle`, and `DesktopLifecycleManager.handleReopenRequest()` runs the Show path below, so window state keeps a single owner instead of being duplicated in Swift.
- Implementation: `DesktopLifecycleManager.showWindow()` invokes `windowManager.show()` followed by `windowManager.focus()`.

macOS keeps the app alive behind those paths because `macos/Runner/AppDelegate.swift`
answers `false` from `applicationShouldTerminateAfterLastWindowClosed`. Flutter's
template answers `true`, which makes AppKit terminate the process as soon as the last
window closes and silently discards the tray icon on macOS only; Windows has no
equivalent policy. Flutter's delegate also implements no reopen handling and AppKit
never un-hides a window that `window_manager` ordered out, so a missing reopen
handler leaves the app running with no way back except the tray menu.

### 3.3 Explicit Shutdown (`Quit`)

"Quit" is the only path that performs full application shutdown. When triggered from the tray menu item "Quit":
1. **Tray Disposal**: Destroys the native tray icon and unhooks listeners (`AppTrayService.destroy()`).
2. **Client CLI Host Shutdown**: Unbinds the Unix domain socket / named pipe and stops the HTTP listener (`ClientCliHost.stop()`).
3. **Cache Flushing**: Synchronously flushes in-memory conversation drafts and snapshots to persistent storage (`ConversationCachePersistor.flush()`).
4. **Service Disposal**: Disposes `AppState`, `SanadSocketService`, and `DeviceConnectionCoordinator`.
5. **Window Teardown**: Disables `setPreventClose(false)` and destroys the native window (`windowManager.destroy()`).
6. **Process Exit**: Calls `exit(0)`.

Errors during any individual cleanup step are caught and logged; subsequent steps always proceed to ensure deterministic termination.

Quit also ends notification delivery. Hiding the window keeps the socket, the
tray icon, and the notification pipeline alive, so an ask that arrives while the
window is hidden still reaches the operating system; an explicit Quit tears the
same process down and no later ask can be presented. See 7.6.

---

## 4. System Tray Projection and Actions

The system tray menu is constructed via `TrayMenuBuilder.buildMenu()` and updated reactively by `AppTrayService`.

### 4.1 Menu Layout

```text
Show
---
[Recent Conversation 1]
[Recent Conversation 2]
... (up to 5 conversations)
---
Agent: Running (or Stopped)
Restart Agent (or Start Agent)
---
Client CLI: Enabled (or Disabled)
---
Quit
```

### 4.2 Recent Conversations Projection

- **Source**: Aggregated from `ConversationCacheStore` across all cached devices.
- **Ordering**:
  1. `lastMessageAt` descending (nulls last).
  2. `updatedAt` descending.
  3. `id` ascending (stable tie-breaker).
- **Cap**: At most 5 conversations are displayed (never more than 5).
- **Formatting**: Titles longer than 35 characters are safely truncated with `...`. Empty or whitespace-only titles display as `New Chat`.
- **Safe Fallback**: If no conversations exist in cache, a disabled informational item labeled `No recent conversations` is shown.
- **Navigation Behavior**: Selecting a conversation brings the client window to the foreground via `showWindow()`, then navigates directly to `ConversationDestination.session(deviceId: ..., sessionId: ...)`. Only the selected conversation is activated; no other conversation state is mutated.

### 4.3 Local Agent Availability and Controls

- **Query**: Queried via `LocalDaemonController.isDaemonRunning()`.
- **State Projection**:
  - If running: displays disabled informational item `Agent: Running`, followed by clickable action `Restart Agent`.
  - If stopped: displays disabled informational item `Agent: Stopped`, followed by clickable action `Start Agent`.
- **Execution**:
  - Clicking `Restart Agent` calls `LocalDaemonController.restartDaemon()`.
  - Clicking `Start Agent` calls `LocalDaemonController.startDaemon()`.
  - Re-entrancy guard ensures actions are executed exactly once per click.
  - The menu status refreshes immediately upon completion.

### 4.4 Client CLI State and Toggle

- **State Projection**: Reflects `ClientCliCubit.state.enabled` (`Client CLI: Enabled` vs `Client CLI: Disabled`).
- **Toggle Action**: Clicking the item toggles the state via `ClientCliCubit.setEnabled(!enabled)`, which updates `SharedPreferences` and starts or stops `ClientCliHost`.
- **Reactive Refresh**: `AppTrayService` subscribes to `ClientCliCubit.stream` and updates the menu label dynamically.

---

## 5. Architectural Seams and Testability

All native platform plugins (`window_manager`, `tray_manager`) are wrapped behind abstract adapters:
- `DesktopWindowManagerAdapter`: encapsulates window show, hide, focus, preventClose, and destroy.
- `TrayManagerAdapter`: encapsulates tray initialization, context menu updates, and destruction.
- `TrayMenuBuilder`: pure function producing `TrayMenuItemDescriptor` lists, allowing 100% test coverage of menu layout, sorting, truncation, and callbacks without requiring native C++ or platform channel execution.

### 5.1 Compile-time tray backend boundary

`tray_manager` reaches the native `nativeapi`/`cnativeapi` FFI library. That library
cannot be compiled for the Web (`dart:ffi unsupported`; `Only JS interop members
may be 'external'`), and a runtime platform guard cannot remove it from the
transitive compile graph. Abstracting the tray behind `TrayManagerAdapter` is
therefore not sufficient on its own: the *import* of the tray package must be
platform-conditional.

All tray files are workspace-relative under
`client/lib/infrastructure/platform/`:

| File | Compiled for | Contents |
| :--- | :--- | :--- |
| `tray_manager_adapter.dart` | every target | `TrayManagerAdapter` contract, no native import |
| `tray_manager_backend.dart` | every target | Conditional import selecting the backend, plus `createPlatformTrayManagerAdapter()` |
| `tray_manager_backend_native.dart` | `dart.library.io` | `NativeTrayManagerAdapter`; the only library that imports `package:tray_manager` |
| `tray_manager_backend_unsupported.dart` | every non-`dart.library.io` target, including Web | `UnsupportedTrayManagerAdapter`, a total no-op |

Rules:
- No library other than `tray_manager_backend_native.dart` may import `package:tray_manager`
  or another native FFI plugin.
- `tray_manager_service.dart` re-exports the contract and the factory, so consumers keep
  importing the tray surface from one place.
- Dependency injection resolves the adapter only through `createPlatformTrayManagerAdapter()`;
  it must not name a concrete backend class.
- Desktop behavior is unchanged: macOS, Windows, and Linux still receive the native adapter,
  and any target without a native backend gets a silent no-op instead of a compile failure.

---

## 6. Dependency and Toolchain Compatibility

### 6.1. Native tray icon lifetime

The tray icon is a native object owned by the process (`NSStatusItem` on macOS,
`Shell_NotifyIcon` on Windows, a `StatusNotifierItem` on Linux), not by the Dart
isolate. `tray_manager` 0.8.0 and its `nativeapi` 0.5.1+ core release those
handles through a `NativeFinalizer` when the isolate group shuts down, and revoke
the callbacks the previous isolate registered.

Earlier versions released the handles only through a Dart `Finalizer`, which does
not run on a Flutter hot restart: every restart left one more tray icon behind in
the operating system and could call into a dead isolate on the next click. The
Client therefore pins `tray_manager` at 0.8.0 or newer, and tray changes are
verified with an actual hot restart (`sanad-dev restart client`), because a fresh
process launch never exercises this boundary.

### 6.2. Tray icon assets

| Platform | Asset | Why |
| :--- | :--- | :--- |
| macOS | `client/assets/tray/sanad-tray-macos.png` | The bar owns the colour: the icon is a white monochrome glyph (`isIconTemplate = true`) drawn in the menu bar's own tint |
| Windows / Linux | `client/assets/tray/sanad-tray-default.png` | The icon is drawn as-is, in brand blue `#60A5FA` |

Both assets are 36x36 renders of
`docs/assets/brand/sanad-adaptive-foreground-source.svg` (the same artwork as
`client/assets/sanad_adaptive_foreground.png`): the artwork's alpha bounding box
is centred on a square canvas with a 2% margin, so it fills the icon instead of
floating inside the source file's empty margins, and the square canvas keeps the
lockup's aspect ratio when the platform stretches the image to 18x18 points.
Never point the tray at `client/assets/app-logo.png`: that artwork is fully
opaque, so it draws as a black square in the menu bar. Regenerate both assets if
the brand artwork changes, keeping the same canvas geometry and colours.

macOS keeps the platform default icon size (18x18 points) and no explicit size is
set; the tray adapter also releases any previously created icon before creating a
replacement, so a re-initialization inside one isolate cannot orphan an icon.

### 6.3. Linux build compatibility

Tray support is macOS/Windows only, but the tray dependency is a normal
cross-platform Flutter plugin, so its Linux backend is compiled for every Linux
desktop build. `tray_manager` pulls in `nativeapi`, whose GTK/GIO backend calls
`G_APPLICATION_DEFAULT_FLAGS`, a name that only exists from GLib 2.74 onwards.

`client/linux/CMakeLists.txt` defines that symbol to the identical legacy flag
`G_APPLICATION_FLAGS_NONE` only when the local GLib predates 2.74, and only
before the generated plugin subdirectories are added. This keeps supported Linux
development toolchains (for example Ubuntu 22.04 with GLib 2.72) building the
Client with the Linux tray enabled.

### 6.4. Linux runtime surface

- The tray icon is a `StatusNotifierItem` published over the session D-Bus by
  `tray_manager`, so no `libappindicator` package is required at runtime; the
  panel (GNOME with the AppIndicator extension, KDE Plasma, and most others)
  hosts the icon and opens the menu itself, which means tray click events never
  reach the application on Linux. Every action must therefore exist as a menu
  entry, including `Show`.
- `client/linux/runner/my_application.cc` sets the GTK application display name
  to `Sanad`; without it the desktop shell labels the running window with the raw
  application id.
- Bootstrap initializes the tray service on every desktop platform, and a window
  close hides the window instead of exiting.

---

## 7. Desktop OS notifications (Plan 174b)

The Client raises a native OS notification on macOS, Windows, and Linux for a
notify-worthy Agent event. Delivery is local on every desktop target: the event
arrives over the existing local or cloud socket, the Client decides whether it
is still news, and it presents the notification itself. No push provider, token,
or hosted relay participates on desktop.

Implementation lives under the workspace-relative
`client/lib/features/notifications/`; its local contract is
`client/lib/features/notifications/AGENTS.md`.

### 7.1 One path, two equal routes

`NotificationService` consumes `DeviceConnectionCoordinator.eventStreams` — the
local WebSocket and the cloud socket — through one subscription path. Nothing in
the pipeline selects a transport, prefers one, or labels a notification with the
route it came from. A notification raised by the cloud route is identical to one
raised by the local route.

The Agent owns the decision and the payload: kind, urgency, copy, redaction,
collapse identity, expiry, and target. The Client parses one additive event
(`notification`, with `notification_dispatch` accepted as an alias) whose payload
carries the kind, urgency, title, body, actions, deep link, collapse key, expiry,
and protocol version. Both a flat payload and an explicit `notification` block
are accepted, so a producer can attach the block to an existing event.

### 7.2 Platform facts

| Platform | Permission | Presentation | Action buttons | Cancel |
| :--- | :--- | :--- | :--- | :--- |
| **macOS** | `UNUserNotificationCenter`; asked only from Settings | Banner, sound, thread per session | Yes, through the category registered for the offered actions (`sanad_ask` family) | Yes |
| **Linux** | None; the freedesktop D-Bus service is the gate | `org.freedesktop.Notifications` with urgency | Yes, freedesktop actions | Yes (by notification id) |
| **Windows** | None | WinRT toast under the app's AUMID | No (see 7.3) | No on an unpackaged build |

The plugin is `flutter_local_notifications`, reached only through
`notification_backend_native.dart`. Web resolves a total no-op through a
conditional import, so the Web build links no native notification library.

macOS initialization explicitly disables the permission prompt
(`requestAlertPermission`, `requestSoundPermission`, `requestBadgePermission`
are `false`), because a prompt may only follow a click in Settings. The Client
records that it asked, so Settings can distinguish "not asked yet" from "refused"
— macOS reports both as "not enabled" — and offers the system notification pane
after a refusal instead of prompting a second time.

Linux talks to the session notification daemon over D-Bus, which is why the
feature needs no `libnotify` build dependency. A session without a daemon (or
without a running notification server) reports `unavailable` rather than
silently dropping every notification.

Button copy is fixed by the platform, not by the presentation request: macOS
registers its notification categories exactly once, when the plugin initializes,
and Linux fixes its default action name at that same moment. The adapter therefore
receives the localized action labels with `initialize` and resolves them once.
Because the saved locale is restored before the UI starts, the registered copy
matches the user's language; a language change made later in the running session
does not re-register the categories, so those buttons keep the previous language
until the next launch.
macOS registers `sanad_ask` for the full approval set plus one category per
offered subset (`sanad_ask.allow_once+deny`, …), so the buttons a notification
presents are exactly the actions its payload offered and a category can never add
one the payload left out. A payload that offers no approval action this build can
name matches no category and is presented without buttons. The English fallback
in `NotificationActionLabels` is used only when the label map is empty, and a raw
intent name such as `allowOnce` is never presented as copy.

### 7.3 Windows limitations under the current NSIS packaging

The Windows installer is NSIS, so the process has no MSIX package identity:

- **Cancellation does not work.** Windows only lets a package-identified app
  query or withdraw its own toasts, so `cancel` from this build is a no-op and a
  resolved ask can stay on screen until the user dismisses it. The Client still
  calls it, so a future packaged build withdraws correctly.
- **Active toast retrieval does not work.** `getActiveNotifications` returns an
  empty list for the same reason, so no surface may infer what is currently on
  screen from that API.
- **Replacement by tag still works.** Showing the same notification id replaces
  the banner, which is what collapse by `session_id + kind` relies on; only
  withdrawal is unavailable.
- **No approval buttons.** The Windows plugin reports the payload as the pressed
  action id and never exposes which button was pressed. Since an unreadable
  action must never become an execution decision, Windows presents the ask
  without buttons and a click opens the session, where the prompt is
  interactive.

### 7.4 Display decision

One policy answers "does this reach the operating system?", in this order:

1. **Platform support** — a target with no notification surface drops it.
2. **Expiry** — a notification whose `expires_at` has passed is dropped, so a
   late escalation never wakes a device for a resolved ask.
3. **Deduplication** — the canonical `event_id` is claimed once. The
   transport-shared `EventDeduplicator` keys on `event_id` plus a payload
   fingerprint, so the notification path uses its own instance called without a
   fingerprint; that reduces the key to the event id and makes both route copies
   one sighting. A duplicate in a quiet window is consumed there and never
   replayed later.
4. **Quiet window** — see 7.5.
5. **Preferences** — the global switch, the per-kind switch, and the per-kind
   urgency ceiling. Every kind is enabled by default at banner-and-sound; a
   stored value only records a deliberate change, and a ceiling can only lower
   what the Agent decided. See §8.1 and
   [communication_protocols.md](communication_protocols.md) §7.10.
6. **OS permission** — nothing is shown while the OS has not granted it.
7. **Presence** — the ask is suppressed only while the window is visible *and*
   the routed conversation surface is that exact session. A session on screen
   with no projected ask yet still counts, because the in-app prompt for the
   arriving ask is what the user is about to see. A session showing a *different*
   pending ask does not count, and a hidden window never counts even when its
   selected session is the one asking.

Window visibility is not a heuristic. `DesktopLifecycleManager` owns every hide
and show the Client performs — close-to-tray, the tray Show item, a notification
click, an explicit quit — and `NotificationWindowPresenceReporter` projects that
record into presence, so a platform that emits no lifecycle transition for a tray
hide can no longer leave presence claiming a window the user cannot see. An OS
lifecycle state is only corroboration: a lifecycle-hidden state also clears
presence, but `resumed` never overrides a deterministic hide, because activating
the process (a Dock-icon click, for example) does not necessarily restore the
window. On a target without the desktop manager the lifecycle state is the only
signal, which is the contract mobile and web will use.

Residual gap: a window that the operating system or the window manager hides
without going through `DesktopLifecycleManager` — most notably a user-driven
minimize that emits no lifecycle transition — is not observed, and presence then
treats the session as visible.

Suppression never changes in-app state. The conversation path that renders the
prompt does not consult this pipeline, so an ask is still projected, still
interactive, and still answerable while its OS notification is withheld.

Replacement identity is `session_id + kind`: two asks in one session collapse to
one banner whose id is a stable hash of that key. The Agent's `collapse_key` is
accepted only when it matches that derivation, so replacement stays deterministic
across releases and transports.

### 7.5 Quiet window after a connect

Every socket connect — local or cloud — opens a short quiet window (10 seconds).
A reconnect and a profile switch replay the parked state of every session,
including an ask the user never answered; that replay is authoritative in-app
state and must reach the conversation surfaces, but it is not a new
interruption. The window suppresses only the OS notification, and every new
connect restarts it so a flapping transport cannot deliver a replay after the
first window closed.

### 7.6 Interaction, and the quit limitation

- **Click** restores the window (from tray background mode too), raises and
  focuses it, resolves the Agent that raised the notification, and opens the
  session. Resolution prefers the envelope's device identity, then the cached
  session index, then the active device; an unresolvable notification opens
  nothing rather than the wrong device.
- **Approval actions** (macOS and Linux) are sent through the existing
  `tool_permission_response` command, allow-once (`scope: once`), allow-session
  (`scope: session`), or deny. Nothing is mutated optimistically: the in-app
  prompt clears from the Agent's resolved event, exactly as it does when the user
  answers in the app.
- **A stale action fails closed.** An action whose request is no longer pending,
  whose payload names a different request, or whose expiry has passed sends
  nothing and changes no UI. `NotificationAskRegistry` is the bounded record that
  makes this decidable while no conversation surface is mounted; a reconnect
  refresh arrives as a replayed `tool_permission_request`.
- **A cold start is not resumed.** An interaction whose launch started the
  process reaches a Client with an empty ask registry and no routed conversation
  surface, so answering it would build a decision from the notification payload
  alone, and opening it would navigate with no resolved destination. The adapter
  reports the launch interaction once (`readLaunchResponse`); the service records
  it (`NotificationColdStartOutcome`: `dropped`, or `unreadable` for a payload
  this build cannot parse) and acts on nothing. The pending ask, when the Agent
  still holds one, arrives through the ordinary reconnect replay and is answered
  in the app with full context.
- **A resolved ask is withdrawn** on macOS and Linux; see 7.3 for Windows.

Delivery therefore lives exactly as long as the process does. Hiding the window
through tray background mode keeps the sockets, the tray, and the notification
pipeline running, which is the point of that mode. An explicit **Quit** is the
only action that ends delivery: after it, no ask can be presented, because the
process that receives the event no longer exists.

### 7.7 Extension point for mobile and web

`NotificationPlatformAdapter` is the boundary the later delivery tasks plug
into. A mobile adapter (push plus foreground display) and a web adapter
implement the same contract — initialize, check/request permission, show,
cancel, open system settings — and are selected by the same conditional factory
in `notification_backend.dart`. Nothing above the adapter branches on platform,
and the display policy, collapse, dedupe, quiet window, and action routing are
shared as-is. `flutter_local_notifications` is compiled into Android and iOS
builds today because it is a normal pub dependency; that is why the Android
build enables library desugaring, which the plugin requires even when no
scheduled notification is used.

### 7.8 Verification boundary

Unit tests own the display matrix, collapse identity, dedupe, quiet window,
payload parsing, preference persistence, the fail-closed action rules, the macOS
category derivation (one category per offered action set), the action-label
fallback, and the cold-start outcome. Widget tests own the end-to-end pipeline
through a fake adapter, the Settings surface, and the window-presence projection
that turns a `DesktopLifecycleManager` hide into a display decision. Real
permission prompts, tray-hidden display, toast replacement, and notification
clicks are proven only by a live desktop pass per platform; any platform that has
not been exercised is listed as a limitation in
`docs/plans/tasks/174b-desktop-os-notifications.md`, and the preference surface
of `174f` records its own per-platform evidence in
`docs/plans/tasks/174f-notification-preferences-and-verification.md`.

## 8. Notification preferences, test notification, and platform limits (Plan 174f)

Settings → Notifications is the one place a user controls these, and every
control is **device-scoped**: the choice is stored on this Client, never on the
account, and never shared with another device. The wire shape and the Agent-side
application are owned by
[communication_protocols.md](communication_protocols.md) §7.10; this section
owns what the surface states.

### 8.1 What the page shows

- **System permission** with the real state, read on open and on app resume. When
  the OS refuses or revokes it while the in-app switch is on, the page says so and
  offers the system notification pane; the switch is not silently forced off, and
  no second prompt is offered where the platform has none (macOS).
- **The global switch**, then one row per kind with its current urgency. A kind
  offers exactly two loudness choices — the product default (banner and sound)
  and banner only (no sound) — because those are what the adapters actually
  implement; a third state, off, is the row switch itself. A row states what this
  device can actually do: while the OS refuses permission, or while no
  notification service is reachable, the row says so instead of describing an
  alert style that would not appear. The listed kinds
  include the two Client-owned kinds (`connection_lost`, `auth_required`) so the
  taxonomy is one model on every platform, even though `174b` does not raise them.
- **A test notification action** that runs the real pipeline. Its answer is one of
  shown, suppressed by a kind setting, suppressed by the OS permission,
  unsupported on this system, or failed to present; a probe that always claims
  success would be worse than no probe. The action is offered only once the
  running pipeline has attached its sender.
- **Platform limits**, stated in the page rather than discovered later:
  - OS settings always win. A system-level block is not overridden by the in-app
    switch, and nothing is shown while it is in place.
  - On iPhone and iPad a web notification arrives only when the site is installed
    as a web app from the browser share menu; an ordinary browser tab receives
    none. The line is rendered only on the web surface, so a desktop build does
    not claim a limit it does not have.

### 8.2 Localization

Every string on this surface is authored in `client/lib/l10n/app_en.arb` and
translated in `app_ar.arb`; no widget holds a literal and no Dart source holds an
Arabic literal. `client/test/guards/notifications_localization_guard_test.dart`
enforces all three (no hard-coded `Text(...)` literal, no Arabic literal, every
referenced key authored in both locales), and
`notification_settings_rtl_test.dart` proves the page renders right to left in
Arabic with no English label leaking through.

### 8.3 Verification record

The per-platform matrix is recorded in
[174f-notification-preferences-and-verification.md](../../docs/plans/tasks/174f-notification-preferences-and-verification.md),
with the date and the build identity of each executed row. A platform without
recorded evidence is marked `[!]` with the reason and the owner; nothing is
claimed as verified because a mock passed.
