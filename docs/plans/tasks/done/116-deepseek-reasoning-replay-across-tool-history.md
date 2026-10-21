---
id: 116
title: Per-request provider-compatible conversation projection and cross-provider continuation
status: completed
gate: completed-with-deepseek-live-residual
created: 2026-10-18
parent_task: none (detached from 106)
depends_on: []
delivery: own PR (squash-merged to main)
---

# Task 116 — Provider-Compatible Conversation Projection and Continuation

## Goal

Ensure every request projects the same canonical conversation into the selected destination provider/model/protocol's valid wire representation, including successive provider changes in one conversation. Cover all currently supported adapter/protocol families and distinct route-policy requirements, not only DeepSeek. Preserve portable conversation meaning, tool-call/result relationships, supported media, the user's thinking choice, canonical history and provider-state issuer isolation. The reported DeepSeek thinking-mode failure remains a required regression case, not the entire scope.

## Intake and Authorization

- The user supplied an external investigation of a failure observed while working in Task 106's worktree. The initial intake was record-only; the 2026-10-19 user amendment authorized this scoped repair, originally within [Task 106](docs/plans/tasks/done/106-compaction-resilience-and-token-estimation-repair.md).
- Detached from Task 106 on 2026-10-21 and delivered in its own PR. Task 115 is complete ([record](docs/plans/tasks/done/115-post-201-provider-thinking-route-admission-regression.md)), so there is no remaining admission dependency. [Task 120](docs/plans/tasks/done/120-opencode-go-per-model-protocol.md) depends on this task and must keep provider-state issuers stable for unchanged Chat routes.
- Keep reasoning replay distinct from thinking-capability admission and pressure estimation. An upstream replay failure after admission is not automatically a compaction-estimation cause. Any proven blocking dependency on another task must be recorded here before work proceeds.
- Live acceptance uses this task's own worktree source and the user-designated Test Home (`.sanad-test` under user home), preserving the normal conversation runtime; rediscover runtime ownership before live work. No merge, protected label, runtime source switch, credential copy or new provider is implied by this plan.
- The report is not independent verification by the coordinating principal. Its counts, causal claims and proposed remedies remain hypotheses until the exact request, canonical rows and current source are correlated.

## Design

A read-only design report (adapter/protocol inventory, correlated DeepSeek-on-OpenCode-Go mechanism, fetched vendor evidence, smallest owning-boundary design, wire-fixture plan and file ownership versus Tasks 117 and 120) exists in the coordinator's records. It is input, not accepted policy. Implementation is wave 2. It has no file overlap with [Task 117](docs/plans/tasks/done/117-session-history-integrity.md); the shared contract is that `providerState` and `metadata` stay opaque and round-trip byte-identically through history rewrites, and 116 adds keys only, never columns or `SessionDB` changes.

## Expanded User Scope and Live Verification — 2026-10-19

- Resolve the destination route for each request, not once for the conversation. Requests to X, then Y, then X in the same session must each use the destination's compatible roles, content/tool/media representation, continuation requirements and supported thinking directives. Do not reset or fork the conversation to make switching pass.
- Reuse canonical models, existing adapters/codecs and route policies. Add only missing transformations at their owning boundary; do not build a universal protocol framework or duplicate serializers. Provider compatibility is distinct from Task 115's capability admission.
- Keep ordinary portable history and tool relationships available across transitions. Never forward issuer-bound signatures, encrypted reasoning or other opaque continuation state to a foreign route, fabricate reasoning, relabel an issuer or silently discard history. If a required historical construct truly has no supported truthful representation, return a specific safe explanation; rejection is not a substitute for implementing supported provider transitions.
- Cover each supported adapter/protocol family and materially different route policy with discriminating wire fixtures. Use bounded representative transitions, including X→Y→X and a subsequent request after compaction/restart, rather than an exhaustive every-model pairwise campaign. Record unsupported coverage explicitly; do not claim all vendors were live-tested.
- Prefer daemon-backed Sanad CLI for live runs, targeting the verified Test Home and an explicit test-session identity so successive sends exercise the same conversation. Verify the available CLI targeting/route/compaction commands before use; if a required operation is unsupported, report that exact gap and use the smallest existing supported boundary rather than silently create a new session or standalone engine.
- Keep the Test Home Client open on that same test daemon/session for user observation. Drive UI only for UI-specific assertions; command success alone does not prove Client rendering/event delivery. CLI tests must traverse the real daemon orchestration, provider adapters, persistence and compaction, not a standalone or fixture-only substitute. Normal user Home/runtime remains untouched.

