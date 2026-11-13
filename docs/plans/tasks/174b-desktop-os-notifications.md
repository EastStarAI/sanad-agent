# 174b — Desktop OS notifications

**Status:** implemented — G0–G4 closed on this host, G5 partially closed (unit and
widget evidence complete; live desktop pass per platform not executable here)
**Owners:** new `client/lib/features/notifications/`, `client/lib/infrastructure/socket/event_deduplicator.dart`, `client/lib/app.dart`
**Plan:** [174](../174-client-notifications-and-push-delivery.md)
**Depends on:** `174a` (payload and kinds)

## Goal

Raise a native OS notification on macOS, Windows, and Linux whenever a
notification-kind event reaches the desktop Client from either the local or the
cloud route, without any push provider, and without replaying old state as new
interruptions.

## Locked decisions and scope

1. Desktop delivery is local-only: the event arrives over the existing socket and
   the Client renders the OS notification itself.
2. Both routes are equal. The same canonical `event_id` delivered twice produces
   one visible notification.
3. The OS notification is raised even when the window is focused, unless the
   Client is currently showing that exact session.
4. Reconnect and profile-switch replays never raise an OS notification.
5. Notification permission is requested from an explicit user action in
   Settings, never on first event.
6. Clicking a notification opens the session and request that produced it;
   stale asks fail closed.

## Gates

### G0 — Platform discovery — closed on this host

- [x] Verify the plugin choice against all three desktop targets, including
      macOS bundle signing, Linux notification daemon availability, and Windows
      toast behavior under the current NSIS packaging.
- [x] Record the Windows limitation that active toast retrieval and cancellation
      require package identity, and confirm what replacement-by-tag can do
      without it.
- [x] Confirm the tray lifecycle keeps sockets alive while the window is hidden,
      and that an explicit quit ends delivery.
- [x] Confirm the existing `event_deduplicator.dart` contract and whether it can
      own cross-route dedupe.

**Findings**

- **Plugin:** `flutter_local_notifications` 23.0.1 (declares macOS, Windows,
  Linux, Android, iOS, and Web). It is reached through one conditional factory
  (`client/lib/features/notifications/infrastructure/notification_backend.dart`),
  and `notification_backend_native.dart` is the only library that imports it.
  macOS ≥ 10.14 is required by the plugin; `client/macos/Podfile` and the Xcode
  project already target 12.0. Linux resolves the plugin's D-Bus implementation
  (`dbus`, `xdg_directories`), so no `libnotify`/GTK build dependency is added.
  Windows resolves an FFI plugin that compiles into the Windows runner build.
- **macOS signing:** the release job builds with an imported Developer ID
  certificate, then `client/release/macos/release_macos.sh` notarizes and staples
  the DMG (`notarize_macos.sh` runs `notarytool`, `stapler`, and `spctl`). The
  app is not sandboxed (`com.apple.security.app-sandbox` = `false`), and local
  notifications need no notification-specific entitlement. A time-sensitive
  interruption level was deliberately not used, because that capability is a
  separate entitlement and the plan rules out requesting special approval.
- **Linux notification daemon:** the plugin talks to
  `org.freedesktop.Notifications` over the session bus, so availability is a
  runtime property, not a build one. Probed on this host:
  `daemon=absent reason=org.freedesktop.DBus.Error.ServiceUnknown`, i.e. a session
  with a bus but no notification server. The adapter therefore reports
  `unavailable` there instead of dropping notifications silently, and no live
  Linux notification pass is possible on this machine.
- **Windows packaging:** the release job installs a pinned NSIS 3.12 compiler and
  ships an `.exe`, so the process has no MSIX package identity. The plugin's
  Windows package documents the consequence: `cancel` does nothing and
  `getActiveNotifications` returns an empty list without package identity, while
  showing the same notification id still replaces the banner. Approval buttons
  are therefore not presented on Windows: the plugin reports the payload as the
  action id and drops the pressed button's identity, and an unreadable action
  must never become a decision.
- **Tray lifecycle:** `DesktopLifecycleManager` hides the window on close
  (`windowManager.hide()`), Clear keeps the process, sockets, Client CLI host, and
  tray alive; only `quit()` disposes services and calls `exit(0)`. Delivery
  therefore lives exactly as long as the process, and an explicit Quit ends it.
  Recorded in `docs/technical/desktop_background_and_system_tray.md` §3.3 and
  §7.6.
