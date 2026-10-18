---
id: 106
title: Context Compaction Resilience, Protocol Alignment, and Reference-Grounded Token Estimation
status: in_progress
gate: G9-explanatory-feedback
created: 2026-10-13
branch: fix/106-compaction-resilience-and-token-estimation-repair
evidence_id: 106
evidence_fingerprint: sha256:521e2ac07cf2bec923e9ec68afab079e0b72aefbe883c8e6c28886c4cfee2374
amendment_evidence_id: 106-compaction-regression
amendment_evidence_fingerprint: sha256:8aa804e28d73531802382ed043c3a20bb699b254c10a1de044a04ed31b8638c1
---

# Task 106 — Context Compaction Resilience, Protocol Alignment, and Reference-Grounded Token Estimation

## Goal
Restore reliable manual, automatic, and overflow context compaction across structured tool results and image attachments without changing the user's thinking selection or losing conversation history. Contain failures and explain their actual stage/cause in durable state and the Client. Preserve the original work on orphan-claim recovery, protocol compatibility, wire-grounded token estimates, and mathematically consistent UI metrics.

## Authorized Scope Amendment — 2026-10-18

Task 106 is reopened for a bounded post-merge compaction regression. Its existing Draft PR is not merged. The historical G1–G5 checkmarks below describe earlier work only; they do not establish acceptance of this amendment. The current file location is retained pending the research-to-plan reconciliation.

### Locked User Decisions

- Preserve the user's exact thinking selection. Compaction must not lower, clear, replace, or persist a different thinking level to recover from a failure. Validation errors must be contained and explained, not silently bypassed.
- The UI defect is non-actionable feedback, not visual disappearance: an error toast is shown, and the failed timeline event's details show only `Failure: summarizationFailed`. Improve the explanation without inventing an event-delivery incident.
- Expand Task 106 rather than creating a new numbered implementation task.
- Conduct two independent reference studies before authoring the amendment's final execution gates. Each worker writes one separate ignored report under `temp/106-reference-audit/`; no product implementation, reference execution, live database changes, runtime actions, commits, pushes, or PR changes are authorized by this research request.

### Verified Audit Baseline

- The supplied `agent.db` is empty; the operational data is in the user's `state.db`. All database inspection and reproduction used read-only access.
- Five persisted operations in the inspected two-hour window failed; six persisted operations failed after the merged update. The latest preceding success started at 23:37 local time. There were no lingering `started` compaction claims at inspection.
- Read-only reproduction using one real source-range tool message per failed operation reproduced the same exception in all six cases: `CompactionToolPruner` changes `content` while retaining the original `toolResult`, violating `Message`'s `content == toolResult.displayText` invariant. This includes the session without image attachments and occurs before provider summarization.
- A separate manual-compaction failure escapes provider-seed preparation and the asynchronous command boundary, terminating the daemon with `thinking_capability_unsupported` and exit code 255. Do not weaken thinking validation as the remedy.
- Compaction option builders omit request context, including the resolved thinking directive, capability profile, and attachment store. These are additional defects, not the demonstrated first failure in the six operations.
- Generic exception handling maps unrelated failures to `summarizationFailed` without safe cause details. The amendment must distinguish the failure stage and cause while avoiding secrets, user content, paths, attachment names, and raw provider payload leakage.
- The focused existing engine, request-factory, and compact-command suites passed 38 tests despite the six reproduced failures. Fixtures do not cover the new structured tool-result boundary adequately.

### Reference Study Assignment

Both studies independently inspect source and behavior tests for: immutable structured-result/media pruning; auxiliary-request option preservation; separation of a user's thinking choice from internal request policy; pre-admission and asynchronous exception containment; safe durable failure taxonomy; and actionable command/timeline feedback. Compare manual, automatic, and overflow paths where the source actually has equivalents.

Each ignored report must pin the inspected revision, document license and relevant dirty-source overlap, cite exact source/test locations, distinguish verified behavior from inference, and provide an Adopt/Adapt/Reject matrix with source-neutral acceptance obligations. Explicitly reject automatic changes to the user's thinking selection. Do not treat a source's absent mechanism as an established behavior or copy implementation code.

Both studies are complete and were consolidated against directly checked source/test evidence. Amendment evidence `106-compaction-regression` resolves `ready` with fingerprint `sha256:8aa804e28d73531802382ed043c3a20bb699b254c10a1de044a04ed31b8638c1`. The final added gates are G6–G10 below. Report paths and source-specific evidence remain ignored; tracked requirements stay source-neutral.

Accepted: coherent derived result transformations, complete request context, whole-command containment, transcript-preserving failure, and safe explanatory feedback. Rejected: default-low/off or fallback thinking even on the auxiliary wire, raw error formatting masquerading as redaction, fabricated started operations before claim, and destructive failure fallback. New media-retention policies, head/tail truncation redesigns, cooldowns, alternate summary models/providers, and timeout increases are deferred outside this repair.

