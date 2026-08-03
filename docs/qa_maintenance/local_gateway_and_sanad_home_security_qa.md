---
title: "Local Gateway and Sanad Home Security QA"
description: "Regression matrix for authenticated loopback transport, secure local files, migration, and isolated runtimes."
---

# Local Gateway and Sanad Home Security QA

## Admission Matrix

| Scenario | Required result |
|---|---|
| Missing or incorrect credential on any HTTP route | `401`; no route logic or sensitive response executes |
| Correct credential with missing, malformed, or non-loopback Host | `403`; no route logic executes |
| Correct credential and Host with an unknown Origin | `403`; no upgrade or route logic executes |
| Authenticated native loopback request without Origin | Accepted; absence of Origin alone grants nothing |
| Non-loopback configured bind | Daemon exits nonzero without fallback |
| Upgrade count exceeds the pre-auth budget | Excess handshake is rejected promptly and released slots recover |
| Flutter Web or mobile runtime | No Local Gateway credential read and no local connection attempt |

Real transport coverage includes health, ordinary WebSocket admission,
Origin/Host enforcement, and the pre-authentication budget. The same admission
gate runs before every lifecycle, logs, and voice route. Constructor coverage
proves an empty expected credential cannot become a fail-open mode.

## Filesystem Matrix

| Scenario | Required result |
|---|---|
| New Home and nested directory | Owner-only root and directories before use |
| New secret/config write | Exclusive secure temp before payload, atomic activation, owner-only destination |
| Simulated write failure | Original destination unchanged and no temporary artifact remains |
| Legacy permissive files and directories | Content preserved, permissions tightened, second migration unchanged |
| Root or child symbolic link | Typed failure without touching the link target |
| Traversal, absolute child, null byte, or overlapping roots | Typed failure without creating a file |
| Existing SQLite database and sidecars | Secured before/after open without replacing SQLite-owned bytes |
| Windows legacy ACL | Inheritance and prior rules removed; only the current user retains access |

The inventory covers identity, provider auth/secrets, environment configuration,
state database sidecars, memories, request dumps, logs, backups, model caches,
MCP user configuration, and developer-launcher runtime files.

## Restart and Isolation Matrix

1. Start with a legacy Home, connect the native client, restart the daemon, and
   reconnect using the same Home credential without content or identity loss.
2. Run primary and linked-worktree instances concurrently and prove that each
   client uses its matched port, Home credential, database, memories, dumps,
   launcher records, and preference namespace.
3. Run daemon-backed tests with temporary Homes and synthetic provider state;
   verify the ordinary user Home remains byte-for-byte untouched.
4. Exercise missing/invalid credential repair and confirm neither the old nor
   replacement value appears in logs, exceptions, health, or process arguments.
5. Restart the client independently from the daemon and the daemon independently
   from the client; both recover through the durable Home credential.

## Release Evidence

The release record includes focused unit tests, real daemon/client transport
tests, legacy restart coverage, worktree isolation coverage, agent and Flutter
analysis, and a Windows ACL run on Windows. Platform-specific evidence may be
recorded separately, but an unverified platform claim is not marked complete.
