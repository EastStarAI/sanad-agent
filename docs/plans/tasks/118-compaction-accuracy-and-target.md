---
id: 118
title: Compaction accuracy and complete-request target
status: in_progress
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

## Round Log

### Round 1 — writer, 2026-10-21 (base `f77f0571`, not committed)

Delivered in priority order; each item was red on the base, then green. Logs are under `temp/118/` (gitignored).

| Item | What changed | Red → green evidence |
|---|---|---|
| Moved-in 1: pass timeout | `CompactionRequestFactory.buildCompactionRequestOptions` replaces only the response-arrival watchdog (`connectTimeout`, which bounds a whole non-streamed response) with `Config.compactionPassTimeout`: default 600 s (`ModelAwareCompactionPolicy.defaultPassTimeout`), `config.yaml` `compaction.passTimeoutSeconds` (positive integer). First-byte, stream-idle and total watchdogs and every normal turn are unchanged. Streaming the passes was rejected: it changes every adapter family's wire path for one caller. | `item1-red.log` (3 failures), `item1-green.log`; `compaction_pass_timeout_test.dart` |
| Moved-in 2: overflow breaker | The overflow path checks `_autoCompactionBlockedForRun`, and a failed or thrown Overflow compaction opens it. The ambiguous line in `agent/lib/engine/runtime/AGENTS.md` now defines automatic compaction as Auto preflight plus Overflow. | `item2-red.log` (2 failures), `item2-green.log`; `compaction_preflight_integration_test.dart` group "Task 118 item 2" |
| Stage2: failed summary shapes | Safe shape codes (`summary_tool_call`, `summary_truncated`, `summary_incomplete`, `summary_reasoning_only`, `summary_empty`, `summary_invalid_json`) replace free text and `FormatException` messages (which carried provider text) in the ledger. One correction per pass, then a provider-stage failure with the latest shape's cause instead of a misleading `continuity_validation_failed`; the same in recovery passes. Each attempt keeps usage and measured duration; a timeout fails at once with its duration. New causes `summary_empty`, `summary_reasoning_only`, `summary_truncated` have en/ar Client copy. | `stage2-red.log` (10 failures), `stage2-recovery-red.log`, `stage2-green.log`; `stage2-client-red.log`, `stage2-client-green.log` |
| Stage3B: threshold denominator | `RequestPressureSnapshot.thresholdTokens` is `ratio × W` capped by usable input (232200 at W=258000, not 227592); `nominalThresholdTokens` and `thresholdCappedByUsableBudget` exist, and the decision snapshot records `nominal_threshold_tokens`, `threshold_scope` and `threshold_capped_by_usable_budget`. Fixtures that encoded the old denominator were updated with the reason in place. | `stage3b-threshold-red.log`, `stage3b-threshold-green.log`; `context_compaction_engine_test.dart` |

Gates at this round: agent `fvm dart analyze` clean; full agent suite +2939 ~14 (`agent-full-suite.log`); client `fvm flutter analyze` clean; client compaction tests 55 passed (`client-tests.log`). Daemon E2E 9/10 (`daemon-e2e.log`): F.53.6 fails exactly as on the base (`accepted` instead of `failed` for a rejected thinking preparation); it is outside item 2 and Stage2 and was not touched.

Remaining after round 1:

- Stage3A entirely: complete-request target against `W` (today the target is still `usable × ratio` and checks the tail only; `target_scope` stays `usable_budget`), replay-aware tail selection with the 4/23 and 8/39 paired fixtures, Client metrics on `W` (`compaction_event_tile.dart` still uses usable input as its percentage denominator and shows a usable-input line).
- Stage3B regressions beyond the denominator: restart non-repeat, cache, route/prompt/options/schema drift, image and rich results, and post-boundary non-repeat need an audit against the existing Task 106 G11 suites, with daemon coverage where mocks are not enough.
- Stage2 measured benefit and fallback are not new in this round (the existing `after < before` guard stands).
- Independent review and Test Home live acceptance.

### Round 2 — writer, 2026-10-21 (base `f77f0571`, round 1 kept, not committed)

Input: the 118a live acceptance on Test Home 1 (operation `4d6d5d86`, OpenRouter `z-ai/glm-4.5v`, W=65,536). Checks 1–3 passed; two findings.

