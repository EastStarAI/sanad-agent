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
| Null / cleared selection | Provider default by omission; no invented `balanced` |
| Legacy `fast`/`balanced`/`deep` when mapped option exists | Migrates to `low`/`medium`/`high` only when present in descriptor |
| Legacy alias when mapped option missing | Cleared with correction reason `thinking_option_unavailable_for_route` |
| Anthropic manual vs adaptive model | Manual emits `budget_tokens`; adaptive emits `thinking.type=adaptive` + effort; never both |
| Gemini budget vs level | Nested `thinking_config` uses budget or level only |
| DeepSeek fixture model | Toggle XOR effort; unresolved DeepSeek models stay `unknown` |
| Aggregator OpenRouter upstream | Delegates descriptor/directive to upstream family policy |
| Ollama without live thinking capability | Descriptor `unknown`; no invented options from model name |
| Ollama with live `thinking` capability | Options from probe; `off` → `think: false` |
| Custom / Kimi / generic chat_completions without opt-in | `unknown` policy; no selector inventing OpenAI effort |
| Client `thinking_mode_source=model` | Composer uses model/`thinking_control` options only; empty list does not fall back to `balanced` |
| Client unsupported descriptor | Thinking chip hidden |
| Client unknown descriptor | Chip disabled with `Unavailable` |
| Route revision mismatch | Stale session descriptor ignored |
| Model/provider switch invalidating selection | Preference cleared + correction event |
| Daemon restart with queued turn | Revalidates persisted selection before provider call |

## Automated anchors

- `agent/test/core/provider_thinking/`
- `agent/test/engine/thinking_selection_agent_runner_test.dart`
- `agent/e2e_test/thinking_mode_gate_i_e2e_test.dart` (`--concurrency=1`)
- `client/test/unit/conversations/route_thinking_control_test.dart`
- `client/test/unit/bloc/conversation_input_cubit_test.dart` (model-scoped defaults/clear)