Current authorization (2026-10-18): the user instructed delegation and continued implementation of G6–G10. Research and gate authoring are complete. Execution started with Wave A (G6–G7) through one agy implementer in the owning isolated worktree; the implementer returned an uncommitted G6–G7 candidate after 22m 09s (8 pruning tests, 5 option-preservation tests, clean Agent analyzer, retained logs). The user then replaced agy with the native Sanad reviewer using the existing `OpenCode Go / deepseek-v4.1-flash` instance, thinking `max` when supported and provider default only if max cannot be selected; that designation applies solely to the reviewer's new session, never to product compaction's thinking policy. Independent review completed the same day with scoped repairs in the same worktree; verdict, findings and evidence are recorded in `temp/106-implementation/wave-a-review.md`. G6 is implementation/review verified. G7 source and forwarding tests passed review, and its remaining real-adapter wire/attachment acceptance was subsequently closed at fixture-wire level during the Wave B review (see G7 receipts). Principal frozen-candidate verification reran 101 focused tests (exit 0, 3303ms) and Agent analysis (exit 0, 3951ms), with unique logs under `temp/106-implementation/`. Wave B's implementer returned a G8 candidate after 29m 06s; independent review and scoped repairs completed on 2026-10-18 with verdict, findings and evidence in `temp/106-implementation/wave-b-review.md`, and the early runtime-readiness checkpoint record in `temp/106-implementation/runtime-readiness.md`. The user requested an early readiness notice for a possible later source handoff because compaction failure is growing the current conversation. The isolated Agent-readiness subset of G10 was prioritized after G8 review, before G9, and is now recorded; G9 remains unimplemented. The subsequent user instruction explicitly authorizes the principal's source handoff when ready, while preserving the selected Home and all unrelated data/runtimes. Latest explicit user authorization permits the principal to switch the current runtime to this Task 106 worktree once the candidate is ready; the user confirms no other sessions are active. The user also instructed continuing afterward until the existing PR is ready to merge: principal-owned tested commits, push, PR updates, CI repair/verification and Ready handoff are authorized. Actual merge into main and protected-review labels remain separate authorization boundaries. Workers cannot perform the runtime handoff or commit/push unless a later brief explicitly delegates those actions.

### Implementation Routing and Handoff

- Wave A: G6–G7, one agy implementer (`gemini-3.8-flash-high`), fresh project/conversation, ordinary tool access with the approved permission flag. Preserve all existing task-plan edits and the already committed G1–G5 implementation.
- Work exclusively in `.agent/worktrees/106-compaction-resilience-and-token-estimation-repair`; no additional worktree or primary-checkout edits are needed for this single writer. The implementer stops writing after the tested candidate; a separate native Sanad reviewer (`OpenCode Go / deepseek-v4.1-flash`, new session, requested thinking `max`) then reviews the diff, re-runs the scoped gates and repairs findings in the same worktree.
- Wave A delivery: red/green evidence for the actual structured-result failure; focused regressions for all three compaction paths and exact request-option/thinking preservation; relevant analyzer; source-neutral owning docs; a scoped diff and a handoff report under ignored `temp/106-implementation/`. Checkboxes may reflect evidenced implementation only; independent review and final acceptance stay separate.
- Verification captures exit status, elapsed duration and stdout/stderr in unique temporary logs; successful tool output is bounded to the final five lines. Use normal concurrency for unit/widget suites. Do not repeatedly run full suites during implementation; the frozen-candidate shared-suite and integration assignment remains G10.
- The worker reads all owning contracts and the current amendment evidence packet/consolidation before implementation. No reference-project execution, live provider/database access, runtime actions, commit, push, PR changes or independent-review self-approval is delegated.
- Wave B assignment: G8 backend failure containment/diagnostics, including safe stage/cause fields through existing command, lifecycle and history/persistence owners. Do not implement Client presentation yet. Keep claimed-operation and pre-claim rejection semantics distinct; add focused fault-injection regressions and owning source-neutral docs, then stop for independent native Sanad review. Resolve Wave A's unused-helper observation only by using the existing canonical context derivation appropriately or removing dead newly introduced code; no cosmetic refactor program.
- Subsequent waves: G9 explanatory feedback, then G10 integrated verification, including the still-open real-adapter wire/attachment acceptance from G7. Keep dependencies and one-writer ownership explicit; do not invent a second failure-policy authority or silently broaden the locked scope.
- Wave B review returned bounded-ready after scoped repairs: Agent fast suite 2798 passed / 14 skipped, focused 142 passed, isolated daemon E2E 6 passed, clean analyzers. Principal contract triage rejects review suggestion S3's acceptance of raw error/stack logging at the protocol bridge: internal logs are not a secret-leakage exception. The same reviewer replaced the raw log and added a discriminating leakage regression; the repaired freeze passes 143 focused tests, 2799 fast tests / 14 skips, clean Agent analysis and 6 isolated daemon E2E cases. The principal independently matched all 22 Agent/test hashes, reran 50 focused tests (2688ms), the 6 daemon cases (41844ms), and analysis (3986ms); all passed. The first principal focused invocation used the repository root rather than `agent/` and exited 65 without running tests; its corrected invocation and separate log are the cited passing evidence. This named production edit invalidates the prior frozen Agent manifest/fast-suite result; retain prior logs, then bind and verify the repaired frozen candidate once. In parallel the principal checks the target Client build prerequisite. Neither check authorizes source handoff before readiness is restored.
- Principal Client prerequisite evidence: target `sanad-dev setup` passed (7518ms), Client analysis passed (8831ms), and a production-config macOS driver debug build passed (103349ms) without launching it. Upstream compiler warnings were non-fatal. The build removed stale `cnativeapi` entries from `client/macos/Podfile.lock` without Dart dependency/version changes; the reviewer restored that generated ancillary lock artifact to the baseline afterward. No Client source/dependency change remains. If a later macOS build regenerates it, review/reconcile it with G9 before final PR delivery rather than silently including it in the backend checkpoint.
- Post-handoff user requirement: inspect bounded Agent/Client logs and this requester's durable compaction lifecycle to verify the expected automatic pressure-triggered compaction; do not force a manual compact first or infer success from daemon startup. Check outcome, safe failure details, context pressure/usage and history continuity. Record any anomaly in this task and delegate repairs/review before continuing toward PR readiness.
- Review orchestration obstacle: native `run` defaults to a real 300-second execution timeout when omitted. It stopped the first review invocation despite visible progress; authoritative inspection then confirmed the same session idle, no pending intervention, and thinking `max`. Resume that exact reviewer session with an explicit long execution ceiling, not a new reviewer/provider. Event-first observation windows stay 30 minutes and never imply task cancellation. Partial test logs are evidence of activity, not final acceptance.

