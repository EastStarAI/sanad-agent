# 174d — Web push and installable PWA

**Status:** not started — G0 open
**Owners:** `client/web`, new web notification module in `client/`, `client/lib/infrastructure/socket/event_deduplicator.dart`
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

## Gates

### G0 — Service worker and install discovery

- [ ] Decide the service worker strategy: disable the generated worker and own
      one, or keep the generated worker and register the push listener inside it,
      with the offline behavior each choice implies.
- [ ] Confirm the current build flags and whether the PWA manifest is served as
      `standalone` in every deployment profile.
- [ ] Confirm subscription behavior and endpoint lifetime in the supported
      browsers, including the iOS installed-app path.

### G1 — Subscription lifecycle

- [ ] Request permission only from an explicit user action.
- [ ] Create and register the push subscription with the relay, including the
      VAPID public key source.
- [ ] Refresh the subscription on rotation and revoke it on logout.

### G2 — Delivery while closed

- [ ] Handle a push with the tab closed and render the notification from the
      payload alone.
- [ ] Open the exact session and request on notification click.
- [ ] Drop a late escalation for an already resolved ask.

### G3 — Open-tab behavior

- [ ] When the tab is visible and showing that session, show nothing beyond the
      in-app prompt.
- [ ] When the tab is visible and showing another session, show the browser
      notification and flash tab attention.
- [ ] Deduplicate against socket delivery by canonical `event_id`.

### G4 — iOS install path

- [ ] Detect an uninstalled iOS Safari session and explain the install
      requirement in Settings rather than silently offering a permission that
      cannot work.
- [ ] Verify notification delivery and click-through in an installed web app.

### G5 — Verification

- [ ] Unit tests for the display matrix and dedupe.
- [ ] Browser matrix evidence recorded here: Chrome and Firefox on desktop, and
      an installed iOS web app.
- [ ] A closed-tab delivery test that proves the notification is not produced by
      the page.

## Acceptance Criteria

- [ ] Given the tab is closed and a question is raised, when the relay
      dispatches, then a browser notification shows the redacted ask.
- [ ] Given the tab is open on another session, when the event arrives over the
      socket, then a browser notification appears with no push involvement.
- [ ] Given the tab is open on the exact session, when the event arrives, then no
      browser notification appears.
- [ ] Given the same event arrives by socket and by push, when both are handled,
      then exactly one notification is visible.
- [ ] Given an iOS user without an installed app, when they open notification
      settings, then they are told why it cannot work yet.

## Definition of Done

- [ ] `fvm flutter analyze` passes in `client/`.
- [ ] Focused tests pass, and the browser evidence is recorded in this file.
- [ ] The chosen service worker strategy is documented, including its effect on
      offline caching.
- [ ] Strings are localized; no literal UI text in Dart source.
- [ ] Graph index refreshed with `graphify update .`.
