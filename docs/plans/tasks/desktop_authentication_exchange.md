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
- Cross-process refresh locking is intentionally deferred for launch risk control. Both processes retain the existing re-read-before-refresh mitigation.

## Implementation Gates

- [x] Agent `AuthManager` exposes credential-free change notifications and detects meaningful external reload changes.
- [x] Local daemon accepts and broadcasts only the credential-free exchange event.
- [x] Cloud daemon connection starts, reauthenticates, or disconnects after the reloaded file state changes.
- [x] Flutter Desktop emits after local login/refresh/logout persistence and reconciles incoming notifications without echo.
- [x] Flutter authentication presentation follows externally reloaded login/logout state.
- [x] Startup/reconnect reconciliation covers notifications missed while either process was unavailable.
- [x] Focused agent, Flutter unit/widget, and daemon-backed local exchange tests pass.
- [x] Technical and QA documentation describe the final contract.

## Out of Scope

- Sending access or refresh credentials in an exchange event or Local Gateway response.
- Changing Web or Mobile authentication behavior.
- Adding a cross-process refresh lock in this release task.