## Locked Decisions & Scope

1. **Protocol Wire Alignment:**
   - Compaction failure outcomes must serialize as canonical `snake_case` on the wire (`compaction_in_progress`, `session_busy`, `claim_lost`, `source_revision_stale`, etc.).
   - The Flutter Client's `SessionCompactResult` must accept both `snake_case` and legacy `camelCase` for robust backward and forward compatibility.
   - When an unmapped or failure outcome occurs, `SessionCompactResult` must capture the raw outcome or message instead of dropping it to `null`, ensuring the client UI never shows a generic `could not start` error when a specific reason exists.

2. **Daemon Startup Reconciliation:**
   - Any compaction operation left in `status = 'started'` at daemon boot is orphaned from a killed or crashed prior process.
   - The daemon must run a startup reconciliation pass on `CompactionBoundaryRepository` that transitions all lingering `started` rows to `failed` with `failure_reason = 'interrupted'` and a durable `completed_at` timestamp.
   - This ensures the `idx_session_compaction_one_started` unique index never permanently locks a session out of manual or automatic compaction across daemon restarts.

3. **Reference-Grounded Token Estimation:**
   - **Wire Shadowing:** Text character estimation (`CompactionTokenEstimator`) must evaluate only model-visible wire content. Internal agent fields (`thought`, `reasoning`), provider state (`codex_reasoning_items`, `encrypted_content`), and internal message metadata must contribute 0 to text character pricing because the provider prices them under its own token models.
   - **Model Projection Input:** Compaction pressure and token budgeting must be computed over the model-facing projected history rather than raw internal database message entities.
   - **Confirmed Token Usage Anchoring:** Compaction pressure must anchor against `ConfirmedInputUsageBaseline` when available, rather than accumulating uncalibrated character-based estimates over thousands of messages.

4. **Client UI Metric Invariant Guardrails:**
   - **Mathematical Invariant:** The retained tail is a subset of the post-compaction request. In `CompactionEventTile`, `Retained tail` must never be rendered with an estimate greater than `After compaction`.
   - When `providerConfirmedRequestTokensAfter` reconciles `After compaction` downward, the retained tail estimate must be clamped or scaled proportionally, or clearly designated as an uncalibrated prior estimate.
   - **Before Compaction Percentage:** When historical uncompacted messages accumulate beyond the context window, clarify that the percentage represents "accumulated history" rather than an active single-turn payload, preventing confusing values like `464.9%`.
   - **Context Reclaimed Calculation:** Must not mix an uncalibrated 6x character estimate with a real provider-confirmed number to display illusory savings (e.g. 99.2%). Reclaimed context must use consistent bases (estimated-before vs estimated-after, or confirmed vs confirmed).

## Reference Grounding

- Historical evidence: opaque ID `106`, fingerprint `sha256:521e2ac07cf2bec923e9ec68afab079e0b72aefbe883c8e6c28886c4cfee2374`; preserved as the original work's record, not fresh amendment evidence.
- Current amendment evidence: opaque ID `106-compaction-regression`, fingerprint `sha256:8aa804e28d73531802382ed043c3a20bb699b254c10a1de044a04ed31b8638c1`, resolver status `ready`.
- Source-specific reports, exact revisions, comparisons, corrections, and inspected symbols/tests remain in the ignored evidence store and research output directory. No source code was copied; no reference test execution is claimed.

## Gate R0 — External Reference Grounding

Historical evidence receipts for the original scope, not re-executed acceptance of the amendment:

- [x] Resolve original evidence ID `106` and record its then-ready fingerprint.
- [x] Inspect mandatory reference source/tests and record a local Adopt/Adapt/Reject matrix.
- [x] Translate accepted patterns into wire-shadowing, usage-anchoring, startup-reconciliation, and wire-compatibility obligations.
- [x] Author the original packet/run record and verify the recorded fingerprint.
- [x] Establish the original behavior contract before implementation.

