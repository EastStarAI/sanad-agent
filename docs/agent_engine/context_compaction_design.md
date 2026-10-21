---
title: "Context Compaction Engine Design"
description: "Goal-preserving compaction engine contracts for pressure measurement, tail selection, summarization, and continuity validation."
---

# Context Compaction Engine Design

Plan 53c owns the provider-neutral compaction engine under `agent/lib/engine/context/`. Persistence and activation live in 53b; orchestration and protocol wiring live in 53d; client timeline UX lives in 53e.

## Pipeline

```text
CompactionEngineRequest
  -> RequestPressureEvaluator (prospective full-request estimate)
  -> CompactionTailSelector (tool-pair aware verbatim tail)
  -> CompactionToolPruner (model projection only)
  -> CompactionSummaryPrompt + CompactionSummarizer
  -> CompactionContinuityValidator (anchors + required sections)
  -> CompactionCandidate or typed CompactionEngineFailure
```

The coordinator selects immutable source/tail ranges synchronously, persists the
exclusive started claim, and publishes the compacting barrier before the first
summarizer await. Pre-claim preparation and thinking selection errors are contained
without creating a database claim or barrier. `CompactionActivationService` activates
only a validated candidate; summarizer, pruning, validation, or cancellation failure
closes the claimed row as typed failed with allowlisted safe stage and cause diagnostics
(`failure_stage`, `failure_cause` stored in `failure_detail_json`) and never mutates
canonical history. Stale non-null owners cannot clear newer compacting state or drain queues.

## Pressure and budgeting

- Full-request estimation separates system prompt, runtime context, tool schemas,
  media-heavy fields, conversation history, reasoning, and provider replay. When
  a protocol adapter exposes its wire projection, that projection wins over the
  provider-neutral fallback so alternative replay/content forms are not counted twice.
- Effective input window uses `inputLimitTokens` when present, otherwise the
  route `contextWindowTokens`, then subtracts output reservation (`4096` default)
  and safety headroom (`1024` default).
- The automatic threshold is the policy ratio of the full resolved window `W`
  (`inputLimitTokens` when present), capped by that effective input window
  (Task 118). It is reported over `W`; a trigger decided by the cap is flagged
  `threshold_capped_by_usable_budget` rather than shown as the nominal threshold.
- Provider-confirmed input usage is authoritative only for the same route and
  byte-equivalent measured wire prefix. The adapter fingerprints instructions,
  tools, and ordered wire input items; a strict extension starts from the
  confirmed value and estimates only the appended wire suffix (`confirmed` /
  `mixed`). A larger rough estimate of the full request cannot override it.
- A route/model/config revision, prompt, tool-schema, or measured-prefix change
  invalidates the snapshot and returns to an explicitly estimated projection.
- Recovering that baseline after a restart reads the timestamped per-model-step
  `context_usage` snapshot rather than the mutable generic `usage` map, which can
  hold a later run value on the same assistant row. A provider/model identity
  present in that snapshot is authoritative: a matching mutable legacy
  `provider`/`model` value never overrides a mismatched snapshot, and an absent
  or empty recorded identity never matches a null candidate alias. Production
  `BaseOpenAIAdapter` implements `WireInputUsageMeasurer` and
  `WireInputTokenEstimator` through its canonical request builder.
- A baseline recovered from persistence requires a versioned compact non-content
  `wire_proof` (`v1:<sha256>`) that binds confirmed input to complete ordered wire
  items (`inputItemFingerprints`), stable material (`stableMaterialFingerprint`),
  and route signature. The live producer records `wire_proof` in the frozen
  `context_usage` snapshot. Upon restore after a restart, the active adapter
  remeasures the historical prefix preceding the assistant row; the baseline is
  restored only if the adapter exposes `WireInputUsageMeasurer`, `wire_proof`
  is valid and matches remeasurement, and the current request extends that
  prefix on the same route (`extendsMeasurement`). Unsupported/no-measurer adapters,
  legacy unbound rows without `wire_proof`, and any drift in route, prompt, tool
  schemas, or historical message content fail closed to explicit estimates. There
  is no unproven floor: prospective pressure is calculated from the remeasured
  wire extension delta (`wireMeasurement.estimatedTokens - baselineWire.estimatedTokens`),
  and a wire-measured baseline is consumed only while the live remeasurement keeps
  proving that extension. When the proof stops holding — for example a wire-visible
  request option such as a thinking directive changes — admission falls back to the
  explicit estimate until a new provider response supplies a fresh binding; the
  in-memory message comparison remains only for routes whose adapter exposes no wire
  measurement at all. Stale receipts from before an activated compaction boundary are
  discarded by the same material proof, so no wall-clock recency heuristic is needed.
  Metadata-only bookkeeping changes on earlier messages do not alter wire items or
  proofs and do not falsely invalidate valid pressure. Cached input tokens count as
  input, and confirmed pressure exceeding the threshold triggers automatic compaction.
