---
title: "Client Notifications and Push Delivery"
description: "Agent-owned notification decisions, local OS delivery on desktop, mobile push, and web push, all through a content-opaque hosted relay."
status: active
current_gate: "174b implementation (174a implemented)"
remaining_estimate: "174b–174f unstarted"
---

# Plan 174 — Client Notifications and Push Delivery

## Goal

A Sanad user learns that a session needs them while they are away from it, with
enough context to act without opening the app first, on whichever Sanad Client
they can actually reach — while every decision about that notification stays in
the Agent and the hosted relay remains a transport that reads nothing.

## Locked decisions

1. **The Agent owns every notification decision.** Which event notifies, its
   kind, its urgency, its copy, its redaction, its target Client, the escalation
   timer, and the cancellation. The relay transports; it does not decide.
2. **The relay is content-opaque.** It receives a payload the Agent has already
   redacted plus one target instruction, and it performs token resolution and
   provider delivery. It never parses, classifies, stores, or routes on content.
3. **Redaction happens in the Agent before the payload leaves the device.** No
   "hide details" transformation is performed by the relay.
4. **Delivery begins at the Client instance that originated the turn.** If the
   ask is unresolved after 90 seconds, the Agent fans out to every push-capable
   device of the account. Escalation is cancelled by resolution or a terminal
   session state, never by the mere act of displaying the ask.
5. **A Client that is showing the session only silences its own banner.** It
   never suppresses escalation to the user's other devices, because an open
   window is not evidence that a human is in front of it.
6. **Immediate fan-out replaces the timer** when the originating target is
   unreachable (no local membership and not in the cloud recipient set), or when
   the turn originated from a surface that cannot be notified at all, such as the
   standalone CLI or a scheduled run.
7. **Every notification kind is high urgency by default**: banner and sound. No
   kind ships silent. Users may lower an individual kind; the product default
   does not.
8. **Content is rich, not anonymous.** The title carries the session title and
   the body carries the ask, both redacted. A generic "you have a notification"
   is rejected.
9. **Desktop never uses a push provider.** Both the local and the cloud route
   deliver the event to a running Client, which raises the OS notification
   itself.
10. **Push credentials and the device token inventory stay in the hosted
    service.** The Agent names a target by Client instance identity; the relay
    resolves that identity to tokens.
11. **A local-only Agent cannot reach a remote device.** Cross-device
    notification is a hosted capability; the limitation is documented rather
    than worked around.
12. **Dedupe is by canonical `event_id`** across the local socket, the cloud
    socket, and push, so one ask produces one visible notification per device.
13. **The Agent renders notification copy.** The Client registers its locale
    with the Agent, and the Agent keeps a small template table covering the
    notification kinds and action labels only. Session titles are never
    translated.
14. **Client-originated notifications exist** for conditions only the Client can
    observe, such as a lost Agent connection or an expired authentication. They
    are raised locally and never traverse the relay.

## Notification model

Kinds owned by the Agent:

- `permission_request` — the run is blocked on an execution decision.
- `user_question` — the run is blocked on an answer.
- `blocked` — the session cannot proceed without human intervention.
- `failed` — the run ended in a final failure.
- `completed` — the requested result exists.
- `background_task_done` — a background task or terminal command finished.
- `scheduled_result` — a scheduled run produced a result.
- `provider_quota` — the selected provider is exhausted or rate-limited.

Client-owned kinds, raised locally:

- `connection_lost` — the Agent became unreachable.
- `auth_required` — the account session needs re-authentication.

Urgency is an attribute of a kind, not a second taxonomy. Defaults are `high`
for every Agent kind; `connection_lost` and `auth_required` default to `high` as
well, and the user lowers what they do not want.

## Delivery policy

1. Resolve the origin Client instance from the delivery envelope already carried
   by `device_event`.
2. If the origin is missing, not push-capable, or not currently attached by any
   route, dispatch to the account immediately.
3. Otherwise dispatch to the origin and arm one timer keyed by
   `session_id + request_id`.
4. On resolution or a terminal session state, cancel the timer and withdraw the
   notification from every device that received it.
5. On expiry, dispatch to every push-capable device of the account, including
   the origin.
6. Never arm more than one timer per ask, and never re-notify after resolution.

## Wire contract between Agent and relay

The Agent sends one dispatch instruction per step of the policy. It carries:

- canonical `event_id` and `request_id`;
- `target`: one Client instance identity, or the whole account;
- `kind` and `urgency`;
- already-redacted `title`, `body`, and localized action labels;
- `deep_link` fields: `session_id`, `request_id`;
- `collapse_key` derived from `session_id + kind`;
- `expires_at`, so a late escalation never wakes a device for a resolved ask;
- platform hints the Agent already decided, such as the Android channel, the iOS
  category, and the thread identifier.

It carries no conversation transcript, no command text, no credential, and no
field the relay is expected to interpret.

## Task map

- `174a` — Agent notification contract, policy, copy, and redaction.
- `174b` — Desktop OS notifications on macOS, Windows, and Linux.
- `174c` — Mobile push delivery and foreground display policy.
- `174d` — Web push and installable PWA delivery.
- `174e` — Hosted delivery boundary. Owned and tracked by the hosted service;
  this plan obliges it only through the wire contract above.
- `174f` — Preferences, localization, and multi-platform verification.

Ordering: `174a` first because it freezes the payload, then `174b` in parallel
with `174e`, then `174c` and `174d` once the relay boundary exists, then `174f`.

## Out of scope

- External chat channels, email, SMS, and webhooks.
- iOS critical alerts and any entitlement that requires special Apple approval.
- Windows MSIX packaging; the current NSIS installer is retained.
- Rich media, images, and inline reply in notifications.
- Per-device quiet hours and digest batching, which may be designed later.
- Any relay-side interpretation of notification content.

## Risks

- Android channel importance is fixed at creation and can be lowered by the
  user; a single high channel invites app-wide muting.
- iOS Focus and Notification Summary can silence notifications unless the
  Time Sensitive capability is present, and the user can still disable it.
- Origin reachability drives the immediate fan-out rule, so a stale presence
  signal can delay the first notification to the wrong device.
- Notification copy lives in two codebases; without a parity test the Agent and
  the Client will drift.
- Without package identity, a Windows toast cannot be cancelled programmatically.
- Flutter generates its own web service worker, which must be reconciled with the
  push worker before web delivery can work in the background.

## Status

Planning complete. The plan is accepted.

- `174a` (Agent notification contract, policy, copy, and redaction) is
  implemented on `task/174a-agent-contract`: the Agent owns the kinds, the
  localized copy, the origin-first policy with the 90-second escalation, the
  redacted payload, and the withdrawal, and
  [docs/technical/communication_protocols.md](../technical/communication_protocols.md)
  §7 is the wire contract.
- `174b` (Desktop OS notifications on macOS, Windows, and Linux) is
  implemented on the desktop foundation: `NotificationService`,
  `NotificationDisplayPolicy`, collapse identity, dedupe, the quiet window, the
  action router, and Settings.
- `174d` (Web push and installable PWA) is implemented on `task/174d-web-push`:
  the web Client owns `client/web/sw.js` and registers it through an authored
  `client/web/flutter_bootstrap.js`, runs the browser permission and
  account-bound subscription lifecycle from the explicit Settings action,
  revokes on logout, and treats push as a wake-up so a visible tab stays
  authoritative. Live browser and installed-iOS evidence is still unexecuted.
- `174b`–`174f` are authored; `174c`, `174e`, and `174f` remain unstarted.
