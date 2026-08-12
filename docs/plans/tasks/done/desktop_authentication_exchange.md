---
title: "Desktop Authentication Exchange"
description: "Synchronize live Sanad login, refresh, and logout state between the native Flutter client and local Dart daemon without transporting credentials."
status: "implemented_pending_review"
scope: "Public native desktop client and local daemon"
---

# Desktop Authentication Exchange

## Goal

When the native desktop client and daemon share one Sanad Home, either process may update `auth.json`. The writer must notify the other process immediately so it reloads the shared document and updates only its in-memory authentication and cloud-connection projection.

## Design

- `auth.json` remains the credential source of truth.
- The authenticated Local Gateway carries a credential-free `authentication_exchange` notification only.
- A receiver never trusts the event as login or logout authority. It reloads `auth.json`, compares the resulting state with memory, and applies the file state.
- Login, refresh, and logout writers persist first, update their own memory, then emit the notification.
- Reconciliation caused by an incoming notification never emits another notification.
- Native desktop performs the exchange. Mobile and Web remain cloud-only and keep their independent Portal authentication lifecycle.
- Native auth writers serialize through the shared owner-only `auth.refresh.lock`; a waiter re-reads and adopts a peer-rotated pair before deciding whether a Portal refresh is still required.
- Desktop logout snapshots the Client access/refresh pair for Portal revocation, persists a credential-free pending Agent logout marker, clears Client credentials, then asks the authenticated Local Gateway to perform `AuthManager.logout()` outside the shared lock.
- A running Agent deletes durable and pending Device Credentials and disconnects only its cloud transport. If the Agent is absent, the pending marker survives in `auth.json`; startup consumes it before cloud authorization while preserving `hardware_id` and any newer Client login.
- This release does not add post-login deferred Agent enrollment. If Client logout and a later Client login both occur while the Agent is absent, Agent startup clears the old account credential and remains unauthorized until a future explicit enrollment path runs.
- Agent/client restart sequencing may expose an active conversation before Local Gateway is ready. When the local transport later reaches `ready`, transport readiness—not the stale pre-reconnect `DeviceConfig.isOnline` snapshot—triggers session-list reconciliation followed by active history hydration.

## Implementation Gates

- [x] Agent `AuthManager` exposes credential-free change notifications and detects meaningful external reload changes.
- [x] Local daemon accepts and broadcasts only the credential-free exchange event.
- [x] Cloud daemon connection starts, reauthenticates, or disconnects after the reloaded file state changes.
- [x] Flutter Desktop emits after local login/refresh/logout persistence and reconciles incoming notifications without echo.
- [x] Flutter authentication presentation follows externally reloaded login/logout state.
- [x] Startup/reconnect reconciliation covers notifications missed while either process was unavailable.
- [x] Windows, Linux, and macOS auth mutations use one shared OS-backed lock and concurrent refresh waiters do not replay the old credential.
- [x] Focused agent, Flutter unit/widget, and daemon-backed local exchange tests pass.
- [x] Strict authenticated `POST /auth/logout` invokes `AuthManager.logout()` with no query/body/extra fields and a bounded credential-free response.
- [x] Client logout remains successful across absent/timeout Local Agent failures and a daemon-backed Client→Local Gateway→`AuthManager` test proves vault deletion.
- [x] Offline Agent startup consumes pending logout without deleting `hardware_id` or reusing the prior account Device Credential.
- [x] Technical and QA documentation describe the final contract.

## Out of Scope

- Sending access or refresh credentials in an exchange event or Local Gateway response.
- Changing Web or Mobile authentication behavior.
- Automatic deferred Agent enrollment after Client login completed while the Agent was absent; this is a separate account-bound protocol change.
- Recovering a process crash after server-side refresh consumption but before local pair persistence; that requires server-side idempotency.