| Finding | Result | Evidence |
|---|---|---|
| 1. Usage of an unusable recovery attempt | Fixed. Recovery chunk `chunk:2_0` returned `summary_invalid_json` with billed usage (11,535 in / 1,388 out), but its ledger entry had no tokens: in `_recoveryPass` the parsed-text failure (`FormatException`) wrote the entry without the usage it had already added to the pass aggregate. The entry now carries that usage. The same pass's aggregate already counted it, so the live `aggregate_usage` 136,982 and `summarization_input_tokens` were correct (50,444 + 54,184 + 11,535 + 11,577 + 9,242); the 148,517 in the live notes counted chunk 2 twice. A second gap of the same class is fixed too: a failing recovery pass reported only its own usage, so a failure in a later chunk or reduce dropped every earlier billed pass from the failure's `aggregate_usage`; the recovery now wraps the pass diagnostics with its running aggregate. The main path already kept usage for every shape. Tool-call and incomplete shapes were added to the shape matrix (main and recovery). | `temp/118/r2-usage-red.log` (2 failures: recovery invalid-JSON entry `null` tokens; failed reduce entries `null`), `temp/118/r2-usage-ledger-only.log` (ledger fixed, failure aggregate 200 instead of 300), `temp/118/r2-usage-green.log` (23 passed) |
| 2. Second `context_compaction.completed` at the post-boundary confirmation | Not caused by 118, no change. `CompactionCoordinator.reconcilePostBoundaryUsage` (and `reconcileProviderUsage`) republish the completed event with the same deterministic id `context_compaction:<id>:completed` after the write-once `provider_confirmed_request_tokens_after` is set, so live Clients fold the confirmed value into the existing tile. It is called from `AgentRunner` post-boundary usage reconciliation on the first model step after the boundary. The path exists unchanged at `f77f0571` (from `40302223`/`2607a342`); 118 touches neither the coordinator nor that runner call. Contract: `docs/technical/context_compaction.md` §8.4 ("The completed lifecycle event may be republished …"). | `git diff f77f0571 -- agent/lib/engine/runtime/compaction_coordinator.dart` is empty |

Gates at this round: agent `fvm dart analyze` clean (`r2-analyze.log`); 118 focused tests 101 passed (`r2-focused.log`); full agent suite +2950 ~14, all passed (`r2-agent-full-suite.log`).

Still remaining: Stage3A (finding 3 of the live run: `target_scope` stays `usable_budget`), the Stage3B audit items listed in round 1, independent review and the Stage3A live acceptance.

## Delivery Split

Task 118 is delivered in two PRs. This file stays in `docs/plans/tasks/` until 118b lands.

### 118a — delivered (rounds 1 and 2)

- Compaction pass timeout: 600 s default, configurable as `compaction.passTimeoutSeconds`.
- Overflow-path breaker: a failed automatic compaction blocks Overflow compaction for the rest of the run.
- Stage2: safe summary-shape codes, one correction per shape, attempt-usage accounting (round 2), and the fix for provider text leaking into the ledger.
- Stage3B threshold denominator: `0.9 × W`, capped only by usable input.

Coordinator review:

- Round 1: analyze clean; 95 agent and 13 client focused tests passed.
- Round 2: 101 focused tests passed.
- Writer full agent suite: +2950 ~14.

Live acceptance on a Test Home:

- Session `774e49f7` on OpenRouter `glm-4.5v` (W=65,536): recovery passes of 104 s and 133 s completed past the old 90 s cap, and the compaction completed, 244,490 → 10,530 tokens, post-input ratio 0.161.
- A restart did not repeat the compaction.
- The threshold was 58,982 = 0.9 × W, not capped.
- The round 2 accounting fix is proven by tests only; it is simple and test-provable, so no live rerun was needed.
- The second `context_compaction.completed` event is the planned republish by `reconcilePostBoundaryUsage`, which predates 118.

### 118b — open

- Stage3A: the complete-request target against `W`, replay-aware tail selection, and Client metrics on `W`.
- The rest of Stage3B (the audit items listed in round 1).
- `projection_still_over_budget` on very small sessions (moved-in item 3).
