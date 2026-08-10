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
| Flutter logout | File credentials are removed, hardware identity remains, daemon cloud transport disconnects, Local Gateway remains. |
| Daemon/CLI mutation | Running daemon reloads and broadcasts; Flutter updates `AuthCubit` without echoing. |
| Missed notification | Local reconnect performs reconciliation and requests one peer reload. |
| Malicious extra event field | Entire exchange is rejected before payload logging; no file reload or response occurs. |
| Portal timeout/503 | Existing transient outcome retains credentials and does not publish logout. |
| Concurrent client/daemon refresh | Exactly one native process calls the Portal; the waiter acquires `auth.refresh.lock`, re-reads `auth.json`, adopts the rotated pair, and emits no second refresh request. |
| Concurrent login/logout/pairing mutation | The complete read-modify-write transaction is serialized and cannot overwrite a peer rotation. |
| Lock owner exits or throws | The operating-system lock is released and the next waiter proceeds. |
| Lock held past acquisition bound | The caller preserves credentials and reports a transient recovery outcome rather than logging out. |
| Windows/Linux/macOS | The same stable lock file and native advisory-lock contract pass on each release runner. |
| Web/mobile | No Local Gateway exchange or native auth lock is started; existing independent Portal lifecycle remains unchanged. |

## Commands

Run the shared lock package tests, including the real two-process contention fixture. Run focused agent tests for `AuthManager`, Local Gateway transport, and cloud platform authentication lifecycle. Run focused Flutter tests for `AuthService` and socket recovery, then both analyzers. Windows, Linux, and macOS release CI must execute the shared package test before release closure.

## Remaining Distributed Commit Risk

Local mutual exclusion closes simultaneous-process replay. It cannot recover a process that exits after the Portal consumes a rotating refresh credential but before the new pair reaches `auth.json`; that separate crash window requires a future server-side idempotent refresh protocol.
