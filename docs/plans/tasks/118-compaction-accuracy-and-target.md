---
id: 118
title: Compaction accuracy and complete-request target
status: planned
gate: ready (117 landed)
created: 2026-10-21
parent_task: none (split from 106)
depends_on: [117]
delivery: own PR
---

# Task 118 — Compaction Accuracy and Target

## Goal

Compaction succeeds near the window or fails with a safe explanation; the post-compaction request meets the configured complete-request target (or reports measured infeasibility); and automatic compaction triggers only on true pressure, including after restart.

## Origin

Split from [Task 106](docs/plans/tasks/done/106-compaction-resilience-and-token-estimation-repair.md) Stages 2, 3A and 3B. Task 106's locked decisions (minimal durable record, provider-first measurement, full-request target, replay-aware tail selection) and its post-merge production observations are the binding inputs; read them there.

## Scope

1. **Stage2 — near-window summarization resilience.** Bounded handling of timeout, invalid, empty, reasoning-only and truncated summaries with continuity validation. Prove valid success and continuation, safe explained failure, fallback and attempt accounting, and measured benefit.
2. **Stage3A — complete-request target and public metrics.**
   - Budget the whole post-compaction request (summary + tail + system/runtime instructions + tools + media + required replay) against the full window `W`, not usable input. Product defaults stay 90% threshold / 10% target (`agent/lib/core/config.dart`).
   - Keep the summary, system and tools intact; select the newest complete connected tail that fits; prove source coverage.
   - Replay-aware tail selection: selection cost must match the transmitted projection. Regression pair from 106's observations: 4 versus 23 replay items, 8 versus 39 tool/result pairs (estimated tail 20666 versus provider-attributed 32557).
   - Validate with the first actual provider-confirmed post-input; public percentages use `W`.
3. **Stage3B — premature or repeated automatic pressure, including restart.** Below the threshold must not compact; true pressure must trigger. Cover cache, route/prompt/options/schema drift, image and rich results, restored proof, post-boundary non-repeat, and the internal-versus-nominal threshold discrepancy (227592 versus 232200 at `W=258000`).

Owners: `agent/lib/engine/context/context_compaction_engine.dart` (`prepareSelection`), `agent/lib/engine/context/compaction_tail_selector.dart`, `agent/lib/engine/runtime/` pressure evaluation, `agent/lib/evolution/compaction/model_projection_builder.dart`, and Client metrics presentation.

## Items Moved In from Task 117

Both predate Task 117 and were observed during its live acceptance on a Test Home with the representative corpus (two rounds). Evidence is in [Task 117](docs/plans/tasks/done/117-session-history-integrity.md).

1. **Compaction-pass provider timeout.** The bounded recovery engaged as designed (3 chunks, per-pass budget 44,694, estimated source 96,218), but a recovery pass failed on a provider timeout in both rounds. The 90 s `connectTimeout` in `agent/lib/engine/adapters/provider_watchdog_config.dart` caps non-streamed compaction passes. The failure was contained: the session stayed usable and showed a notice.
2. **Overflow-path breaker.** After a failed automatic compaction, overflow compaction still runs in the same run: `_autoCompactionBlockedForRun` in `agent/lib/engine/agent_runner.dart` is not checked on the overflow path.

## Boundaries

- No blanket multiplier, fabricated floor, ciphertext-length cost or zero opaque cost.
- Never trim required summary sections, drop tools, lower thinking, globally delete replay or shrink summary limits to force a fit.
- Destination/issuer compatibility is [Task 116](docs/plans/tasks/done/116-deepseek-reasoning-replay-across-tool-history.md); history rewrite and the recovery summarizer are [Task 117](docs/plans/tasks/done/117-session-history-integrity.md).

## Gates

- [ ] Stage2 red → green for each failed-summary shape, with attempt accounting and localized safe feedback.
- [ ] 3A deterministic paired regressions with fixture-scoped provider receipts; feasible and infeasible target cases; Client metrics consistent with `W`.
- [ ] 3B runner/daemon regressions for below-threshold, true pressure, drift and restart non-repeat.
- [ ] Owning docs: `docs/technical/context_compaction.md`, `docs/agent_engine/context_compaction_design.md`, `docs/qa_maintenance/context_compaction_qa.md`.
- [ ] Independent review and delegated Sanad live acceptance on the Test Home (large-context route `OpenCode Go / deepseek-v4.1-flash`) with a bounded call and token budget; validate the first actual post-input. Meet 10% (13% allowed upper result for the observed case) or report measured infeasibility.

## Representative Data

Real sessions exported read-only from the main Home are staged privately for this task. The import procedure is in the coordinator's records. Imported usage is historical evidence, not fresh provider confirmation.

## Dependencies

- Depends on [Task 117](docs/plans/tasks/done/117-session-history-integrity.md): its boundary-range and recovery changes touch the same selection inputs.