### R0 Exit

- [x] Preserve the historical local grounding record with its fingerprint and inspected evidence.
- [x] Keep tracked requirements behavioral and source-neutral; source-specific navigation stays ignored.
- [x] Establish isolated worktree `.agent/worktrees/106-compaction-resilience-and-token-estimation-repair` on branch `fix/106-compaction-resilience-and-token-estimation-repair`.

## Execution Gates


### G1 — Protocol Wire-Format Alignment & Error Presentation
- [x] Align `CompactionFailureReason.wireValue` in `agent/lib/engine/compaction/compaction_enums.dart` to canonical snake_case strings (`session_busy`, `compaction_in_progress`, `claim_lost`, `source_revision_stale`, `summarization_failed`, `continuity_validation_failed`, `projection_still_over_budget`, `persistence_failed`, `interrupted`).
- [x] Update `SessionCompactResult.fromJson` and getter properties in `client/lib/features/conversations/domain/models/compaction_event_snapshot.dart` to support both `snake_case` and `camelCase`.
- [x] Ensure `SessionCompactResult` captures the failure reason and human-readable feedback when outcome is not accepted, preventing silent fallbacks to generic error messages.
- [x] Add unit tests for wire-format serialization, deserialization, and client error message resolution.

### G2 — Daemon Startup Reconciliation for Orphaned Compactions
- [x] Add `reconcileOrphanedStartedOperations()` to `CompactionBoundaryRepository` in `agent/lib/evolution/db/compaction_boundary_repository.dart` that marks any existing `started` operations as `failed` (`failure_reason = 'interrupted'`).
- [x] Wire the reconciliation call into daemon bootstrap lifecycle (in `agent_runtime_service.dart` / `gateway_manager.dart` or during database open).
- [x] Add regression tests in `agent/test/evolution/compaction_boundary_repository_test.dart` verifying that orphaned rows from previous runs are safely reconciled on startup and do not block subsequent claims.

### G3 — Reference-Grounded Wire Shadowing & Token Estimation Accuracy
- [x] Implement wire shadowing in `CompactionTokenEstimator` (`agent/lib/engine/context/compaction_token_estimator.dart`):
  - Exclude `message.thought` and `message.reasoning` from character token counting when they do not reach the model wire.
  - Exclude opaque provider state (`message.providerState`) and encrypted blobs from raw character pricing.
  - Price tool calls accurately based on schema parameters and invocation arguments.
- [x] Integrate model-projected history from `ModelProjectionBuilder` into `RequestPressureEvaluator` so pressure checks evaluate only model-visible turns.
- [x] Add unit tests verifying that large reasoning chains or provider state metadata do not inflate message token estimates.

### G4 — Client UI Metric Consistency & Invariant Guardrails
- [x] Update `CompactionEventTile` in `client/lib/features/conversations/presentation/widgets/compaction_event_tile.dart`:
  - Enforce mathematical invariant: `Retained tail` cannot exceed `After compaction`.
  - When `providerConfirmedRequestTokensAfter` is present, clamp or calibrate `Retained tail` so it reflects the confirmed context boundary.
  - Fix `Context reclaimed` calculation so it uses consistent bases and does not subtract confirmed figures from inflated character estimates.
  - Clarify the "Before compaction" label when estimated usage exceeds 100% of context window (e.g. indicate accumulated conversation history).
- [x] Add widget and unit tests for `CompactionEventTile` verifying no UI contradictions when provider usage is confirmed.

### G5 — Verification, Tests & Documentation
- [x] Run `fvm dart analyze` in `agent/` and `fvm flutter analyze` in `client/`.
- [x] Run focused unit and widget test suites covering compaction commands, boundary repository, token estimator, and event tile widgets.
- [x] Verify that `docs/llms.txt`, contracts, and task documentation are updated in accordance with the Definition of Done.
- [x] Run `graphify update .` to keep knowledge graph current.

## Amendment Execution Gates — Implementation Authorized

### G6 — Structured-Result Pruning Integrity

Owners: `agent/lib/engine/context/compaction_tool_pruner.dart`, existing engine compaction tests and anonymized fixtures.

- [x] First capture a failing regression with an old tool message carrying a structured result longer than the pruning limit; assert the reproduced constructor failure on the unfixed owner.
- [x] Transform immutable derived message/result representations together so `content == toolResult.displayText` remains true. Preserve call identity, error flags/codes and required metadata; do not weaken the constructor or silently discard structured results.
- [x] Cover plain legacy text, structured text, error results, mixed text/image blocks, source-media replacement, and oversized retained-tail projection. Keep canonical records and protected-tail source objects unchanged, including when the existing oversized-tail policy derives a separate model projection; do not create invalid empty image blocks or introduce a new image-retention policy.
- [x] Acceptance: all representative cases build a consistent candidate without the old `ArgumentError`; failed candidates never activate a boundary, and input messages remain byte-equivalent in their durable representation.
- Review receipt (2026-10-18): reverting the owner to its unfixed revision fails 7 of 8 suite tests with `Invalid argument (content): must equal toolResult.displayText`; the repaired owner is green in focused and consolidated runs; canonical records, protected-tail objects, error flags/codes, and image payloads remain intact — `temp/106-implementation/wave-a-review.md`.

