---
title: "Client Portal Authentication"
description: "Portal-owned login, polling, refresh, credential persistence, and platform presentation architecture for Sanad clients."
---

# Client Portal Authentication

The Web client loads its `AuthPopup` JavaScript bridge from the same-origin
`web/auth_popup.js` file before the asynchronous Flutter bootstrap. The bridge
must not be embedded inline: deployment CSP keeps script `unsafe-inline`
disabled, and the external source avoids a release-specific CSP hash while
ensuring the Dart JS-interop target exists before the user can start login.

## Ownership

`sanad-portal` is the public authentication broker for open-source Sanad clients.
The Flutter client and agent CLI use the same portal-facing lifecycle and do not
construct backend authentication URLs or choose an identity provider flow.
Google login is completed entirely by the Portal/Backend OAuth flow; the Flutter
client consumes only the resulting Sanad authentication lifecycle.
After authentication completes, the backend gateway is used only as an
authenticated application transport.

## Public Lifecycle

1. The client sends platform identity plus non-sensitive capabilities to the
   portal start operation.
2. The portal returns a browser-visible authorization URL, a private polling
   token, and an optional user code for explicit headless fallback.
3. The client opens the authorization URL in the platform-appropriate browser
   surface and retains the polling token only in process memory.
4. Status polling sends the private token in a request body until the portal
   reports completion, cancellation, expiry, or failure.
5. Completed access and refresh credentials are persisted locally, then used for
   authenticated backend REST and Socket.IO connections.
6. Refresh and logout continue through the portal-owned lifecycle rather than
   backend `/api/auth/*` orchestration.

## Secret Boundaries

- The polling token never enters a URL, browser state, logs, stdout, or durable
  storage.
- Refresh tokens are transmitted in request bodies and are never query values.
- Raw access, refresh, device, and polling tokens are excluded from logs.
- Socket diagnostic serialization recursively replaces credential-shaped fields
  with a redaction marker before length limits are applied. Nested maps and
  lists follow the same rule, including authorization headers, cookies,
  passwords, API keys, and client secrets.
- Desktop Sanad authentication is stored in `SANAD_HOME/auth.json` (normally
  `~/.sanad/auth.json`) with owner-only permissions on Unix-like systems and an
  equivalent user-restricted ACL on Windows.
- Provider OAuth and API-key credentials are separate from Sanad identity and
  follow `docs/technical/provider_protocol.md`.

## Platform Presentation

Desktop, web, and mobile normally complete authentication in a browser without
showing an in-app code-entry overlay. A visible user code is reserved for an
explicit CLI/headless fallback selected by the portal. Platform clients do not
encode provider names or portal flow identifiers in their public auth request.

## Refresh outcome contract

Flutter refresh is a three-way result rather than a Boolean:

- `success` publishes the rotated access token only after the access/refresh
  pair has been persisted as one authoritative preference value. Legacy keys
  remain migration mirrors and cannot override that pair.
- `terminalRejected` is limited to a trusted Portal `401` or the local absence
  of any refresh credential. It clears the user session exactly once.
- `transientUnavailable` covers offline state, DNS/connection/timeout failures,
  malformed replies, and non-`401` HTTP failures including `5xx/503`. It keeps
  both credentials and cached user data intact.

The Portal preserves a Backend `401` as the public terminal result. Backend
status failures other than `401` and transport failures become a bounded public
`503`; neither response nor logs expose Backend bodies or credential details.
An authenticated request is retried at most once after refresh. A second `401`
for the newly issued access token is terminal and cannot start another rotation.

## Foreground resume and socket recovery

After a real background-to-foreground transition, the client debounces one
single-flight cloud reconnect. Initial app startup does not count as resume.
Socket authentication failure enters the typed refresh path; transient refresh
failure leaves the application authenticated and its cache visible.

`auth_success` is a recovery trigger, not proof that client data is fresh. The
existing data-layer listeners request authoritative device inventory and then
rehydrate managed conversation clients. Session-list and selected-session
history hydration preserve the prior snapshot until success. History requests
carry a monotonically increasing client generation, so an older response for
the same session cannot replace a newer one. Live events observed while history
is in flight are reconciled through canonical event identities.

Authenticated mobile/web clients remain on their cached home surface while the
cloud is offline and expose the existing non-blocking `Offline`/retry status.
Only terminal refresh rejection changes presentation to unauthenticated.
Desktop local inventory remains independent of this cloud recovery path; mobile
and web never attempt the Local Gateway.

Native desktop processes reconcile live login, refresh, and logout through the
credential-free Local Gateway notification specified in
`docs/technical/desktop_authentication_exchange.md`. The shared auth document,
not the notification, remains authoritative.

## Runtime Consumers

The Flutter `PortalAuthClient` and daemon/CLI auth manager implement the same
logical lifecycle while retaining platform-specific browser and persistence
adapters. `hardware_id` remains persistent Sanad device identity and is distinct
from backend-assigned device registration ids.
