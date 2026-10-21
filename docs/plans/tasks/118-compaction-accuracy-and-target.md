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
3. `projection_still_over_budget` on very small sessions (seen on 120 live and on DeepSeek 2026-10-20) — review in Stage2/3A.

## Boundaries

- No blanket multiplier, fabricated floor, ciphertext-length cost or zero opaque cost.
- Never trim required summary sections, drop tools, lower thinking, globally delete replay or shrink summary limits to force a fit.
- Destination/issuer compatibility is [Task 116](docs/plans/tasks/done/116-deepseek-reasoning-replay-across-tool-history.md); history rewrite and the recovery summarizer are [Task 117](docs/plans/tasks/done/117-session-history-integrity.md).

## Gates

- [ ] Stage2 red → green for each failed-summary shape, with attempt accounting and localized safe feedback.
- [x] 3A deterministic paired regressions with fixture-scoped provider receipts; feasible and infeasible target cases; Client metrics consistent with `W` (118b writer; review pending).
- [x] 3B runner/daemon regressions for below-threshold, true pressure, drift and restart non-repeat (118b writer; review pending).
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

### Round 2 — 118b writer, 2026-10-21 (base `66e21c47`, branch `feat/118b-compaction-target`)

One commit per item; each was red first, then green. Logs are under `temp/118b/` in the writer worktree (gitignored).

| Item | What changed | Red → green evidence |
|---|---|---|
| 1. Stage3A complete-request target | The target is `floor(targetRatio × W)` for the whole next request from every caller (`CompactionTargetPolicy`). Before selection, the engine measures two things with the route's wire meter: the fixed overhead (leading instructions plus tools, kept intact) and the current request. The coordinator builds the meter from the adapter's `WireInputUsageMeasurer`. The tail budget is `target − overhead − summary reservation`: the previous summary's transmitted size, or 2048 for the instruction's two pages. After summarization the request is measured again in its transmitted form. The decision snapshot then records the estimated outcome and feasibility (`target_scope: context_window`). A tail above the target is a measured `not_met`, no longer a failure; nothing is trimmed to fit. The first confirmed post-input decides `target_outcome`. Manual and overflow "before" is the active projection, never the hidden canonical head. | `item1-red.log` (5 failures: scope `usable_budget`, no feasibility, factory 25288, outcome `unknown` ×2), `item1-green.log` |
| 2. Replay-aware tail selection | Each candidate tail is priced as transmitted: the wire estimate, with the span between provider receipts that the adapter proves against the current request priced at the confirmed input difference. The receipt reader is shared with the restart restore. Opaque replay outside a proven span is counted as `unproven_replay_items`: not zero, not priced from ciphertext, and never a `met` estimate. Fixture-scoped pair from Task 106: A (4 replay items, 8 pairs, estimated 20031, provider 19689) and B (23 replay items, 39 pairs, 20666 versus 32557). Covered cases: stale, foreign-model and missing receipts; the newest replay item; feasible and infeasible targets. | `item2-red.log` (case B: item-1 code selects a tail whose provider cost 19982 exceeds the 12685 budget), `item2-red-compile.log`, `item2-green.log` (9 passed) |
| 3. Client metrics on `W` | The detail card's before, after and threshold percentages use `W`; the usable-input line is removed. | `item3-red.log` (2 failures), `item3-green.log` (13 passed) |
| 4. Stage3B regressions | Runner: after a completed compaction and a restart, the pre-boundary receipt in the retained tail is not restored and does not repeat compaction. Green on the base; a seeded mutation that skips the proof turns it red. Daemon F.53.11: one compaction under true pressure, no repeat across a restart and two follow-ups, and a small sibling never compacts. F.53.11 is a regression lock: green on `66e21c47`, and the mutation does not discriminate it. The audit of the existing drift, cache, image and restore suites is in `docs/qa_maintenance/context_compaction_qa.md`. | `item4-red-mutation-proof-ignored.log`, `item4-green-runner.log`, `item4-red-mutation-daemon.log` (non-discriminating, reported) |
| 5. `projection_still_over_budget` on very small sessions | Cause, reproduced on `66e21c47`: a manual `/compact` of a session already within the target paid for a summary larger than the rows it replaced. The no-progress guard then rejected it with an "over budget" cause. Fix: a manual compaction within the target is `no_op` before any claim or provider call. Auto and overflow are unaffected. The Client shows a localized neutral not-needed notice (en/ar). Fixtures that modelled small sessions under large targets now use targets their sessions exceed. | `item5-red.log`, `item5-red-base-66e21c47.log`, `item5-green.log`, `item5-client-red.log`, `item5-client-green.log` |

Gates at this round:

- Agent `fvm dart analyze` clean.
- Full agent suite +3217 ~14 (`final-agent-suite.log`; baseline +3199 ~14).
- Daemon E2E 11/11 with `--concurrency=1` (`final-daemon-e2e.log`; baseline 10/10).
- Client `fvm flutter analyze` clean; full Client suite +1882 ~1 (`final-client-suite.log`).
- `scripts/lint_wiki.dart` passes.

Findings reported, not changed:

- The transmitted summary projection (`CompactionSummaryProjection.format`) omits the required `criticalContext` and `latestUserRequest` fields that the engine's own `formatSummary` includes. The engine now measures the transmitted form. Whether the projection should carry those fields is a decision outside this task.
- A session above the target whose summary still makes no progress keeps the documented F5 `projection_still_over_budget` classification.
- Task 117's optional "re-anchor boundary endpoints by `message_id`" slice names 118 as its destination but is not in this task's scope list; it was not implemented.

Still remaining: independent review and the Stage3A live acceptance on the Test Home.

### Round 3 — 118b writer, live r1 findings, 2026-10-21 (on `a80a59f2`, then merged with `origin/main` `4fa4dd72`)