### G7 — Complete Compaction Request Context and Exact Thinking Preservation

Owners: `agent/lib/engine/agent_runner.dart`, `agent/lib/engine/runtime/compaction_request_factory.dart`, existing request-options owner and adapter fixtures.

- [x] Reuse a single canonical request-context derivation for manual, automatic and overflow compaction. Explicitly account for every `LLMRequestOptions` field rather than maintaining partial constructor copies.
- [x] Preserve provider/model route, admitted thinking selection/directive, capability profile/snapshot, attachment store and transport test seam. Change only compaction correlation and lifecycle fields that need distinct ownership; verify cancellation/timeout/watchdog semantics instead of copying an expired run scope blindly.
- [x] Acceptance: fixture adapters observe the exact expected options and thinking wire directive in all three paths; stored session choice remains unchanged on success, rejection and provider failure. No implicit low/off/default substitution, fallback thinking, or alternate summary model/provider is introduced. Wire closure at actual adapter builders delivered during Wave B review — G7 receipt below.
- [x] Acceptance: an image-bearing request succeeds through the real adapter builder with a verified temporary attachment store; absent/corrupt/unauthorized media fails specifically before HTTP, preserving the storage jail and original history. Wire closure suite delivers the adapter-builder success and pre-HTTP failure cases — G7 receipt below.
- Review receipt (2026-10-18): manual derivation is asserted through `forSession`; auto and overflow forwarding assertions (session, route, correlation id, thinking choice, capability profile, attachment store) were added during review and fail on the previous runner wiring; the stored `high` choice survives auto success and auto failure — `temp/106-implementation/wave-a-review.md`.
- Wire-closure receipt (2026-10-18, Wave B review): `compaction_adapter_wire_closure_test.dart` dispatches compaction-derived options through the real `BaseOpenAIAdapter`/`BaseAnthropicAdapter` with fixture HTTP capture — manual (`forSession`), auto and overflow shapes emit the exact resolved directive; an image-bearing request succeeds with a temporary-Home store and corrupt/foreign-Home media fail before HTTP. Discriminating red: dropping the builder's directive fallback fails the suite (`wbreview-red-wire-closure-20261018-061204.log`); green after hash-verified restore — `temp/106-implementation/wave-b-review.md`.

### G8 — Failure Containment, Ownership and Safe Cause Details

Owners: `agent/lib/interfaces/runtime/session_run_orchestrator.dart`, compact command/async transport handlers, engine/coordinator and durable compaction owners.

- [x] Contain runner construction, provider-seed preparation, request construction and claimed execution; retain the general asynchronous transport safety boundary so one failed command cannot terminate the daemon or other sessions.
- [x] Add a minimal stable stage/cause representation covering actual preparation/validation, pruning, provider and persistence failures. Use allowlisted safe fields; do not persist or transmit raw exception values, stack traces, user content, secrets, paths, attachment names or provider bodies. Formatting/truncation alone is not redaction.
- [x] Before claim, return one correlated command rejection without inventing a started operation or activating history. After claim, persist one owner-valid terminal failure and matching lifecycle outcome; preserve the canonical transcript and release only the matching session/claim ownership.
- [x] Acceptance: unsupported/unknown/unavailable thinking selections, malformed rich results, provider timeout/error and persistence failure produce actionable bounded outcomes. The daemon stays responsive, a sibling session survives, no orphan claim remains, and stale non-null owners cannot emit terminal success, clear newer busy state or drain its queue.
- [x] Retain legacy failure decoding and original enum compatibility. Unexpected failures remain contained with a safe fallback classification, not an unhandled exception or a misleading fabricated provider diagnosis.
- Review receipt (2026-10-18): re-ran the Wave B focused set (22 tests, exit 0); independent red checks prove containment by reverting the preparation catch (exception escapes `handleCompactCommand`) and by bypassing the owner guard (stale owner clears the newer owner); fixed a diff-integrity whitespace warning, a doc/code cause-allowlist mismatch, a non-exercising stale-owner test, and strengthened persistence stage/cause assertions; daemon E2E proves a contained `thinking_capability_unsupported` rejection with daemon survival, unchanged stored choice and sibling responsiveness — `temp/106-implementation/wave-b-review.md`, `temp/106-implementation/runtime-readiness.md`.
- Follow-up receipt (2026-10-18, principal triage): the protocol-bridge raw error/stack internal logging was replaced with bounded allowlisted diagnostics plus correlation (containment preserved), with a discriminating sensitive-fixture regression that fails on the raw logging and passes on the repaired code (`wbreview-S3-red-raw-logging-20261018-064103.log`, `wbreview-S3-green-restored-20261018-064120.log`); the regression also exposed and repaired an un-awaited `getIt.reset()` setUp hazard; the named production edit invalidated the first frozen evidence and the repaired candidate was re-verified once — `temp/106-implementation/wave-b-review.md`.

### G9 — Explanatory Toast and Timeline Feedback

Owners: Client compaction domain models, command result handling, event/history mapping, `CompactionEventTile`, and authored localization resources.

