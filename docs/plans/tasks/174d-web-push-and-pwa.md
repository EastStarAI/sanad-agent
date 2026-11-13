# 174d — Web push and installable PWA

**Status:** implemented on `task/174d-web-push`; build, analyzer, and tests
green. Live browser and installed-iOS evidence is unexecuted on this host and
recorded as `[!]` below.
**Owners:** `client/web`, web notification module in
`client/lib/features/notifications/`, `client/lib/infrastructure/socket/event_deduplicator.dart`
**Plan:** [174](../174-client-notifications-and-push-delivery.md)
**Depends on:** `174a` (payload and kinds), `174e` (relay delivery boundary)

## Goal

Deliver a notification to a browser tab that is closed, on desktop browsers and
on Android, and on iOS through an installed home-screen web app, while keeping
the in-page experience authoritative when the tab is open.

## Locked decisions and scope

1. Web push is a wake-up path, not the primary one. An open tab receives the
   event over the socket and decides locally whether to show a browser
   notification.
2. Push subscriptions are registered against the authenticated account session
   and revoked on logout.
3. iOS web push is only supported for an installed home-screen app; the product
   states that requirement instead of hiding it.
4. Service worker ownership is decided once and documented, because Flutter
   generates its own worker and cannot host the push listener itself.
5. Every kind is high urgency; browsers still apply their own site-level and
   OS-level settings, which the product does not attempt to override.

## Decisions taken here (smallest reversible option)

1. **Own the root-scope worker.** `client/web/sw.js` is the only registered
   service worker; an authored `client/web/flutter_bootstrap.js` registers it and
   the Flutter-generated worker is never requested. Verified fact behind the
   decision: in Flutter 3.47 the generated `flutter_service_worker.js` is a
   tombstone whose `activate` handler unregisters itself and reloads clients; it
   has no offline cache and no injection point. Offline consequence: no app-shell
   pre-cache and no cold offline start, identical to the generated worker's
   current behavior; installability is preserved by the manifest. Legacy
   `flutter*` caches are deleted on activate. Documented in
   [web_push_delivery.md](../../technical/web_push_delivery.md).
2. **Approval buttons are not offered on web.** Chrome caps a notification at two
   actions, Safari at one, and Firefox ignores them, so a three-way approval set
   cannot be shown without silently dropping a decision. The banner is the
   wake-up; the click opens the exact session and the user answers through the
   existing in-app prompt and `tool_permission_response` path. Any action a
   browser does report is still routed through `NotificationActionRouter`, and
   the web adapter therefore reports `supportsApprovalActions = false`.
3. **A closed-tab action opens the session instead of replaying a decision.**
   With no page to receive a postMessage, the worker opens
   `?sanad_session_id=…&sanad_request_id=…`, the page consumes and clears the
   query, opens that session, and retries once when the device inventory arrives
   after a cold start. A URL is not evidence that the user pressed a button, so
   the decision is never taken from it.
4. **VAPID public key is a build define**, `SANAD_WEB_PUSH_VAPID_PUBLIC_KEY`;
   empty means `unconfigured` and Settings says so. The private key never enters
   the Client.
5. **Client-to-relay registration is a documented public contract** with
   fail-closed handling: `POST`/`DELETE
   {backend}/api/notifications/web-push/subscriptions`, bearer-authenticated.
   `404/405/501` leaves the browser permission intact and reports that delivery
   is not registered. Owned by 174e on the hosted side; recorded in
   [communication_protocols.md](../../technical/communication_protocols.md) §7.10.

## Gates

### G0 — Service worker and install discovery

- [x] Own the worker rather than keep the generated one; the generated worker
      cannot host a listener because it unregisters itself. Offline behavior is
      unchanged (no app-shell cache) and is documented.
- [x] Confirmed there is no `--pwa-strategy` flag in Flutter 3.47; the default
      build emits the tombstone and `flutter_bootstrap.js`, and the authored
      bootstrap is the supported override (`{{flutter_js}}`,
      `{{flutter_build_config}}` substituted by the build). The PWA manifest is
      served `standalone` in every profile because it is a static
      `web/manifest.json` copied by the build; the web build has no
      profile-specific manifest.
- [x] Subscription behavior and endpoint lifetime confirmed from the platform
      contracts: `PushSubscription.endpoint` is opaque and may rotate through
      `pushsubscriptionchange`; iOS exposes push only to an installed home-screen
      app.

### G1 — Subscription lifecycle

- [x] Permission is requested only from the Settings action, and only when the
      browser has not decided.
- [x] Subscription creation uses the build-defined VAPID public key; registration
      uses the current account bearer token and the Client instance id.
- [x] Rotation is re-registered from `pushsubscriptionchange`; logout revokes
      with the token captured while the session was still valid, then
      unsubscribes and clears the local record.

