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
  for a desktop Client; the event arrives over the existing local or cloud socket
  and the Client presents it.
- Mobile delivery is a wake-up only. The hosted relay resolves a target to device
  tokens; the Client owns the token lifecycle and the foreground decision. No
  provider credential, provider SDK, or provider configuration is part of the
  public dependency graph, and the token never reaches the Agent, a log line, or
  workspace state.
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

## Mobile Delivery Ownership
- `MobilePushMessage` rebuilds the canonical envelope from the provider payload so
  `NotificationPayload.fromEvent` remains the only parser on every transport; a
  second parser is a drift risk and is not allowed.
- `MobilePushTransport` is the only push platform boundary. It carries messages,
  interactions, and the device token, and it decides nothing. A build with no
  provider resolves a total no-op.
- `MobilePushTokenRegistrar` owns the token lifecycle: register after
  authentication, refresh on rotation, re-register on reconnect, and withdraw on
  logout, session revocation, and account deletion. A withdrawal is durable: it
  is recorded before it is sent and flushed on the next authenticated connection
  ahead of any registration, because the account lifecycle tears the cloud socket
  down before this pipeline sees the logout. The record is the only persisted form
  of the token, it is bounded, and it is deleted once the relay accepts the
  withdrawal; diagnostics use the fingerprint alone.
- `MobileNotificationCatalog` owns the channel and category inventory. Every
  channel is created high importance before any delivery, one per kind, and a
  payload hint is honoured only when it matches the identity the Client owns.
- `MobileForegroundPolicy` is the only foreground rule, and it reuses
  `NotificationPresence.showsAsk` rather than re-deriving presence. The exact
  visible session is in-app only; any other session is a heads-up banner.
- `MobilePushService` adds sequencing only: an arrival goes through the existing
  display pipeline (so preferences, permission, collapse, quiet window, and
  `event_id` dedupe against the socket copy apply unchanged), and an interaction
  goes through the existing action router. A terminated Client renders from the
  payload alone and answers nothing until the replayed ask state arrives.

## Presentation and Platform
- `NotificationPlatformAdapter` is the only platform boundary. The native
  implementation is the only library that imports `flutter_local_notifications`;
  a web target resolves a browser adapter and a push client through the same
  conditional import, and mobile composes the same adapter behind its own push
  transport.
- Android channel importance is fixed at creation, so the adapter creates every
  channel at high importance at initialization and never recreates one lower.
- iOS fixes a notification's buttons in the registered category, so the categories
  are registered at initialization with the payload contract's action set.
- The iOS foreground hook is a notification-center delegate that answers per
  event from the mirrored visible session and preserves the previously installed
  chain. A globally silent foreground is rejected.
- A permission read is ordered after platform initialization, and the first one
  is published before any event is consumed. Every adapter builds the objects it
  answers a read with inside `initialize`, so `NotificationService.start()`
  awaits an `onPlatformReady` hook between initialization and stream subscription;
  the bridge supplies it, completes `NotificationPlatformReadiness` there, and
  loads Settings from it. `NotificationPlatformReadiness` is also what a read that
  arrives first waits on, so a page opened earlier still cannot observe a
  capability the platform has not built yet. Without that ordering the cold-start
  read throws, is reported as `unavailable`, and the display policy refuses every
  Agent-raised notification until something else refreshed the permission — the
  Settings page being the surface that did.
- Permission is requested only from an explicit Settings action. Nothing asks on
  startup, on first event, or on first notification. A refusal or a revocation is
  reported as it is; nothing rewrites the in-app switch on the user's behalf.
- Web owns one root-scope service worker (`client/web/sw.js`), registered from
  `client/web/flutter_bootstrap.js`; the Flutter-generated worker is a
  self-unregistering tombstone and is never registered. The worker presents both
  page-decided and push-decided notifications, so one collapse tag and one click
  path exist.
- The web worker resolves the session and request from every shape the product
  sends — the family `device_event` envelope, the documented transport body, and a
  bare instruction block — in the same precedence as `NotificationPayload.fromEvent`.
  A shape the page accepts is never silently dropped by the closed-tab path.