- Tool-schema token estimates are cached by route identity + schema fingerprint
  so stable schemas are cheap to re-evaluate and routes never share a cache entry.
- Image material is priced from its model-facing form, not its transport: a base
  charge plus a tile charge per image after the model's maximum-edge and
  minimum-short-side fit, with the per-image ceiling for an image whose
  dimensions are not recorded. Only `low` detail is charged the base rate;
  canonical `ToolImageDetail.original` reaches the wire as `high` and is priced
  on the tile grid. The fitted grid is clamped to the same per-image ceiling so
  thin or panorama images cannot demand an unbounded tile grid, and a fitted
  thin side that rounds to zero keeps one pixel instead of a non-finite scale.
  Text is chars/4 for ASCII; CJK, Hangul and Kana cost one token per code
  point and other non-ASCII text costs UTF-8 bytes / 4, because chars/4
  priced Arabic at about half its real cost (Task 118b).
  Encoded media strings (data URIs, long base64
  blobs) are never priced as text; declared `media_bytes` keep byte-based
  accounting and homogeneous filler text stays on the chars/4 estimator. A user
  attachment is priced by the per-image ceiling even when the route text-projects
  it instead of sending the image, so the residual error stays bounded (at most
  one ceiling per attachment) and never grows with the encoded payload.
- Automatic compaction triggers above `90%` of the full window `W` by default.
  The complete post-compaction request (intact instructions and tools, the
  summary and the retained tail) has a `10%` target over `W` (Task 118
  Stage3A). Both ratios may be overridden per exact normalized model id in
  `SANAD_HOME/config.yaml`.
- A manual compaction whose complete request is already within the target is
  a no-op before any claim or provider call (Task 118: very small sessions
  otherwise paid for a summary larger than the rows it replaced and failed
  with `projection_still_over_budget`).
- Before the tail is selected, `ContextCompactionEngine.measureRequest`
  measures the fixed overhead and the complete current request with the
  route's wire meter (fallback: provider-neutral estimate). The tail budget is
  `target − fixed overhead − summary reservation`; the reservation is the
  previous summary's transmitted size or the two-page planning constant in
  `CompactionTargetPolicy`. After summarization the request is measured again
  and the decision snapshot records the estimated target outcome and whether
  the target was attainable at all. A tail above the target is a measured
  `not_met`, not a failure; only a request that would not fit usable input, or
  is not smaller than before, is rejected.
- Output reservation and safety headroom remain internal safeguards. On tiny
  test/local windows where their fixed sum would consume the whole window, the
  combined reservation is bounded to `25%`; normal model windows retain the
  fixed `4096 + 1024` reservation.
- After a boundary is active, automatic preflight measures summary + retained
  tail + post-boundary rows. It must not remeasure the hidden canonical head,
  otherwise every later turn would retrigger compaction.
- Persistence keeps `messages.id` stable for top-level metadata-only patches.
  Usage, model-step, and delivery metadata therefore cannot invalidate an active
  boundary or force preflight back to the full canonical transcript; a genuine
  message-semantic edit still rewrites the suffix and rejects an unsafe summary.

## Tail selection and projection pruning (C1–C2)

- `CompactionTailSelector` partitions durable `messages.id` ranges into compressible
  head and tool-pair-aware retained tail.
- A tail boundary that lands on any result inside a contiguous multi-tool batch
  expands to the assistant message that owns the complete batch; it does not
  assume the result immediately follows the assistant call message.
- Projection hydration rejects a persisted boundary when its retained tail
  contains a tool result without the owning assistant tool call. This preserves
  canonical fallback and lets a later compaction replace an older unsafe boundary.
- Selection walks backward from the newest row and produces one connected suffix.
  Every model-visible canonical row is therefore either summary source or retained
  tail; no middle gap is permitted.