- [x] Deliver the safe stage/cause consistently through manual results, live lifecycle events and history hydration. An automatic/overflow failure must remain understandable in its timeline event without requiring a manual-command toast.
- [x] Render a localized explanation of what failed and an appropriate safe next action in the existing toast and failed-event details, not only `Failure: summarizationFailed`. Preserve English/Arabic parity, snake_case/camelCase decoding and useful legacy fallback behavior; do not display raw exception strings.
- [x] Acceptance: distinguish preparation/thinking validation, tool-result pruning, provider and persistence errors in model/widget tests. Reopening a conversation shows the same explanation as the original live event; details expose no secret-like fixture data and no fabricated token metrics.
- [x] Scope is feedback quality, not missing-event delivery. Avoid unsolicited duplicate toasts or a transport/event redesign.
- Implementation receipt (2026-10-18): G9 delivered with typed `failureStage` and `failureCause` on `CompactionEventSnapshot` and `SessionCompactResult`, unified history and live mapping in `UnifiedDeviceMapper`, central `CompactionFailureFormatter` resolving localized explanation and safe next action without leaking sensitive data, English/Arabic RTL parity via `app_en.arb`/`app_ar.arb`, and updated `CompactionEventTile` details and `/compact` toast dispatch. 56 focused tests passed (exit 0), Client analysis clean (exit 0); evidence recorded in `temp/106-implementation/wave-c-report.md`.
- Review receipt (2026-10-18, native reviewer `opencode-go / deepseek-v4.1-flash`, thinking max): G9 verified with scoped repairs. The unclassified `unexpected_error` cause no longer inherits the provider-default explanation (honest fallback; an Agent-asserted stage keeps its stage copy) with a discriminating model test that failed before the repair, and dead no-op cause inference was removed; owning docs updated. Toast (manual `/compact` result) and timeline tooltip resolve the same explanation/action through one formatter, live and hydrated history stay at parity through `UnifiedDeviceMapper`, snake_case/camelCase legacy decoding is covered by model/history tests, ARB keys are 1:1 (38/38), no Arabic literal entered widget code, and no raw exception text reaches the UI. The generated `client/macos/Podfile.lock` removal of stale `cnativeapi` (0.1.3 plugin-era) entries was reconciled and retained: the current dependency resolves `cnativeapi` 0.5.2 as a non-plugin FFI package and the lock's 17 dependencies now equal the 17 declared macOS plugins. Client analyzer clean; 60 focused tests (8409ms) and the full fast suite of 1639 tests (87516ms) passed once at the reviewed freeze — `temp/106-implementation/wave-c-review.md`.

- [x] Close principal contract triage of the G9 review: newly added English failure-copy fallbacks must derive from the localization system/ARB authority rather than duplicate authored English strings; no newly added Arabic literals may remain in handwritten Client Dart, including tests (existing conventions do not override the root law). Lock English tile copy through localization delegates and add an Arabic toast-path assertion. The localization-authority production edit explicitly invalidates the first G9 Client freeze; retain its 1639-pass log and verify the repaired freeze once. — Completed 2026-10-18: `CompactionFailureFormatter` and its detail-line prefixes now resolve every English fallback from the generated localization (`AppLocalizationsEn`), with the duplicated literals and redundant prefix parameters removed; the new formatter, tile and dispatch tests derive all English/Arabic expectations from `AppLocalizations`/`AppLocalizationsEn`/`AppLocalizationsAr` (zero Arabic literals remain in changed Dart), the three English tile pumps pass `AppLocalizations` delegates so tile copy is pinned through the ARB authority, and `pumpTestApp` gained an optional `locale` for the new Arabic toast assertion. Named invalidation: the localization-authority production edit invalidated the first freeze (retained `wave-c-review-client-fast-20261018-074206.log`, 1639 pass); the repaired freeze was verified once — analyzer clean (6904ms), 61 focused tests (6095ms), full fast suite 1640 tests (94921ms) — `temp/106-implementation/wave-c-review.md`.
- Principal independent verification of the repaired G9 freeze (2026-10-18): 13 full-path content hashes matched the reviewer's final table with no mismatch; Client analysis clean and all 61 focused tests passed (14049ms) — `temp/106-implementation/principal-g9-r2-client-20261018-080453.log`. R2 changed only the formatter/prefix resolution and its tests plus a shared test helper, so the reviewed production behavior is limited to localization authority; the 1640-test full fast suite remains the reviewer's single freeze run.
- Verified runtime refresh receipt: after the first G9 reviewed freeze, principal Agent analysis + 11 isolated missing-Home tests passed (5510ms), Client analysis + 60 focused tests passed (14510ms). At the user's explicit request the principal performed checkpoint-safe Agent restart (exit 0, suspended turn restored) then managed Client restart; target status retained source/Home/endpoints and the Client reconnected. No source handoff or forced kill occurred. After the R2 verified Client repairs the principal performed a second managed Client restart (no Agent source change since its restart) and confirmed the runtime remained on Task 106 with the same Home/endpoints and a reconnected Client.

### G10 — Integrated Regression Proof and Delivery Readiness

Final closure depends on G6–G9; this gate does not authorize a live runtime switch, implementation delivery or merge. At the user's request, advance the Agent-only runtime-readiness subset below before G9. Do not misreport that subset as completion of G9 or final G10.

