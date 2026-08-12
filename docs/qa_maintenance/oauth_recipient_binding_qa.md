---
title: "OAuth Recipient Binding QA"
description: "Public Client and Agent regression matrix for PKCE and key-bound Device Authorization."
---

# OAuth Recipient Binding QA

## Automated public checks

- Flutter `PortalAuthClient` sends only registered client ID, exact redirect,
  S256 challenge, and later code+verifier; it contains no generic status poller.
- Web popup accepts one authorization-code message only from the exact Portal
  origin and popup window source; Portal targets the exact app origin.
- Desktop callback binds literal IPv4 loopback on an ephemeral port and fixed
  path. A valid callback returns a no-store, no-referrer completion page matching
  the Portal Success card, animations, return action, and close guidance; wrong
  paths and replay remain rejected. Mobile
  accepts only configured claimed HTTPS links.
- A Client-only User session does not initiate Agent cloud registration. An
  `AUTH_INVALID_TOKEN` registration failure never calls User refresh, preventing
  register/refresh feedback loops and Portal rate-limit exhaustion.
- Desktop co-located login passes only a non-secret enrollment request identity
  from Local Agent to Portal. The Agent retains device code/key/proof and redeems
  the Device Credential itself. Query payloads, request-id mismatch, replay, and
  headless lookup of a co-located request fail closed. UI remains `Completing
  sign-in` until Agent redemption completes; absent Agent remains Client-only.
- Wrong/missing verifier, callback state mismatch, and consumed/expired code do
  not persist a User session.
- Agent creates/loads P-256 identity, prints no device code/private key, and
  signs each token poll with fresh JTI and device-code hash. Headless and
  co-located enrollment use the privacy-preserving `Sanad Agent (<OS name>)`
  display default and never expose a hostname or local IP address.
- Agent stores only Device Credential after Headless approval; no User refresh
  token is created by this flow. The P-256 private key and Device Credential are
  OS-vault entries, and migration deletes legacy plaintext only after verified
  write/read.
- Gateway reconnect requires a fresh nonce proof from the same Agent key.

## Manual matrix

| Mode | Required success | Required failure |
|---|---|---|
| Web | Exact-origin popup code exchange | wrong origin/source/state ignored |
| Desktop | system browser → loopback callback | wrong host/path and expired callback rejected |
| iOS/Android | claimed HTTPS app link | custom scheme/unrelated link rejected |
| Linux Headless | fixed URI + code approved from separate browser | wrong key, denial, expiry, replay rejected |
| Restart | stored Device Credential + same P-256 key reconnect | missing/locked key storage fails closed |

Do not record real credentials, codes, proof JWTs, private keys, or PII in test
output or evidence.

## Local focused evidence

- Client focused tests cover exact S256 create/redeem payloads, desktop callback
  wrong-path and replay rejection, wrong transaction state before Portal
  redemption, and Web rejection of wrong origin/source/type with one-time
  delivery. The four focused files pass `15` tests and Client analysis is clean.
- Agent focused tests cover persistent P-256 identity, ES256 signature
  verification, DPoP token claims, Gateway nonce claims, unique proof JTIs,
  pending/slow-down backoff, Device Credential-only persistence, restart, and
  the Socket adapter's challenge-before-registration sequence. Vault tests also
  cover verified migration, unavailable/corrupt vault failure, retained legacy
  recovery bytes, and a real macOS Keychain round trip. The focused vault/auth
  set passes `16` tests. Pairing claim now requires the same key's fresh Gateway
  proof and is covered with the Gateway adapter in Agent focused `24/24` plus
  Backend focused `10/10`; analyzer and full parallel Agent suite pass `1080`
  tests with `4` skipped. The implementation uses Pointy Castle and emits the
  JOSE P-256 raw signature format (`r || s`) supported by the Portal verifier.
- Mobile platform-contract tests now verify Android auto-verified hosts/path,
  preservation of the general `sanad://` scheme while auth rejects it, iOS
  Associated Domains, Xcode entitlement attachment, disabled Flutter Router
  deep-link ownership, and Production callback defines. Router tests prove OAuth
  query/fragment canaries and credential-bearing redirects never enter navigation
  diagnostics. Portal tests verify exact AASA
  output and fail-closed Android association when certificate fingerprints are
  absent. Clean-device cold/warm claimed-link handling on physical Android/iOS
  and separate-browser Headless E2E remain manual/platform gates.
