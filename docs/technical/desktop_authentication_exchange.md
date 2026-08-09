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

No additional field is accepted, returned, broadcast, or logged. Receiving this notification grants no authentication state: the receiver reloads the owner-only `auth.json` and derives login, refreshed credentials, device pairing, or logout from that file alone.

## Lifecycle

- A writer persists login, refresh, pairing, or logout first, updates its own memory, then requests an exchange.
- The daemon reloads the file and broadcasts the same credential-free notification only when its in-memory authentication snapshot changed.
- Flutter reloads the file, updates `AuthService` and `AuthCubit`, and reconnects or disconnects its cloud application socket through the existing auth listener.
- The daemon starts, re-registers, or disconnects its cloud gateway projection when `AuthManager` changes. The Local Gateway remains available after logout.
- Reconciliation caused by a received notification does not emit another notification.
- Native Flutter publishes one exchange after Local Gateway readiness, and also reconciles locally, so state converges after a notification was missed while either process was stopped.
- CLI login, pairing, and logout notify a running daemon through the authenticated local `/authentication-exchange` trigger. If no daemon is running, startup reload remains authoritative.

## Refresh Boundary

The existing re-read-before-refresh mitigation remains in both processes. The exchange lets the peer adopt a completed rotation instead of starting from stale memory. A cross-process refresh lock is deliberately deferred for this release; the narrow simultaneous-read race remains documented rather than introducing a new locking lifecycle immediately before launch.

## Security

- The Local Gateway credential authenticates the loopback request; it is never part of the event.
- Access, refresh, device, pairing, and Local Gateway credentials never cross this exchange.
- Unexpected WebSocket fields are rejected before payload diagnostic logging.
- An admitted local caller can request only a reload of the owner-only file. It cannot assert login/logout state or retrieve credentials.
