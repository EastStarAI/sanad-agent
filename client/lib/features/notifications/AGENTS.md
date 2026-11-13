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
  in this feature; the event arrives over the existing local or cloud socket and
  the Client presents it.

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
  Web resolves a total no-op through a conditional import, and mobile keeps the
  boundary free for its own push adapter.
- Permission is requested only from an explicit Settings action. Nothing asks on
  startup, on first event, or on first notification. A refusal or a revocation is
  reported as it is; nothing rewrites the in-app switch on the user's behalf.

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
- A suppressed result is reported as a localized explanation, never as success.
  A presentation the platform refused is its own outcome
  (`NotificationDisplayOutcome.presentationFailed`): the probe reports a
  localized failure instead of claiming it was shown, and the same outcome is
  returned for an arrival whose platform call failed.
- The action is unavailable until the running pipeline attaches its sender
  (`NotificationSettingsState.canSendTest`), because Settings cannot raise a
  notification itself and a probe without the pipeline could only report a
  failure it did not cause.

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
- A cold-start interaction is not resumed. `NotificationService` reads the
  launch interaction once, records it as `NotificationColdStartOutcome`, and acts
  on nothing: no approval is sent from a payload alone and no destination is
  opened without replayed state. The ask stays answerable in the app after the
  reconnect replay.
- An approval is answered through the existing `tool_permission_response`
  command, with the request the Client already holds. A response mutates no
  Client state; the in-app prompt clears from the Agent's resolved event.

## Verification
- Unit tests own the display matrix, collapse keys, dedupe identity, the quiet
  window, payload parsing, the ask registry, the action fail-closed rules, the
  macOS action-set derivation and registration, the action-label fallback, the
  cold-start outcome, the preference ceiling and its stored form, the
  per-device declaration (including the off-wins precedence in either order) and
  its registration envelope, and the test-action outcome mapping including a
  refused platform call.
- Widget tests own the end-to-end pipeline through a fake platform adapter, the
  Settings surface (permission states, per-kind urgency, the row copy that states
  an OS block instead of a delivery style, the test action and its failure, the
  stated limits), Arabic right-to-left rendering, and the window-presence
  projection driven by a `DesktopLifecycleManager`.
- `client/test/guards/notifications_localization_guard_test.dart` owns the
  localization invariant: no hard-coded widget string, no Arabic literal in Dart,
  and every referenced key authored in both locales.
- Real macOS, Windows, and Linux behavior is verified by a live desktop pass, not
  by mocks. A platform that has not been exercised is recorded as a limitation in
  `docs/plans/tasks/174b-desktop-os-notifications.md`, and the `174f` preference
  and localization surface records its own per-platform evidence in
  `docs/plans/tasks/174f-notification-preferences-and-verification.md`.
