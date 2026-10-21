---
title: "Context Compaction Architecture"
description: "Ownership boundaries, vocabulary, and wire-safety rules for durable goal-preserving context compaction (Plan 53)."
---

# Context Compaction Architecture

This document is the technical design owner for Plan 53 compaction. It defines
ownership boundaries and shared vocabulary consumed by tasks 53a–53g. Runtime
laws remain in `agent/lib/engine/AGENTS.md`; this page holds design detail only.

## 1. Prototype Retirement Inventory (Task 53a Gate A0)

The experimental `ContextEngine` must be removed before any production compaction
path ships. The following references were audited on 2026-08-29.

### 1.1 Production code (removed in Gate A1 — 2026-08-29)

| Location | Former role | Status |
|---|---|---|
| `agent/lib/engine/context_engine.dart` | Prototype engine | **Deleted** |
| `agent/lib/engine/agent_runner.dart` | `compressIfNeeded` in sync/stream loops | **Removed** |
| `agent/lib/core/di.dart` | `ContextEngine` singleton | **Removed** |

### 1.2 Tests and generated mocks (removed in Gate A1)

| Location | Status |
|---|---|
| `agent/test/engine/context_engine_test.dart` | **Deleted** |
| `agent/test/engine/context_engine_test.mocks.dart` | **Deleted** |
| `agent/test/core/di_live_default_adapter_test.dart` | **Updated** |
| `agent/test/interfaces/interfaces_test.mocks.dart` | **Regenerated** |
| `agent/e2e_test/sanad_gateway_platform_e2e_test.dart` | **Updated** |

### 1.3 Documentation corrected (Gate A1)

| Location | Status |
|---|---|
| `docs/technical/agent_runtime.md` § Context Compaction | **Updated** |
| `docs/technical/provider_protocol.md` | **Updated** |
| `agent/lib/plugins/AGENTS.md` | **Updated** |

### 1.4 Out of scope for prototype removal

| Location | Why it stays |
|---|---|
| `agent/lib/engine/agent_context_assembler.dart` | System prompt assembly; unrelated to history compression |
| `AgentRunner.getContextTokens()` / `_buildContextUsageSnapshot()` | Provider context limit and latest usage projection |
| `agent/lib/engine/runtime/turn_route_state.dart` | Per-turn route resolution for adapters |
| Provider adapters `getContextLimit()` | Wire/model metadata; consumed by pressure evaluation later |
| `client/` context usage indicator | Renders daemon `context_usage` events only |
| Fake slash commands in `local_workspace_runtime_service.dart` | Removed in task 53e, not 53a |

## 2. Non-Impact Proof (Gate A0)

Removing `ContextEngine` does **not** alter these independent paths:

### 2.1 `AgentContextAssembler`

- Builds one ephemeral system message per model request from stable/context/volatile tiers.
- Never reads or writes conversation `history`.
- Prototype compression mutated `history` in place before assembly; removal stops that mutation only.

### 2.2 Context-usage metrics

- `MetricsTracker` accumulates turn usage; `AgentRunner._buildContextUsageSnapshot()` projects latest provider-reported input against the active route's context window.
- Compaction-summary usage reuses the same canonical provider normalization as
  ordinary turns, including nested `input_tokens_details.cached_tokens` and
  nested cache-write/reasoning details; absent provider values remain absent.
- Prototype compression did not feed usage metrics; it only replaced message lists before the provider call.
- Latest provider-reported input usage for the same route and measured request
  material is the authoritative pressure baseline. Adapter-owned wire
  fingerprints prove the extension, and only the appended wire suffix is
  estimated; a rough full-request estimate must not override that confirmed
  value. Route, prompt, schema, or measured-prefix changes invalidate the
  baseline. After daemon restart, the runner may recover the latest persisted
  assistant usage only by rebuilding the exact request prefix that produced that
  assistant response. The timestamped per-model-step `context_usage` snapshot is
  the authority there, because the generic `usage` map on the same row is a
  mutable run value that can disagree with the frozen per-call snapshot;
  `usage.input_tokens` remains a legacy fallback. Route identity follows
  authority: a provider/model identity present in the `context_usage` snapshot
  wins, so a matching mutable legacy `provider`/`model` value never overrides a
  mismatched snapshot; a recorded identity that is absent or empty never
  matches, and candidate aliases themselves are never null. Production
  `BaseOpenAIAdapter` implements `WireInputUsageMeasurer` and
  `WireInputTokenEstimator` by reusing its canonical request builder,
  ensuring generic OpenAI-compatible routes participate in wire measurement
  without alternate codecs or transport-counting discrepancies.
- A baseline recovered from persisted usage requires a compact versioned
  non-content proof (`wire_proof`, format `v1:<sha256>`) that binds the
  confirmed input to the complete ordered wire items (`inputItemFingerprints`),
  stable material (`stableMaterialFingerprint`), and safe route signature. The
  live producer writes `wire_proof` into the frozen per-step `context_usage`
  snapshot. On restore after restart, the active adapter remeasures the exact
  historical request prefix preceding the assistant row; the baseline is
  restored only if the adapter exposes `WireInputUsageMeasurer`, the row
  carries a valid `wire_proof`, the persisted proof matches the remeasured
  prefix and route signature, and the current request extends that
  prefix on the same route (`extendsMeasurement`). Unsupported/no-measurer
  adapters, legacy unbound rows without `wire_proof`, and any drift in route,
  prompt, tool schemas, or historical message content fail closed to explicit
  estimates. There is no unproven floor: prospective pressure is calculated
  from the remeasured extension delta (`wireMeasurement.estimatedTokens -
  baselineWire.estimatedTokens`), and a wire-measured baseline is consumed only
  while the live remeasurement keeps proving that extension. If the proof stops
  holding — for example a wire-visible request option such as a thinking
  directive changes — admission falls back to the explicit estimate until a new
  provider response supplies a fresh binding; the in-memory message comparison
  remains only for routes whose adapter exposes no wire measurement at all.
  Stale receipts recorded before an activated compaction boundary are discarded
  by the same material proof, so no wall-clock recency heuristic is needed.
  Metadata-only bookkeeping changes on earlier
  messages do not alter the wire payload or item fingerprints and thus do not
  falsely invalidate valid pressure. Cached input tokens remain part of the
  confirmed input and are never discounted, and confirmed pressure that already
  exceeds the threshold still triggers automatic compaction.
- Adapter wire measurement prices only model-visible material: text uses the
  text rate, and provider-owned opaque state — Codex reasoning
  `encrypted_content` replay — is excluded entirely, because the provider prices
  it under its own token models rather than as request text. Encoded media
  transport (data URIs and long base64 blobs) is never priced as text; image
  material is priced separately from its canonical, dimension-bearing history
  (a base charge plus a tile charge per image after the model's edge and
  minimum-short-side fit). Only `low` detail is charged the base rate: canonical
  `ToolImageDetail.original` reaches the wire as `high` and is priced on the
  tile grid. The fitted grid is clamped to the per-image ceiling, so a thin or
  panorama image that would otherwise scale to an unbounded tile grid stays
  bounded, and a fitted thin side that rounds to zero keeps one pixel instead
  of producing a non-finite scale. An image without recorded dimensions is
  bounded by the same per-image ceiling instead of its transport size, and
  declared `media_bytes` keep byte-based accounting. The estimate therefore never charges
  the serialized transport for opaque replay or encoded media, and confirmed
  baseline deltas reuse that same basis. Ordering fingerprints are unchanged,
  so a baseline measured on a different (for example pre-repair) pricing basis
  yields a non-extending or negative delta and is discarded instead of mixing
  stale usage into the prospective estimate.
- Provider/model text injected into the volatile system tier comes from the
  resolved route identity, not response-metrics display state. A provider
  response therefore cannot mutate the next request prefix and invalidate an
  otherwise applicable confirmed baseline.
- The retained-tail start row is the durable projection split anchor. Recovery
  or edit may replace the old tail end with higher AUTOINCREMENT rows; while
  the start survives, projection includes every current row from that anchor
  onward. Partial mutation of the summarized source or loss of the tail start
  still fails closed.

### 2.3 Provider context-limit resolution

- `LLMAdapter.getContextLimit(model)` and `AgentRunner.getContextTokens()` stay on the turn route.
- Prototype used the same adapter hook but will be replaced by `RequestPressureSnapshot` (53c) without removing adapter APIs.
- Task 53g makes `SANAD_HOME/config.yaml` the only user-owned non-secret override.
  Runtime resolution uses the exact normalized override first, then the selected
  model's `context_window` from the revision-matched catalog cache of the same
  provider instance, then adapter/provider metadata and its bounded fallback.
  Catalog metadata never crosses instance, config-revision, or
  credential-revision boundaries. Legacy `CONTEXT_LIMIT` cannot impose one
  window on every model.
