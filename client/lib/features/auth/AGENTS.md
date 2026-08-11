# Authentication Feature Contract

## Scope
This contract applies to `client/lib/features/auth/`.

## Portal Ownership
- `sanad-portal` is the only public authentication surface for the open-source client.
- Do not call backend `/api/auth/*` endpoints from this feature.
- Do not mention identity-provider names, portal flow identifiers, or `{provider}` in auth feature contracts or payload construction; the portal chooses provider and flow.
- `backendUrl` is available only for authenticated REST and Socket.IO traffic after access-token acquisition.
- Preserve the authenticated profile's technical `username` separately from its human-facing `display_name`. Presentation prefers a non-empty display name and falls back to username for legacy accounts or servers.

## Authentication Flow
- `AuthService.login()` generates one in-memory PKCE verifier and S256 challenge, creates a server-registered Client transaction, validates the platform-owned callback state, and redeems the one-time code with the same verifier before storing User credentials.
- Web callback delivery validates exact Portal origin, popup source, message type, and transaction state. Desktop binds literal IPv4 loopback on an ephemeral port and fixed path. Mobile accepts only environment-configured claimed HTTPS links.
- Android owns verified App Links for `/oauth/android` on the Development, Staging, and Production Portal hosts; iOS owns matching Associated Domains and `/oauth/ios`. `app_links` is the sole Flutter callback handler and subscribes before browser launch so cold/warm delivery is not lost. Portal association documents must authorize only `com.eaststarai.sanad`; Android certificate fingerprints are environment-injected public metadata and missing configuration fails closed.
- Generic polling-token login and Headless user-code flows never enter this feature. Desktop, web, and mobile browser sign-in must not show `DeviceLoginChallengeOverlay`.
- Refresh and logout must use the portal-owned operations; never rotate tokens through the backend gateway.
- Refresh outcomes are typed: only a trusted Portal `401` or missing local refresh credential is terminal; timeout, DNS/transport failure, malformed replies, and non-`401` HTTP failures are transient and must retain credentials.
- Persist a rotated access/refresh pair as one authoritative value before publishing refresh success. Retry an authenticated request at most once; a second `401` is terminal.
- Native desktop login, refresh, logout, and auth-document mutations use the shared `auth.refresh.lock`. Refresh re-reads `auth.json` only after acquiring the lock and adopts a pair rotated by another process without calling the Portal again. Web and mobile never use this file lock.
- Native desktop auth mutations publish only a credential-free exchange request after `auth.json` persistence. Incoming exchange reconciliation reloads that file and never echoes another request. Web and mobile do not participate.

## Secret Safety
- Never log access, refresh, polling, device, or authorization tokens.
- Send refresh tokens in request bodies, never query strings.
- Desktop auth persistence containing bearer credentials must use owner-only filesystem permissions on Unix-like systems.
- Keep browser-visible state free of private polling and refresh credentials.
