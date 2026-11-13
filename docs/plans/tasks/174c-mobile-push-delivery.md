# 174c — Mobile push delivery

**Status:** implemented on `task/174c-mobile-push` — device verification open (`[!]`)
**Owners:** new mobile notification module in `client/`, `client/android`, `client/ios`, `client/lib/infrastructure/socket/event_deduplicator.dart`
**Plan:** [174](../174-client-notifications-and-push-delivery.md)
**Depends on:** `174a` (payload and kinds), `174e` (relay delivery boundary)

## Goal

Deliver a notification to a backgrounded or terminated Android and iOS Client,
and let that Client decide from the foreground whether to show a banner: silence
when the user is reading the exact session, a heads-up notification when they are
reading another one.

## Locked decisions and scope

1. Push is only a wake-up. The same event may also arrive over the cloud socket;
   the canonical `event_id` guarantees one visible notification.
2. Provider credentials never ship in the Client. The Client registers a token
   with the relay through the authenticated account session and nowhere else.
3. Every kind is high urgency. On Android this requires a notification channel
   created with high importance before any user modification, because importance
   cannot be raised afterwards.
4. The foreground decision belongs to the Client: exact session visible means
   in-app only; any other session means banner and sound.
5. The user's OS settings win. Do Not Disturb, Focus, and per-app notification
   settings are never overridden silently; the product only documents what it
   cannot bypass.
6. Actions resolve the ask through the existing `tool_permission_response`
   command; no new authorization path is introduced.
7. iOS foreground suppression for a specific event requires a native delegate
   hook; the alternative of a globally silent foreground is rejected.

## Decisions taken in this task

1. **No push provider dependency entered the public graph.** The release contract
   forbids a Firebase dependency returning and forbids shipping push configuration
   in public config, so the provider SDK is a platform-owner build input rather
   than a repository dependency. The Client talks to one dependency-free
   platform channel (`com.eaststarai.sanad/mobilePush` plus its event channel), the
   Android bridge answers "no token" without a provider module, and iOS needs no
   SDK at all because APNs is a system framework. This is the smallest reversible
   choice: adding a provider later touches the platform build, not the Dart
   architecture or the release invariant.
2. **The foreground rule reuses `NotificationPresence.showsAsk`** instead of
   re-deriving presence, so mobile and desktop cannot disagree. One consequence is
   recorded deliberately: a session on screen that is already showing a
   *different* pending ask raises a banner, because the ask in the notification is
   not the one in front of the user. The session-only reading of the acceptance
   criterion still holds when no other ask is projected.
3. **Background and terminated display is provider-rendered.** The relay sends the
   redacted display fields the platform needs and a `sanad_envelope` JSON string;
   the Client therefore renders from the payload alone with no socket and no
   second parser.
4. **`openSystemSettings` is capability-gated.** iOS can open its per-app pane, so
   Settings offers the button there; Android cannot do it through the notification
   plugin, so the button is hidden rather than doing nothing.
5. **A terminated-client interaction waits for the replayed ask.** An approval is
   answered only after the Client's authoritative state arrives; a timeout drops
   the interaction instead of answering from the payload alone.

## Gates

### G0 — Platform discovery

- [x] FCM and APNs prerequisites confirmed: APNs is a system framework and needs
      only the App ID capability plus the `aps-environment` entitlement (both
      owned by release/platform); FCM needs a provider AAR and sender credentials,
      which stay with the hosted relay and the platform build. The iOS
      entitlement is now present; the App ID capability and profile regeneration
      are open items.
- [x] The current `AppDelegate` uses the UIScene life cycle with plugins
      registered in `didInitializeImplicitFlutterEngine`. `FlutterAppDelegate`
      forwards `UNUserNotificationCenter` callbacks to registered app delegates and
      `flutter_local_notifications` (23.0.1) registers as an app delegate, not as
      the notification-center delegate. The smallest correct hook is therefore a
      dedicated `UNUserNotificationCenterDelegate` installed after plugin
      registration that answers per event and preserves the previous chain.
- [x] Android 13 runtime permission is handled through the notification plugin
      (`requestNotificationsPermission`, `areNotificationsEnabled`) and is
      requested only from Settings. Channel inventory before this task was empty;
      it is now one high-importance channel per kind, created at initialization.
- [x] Mobile lifecycle: sockets die in the background and reconnect on resume;
      `AppShell` already calls `appCtrl.onAppResumed()` for mobile and web, and the
      bridge mirrors the foreground state so a backgrounded app is never treated
      as "in app".

### G1 — Token registration

- [x] Register after authentication, refresh on rotation, re-register on reconnect.
- [x] Revoke on logout, terminal `auth_revoked`, and account deletion (which
      performs the same logout).
- [x] The token stays in memory only: never logged, never in the Agent, never in
      workspace state, and referenced in diagnostics by fingerprint only.

### G2 — Foreground display policy

- [x] Channel and category inventory: every kind is high importance from creation,
      one channel per kind, iOS category per kind with the approval action set.
- [x] Exact visible session means no banner; another session means a heads-up
      notification with the Agent copy and actions.
- [x] The in-app attention state stays authoritative and is never mutated by push.

### G3 — Background and terminated display