- Pressure above threshold is not itself proof that compaction can make
  progress. If the active canonical projection has no source head before its
  retained tail, automatic or forced preparation returns no candidate and the
  model request continues without throwing a range-selection argument error.

## 3. Ownership Boundaries (Gate A0)

Three sources of truth (Plan 53 §4.1):

```text
Canonical conversation history   → evolution/session persistence (unchanged rows)
Compaction boundaries            → new persistence owner (53b)
Active model projection          → builder reading history + latest successful boundary (53b)
```

### 3.1 Component responsibilities

| Owner | Owns | Must not own |
|---|---|---|
| **Pressure evaluation** (`CompactionPressureEvaluator`, 53c) | Prospective full-request token/material estimate for the next provider call; threshold comparison; output reservation and safety buffer | History mutation, boundary persistence, queue, protocol events |
| **Compaction engine** (`ContextCompactionEngine`, 53c) | Transform immutable history snapshot + pressure contract into a typed `CompactionCandidate` or failure; continuity anchor extraction and validation | DB writes, session queue, summarizer HTTP (delegates to injected summarizer port), Flutter |
| **Persistence** (`CompactionBoundaryRepository`, 53b) | `compaction_id`, source revision, lifecycle (`started`→`completed`\|`failed`), CAS activation, internal summary storage, metrics | Pressure decision, provider wire serialization, run admission |
| **Model projection builder** (53b) | Read canonical history + latest **successful** boundary; emit summary anchor + verbatim tail + post-boundary messages for provider assembly | Summarization, queue drain, slash commands |
| **Runtime orchestrator** (`SessionRunOrchestrator` + compaction coordinator, 53d) | Exclusive session claim, serialization of concurrent compactions, FIFO queue during compaction, terminal session state, overflow recovery trigger | Summary prompt design, DB schema design |
| **Protocol / interfaces** (53d/53e) | Lifecycle events to clients (`context_compaction.started` / `.completed` / `.failed`); slash-command dispatch for `/compact`; redacted detail payloads | Summary text, compression policy, pressure thresholds |
| **`AgentRunner`** | Conversation history for the active turn, model loop, tool loop, `AgentContextAssembler` invocation, attaching projection output to provider requests | Direct summarization, boundary activation, hidden in-memory history replacement |

### 3.2 `AgentRunner` vs new services

- Today `AgentRunner` previously delegated compression to the removed prototype
  and assigned the returned list to `history` — a hidden mutation the new design
  forbids. That path is gone as of Gate A1.
- After 53d, `AgentRunner` requests an **active model projection** from the projection builder before each provider call. Canonical `history` remains intact; only the ephemeral request payload shrinks.
- Compaction trigger policy (auto/manual/overflow) lives in the orchestrator layer, not in `AgentRunner` loop internals.
- No shared ambiguous field on `AgentRunner` for both history and compaction state; a dedicated `CompactionCoordinator` (name fixed in 53d) holds in-flight operation identity.

## 4. Shared Vocabulary (implemented in 53a Gate A2)

Provider-neutral domain types live under `agent/lib/engine/compaction/` (owner: engine package, no Flutter imports). Import via `package:sanad_agent/engine/compaction/compaction.dart`.

### 4.1 `CompactionTrigger`

```dart
enum CompactionTrigger { manual, auto, overflow }
```

### 4.2 `CompactionStatus`

Terminal states are explicit; no implicit "active" beyond `started`.

```dart
enum CompactionStatus { started, completed, failed }
```

### 4.3 `CompactionFailureReason`

Typed, redactable failures for persistence and protocol. Initial set:

| Value | Meaning |
|---|---|
| `sessionBusy` | Manual `/compact` while a run is active |
| `compactionInProgress` | Second manual request during in-flight compaction |
| `claimLost` | CAS / exclusive claim failed (stale or concurrent) |
| `sourceRevisionStale` | History changed after snapshot freeze |
| `summarizationFailed` | Summarizer error or timeout |
| `continuityValidationFailed` | Summary missing required anchor coverage |
| `projectionStillOverBudget` | Post-compaction request estimate still above threshold |
| `persistenceFailed` | Boundary commit failed |
| `interrupted` | Restart with non-terminal `started` row |

### 4.3.1 Safe Diagnostics (`CompactionFailureStage` & `CompactionFailureCause`)

Plan 106 Gate G8 introduces allowlisted, typed failure diagnostics carrying stage and cause across:
1. Command Result (`SessionCompactResult` via `sessionCompactResult` envelope payload: `failure_stage`, `failure_cause`).
2. Live Lifecycle Broadcast (`CompactionLifecycleEvent` via `contextCompactionFailed` canonical event: `failure_stage`, `failure_cause`).
3. Historical Timeline Hydration (`SessionQueryHandler._compactionLifecycleHistoryRow`: `failure_stage`, `failure_cause` extracted from durable `failure_detail_json`).
4. Durable Persistence (`session_compaction_operations.failure_detail_json`: `{"stage": stage, "cause": cause, ...}`).

#### Allowlisted Stages (`CompactionFailureStage`)
- `preparation`: Pre-claim validation, runner initialization, thinking selection validation, admission checks.
- `pruning`: Message and tool-result pruning before summarization, including projection budget handling.
- `provider`: Summarizer model invocation (timeouts, rate limits, network, provider HTTP codes).
- `validation`: Continuity anchor validation.
- `persistence`: Database commit, boundary CAS, or activation failure.

#### Allowlisted Causes (`CompactionFailureCause`)
Allowlisted non-sensitive identifier strings representing exact failure modes without leaking raw exception bodies, secrets, paths, user content, or HTTP payloads:
- Preparation: `session_busy`, `compaction_in_progress`, `invalid_request`, `unavailable`, `session_not_found`, `thinking_capability_unsupported`, `thinking_capability_unknown`, `thinking_option_unavailable_for_route`, `thinking_route_instance_not_found`, `route_resolution_failed`, `preparation_failed`.
- Pruning: `tool_result_malformed`, `pruning_failed`, `projection_still_over_budget`, `recovery_capacity_exceeded` (Task 117: the bounded recovery summarizer needs more chunks than configured; decided before any recovery provider call).
- Provider: `timeout`, `rate_limited`, `overflow`, `invalid_response`, `network_error`, `provider_error`, `summarization_failed`, and the Task 118 failed-summary shapes `summary_empty`, `summary_reasoning_only` and `summary_truncated` (§8.11.1).
- Validation: `continuity_validation_failed`.
- Persistence: `source_revision_stale`, `claim_lost`, `stale_operation`, `superseded`, `missing_message_rows`, `database_error`, `persistence_failed`, `interrupted`.
- Fallback: `unexpected_error`.

### 4.3.2 Client Explanatory Feedback & Safe Next Actions (Gate G9)

Plan 106 Gate G9 maps allowlisted stage and cause diagnostics into user-actionable, localized feedback:
1. **Reusable Resolution:** `CompactionFailureFormatter` in `client/lib/features/conversations/presentation/utils/compaction_failure_formatter.dart` normalizes wire fields (accepting both canonical `snake_case` and legacy `camelCase`) and resolves one `CompactionFailureExplanation` containing:
   - `explanation`: Localized statement of what failed.
   - `nextAction`: Localized guidance on safe next actions.
   - `toToastMessage()`: Combined message used for manual `/compact` error toasts.
   - `toDetailLines()`: Formatted `Failure:` and `Next action:` lines rendered in `CompactionEventTile` tooltips.
   - Fallback authority: without an ambient localization the resolver reads the generated English localization (`AppLocalizationsEn`), so `app_en.arb` remains the single copy authority and no English failure copy is duplicated as Dart literals.
2. **Failure Categorization:**
   - **Preparation & Thinking Validation:** Distinguishes unsupported thinking modes (`thinking_capability_unsupported`, `thinking_capability_unknown`, etc.), busy sessions, duplicate in-progress operations, and invalid requests.
   - **Pruning:** Distinguishes malformed tool results from unresolvable over-budget projections (`projection_still_over_budget`) and from a session too large for bounded recovery (`recovery_capacity_exceeded`, whose next action is to start a new session or switch to a larger-context model).
   - **Provider:** Distinguishes timeouts, rate limits (HTTP 429), context overflow, invalid responses, network errors, and generic provider errors. Task 118 adds an empty summary (`summary_empty`), a reasoning-only response with no summary (`summary_reasoning_only`) and a summary cut at the model output limit (`summary_truncated`), each with its own English and Arabic explanation and next action.
   - **Validation:** Distinguishes continuity anchor failures (`continuity_validation_failed`).
   - **Persistence:** Distinguishes stale revisions, superseded claims, daemon restarts (`interrupted`), and storage write errors.
   - **Unclassified:** `unexpected_error` (and any unknown cause) renders the honest fallback explanation and retry action; it never inherits the provider default explanation, because the Agent defaults the stage to `provider` when no stage hint existed. A stage the Agent explicitly asserted keeps its stage-specific explanation.
