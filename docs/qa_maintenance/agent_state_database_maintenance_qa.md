---
title: "Agent State Database Maintenance QA"
description: "Run, skip, and failure matrix for startup orphan cleanup, 14-day terminal work-item prune, and thresholded VACUUM of state.db."
---

# Agent State Database Maintenance QA

Startup maintenance of `state.db` is a contained, once-per-boot pass. It must not reclassify restorable work, delete conversation history, or prevent daemon restore and platform start.

## Ownership

- Policy and ordered steps: `agent/lib/evolution/db/agent_state_maintenance_service.dart`
- Success timestamps: `agent/lib/evolution/db/agent_maintenance_state_repository.dart`
- Page statistics and `VACUUM`: `agent/lib/evolution/db/agent_state_database.dart`
- Orphan and terminal SQL: `agent/lib/evolution/db/runtime/session_work_item_repository.dart`
- Contained call site: `agent/bin/daemon.dart` after DI/logging, before orchestrator attach, durable restore, and `GatewayManager.start()`
- Not an owner: `SessionRecoveryRestorer` must not run general database maintenance

## Automated scenarios

1. `completed` and `cancelled` work items older than the 14-day cutoff are deleted; rows at the cutoff exactly are kept.
2. `queued`, `running`, `waiting`, `blocked`, and `resuming` work items are kept regardless of age.
3. `sessions` and `messages` rows are unchanged after prune.
4. A legacy orphan work item (inserted with foreign keys off) is deleted; live session work remains.
5. The first boot runs terminal prune; a second boot inside 24 hours skips it.
6. A success timestamp exactly 24 hours old makes prune due.
7. Missing, malformed, and future success timestamps are treated as due.
8. A prune transaction failure rolls back both deleted rows and the success timestamp.
9. `VACUUM` is skipped when reclaimable bytes are below 64 MiB or free pages are below 20%, even if the other threshold is met.
10. `VACUUM` runs when both thresholds are met and the last success is at least 7 days old, including exact equality.
11. A successful `VACUUM` writes `last_vacuum_succeeded_at`; a failed `VACUUM` does not.
12. `VACUUM` is rejected while the database owner has an open transaction.
13. A throwing maintenance service does not prevent durable restore or gateway start.
14. Maintenance runs once from daemon startup and is not repeated by restore.
15. `provider_model_cache` is unchanged after maintenance.
16. `VACUUM` is throttled when the last success is younger than 7 days even if both size thresholds are met.
17. A successful terminal prune with zero deleted rows still writes `last_terminal_prune_succeeded_at`.

## Run / skip / fail matrix

| Step | Runs when | Skips when | Failure behavior |
|---|---|---|---|
| Orphan cleanup | Every boot, before prune throttle | Never skipped by throttle | Warning; prune may still run; restore continues |
| Terminal prune | Missing/malformed/future stamp, or last success ≥ 24h | Last success < 24h ago | Transaction rollback of deletes and stamp; `VACUUM` skipped this boot; restore continues |
| `VACUUM` | Due, `reclaimableBytes >= 64 MiB`, `freeRatio >= 0.20`, no open transaction, prune did not fail | Throttled (< 7 days since success), below either threshold, or prune failed | Stamp unchanged; prune results kept; restore continues |

## Test ownership

- Timestamp parsing, prune, throttle, vacuum decision, rollback, startup containment, on-disk vacuum, and daemon-backed startup: `agent/test/evolution/agent_state_maintenance_test.dart`
- Existing orphan-SQL coverage retained: `agent/test/evolution/runtime_state_repositories_test.dart`
- Daemon source order: `agent/test/guards/test_daemon_provider_startup_contract_guard.dart`