#### Early Runtime-Readiness Checkpoint — Conditionally Authorized Handoff

- [x] Independently review/repair G8 and its interactions with G6–G7. Preserve actual thinking directives and stored choices, canonical history, claim ownership and failure containment; resolve current diff-integrity issues. — Completed during the Wave B review; diff-integrity warning resolved; evidence in `temp/106-implementation/wave-b-review.md`.
- [x] On a frozen Agent candidate, complete Agent analysis, focused regressions and the required Agent fast suite once, with retained logs/exit status/durations and content hashes. If later production changes invalidate it, name the invalidation before a rerun. — Analyzer exit 0; 142 focused tests exit 0 (7s) and fast suite 2798 passed / 14 skipped exit 0 (64s) at first freeze; named invalidation: the principal-triage bridge bounded-logging production edit; single re-verification of the repaired candidate: 143 focused tests (7s), fast suite 2799 passed / 14 skipped (72s), daemon E2E 6/6 (62s), 26 content hashes per revision — `temp/106-implementation/runtime-readiness.md`.
- [x] Run `agent/e2e_test/context_compaction_daemon_e2e_test.dart` with temporary test Homes and the deterministic fixture provider. Extend existing coverage as needed to prove real daemon startup, structured-result compaction, rejected thinking preparation without process exit or preference mutation, a responsive subsequent/sibling command, and failure/history consistency. Do not use the user's Home/database or provider credentials. — 6/6 tests exit 0 (48s); F.53.5/F.53.6 added for structured-result compaction and contained thinking rejection — `wbreview-e2e-daemon2-20261018-061821.log`.
- [x] Close the remaining G7 real-adapter wire/attachment gaps with fixture HTTP capture at actual adapter builders, not codec-only calls; identify synthetic carrier coverage accurately and do not claim live vendor acceptance. — `compaction_adapter_wire_closure_test.dart` (5 tests, exit 0); synthetic MockClient carrier explicitly recorded; no live-vendor claim.
- [x] Verify Client analysis/build prerequisites for the proposed source pair without launching or changing the primary pair. Record any untested bootstrap/platform prerequisite or remaining safety blocker explicitly. — `fvm flutter analyze` exit 0 (6.2s), no client source change; principal target setup and macOS driver debug build subsequently passed (103349ms); pair launch and UI acceptance remain unperformed. The generated lock artifact was restored, and Client source is unchanged.
- [x] Principal independently verifies the frozen candidate and reports either a blocker or bounded source-handoff readiness, with changed-file hashes, test evidence and G9/final-G10 limitations. Stop all source writers while a handoff decision is pending; do not continue changing a source candidate the user may switch to. — Principal independently verified the repaired freeze: 22 Agent/test hashes matched, 50 focused tests passed, 6 isolated daemon tests passed, Agent analysis clean; target setup, Client analysis and macOS driver debug build passed. Source writers/reviewers stopped. G9/final G10 remain incomplete; no live-provider acceptance is inferred from fixture tests.
- [x] After the frozen candidate is ready and all writers/reviewers stop, the principal may execute the user's explicitly authorized handoff: current runtime to the Task 106 worktree. The user confirms no other sessions are active; all attached clients/sessions reconnect, as disclosed. Run canonical status from the current source immediately before, invoke the handoff from the target, and run target status afterward. The original switch result is authoritative. Any changed target, uncertain ownership, additional active sessions or failed/rolled-back handoff requires fresh confirmation before another attempt. Do not mutate the user's Home directly. — Executed by the principal after checkpoint `023d4593`: original result `Switch complete`; target status confirms the Agent and sole switch-capable macOS Client source/branch match Task 106, original Home and gateway/VM endpoints retained, no cross-owned or unverifiable clients. Do not repeat this handoff.

#### Post-Handoff Live Receipt

- [x] Inspect automatic compaction before any manual compact: requester operation `trigger=auto`, `status=completed`, one summarization attempt, 95296ms; Agent lifecycle and Client receipt confirm completion and the same turn resumed tool execution. Selected model/thinking remain unchanged.
- [x] Keep measurement kinds explicit: before 395936 tokens (`mixed`), estimated after 45187, provider-confirmed after 47541, budget 252880, threshold 227592, retained tail 20143. The later confirmed usage rose normally as this continuing turn loaded tools/docs. Source range still contains 351 active rows and retained tail 57 rows; four root-user rows are present and active. This proves prefix/tail presence, not a byte-for-byte pre/post checksum (none was captured).
- [x] User-supplied tooltip screenshot independently matches the durable operation: automatic completion, confirmed after 47541 / 18.8%, history-before 395936 / 156.6%; this is acceptance of this success case only, not G9 failure UX or all G10 scenarios.
- [ ] Triage the non-fatal auxiliary `LLMRequestDumper` warning (`lastDumpFilePath is null`) observed once during compaction completion. Keep any repair scoped to safe request-scoped diagnostic ownership; do not dump raw content or change thinking/compaction policy.
- [ ] Final diagnostics hardening: the bridge containment log still interpolates unconstrained transport correlation fields. Replace those log interpolations with bounded lifecycle/type metadata and allowlisted stage/cause; keep response correlation intact. Add adversarial identifier leakage/length coverage. Name the production edit as frozen-Agent evidence invalidation before re-verification.