3. **Multilingual Parity:** English (`app_en.arb`) and Arabic RTL (`app_ar.arb`) keys provide natural translations without hardcoded widget literals. Widget and test expectations are resolved through the localization system — handwritten Dart carries no Arabic literals, including tests (root localization law), and the English timeline tile copy is locked through the localization delegates.
4. **History & Live Parity:** `UnifiedDeviceMapper` parses `failure_stage` and `failure_cause` from both live `context_compaction.failed` envelopes and hydrated historical rows (`session.query`), ensuring reopening a conversation reproduces the exact same explanation as the original event.
5. **Redaction & Safety:** Client feedback never renders raw exception messages, stack traces, file paths, or provider bodies.

### 4.3.3 Manual `/compact` Acknowledgement Timing (Task 119)

The daemon's `SessionRunOrchestrator.handleCompactCommand` awaits `CompactionCoordinator.runCompaction` before the handler emits `session.compact_result`, so the result carries the terminal outcome (`accepted` means completed) rather than admission. Busy, in-progress, unavailable and invalid-request rejections still return before any provider call. A provider summary can therefore outlive the Client's request window; the Client owns truthful presentation of that gap:

1. **One dispatch, unchanged window:** `ConversationCommands.compactSession` sends `session.compact` once with the gateway's 10-second acknowledgement window (`defaultCompactAcknowledgementTimeout`); the global gateway timeout is not raised, and a timeout never resends.
2. **Pending, not failed:** an unacknowledged dispatch returns `SessionCompactResult.pendingOutcome`. The composer shows the neutral localized `compactionPendingStillRunning` notice (info toast, not an error) and releases the runtime action; a later explicit `/compact` is a new user intent that the daemon admits or rejects (for example `compaction_in_progress`).
3. **Late correlation:** a listener registered before dispatch matches the late `session.compact_result` by exact `session_id` and `request_id` and settles at most once (duplicates and other requests or sessions are ignored). Without a match inside `defaultCompactSettlementWindow` (10 minutes) or when the event stream closes, it settles as `unconfirmedOutcome`, which is unknown rather than failed and shows nothing further.
4. **Real outcome:** a late failure or rejection shows the same `CompactionFailureFormatter` toast as an on-time one, exactly once, and only while the composer still shows the requesting session. A late success shows no toast. The `context_compaction.started|completed|failed` lifecycle tiles remain the durable timeline and history surface in every case.

### 4.4 `CompactionPressure`

Input to the engine; produced by pressure evaluation only.

| Field | Purpose |
|---|---|
| `routeSignature` | Provider instance + model for this measurement |
| `contextWindowTokens` | Active model limit |
| `outputReservationTokens` | Reserved completion budget |
| `safetyBufferTokens` | Central testable headroom |
| `estimatedRequestTokens` | Full next-request estimate (history projection + system + tools + media) |
| `confirmedInputTokens` | Latest provider-reported input, if any |
| `measurementKind` | `estimated` \| `confirmed` \| `mixed` |
| `exceedsThreshold` | Derived boolean for orchestrator |

### 4.5 `CompactionCandidate`

Immutable output of a successful engine pass **before** activation.

| Field | Purpose |
|---|---|
| `compactionId` | Pre-assigned identity matching persistence row |
| `sessionId` | Owning session |
| `trigger` | `CompactionTrigger` |
| `sourceRevision` | History revision at freeze time |
| `sourceRange` | Stable message identities summarized (not list indices) |
| `retainedTailRange` | Verbatim tail identities |
| `internalSummary` | Validated structured summary (not a `Message`) |
| `continuityResult` | Anchor coverage validation outcome |
| `metrics` | Before/after token estimates, reclaimed amount, duration placeholders |
| `routeSignature` | Summarizer route used |

### 4.6 `CompactionOutcome`

Terminal result visible to orchestrator and protocol mappers.

| Field | Purpose |
|---|---|
| `compactionId` | Operation identity |
| `status` | `CompactionStatus` |
| `trigger` | Original trigger |
| `failureReason` | Set when `status == failed` |
| `candidate` | Present only when `status == completed` and activation succeeded |
| `queuedMessagesAccepted` | Count accepted during operation (orchestrator-owned) |

### 4.7 Summary is not a message

- `internalSummary` is never persisted as `MessageRole.system`, user, or assistant rows.
- Model projection injects summary content through the projection builder into the ephemeral provider payload only.
- Timeline shows compaction **events**, not summary text (Plan 53 §4.7).

### 4.8 Target Ratio and Tail Budgeting Semantics

Compaction policy declares two primary thresholds:
- `threshold`: Context utilization ratio (default `0.90`) of the **full resolved window `W`** at which prospective request token estimation triggers automatic compaction (Task 118: at `W=258000` the trigger is `232200`, not `0.90 × usable 252880 = 227592`). The usable input budget only caps it: when `ratio × W` exceeds usable input, usable input decides the trigger and the decision snapshot records `threshold_capped_by_usable_budget: true` instead of presenting it as the nominal threshold. The snapshot also carries `nominal_threshold_tokens` and `threshold_scope: context_window`.
- `targetRatio`: Ratio (default `0.10`) of the **full resolved window `W`** for the **complete post-compaction request** (Task 118 Stage3A): `targetRequestTokens = floor(targetRatio × W)` (`CompactionTargetPolicy.targetRequestTokens`), so `W=258000` gives `25800`, not `0.10 × usable 252880 = 25288`. Manual, automatic and overflow requests use the same helper. The decision snapshot records `target_scope: context_window`.

#### Exact Semantics in Engine Selection (Task 118 Stage3A)
1. **The target covers the complete next request.** The post-compaction request is `fixed overhead + summary + retained tail`:
   - fixed overhead: the leading system/runtime instructions of the active provider projection plus the tool schemas, kept intact;
   - summary: the generated summary in the form the model projection transmits (`CompactionSummaryProjection.format`);
   - retained tail: the newest connected rows, transmitted verbatim with their media and replay.
2. **Measurement before selection.** `ContextCompactionEngine.measureRequest` measures the fixed overhead and the complete current request. `CompactionCoordinator` gives the engine the active route's wire meter (`CompactionWireMeter`, the adapter's `WireInputUsageMeasurer` with the request's exact tools and options), so both are measured through the route's own codec (`fixed_overhead_measurement: wire_estimate`). A route without wire measurement falls back to the provider-neutral estimate (`estimate`). Selection and the claim stay synchronous after this await.
3. **Tail budget.** `prepareSelection` gives the tail `targetRequestTokens − fixed overhead − summary reservation`, never below zero. The summary reservation is the previous summary's transmitted size when one exists, otherwise `CompactionTargetPolicy.summaryReservationTokens` (2048, the instruction's "about two pages"). The reservation is a planning value only and never enters a reported measurement. The existing progress guard still caps the tail at 50% of the current history tokens. A zero budget keeps only the newest connected exchange (`CompactionTailSelector.minimalTailStart`).
4. **Measured result.** After the summary is generated, `buildCandidate` measures summary and tail on the route's wire (or by estimate) and records in `decision_snapshot`: `fixed_overhead_tokens`, `summary_reservation_tokens`, `tail_budget_tokens`, `summary_tokens`, `retained_tail_tokens`, `estimated_request_tokens_after`, `estimated_target_outcome` (`met` / `not_met`) and `target_feasibility`. The target is `infeasible` when the intact overhead, the summary and the newest connected exchange alone exceed it. That case compacts normally and reports the measured result; nothing is trimmed, dropped or lowered to force a fit.
5. **Hard bounds.** Only two conditions reject a candidate: the post-compaction request does not fit the usable input budget even after projection-only pruning, or it is not smaller than the request it replaces (no progress). Both fail with `projectionStillOverBudget`. A tail above the target is not a failure; it is a measured `not_met`.
6. **Ranges are immutable after the claim.** The summary covers the whole visible conversation, but the source and tail ranges are persisted by the claim before the summarizer runs, and activation keeps them. The tail is therefore not reselected after the summary exists; a summary larger than its reservation is reported through the measured target outcome.
7. **Before-measurement.** The request being replaced is the active projection: its instructions, tools, the previous summary and the rows after the previous source range, never the canonical head behind an eligible boundary. Auto preflight passes its own wire/confirmed measurement; manual and overflow requests use the wire measurement when the route has one.
8. **Target outcome.** The first actual provider-confirmed post-boundary input decides `target_outcome` (§11.4): `met` when it is at most `target_request_tokens`, otherwise `not_met`. Operations recorded under the earlier tail-only `usable_budget` scope stay `unknown`.

