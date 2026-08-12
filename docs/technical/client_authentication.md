---
title: "Bound Client and Agent Authentication"
description: "PKCE-bound Flutter login and P-256-bound Headless Agent authorization through Sanad Portal."
---

# Bound Client and Agent Authentication

## Ownership

`sanad-portal` is the only public Sanad authentication surface. The Flutter
Client and Headless Agent use separate grants and credentials:

- Flutter receives `sanad_client` User access/refresh credentials only after an
  S256 PKCE authorization-code exchange.
- Agent receives a key-bound `sanad_agent` Device Credential only after
  user-code approval plus P-256 proof-of-possession.

The authenticated profile keeps the unique technical `username` separate from
the optional human-facing `display_name`. Flutter presents `display_name` when
it is non-empty and falls back to `username` so older accounts and older hosted
profiles remain compatible.

## Public Lifecycle

The public code remains provider-neutral. Provider choice and callback exchange
are Portal/Backend details. Legacy `/auth/start`, `/auth/status`, `/auth/cancel`,
and `/handoff` are not supported; no transferable polling secret can retrieve a
User credential.

## Flutter Client flow

1. The Client creates a random PKCE verifier in memory and its S256 challenge.
2. A platform callback binding is created before the transaction:
   - Web: exact app origin and popup message receiver.
   - Desktop: literal `127.0.0.1`, ephemeral port, fixed `/oauth/callback` path.
   - iOS/Android: environment-configured claimed HTTPS app/universal link.
3. The Client calls `POST /auth/client/transactions` with registered client ID,
   exact redirect URI, and challenge.
4. The system browser/Portal completes provider login.
5. The registered callback receives only a short code and transaction state.
6. The Client validates state and calls `POST /auth/client/token` with the code,
   exact client/redirect, and locally held verifier.
7. Only then is the User access/refresh pair persisted atomically.

Web `postMessage` validates the exact Portal origin, popup source, message type,
and payload. The Portal success page targets only the registered app origin;
neither side uses `*`. Desktop binds only IPv4 loopback and rejects any other
path. A valid desktop callback returns a no-store page matching the Portal
Success design, with the same completion card, animated status, return action,
and close fallback. Its favicon is embedded as a base64 data URI using the
canonical `sanad-portal/static/favicon.svg` artwork, so the loopback callback
has no external icon request. External font loading is protected by `no-referrer` so the
authorization-code callback URL cannot leave loopback. Mobile keeps `sanad://` as a general application deep-link namespace, but
authentication rejects it and every unrelated claimed link; OAuth completion
accepts only the exact registered HTTPS callback.

### Mobile claimed-link ownership

Android declares three verified HTTPS App Links, one for each Portal environment,
all restricted to `/oauth/android`; `assetlinks.json` binds them to
`com.eaststarai.sanad` and the environment-injected public SHA-256 signing
certificate fingerprints. iOS instead claims the matching Client hosts
(`dev.app`, `staging.app`, and `app`) for `/oauth/ios`. Provider callbacks remain
on Portal, so the final redirect crosses domains and is eligible to open the app;
Apple intentionally retains a Universal Link in Safari when the current page and
target share a domain. Each Client host serves the AASA document binding
`UC2824B99G.com.eaststarai.sanad` only to `/oauth/ios`. If association fails and
HTTP reaches that callback, the edge disables access logging and immediately
redirects to a query-free, no-store failure page instead of forwarding callback
parameters to Flutter Web or Portal. On iOS, `app_links` is the sole callback
owner and `FlutterDeepLinkingEnabled` remains false so GoRouter cannot consume
the OAuth URI as ordinary navigation before PKCE reconciliation. AppDelegate
keeps Flutter's superclass lifecycle delegation, through which `app_links`
receives both application and scene continuation callbacks. Navigation
diagnostics retain only paths and never query, fragment, code, state, or a
redirect carrying them. Missing Android fingerprints return `503` instead of
publishing an unverified association.

Production mobile builds receive the exact callback URIs through
`client/config/prod.json`. Development and Staging builds inject their matching
URIs explicitly and must never reuse another environment's config. Development
and Staging Home-screen/device-tool acceptance uses a signed Profile or reviewed
release-candidate; Production acceptance uses the signed Release/archive artifact.
A Debug iOS build is launched only through Flutter tooling or Xcode and is not a
release gate. Before hosted promotion, inspect the built artifact for team
`UC2824B99G`, bundle `com.eaststarai.sanad`, effective target Client-host
Associated Domain, and embedded exact callback. The hosted private source must
pin a public commit reachable from public `main`, not a content-equivalent PR
head after squash merge. `app_links` subscribes before the system browser opens,
accepts cold-start and warm-link events, and filters exact scheme, host, port,
and path before code/state validation. Flutter's competing built-in Android
deep-link handler is disabled to prevent duplicate callback delivery.