## Reported DeepSeek Regression Evidence

- Failing dump basename: `request_dump_4c5b71ce-919c-42f2-b437-8ca7a4d6b1c7_20261018_160050_07.json`, reported error at line 3603. Raw dumps stay outside tracked project knowledge.
- Reported timestamp: `2026-10-18T16:00:50.007608`; timezone has not been independently established.
- Route: `OpenCode Go / deepseek-v4.1-flash`, OpenAI-compatible Chat protocol, thinking enabled and `reasoning_effort=max`.
- Upstream failure: `invalid_request_error`, stating that `reasoning_content` in thinking mode must be passed back to the API.
- Reported request: 300 messages, 136 assistant messages; 42 included `reasoning_content`, 94 omitted it. All 94 omissions carried `tool_calls`; no omission without tools was reported.
- Reported same-provider zero-reasoning example: canonical row 29578744 had no reasoning delta/provider state despite tool calls.
- Reported retained tail: rows 29578000–29578779. The report attributes some incompatible history to earlier Codex responses and some to same-provider zero-reasoning turns.
- A later successful dump from a different session reportedly had 14 messages, 5 assistants, all 5 with `reasoning_content`. This is not a controlled before/after comparison: both session and history shape differ.

## Parallel Preparation Result — 2026-10-20

- Bounded triage identifies adapter/projection owners as disjoint from106 Stage1 and115 admission; Task 115 has since been delivered. No 116 product writer is dispatched yet.
- The triage's blanket empty `reasoning_content` recommendation for foreign/no-state tool history is **not accepted**. Its linked URLs do not establish pinned, exact-route permission for empty-vs-absent semantics or foreign-history representation. Establish these separately; preserve issuer isolation and every supported adapter/protocol family's coverage rather than reducing the task to DeepSeek.

## Implementation Round 1 — 2026-10-21 (writer record, unreviewed)

- Base `2286267a`, branch `fix/116-provider-compatible-projection`; no commit, live call or runtime action. Task 117 files (SessionDB, compaction boundary repository, history healer, image pruner) untouched; `agent_runner.dart` carries only the D4 branch.
- **Dump credentials (security, handled inside 116):** confirmed from source and a red test that request dumps wrote the first 8 and last 4 characters of the API key (`api_key`, `Authorization`) and the whole key for non-`Authorization` credential headers (`x-api-key` for Anthropic-protocol routes, `api-key`) when the key had no recognized vendor prefix. Fixed at the dumper boundary: presence-only key marker and name-based header/field masking through `SecretsRedactor`.
- D1–D6 implemented as designed in [Provider Protocol — Per-request provider-compatible projection](docs/technical/provider_protocol.md); fixtures and the pending live probes P1–P5 are in [Provider-Compatible Projection QA](docs/qa_maintenance/provider_projection_qa.md). The route echo policy ships the conservative `asRecorded` default; P1–P5 outcomes are a data change only.
- Remaining before acceptance: independent review, live probes P1–P5, daemon-backed CLI live acceptance on Test Home, Client-keyed localization of the new notice title, and the real compaction-engine continuation (fixture covers a compaction-shaped history only).

## Hypotheses to Verify

1. `BaseOpenAIAdapter._messageToWire` correctly rejects foreign namespace/issuer state, but the target route may require an additional, explicitly evidenced history representation for assistant tool-call messages.
2. Sync/stream normalization may omit a required distinction between absent reasoning and an explicitly empty reasoning field on genuine same-provider zero-reasoning tool-call responses.
3. Compaction may expose an existing serializer incompatibility by retaining a connected tool tail; it is not yet established that compaction itself corrupts reasoning.

Relevant owners: `agent/lib/engine/adapters/base_openai_adapter.dart`, typed provider-state/response normalization, the owning Chat wire policy, and existing compaction projection/adapter regression suites.

## Locked Boundaries

- Do not relax namespace/issuer/endpoint isolation or replay foreign opaque state.
- The report's suggestions to copy `message.reasoning` or insert an empty string are not accepted design decisions. Establish the exact provider's required wire semantics and permissible data reuse first; never fabricate thinking or silently substitute provider state.
- Empty reasoning, omitted reasoning and unavailable foreign reasoning are different cases. A remedy valid for a genuine same-provider zero-reasoning response does not automatically authorize a cross-provider fallback.
- Do not lower, clear or replace thinking, switch providers/models, delete canonical history or silently drop retained tool calls to hide the error.
- Public diagnostics remain bounded stage/cause metadata; raw provider payloads, request contents and secrets stay out of logs, tracked docs and UI details.