## 5. Provider Wire Stripping (Gate A0)

The following must never appear in provider request bodies or adapter-visible message lists:

| Category | Examples |
|---|---|
| Compaction row metadata | `compaction_id`, `source_revision`, trigger, failure diagnostics |
| Internal summary structure | Anchor lists, coverage scores, repair attempt counts |
| Redaction markers | Internal secret placeholders from summarizer input |
| Timeline/event fields | Durations, reclaimed ratios, recovery attempt labels |
| Queue/orchestration state | FIFO depth, continuation tokens, overflow retry flags |
| Canonical-only payloads | Full pre-boundary tool media replaced in projection only |

Allowed on wire:

- One assembled system message from `AgentContextAssembler`
- Projected user/assistant/tool messages (possibly truncated tool **results** in projection only)
- Rolling summary content embedded per projection builder rules (not as a second historical system row)

## 6. Dependency Rules for Downstream Tasks

| Task | May import | Must not import |
|---|---|---|
| **53b** persistence / projection | `agent/lib/engine/compaction/*` types | Summarizer implementation, Flutter |
| **53c** engine | `agent/lib/engine/compaction/*`, adapter interfaces for measurement | `SessionDB`, protocol translators |
| **53d** orchestration | engine + persistence ports | Client widgets |
| **53e** UX | protocol event shapes only | `ContextCompactionEngine` internals |

## 7. Gate A0 Exit Evidence

- [x] Full prototype reference inventory recorded (§1).
- [x] Non-impact on assembler, usage metrics, and context limits documented (§2).
- [x] Ownership boundaries defined without ambiguous `AgentRunner` + service overlap (§3).
- [x] Vocabulary adopted for 53b/53c parallel start (§4).
- [x] Wire stripping rules defined (§5).
- [x] Dependency rules verified: 53b/53c consume stable types without Flutter or cross-layer imports (§6).

## 8. Persistence and Identity Contract (Task 53b Gate B0)

Gate B0 defines storage shape and CAS rules only. SQL migration and repository code
ship in Gate B1.

### 8.1 Current schema audit (2026-08-29)

| Asset | Owner table / API | Compaction relevance |
|---|---|---|
| Canonical messages | `messages(id, session_id, data)` via `SessionDB.getMessages` | **`messages.id`** is the durable identity for `CompactionMessageIdentity`; rows are append-only for compaction (no delete/replace during compression). |
| Session metadata | `sessions` | Holds model/route/title; **`history_revision` is absent today** and must be added in B1. |
| Message writers | `session_execution_state_coordinator` (`INSERT`), `SessionDB.replaceMessages` (identity-aligned in-place rewrite, Task 117) | Normal turns append rows; identity-aligned content and metadata changes preserve row ids; replay/supersession (Task 51) uses `replaceMessages` and must bump `history_revision`. |
| Execution queue | `session_work_items`, `session_pending_runs` | Orthogonal to compaction snapshot; queued user input during compaction stays here until terminal drain (53d). |

`SessionDB.replaceMessages` aligns the replacement list with the active rows
by `message_id`, never by content (Task 117):

1. **Identity assignment.** A message without `message_id` reuses the id of
   the active row at the same position, so in-memory history appended after
   the last reload stays bound to its rows. Positional reuse never takes an id
   that another incoming message carries explicitly: a row inserted
   mid-history (a `HistoryHealer` result) mints a fresh identity instead of
   stealing the displaced row's and being overwritten by it.
2. **Duplicate guard.** Two incoming messages with the same `message_id` throw
   `StateError` before any write; the transaction rolls back.
3. **In-place alignment.** While the existing and replacement ids match, a
   row whose stored JSON differs is updated in place through
   `MessageHistoryIdentity.persist(sqliteId:)`, keeping `messages.id`.
   Unchanged rows are not written. Content transforms (processed-image
   pruning, rejected provider-state clearing, steer stamping, metadata
   attachment) therefore keep every row id and every compaction boundary
   endpoint. Legacy rows without a stored `message_id` align by position only
   with a message that carries no explicit id.
4. **Structural suffix.** The first structural divergence (insertion,
   removal, reorder, identity change) deletes only the *active* rows from that
   point and re-inserts the remaining replacement messages, because
   `messages.id` is the only ordering key. Superseded audit rows are never
   deleted by a replace; re-inserted active rows receive ids above them.
5. `history_revision` is bumped once per replace.

Stored payloads stay opaque: an aligned unchanged row is not rewritten, and a
re-inserted row is re-encoded from its decoded `Message`, so `providerState`
and `metadata` round-trip byte-identically (Task 116 relies on this).
| Runtime notices | `session_runtime_notices`, suspended/pending maps | Unrelated to projection boundaries. |

**Findings:**

1. No existing table stores compaction lifecycle; a dedicated table is required.
2. Prototype compression used `replaceMessages`; production compaction must **never** delete summarized rows.
3. `getMessages` orders by `messages.id ASC` — stable and independent of in-memory `AgentRunner.history` list order.
4. `session_work_items` payload JSON does not participate in model projection source selection.

### 8.2 Identities

| Identity | Type | Rule |
|---|---|---|
| `compaction_id` | UUID text PK | Minted at claim time; stable for lifecycle + protocol events. |
| `session_id` | FK → `sessions.session_id` | One session owns many operations; CASCADE on session delete. |
| `source_history_revision` | non-negative integer | Value of `sessions.history_revision` captured at exclusive claim / snapshot freeze. |
| Source range | inclusive `messages.id` pair | Head summarized by engine; stored as `source_start_message_id` + `source_end_message_id`. |
| Retained tail range | inclusive `messages.id` pair | Verbatim tail; stored as `tail_start_message_id` + `tail_end_message_id`. |
| Route | `RouteSignature` fields | Provider instance + model + template/protocol/base URL + config/credential revisions for metrics only; no secrets in rows. |

Invariant: `source_end_message_id < tail_start_message_id`.

The pair is an ordered bound over rows belonging to the session, not a promise
that every integer between the endpoints exists. `messages.id` is global and
edit/retry suffix replacement leaves valid AUTOINCREMENT gaps.

### 8.3 Lifecycle (`started → completed | failed`)

```text
claim (INSERT started)
  -> summarization + validation (53c, volatile)
  -> activation transaction (B1/B3)
      -> completed (summary + metrics persisted)  => authoritative projection
      -> failed (typed failure_reason)           => prior projection unchanged
```

Range preparation is synchronous and precedes the claim. The claim and
`context_compaction.started` publication both precede every summarizer `await`,
so ordinary input admitted during summarization observes `compacting` and stays
durably queued. Every error after claim closes the same row as failed.

Rules:

1. Terminal transition is **single-writer**: `UPDATE … WHERE status = 'started'`; zero rows updated ⇒ stale/no-op.
2. Terminal lifecycle, ranges, route, summary, and estimates are **immutable**.
   The sole post-terminal mutation is the write-once transition of
   `provider_confirmed_request_tokens_after` from null to the first provider
   input-usage value observed on the same route after activation.
3. Restart with `started` and no terminal row ⇒ classify `failed` with `interrupted`; never activate partial summary.
4. `started` and `failed` boundaries do **not** change active model projection.
5. Only the latest **`completed`** boundary whose ranges still resolve against live `messages.id` values is eligible for projection (see §8.7).

Partial unique index (B1): at most one `started` row per `session_id`.

### 8.4 Minimum durable columns (`session_compaction_operations`)

| Column group | Fields |
|---|---|
| Identity | `compaction_id`, `session_id` |
| Lifecycle | `trigger`, `status`, `started_at`, `completed_at` |
| Snapshot | `source_history_revision`, `source_start_message_id`, `source_end_message_id`, `tail_start_message_id`, `tail_end_message_id`, semantic `tail_end_anchor_fingerprint`, `tail_end_anchor_ordinal` |
| Route | `provider_instance_id`, `model_id`, `template_id`, `protocol`, `normalized_base_url`, `config_revision`, `credential_revision` |
| Metrics | `context_window_tokens`, daemon-owned `effective_input_budget_tokens`, daemon-owned `auto_threshold_tokens`, `estimated_request_tokens_before`, `before_measurement_kind`, `estimated_request_tokens_after`, write-once `provider_confirmed_request_tokens_after`, `retained_tail_tokens`, `duration_ms`, separate summarization input/cached/cache-write/output/reasoning tokens, and attempt count |
| Completed only | `internal_summary_json` (redacted structured summary — **not** a `Message` JSON blob) |
| Failed only | `failure_reason` (enum wire name), optional `failure_detail_json` (redacted diagnostics, never provider wire) |