- **`EventDeduplicator` contract:** it dedupes by `event_id` **plus a payload
  fingerprint** (`dedupeKey = '<event_id>::<sha256(payload)>'`), with LRU and age
  bounds, and is shared by both transports through
  `DeviceConnectionCoordinator`. It cannot prove that two route copies with
  different payloads are one notification, so it did not need changing: the
  notification path reuses the class with `payload: null`, which reduces the key
  to the canonical `event_id` and makes both routes one sighting. No edit to
  `event_deduplicator.dart` was required.

### G1 — Permission and settings surface — closed

- [x] Add a Settings entry that shows the permission state and requests it from a
      click, with a clear explanation when the OS denies it.
- [x] Persist a global toggle and a per-kind toggle, localized, with all kinds
      enabled by default.
- [x] Reflect OS-level revocation without requiring an app restart.

**Evidence:** Settings → Notifications (`notifications_page.dart`, navigation key
`nav_tile_notifications`, deep link `?section=notifications`). Permission copy is
one of four states (granted / not asked / denied with an "Open system settings"
action / unavailable), and the ask button exists only before the OS was asked.
`NotificationSettingsCubit` owns permission and preferences for both the page and
the display pipeline; it refreshes on mount, after a request, and on app resume
(`NotificationBridge.didChangeAppLifecycleState`), so a revocation reaches both
surfaces without a restart. Preferences persist in
`NotificationPreferencesStore` (`notifications_enabled`,
`notifications_kinds_disabled`, `notifications_permission_requested`); a missing
value means enabled. Tests:
`test/widget/notifications/notification_settings_page_test.dart`,
`test/unit/features/notifications/notification_settings_cubit_test.dart`.

### G2 — Display pipeline — closed

- [x] Map each Agent kind to title, body, urgency, and actions, using the
      localized copy the Agent already rendered.
- [x] Raise the notification for both routes through one path.
- [x] Collapse repeated asks by `session_id + kind` so a replayed event replaces
      rather than stacks.
- [x] Suppress display only while the exact session and request are on screen,
      and still update in-app state in that case.

**Evidence:** `NotificationPayload.fromEvent` (Agent copy wins, Client l10n
fallback by kind), `NotificationDisplayPolicy.decide` (ordered matrix),
`NotificationCollapseKey.forAsk` (one stable OS id per `session_id + kind`),
`NotificationService` (one subscription path over
`DeviceConnectionCoordinator.eventStreams`). Suppression lives only in this
pipeline; the conversation path that renders the prompt never consults it, so
in-app state is unaffected. Tests:
`test/unit/features/notifications/notification_display_policy_test.dart`,
`notification_payload_test.dart`, `notification_collapse_key_test.dart`,
`test/widget/notifications/notification_display_matrix_test.dart`.

### G3 — Interaction — closed (platform coverage differs and is documented)

- [x] Open the session and request on click, including when the window was
      hidden through tray background mode.
- [x] Expose actions for approval kinds and route them to the existing
      `tool_permission_response` command.
- [x] Fail closed on an action whose request is already resolved, with no
      optimistic UI.

