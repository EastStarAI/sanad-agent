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
- Prototype compression did not feed usage metrics; it only replaced message lists before the provider call.
- Latest provider-reported input usage for the same route and measured request
  material is the authoritative pressure baseline. Adapter-owned wire
  fingerprints prove a strict extension and only the appended wire suffix is
  estimated; a rough full-request estimate must not override that confirmed
  value. Route, prompt, schema, or measured-prefix changes invalidate the
  baseline. After daemon restart, the runner may recover the latest persisted
  assistant `usage.input_tokens` only by rebuilding and adapter-measuring the
  exact request prefix that produced that assistant response. The normal
  strict-extension proof still decides whether the recovered baseline applies
  to the next request, so stale route or wire material fails closed.
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
- Task 53g makes `SANAD_HOME/config.yaml` the only user-owned non-secret override:
  exact normalized `context.modelLimits` first, then live provider metadata,
  current model metadata, and the provider fallback. Legacy `CONTEXT_LIMIT`
  cannot impose one window on every model.

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
| Message writers | `session_execution_state_coordinator` (`INSERT`), `SessionDB.replaceMessages` (semantic-prefix + changed-suffix rewrite) | Normal turns append rows; metadata-only patches preserve row ids; replay/supersession (Task 51) uses `replaceMessages` and must bump `history_revision`. |
| Execution queue | `session_work_items`, `session_pending_runs` | Orthogonal to compaction snapshot; queued user input during compaction stays here until terminal drain (53d). |

`SessionDB.replaceMessages` preserves the longest semantically identical
canonical prefix and its existing row IDs. Exact matches are untouched;
top-level metadata-only changes update the existing row in place; the first
role/content/tool/reasoning/provider-state change deletes and reinserts the
changed suffix. Ordinary appends and response-metadata attachment therefore
keep an activated boundary eligible, while edit/retry still supersedes the
changed suffix and bumps `history_revision`.
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
| Metrics | `context_window_tokens`, daemon-owned `effective_input_budget_tokens`, daemon-owned `auto_threshold_tokens`, `estimated_request_tokens_before`, `before_measurement_kind`, `estimated_request_tokens_after`, write-once `provider_confirmed_request_tokens_after`, `retained_tail_tokens`, `duration_ms` |
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

When `replaceMessages` removes or rewrites rows at or before a boundary's tail:

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
| `CompactionBoundaryValidity` | Eligibility checks; endpoint loss rejects a partially superseded range while numeric gaps between present endpoints remain valid |

Projection rules:

1. No eligible completed boundary ⇒ full canonical history (no summary injection).
2. Active boundary ⇒ `[summary user message] + retained tail verbatim + current rows after the retained suffix`. Projection uses the surviving tail-start endpoint when recovery rewrites the obsolete tail-end row; the semantic tail-end fingerprint is reserved for causal placement of lifecycle events during history hydration.
3. System prompt and runtime overlays remain outside projection; `AgentContextAssembler` owns them per request (53d wiring).
4. Repeated compactions use only the newest eligible boundary; prior summaries are not stacked.
5. Exactly one missing endpoint in the newest completed boundary ⇒ `ModelProjectionException` (no silent reorder fallback). Both endpoints missing skip to older boundaries or rule 1; numeric gaps between present endpoints are normal.
6. Compaction row fields and projection metadata never enter provider wire payloads.

DI: `ModelProjectionBuilder` registered after `SessionManager` in `agent/lib/core/di.dart`.

Verification: `fvm dart test test/evolution/model_projection_builder_test.dart` — 7 passed.

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
- A failed Auto attempt opens a breaker for the active run, preventing repeated summarizer/provider work on later tool-loop steps. A new run resets the breaker and manual `/compact` remains available.
- Incoming user messages during compaction remain durable queued work and are never folded into the in-flight summary snapshot.

### 9.2 Triggers

| Trigger | When |
|---|---|
| `manual` | Idle `/compact` command |
| `auto` | Prospective pressure preflight at model boundaries |
| `overflow` | Confirmed provider context-overflow before any durable/visible provider output; one retry only |

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
