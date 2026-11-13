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
  authentication, refresh on rotation, re-register on reconnect, and revoke on
  logout, session revocation, and account deletion. The token lives in memory only
  and is referenced in diagnostics by fingerprint alone.
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
  Web resolves a total no-op through a conditional import, and mobile composes the
  same adapter behind its own push transport.
- Android channel importance is fixed at creation, so the adapter creates every
  channel at high importance at initialization and never recreates one lower.
- iOS fixes a notification's buttons in the registered category, so the categories
  are registered at initialization with the payload contract's action set.
- The iOS foreground hook is a notification-center delegate that answers per
  event from the mirrored visible session and preserves the previously installed
  chain. A globally silent foreground is rejected.
- Permission is requested only from an explicit Settings action. Nothing asks on
  startup, on first event, or on first notification.
- `NotificationBridge` and `NotificationPresenceReporter` are composition only:
  they supply dependencies and report what is on screen. They contain no display
  rule.
- An approval is answered through the existing `tool_permission_response`
  command, with the request the Client already holds. A response mutates no
  Client state; the in-app prompt clears from the Agent's resolved event.

## Verification
- Unit tests own the display matrix, collapse keys, dedupe identity, the quiet
  window, payload parsing, the ask registry, the action fail-closed rules, the
  mobile foreground matrix, the token lifecycle, the channel and category
  inventory, and payload-only parsing.
- Widget tests own the end-to-end pipeline through a fake platform adapter and
  the Settings surface.
- Real macOS, Windows, Linux, Android, and iOS behavior is verified by a live pass
  on that platform, not by mocks. A platform that has not been exercised is
  recorded as a limitation in its task file; mobile device cases are recorded in
  `docs/plans/tasks/174c-mobile-push-delivery.md`.
