---
title: "Desktop Authentication Exchange"
description: "Credential-free live authentication reconciliation between a native Flutter client and its local Dart daemon."
---

# Desktop Authentication Exchange

## Boundary

The exchange exists only between a native desktop client and the authenticated loopback Local Gateway under the same Sanad Home. Web and mobile remain cloud-only and keep independent Portal authentication state.

`auth.json` is the only credential authority. The exchange notification is exactly:

```json
{"type":"authentication_exchange"}
```

No additional field is accepted, returned, broadcast, or logged. Receiving this notification grants no authentication state: the receiver reloads the owner-only `auth.json` and derives login, refreshed credentials, device pairing, or logout from that file alone. The credential-free `agent_logout_pending: true` file marker is durable desired cleanup state, not an exchange assertion or credential.

## Lifecycle

- A writer persists login, refresh, pairing, or logout first, updates its own memory, then requests an exchange.
- The daemon reloads the file and broadcasts the same credential-free notification only when its in-memory authentication snapshot changed.
- Flutter reloads the file, updates `AuthService` and `AuthCubit`, and reconnects or disconnects its cloud application socket through the existing auth listener.
- The daemon starts, re-registers, or disconnects its cloud gateway projection when `AuthManager` changes. The Local Gateway remains available after logout.
- Reconciliation caused by a received notification does not emit another notification.
- Native Flutter publishes one exchange after Local Gateway readiness, and also reconciles locally, so state converges after a notification was missed while either process was stopped.
- CLI login and pairing notify a running daemon through the authenticated local `/authentication-exchange` trigger. If no daemon is running, startup reload remains authoritative.
- Desktop Client logout first snapshots the latest User access/refresh pair under `auth.refresh.lock`, clears Client/pairing fields, preserves `hardware_id`, and persists `agent_logout_pending: true`. It then clears presentation/session state immediately, invokes Portal revocation with the snapshot, and best-effort calls authenticated `POST /auth/logout` outside the lock.
- `POST /auth/logout` accepts no query or body and delegates to `AuthManager.logout()`. The Agent verifies deletion of durable and pending Device Credentials, clears pairing state, emits its normal auth change signal so cloud transport disconnects, removes the pending marker, and leaves Local Gateway running.
- If the Agent is absent, Client logout still completes. Agent startup consumes the marker before cloud authorization while preserving any newer Client access/refresh pair and the stable `hardware_id`. A Client login completed while Agent remains absent does not authorize the old account credential; startup leaves Agent unauthorized. Automatic deferred enrollment for that sequence is outside this release.

## Refresh Boundary

Native Windows, Linux, and macOS processes serialize authentication mutations with the stable `SANAD_HOME/auth.refresh.lock` file. The shared pure-Dart lock combines an in-isolate queue with a bounded operating-system advisory exclusive lock; the file is owner-only, contains no credentials, and is never replaced or deleted during normal operation.

A refresher acquires the lock before re-reading `auth.json`. If the persisted access/refresh pair changed while it waited, it adopts that complete pair and does not call the Portal. Otherwise it keeps the lock through the bounded Portal request and atomic pair persistence. Login, logout, pairing, and auth-document read-modify-write mutations use the same lock to prevent lost updates. Web and mobile neither open `auth.json` nor participate in this lock.

An operating-system lock is released automatically when its process exits. A crash after the Portal consumes a rotating credential but before the new pair is persisted remains a separate distributed commit gap; closing that gap requires a server-side idempotent refresh protocol and is not solved by local mutual exclusion.

## Security

- The Local Gateway credential authenticates the loopback request; it is never part of the event.
- Access, refresh, device, pairing, and Local Gateway credentials never cross this exchange.
- Unexpected WebSocket fields are rejected before payload diagnostic logging.
- An admitted local caller can request a reload of the owner-only file and may separately request explicit Agent logout through the strict local POST endpoint. The exchange notification still cannot assert login/logout state or retrieve credentials.
- Logout responses are bounded status only. Access, refresh, Device Credential, pending credential, pairing authority, and Local Gateway credential never enter the URL, body, response, event, or logs.