## Headless Agent Device Authorization

1. `sanad login --portal` creates or loads an Agent-owned P-256 identity from
   the OS-backed Agent vault (macOS Keychain, Linux Secret Service, or Windows
   DPAPI-protected ciphertext).
2. The Agent calls `POST /auth/device/transactions` with the public JWK,
   normalized device display name, and platform.
3. CLI prints only the fixed verification URI, short user code, and shortened
   RFC 7638 JWK thumbprint. Device code and private key remain local and never
   enter CLI arguments, URLs, or output.
4. The user enters the code from another browser, checks device identity and
   fingerprint, authenticates, then explicitly approves or denies.
5. Agent polls `POST /auth/device/token` with a fresh ES256 DPoP-style proof
   containing exact method/URI, time, JTI, and device-code hash. Dart CLI signs
   P-256 through Pointy Castle and serializes the JOSE signature as fixed-width
   raw `r || s`; DER signatures are not sent.
6. Success returns only a key-bound `sanad_agent` Device Credential. No User
   access/refresh token is stored by Headless login.
7. Gateway reconnect first requests a one-use nonce without sending the Device
   Credential, then signs a `SOCKET`/`sanad-gateway:register_device` proof with
   the same P-256 key and sends credential plus proof in registration.

The private key and durable Device Credential are separate OS-vault entries
scoped by the canonical Sanad Home. macOS uses Keychain directly, Linux uses
Secret Service through `secret-tool` without placing values in process
arguments, and Windows stores only DPAPI ciphertext under the protected Home
boundary. Linux command-launch failures and Windows DPAPI/library/filesystem
failures are normalized as vault-unavailable outcomes. During startup, an
unavailable vault disables Agent cloud authority while the local daemon remains
available; pending logout and legacy migration bytes stay intact for a later
verified retry. Startup migrates legacy `device_identity.json` and
`auth.json.device_token` by writing and reading back the vault entry before
deleting plaintext. An unavailable or unverifiable vault fails closed and
preserves legacy bytes only for recovery; it never loads them as an active
fallback credential. Explicit vault mutations still fail rather than claiming
an unverified write or deletion.

## Pairing boundary

One-command pairing remains separate. It begins from an already authenticated
Client and consumes a short-lived pairing credential. Before claim, Agent loads
its vault-backed P-256 key, obtains a one-use Gateway nonce, then sends pairing
authority, public JWK, and proof. Backend consumes the pairing token only after
proof verification and atomically binds the final credential to the JWK
thumbprint, `sanad_agent` audience, hardware, and auth epoch. A lost success
response is retried with the same key/credential but a fresh nonce proof.
This does not turn pairing into user-code login, and Headless Device
Authorization never accepts a pairing token.

## Refresh and logout

Only Flutter User sessions refresh through `/auth/refresh`. Refresh outcomes
remain typed: a trusted `401` is terminal, while network and `5xx/503` failures
retain credentials and cached state. Native desktop auth mutations retain the
shared `auth.refresh.lock` and credential-free local exchange notification.
Desktop logout snapshots User credentials for Portal revocation, persists
credential-free pending Agent logout while preserving `hardware_id`, and then
requests strict authenticated Local Gateway Agent logout outside the lock. Agent
absence never prevents Client logout; startup deletes the prior Agent credential
before cloud authorization. Deferred Agent enrollment after a Client login that
completed while Agent was absent is intentionally a later account-bound flow.
Device Credentials do not enter this User refresh family. A User login or token
rotation does not make the local Agent eligible for cloud registration. On
Desktop, the Client first asks the authenticated Local Gateway for a non-secret,
key-bound enrollment request identity and includes only that identity in its
normal PKCE transaction. The Agent separately sends its non-secret persistent
hardware identity to Portal so Backend reuses the canonical device record and
preserves its display name; default names are `Sanad Agent (<OS name>)`, never a
hostname or IP address. Portal binds both issuance grants to the authenticated
principal; the Client receives only Client credentials, while the Agent redeems
its Device Credential with its private device code and P-256 proof. The UI stays
`Completing sign-in` until the local status reports completion. No local Agent
preserves Client-only login, and Web/Mobile never probe the Local Gateway.
Likewise, Gateway rejection of an Agent credential never refreshes the User
family.

## Secret boundaries

- PKCE verifier, provider code, device code, proof JWTs, private keys, and raw
  credentials never enter logs.
- Authorization and Device Credentials never enter URLs.
- Refresh credentials are request-body values only.
- User codes are display identifiers, attempt/rate limited, and are not bearer
  credentials.
- `sanad_client` and `sanad_agent` audiences are never cross-accepted.
