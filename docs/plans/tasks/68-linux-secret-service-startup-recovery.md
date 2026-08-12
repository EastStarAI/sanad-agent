# Task 68 — Linux and Windows Agent Vault Startup Recovery

## Problem

The Linux Agent vault invokes `secret-tool` directly. When the executable or Secret Service is unavailable, Dart can surface a raw `ProcessException`. During authentication reload—especially while consuming `pending_agent_logout`—that exception aborts daemon bootstrap and the supervisor repeatedly restarts it.

## Goal

Keep the local daemon available while Linux vault access is unavailable, without loading Agent cloud credentials from plaintext or clearing unverified logout/migration state.

## Design

1. Normalize Linux `secret-tool` launch failures and Windows DPAPI/native/filesystem failures into `AgentSecretStoreUnavailable` for read, write, and delete.
2. During authentication reload, treat vault unavailability on either platform as a fail-closed cloud-auth state:
   - clear in-memory durable and pending Agent credentials;
   - retain non-secret local identity and Client session metadata;
   - preserve pending logout and legacy credential fields for a later verified retry;
   - allow daemon bootstrap to continue.
3. Keep explicit credential mutations strict: writes, logout, and authorization operations still report vault unavailability rather than claiming success.

## Verification

- Unit tests simulate a missing `secret-tool` executable on macOS and prove normalized failures for read/write/delete.
- Auth tests prove startup continues with no cloud authority and preserves pending logout/legacy bytes while the vault is unavailable, then completes reconciliation after recovery.
- Run focused tests and `fvm dart analyze`.
- Run the focused test on Linux and Windows as final platform gates because macOS cannot exercise a real Secret Service session or Windows DPAPI.

## Status

Implementation and macOS-hosted regression verification are complete. Remaining: real Linux Secret Service and Windows DPAPI platform gates (15%).

## Definition of Done

- No raw `ProcessException` escapes the Linux vault abstraction.
- Vault unavailability cannot create a daemon restart loop during `AuthManager.initialize()`.
- No plaintext fallback credential becomes active.
- Deferred cleanup remains retryable and is verified after vault recovery.
- Technical and QA documentation reflect the behavior.