- [!] Notification arrives and displays when backgrounded on Android: not
      executable on this host (no Android runtime/emulator, no provider module).
      Platform owner: release/platform pipeline.
- [!] Notification arrives and displays when terminated on Android: same reason
      and owner.
- [!] Notification arrives and displays when backgrounded on iOS: not executable
      on this host (no iOS simulator/device, no signing profile with the Push
      capability). Platform owner: release/platform pipeline.
- [!] Notification arrives and displays when terminated on iOS: same reason and
      owner.
- [x] A late escalation for an already resolved ask is dropped (unit-proven on the
      interaction path: unknown, resolved, and expired asks all fail closed).

### G4 — Actions and navigation

- [x] Approve, deny, and open from the notification resolve through the existing
      `tool_permission_response` path (unit-proven).
- [x] Deep link into the exact session and request on open (unit-proven through
      the session opener).
- [x] Fail closed when the request is already resolved or no longer exists
      (unit-proven).
- [!] The same three cases on a real device: not executable on this host; owner is
      the platform/release pipeline.

### G5 — Verification

- [x] Unit tests for the foreground decision matrix and dedupe with socket
      delivery.
- [x] Widget tests for the notification Settings surface, including the new
      pane-button capability rule.
- [!] Real-device verification on Android and iOS for background, terminated,
      action, and deep-link cases: see G3/G4. No PASS is claimed for any case that
      was not executed on this host.

## Recorded evidence for this session

| Case | Result | Reason / owner |
|---|---|---|
| Foreground, exact session visible | PASS (unit) | `mobile_foreground_policy_test.dart`, `mobile_push_service_test.dart` |
| Foreground, other session visible | PASS (unit) | Same suites; also asserts channel/category identity |
| Socket and push copy of one event | PASS (unit) | One presentation for one `event_id` |
| Token register/rotate/revoke | PASS (unit) | `mobile_push_token_registrar_test.dart` |
| Token never logged in the clear | PASS (unit) | `toString`/`fingerprint` assertions |
| Channels all high, categories per kind | PASS (unit) | `mobile_notification_catalog_test.dart` |
| Payload-only parsing | PASS (unit) | `mobile_push_message_test.dart` |
| Android background / terminated / action / permission prompt | `[!]` | No Android runtime on this host; needs the provider module; owner: platform/release |
| iOS background / terminated / per-event suppression / action | `[!]` | No iOS runtime on this host; App ID Push capability required; owner: platform/release |

## Acceptance Criteria

- [ ] Given the app is terminated and a permission request is raised, when the
      relay dispatches, then a banner with sound shows the redacted ask.
      `[!]` device case (see G3).
- [ ] Given the app is in the foreground reading the same session, when the push
      arrives, then no banner appears and the in-app prompt updates. `[x]` unit.
- [ ] Given the app is in the foreground reading another session, when the push
      arrives, then a heads-up notification appears. `[x]` unit.
- [ ] Given the user approves from the notification, when the Agent accepts, then
      the run resumes and the in-app prompt clears from the resolved event. `[x]`
      unit for the command path; `[!]` for the device round trip.
- [ ] Given the same event arrives by socket and by push, when both are handled,
      then exactly one notification is visible. `[x]` unit.
- [ ] Given the user logged out, when the relay dispatches afterwards, then no
      delivery occurs for the revoked token. `[x]` unit for the revocation; relay
      side is `174e`.

## Definition of Done

- [x] `fvm flutter analyze` passes in `client/`.
- [x] Focused tests pass, and the real-device evidence is recorded in this file.
- [x] `docs/technical/communication_protocols.md` §7.10 and
      [docs/technical/mobile_push_delivery.md](../../technical/mobile_push_delivery.md)
      describe the mobile behavior.
- [x] All new strings are localized; no Arabic literal exists in Dart source.
- [!] Graph index refreshed with `graphify update .`: the Graphify CLI is not
      installed on this host and no `graphify-out/` exists in this worktree, so the
      refresh could not run. Owner: whoever runs the graph maintenance step on a
      host that has the CLI; nothing in this change depends on the graph.

## Verification commands and results

Run from the repository root with `fvm` on `PATH`:

| Command | Result |
|---|---|
| `cd client && fvm flutter analyze` | `No issues found!` |
| `cd client && fvm flutter test test/unit/features/notifications test/widget/notifications` | `All tests passed! (133 tests)` |

## Open items

1. **Android provider module.** The platform build must add `firebase-messaging`
   and a `FirebaseMessagingService` that calls `SanadPushBridge.onToken`,
   `onDisplay`, and `onInteraction`. Until then Android registers no token and the
   Client reports no registered device, which is the honest state of the build.
2. **iOS App ID Push capability and signing profile.** The entitlement is in the
   repository; the Apple App ID must enable Push Notifications before a signed
   build with that key can be produced, otherwise the TestFlight export fails at
   signing time. Reversible: removing the entitlement disables iOS push and leaves
   the rest of the app unchanged.
3. **Relay side of `174e`.** `push.register_token` / `push.revoke_token` and the
   provider payload shape are specified in §7.10; the hosted service must
   implement them before any device case can be exercised.
4. **iOS `remote-notification` background mode** is deliberately not enabled: the
   relay sends a display payload, so background and terminated presentation need
   no background mode, and adding one would change the app's review posture.
