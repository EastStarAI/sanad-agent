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
- Web callback delivery validates exact Portal origin, popup source, message type, and transaction state. Desktop binds literal IPv4 loopback on an ephemeral port and fixed path, then returns a no-store completion page that mirrors the Portal Success design, attempts to close, and otherwise tells the user to return to Sanad. Any external visual asset requires a no-referrer policy so the callback URL cannot leak. Mobile accepts only environment-configured claimed HTTPS links.
- Android owns verified App Links for `/oauth/android` on the Development, Staging, and Production Portal hosts. iOS owns `/oauth/ios` on the matching Client hosts so the final provider callback navigation crosses from Portal to Client instead of being retained by Safari's same-domain Universal Link rule. `app_links` is the sole Flutter callback handler and subscribes before browser launch so cold/warm delivery is not lost; iOS must disable Flutter's built-in Router deep-link handler to prevent callback ownership races. Association documents authorize only `com.eaststarai.sanad`; Android certificate fingerprints are environment-injected public metadata and missing configuration fails closed.
- Generic polling-token login and Headless user-code flows never enter this feature. Desktop, web, and mobile browser sign-in must not show `DeviceLoginChallengeOverlay`.
- Refresh and logout must use the portal-owned operations; never rotate tokens through the backend gateway.
- Refresh outcomes are typed: only a trusted Portal `401` or missing local refresh credential is terminal; timeout, DNS/transport failure, malformed replies, and non-`401` HTTP failures are transient and must retain credentials.
- Persist a rotated access/refresh pair as one authoritative value before publishing refresh success. Retry an authenticated request at most once; a second `401` is terminal.
- Native desktop login, refresh, logout, and auth-document mutations use the shared `auth.refresh.lock`. Refresh re-reads `auth.json` only after acquiring the lock and adopts a pair rotated by another process without calling the Portal again. Web and mobile never use this file lock.
- Native desktop auth mutations publish only a credential-free exchange request after `auth.json` persistence. Incoming exchange reconciliation reloads that file and never echoes another request. Web and mobile do not participate.
- Desktop logout snapshots the latest Client access/refresh pair for Portal revocation, then under `auth.refresh.lock` removes Client and pairing fields while preserving `hardware_id` and persisting non-secret Agent logout intent. It requests explicit Agent logout outside the lock; absent or stalled Local Agent work never delays Client logout.
- Client login completed while the Agent is absent does not clear pending Agent logout or authorize reuse of an old account Device Credential. Deferred account-bound enrollment after that sequence is intentionally outside the current release slice.
- Before Desktop PKCE login, the Client may ask the authenticated Local Gateway to start co-located enrollment and attach only its non-secret request identity to the Portal transaction. The Client never receives the Agent device code, key, proof, or Device Credential. Presentation stays `Completing sign-in` after Client credential persistence until the Local Agent reports completion; absent Local Agent preserves Client-only login. Web/mobile never probe this surface.

## Client Instance Binding
- One UUID v4 `client_instance_id` is stored in the active SharedPreferences namespace. It survives logout and upgrades, while reinstall, site-data deletion, or a different Sanad Home/preferences prefix creates a new id.
- Send the id and allowlisted display metadata only at Portal transaction creation and authenticated Cloud/Local handshakes. Never repeat it in ordinary commands or treat it as a credential.
- Display metadata is limited to client kind, normalized platform/OS/browser family, and app version. Do not collect hostname, personal device name, email, IP address, locale, advertising id, serial number, or free-form user agent.

## Secret Safety
- Never log access, refresh, polling, device, or authorization tokens.
- Send refresh tokens in request bodies, never query strings.
- Desktop auth persistence containing bearer credentials must use owner-only filesystem permissions on Unix-like systems.
- Keep browser-visible state free of private polling and refresh credentials.
