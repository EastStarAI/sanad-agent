---
title: "Web Push and Installable Web Delivery"
description: "Owned service worker, browser push subscription lifecycle, foreground authority, and the install requirement for iOS in the Sanad web Client."
---

# Web Push and Installable Web Delivery (Plan 174d)

The web Client learns about a suspended ask while no tab is open, and stays
authoritative when one is. It reuses the desktop pipeline unchanged: the Agent
owns the notification decision and its redacted copy, `NotificationPayload`
parses one canonical envelope, `NotificationDisplayPolicy` decides, and
`NotificationService` deduplicates by `event_id`. Web push adds one wake-up
transport plus the browser permission and subscription lifecycle that transport
needs, and nothing else.

Owning code: `client/lib/features/notifications/` (local contract
`client/lib/features/notifications/AGENTS.md`), `client/web/sw.js`, and
`client/web/flutter_bootstrap.js`. The Agent-to-relay instruction contract stays
in [communication_protocols.md](communication_protocols.md) §7.

## 1. Service worker ownership

**Decision: the Client owns one root-scope worker, `client/web/sw.js`, and
registers it from an authored `client/web/flutter_bootstrap.js`. The
Flutter-generated worker is not registered.**

Why this is not a preference but a fact of the toolchain:

- Flutter 3.47 generates `flutter_service_worker.js` as a tombstone: its
  `install` handler calls `skipWaiting`, and its `activate` handler unregisters
  its own registration and reloads every window client. It provides no offline
  cache at all. A push listener cannot be hosted in a worker that deletes itself,
  and there is no supported injection point into generated output.
- Flutter's bootstrap registers that tombstone at the root scope, so a second
  registration at the same scope would race it. A custom `web/flutter_bootstrap.js`
  is the supported override (`{{flutter_js}}` and `{{flutter_build_config}}` are
  substituted by `flutter build web`), so registration moves there and the
  tombstone is simply never requested.
- `sw.js` performs the tombstone's remaining job: on activate it claims clients
  and deletes legacy `flutter*` caches, so an older installed Client does not keep
  serving a stale app shell.

**Offline behavior.** There is no app-shell pre-cache and no fetch handler. A
cold start without a network fails, exactly as it does with Flutter 3.47's
self-unregistering worker, and ordinary HTTP caching is the only reuse. The PWA
install itself does not depend on a fetch-handling worker: name, icons, and
`display: standalone` in `web/manifest.json` are what make the app installable.
If offline start becomes a product requirement it needs a versioned cache of the
Flutter bootstrap, `main.dart.js`, assets, and CanvasKit, which is a separate
task rather than a side effect of push.

## 2. Subscription lifecycle

Permission is requested only from the explicit Settings action, and a browser
permission without a registered endpoint would deliver nothing, so the action
runs the whole lifecycle in one place (`WebPushSubscriptionService`):

1. Read the browser permission. Request it only when the browser has not decided
   (`unknown`); a refusal is reported, never re-prompted.
2. Register the owned worker if it is not active yet.
3. Reuse the browser's existing subscription, or create one with
   `pushManager.subscribe({userVisibleOnly: true, applicationServerKey})`.
4. Register the opaque endpoint and its two keys against the authenticated
   account. No access token, no registration: a browser subscription is bound to
   an account, never anonymous.
5. Persist only the endpoint and the account/client-instance identity, so a
   logout can revoke it after the tokens are gone and a second account
   re-registers instead of inheriting the first one's endpoint.

**The reported status is the relay acknowledgement.** Settings reports
`subscribed` only after the relay accepted the endpoint for the signed-in
account, and the persisted record is that acknowledgement. A browser
subscription alone proves nothing — the relay resolves the account's endpoints,
so an endpoint it never accepted delivers nothing. A refused, unreachable, or
otherwise unacknowledged registration is therefore reported as a failure with a
retry that registers the same browser subscription again without prompting, and
a later acknowledgement clears the failure. Reopening Settings cannot turn a
refused registration into a working pipeline, and a record that belongs to
another account is not this browser's delivery.

Rotation and revocation:

| Trigger | Behavior |
| :--- | :--- |
| Browser rotates the endpoint (`pushsubscriptionchange`) | The worker re-subscribes with the same application server key, forwards the new endpoint to an open page, and the page registers it again. With no page, the next startup repairs it. |
| App start while signed in | `synchronize` registers an existing subscription for the current account when the stored record is missing or names another account. It never prompts. |
| App start while signed out | A kept subscription is unsubscribed and forgotten; the previous account cannot be delivered to it. |
| Logout | Revoke at the relay with the token captured while the session was still valid, then unsubscribe the browser and clear the record. |
| Settings "Turn off browser notifications" | Same revoke and unsubscribe. |

The VAPID **public** key is a build define:
`--dart-define=SANAD_WEB_PUSH_VAPID_PUBLIC_KEY=…`, read once through
`AppConfig.webPushVapidPublicKey`. The private key stays on the hosted relay and
never enters a Client build. An empty value makes availability `unconfigured`
and Settings states that instead of offering a permission that cannot work.

## 3. Foreground authority

A push is a wake-up, not a decision.

- The worker asks the browser for window clients. If any is visible, it posts
  `{type: 'sanad.push', envelope}` and shows no notification.
- The page feeds that envelope into the same `NotificationService` the local and
  cloud sockets feed. Receiver counts do not matter: `NotificationPayload.fromEvent`
  parses both the socket envelope and the push envelope, and dedupe collapses the
  same canonical `event_id` to one sighting. The display policy then applies
  presence: a visible tab showing the exact session raises nothing beyond the
  in-app prompt, and a visible tab showing another session raises the browser
  notification with no push involvement.