- Each candidate tail is priced as transmitted (Task 118 Stage3A): the
  route's wire estimate of the tail, with the span between two provider
  receipts that the active adapter proves against the current request priced
  at the provider-confirmed input difference. Replayed reasoning and tool
  framing therefore cost what the provider reported. Opaque replay outside a
  proven span is counted as unknown (`unproven_replay_items`), never priced as
  zero or from ciphertext. Detail: `docs/technical/context_compaction.md`
  §4.8, "Replay-Aware Tail Selection".
- Summarizer input describes media and truncates oversized tool results; protected
  tail rows stay verbatim for summarizer partitioning.
- Structured tool results (`Message.toolResult`) are pruned coherently with their
  string projection: `CompactionToolPruner` derives immutable replacement
  `ToolExecutionResult` blocks so the invariant `content == toolResult.displayText`
  is strictly preserved. Call identity (`toolCallId`), error flags/codes (`isError`,
  `errorCode`), schema version, and metadata remain intact.
- For summarizer input, media blocks (`ToolImageBlock`) are converted to clean text
  descriptions (`[media omitted for compaction summary: <bytes> bytes]`). For oversized
  retained-tail projection (`pruneOversizedForProjection`), `ToolImageBlock`s remain
  unmodified without creating invalid empty image blocks or inventing a new image-retention policy.
- When a single recent tool/media payload would keep the post-compaction request
  over budget, `CompactionToolPruner.pruneOversizedForProjection` shrinks
  projection-only copies so the engine can still emit a candidate. Canonical rows
  are never rewritten.

## Goal preservation

Structured summary sections:

1. Current Goal and Success Criteria
2. Active Constraints and User Preferences
3. Completed Work and Verified Results
4. Current State and In-Progress Work
5. Key Decisions and Rationale
6. Blockers, Errors, and Unresolved Questions
7. Pending User Asks
8. Relevant Files, Symbols, IDs, and External State
9. Remaining Work and Safest Next Action
10. Critical Context That Must Not Be Lost

Continuity anchors extracted before summarization must survive validation.
Semantic labels (`goal`, `blocker`, `pending ask`, `decision`, `path`) establish
intent only when they occur in user-authored messages. Assistant content and
tool output frequently quote source, logs, JSON, or plans containing the same
labels and therefore cannot create semantic anchors; tool effects retain their
typed `tool_call_id` supporting anchor instead. One bounded repair attempt is
allowed; weak fallback summaries never activate a boundary. Failures may carry
`CompactionAntiThrashingHints` for 53d cooldown.
One failed automatic attempt (Auto preflight or Overflow) also opens a per-run
breaker so neither later tool-loop model steps nor a provider overflow in that
run can repeat compaction work; manual compaction and a new run remain eligible.

## Provider-backed summarizer contract (53i)

- Production uses the exact active provider/model/endpoint and the exact
  provider-visible projection for the trigger. Auto includes the admitted user
  turn; overflow reuses the failed projection; manual uses the current idle
  projection without inventing a turn.
- Request options are derived through a single canonical builder
  (`CompactionRequestFactory.buildCompactionRequestOptions`) shared across manual,
  automatic, and overflow paths. Every `LLMRequestOptions` field is explicitly accounted for:
  the active route signature, user-selected thinking mode, native thinking directive,
  capability profile and snapshot, attachment store, and transport test seams (`requestClientFactory`)
  are preserved verbatim. Compaction overrides only correlation (`requestId: 'compaction:...'`)
  and safely verifies cancellation scope lifecycle (clearing expired or cancelled scopes
  rather than copying them blindly).
- Exact thinking preservation is strict: the user's selected thinking mode and wire directive
  are never lowered, cleared, defaulted, or substituted as error recovery.
- Image attachments are verified against the request's `AttachmentStore` before transmission;
  missing, corrupt, or unauthorized media fails specifically before HTTP, preserving the storage jail.
- One ordinary ephemeral user message is appended. The normal tool list and
  request settings remain unchanged, but the final instruction line forbids
  tool calls and requires the final JSON object only. A returned tool call is
  never executed: one corrective attempt starts again from the same immutable
  base, then compaction fails safely. Empty, reasoning-only, truncated and
  invalid-JSON summaries follow the same single correction and fail with a safe
  shape-specific cause, and every billed attempt keeps its usage in the
  ledger and the aggregate (recovery included); a timed-out pass fails at once
  (`docs/technical/context_compaction.md` §8.11.1).
