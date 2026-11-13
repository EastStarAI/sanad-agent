---
title: "Mobile Push Delivery"
description: "Android and iOS wake-up delivery for Sanad notifications: device token lifecycle, channel and category inventory, the foreground rule, background and terminated rendering, and action handling."
---

# Mobile Push Delivery

## Purpose

A push is a wake-up, never a decision. The Agent decides that a notification
exists, its kind, urgency, copy, redaction, target, and expiry; the hosted relay
resolves a target to device tokens and delivers; the Client decides what the user
sees on the device that received it. This page owns the Client half on Android
and iOS: token registration, the channel and category inventory, the foreground
rule, background and terminated rendering, and how an action resolves an ask.

Desktop delivery is unchanged and stays local; see
[Desktop Background Lifecycle, System Tray, and OS Notifications](desktop_background_and_system_tray.md).
The wire contract is §7 of
[Communication Protocols](communication_protocols.md#7-agent-owned-notification-dispatch-plan-174).

## Boundaries

| Layer | Owns | Never does |
|---|---|---|
| Agent | Kind, urgency, copy, redaction, collapse key, expiry, target, escalation | Reads a device token, calls a provider, or stores provider credentials |
| Hosted relay | Resolves a target to tokens, performs provider delivery, stores the token inventory | Parses, classifies, stores, or rewrites notification content |
| Client | Device token registration, channel and category inventory, foreground decision, payload parsing, action routing | Invents a notification, derives a decision from a payload alone, or holds a provider credential |

The public dependency graph carries no push provider SDK and no provider
configuration. The platform provider module is supplied by the platform owner,
which is what keeps credentials and build configuration out of the repository.

## Device token lifecycle

A device token is a bearer capability for one installation, so its lifecycle is
tied to the account session rather than to the app process:

1. **Register after authentication.** The Client asks the platform for its token
   and announces it on the authenticated Cloud Socket with `push.register_token`
   (`version`, `provider`, `token`). The Gateway derives the account from the
   authenticated socket; no user identity travels in the payload.
2. **Refresh on rotation.** A provider may replace a token at any time. A rotation
   is announced immediately, because the previous token stops delivering.
3. **Re-register on reconnect.** Every return to a ready authenticated socket
   announces the token again; the relay may have dropped the binding while the
   device was away.
4. **Revoke when the session ends.** Logout, a terminal Gateway `auth_revoked`,
   and account deletion (which performs the same logout) all send
   `push.revoke_token`. A device that signed out stops being a delivery target.

The token is held in memory only. It is never written to preferences, a
workspace file, a conversation record, or an Agent payload, and it is never
logged: the only form that may appear in a log line or diagnostic is a short
SHA-256 fingerprint, which exists for change detection rather than recovery.

## Channels and categories

Android fixes a channel's importance when the channel is created and never raises
it afterwards, so a channel created implicitly by a delivery would adopt that
delivery's importance. The Client therefore creates every channel it owns at
startup, before any delivery can arrive, all at high importance:

| Surface | Identity | Fixed at |
|---|---|---|
| Android channel | `sanad_<kind>_high` | First app start after install |
| iOS category | `SANAD_<KIND>` | Notification plugin initialization |

One channel per kind rather than one app-wide channel is deliberate: a user who
mutes one kind must not mute the rest. A payload `platform_hints` value is
honoured only when it matches the identity the Client owns for that kind, exactly
like a disagreeing collapse key, so a producer change can never create a silent
channel or an unknown category.

The approval actions are registered with the category, not with the individual
notification, because iOS needs the button set before a notification arrives,
including one that arrives while the app is terminated.

Importance is a product default, not a guarantee. The system settings win: a user
who lowers a channel, enables Do Not Disturb, or silences Focus is never
overridden, and the Client does not attempt to detect or bypass those states.

## The foreground rule

While the app is running, the Client decides; the payload never decides for it.

| Situation | Outcome |
|---|---|
| The exact visible session is on screen | In-app only: no banner, no sound; the in-app prompt is the surface |
| Any other session, or no session, is on screen | Heads-up notification with the Agent copy, the Agent actions, and sound |
| The app is backgrounded or terminated | The operating system presents the notification it was handed |

The decision reuses the shared presence rule (`NotificationPresence.showsAsk`)
instead of re-deriving it, so mobile and desktop can never disagree about the
same session. A session on screen with a *different* ask projected still raises a
banner, because the ask in the notification is not the one in front of the user.

iOS asks the question before Dart can be involved, so the smallest possible hook
answers it: a
`UNUserNotificationCenterDelegate` installed at engine initialization that
compares the arriving notification's session with the session the Client last
mirrored to it. A matching session returns no presentation options; every other
remote notification returns banner, sound, and list. The delegate preserves the
previously installed chain, so local notifications keep the behavior they had.
A globally silent foreground is rejected: it would hide a notification for a
session the user is not looking at.

Android presents through the same local notification adapter the desktop path
uses, with the channel and category identity above. A foreground arrival that the
Client does not present is not shown at all, which is exactly the in-app-only
case.

## Background and terminated delivery

A terminated Client has no socket, no ask registry, and no replay. The
notification is rendered by the operating system from the provider payload alone:

- the provider payload carries the redacted title and body, the Android channel
  and iOS category, the thread identity, and the action set the category fixes;
- it also carries `sanad_envelope`, a compact canonical envelope, so a running
  Client parses the arrival with the same parser the socket path uses and never
  needs a second one;
- nothing in the payload is a transcript, tool output, workspace path, policy
  key, credential, or submitted secret value.

Opening the app from that notification reports one interaction: the session, the
request, the kind, and the action the user pressed. The Client waits briefly for
the replayed authoritative state, then routes the interaction through the
existing action path. If the replay does not arrive, the interaction is dropped
rather than answered from the payload alone.

## Actions

Every action resolves the ask through the existing `tool_permission_response`
command; no new authorization path exists for mobile.

- **Allow once**, **Allow for this session**, and **Deny** are offered only when
  the ask is still pending in this Client and the request identity matches.
- **Open** (the ordinary click) navigates to the session and request.
- A late escalation for an already resolved ask is dropped, as is any interaction
  whose ask is unknown, expired, or names a different request. Nothing is
  answered optimistically, and no Client state is mutated by the response: the
  in-app prompt clears from the Agent's resolved event.

## Platform prerequisites and ownership

| Item | Owner | State |
|---|---|---|
| iOS Push Notifications capability on the App ID | Release/platform | Required before a build with the `aps-environment` entitlement can be signed |
| `aps-environment` entitlement | Client source | Present in `client/ios/Runner/Runner.entitlements` |
| APNs signing key | Hosted service | Stays hosted; never in the Client |
| Android provider module (`firebase-messaging`) | Platform owner | Not in the public dependency graph; the bridge exposes the seam |
| FCM sender credentials | Hosted service | Stays hosted; never in the Client |

The Android bridge is dependency-free and always attached. It exposes the token,
the arrival, and the interaction channel, and a build without a provider module
answers "no token": the Client then reports that no device is registered instead
of pretending. The provider module calls `SanadPushBridge.onToken`,
`onDisplay`, and `onInteraction` from its own service and adds no Dart-side
surface. `onDisplay` is for an arrival while the process is alive and visible;
a background delivery is posted by the provider itself, so the Client never
presents the same notification twice.

## Verification status

Unit and widget coverage proves the foreground matrix, the token lifecycle,
payload-only parsing, channel and category derivation, and the fail-closed action
rules. Device behavior has not been executed on this host:

- `[!]` Android background and terminated display: no Android runtime here; owner
  is the platform/release pipeline, and it also needs the provider module.
- `[!]` Android action and deep link: same owner and blocker.
- `[!]` Android 13 runtime permission prompt: same owner and blocker.
- `[!]` iOS background and terminated display: no iOS runtime here; owner is the
  release pipeline, which must also enable the Push capability on the App ID.
- `[!]` iOS per-event foreground suppression: same owner and blocker.
- `[!]` iOS action and deep link: same owner and blocker.

The record for each case belongs to
[174c](../plans/tasks/174c-mobile-push-delivery.md), which names the case, the
reason it was not executed, and the platform owner.

## Limitations

- Cross-device notification is a hosted capability. A local-only Agent reaches
  only the Clients attached to its machine.
- No kind ships silent. A user lowers an individual kind in Settings or in the
  system settings; the product default is banner and sound.
- iOS Focus, Notification Summary, and per-app settings can silence a delivery.
  The Client documents what it cannot bypass instead of working around it.
- Rich media, inline reply, critical alerts, and digest batching are out of
  scope.
