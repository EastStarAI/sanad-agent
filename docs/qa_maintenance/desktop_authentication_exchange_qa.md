---
title: "Desktop Authentication Exchange QA"
description: "Regression matrix for credential-free client-daemon authentication reconciliation."
---

# Desktop Authentication Exchange QA

## Automated Matrix

| Scenario | Required result |
|---|---|
| Flutter login | File is persisted before one exchange request; daemon reloads and can connect without restart. |
| Flutter refresh | Peer adopts the rotated pair from the file; notification contains no credentials. |
| Flutter logout | Latest access/refresh are retained only for Portal revoke; Client credentials and pairing fields are removed, pending Agent logout is persisted, explicit local Agent logout is requested outside the file lock, and `hardware_id` remains. |
| Running Agent logout | `AuthManager.logout()` deletes durable and pending credentials from Secret Store, cloud transport disconnects, Local Gateway remains healthy, and bounded payload/log canaries contain no credential. |
| Absent/timeout Agent | Client logout and Portal revoke continue without waiting; pending logout survives for Agent startup. |
| Offline logout then newer Client login | Startup consumes pending logout, preserves the newer Client pair and `hardware_id`, deletes the prior account Device Credential, and leaves Agent unauthorized; deferred enrollment is not claimed. |
| Local logout admission | Only authenticated POST with no query/body succeeds; GET, query, body, transfer-encoded payload, and unauthenticated requests fail before logout. |
| Daemon/CLI mutation | CLI retries transient authenticated HTTP delivery, requires an explicit credential-free acknowledgment, and the running daemon reloads and broadcasts so Flutter updates `AuthCubit` without echoing. A stopped daemon is silent/expected; a reachable non-acknowledging daemon yields a bounded service-restart instruction. |
| Missed notification | Local reconnect performs reconciliation and requests one peer reload. |
| Malicious extra event field | Entire exchange is rejected before payload logging; no file reload or response occurs. |
| Portal timeout/503 | Existing transient outcome retains credentials and does not publish logout. |
| Concurrent client/daemon refresh | Exactly one native process calls the Portal; the waiter acquires `auth.refresh.lock`, re-reads `auth.json`, adopts the rotated pair, and emits no second refresh request. |
| Concurrent login/logout/pairing mutation | The complete read-modify-write transaction is serialized and cannot overwrite a peer rotation. |
| Lock owner exits or throws | The operating-system lock is released and the next waiter proceeds. |
| Lock held past acquisition bound | The caller preserves credentials and reports a transient recovery outcome rather than logging out. |
| Linux Secret Service round trip | On a real Linux user session with Secret Service available and `secret-tool` absent, direct D-Bus write/read/delete succeeds and leaves no process-argument or environment secret. |
| Linux legacy migration | A synthetic legacy Device Credential is written to Secret Service, read back byte-for-byte, and only then removed from `auth.json`. |
| Linux vault unavailable or locked | Missing session D-Bus, missing Secret Service, a locked collection, or any operation requiring an interactive prompt becomes a typed vault-unavailable outcome; daemon startup remains available locally, Agent cloud authority is absent, and pending logout/legacy migration state remains retryable. |
| Windows vault unavailable | DPAPI, native-library, or protected-file failure becomes a typed vault-unavailable outcome; startup follows the same fail-closed local-availability behavior and never treats ciphertext as plaintext. |
| Windows DPAPI round trip | A temporary-home write/read/delete round trip succeeds on the Windows runner and the persisted vault file does not contain the synthetic plaintext. |
| Windows/Linux/macOS | The same stable lock file and native advisory-lock contract pass on each release runner. |
| Web/mobile | No Local Gateway exchange or native auth lock is started; existing independent Portal lifecycle remains unchanged. |

## Commands

Run the shared lock package tests, including the real two-process contention fixture. Run focused agent tests for `AuthManager`, Local Gateway transport, and cloud platform authentication lifecycle. Run focused Flutter tests for `AuthService` and socket recovery, plus the daemon-backed `Client logout reaches Local Gateway and deletes Agent vault authorization` case sequentially, then both analyzers. The integration case must use a temporary Sanad Home, migrate a synthetic Device Credential into the platform Secret Store, logout through the real Client adapter, restart the daemon, and prove authorization remains absent. Windows, Linux, and macOS release CI must execute the shared package test before release closure.

## Remaining Distributed Commit Risk

Local mutual exclusion closes simultaneous-process replay. It cannot recover a process that exits after the Portal consumes a rotating refresh credential but before the new pair reaches `auth.json`; that separate crash window requires a future server-side idempotent refresh protocol.