**Evidence:** `NotificationSessionOpener` restores and focuses the window through
`DesktopLifecycleManager.showWindow()`, resolves the agent (envelope identity →
cached session index → active device, else opens nothing), and navigates through
the application navigator key. `NotificationActionRouter` answers only through
the pending `DeviceSuspendedRequest` and
`ConversationRepository.respondToSuspendedRequest` (`scope: once` / `session`,
deny keeps the request's own scope); it mutates no Client state, so the prompt
clears only from the Agent's resolved event. A resolved, mismatched, or expired
request returns `stale` and sends nothing. Approval buttons are presented through
the macOS `sanad_ask` category and freedesktop actions on Linux; Windows and any
platform that cannot name the pressed button present no buttons. Tests:
`test/unit/features/notifications/notification_action_router_test.dart` plus the
action round-trip cases in
`test/widget/notifications/notification_display_matrix_test.dart`.

### G4 — Replay and quiet window — closed

- [x] Open a short quiet window after any socket connect, and keep in-app
      surfaces live while suppressing only the OS notification.
- [x] Prove that an unresolved ask restored from a checkpoint does not notify
      again after reconnect.

**Evidence:** `NotificationQuietWindow` (10 s) is armed from
`NotificationBridge` on every local or cloud `SocketLifecycleState.ready`.
`NotificationDisplayPolicy` consults it after dedupe and before preferences, and
it is the only consumer — in-app projections never read it. Tests:
`test/unit/features/notifications/notification_quiet_window_test.dart` and the
"suppresses a replay restored by a reconnect" / "raises a genuinely new ask after
the quiet window closes" widget cases.

### G5 — Verification — partially closed

- [x] Widget tests for the display decision matrix: focused same session,
      focused other session, hidden, replayed event, duplicate route.
- [x] Unit tests for collapse keys and the quiet window.
- [ ] One live desktop pass per platform for permission, display, click, and
      action. **Not executed** — no macOS, Windows, or Linux desktop session with
      a notification service is available on this host (see limitations).

## Acceptance Criteria

- [x] Given the window is hidden and a permission request arrives over the cloud
      route, when the event is processed, then one OS notification appears.
      *Proven at the pipeline boundary with a fake platform adapter: the adapter
      receives exactly one presentation request. Not proven against a real OS.*
- [x] Given the same ask arrives over both routes, when both are processed, then
      exactly one notification exists. *(Same canonical `event_id` → second copy
      is `dropDuplicate`; one adapter call.)*
- [x] Given the Client reconnects with a parked unresolved ask, when the socket
      opens, then no OS notification is raised and the in-app prompt is shown.
      *(Quiet-window case; in-app projection is untouched by this pipeline.)*
- [x] Given the Client is displaying that exact session and request, when the
      event arrives, then no banner appears and the prompt stays interactive.
      *(Presence suppression; the conversation path is independent.)*
- [x] Given the user clicks the notification, when the app restores, then the
      matching session is open and focused on the request. *(Window restore +
      resolved destination; the request itself is projected by the session
      surface from its own state.)*
- [x] Given the user answers from the notification action, when the Agent
      accepts, then the in-app prompt clears only from the resolved event.
      *(No optimistic mutation anywhere in the action path.)*

## Decisions during implementation

1. **Payload event name and shape.** `174a` is unstarted, so this task fixed the
   Client half of the contract: an additive `notification` event (alias
   `notification_dispatch`) carrying `kind`, `urgency`, `title`, `body`,
   `actions`, `deep_link`, `collapse_key`, `expires_at`, and `protocol`.
   Both a flat payload and a nested `notification` block are accepted.
   *Reason:* the smallest reversible choice that lets the Client be finished and
   testable now, without inventing an Agent decision. `174a` must emit this shape
   or the two tasks reconcile it explicitly.
2. **Collapse identity is Client-derived.** `session_id + kind` is canonical and
   an Agent `collapse_key` is accepted only when it equals that derivation.
   *Reason:* replacement must stay deterministic across releases and transports
   even if a producer changes its own derivation.
3. **Dedupe uses a private `EventDeduplicator` called without a payload.** It
   cannot be the transport-shared instance because that key includes a payload
   fingerprint.
   *Reason:* reusing the existing bounded LRU avoids a second dedupe
   implementation, and passing no payload is exactly the "event id only" contract.
4. **Platform support is a property of the adapter.** `isSupported` is false off
   desktop, so the pipeline drops everything and Settings states the limitation,
   instead of the app branching on platform.
   *Reason:* keeps mobile and web plugging into the same policy.
5. **Approval buttons only where the pressed button can be named** (macOS
   category, Linux actions). Windows presents none.
   *Reason:* a button whose identity cannot be read would either be dead or
   become a guessed decision.
6. **Presence is reported by the routed conversation surface, not by the
   conversation cache.** The reporter lives inside `HomeScreen`'s scope and reads
   the routed destination and the projected pending request.
   *Reason:* "on screen" is a routing fact; the cache cannot tell a hidden window
   or a Settings page apart from a visible session.
7. **A session on screen with no projected ask yet counts as presence.** A
   session showing a *different* pending ask does not.
   *Reason:* the ask's own prompt is about to appear in front of the user; a
   second banner would duplicate it, while suppressing a different ask would hide
   news.
8. **The quiet window is 10 seconds and restarts on every connect.**
   *Reason:* replayed state arrives immediately after a connect, and a flapping
   transport must not slip a replay past a window that already closed.
9. **Resolved asks are withdrawn** on platforms that support it (`cancel`).
   *Reason:* prevents a stale ask from being answerable after resolution; Windows
   cannot do it, which is documented rather than worked around.
10. **`flutter_local_notifications` is a normal pub dependency, which is why the
    Android build now enables core library desugaring** (the plugin requires it
    even when no scheduled notification is used).
    *Reason:* a `path`/desktop-only dependency cannot be conditional in pub; the
    alternative was writing three unverifiable native channels. The Android
    change is the documented requirement of the chosen plugin.
11. **No notification is derived from existing conversation events.** The Client
    raises only what the Agent dispatched (`tool_permission_request` is used
    solely to track pending asks for fail-closed actions).
    *Reason:* locked decision 1 — the Agent owns which event notifies. A local
    derivation would double-notify once `174a` lands.
12. **Settings gained a `notifications` destination** instead of embedding the
    switches in General.
    *Reason:* the surface owns permission plus ten kind switches, which does not
    fit the General page, and a destination is deep-linkable and driver-testable.

## Verification (commands and results)

All commands were run inside `client/` with `fvm` (Flutter 3.47.0 / Dart 3.13.0).

| Command | Result |
| :--- | :--- |
| `fvm flutter pub get` | Changed 7 dependencies (adds `flutter_local_notifications` 23.0.1 and its platform packages). |
| `fvm flutter gen-l10n` | Regenerated localizations; 47 new keys in `app_en.arb` and `app_ar.arb`. |
| `fvm flutter analyze` | `No issues found!` |
| `fvm flutter test test/unit/features/notifications test/widget/notifications` | `All tests passed!` (95 tests) |
| `fvm flutter test test/guards` | `All tests passed!` (includes the 1000-line ratchet, locale-stable keys, and font guards) |
| `fvm flutter test` (full fast suite) | `All tests passed!` — 2891 passed, 3 skipped (browser-only web guard) |
| `fvm flutter build web --release --dart-define-from-file=config/prod.json` | `✓ Built build/web` — the conditional import keeps Web free of the native notification library. |
| Linux notification-service probe (`DBusClient` → `org.freedesktop.Notifications.GetCapabilities`) | `ServiceUnknown` — no notification daemon on this host. |

## Limitations (implemented, not executed here)

1. **macOS live pass not executed.** No macOS host. Unverified: the permission
   prompt from the Settings button, `checkPermissions` reflecting revocation,
   banner presentation while the app is frontmost, the `sanad_ask` category
   buttons, click/action callbacks, notification replacement, and withdrawal on
   resolution. Implemented against the plugin's documented API only.
2. **Windows live pass not executed.** No Windows host. Unverified: toast
   delivery under the NSIS build, AUMID registration, replacement by notification
   id, and click handling. Known and documented limitations: no cancellation and
   no active-toast retrieval without package identity, and no approval buttons
   because the plugin does not report which button was pressed.
3. **Linux live pass not executed.** This host has a session bus but no
   notification daemon (`ServiceUnknown`) and no display, so the adapter would
   (correctly) report `unavailable`. Unverified: banner presentation, urgency
   mapping, freedesktop actions, replacement, and withdrawal.
4. **No platform build of the desktop runners was executed** (macOS/Windows/
   Linux native builds require their SDKs; this host lacks GTK dev packages).
   The Web release build was executed and passed.
5. **Android and iOS are not part of this task** and were not built. The new pub
   dependency is compiled into both, which is why the Android build enables core
   library desugaring; that Gradle change is unverified on this host.
6. **The Agent does not emit the notification event yet** (`174a` unstarted), so a
   live session cannot raise a real notification until `174a` lands. Everything
   was verified with synthetic canonical envelopes.
7. **`graphify update .` was not run.** The Graphify CLI is not installed in this
   environment and no `graphify-out/` exists in this worktree or the primary
   checkout, so the index could not be refreshed.

## Definition of Done

- [x] `fvm flutter analyze` passes in `client/`.
- [x] Focused widget and unit tests pass.
- [x] `docs/technical/desktop_background_and_system_tray.md` records the
      notification behavior and the quit limitation (§3.3, §7).
- [x] New user-facing strings exist in `client/lib/l10n/app_en.arb` and the
      Arabic source, with no hard-coded text.
- [ ] Graph index refreshed with `graphify update .` — not possible here (see
      limitation 7).