### G2 — Delivery while closed

- [x] The worker renders title, body, and icon-less text from the payload alone,
      enforces `expires_at`, honours the mirrored preference policy, and skips
      unknown kinds.
- [x] Notification click focuses an open window or opens the exact session; an
      action is never replayed from a URL.
- [x] A withdrawal instruction closes the notification by tag instead of raising
      one; an expired escalation is dropped in both contexts.

### G3 — Open-tab behavior

- [x] Visible tab showing the exact session: the worker forwards the wake-up and
      the display policy suppresses the banner (`suppressedOnScreen`).
- [x] Visible tab showing another session: the worker forwards the wake-up and
      the page raises the browser notification, with no push involvement in the
      decision.
- [x] Dedupe by canonical `event_id` across socket and push, proven in
      `notification_push_wakeup_dedupe_test.dart`.

### G4 — iOS install path

- [x] Uninstalled iOS Safari is detected (`iPad|iPhone|iPod`, plus the iPadOS
      desktop user agent with touch points) and reports `installRequired`;
      Settings explains the Add to Home Screen requirement and offers no
      permission button.
- [!] Delivery and click-through in an installed iOS web app were not executed:
      no iOS device, no browser, and no HTTPS origin with a relay on this host.

### G5 — Verification

- [x] Unit tests for the lifecycle, availability states, rotation, revocation,
      and the display/dedupe matrix.
- [!] Browser matrix not executed: no browser is installed on this host.
      Chrome desktop, Firefox desktop, Safari macOS, and an installed iOS web app
      remain to be exercised on a machine with those browsers.
- [!] Closed-tab delivery proof not executed: it needs a real relay that can
      deliver a push to a real endpoint. The worker code path is covered by the
      source contract test, not by delivery.

## Acceptance Criteria

- [!] Given the tab is closed and a question is raised, when the relay
      dispatches, then a browser notification shows the redacted ask. —
      implemented in `sw.js`; needs a live push to prove.
- [x] Given the tab is open on another session, when the event arrives over the
      socket, then a browser notification appears with no push involvement. —
      proven at the pipeline boundary.
- [x] Given the tab is open on the exact session, when the event arrives, then no
      browser notification appears. — proven at the pipeline boundary.
- [x] Given the same event arrives by socket and by push, when both are handled,
      then exactly one notification is visible. — proven at the pipeline boundary
      and by one shared collapse tag in the worker.
- [x] Given an iOS user without an installed app, when they open notification
      settings, then they are told why it cannot work yet. — widget test.

## Verification performed

| Command | Result |
| :--- | :--- |
| `fvm flutter analyze` (in `client/`) | No issues found. |
| `fvm flutter build web --release --dart-define-from-file=config/prod.json` | Passed; `build/web/sw.js` and the authored `build/web/flutter_bootstrap.js` are emitted, and the bootstrap contains exactly one service-worker registration for `sw.js`. |
| `fvm flutter test test/unit/notifications test/widget/notifications test/tool/web_push_pwa_contract_test.dart` | All passed (61 tests). |
| `fvm flutter test test/guards/file_size_ratchet_guard_test.dart test/guards/locale_stable_widget_keys_guard_test.dart test/tool/app_web_startup_contract_test.dart test/tool/settings_navigation_contract_test.dart` | All passed. |

## Limitations (implemented, not executed here)

1. No browser on the build host, so no live permission prompt, push delivery,
   click, rotation, or background behavior was observed. The worker and the
   lifecycle are covered by source and unit tests only.
2. No hosted relay deployment serves
   `/api/notifications/web-push/subscriptions` yet (174e owns it). The Client
   reports `unavailable` and keeps the browser permission when the route is
   absent.
3. The relay must preserve the Agent envelope's `event_id` when it delivers a
   push. Socket/push dedupe depends on it, and the hosted side has not been
   exercised here.
4. iOS delivery needs an installed home-screen app on a real device; the
   detection and the copy are implemented and tested, the delivery is not.
5. Offline cold start is still unsupported, unchanged from Flutter 3.47's
   self-unregistering worker. If it becomes a requirement, it needs its own
   versioned app-shell cache task.

## Definition of Done

- [x] `fvm flutter analyze` passes in `client/`.
- [x] Focused tests pass, and the browser evidence is recorded in this file
      (branches unexecuted here are marked `[!]` with the reason).
- [x] The chosen service worker strategy is documented, including its effect on
      offline caching.
- [x] Strings are localized; no literal UI text in Dart source.
- [!] Graph index not refreshed: the Graphify CLI is not installed and no
      `graphify-out/` index exists in this checkout or its primary worktree, so
      there was nothing to update. Re-run `graphify update .` where the index is
      present.