- `WebPushSubscriptionService` is the only owner of the browser permission and
  subscription lifecycle. Permission is requested only from the explicit Settings
  action, a subscription is registered to the authenticated account, and logout
  revokes it with the token captured while the session was valid. Its reported
  state is the relay acknowledgement, never the browser subscription alone: only
  the relay can reach an endpoint, so an unacknowledged registration is a failure
  with a retry, and the persisted record is the acknowledgement that clears it.
- Browser approval buttons are not offered: browser action limits cannot carry a
  three-way approval set without hiding a decision. A click opens the exact
  session, and a decision is answered only through the in-app prompt and
  `tool_permission_response`.
- `NotificationBridge` and `NotificationPresenceReporter` are composition only:
  they supply dependencies and report what is on screen. They contain no display
  rule.
- Window visibility has one deterministic owner: `DesktopLifecycleManager`
  publishes every hide and show it performs, and
  `NotificationWindowPresenceReporter` projects that record into presence. An OS
  lifecycle transition is corroboration only; `resumed` never overrides a
  deterministic hide, and a target without the manager falls back to the
  lifecycle state. Presence never infers visibility from window state kept
  anywhere else.
- The presented approval actions never exceed what the payload offered. macOS
  fixes button copy and the button set when a category is registered at startup,
  so `DarwinActionCategories` derives one category per offered subset and the
  adapter selects the one that matches the request; an unmatched set is presented
  without buttons. Button copy comes from the localized labels the adapter
  receives with `initialize`; the English fallback applies only to an empty map,
  and a raw intent name is never user-facing copy.
- The one button whose copy follows a language change inside a running session is
  the freedesktop open action. Linux builds its action array per notification, so
  `NotificationPresentationRequest.openActionLabel` carries the label resolved
  for the language in use; an absent label keeps the copy `initialize`
  registered. A Darwin category cannot be corrected after registration and keeps
  the language it was registered in until the next launch.
- A cold-start interaction is not resumed. `NotificationService` reads the
  launch interaction once, records it as `NotificationColdStartOutcome`, and acts
  on nothing: no approval is sent from a payload alone and no destination is
  opened without replayed state. The ask stays answerable in the app after the
  reconnect replay.
- An approval is answered through the existing `tool_permission_response`
  command, with the request the Client already holds. A response mutates no
  Client state; the in-app prompt clears from the Agent's resolved event.

## Per-Device Preferences
- Every notification choice belongs to **this device**, never to the account. The
  platform preferences file is the storage owner
  (`NotificationPreferencesStore`), the choice is never uploaded, and another
  device never writes it.
- Two levels and one ceiling: the global switch, a per-kind off switch, and a
  per-kind urgency ceiling. Every kind starts enabled at the product default
  (banner and sound); a stored value only records a deliberate change, and
  `withKindUrgency` never stores a value that would raise a kind, so a corrupt
  file or a future build cannot make one louder.
- The ceiling has one name everywhere it is shown. The Settings control states
  the value it will apply (`Alert` / `Banner only`), the menu states the delivery
  that value means (`Banner and sound` / `Banner without sound`) beside it, and
  the row subtitle reports an off kind, a missing service, or a revoked OS
  permission instead of an alert style the pipeline would refuse.
- A kind is off **or** quietened, never both on the wire. The two choices are
  stored separately so unmuting restores the ceiling, but
  `toAgentDeclaration` emits exactly one token per kind and `off` wins in either
  order; `ceilingFor` answers the product default for a muted kind, so neither
  the page nor the declaration can describe a style for a kind that delivers
  nothing. The Agent reads the same rule
  ([communication_protocols.md](../../../../docs/technical/communication_protocols.md)
  §7.10).
- The ceiling is applied at presentation — `NotificationService` asks the
  preferences for `urgencyFor(kind, agentUrgency)` — because every route, local
  socket, cloud socket, and future push, converges on that one call.
