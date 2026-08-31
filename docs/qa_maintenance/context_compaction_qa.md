---
title: "Context Compaction QA"
description: "Automated and daemon-backed regression matrix for durable context compaction."
---

# Context Compaction QA (Plan 53)

## Scope

Verification matrix for durable goal-preserving context compaction across agent persistence, engine quality, orchestration, client UX, and restart/concurrency scenarios.

## Automated suites

| Area | Command | Notes |
|---|---|---|
| Domain types (53a) | `cd agent && fvm dart test test/engine/compaction_types_test.dart` | Enums, summary, candidate invariants |
| Boundary repository (53b B1) | `cd agent && fvm dart test test/evolution/compaction_boundary_repository_test.dart` | Claim, CAS, redaction |
| Model projection (53b B2) | `cd agent && fvm dart test test/evolution/model_projection_builder_test.dart` | Projection, reload, tail pairing |
| Activation (53b B3) | `cd agent && fvm dart test test/evolution/compaction_activation_service_test.dart` | Projection revision, stale completion |
| Engine (53c) | `cd agent && fvm dart test test/engine/context_compaction_engine_test.dart test/engine/context_compaction_fixture_test.dart` | Pressure, tail, repeated anchor, redaction validation |
| Model policy (53g) | `cd agent && fvm dart test test/core/config_test.dart test/engine/adapters_test.dart test/engine/adapters/codex_responses_adapter_test.dart` | YAML defaults/validation, exact model windows, codec-native wire estimate |
| Overflow recovery (53d D4) | `cd agent && fvm dart test test/engine/runtime/compaction_overflow_recovery_test.dart test/core/provider_runtime/runtime_failure_reason_test.dart` | 400 context-overflow classify, one-shot recovery, stream guard |
| Preflight/checkpoint (53d D2/D7) | `cd agent && fvm dart test test/engine/runtime/compaction_preflight_integration_test.dart test/engine/runtime/compaction_checkpoint_resume_test.dart` | Provider history rebuild + checkpoint resume after activation |
| Restart persistence (53f F2) | `cd agent && fvm dart test test/evolution/compaction_restart_persistence_test.dart` | Boundary survives DB reopen |
| Daemon E2E (53f F5) | `cd agent && fvm dart test --concurrency=1 --timeout=120s e2e_test/context_compaction_daemon_e2e_test.dart` | Manual compact + restart history hydration over real daemon |
| Slash catalog (53e E0) | `cd agent && fvm dart test test/interfaces/local_workspace_compact_slash_test.dart test/interfaces/sanad_bridge_test.dart` | `/compact` runtime command exposed |
| Client dispatch (53e E5) | `cd client && fvm flutter test test/widget/compact_command_dispatch_test.dart test/unit/services/skill_composer_utils_test.dart test/unit/bloc/composer_slash_commands_cubit_test.dart` | Partial Enter/click immediate action, exact `/compact`, mid-message exclusion, skill insert-then-submit, duplicate/args/busy feedback |

## Manual scenarios (53f)

1. Long session auto-compaction before provider call when request exceeds budget.
2. `/compact` at composer index zero while session idle; busy while run active.
3. User messages during compaction queue and drain FIFO after terminal outcome.
4. Restart after started/failed/completed boundary; canonical history remains full.
5. Context overflow before first provider token triggers one compaction retry.
6. Timeline tile shows started → completed/failed without exposing internal summary.

## Evidence checklist

