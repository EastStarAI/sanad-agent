---
id: 106
title: Context Compaction Resilience, Protocol Alignment, and Reference-Grounded Token Estimation
status: planned
gate: G1
created: 2026-10-13
branch: fix/106-compaction-resilience-and-token-estimation-repair
evidence_id: 106
evidence_fingerprint: sha256:521e2ac07cf2bec923e9ec68afab079e0b72aefbe883c8e6c28886c4cfee2374
---

# Task 106 — Context Compaction Resilience, Protocol Alignment, and Reference-Grounded Token Estimation

## Goal
Eliminate context compaction failures caused by orphaned database locks, fix the protocol mismatch that prevents the client from displaying compaction failure reasons, ground token estimation in reference-project wire shadowing to prevent massive token overestimation, and ensure consistent, mathematically valid metric display in the Flutter client UI.

## Locked Decisions & Scope

1. **Protocol Wire Alignment:**
   - Compaction failure outcomes must serialize as canonical `snake_case` on the wire (`compaction_in_progress`, `session_busy`, `claim_lost`, `source_revision_stale`, etc.).
   - The Flutter Client's `SessionCompactResult` must accept both `snake_case` and legacy `camelCase` for robust backward and forward compatibility.
   - When an unmapped or failure outcome occurs, `SessionCompactResult` must capture the raw outcome or message instead of dropping it to `null`, ensuring the client UI never shows a generic `could not start` error when a specific reason exists.

2. **Daemon Startup Reconciliation:**
   - Any compaction operation left in `status = 'started'` at daemon boot is orphaned from a killed or crashed prior process.
   - The daemon must run a startup reconciliation pass on `CompactionBoundaryRepository` that transitions all lingering `started` rows to `failed` with `failure_reason = 'interrupted'` and a durable `completed_at` timestamp.
   - This ensures the `idx_session_compaction_one_started` unique index never permanently locks a session out of manual or automatic compaction across daemon restarts.

3. **Reference-Grounded Token Estimation (Hermes & OpenCode Parity):**
   - **Wire Shadowing (Hermes pattern):** Text character estimation (`CompactionTokenEstimator`) must evaluate only model-visible wire content. Internal agent fields (`thought`, `reasoning`), provider state (`codex_reasoning_items`, `encrypted_content`), and internal message metadata must contribute 0 to text character pricing because the provider prices them under its own token models.
   - **Model Projection Input (OpenCode pattern):** Compaction pressure and token budgeting must be computed over the model-facing projected history (`toModelMessagesEffect` equivalent) rather than raw internal database message entities.
   - **Confirmed Token Usage Anchoring:** Compaction pressure must anchor against `ConfirmedInputUsageBaseline` when available, rather than accumulating uncalibrated character-based estimates over thousands of messages.

4. **Client UI Metric Invariant Guardrails:**
   - **Mathematical Invariant:** The retained tail is a subset of the post-compaction request. In `CompactionEventTile`, `Retained tail` must never be rendered with an estimate greater than `After compaction`.
   - When `providerConfirmedRequestTokensAfter` reconciles `After compaction` downward, the retained tail estimate must be clamped or scaled proportionally, or clearly designated as an uncalibrated prior estimate.
   - **Before Compaction Percentage:** When historical uncompacted messages accumulate beyond the context window, clarify that the percentage represents "accumulated history" rather than an active single-turn payload, preventing confusing values like `464.9%`.
   - **Context Reclaimed Calculation:** Must not mix an uncalibrated 6x character estimate with a real provider-confirmed number to display illusory savings (e.g. 99.2%). Reclaimed context must use consistent bases (estimated-before vs estimated-after, or confirmed vs confirmed).

## Reference Grounding

- **Evidence Packet:** `refrence_projects/.sanad-evidence/packets/106.md` (`sha256:521e2ac07cf2bec923e9ec68afab079e0b72aefbe883c8e6c28886c4cfee2374`).
- **Inspected Sources:**
  - `hermes-agent`: `agent/model_metadata.py` (`_wire_message_shadow`, `_estimate_message_tokens_without_images`), `agent/compaction_display.py` (`_COMPACTION_INTERNAL_FIELDS`).
  - `opencode`: `packages/opencode/src/session/overflow.ts` (`isOverflow`, `usable`), `packages/opencode/src/session/compaction.ts` (`estimate`, `select`), `packages/core/src/util/token.ts`.
- **Run Record:** `refrence_projects/.sanad-evidence/runs/106.md`.

## Gate R0 — External Reference Grounding

- [x] حل `evidence_id: 106` عبر workflow التأصيل الخارجي (`.agents/skills/sanad-reference-grounding/scripts/resolve_packet.sh 106`) والتحقق من freshness و fingerprint (`status=ready`).
- [x] قراءة implementations والاختبارات الإلزامية في المصادر المرجعية وتسجيل مصفوفة `Adopt / Adapt / Reject` محلية ومحايدة المصدر.
- [x] تحويل القرارات المقبولة إلى invariants واختبارات صريحة لهذه المهمة (Wire shadowing, usage anchoring, startup reconciliation, wire enum alignment).
- [x] عند غياب الحزمة، تشغيل authoring للحزمة وسجل التشغيل حتى تصبح `ready` (`sha256:521e2ac07cf2bec923e9ec68afab079e0b72aefbe883c8e6c28886c4cfee2374`).
- [x] عدم بدء التنفيذ البرمجي قبل تحقق `ready` وتثبيت العقد السلوكي.

### R0 Exit

- [x] سجل التأصيل يحمل fingerprint والرموز والاختبارات المتحققة والقرارات (`refrence_projects/.sanad-evidence/runs/106.md`).
- [x] لا يحتوي أي ملف متتبع هوية المصدر الخارجي أو مساره؛ يبقى العقد سلوكيًا ومحايد المصدر.
- [x] إنشاء مساحة العمل المعزولة `.agent/worktrees/106-compaction-resilience-and-token-estimation-repair` على الفرع `fix/106-compaction-resilience-and-token-estimation-repair`.

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
- [x] Implement wire shadowing in `CompactionTokenEstimator` (`agent/lib/engine/context/compaction_token_estimator.dart`) following Hermes `_wire_message_shadow`:
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

## Acceptance Criteria

- [x] Typing `/compact` while another compaction is running displays `"Context compaction is already in progress."` in the client UI, not `"Context compaction could not start."`.
- [x] If a compaction fails for a specific reason (e.g. `source_revision_stale`, `session_busy`), the client displays the specific failure reason.
- [x] Killing or restarting the agent daemon while a compaction is active does not permanently lock the session; upon daemon restart, the session can immediately run `/compact` or send messages.
- [x] Token estimation for long conversations with thinking/reasoning models (like ChatGPT Codex) matches within a reasonable margin of actual provider token usage, rather than inflating by 6x+.
- [x] In `CompactionEventTile`, the `Retained tail` token count never exceeds the `After compaction` token count.
- [x] Context reclaimed percentage is mathematically consistent and never derived from mismatched estimated vs. confirmed bases.

## Definition of Done

- All gates G1–G5 completed and checked.
- Agent and client analyzers clean with zero errors or warnings.
- All focused unit and widget tests passing under bounded verification commands (`tail -5`).
- Graphify graph updated via `graphify update .`.
- PR delivered through isolated worktree.