Input: 118b live r1 on Test Home 1, route OpenCode Go `deepseek-v4.1-flash`, which resolves `W` = 1,000,000.

What passed:

- A manual compaction met the target: the first confirmed post-input was 63,687, 6.37% of `W`.
- The small-session no-op.
- The Client tile shows `W`.
- Restart and below-threshold, but neither could discriminate at `W` = 1M.

Auto compaction was budget-blocked: crossing 90% of a 1M window costs over 900k input per call.

| Finding | Result | Red → green evidence |
|---|---|---|
| D1. Fixed overhead under-measured on the manual path | Cause: `handleCompactCommand` seeded from a fresh session runner without the per-turn tool catalog or the runtime context. The measured overhead (1125) therefore missed the runtime system context and the 13 tools the follow-up carried (about 3863 by chars/4), and the summary pass lacked the ordinary tool list. `LocalRuntimeOrchestrator.prepareIdleRequest` now registers the same catalog and builds the same runtime context as an ordinary request; the idle request shape is shared with suspended resume. A runner-level check confirms the seed's instructions and tools equal the ordinary request's for the same inputs. The rest of the under-estimate (63,687 confirmed versus 54,800 estimated) is only partly overhead: about 2,700 is the overhead gap and about 6,100 (11%) is the summary and tail estimate. The retained tail was `estimated` (`proven_receipts=0`, since the imported receipts came from another instance and model), so the chars/4 rate applied. A same-route receipt inside the tail moves it to `mixed`. | `r2-d1-red.log` (runtime orchestrator never consulted), `r2-d1-green.log` |
| D2. "Auto threshold" missing from the tile after restart and reopen | Cause: the Client history-row mapper dropped `auto_threshold_tokens`. Live events already carried it. This predates 118b (absent at `66e21c47`). | `r2-d2-red.log`, `r2-d2-green.log` |
| G2. Pressure decision not observable on a turn that does not compact | Every automatic pressure decision now logs one fine-level scalar line: `auto_pressure basis=… estimated=… confirmed=…\|none threshold=… window=… capped=… decision=below_threshold\|cooldown\|compact`. | `r2-g2-red.log` (no record), `r2-g2-green.log` |

Gates after the merge:

- Agent `fvm dart analyze` clean; full agent suite +3251 ~14 (`r2-final-agent-suite.log`).
- Daemon E2E 11/11 with `--concurrency=1` (`r2-final-daemon-e2e.log`).
- Client `fvm flutter analyze` clean; full Client suite +1927 ~1 (`r2-final-client-suite-rerun.log`). The first run's two MCP test files failed to load ("Unable to connect to flutter_tester process"), then passed alone and in the full rerun.
- Wiki lint passes.

For a smaller-window live route (for example `W` ≈ 128k): the threshold is 115,200 and the target 12,800. With Sanad's fixed overhead (about 4k), a 2048 summary reservation and a summary of about 2k, the tail budget is about 6.7k, so the target is attainable only with a short tail. `target_feasibility` should still read `feasible`. Auto compaction records `before_measurement_kind` `mixed` or `confirmed` from the route's own receipts, and `retained_tail_cost_kind` `mixed` when the tail contains same-route receipts. Set `LOG_LEVEL=FINE` to see `auto_pressure` lines.

### Round 4 — 118b writer, live r2 findings, 2026-10-21 (on `4039c570`; `origin/main` unchanged at `4fa4dd72`)

Input: 118b live r2 on Test Home 3, route OpenRouter `openai/gpt-4o-mini`, `W` = 128,000.

What passed:

- Auto compaction met the target: the first confirmed post-input was 10,052, 7.85% of `W`. The estimate was 9,837, −2.1% (r1 was −14%).
- D2.
- Restart and below-threshold, with `auto_pressure` lines recorded.

The manual compaction failed (D3).

| Finding | Result | Red → green evidence |
|---|---|---|
| D3. Field type mismatch treated as invalid JSON | Valid JSON with a non-string value in an allowlisted field (an object or array in `filesAndPaths`) is now the distinct ledger shape `summary_schema_mismatch`; its terminal cause is `invalid_response`, so no new Client copy. Its single correction names each field and its JSON type instead of re-listing every required field. Applies in the main and recovery paths. Values are not normalized, because the design keeps wrong types rejected rather than flattening content. | `r4-d3-red.log` (8 failures), `r4-d3-green.log` (31 passed) |
| D4. A failed operation under-reported its spend | `failStarted` writes `summarization_attempts` (ledger length) and the aggregate usage and duration into the accounting columns. The projection estimate columns stay NULL. | `r4-d4-red.log` (`Expected: <2> Actual: <0>`), `r4-d4-green.log` |
| O1. Full pass sent although it must overflow | Not changed. The design forbids a compaction-only output cap, and predicting a provider overflow needs the provider's default output reservation, which the request does not know; the chars/4 estimate is not exact enough to skip the pass safely. The rejected pass was not billed (1.8 s), and bounded recovery then succeeded. | — |

Gates:

- Agent `fvm dart analyze` clean; full agent suite +3260 ~14 (`r4-final-agent-suite.log`).
- Daemon E2E 11/11 with `--concurrency=1` (`r4-final-daemon-e2e.log`).
- Client `fvm flutter analyze` clean; full Client suite +1927 ~1 (`r4-final-client-suite.log`).
- Wiki lint passes.

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

### 118b — writer complete, review and live acceptance pending

- Stage3A: the complete-request target against `W`, replay-aware tail selection, and Client metrics on `W` (round 2 — 118b writer).
- The rest of Stage3B (the audit items listed in round 1).
- `projection_still_over_budget` on very small sessions (moved-in item 3).
