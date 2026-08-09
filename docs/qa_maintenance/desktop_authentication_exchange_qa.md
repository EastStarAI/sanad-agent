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
| Web/mobile | No Local Gateway exchange is started; existing independent Portal lifecycle remains unchanged. |

## Commands

Run focused agent tests for `AuthManager`, Local Gateway transport, and cloud platform authentication lifecycle. Run focused Flutter tests for `AuthService` and `AuthCubit`, then both analyzers. A daemon-backed desktop test must verify real login/refresh/logout convergence before release closure.

## Known Deferred Risk

There is no cross-process refresh lock in this release. Both processes re-read `auth.json` immediately before refresh, and completed rotations are exchanged promptly, but an exact concurrent read/request window remains possible. Lock design and stale-owner recovery require a separate post-launch task.