- When no tab is visible, the worker renders the notification from the payload
  alone: the Agent already redacted and localized the title and body, so the worker
  invents nothing and reads no conversation state. It resolves the session from
  every shape the product sends — the family `device_event` envelope, the
  documented transport body, and a bare instruction block — using the same
  precedence as `NotificationPayload.fromEvent`, so a shape the page accepts is
  never silently dropped here. Every Agent kind is high urgency, so the worker
  passes `requireInteraction`; a browser that does not support it ignores the
  option, and an explicit `low` or `normal` urgency never forces a banner to
  stay.
- The user's global switch and per-kind choices are mirrored to the worker
  (`Cache API`, because a worker has no `localStorage`) so a closed tab honours
  the same preferences the page applies. `expires_at` is enforced in both
  contexts, so a late escalation never wakes a user for a resolved ask, and a
  withdrawal closes the matching notification instead of raising one.

## 4. Presentation and collapse identity

The page raises a notification through
`ServiceWorkerRegistration.showNotification`, not through `new Notification`.
Both raisers therefore produce the same object class, the same tag, and the same
click path, and a socket notification followed by a push wake-up replaces rather
than stacks.

The tag is the numeric identity the Client derives from its effective collapse
key with FNV-1a (`NotificationCollapseKey.notificationId`). `sw.js` repeats that
derivation byte-for-byte — including the Client's canonical
`ask\0<session>\0<kind>` form when the Agent-supplied key disagrees — because a
notification raised while no page exists has no page to compute it.

## 5. Click-through and actions

- A click focuses an existing Sanad window when there is one, then posts the
  payload to that page. The page routes it through the existing
  `NotificationActionRouter`: a plain click opens the exact session, and an
  action the browser reports is answered through the same
  `tool_permission_response` path, with the same expiry, kind, and pending-request
  checks that fail closed.
- With no open page, the worker opens the app at the session the notification
  names (`?sanad_session_id=…&sanad_request_id=…`), resolving that identity from
  the same three payload shapes and from the page's own presentation payload. The
  page consumes and clears the query, opens that session, and retries once when
  the device inventory arrives after a cold start. An action is **not** replayed
  from the URL: a URL is not evidence that the user pressed the button, so a
  closed-tab action opens the session and the user answers in context.
- Approval **buttons are not offered on web**. Chrome caps a notification at two
  actions, Safari at one, and Firefox ignores them; a three-way approval set
  (allow once, allow for this session, deny) cannot be shown without silently
  removing a decision. The banner is the wake-up and the in-app prompt is the
  decision surface. `supportsApprovalActions` is therefore `false` for the web
  adapter, and the router above still handles any action a browser reports.

## 6. Relay registration contract

The public half of the hosted boundary; the relay's Agent-facing side is
[communication_protocols.md](communication_protocols.md) §7.

`POST {backend}/api/notifications/web-push/subscriptions`

```json
{
  "platform": "web",
  "client_instance_id": "<the Client instance id used in the socket handshake>",
  "endpoint": "<opaque push endpoint>",
  "keys": { "p256dh": "<base64url>", "auth": "<base64url>" },
  "created_at": "<ISO-8601>"
}
```

`DELETE {backend}/api/notifications/web-push/subscriptions` with
`{ "endpoint": "<opaque push endpoint>" }`.

Both carry `Authorization: Bearer <account access token>`. The relay stores the
endpoint against the account and resolves the Agent's target — one Client
instance or the whole account — to endpoints. It never parses a notification.

Failure is contained: `401/403` means the session was rejected, `404/405/501`
means this deployment does not serve the route yet, and any other failure is
reported without removing the browser permission. A failed registration keeps
the subscription so a later attempt reuses it instead of prompting again, and
Settings states that delivery is not registered until the relay acknowledges the
endpoint; a reopened page cannot upgrade that to "delivery works".

The push payload the relay delivers is the Agent's canonical notification
envelope. The relay must preserve its `event_id`, because the page's dedupe
depends on the socket copy and the push copy carrying the same identity.

## 7. iOS

Web push exists on iOS only inside an installed home-screen app. A Safari tab has
no Push API and no notification permission at all, so the Client detects an
uninstalled iOS session (`iPad|iPhone|iPod`, or an iPadOS desktop user agent with
touch points) and reports `installRequired`. Settings explains the Add to Home
Screen requirement and offers no permission button that cannot work; the product
requirement is stated in [Settings Hub](../product/settings_hub.md).

## 8. Browser settings the product does not override

Every Agent kind is high urgency by design, and the browser still wins: site
permission, the operating system's notification settings, Do Not Disturb/Focus,
and a browser's own per-site quieting are respected as they are. On iOS, Focus
and Notification Summary can silence a delivery unless the user allows it. The
product documents this instead of attempting to bypass it.

## 9. Verification boundary

`fvm flutter build web` proves the web surface compiles, the owned worker is
copied, and the bootstrap registers it instead of the Flutter worker. Unit and
widget tests prove the lifecycle, the acknowledgement-driven Settings state, the
display and dedupe matrix, the iOS install state, and Settings copy.
`test/web/sw_closed_tab_notification_test.mjs`, run by
`test/tool/web_push_worker_execution_test.dart`, executes the worker itself with
no browser and no page: for each payload shape it asserts exactly one rendered
notification and the exact click-through URL, plus the known-kind filter, the
withdrawal path, foreground forwarding, and that no notification copy is logged.
No browser is available on the build host, so live permission prompts, real push
delivery, click-through in a real browser, rotation, and the installed iOS path
are recorded as unexecuted in
[174d-web-push-and-pwa.md](../plans/tasks/174d-web-push-and-pwa.md).