- [ ] Exact checkpoint CI run `39095542529` failed on Linux: all 11 containment cases fail during fixture `AuthManager` construction with `home_unprepared`. Repair with an injected isolated/in-memory secret store or a correctly prepared temporary test Home; never use the user's Home, skip the tests or weaken assertions. Retain failed evidence and prove clean-environment red/green. This environment invalidation requires new focused/fast evidence at the repaired freeze. — Fixture repaired in the reviewed change with an injected `MemoryAgentSecretStore` (assertions untouched) and proven red/green under an isolated missing-Home environment: 11 `home_unprepared` failures (1961ms) → 11 passes (1162ms), isolated path never created — `temp/106-implementation/wave-c-review.md`. Agent focused/fast at the repaired freeze and CI confirmation remain pending.
- [x] User-supplied configuration was inspected read-only: model limits 258000/358000, threshold 0.9, targetRatio 0.1. Source confirms `targetRequestTokens` is derived from the ratio, but `ContextCompactionEngine.prepareSelection` uses it as a retained-tail budget; `buildCandidate` constrains retained tail against that target and the full request against the effective input budget. Summary/system/runtime/tool overhead remains additive. Thus confirmed full-request 18.8% alone is not a target-policy failure. Preserve configuration and thinking; delegate documentation clarification of the existing semantics with G10, not a policy redesign.

#### Final Integrated Acceptance

- [ ] Run relevant Agent/Client analyzers and focused suites. Run each required full fast suite once on a frozen shared-boundary candidate; retain unique logs, exit status and elapsed duration, distinguishing SDK/bootstrap, baseline-suite and added-test costs.
- [ ] Add daemon-backed deterministic coverage for manual/auto/overflow rich-result and attachment compaction, rejection before claim, contained async failure, sibling-session responsiveness, durable failure hydration and restart cleanup. Use temporary Homes and a fixture provider, never the user's live database/provider; serialize only tests binding shared ports/resources.
- [ ] Demonstrate red/green at the owning structured-result boundary and negative tests proving that actual thinking directives and persisted choices never change as error recovery. A passing legacy-only suite is not evidence of the repair.
- [ ] Update `docs/technical/context_compaction.md`, `docs/agent_engine/context_compaction_design.md`, `docs/qa_maintenance/context_compaction_qa.md` and relevant protocol/adapter guidance when their contracts change. Review closest owning contracts; update only stale laws. Refresh the graph after product code changes.
- [ ] Complete independent review using the user-designated native Sanad reviewer (`OpenCode Go / deepseek-v4.1-flash`, separate session; max if supported, otherwise default). Keep review, automated verification, principal-owned live acceptance and delivery status separate; no worker may substitute for the principal's UI acceptance.
- [ ] After fresh live authorization, the principal verifies successful image/rich-result compaction and a clearly explained rejection with the existing configured provider and selected thinking level. The principal may use the recorded conditional source-handoff and PR-delivery authorizations; actual merge and protected labels still require their own explicit authorization.

## Acceptance Criteria — Historical G1–G5 Receipts

- [x] Typing `/compact` while another compaction is running displays `"Context compaction is already in progress."` in the client UI, not `"Context compaction could not start."`.
- [x] If a compaction fails for a specific reason (e.g. `source_revision_stale`, `session_busy`), the client displays the specific failure reason.
- [x] Killing or restarting the agent daemon while a compaction is active does not permanently lock the session; upon daemon restart, the session can immediately run `/compact` or send messages.
- [x] Token estimation for long conversations with thinking/reasoning models (like ChatGPT Codex) matches within a reasonable margin of actual provider token usage, rather than inflating by 6x+.
- [x] In `CompactionEventTile`, the `Retained tail` token count never exceeds the `After compaction` token count.
- [x] Context reclaimed percentage is mathematically consistent and never derived from mismatched estimated vs. confirmed bases.

## Definition of Done — Active Amendment

- [ ] G6–G10 completed with acceptance evidence, not merely authored code; original G1–G5 regressions remain green.
- [ ] Required analyzers, focused/full-fast and daemon-backed suites pass with bounded output, retained exit status, logs and timing evidence.
- [ ] Actual thinking directives and stored user choices are unchanged; failures preserve history and cannot terminate the daemon.
- [ ] Toast and timeline show safe, localized stage/cause explanations live and after history hydration.
- [ ] Relevant docs and graph maintenance are complete after product changes; current grounding obligations are audited against the finished behavior.
- [ ] Independently reviewed and principal-owned live acceptance recorded separately from automated verification; delivery status and user authorization boundaries remain explicit.
- [ ] Existing Draft PR is the single delivery vehicle if later authorized; no new numbered task or duplicate PR is created for this amendment.

Execution checkpoint: implementation and automated verification proceed in ordered waves with native Sanad review. The principal's source handoff is conditionally authorized after readiness, and delivery through the existing PR to a verified Ready-to-merge state is authorized. Preserve actual merge/protected-label boundaries, frozen-candidate evidence and primary runtime safety.