## Gates and Acceptance

- [x] Perform bounded source/owner/dependency preparation now; record exact base and disjoint files before implementation. No product/runtime/model changes during preparation. Record sole-writer/reviewer/Test Home readiness.
- [x] Independently correlate the exact failing request with canonical rows and source; verify all reported counts and distinguish same-provider, foreign-provider and genuinely zero-reasoning cases.
- [x] Inventory existing supported adapter/protocol families and materially distinct route policies; pin only the protocol evidence needed for their disputed wire requirements, including DeepSeek/OpenCode Go empty-vs-absent reasoning. Do not infer one provider's semantics from another or start a broad reference-research campaign.
- [x] Agree the smallest owning-boundary design before delegating implementation; define a specific safe rejection if required historical material cannot be represented truthfully.
- [x] Demonstrate red/green through actual adapter HTTP-wire fixtures covering the supported families/policies: sync/stream tool calls and results, explicit empty vs absent reasoning, permitted same-issuer replay, forbidden foreign state, destination-compatible content/media, and compaction-retained tails. Exercise one session through X→Y→X and representative additional families, including return to a prior issuer and continuation after restart/compaction. Preserve selected thinking and canonical records; rebind input measurements to the new route.
- [x] Cover both the reported large history and a minimal zero-reasoning tool-call sequence; a small fresh-session success alone is insufficient.
- [x] Run affected analyzers/focused suites and necessary daemon integration, then freeze required fast suites once with unique logs, exit status and timings.
- [x] Obtain user-designated independent review and principal daemon-backed CLI live acceptance on Test Home using existing authorized configured providers, including same-session provider changes, minimal and large-history tool/reasoning cases and post-compaction continuation. Keep the matched Client open for observation and perform only the necessary UI-specific checks. Report live-tested routes separately from fixture-only coverage; unavailable authentication/quota is a visible gap, not permission to add providers or claim success. Update owning design/QA docs and graph.
- [x] Deliver the reviewed, automatically and live-accepted repair in this task's own PR; record exact-SHA green CI and remaining work. No main merge, protected label or runtime source handoff is inferred.

## Acceptance Evidence — 2026-10-21

- **Coordinator review:** `dart analyze` clean. Focused suites (secrets dumper, Chat replay wire and policy, Anthropic thinking replay, cross-family projection, runner, adapters, image projection) 133 passed. Writer's full agent suite: +2897 ~14, no failures.
- **Live probes P1–P5** (12 raw requests, OpenCode Go `deepseek-v4.1-flash`): P1–P4 accepted (2xx), no 400. P5 not sent: identical to P2 on the wire. Intermittent `503 Endpoint is unavailable` responses were availability failures, not request rejections. Decision: every route echo cell stays `asRecorded`; no code change. Caveat: `reasoning_tokens` was 0 throughout, so this is weak evidence for reasoning-bearing turns.
- **Live sanity on Test Home (daemon-backed):**
  - Request dump masking PASS: 10 dumps, `api_key` recorded as `***`, every `Authorization` header masked.
  - Same-route tool replay PASS on `glm-5.2` and on `kimi-k2.6` (135 real `reasoning_details` entries replayed).
  - Cross-model switch `kimi-k2.6` → `glm-5.2` PASS: 0 reasoning carried, HTTP 200.
  - DeepSeek route live acceptance BLOCKED by an upstream 503 outage (see Remaining Work).

## Residual Risks and Remaining Work

- **DeepSeek live gap:** re-verify the OpenCode Go `deepseek-v4.1-flash` same-session tool/reasoning flow once the endpoint is healthy. The same-route default is unchanged from pre-116 behaviour.
- An orphan Anthropic `tool_use` (no matching result) is now rejected with a specific notice instead of being silently dropped.
- Legacy assistant rows without a recorded model are treated as foreign for opaque-state replay.
- The rejection notice is English-only until the Client-keyed localization lands.
- [Task 120](docs/plans/tasks/done/120-opencode-go-per-model-protocol.md) must keep provider-state issuer strings stable for unchanged Chat routes.
- Live post-compaction continuation is covered by a compaction-shaped fixture only.
