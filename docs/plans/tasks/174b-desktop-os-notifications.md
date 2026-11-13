# 174b — Desktop OS notifications

**Status:** not started — G0 open
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

### G0 — Platform discovery

- [ ] Verify the plugin choice against all three desktop targets, including
      macOS bundle signing, Linux notification daemon availability, and Windows
      toast behavior under the current NSIS packaging.
- [ ] Record the Windows limitation that active toast retrieval and cancellation
      require package identity, and confirm what replacement-by-tag can do
      without it.
- [ ] Confirm the tray lifecycle keeps sockets alive while the window is hidden,
      and that an explicit quit ends delivery.
- [ ] Confirm the existing `event_deduplicator.dart` contract and whether it can
      own cross-route dedupe.

### G1 — Permission and settings surface

- [ ] Add a Settings entry that shows the permission state and requests it from a
      click, with a clear explanation when the OS denies it.
- [ ] Persist a global toggle and a per-kind toggle, localized, with all kinds
      enabled by default.
- [ ] Reflect OS-level revocation without requiring an app restart.

### G2 — Display pipeline

- [ ] Map each Agent kind to title, body, urgency, and actions, using the
      localized copy the Agent already rendered.
- [ ] Raise the notification for both routes through one path.
- [ ] Collapse repeated asks by `session_id + kind` so a replayed event replaces
      rather than stacks.
- [ ] Suppress display only while the exact session and request are on screen,
      and still update in-app state in that case.

### G3 — Interaction

- [ ] Open the session and request on click, including when the window was
      hidden through tray background mode.
- [ ] Expose actions for approval kinds and route them to the existing
      `tool_permission_response` command.
- [ ] Fail closed on an action whose request is already resolved, with no
      optimistic UI.

### G4 — Replay and quiet window

- [ ] Open a short quiet window after any socket connect, and keep in-app
      surfaces live while suppressing only the OS notification.
- [ ] Prove that an unresolved ask restored from a checkpoint does not notify
      again after reconnect.

### G5 — Verification

- [ ] Widget tests for the display decision matrix: focused same session,
      focused other session, hidden, replayed event, duplicate route.
- [ ] Unit tests for collapse keys and the quiet window.
- [ ] One live desktop pass per platform for permission, display, click, and
      action.

## Acceptance Criteria

- [ ] Given the window is hidden and a permission request arrives over the cloud
      route, when the event is processed, then one OS notification appears.
- [ ] Given the same ask arrives over both routes, when both are processed, then
      exactly one notification exists.
- [ ] Given the Client reconnects with a parked unresolved ask, when the socket
      opens, then no OS notification is raised and the in-app prompt is shown.
- [ ] Given the Client is displaying that exact session and request, when the
      event arrives, then no banner appears and the prompt stays interactive.
- [ ] Given the user clicks the notification, when the app restores, then the
      matching session is open and focused on the request.
- [ ] Given the user answers from the notification action, when the Agent
      accepts, then the in-app prompt clears only from the resolved event.

## Definition of Done

- [ ] `fvm flutter analyze` passes in `client/`.
- [ ] Focused widget and unit tests pass.
- [ ] `docs/technical/desktop_background_and_system_tray.md` records the
      notification behavior and the quit limitation.
- [ ] New user-facing strings exist in `client/lib/l10n/app_en.arb` and the
      Arabic source, with no hard-coded text.
- [ ] Graph index refreshed with `graphify update .`.