**Retention:** rows store summary text, numeric ranges, and a one-way semantic
tail-end fingerprint/occurrence only. Canonical message payloads remain solely
in `messages.data`; no duplicate tool/media blobs enter compaction rows. The
fingerprint excludes mutable per-turn metrics and relocates the same logical
anchor when recovery/edit gives its row a new AUTOINCREMENT id.

The completed lifecycle event may be republished with the same deterministic
event id after provider reconciliation. Live clients fold that update into the
existing tile, and history hydration reads the same confirmed value. Later
tool-loop responses cannot replace the first confirmed value.
Client transport deduplication therefore distinguishes exact redelivery from a
same-id payload enrichment: the cache key includes a canonical payload
fingerprint, so the enriched event is applied once without minting a competing
lifecycle identity.

**Session column (B1):** add `sessions.history_revision INTEGER NOT NULL DEFAULT 0 CHECK (history_revision >= 0)`, bumped in the same transaction as message insert/delete/replace.

### 8.5 History revision / CAS

Activation transaction (B3) must verify:

1. `sessions.history_revision == source_history_revision` captured at claim **or** documented supersession rules apply (Task 51).
2. Referenced `messages.id` values still exist for the session.
3. No newer `completed` boundary already committed for the same session with a higher `completed_at` (late stale completion ⇒ no-op).

Queued user messages during compaction do not mutate `messages` until post-terminal drain; therefore `history_revision` should remain stable for the frozen head/tail snapshot while `status = started`.

### 8.6 Timeline, pagination, and Task 47

| Query | Source | Must not |
|---|---|---|
| Canonical transcript pagination | `messages` ordered by `id` | Filter or truncate at compaction boundary |
| Compaction timeline markers | `session_compaction_operations` (+ protocol events in 53e) | Embed summary text in user-visible transcript |

Task 47 consumers paginate **full** canonical history and optional compaction **events** separately. Model projection is never the pagination source of truth.

### 8.7 Coordination with Tasks 51 and 52

**Task 51 — soft rewind / supersession**

When `replaceMessages` structurally inserts, removes, or reorders rows at or before a boundary's tail (identity-aligned content changes keep row ids and never invalidate a boundary, Task 117):

1. Completed rows remain for audit but become **projection-ineligible** via `CompactionBoundaryValidity`.
2. Orchestrator recomputes projection from the newest eligible completed boundary, or full history when none remain.
3. Any in-flight `started` operation whose `source_history_revision` ≠ live revision ⇒ terminal `failed` / `sourceRevisionStale` without activation.

**Task 52 — fork**

1. Forked session with deterministic message-id mapping ⇒ remap range columns or copy boundaries with mapped ids.
2. When mapping is not deterministic ⇒ new session starts with **no** inherited active boundary; canonical history copies without implying projection.

Dart helper: `CompactionBoundaryValidity` in `agent/lib/evolution/models/compaction_operation_record.dart`.

### 8.8 Gate B0 exit evidence

- [x] Schema audit recorded (§8.1).
- [x] Identities and lifecycle adopted (§8.2–§8.3).
- [x] Minimum durable fields + retention defined (§8.4).
- [x] CAS / revision rules defined (§8.5).
- [x] Timeline/pagination independence documented (§8.6).
- [x] Task 47/51/52 coordination rules documented (§8.6–§8.7).
- [x] Contract independent of in-memory list order (uses `messages.id`).
- [x] Row-shape Dart record + validity helper for B1 (`CompactionOperationRecord`).

### 8.9 Gate B1 implementation (2026-08-29)

- Migration: `sessions.history_revision`, `session_compaction_operations`, partial unique index for one `started` row per session.
- Repository: `CompactionBoundaryRepository` + `SessionHistoryRevisionRepository` + `CompactionOperationCodec`.
- History revision bumps wired on `SessionDB.replaceMessages` and message `INSERT` paths in `SessionExecutionStateCoordinator`.
- DI: repositories registered in `agent/lib/core/di.dart`.
- Restart recovery: `recoverInterruptedStartedOperations()` marks orphaned `started` rows `failed/interrupted`.
- Redaction: summary and failure detail pass through `SecretsRedactor` before persistence.

### 8.10 Gate B2 — active model projection (2026-08-29)

| Component | Role |
|---|---|
| `ModelProjectionBuilder` | Reads canonical history + newest **eligible** completed boundary; emits ephemeral provider conversation list |
| `CompactionSummaryProjection` | Formats internal summary as one projected **user** message (`sanad_compaction_summary: true` metadata) |
| `CanonicalConversationTimeline` | Full `messages.id` ordering for UI/audit; independent of projection |
| `CompactionBoundaryValidity` | Eligibility checks; missing source endpoints or missing retained-tail start mark the boundary ineligible (falling back to older boundaries or full history) while numeric gaps between present endpoints remain valid |

Projection rules:

1. No eligible completed boundary ⇒ full canonical history (no summary injection).
2. Active boundary ⇒ `[summary user message] + retained tail verbatim + current rows after the retained suffix`. Projection uses the surviving tail-start endpoint when recovery rewrites the obsolete tail-end row; the semantic tail-end fingerprint is reserved for causal placement of lifecycle events during history hydration.
3. System prompt and runtime overlays remain outside projection; `AgentContextAssembler` owns them per request (53d wiring).
4. Repeated compactions use only the newest eligible boundary; prior summaries are not stacked.
5. Missing source endpoints or a missing retained-tail start in a completed boundary mark that boundary projection-ineligible and emit an invalidation diagnostic (skipping to older boundaries or rule 1 without lockout). A surviving tail start with a replaced tail end remains eligible and projects the replacement suffix. Numeric gaps between present endpoints are valid. `history_revision` is a monotonic write counter; `history_revision_future` means the boundary claims a revision ahead of live history (restore/rollback). After Task 117 only a structural mid-history insert inside a summarized range (or a legacy boundary invalidated before the fix) reaches this rule; content rewrites keep the endpoints. The invalidated record is never repaired or reused as `previousSummary`; a new boundary comes from normal preflight, and a session too large for one request is summarized by the bounded recovery summarizer (§8.12) or fails with `recovery_capacity_exceeded`. Re-anchoring endpoints by `message_id` across structural inserts is Task 118 scope.
6. Compaction row fields and projection metadata never enter provider wire payloads.

DI: `ModelProjectionBuilder` registered after `SessionManager` in `agent/lib/core/di.dart`.

Verification: `fvm dart test test/evolution/model_projection_builder_test.dart` — 23 passed (Task 117, 2026-10-21).

### 8.11 Provider-backed summary request (Task 53i)

Production compaction resolves the exact session route and appends one ephemeral
user instruction to the trigger-owned provider projection. Auto includes the
currently admitted user request; Overflow reuses the exact request projection
that the provider rejected before output; Manual uses the current idle
projection without adding a synthetic conversation turn. The message and the
provider response are never persisted as canonical messages.

The compaction request options are built through a single canonical derivation
(`CompactionRequestFactory.buildCompactionRequestOptions`) shared across manual,
automatic, and overflow triggers. Every `LLMRequestOptions` field is explicitly
accounted for: active route signature, user-selected thinking mode, native thinking
directive, route capability profile/snapshot, attachment store, and transport test seams
(`requestClientFactory`) are preserved verbatim. Compaction correlation overrides
`requestId: 'compaction:...'` and cancellation scopes are verified (clearing expired
or cancelled scopes rather than blindly copying them). Stored thinking choices and wire
directives are never lowered or substituted as an error fallback. User image attachments
are verified through the request's `AttachmentStore` before transmission; missing, corrupt,
or unauthorized media fails specifically before HTTP, preserving the storage jail.

Before summarization, compressible head tool messages are pruned by `CompactionToolPruner`.
For structured tool results (`Message.toolResult`), the pruner derives immutable replacement
`ToolExecutionResult` blocks so `content == toolResult.displayText` strictly holds. Call
identities (`toolCallId`), error flags/codes (`isError`, `errorCode`), schema version, and
metadata are preserved. For summarizer input, media blocks (`ToolImageBlock`) are converted
to text descriptions (`[media omitted for compaction summary: <bytes> bytes]`); for oversized
retained-tail projection, valid image blocks remain untouched without creating invalid empty
image blocks or inventing an unsanctioned image retention policy. Canonical records are never mutated.

The prompt asks for approximately two pages but creates no compaction-only token, byte,
or field-length limit. Its last line forbids tool calls and requires only the final JSON object.
A tool-call response is never dispatched and receives one corrective attempt from the same
immutable base; a second invalid response closes the operation as failed.

#### 8.11.1 Failed summary shapes and pass timeout (Task 118 Stage2)

Every provider pass (full, repair, recovery chunk and reduce) classifies an
unusable response into one safe shape code; provider text never enters the
ledger, diagnostics or logs:

