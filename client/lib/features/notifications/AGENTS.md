# Notifications Feature Contract

## Scope
This contract applies to `client/lib/features/notifications/`.

## Authority
- The Agent owns every Agent-notification decision: whether an event notifies, its
  kind, its urgency, its copy, its redaction, its collapse identity, its expiry,
  and its target. This feature projects that decision and never derives one from
  conversation content, session state, or a run outcome.
- The Client raises only the two kinds it can observe itself (`connection_lost`
  and `auth_required`). They are modelled here and are raised by a later task;
  nothing in this feature fabricates an Agent kind.
- Desktop delivery is local. No push provider, no token, and no relay call exists
  on desktop: the event arrives over the existing local or cloud socket and the
  Client presents it.
- Web delivery adds a browser wake-up, never a decision. A visible tab receives
  the envelope and decides with the same display policy; with no visible tab the
  owned worker renders the Agent's already-redacted copy from the payload alone.

## Pipeline Ownership
- `NotificationPayload.fromEvent` is the only parser of the Agent payload, and it
  is tolerant by design: an unknown field is ignored, an unknown kind or a
  missing session identity rejects the whole notification.
- `NotificationDisplayPolicy.decide` is the only place that answers "does this
  reach the operating system?". Its inputs are injected, so the matrix is proven
  by tests rather than by a socket, a window, or a platform.
- `NotificationService` owns the single path both transports feed. It dedupes by
  canonical `event_id` through a private `EventDeduplicator` called without a
  payload fingerprint: the transport-shared instance keys on `event_id` plus a
  payload hash and therefore cannot prove that two route copies are one
  notification.
- `NotificationCollapseKey` owns replacement identity: `session_id + kind`
  derives one OS notification id, and an Agent-supplied key is accepted only when
  it matches that derivation.
- `NotificationQuietWindow` suppresses the OS notification after every socket
  connect. It never suppresses in-app state: the conversation path does not
  consult it.
- `NotificationAskRegistry` is the Client's bounded record of pending asks, so an
  approval from a notification can fail closed without a mounted conversation
  surface.

## Presentation and Platform
- `NotificationPlatformAdapter` is the only platform boundary. The native
  implementation is the only library that imports `flutter_local_notifications`;
  a web target resolves a browser adapter and a push client through the same
  conditional import, and mobile keeps the boundary free for its own push
  adapter.
- Web owns one root-scope service worker (`client/web/sw.js`), registered from
  `client/web/flutter_bootstrap.js`; the Flutter-generated worker is a
  self-unregistering tombstone and is never registered. The worker presents both
  page-decided and push-decided notifications, so one collapse tag and one click
  path exist.
- `WebPushSubscriptionService` is the only owner of the browser permission and
  subscription lifecycle. Permission is requested only from the explicit Settings
  action, a subscription is registered to the authenticated account, and logout
  revokes it with the token captured while the session was valid.
- Browser approval buttons are not offered: browser action limits cannot carry a
  three-way approval set without hiding a decision. A click opens the exact
  session, and a decision is answered only through the in-app prompt and
  `tool_permission_response`.
- `NotificationBridge` and `NotificationPresenceReporter` are composition only:
  they supply dependencies and report what is on screen. They contain no display
  rule.
- An approval is answered through the existing `tool_permission_response`
  command, with the request the Client already holds. A response mutates no
  Client state; the in-app prompt clears from the Agent's resolved event.

## Verification
- Unit tests own the display matrix, collapse keys, dedupe identity, the quiet
  window, payload parsing, the ask registry, the action fail-closed rules, and the
  web subscription lifecycle.
- Widget tests own the end-to-end pipeline through a fake platform adapter, the
  Settings surface, and the browser install/configuration states.
- Real macOS, Windows, and Linux behavior is verified by a live desktop pass, not
  by mocks. A platform that has not been exercised is recorded as a limitation in
  `docs/plans/tasks/174b-desktop-os-notifications.md`.
- The web worker, live browser delivery, and the installed iOS path are recorded
  as unexecuted in `docs/plans/tasks/174d-web-push-and-pwa.md`; `fvm flutter build
  web` and the source contract in `client/test/tool/web_push_pwa_contract_test.dart`
  are the executable evidence on a host without a browser.