- A change is announced to the Agent through the Client's authenticated
  registration envelope (`client.hello` locally, the client identity the hosted
  service relays for a cloud connection). The declaration names this device's
  choice only; the relay forwards it and reads nothing. The Agent-side registry
  and its dispatch application are owned by
  [communication_protocols.md](../../../../docs/technical/communication_protocols.md)
  §7.10.
- Settings never derives a preference from conversation content, presence, or an
  OS permission read, and it never presents an account-wide switch.

## Test Notification
- `NotificationService.raiseTestNotification` is the only event this feature
  fabricates, and it exists only because a user cannot otherwise tell a working
  setup from a silent one. It is a user action, never a producer decision.
- It runs the real pipeline: the same envelope parser, the same collapse
  identity, the same display policy, and the same adapter. It therefore honours
  the global switch, the kind, the ceiling, and the OS permission.
- It is not an arrival, so it ignores the transport-owned suppressions: no
  deduplication, no post-connect quiet window, and no presence suppression.
- Its copy is supplied by `NotificationCopySource.testNotificationCopy` and names
  it as a test, so a probe can never be read as an Agent decision. It is never
  published to the relay.
- It borrows `NotificationService.testNotificationKind` and therefore inherits
  that kind's alert style, so Settings names the borrowed kind beside the action.
  A quietened kind must never read as a test that forgot the setting.
- A suppressed result is reported as a localized explanation, never as success.
  A presentation the platform refused is its own outcome
  (`NotificationDisplayOutcome.presentationFailed`): the probe reports a
  localized failure instead of claiming it was shown, and the same outcome is
  returned for an arrival whose platform call failed.
- The action is unavailable until the running pipeline attaches its sender
  (`NotificationSettingsState.canSendTest`), because Settings cannot raise a
  notification itself and a probe without the pipeline could only report a
  failure it did not cause.

## Verification
- Unit tests own the display matrix, collapse keys, dedupe identity, the quiet
  window, payload parsing and the payload-only mobile rebuild, the ask registry,
  the action fail-closed rules, the macOS action-set derivation and registration,
  the action-label fallback, the cold-start outcome, the preference ceiling and
  its stored form, the per-device declaration (including the off-wins precedence
  in either order) and its registration envelope, the test-action outcome mapping
  including a refused platform call, the mobile foreground matrix, the token
  lifecycle, the channel and category inventory, and the web subscription
  lifecycle.
- Widget tests own the end-to-end pipeline through a fake platform adapter, the
  Settings surface (permission states, per-kind urgency and the value its control
  states, the menu vocabulary and its alignment, the row copy that states an OS
  block instead of a delivery style, the test action, the kind it follows, and its
  failure, the stated limits), the window-presence projection driven by a
  `DesktopLifecycleManager`, the browser install/configuration states, and Arabic
  right-to-left rendering.
- Unit tests own the cold-start ordering itself: a platform whose permission read
  depends on `initialize` still delivers an Agent-raised notification, and a
  language change reaches the open action label without a restart.
- `client/test/guards/notifications_localization_guard_test.dart` owns the
  localization invariant: no hard-coded widget string, no Arabic literal in Dart,
  and every referenced key authored in both locales.
- Real macOS, Windows, Linux, Android, and iOS behavior is verified by a live pass
  on that platform, not by mocks. A platform that has not been exercised is
  recorded as a limitation in its task file: desktop cases in
  `docs/plans/tasks/174b-desktop-os-notifications.md`, mobile device cases in
  `docs/plans/tasks/174c-mobile-push-delivery.md`, and the `174f` preference and
  localization surface records its own per-platform evidence in
  `docs/plans/tasks/174f-notification-preferences-and-verification.md`.
- The web worker, live browser delivery, and the installed iOS path are recorded
  as unexecuted in `docs/plans/tasks/174d-web-push-and-pwa.md`; `fvm flutter build
  web` and the source contract in `client/test/tool/web_push_pwa_contract_test.dart`
  are the executable evidence on a host without a browser. The worker itself is
  executed there too, through `client/test/web/sw_closed_tab_notification_test.mjs`
  and `client/test/tool/web_push_worker_execution_test.dart`, which run every
  payload shape with no visible client and assert one notification plus the exact
  click-through URL.