| Shape (ledger `failure_reason`) | Detected when | Terminal cause after the bounded attempts |
|---|---|---|
| `summary_tool_call` | the response carries a tool call | `invalid_response` |
| `summary_truncated` | finish reason `length` or `incomplete` | `summary_truncated` |
| `summary_incomplete` | finish reason `failed` or `cancelled` | `invalid_response` |
| `summary_reasoning_only` | visible content is empty after reasoning markup is removed, and reasoning or markup was returned | `summary_reasoning_only` |
| `summary_empty` | no visible content and no reasoning | `summary_empty` |
| `summary_invalid_json` | the strict JSON parser rejects the text | `invalid_response` |

Each shape gets exactly one corrective attempt from the immutable base; the
failure is stage `provider` with the latest attempt's cause, never a continuity
failure (a parsed summary that misses anchors stays `continuity_validation_failed`).
Every attempt whose response the provider answered keeps that response's
usage and the measured duration in its own ledger entry and in the aggregate
usage, for every shape above, in the main and the recovery paths alike
(invalid JSON included: the provider billed it even though the parser rejected
it). When a recovery pass fails, the failure's `aggregate_usage` includes every
earlier billed chunk and reduce pass of that recovery, not only the failing
pass. A timed-out pass is not repeated: it fails at once with cause
`timeout` and records its elapsed duration.

A non-streamed pass delivers nothing until its whole response arrives, so the
transport's response watchdog (`ProviderWatchdogConfig.connectTimeout`, 90 s
for normal turns) used to cut slow models (Task 117 live acceptance: ~50k-input
recovery passes took 60–71 s on a slow model and a pass timed out).
`CompactionRequestFactory.buildCompactionRequestOptions` now replaces only
that field with the compaction pass timeout from the central config
(`Config.compactionPassTimeout`; default 600 s in
`ModelAwareCompactionPolicy.defaultPassTimeout`, overridable by
`compaction.passTimeoutSeconds` in `config.yaml`, a positive integer). The
first-byte, stream-idle and optional total watchdogs keep their normal-turn
values, and normal turns are unchanged. Streaming the passes was not chosen:
it would change the wire path of every adapter family for one caller, while
the timeout fix is one central option. Run cancellation still interrupts a
pass immediately.

The 16 registered provider templates resolve to four production wire families:
Codex Responses, OpenAI-compatible Chat Completions, Anthropic-compatible
Messages, and Ollama. One adapter-contract suite drives the production
summarizer through all four real request builders with mocked transports and
proves that the final semantic input is the compaction user instruction while
the ordinary tools and routed model remain present. Anthropic may merge that
instruction with an adjacent user message as a final text block, as required by
its alternating-role wire contract. Ollama retains its ordinary compatibility
fallback: only when the endpoint explicitly rejects tool support does the
adapter retry without tools.

Non-terminal provider results cannot activate a summary. Anthropic
`pause_turn` normalizes to `incomplete`, and Ollama `done_reason=length`
normalizes to `length`; both enter the same single corrective attempt and then
fail safely if repeated.

The JSON summary schema is versioned and requires fixed string fields, including
`currentGoal`, `latestUserRequest`, `activeState`, `criticalContext`, and
`remainingWork`. Duplicate/unknown keys and wrong types fail validation. Parsed
content is redacted before persistence. Activation also fences the history
revision, projection revision, and complete route signature.

Compaction performs no cache-specific measurement or prefix enforcement. Cache
behavior is incidental to the ordinary codec/provider request and is neither a
correctness condition nor an efficiency claim. If the full request overflows,
bounded contiguous chunk/reduce recovery (§8.12) preserves tool groups and never
activates partial summaries.

### 8.12 Bounded recovery summarizer (Task 117, 0P-F2)

`ContextCompactionEngine._generateRecoverySummary` runs only after the
ordinary provider request reports `CompactionProviderOverflow`. Its limits
live in `CompactionRecoveryPolicy` (`agent/lib/core/config.dart`; defaults:
safety ratio `0.80`, at most `16` chunks, minimum pass budget `512` tokens)
and are injectable through the engine constructor.

1. **Per-pass budget.** `floor(effectiveInputBudget × safetyRatio)` minus the
   stable system messages, the tool schemas, and the longer of the chunk and
   final instructions, all measured with `CompactionTokenEstimator` (text plus
   model-facing media). The ratio stays below 1 because chars/4 underestimates
   Arabic and CJK text.
2. **Packing.** The pruned source is split into atomic groups (an assistant
   tool-call batch plus its results, otherwise one message) and greedily
   packed, in order, into chunks that fit the budget.
3. **Oversized group.** A group over budget is copied with a deterministic
   head-and-tail text cap per message (budget shared evenly) and an explicit
   `[truncated N chars for summary]` marker. It is never dropped; if it is
   still over budget it forms its own chunk. Canonical rows are untouched.
4. **Capacity.** A pass budget below the minimum, or more chunks than
   `maxChunks`, fails with stage `pruning`, cause `recovery_capacity_exceeded`
   **before any recovery provider call** (only the original overflowing
   request was sent). The Client shows an actionable localized notice.
5. **Split once.** A chunk whose request overflows is halved by group once;
   a half that overflows again, or a single-group chunk, fails with cause
   `overflow`. There is no further bisection.
6. **Bounded reduce.** The eligible `request.previousSummary` (when present)
   precedes the chunk partials. Items are packed into reduce batches within
   the pass budget; each multi-item batch is merged by one partial `reduce`
   pass (`reduce:<n>_<attempt>`), single items carry over, and a level that
   cannot merge any two items fails with `recovery_capacity_exceeded`. The
   last single batch receives the final `reduce:<attempt>` pass with the
   continuity anchors. Every level strictly shrinks the item count, so reduce
   calls are bounded by the number of partials.
7. **Diagnostics.** The decision snapshot records
   `recovery_pass_budget_tokens`, `recovery_source_tokens`,
   `recovery_chunk_count`, `recovery_max_chunks`, `recovery_safety_ratio`,
   `recovery_split_count`, `recovery_reduce_batches`, and
   `recovery_provider_calls`; each pass keeps its ledger entry.

Skipping the ordinary request when it is already estimated to overflow is not
implemented; the reactive overflow remains the only recovery trigger.

## 9. Orchestration and Protocol Contract (Task 53d)

### 9.1 Session lifecycle ownership

`SessionRunOrchestrator` owns session busy/compacting barriers. Compaction does not create a competing source of truth:

```text
idle|running -> compacting (in-memory barrier + durable started row)
  -> completed|failed terminal disposition
  -> drain FIFO queued work on the active projection
```

- Manual `/compact` is admitted only when the session is idle.
- Busy run returns typed `session_busy`.
- In-flight compaction returns typed `compaction_in_progress`.
- Auto preflight and overflow recovery keep the active work item / run authority.
- A failed automatic attempt, Auto preflight or Overflow, opens a breaker for the active run. While it is open neither Auto preflight nor Overflow compaction runs again in that run (Task 118: Overflow used to ignore it), so a later tool-loop step or a provider overflow does not repeat summarizer/provider work; an overflow then takes the ordinary overflow recovery notice. A new run resets the breaker and manual `/compact` remains available.
- Incoming user messages during compaction remain durable queued work and are never folded into the in-flight summary snapshot.

### 9.2 Triggers

| Trigger | When |
|---|---|
| `manual` | Idle `/compact` command |
| `auto` | Prospective pressure preflight at model boundaries |
| `overflow` | Confirmed provider context-overflow before any durable/visible provider output; one retry only |

A successful `overflow` compaction re-projects the provider history from the
newly activated boundary before that single retry, so the retried request is the
reduced projection instead of the failed request; one turn performs at most one
overflow compaction and later tool-loop steps cannot repeat it.

### 9.3 Canonical command and events (D6)

| Wire surface | Shape |
|---|---|
| Command | `compact` via gateway session command handler |
| Catalog type | `runtime_action`; leading-only, no arguments, immediate selection dispatch |
| Events | `context_compaction.started` / `context_compaction.completed` / `context_compaction.failed` |
| Identities | `session_id`, logical `compaction_id`, transition-specific `event_id`, `trigger`, `status` |
| Safe metrics | before/after/retained/window/duration only |
| Failures | typed `failure_reason` wire names; no summary text or secrets |

After local validation, selecting or submitting `/compact` consumes the runtime
command immediately: the client clears the composer, closes slash suggestions,
and persists the cleared draft before awaiting the daemon result. A typed busy,
in-progress, or terminal failure remains user-visible feedback, but command text
is not restored because it is an executed control action rather than an unsent
conversation message.

