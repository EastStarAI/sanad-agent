---
title: "Provider-Aware Thinking Mode QA"
description: "Focused QA matrix for Task 43 dynamic thinking controls across daemon policy, protocol, and client composer."
---

# Provider-Aware Thinking Mode QA

## Scope

Validates that thinking controls are model-route scoped, fail closed for unknown
routes, and never silently ignore an explicit unsupported selection.

## Matrix

| Scenario | Expected |
|---|---|
| OpenAI reasoning model (`o3`) with selection `high` | Chat Completions body includes top-level `reasoning_effort=high`; sync/stream parity for non-stream fields |
| OpenAI non-control model with explicit selection | Typed rejection before HTTP; zero provider requests |
| Null / cleared selection | Provider default by omission; no invented `balanced`, and no provider-instance capability lookup is required for deterministic/standalone routes |
| Capabilities switch from legacy to `thinking_mode_source=model` on an unchanged route | Composer reloads the model snapshot immediately instead of remaining `Unavailable` |
| Legacy thinking controls in an isolated composer | Legacy list remains renderable without requiring model-scoped `SessionCubit` context |
| Legacy `fast`/`balanced`/`deep` when mapped option exists | Migrates to `low`/`medium`/`high` only when present in descriptor |
| Legacy alias when mapped option missing | Cleared with correction reason `thinking_option_unavailable_for_route` |
| Anthropic manual vs adaptive model | Manual emits `budget_tokens`; adaptive emits `thinking.type=adaptive` + effort; never both |
| Gemini budget vs level | Nested `thinking_config` uses budget or level only |
| DeepSeek fixture model | Toggle XOR effort; unresolved DeepSeek models stay `unknown` |
| Aggregator OpenRouter upstream | Delegates descriptor/directive to upstream family policy |
| Ollama without live thinking capability | Descriptor `unknown`; no invented options from model name |
| Ollama Boolean declaration | Exactly declared On/Off choices and member Boolean default; sync/stream `think` remains Boolean; omitted Default emits no `think` |
| Ollama level declaration | Exactly declared native string choices/default; a native string `off` stays a string, not Boolean `false` |
| Malformed native values/default or untyped capability list | No fabricated options/defaults; unresolved evidence stays unknown |
| Codex exact native metadata | `supported_reasoning_levels` and optional member `default_reasoning_level` survive discovery/cache/resolution; malformed or foreign-model metadata is not finite evidence |
| Valid native levels without a default | No guessed first/medium default; provider Default remains wire omission |
| GPT-5.6 Sol `none` versus Default | `none` is an explicit Off effort; Default omits the field; Astra does not acquire unsupported `none` |
| Custom / generic compatible route without exact model evidence or declaration | `unknown`; no selector inventing OpenAI effort |
| Compatible route with exact evidenced Kimi model | Model-owned finite Kimi controls; fixed models unsupported; aggregator retains its route-owned envelope |
| Every registry/factory kind | Automatic evidenced/unknown/unsupported expectations plus finite declaration, actual-mode and default-omission checks; no claim that registry coverage proves every upstream model |
| OpenCode Go recognized reasoning family | Selector uses the OpenAI Chat effort descriptor and supported ordered tiers |
| OpenCode Go unknown model with `supports_reasoning_output=true` | Control remains unavailable; reasoning output alone does not invent selectable effort |
| Explicit empty `thinking_mode` session preference | Client transmits the present empty field; daemon clears persistence and emits `thinking_mode: null` |
| Client `thinking_mode_source=model` | Composer uses model/`thinking_control` options only; empty list does not fall back to `balanced` |
| Client exact model descriptor identity | Resolves thinking descriptors using exact model ID; preserves catalog namespaces (`VendorA/model` vs `VendorB/model`), case (`CaseModel` vs `casemodel`), and variant markers (`~`, `:`); strips only transport-owned provider-instance prefixes (`provider-1/`) with exact boundaries |
| Client unsupported descriptor | Thinking chip hidden |
| Client initial descriptor load | Shows `Loading...` until the authoritative snapshot arrives |
| Client authoritative unknown descriptor | Shows `Default` / provider-managed behavior; does not invent selectable controls or display a false `Unavailable` state |
| Route revision mismatch | Stale session descriptor ignored |
| Model/provider switch invalidating selection | Preference cleared + correction event |
| Daemon restart with queued turn | Revalidates persisted selection before provider call |

## Automated anchors

- `agent/test/core/provider_thinking/`
- `agent/test/engine/thinking_selection_agent_runner_test.dart`
- `agent/e2e_test/thinking_mode_gate_i_e2e_test.dart` (`--concurrency=1`)
- `client/test/unit/conversations/route_thinking_control_test.dart`
- `client/test/widget/route_thinking_mode_selector_test.dart`
- `client/test/unit/bloc/conversation_input_cubit_test.dart` (model-scoped defaults/clear)
