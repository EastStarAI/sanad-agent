# 174c — Mobile push delivery

**Status:** not started — G0 open
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

## Gates

### G0 — Platform discovery

- [ ] Confirm the FCM and APNs prerequisites for both platforms, including the
      APNs key ownership, the iOS capability set, and the entitlements the app
      already carries.
- [ ] Verify how the current iOS AppDelegate interacts with the messaging plugin
      delegate, and choose the smallest hook that allows per-event foreground
      suppression.
- [ ] Confirm Android 13 runtime permission handling and the existing channel
      inventory.
- [ ] Confirm the mobile Client's lifecycle behavior: sockets die in the
      background and reconnect on resume.

### G1 — Token registration

- [ ] Register the device token after authentication, and refresh it on rotation.
- [ ] Invalidate the token on logout, session revocation, and account deletion.
- [ ] Keep the token out of logs, out of the Agent, and out of workspace state.

### G2 — Foreground display policy

- [ ] Define channels and categories so that every kind is high importance.
- [ ] Implement the rule: exact session visible means no banner; another session
      means a heads-up notification with the Agent-provided copy and actions.
- [ ] Keep the in-app attention state authoritative and unchanged by push.

### G3 — Background and terminated display

- [ ] Prove a notification arrives and displays when the app is backgrounded.
- [ ] Prove it arrives when the app is terminated, with content rendered from
      the payload alone.
- [ ] Prove a late escalation for an already resolved ask is dropped.

### G4 — Actions and navigation

- [ ] Approve, deny, and open from the notification.
- [ ] Deep-link into the exact session and request on open.
- [ ] Fail closed when the request is already resolved or no longer exists.

### G5 — Verification

- [ ] Unit tests for the foreground decision matrix and dedupe with socket
      delivery.
- [ ] Widget tests for the in-app notification permission flow and Settings.
- [ ] Real-device verification on Android and iOS for background, terminated,
      action, and deep-link cases.

## Acceptance Criteria

- [ ] Given the app is terminated and a permission request is raised, when the
      relay dispatches, then a banner with sound shows the redacted ask.
- [ ] Given the app is in the foreground reading the same session, when the push
      arrives, then no banner appears and the in-app prompt updates.
- [ ] Given the app is in the foreground reading another session, when the push
      arrives, then a heads-up notification appears.
- [ ] Given the user approves from the notification, when the Agent accepts, then
      the run resumes and the in-app prompt clears from the resolved event.
- [ ] Given the same event arrives by socket and by push, when both are handled,
      then exactly one notification is visible.
- [ ] Given the user logged out, when the relay dispatches afterwards, then no
      delivery occurs for the revoked token.

## Definition of Done

- [ ] `fvm flutter analyze` passes in `client/`.
- [ ] Focused tests pass, and the real-device evidence is recorded in this file.
- [ ] `docs/technical/communication_protocols.md` and the notification section of
      the Client documentation describe the mobile behavior.
- [ ] All new strings are localized; no Arabic literal exists in Dart source.
- [ ] Graph index refreshed with `graphify update .`.