`CompactionLifecycleBroadcaster` maps engine lifecycle to gateway responses. The
logical operation keeps one `compaction_id`, while each transition has the
deterministic identity `context_compaction:<compaction_id>:<status>`. Live
delivery and history hydration must reconstruct the same transition
`event_id`; started, completed, and failed must never collapse onto the bare
operation id.

History merge uses `retained_tail_range.end` as the causal anchor: the logical
lifecycle row is inserted after that durable message row and before the first
later canonical message. `started_at` and `completed_at` remain display and
audit metadata only; they are not compared against synthetic history message
timestamps.

Live lifecycle delivery is session-scoped. The client accepts a
`context_compaction.started|completed|failed` timeline update only when its
explicit `session_id` matches the active conversation; compaction in a
background conversation must not mutate the visible timeline.

## 10. Compaction LLM Request Dumper Pairing and Isolation

Diagnostic capture of auxiliary compaction exchanges is owned by `LLMRequestDumper` and production provider adapters (`BaseOpenAIAdapter`, `BaseAnthropicAdapter`, `CodexResponsesAdapter`).

### 10.1 Opt-in Activation

Compaction request dumping reuses the standard `DUMP_REQUESTS` environment variable (or `Config.dumpRequests`). When disabled, all dumper calls return immediately with zero I/O or state modification.

### 10.2 Canonical Keying & Pairing

Compaction calls carry an explicit `compaction:`-prefixed `requestId` or `compactionId`. The dumper canonicalizes these through `LLMRequestDumper.compactionKey(compactionId: ..., requestId: ...)`, producing keys formatted as `compaction:<compactionId>:<requestId>` (or `compaction:<compactionId>`).

- **Preflight/Initial dump:** `dumpRequest` with compaction parameters initializes a dedicated dump file `request_dumps/compaction_dump_<safeKey>_<timestamp>.json` with `capture_state: 'initialized'`.
- **Wire dispatch:** `recordActualRequest` updates the dump with resolved wire headers and serialized body, transitioning `capture_state: 'request_sent'`. If an adapter dispatches without a preceding initial dump, `recordActualRequest` auto-creates the compaction dump file.
- **Completion:** `dumpResponse` attaches the sanitized response payload, sets `capture_state: 'completed'`, and clears the active in-flight map.
- **Failure:** Transport errors (socket drop, HTTP error, timeout) caught in adapters invoke `recordError`, writing the sanitized error message and type, marking `capture_state: 'error'`, and removing the in-flight key.
- **Cancellation:** Streaming subscription cancellations execute adapter `finally` blocks invoking `cleanupActiveDump`, immediately removing in-flight tracking from `_activeCompactionDumps` without leaking active map state.

### 10.3 Strict Normal-Turn Isolation and Cross-Request Keyed Fail-Closed Boundary

Compaction requests are strictly decoupled from normal turn exchanges:
- Compaction operations **never** read, write, or overwrite the static `lastDumpFilePath`.
- Normal-turn dumps use `_activeNormalDumps` (keyed by `requestId`) and `_activeUnkeyedNormalDumpPath` (for unkeyed auxiliary exchanges) rather than falling back to an ambiguous global pointer.
- **Fail-Closed on Unknown/Terminal Request IDs:** If a nonempty `requestId` is supplied to `recordActualRequest`, `recordError`, or `dumpResponse` but is not actively registered in `_activeNormalDumps` (e.g., late arrival after turn completion), the call fails closed (`return null`). It never attaches to, overwrites, or mutates another active turn's dump file.
- **Unkeyed Traffic Isolation:** Auxiliary or unkeyed normal traffic (`requestId == null || requestId.isEmpty`) pairs strictly with `_activeUnkeyedNormalDumpPath` or auto-creates an independent dump file; it never attaches to an in-flight keyed normal turn.
- **Retry Attempt Isolation:** Real runner retry attempts generate distinct request IDs (`$turnRequestId`, `$turnRequestId:retry_1`), keeping each attempt's dump file hermetic (attempt 0 records the retriable error e.g. 429, while attempt 1 records completion).
- Active in-flight mappings are tracked only during active execution and cleared upon completion, error, or stream cancellation, preserving hermetic state without speculative memory caches.

### 10.4 Route Metadata, Safe Options, and Durable Dump References

For compaction exchanges, the dump captures the exact route and safe options used for the wire call:
- **Route Metadata:** `provider`, `model`, `base_url`, `protocol`, and `stream` are recorded at initial dump and confirmed upon wire dispatch.
- **Safe Options:** Options are sanitized via `toSafeDumpOptions()`, preserving `thinking_mode`, `thinking_directive`, `timeout_ms`, and `max_output_tokens` without exposing credentials or internal state.
- **Timing and Status:** Dispatches and responses record `status_code`, `duration_ms`, and provider `finish_reason`.
- **Capture Completeness:** Dumper tracks `capture_state` through `initialized` → `request_sent` → `completed` (or `error`). Responses marked incomplete or truncated due to length limits (`length`, `incomplete`, Anthropic `max_tokens`, or `partial_message`) explicitly set `capture_state: 'truncated'` and `truncated: true`. Responses terminating with `failed` or `cancelled` finish reasons or non-200 status codes are explicitly marked `capture_state: 'error'`.
- **Durable Link:** Completed compaction dumps cache their repository-relative path (e.g., `request_dumps/compaction_dump_<key>_<timestamp>.json`), which is persisted directly into the compaction operation record via `diagnostics_json` (`relative_dump_path`). Captures are discoverable by operation and request ID without reading payload bodies.

## 11. Minimal Durable Compaction Diagnostics & Post-Boundary Binding

Task 106 Stage 1 Slice 2 introduces minimal durable diagnostics on `session_compaction_operations`, isolating single-request context occupancy from aggregate execution cost and binding provider-confirmed post-compaction usage to the exact first request using the newly activated boundary.

### 11.1 Additive Persistence (`diagnostics_json`)

Compaction diagnostics are persisted in SQLite on `session_compaction_operations.diagnostics_json` as additive JSON (`CompactionDurableDiagnostics`). This preserves schema backward compatibility without requiring separate event stores or schema migrations. Diagnostics survive daemon restart and database re-open.

The durable record contains:
- `relative_dump_path`: safe relative path to the associated compaction LLM request dump.
- `attempts`: ordered per-attempt summarization ledger entries.
- `aggregate_usage`: total token consumption across all summarization attempts.
- `last_pre_compaction_call`: attribution of the last ordinary provider-confirmed call that preceded the boundary.
- `post_boundary`: exact post-boundary confirmation status and usage receipt.

### 11.2 Per-Attempt Summarization Ledger

When summarization executes (including single-shot, recovery chunk/reduce, or corrective retry passes), each attempt is recorded in the ledger as a `CompactionSummarizationAttemptRecord`:
- **Attempt Identification:** `pass_kind` (`full`, `repair`, `chunk`, `reduce`) and distinct `request_id` formatted as `compaction:[<trigger>:]<compactionId>:<passKind>:<attempt>` (e.g. `compaction:overflow:<compactionId>:full:0`). Recovery chunk passes and intermediate reduce batches add a sequence index: `<passKind>:<index>_<attempt>` (§8.12).
- **Timing:** `duration_ms` for that specific attempt.
- **Provider Usage:** `input_tokens`, `cached_input_tokens`, `cache_write_tokens`, `output_tokens`, and `reasoning_tokens` reported for that call. Missing or unsupported usage stays `null`.
- **Outcome and Failure Cause:** `outcome` (`success`, `validation_failed`, `invalid_response`, `overflow`, `error`) and typed `failure_reason` (an allowlisted code such as the §8.11.1 summary shapes or a cause; never provider text or exception messages).

**Preservation of Legacy Aggregate Semantics & Granular Per-Attempt Attribution:**
- `CompactionMetrics.summarizationInputTokens` (and `session_compaction_operations.summarization_input_tokens`) preserves legacy aggregate semantics, recording the total input tokens consumed across all summarization attempts (aggregate processing cost).
- `diagnostics.aggregateUsage` captures the aggregate breakdown (`input_tokens`, `output_tokens`, `cached_input_tokens`, etc.), while `diagnostics.attempts` provides granular per-attempt attribution and outcome history.

### 11.3 Last Ordinary Call Before the Boundary (Pre-Call Attribution)

The claim transaction binds the last ordinary provider-confirmed call that preceded the boundary into `diagnostics_json.last_pre_compaction_call` (`CompactionPreCallAttribution`). It reuses the usage snapshots already persisted on assistant message rows: `metadata.context_usage` when present, with the legacy `metadata.usage` map normalized through `LlmUsageSnapshot` only as a legacy fallback when `context_usage` is absent. No new table, estimator, event store, or reporting surface is introduced.

