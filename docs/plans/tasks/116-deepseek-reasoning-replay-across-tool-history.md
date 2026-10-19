---
id: 116
title: Per-request provider-compatible conversation projection and cross-provider continuation
status: planned
gate: 106-consolidated-queue-stage-5
created: 2026-10-18
parent_task: 106
depends_on: [115]
delivery_pr: 210
---

# Task 116 — Provider-Compatible Conversation Projection and Continuation

## Goal

Ensure every request projects the same canonical conversation into the selected destination provider/model/protocol's valid wire representation, including successive provider changes in one conversation. Cover all currently supported adapter/protocol families and distinct route-policy requirements, not only DeepSeek. Preserve portable conversation meaning, tool-call/result relationships, supported media, the user's thinking choice, canonical history and provider-state issuer isolation. The reported DeepSeek thinking-mode failure remains a required regression case, not the entire scope.

## Intake and Authorization

- The user supplied an external investigation of a failure observed while working in Task 106's worktree. The initial intake was record-only; the 2026-10-19 user amendment now authorizes this scoped repair within the [Task 106 consolidated repair queue](docs/plans/tasks/done/106-compaction-resilience-and-token-estimation-repair.md).
- Work in `.agent/worktrees/106-compaction-resilience-and-token-estimation-repair`, with one writer and delivery through existing Draft PR 210. This is stage 5, after stage 4 / Task 115 has independent review, automated and Test Home live acceptance, a pushed checkpoint and exact-SHA green CI. Record that checkpoint, not an assumed `main` merge; no separate worktree or PR is planned.
- Keep reasoning replay distinct from thinking-capability admission and pressure estimation even though they share a delivery vehicle. An upstream replay failure after admission is not automatically a compaction-estimation cause. Any proven blocking dependency requiring an earlier repair must first be reflected in Task 106's queue.
- Live acceptance uses the separately managed Task 106 source pair and user-designated Test Home (`.sanad-test` under the user home), preserving the normal pre-PR201 conversation runtime. After review, automated and principal live acceptance, scoped commit/push is authorized; await exact-SHA green CI before final combined acceptance. No merge, protected label, runtime source switch, credential copy or new provider is authorized.
- The report is not independent verification by the coordinating principal. Its counts, causal claims and proposed remedies remain hypotheses until the exact request, canonical rows and current source are correlated.

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

- [ ] Activate in the existing Task 106 worktree after Task 115's accepted, live-tested, pushed and exact-SHA CI-green checkpoint; record SHA and sole-writer/reviewer/Test Home readiness.
- [ ] Independently correlate the exact failing request with canonical rows and source; verify all reported counts and distinguish same-provider, foreign-provider and genuinely zero-reasoning cases.
- [ ] Inventory existing supported adapter/protocol families and materially distinct route policies; pin only the protocol evidence needed for their disputed wire requirements, including DeepSeek/OpenCode Go empty-vs-absent reasoning. Do not infer one provider's semantics from another or start a broad reference-research campaign.
- [ ] Agree the smallest owning-boundary design before delegating implementation; define a specific safe rejection if required historical material cannot be represented truthfully.
- [ ] Demonstrate red/green through actual adapter HTTP-wire fixtures covering the supported families/policies: sync/stream tool calls and results, explicit empty vs absent reasoning, permitted same-issuer replay, forbidden foreign state, destination-compatible content/media, and compaction-retained tails. Exercise one session through X→Y→X and representative additional families, including return to a prior issuer and continuation after restart/compaction. Preserve selected thinking and canonical records; rebind input measurements to the new route.
- [ ] Cover both the reported large history and a minimal zero-reasoning tool-call sequence; a small fresh-session success alone is insufficient.
- [ ] Run affected analyzers/focused suites and necessary daemon integration, then freeze required fast suites once with unique logs, exit status and timings.
- [ ] Obtain user-designated independent review and principal daemon-backed CLI live acceptance on Test Home using existing authorized configured providers, including same-session provider changes, minimal and large-history tool/reasoning cases and post-compaction continuation. Keep the matched Client open for observation and perform only the necessary UI-specific checks. Report live-tested routes separately from fixture-only coverage; unavailable authentication/quota is a visible gap, not permission to add providers or claim success. Update owning design/QA docs and graph.
- [ ] Commit/push the reviewed, automatically and live-accepted repair to PR 210 under Task 106's staged authorization; record exact-SHA green CI and remaining work before final combined acceptance. No main merge, protected label or runtime source handoff is inferred.
