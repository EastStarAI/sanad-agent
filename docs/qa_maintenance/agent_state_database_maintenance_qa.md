---
title: "Agent State Database Maintenance QA"
description: "Readiness, idle batching, retention, and controlled-exit VACUUM verification for state.db."
---

# Agent State Database Maintenance QA

Maintenance must never delay daemon readiness, reclassify restorable work, delete conversation history, or block accepted user work. Cleanup begins only after durable restore, platform start, the readiness signal, a grace period, and runtime idleness.

## Ownership

- Deferred policy, grace/idle gating, batching, and vacuum qualification: `agent/lib/evolution/db/agent_state_maintenance_service.dart`
- Success timestamps and pending-vacuum marker: `agent/lib/evolution/db/agent_maintenance_state_repository.dart`
- Page statistics and full `VACUUM`: `agent/lib/evolution/db/agent_state_database.dart`
- Orphan/terminal identity discovery and conditional batches: `agent/lib/evolution/db/runtime/session_work_item_repository.dart`
- Post-ready scheduling: `agent/bin/daemon.dart`
- Controlled-exit execution: `agent/lib/interfaces/runtime/daemon_restart_coordinator.dart`
- Not an owner: `SessionRecoveryRestorer`; recovery ignores orphan rows through a live-session join

## Automated scenarios

1. Daemon source and daemon-backed startup prove readiness occurs before maintenance scheduling or deletion.
2. Restorable-session discovery excludes a legacy orphan without requiring startup cleanup.
3. `completed` and `cancelled` rows older than the exclusive 14-day cutoff are deleted; active, newer, and exactly-at-cutoff rows remain.
4. Terminal/orphan identities are deleted in bounded batches; activity appearing after a batch pauses progress until idle.
5. A completed zero-row pass writes `last_terminal_prune_succeeded_at`; a failed/incomplete pass remains due, while already committed batches remain safely deleted.
6. Missing, malformed, future, exact-24-hour, and throttled timestamps preserve their documented behavior.
7. A vacuum success younger than seven days prevents page-statistics reads entirely.
8. Both 64 MiB and 20% thresholds are required. Qualification writes `vacuum_pending=true` but does not run `VACUUM` while serving.
9. A safe controlled restart invokes pending vacuum after drain and before exit. Success writes the vacuum stamp and clears pending; failure leaves pending and cannot cancel restart.
10. `VACUUM` remains rejected inside an owner transaction.
11. Sessions, messages, active work, and `provider_model_cache` remain unchanged by retention cleanup.
12. Service resolution/execution failure is contained after readiness.
13. An on-disk fixture proves prune creates reclaimable pages and controlled-exit vacuum reduces page count.

## Run / pause / fail matrix

| Step | Runs when | Pause/skip | Failure behavior |
|---|---|---|---|
| Recovery orphan filtering | Every startup query | Never deletes | Orphan work is ignored; valid sessions restore normally |
| Deferred orphan cleanup | After readiness, grace, and idleness | Pauses before the next batch on activity | Warning; terminal work may continue; daemon remains available |
| Deferred terminal prune | Due and idle | Throttled under 24h; pauses between batches on activity | Committed batches remain deleted; stamp stays due until a complete pass |
| Page statistics | Vacuum due and cleanup pass completed | No read when vacuum is throttled | Failure is contained; no pending marker is advanced |
| Full `VACUUM` | `vacuum_pending=true` after safe controlled drain and response flush | Never during startup or normal serving | Marker remains pending; accepted restart still exits |

## Performance gate

Use AOT executables and isolated copies of the authorized large fixture. Time from process launch to `Daemon is running`; file cloning is outside the timed interval. Alternate baseline/branch order over at least 25 samples.

Acceptance: branch median must not exceed `main` by more than both 5% and 25ms. Report median, mean, p95, min/max, sample count, fixture size, and whether maintenance was due. Never run benchmarks against the live database file.

## Test ownership

- Deferred policy, batching, throttle, pending marker, on-disk reclaim, and daemon-backed readiness: `agent/test/evolution/agent_state_maintenance_test.dart`
- Controlled-exit ordering and failure containment: `agent/test/interfaces/runtime/daemon_restart_coordinator_test.dart`
- Existing repository composition coverage: `agent/test/evolution/runtime_state_repositories_test.dart`
- Daemon source order: `agent/test/guards/test_daemon_provider_startup_contract_guard.dart`
