---
title: "Provider-Compatible Projection QA"
description: "Fixture and live-probe coverage for per-request reasoning/state projection across Chat, Codex Responses, Anthropic and Ollama, including same-model replay, route echo policy, pre-dispatch rejection and request-dump credential masking."
---

# Provider-Compatible Projection QA

## Scope

Validates Task 116: every request projects canonical history for its own
destination route without rewriting stored history. Design and wire contract:
[Provider Protocol — Per-request provider-compatible projection](../technical/provider_protocol.md).

All fixture evidence is synthetic and observed on the actual adapter HTTP body
through a mock carrier. It is not live vendor acceptance.

## Fixture Matrix

| Area | Scenario | Expected | Suite |
|---|---|---|---|
| Dumps | Key without a vendor prefix; `x-api-key`, `api-key`, non-Bearer `Authorization` | No prefix, suffix or whole key on disk; header values `***` (Bearer keeps scheme) | `agent/test/engine/llm_request_dumper_secrets_test.dart` |
| D1 | Sync/stream tool call with reasoning string, `""`, `null`, absent | State stamped with `issuer_model` and `reasoning_field`; issuer unchanged; a later null delta never downgrades a string | `agent/test/engine/adapters/chat_reasoning_replay_wire_test.dart` |
| D2 | Kimi then DeepSeek on one OpenCode Go instance | Kimi reasoning not sent to DeepSeek | same |
| D2 | Legacy state: model from `context_usage.model_id`, `metadata.model`, or none | Replays only on a matching stored model; none is foreign | same |
| D2 | Aggregator `reasoning_details` across two models | Withheld from the other model | same |
| D3 | Same-route `""`; recorded `null` to echo vs strict route | `""` verbatim; `null` only where `interleaved.field` declares it | same |
| D3 | Foreign Codex state, unrecorded foreign turn, same-route absent | No reasoning key, no padding, no relabelled visible reasoning | same |
| D3 | Minimal zero-reasoning tool loop; 136-assistant replica of the reported dump shape | As recorded: 42 with field (3 `""`), 94 omitted | same |
| D4 | Injected probe outcomes (P1, P4, P5), exact-route override, thinking off, no echo declaration | Typed rejection before HTTP (zero requests) with route/reason/count only, or dispatch as recorded | `agent/test/engine/adapters/chat_reasoning_replay_policy_test.dart` |
| D4 | Measurement under a rejecting policy | Returns a real estimate, no HTTP, no exception | same |
| D4 | Runner presentation | One blocked `invalid_request` notice, no dispatch, no failover, history unchanged, no compaction advice | `agent/test/engine/cross_provider_projection_runner_test.dart` |
| D5 | Anthropic sync/stream signed and redacted thinking | Captured with issuer and model; replayed first only to the same issuer and model; unsigned never replayed | `agent/test/engine/adapters/anthropic_thinking_replay_wire_test.dart` |
| D5 | Unpaired `tool_use` | `unpaired_tool_call` rejection before HTTP (previously silently stripped) | same |
| D6 | Mixed Chat/Codex/Anthropic history to Ollama, Codex and strict Chat templates | No foreign state; tool ids and arguments preserved; Codex replays only own issuer | `agent/test/engine/adapters/cross_family_projection_wire_test.dart` |
| X→Y→X | DeepSeek → Codex → DeepSeek, each turn a fresh runner over persisted history, then a compaction-shaped tail | Own reasoning back on DeepSeek, Codex state never on Chat, canonical state byte-stable | `agent/test/engine/cross_provider_projection_runner_test.dart` |

Fixture-only coverage, not yet live: the compaction engine itself (the
continuation case uses a compaction-shaped history), Gemini thought signatures,
Codex cross-model reasoning rejection, and Anthropic manual-budget behaviour on
third-party Anthropic-compatible endpoints.

## Live Probes P1–P5 (decision pending)

Purpose: settle the empty-vs-absent-vs-null and foreign-history semantics for
OpenCode Go `deepseek-v4.1-flash`, which no fetched vendor page states. Each
probe changes one variable. Outcomes are applied as data in
`ChatReasoningReplayPolicy` in `agent/lib/engine/adapters/chat_reasoning_replay_policy.dart` (`defaultDecisions` or an exact `routeOverrides`
entry for `opencode-go/deepseek-v4.1-flash`), never as adapter logic.

Common shape for every probe:

- Route: an existing authorized OpenCode Go instance, Chat protocol, model
  `deepseek-v4.1-flash`, `thinking: {type: enabled}`, an effort the route
  admits, `stream: true`, one trivial synthetic tool declared.
- Runtime: the Task 116 worktree source on the user-designated Test Home
  through the daemon-backed CLI, an explicit test session per probe, seeded
  synthetic history only. No credential copy, no normal Home, no new provider.
- History: system, user, then the probe's assistant tool-call message, its
  tool result, then the request. Synthetic ids and text only.
- Observation: HTTP status and the bounded error code/class only; no payload
  content in tracked notes.

| Probe | Assistant tool-call message under test | Request shape | Decides |
|---|---|---|---|
| P1 | Current turn, same route, `reasoning_content: ""` | `{role: assistant, content: "", reasoning_content: "", tool_calls: [...]}` | `sameRouteEmpty`: 2xx keeps `asRecorded`; the reported 400 means `reject` |
| P2 | Current turn, same route, field absent | `{role: assistant, content: "", tool_calls: [...]}` | `sameRouteAbsent` |
| P3 | Current turn, same route, `reasoning_content: null` | `{..., reasoning_content: null, tool_calls: [...]}` | `sameRouteNull` |
| P4 | Clean current turn; an earlier user turn holds a foreign tool exchange with no field | user₁, foreign assistant tool call (no field), tool result, assistant text, user₂ | `foreignEarlierTurn` |
| P5 | Current turn holds a foreign tool exchange with no field | user, foreign assistant tool call (no field), tool result | `foreignCurrentTurn` |

Budget: five ordinary requests, one per probe, each with a small output cap.
A transport or quota failure is recorded as a gap and is not retried into a
conclusion. If P1 and P2 both fail, genuine same-route zero-reasoning turns
have no truthful representation and become rejections; padding (`" "`) is not
an accepted remedy.

## Review Checklist

- Issuer strings for unchanged Chat routes are byte-identical to before.
- No path rewrites stored `providerState` or `metadata`.
- The runner branch is the only runner change and performs no failover,
  retry, thinking change or history change.
- Notice and exception text carries no message content, reasoning or
  credentials.
