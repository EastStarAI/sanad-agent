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
path. Mobile keeps `sanad://` as a general application deep-link namespace, but
authentication rejects it and every unrelated claimed link; OAuth completion
accepts only the exact registered HTTPS callback.

### Mobile claimed-link ownership

Android declares three verified HTTPS App Links, one for each Portal environment,
all restricted to `/oauth/android`; `assetlinks.json` binds them to
`com.eaststarai.sanad` and the environment-injected public SHA-256 signing
certificate fingerprints. iOS uses `Runner.entitlements` Associated Domains for
the same three hosts, while each host serves an AASA document binding
`UC2824B99G.com.eaststarai.sanad` only to `/oauth/ios`. Missing Android
fingerprints return `503` instead of publishing an unverified association.

Production mobile builds receive the exact callback URIs through
`client/config/prod.json`. Development and Staging test builds inject their
matching URI explicitly. `app_links` subscribes before the system browser opens,
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
Secret Service without placing values in process arguments, and Windows stores
only DPAPI ciphertext under the protected Home boundary. Startup migrates
legacy `device_identity.json` and `auth.json.device_token` by writing and reading
back the vault entry before deleting plaintext. An unavailable or unverifiable
vault fails closed and preserves legacy bytes only for recovery; it never loads
them as an active fallback credential.

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
Device Credentials do not enter this User refresh family.

## Secret boundaries

- PKCE verifier, provider code, device code, proof JWTs, private keys, and raw
  credentials never enter logs.
- Authorization and Device Credentials never enter URLs.
- Refresh credentials are request-body values only.
- User codes are display identifiers, attempt/rate limited, and are not bearer
  credentials.
- `sanad_client` and `sanad_agent` audiences are never cross-accepted.