- A compaction pass waits for its complete response under the central
  compaction pass timeout (`compaction.passTimeoutSeconds`, default 600 s), not
  the normal-turn 90 s response watchdog; normal turns keep their watchdogs.
- Output length is a soft request for about two pages. Compaction adds no token,
  byte, or field-length cap and does not reject an otherwise valid JSON result;
  the ordinary provider/request limits remain authoritative.
- The response is strict versioned JSON with fixed keys, no Markdown fallback,
  duplicate keys, unknown keys, or wrong types. Required non-empty fields are
  current goal, latest user request, active state, critical context, and
  remaining work. Provider-only reasoning wrappers are removed and the parsed
  structure is redacted before persistence.
- Before the full pass is sent, its whole request plus the output reservation
  from route capability (settings, provider metadata, models.dev, then a
  documented fallback) is checked against `W`; a pass that cannot fit is not
  sent and the bounded recovery runs directly. No output cap is sent.
- If the append-only request overflows before output, the bounded recovery
  summarizer packs contiguous groups that keep assistant tool calls with their
  results into chunks within a per-pass token budget, splits an overflowing
  chunk at most once, and reduces the partials (preceded by the eligible
  previous summary) in budget-packed batches into one typed summary. A source
  needing more chunks than configured fails with `recovery_capacity_exceeded`
  before any recovery call. Partial summaries never activate a boundary.
  Details: `docs/technical/context_compaction.md` §8.12.
- Compaction adds no cache-specific measurement, enforcement, or metric. Cache
  behavior is incidental to the ordinary codec/provider request and is not a
  correctness condition or performance claim.

## Repeated compaction

- The active projection already contains the previous internal summary once;
  provider-backed compaction does not pass it again in a side channel.
- The next source range begins after the previous source-range end; already
  summarized canonical rows are not summarized again.
- Latest successful boundary alone truncates the active model projection.
- Retained tail stays verbatim and never splits an incomplete tool batch.

## Engine boundaries

- No database imports inside `agent/lib/engine/context/`.
- The summarization request retains the ordinary tool list because it is an
  ordinary provider request, but compaction never dispatches a tool returned
  by the provider.
- Overflow/manual/auto differ only by `CompactionTrigger`; engine policy is shared.
- Pre-compaction metrics retain their `estimated`, `confirmed`, or `mixed`
  provenance. The projection estimate remains available after activation, then
  the first provider response writes a separate confirmed after-value; the two
  values are never silently conflated.
- A live 53g example makes the accounting explicit: the `58,506` pre-confirmation
  after-estimate was `38,979` retained-tail tokens plus `19,527` estimated
  summary/system/runtime/tool/media overhead. The first provider request then
  confirmed `40,829`. Persistence retains both provenances for diagnostics, while
  the UI replaces the superseded after-estimate with the provider-confirmed value.

## Model-aware startup configuration (53g)

`SANAD_HOME/config.yaml` is the canonical non-secret source and is read once at
daemon startup. Changes require restart. `context.modelLimits` resolves model
windows independently from `compaction` trigger/tail policy:

```yaml
context:
  modelLimits:
    gpt-5.6-sol: 258000
compaction:
  threshold: 0.90
  targetRatio: 0.10
  passTimeoutSeconds: 600
  models:
    gpt-5.6-sol:
      threshold: 0.85
      targetRatio: 0.08
```

Absent sections use `{}`, `0.90`, `0.10` and `600`. `passTimeoutSeconds` is
global (not per model) and must be a positive integer. Per-model keys inherit global
values independently. Unknown keys, non-positive model limits, and ratios outside
`(0, 1)` fail startup safely. `thresholdTokens`, `modelThresholds`, wildcards,
and legacy `.env` `CONTEXT_LIMIT` are not supported.

## Verification fixtures

Golden semantic fixtures live under `agent/test/engine/fixtures/context_compaction/` and cover:

- multi-step goals with files, blockers, and pending asks
- repeated compaction preserving unresolved work
- tool-pair tail boundaries and orphan prevention

See `docs/qa_maintenance/context_compaction_qa.md` for integration scenarios exercised in 53f.