- [x] Queue-during-compaction FIFO drain (53d D3 / 53f F3) — `compaction_queue_integration_test.dart` (2026-08-29).
- [x] Manual compact busy/in-progress/unavailable admission (53d D6 / 53e E1) — `handle_compact_command_test.dart` (2026-08-29).
- [x] History includes completed compaction lifecycle rows (53d D6) — `compaction_history_parity_test.dart` (2026-08-29).
- [x] Runtime slash at composer index zero only (53e E0) — `skill_composer_runtime_command_test.dart` (2026-08-29).
- [x] Goal/pending/decision anchors survive three compactions (53f F1) — `context_compaction_fixture_test.dart` (2026-08-29).
- [x] Session A compaction does not affect Session B (53f F2/F3) — `compaction_coordinator_test.dart` (2026-08-29).
- [x] Live/history parity for compaction lifecycle events (53f F4) — `compaction_event_mapper_test.dart` + mapper history fix (2026-08-29).
- [x] Overflow recovery one retry before visible stream (53d D4) — `compaction_overflow_recovery_test.dart` + 400 classify fix (2026-08-29).
- [x] Client `/compact` dispatch and validation outcomes (53e E5) — `compact_command_dispatch_test.dart` (2026-08-29).
- [x] Typed composer selection keeps leading-only `runtime_action` separate from anywhere-insertable `skill`, executes partial Enter/click immediately, coalesces duplicate Enter, and rejects stale slash-search responses after the action closes the surface — focused client suites (2026-08-31 remediation).
- [x] Restart reopens compaction boundary rows (53f F2 partial) — `compaction_restart_persistence_test.dart` (2026-08-29).
- [x] Preflight rebuilds provider history from activated projection (53d D1/D7) — `compaction_preflight_integration_test.dart` (2026-08-29).
- [x] Checkpoint resume stays valid after compaction activation (53d D2) — `compaction_checkpoint_resume_test.dart` (2026-08-29).
- [x] Reconnect/hydration dedupes started→completed lifecycle tiles (53e E2) — `conversation_state_compaction_test.dart` (2026-08-29).
- [x] Full agent/client analyze clean after integration pass (53f F5) — agent + client analyze clean after review fixes (2026-08-29).
- [x] Daemon-backed E2E manual compact, restart causal history hydration, proactive ratio-based auto compaction, and one explicit follow-up executed exactly once without an unnecessary second attempt — `context_compaction_daemon_e2e_test.dart` (2026-08-31 Task 53g: 3/3). The unit/integration barrier suites own deterministic queue classification because the fixture summarizer may complete before the follow-up frame is admitted.
- [x] Multi-tool retained-tail boundary preserves the owning assistant call batch — `context_compaction_engine_test.dart` (2026-08-30 live regression repair).
- [x] Persisted orphan-output boundaries fall back to canonical history — `model_projection_builder_test.dart` (2026-08-30 live regression repair).
- [x] Started/completed/failed lifecycle transitions use distinct deterministic transport `event_id` values while sharing one `compaction_id`, and completed history hydration reproduces the live identity — `compaction_lifecycle_broadcaster_test.dart` + `compaction_history_parity_test.dart` (2026-08-31 independent remediation).
- [x] Flutter preserves that opaque transition `event_id` for transport parity while folding all statuses into one logical `compaction_<compaction_id>` timeline tile — `compaction_event_mapper_test.dart` (2026-08-31 independent remediation).
- [x] A normal post-compaction message preserves canonical prefix row IDs, keeps the active boundary eligible, and measures the compacted projection without producing another boundary — `model_projection_builder_test.dart` + `compaction_preflight_integration_test.dart` (2026-08-31 live regression repair).
- [x] Provider-reported input usage is the route/material-bound preflight baseline; unchanged requests match exactly, new suffixes alone are estimated, and route/prefix changes invalidate it — `context_compaction_engine_test.dart` + `compaction_preflight_integration_test.dart` (2026-08-31 independent remediation).
- [x] Daemon restart restores that baseline from the latest route-matching assistant usage by remeasuring the exact historical request prefix; a resumed 65% request plus a small suffix remains below the 80% Auto threshold — `compaction_preflight_integration_test.dart` (2026-08-31 live regression remediation).
- [x] Response-metrics provider labels cannot change the next request's system prompt route identity or force fallback from confirmed usage to a full-request estimate — `compaction_preflight_integration_test.dart` (2026-08-31 live continuation remediation).
- [x] Stop/resume recovery may rewrite the retained-tail end after activation; projection retains the summary and walks every current row from the surviving tail-start anchor instead of crashing on the obsolete end id — `compaction_operation_record_test.dart` + `model_projection_builder_test.dart` (2026-08-31 live continuation remediation).
- [x] History hydration persists a semantic retained-tail-end fingerprint/occurrence and relocates the lifecycle row after suffix rewrite, preserving `recovery row < compaction < post-compaction response` without timestamp sorting — `compaction_history_parity_test.dart` (2026-08-31 live ordering remediation).
- [x] Live restart/recovery plus client rehydration preserved the active work item and displayed the legacy repaired sequence as failed operations → resumed user message → retained-tail tool result → completed operation (2026-08-31 runtime verification).
- [x] The 463K/359K and 116K/82K drift class is reproduced without transcript data: generic estimation counted visible content/reasoning plus Codex replay alternatives; codec-native estimation returns the wire-only 359K/82K values — `context_compaction_engine_test.dart` (2026-08-31 Task 53g).
- [x] YAML defaults, strict validation, exact per-model inheritance, legacy `CONTEXT_LIMIT` rejection, two distinct model policies, and unlisted fallback are covered by `config_test.dart`; adapter fallback is covered by `adapters_test.dart` (2026-08-31 Task 53g).
- [x] Ratio boundaries below/at/above threshold, retained suffix target, atomic tool groups, repeated compaction, preflight/tool loop, and one-shot overflow recovery pass focused engine/runtime coverage (2026-08-31 Task 53g).
- [x] History places a lifecycle row at the durable retained-tail boundary before the first model response produced afterward, independent of synthetic message timestamps — `compaction_history_parity_test.dart` (2026-08-31 independent remediation).
- [x] A logical compaction cannot regress or switch between terminal `completed` and `failed` states during retry/reload reconciliation — `conversation_state_compaction_test.dart` (2026-08-31 independent remediation).
- [x] Compaction tiles keep a 44px interaction target, render all six manual/auto lifecycle labels at 280px/2x text scale without overflow, and expose identical redacted metrics by tap, hover, and keyboard focus; unconfirmed token metrics are labeled Estimated — `compaction_event_tile_test.dart` (2026-08-31 independent remediation).
- [x] A completed compaction immediately replaces the composer context-usage snapshot with provider-confirmed-after when available, otherwise estimated-after; stale cached-input usage is discarded, while started/failed events do not replace the last valid usage — `compaction_event_mapper_test.dart` (2026-08-31 remediation).
- [x] Manual compaction resolves the active adapter/model context limit before its bounded estimate fallback, carries model/route identity through live and hydrated lifecycle events, and preserves the latest same-model provider window in the composer — `compaction_request_factory_test.dart`, `compaction_lifecycle_broadcaster_test.dart`, and client mapper/usage tests (2026-08-31 remediation).
- [x] The first provider response after activation writes one confirmed after-value, republishes the same completed event id, survives hydration, and cannot be replaced by later tool-loop responses — `compaction_boundary_repository_test.dart` + `compaction_coordinator_test.dart` + live provider verification (2026-08-31 Task 53g).
- [x] Compaction separators fill the conversation width symmetrically while retaining narrow/large-text safety; reconciled details show `Provider confirmed after` and suppress the superseded pre-confirmation estimate — `compaction_event_tile_test.dart` + live UI verification (2026-08-31 Task 53g).
- [x] Compaction details expose one trigger label without the redundant `Type: Auto` / `Trigger: Auto` pair — `compaction_event_tile_test.dart` + live UI verification (2026-08-31 Task 53g).
- [x] Once after-usage is confirmed, the user-facing reclaimed value is recomputed from it rather than the superseded after-estimate; provenance remains estimated when before-usage is estimated — `compaction_event_tile_test.dart` (2026-08-31 Task 53g).
- [x] The durable started claim and queue barrier exist before the first summarizer await, and a thrown summarizer closes started→failed without stranding the session — `compaction_coordinator_test.dart` (2026-08-31 independent remediation).
- [x] Full client fast suite — 1150 passed; 1 skipped (2026-08-31 Task 53g delivery follow-up).
- [x] Full agent fast suite — 1365 passed; 12 skipped. The isolated-runner regression now skips compaction when `AgentRuntimeService` is intentionally absent; the independently reproduced DelegateTaskTool failure is closed (2026-08-31 Task 53g delivery follow-up).
- [x] Compaction AgentRunner/history tests prepare and clean an explicit temporary Sanad Home rather than depending on leaked suite order; the focused Linux-CI repair bundle passes 7/7 (2026-08-31 Task 53g delivery follow-up).
- [x] Provider-confirmed input remains authoritative when Codex wire instructions/tools and the ordered input prefix are unchanged; the `260537 + 1200 = 261737` regression stays below the 80% threshold even when the rough full-wire estimate is `316900` — `context_compaction_engine_test.dart`, `codex_responses_adapter_test.dart`, and `compaction_preflight_integration_test.dart` (2026-08-31 live Auto regression remediation).
- [x] Boundary activation and projection accept edit/retry AUTOINCREMENT gaps such as `[1,5,6,7]` while still rejecting loss of exactly one durable endpoint — `compaction_boundary_repository_test.dart`, `compaction_operation_record_test.dart`, and `model_projection_builder_test.dart` (2026-08-31 live Auto regression remediation).
- [x] Two preflight calls after one synthetic Auto failure emit exactly one started/failed lifecycle because the active-run breaker blocks the repeat — `compaction_preflight_integration_test.dart`; activation diagnostics preserve `sourceRevisionStale`; full agent suite 1373 passed / 12 skipped and isolated daemon E2E 3/3 (2026-08-31 live Auto regression remediation).
- [x] Same-id completed reconciliation bypasses exact-redelivery suppression once, while an identical enriched replay is still dropped; canonical map ordering cannot change the fingerprint — `event_deduplicator_test.dart` + `cross_transport_dedup_test.dart` (2026-08-31 live card remediation).
- [x] The compaction card uses the confirmed after-value, effective-input denominators, daemon-owned automatic threshold, grouped token values, and no Type/Trigger/Status rows; only the centered 44px label opens it and divider clicks do nothing — `compaction_event_tile_test.dart` (2026-08-31 live card remediation).
- [x] Top-level metadata-only history patches preserve every semantic prefix `messages.id` and the newest active compaction boundary, so a small post-compaction suffix stays below threshold; real content changes still rewrite the suffix and invalidate the unsafe summary — `model_projection_builder_test.dart` + `compaction_preflight_integration_test.dart` (2026-08-31 Task 53h).

## Review notes (2026-08-29 evening)

- Gate-by-gate re-review of 53a–53f closed all Exit criteria with focused verification.
- D6 doc fix: canonical lifecycle event names are dotted (`context_compaction.started|completed|failed`), not underscored.
- No git commit/push performed during this review.
