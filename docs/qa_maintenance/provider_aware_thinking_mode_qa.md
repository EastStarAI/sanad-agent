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
| Exact DeepSeek effort model | Enabled thinking plus documented effort; Off disables without effort; fixed reasoners expose no adjustable control and unresolved models stay `unknown` |
| Aggregator OpenRouter upstream | Delegates exact model facts while keeping the aggregator `reasoning` envelope |
| GLM hybrid versus forced effort | GLM-4.5/Air permit On/Off with provider-managed hybrid default; GLM-5.3 permits low/high/max with default max and rejects Off; Kimi XOR wire remains unchanged |
| Ollama missing probe versus valid negative probe | Missing/malformed evidence is `unknown`; a valid capability list lacking `thinking` is `unsupported`; no name-based options |
| Ollama Boolean declaration | Exactly declared On/Off choices and member Boolean default; sync/stream `think` remains Boolean; omitted Default emits no `think` |
| Live native evidence older than the 5-minute TTL | Validated On/Off/default facts are retained under the matching route/config revision: On sends `think: true`, Off sends `think: false`, Default omits `think`; no degradation to unknown or rejection |
| Explicit probe failure or stale cache on a native route | Resolution stays `unknown` and explicit selection is rejected with `thinking_capability_unknown`; aged evidence never bypasses failure/invalidation markers |
| Config or credential revision change with aged native facts | Cached descriptor is invalidated, the fresh revision is reassembled, and selection is rejected while that revision has no native evidence |
| Failed refresh then config/credential revision change | Failure provenance is not cleared by the revision alone; resolution stays `unknown` and selection is rejected |
| Successful live refresh after a failed probe | Failure provenance is dropped, `source` returns to `live`, and On/Off/default resolve with typed native wire |
| Typed thinking-selection rejection at turn admission | Terminal error response delivered only after the owned work item commits `cancelled`, then the turn completes normally; unrelated queued work stays `queued` and restorable |
| Stale rejection whose work item already lost ownership | No terminal response, no in-flight clear, no turn-completion signal (no busy release or queued-work drain); the newer durable owner, its bound identity, and its queued work are untouched |
| Ollama level declaration | Exactly declared native string choices/default; a native string `off` stays a string, not Boolean `false` |
| Malformed native values/default or untyped capability list | No fabricated options/defaults; unresolved evidence stays unknown |
| Codex exact native metadata | `supported_reasoning_levels` and optional member `default_reasoning_level` survive discovery/cache/resolution; malformed or foreign-model metadata is not finite evidence |
| Valid native levels without a default | No guessed first/medium default; provider Default remains wire omission |
| GPT-5.6 Sol `none` versus Default | `none` is an explicit Off effort; Default omits the field; Astra does not acquire unsupported `none` |
| Custom / generic compatible route without exact model evidence or declaration | `unknown`; no selector inventing OpenAI effort |
| Compatible route with exact evidenced Kimi model | Model-owned finite Kimi controls; fixed models unsupported; aggregator retains its route-owned envelope |
| Every registry/factory kind | Automatic evidenced/unknown/unsupported expectations plus finite declaration, actual-mode and default-omission checks; no claim that registry coverage proves every upstream model |
| OpenCode Go recognized reasoning family | Selector uses the OpenAI Chat effort descriptor and supported ordered tiers |
| OpenCode Go exact DeepSeek V4.1 Flash (`deepseek-v4.1-flash`) | Exact model-owned DeepSeek facts override the Go generic effort policy: selector visible with `Off`/`Low`/`High`/`Max` and default `High`; `off` sends disabled thinking with no effort, `low`/`high`/`max` send enabled thinking plus that exact `reasoning_effort`; an empty/null selection sends neither field; the wire keeps the exact model id |
| DeepSeek documented effort remaps | `minimal`/`medium`/`xhigh`/`ultra` are never visible tiers and are rejected as selections (`optionUnavailable`) instead of being relabelled |
| DeepSeek V4.1 near-IDs (`deepseek-v4.1-flash-x`, `deepseek-v4.1-flash-thinking`, `deepseek-v41-flash`, `deepseek-v4-1-flash`, `deepseek-v4.1`, casing variants) | Remain unevidenced: Go keeps its generic result, the chip stays hidden, and a selection is rejected before HTTP; no family/prefix/substring rule may promote them |
| OpenCode Go unknown model with `supports_reasoning_output=true` | Control remains unavailable; reasoning output alone does not invent selectable effort |
| Explicit empty `thinking_mode` session preference | Client transmits the present empty field; daemon clears persistence and emits `thinking_mode: null` |
| Client `thinking_mode_source=model` | Composer uses model/`thinking_control` options only; empty list does not fall back to `balanced` |
| Client exact model descriptor identity | Resolves thinking descriptors using exact model ID; preserves catalog namespaces (`VendorA/model` vs `VendorB/model`), case (`CaseModel` vs `casemodel`), and variant markers (`~`, `:`); strips only transport-owned provider-instance prefixes (`provider-1/`) with exact boundaries |
| Client unsupported descriptor | Thinking chip hidden |
| Client initial descriptor load | Shows `Loading...` until the authoritative snapshot arrives |
| Client authoritative unknown descriptor | Shows `Default` / provider-managed behavior; does not invent selectable controls or display a false `Unavailable` state |
| Route revision mismatch | Stale session descriptor ignored |
| Explicit model refresh on mounted route | Composer updates options, default, and capability revision without route change or restart |
| Model refresh invalidating current selection | Selection repaired visibly to provider default (`null`), retaining valid selections |
| Model refresh removing descriptor or marking unsupported | Transitions visibly to provider-managed (`Default`) or hidden |
| Failed, late, or cross-device model update events | Retains prior validated authority on failure; ignores foreign device/provider events |
| Model/provider switch invalidating selection | Preference cleared + correction event |
| Daemon restart with queued turn | Revalidates persisted selection before provider call |

## Automated anchors

- `agent/test/core/provider_thinking/`
- `agent/test/core/provider_thinking/ollama_live_thinking_ttl_retention_test.dart` (real `OllamaAdapter` over mock HTTP: >5-minute native On/Off/default typed wire, malformed discovery, refresh-failure markers, revision change)
- `agent/test/interfaces/runtime/thinking_selection_rejection_test.dart` (turn-admission rejection commits the owned durable item before delivering; stale non-owner rejection stays silent and preserves the newer owner and its in-flight state)
- `agent/test/core/provider_thinking/opencode_go_deepseek_v41_thinking_regression_test.dart` (exact V4.1 Flash policy/descriptor, production Go Chat mock-HTTP default/Off/effort wire, near-ID negatives)
- `agent/test/engine/thinking_selection_agent_runner_test.dart`
- `agent/e2e_test/thinking_mode_gate_i_e2e_test.dart` (`--concurrency=1`)
- `client/test/unit/conversations/route_thinking_control_test.dart` (exact model identity, freshness arbitration, route binding)
- `client/test/unit/conversations/opencode_go_deepseek_v41_thinking_selector_test.dart` (exact V4.1 descriptor visibility, grounded default label, near-ID hidden negative)
- `client/test/widget/route_thinking_mode_selector_test.dart` (exact identity, refresh lifecycle, invalidation repair, restoration, exact V4.1 visible tiers)
- `client/test/unit/provider_setup/provider_setup_client_impl_test.dart` (event stream projection)
- `client/test/unit/provider_setup/model_cache_snapshot_dto_test.dart` (event parsing)
- `client/test/unit/bloc/conversation_input_cubit_test.dart` (model-scoped defaults/clear)
