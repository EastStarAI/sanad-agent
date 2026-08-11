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
- `AuthService.login()` sends platform and non-sensitive capabilities to `PortalAuthClient`, opens the returned portal URL, polls through the portal client, and stores tokens only after completion.
- Keep the private polling token inside `AuthService`. Never place it in URLs, browser state, logs, or persistent storage.
- Show `DeviceLoginChallengeOverlay` only for an explicit CLI/headless fallback with a non-empty user code. Desktop, web, and mobile browser sign-in must not show it.
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