- **Identity and time:** durable `message_id`, `request_id` (`<run or turn request id>:<model_step_id>`), `run_id`, `model_step_id`, and the snapshot's `observed_at`.
- **Route and usage authority:** `provider_instance_id`, `model_id`, and only provider-reported `input_tokens`/`cached_input_tokens`. When `context_usage` is present, it is the sole authoritative record; missing input stays missing (`usage_missing`) and mutable turn-level aggregate totals from `metadata.usage` are never spliced into the snapshot. `provider_instance_id` preserves genuine instance UUID provenance rather than collapsing to adapter template/profile aliases, ensuring distinct same-template instances (e.g. `inst-1` vs `inst-2`) are strictly differentiated and truthfully evaluate to `not_applicable` with `route_changed`. An absent or unsupported value is omitted from the JSON instead of becoming zero, an estimate, or a mutable run total.
- **Applicability & Material Equivalence:** `applicable`, `not_applicable`, or `unknown`. Every value other than `applicable` carries a typed reason: `no_ordinary_call` (no assistant row exists yet), `usage_missing`, `identity_incomplete`, `route_changed`, `material_changed` (a completed boundary was activated after the measurement, so the measured material predates the current projection), and `material_unverified` (material equivalence unverified against active prompts/schemas/messages). In the repository claim transaction, without an engine-level prefix remeasurement and material comparison, applicability fails closed to `unknown` with reason `material_unverified`, never claiming `applicable` on syntactic wire-proof hash validation alone.
- **Immutability:** the value is written once in the `started` row and carried unchanged through `completeStarted` and `failStarted`. A later ordinary call, retry, restart, or subsequent compaction cannot replace it, so a pending pre-call is never relabelled from a grown request.
- **Classification of Fork Diagnostics Omission:** When a session is forked, `cloneTerminalOperationsForFork` clones existing terminal compaction operations into the child session with remapped message IDs and new operation UUIDs, but omits `diagnostics_json` (evaluating to `NULL` diagnostics for cloned boundaries in the child session). This omission is intentional and non-blocking: granular diagnostics (`last_pre_compaction_call`, `post_boundary`, `attempts`, `relative_dump_path`) contain parent-session identities (`parent message_id`, `parent run_id`, parent dump files). Omitting unmapped diagnostics prevents parent provenance contamination in the child session while preserving canonical boundary projection (`internal_summary_json`, `retained_tail_tokens`, ranges, route signature).
- **Classification of Failed Compaction Scalar Persistence (F2):** Failed compaction operations persist `NULL` in table columns (`context_window_tokens`, `effective_input_budget_tokens`, `auto_threshold_tokens`, `estimated_request_tokens_before/after`, `retained_tail_tokens`, `summarization_*`, `duration_ms`), preserving decision parameters in `diagnostics_json.decision_snapshot` and attempt token usage in `diagnostics_json.attempts`. Because `ModelProjectionBuilder` queries only completed boundaries (`findLatestCompleted`), failed boundaries are non-projectable; preserving scalars exclusively in diagnostics is safe and non-blocking for Stage 1.
- **Classification of No-Progress Pruning Guard (F5):** When tail pruning produces a post-projection estimate not lower than the pre-projection estimate (e.g. when the newest growth turn holds almost all context), `ContextCompactionEngine` returns `projection_still_over_budget`. While semantically representing lack of compaction progress, this failure cause safely aborts ineffective compaction without inventing protocol causes that would require cross-layer enum, translation, and UI changes.
- **Normal Dump Immutability & Retry Attempt Isolation (F3):** Completed normal-turn request dumps (`capture_state = completed` or `error`) are terminal and cannot be overwritten by subsequent unkeyed auxiliary model calls (such as `TitleService`). Requests in a retry loop maintain attempt-isolated request correlation (`$stepRequestId:retry_$attempt`), preserving both failed attempts (e.g. 429) and completed 200 attempts in distinct files without in-flight dump key collisions.

Two limits stay explicit rather than being guessed. Prompt, runtime-context, or tool-schema drift that never produced an activated boundary is not detectable from durable rows alone, so it is not claimed by `applicable`; and the record diagnoses the measurement that preceded the boundary rather than authorizing its reuse as the next request's baseline. Reuse remains governed by the existing remeasured wire-extension proof in `RequestPressureEvaluator`.

### 11.4 Exact Post-Boundary Binding

Post-compaction usage reconciliation binds immutably to the exact first request and step dispatched against the newly activated compaction boundary:
- **Dispatch Reservation:** `AgentRunner` records the active compaction boundary (`_activeProjectionBoundary`) during prompt projection assembly (`ModelProjectionBuilder.buildForSession`). At dispatch time, before calling the model adapter, `AgentRunner` invokes `CompactionCoordinator.reservePostBoundaryDispatch` using `$turnRequestId:$currentModelStepId` and the active staged request's `routeSignature`. Unrelated replies across restart, retries, subsequent model steps in a multi-step turn, route changes, or repeated boundaries cannot steal or replace this reservation. Route applicability is never invented from the boundary's own signature when the actual request route is unavailable.
- **Completion-Boundary Missing Usage Finalization:** Intermediate streaming chunks and finish-reason chunks with null usage do not trigger missing status, preserving OpenAI-compatible streams that emit a finish chunk before a trailing usage chunk. Arriving usage (including trailing stream chunks) reconciles the boundary. If the provider call or stream terminates without reporting token usage, missing usage is finalized at the runner completion boundary (`no_provider_usage` or `missing_input_tokens`).
- **Retry & Route-Failover Finalization:** When a post-boundary turn encounters a same-route transient failure (such as HTTP 429 rate limit with retry budget), the reservation remains `'reserved'` across attempt-isolated retries as long as the boundary identity is unchanged, reconciling confirmed token usage upon retry success. If a same-route retry activates a newer compaction boundary (or the live boundary identity changes), the abandoned boundary reservation is captured and finalized as missing with reason `'no_provider_usage'`. When a failure triggers a handled auto-failover to a different provider or model route (Route A → Route B), the abandoned route's reservation is explicitly finalized as missing with reason `'route_failover'` (`missingReason: 'route_failover'`) immediately upon recovery, before history preparation. This prevents reservations from remaining indefinitely in `'reserved'` status while strictly forbidding fabricated usage attribution from Route B to Route A's boundary. Subscription cancellations (including client disconnects and executor stop requests cancelling the stream), history preparation failures, restart-drain aborts, and unhandled runner errors that exhaust retry budgets are guarded via finally blocks, stream cancellation hooks, and error handlers to finalize unfinalized reservations with `'no_provider_usage'`. Stop acknowledgement no longer waits for generator unwind (cleanup is deadline-bounded by `RunCancellationScope`). Because the cancelled generator may still be suspended at an await (for example a 429 `waitForRetry`) and unwind after acknowledgement, the detached unwind is contained at the stream boundary (`AgentRunner._cancellableTurnStream`): cancellation signals (`RuntimeRecoveryCancelled`, `RateLimitCancelled`, `ProviderRequestCancelledException`) end quietly, any other unwind failure is logged `SEVERE` by error type only, and nothing escapes to the zone as an uncaught error. The streaming reservation holder is stream-scoped per `streamMessage`/`resumeStream` invocation, ensuring cancellation of one stream never cross-finalizes a concurrent or subsequent stream's reservation on the same runner (while production runners remain factory-scoped per event). Both streaming and non-streaming runner paths observe these exact semantics.
- **Receipt Immutability:** Once post-boundary usage is confirmed or marked missing, subsequent calls with grown history or alternate steps are rejected (`null`) and cannot replace or overwrite the first call's status.
- **Route Mismatch Rejection:** If the dispatched post-boundary request is on a different route than the compaction operation's `routeSignature`, reconciliation is rejected (`null`) and the status remains unchanged.
- **Target Outcome (Task 118 Stage3A):** The first confirmed post-boundary input decides `targetOutcome`: `met` when it is at most the recorded `target_request_tokens` with `target_scope: context_window` (the complete-request target over `W`), otherwise `not_met`. No tolerance is added: the 13% upper result allowed for the observed live case is an acceptance criterion, not runtime arithmetic. Operations recorded under the earlier `usable_budget` tail-only scope, or without a target, stay `unknown`. The occupancy ratio is recorded as `post_input_ratio = inputTokens / W`.
- **Legacy Provenance & Unreserved Fail-Closed Protection:** Operations created prior to diagnostic instrumentation (`diagnostics_json == NULL`) fail closed for dispatch reservation, missing usage recording, and post-upgrade reconciliation attempts; subsequent post-upgrade calls are never synthesized or misattributed as the first post-boundary call. Historical confirmed scalars (e.g. 19,182 tokens) remain immutable without synthesizing diagnostics. Unsolicited replies arriving without prior matching dispatch reservation fail closed (`null`) and leave the post-boundary status in its existing pending state.
