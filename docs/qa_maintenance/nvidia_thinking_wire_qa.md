---
title: "NVIDIA NIM Native Thinking Wire QA"
description: "Focused coverage for hosted NIM per-model thinking contracts, the typed chat_template_kwargs toggles, the wire-dialect gate, and the self-hosted-only Qwen declaration."
---

# NVIDIA NIM Native Thinking Wire QA

## Scope

Validates that the shipped `nvidia` template (the hosted NVIDIA NIM catalog,
`https://integrate.api.nvidia.com/v1`, OpenAI-compatible Chat) exposes only its
own documented per-model contracts, that a first-party native extension never
leaks onto a generic/local/custom Chat route merely because a model id matches,
and that self-hosted-only facts stay behind an explicit validated declaration.

Official evidence used (read-only, published documentation):

* hosted `deepseek-ai/deepseek-v4-flash` / `deepseek-ai/deepseek-v4-pro` —
  `reasoning_effort` accepts `none`/`high`/`max`, default `high`, `none`
  disables thinking; no `thinking.type` envelope is documented;
* hosted `moonshotai/kimi-k3` — `reasoning_effort` `low`/`high`/`max`, default
  `max`;
* hosted `moonshotai/kimi-k2.6` — `chat_template_kwargs: {"thinking": bool}`, no
  documented default;
* hosted `qwen/qwen3.5-122b-a10b` — `chat_template_kwargs:
  {"enable_thinking": bool}`;
* self-hosted NIM container `qwen/qwen3.8-27b` — `reasoning_effort`
  `low`/`medium`/`xhigh` (default `xhigh`) plus
  `chat_template_kwargs {"enable_thinking": false}`.

## Matrix

| Scenario | Expected |
|---|---|
| `nvidia` + `deepseek-ai/deepseek-v4-flash` / `-pro` | Supported effort kind, options exactly `none`/`high`/`max`, default `high`, `none` marked Off; every selection reaches Chat `reasoning_effort` with **no** `thinking` envelope and no `chat_template_kwargs`; provider Default omits the field |
| `nvidia` + `moonshotai/kimi-k3` | Supported effort, options `low`/`high`/`max`, default `max`, never an Off; every value reaches `reasoning_effort` with no `thinking` |
| `nvidia` + `moonshotai/kimi-k2.6` | Supported toggle, options `on`/`off`, **no** default; `on`/`off` emit `chat_template_kwargs: {thinking: true/false}` only (no `reasoning_effort`, no `thinking`); Default omits both |
| `nvidia` + `qwen/qwen3.5-122b-a10b` | Same, with the documented `enable_thinking` key |
| Hosted ids without documented controls (`deepseek-ai/deepseek-v4.1-flash`, `moonshotai/kimi-k2-thinking`, `qwen/qwen3-next-80b-a3b-thinking`) and self-hosted/other-transport ids (`qwen/qwen3.8-27b`, bare `deepseek-v4-flash`, bare `kimi-k3`, `kimi-k2.6`) plus casing/variant near-ids | `unknown` with no options; a selection is rejected before dispatch |
| Hosted contracts on an incompatible mode (Anthropic Messages route) | Advertise nothing |
| Generic compatible Chat route (custom) hosting `deepseek-v4-flash` | Only the documented standard effort ladder `low`/`high`/`max` with `reasoning_effort` and no native envelope; no invented disable and no invented default |
| Generic/local carrier hosting a toggle-only family (`kimi-k2.6`, `glm-4.5`) | `unknown`: the family's only documented control is its native envelope, which that wire does not evidence |
| First-party and partner dialects (`deepseek`, `kimi`, `zai`, `zai-coding`, `opencode-go`) | Their documented native semantics are unchanged, including the accepted Go V4.1 `Off`/`Low`/`High`/`Max` behavior |
| Aggregator (`openrouter`) | Unchanged `reasoning` envelope ownership, with only canonical admitted effort `none`, a zero Google budget and a typed false toggle as disables |
| Self-hosted `qwen/qwen3.8-27b` **without** a declaration | `unknown` on both the hosted route and generic routes; never added to the shipped NVIDIA fallback list |
| Self-hosted `qwen/qwen3.8-27b` **with** the explicit declaration (`wire: nim_qwen_thinking`, options `off`/`low`/`medium`/`xhigh`, default `xhigh`) | `low`/`medium`/`xhigh` reach `reasoning_effort`; `off` reaches `chat_template_kwargs: {enable_thinking: false}`; the declared default stays descriptor metadata and is dispatched only when explicitly selected |
| Provider-default omission (both authorities) | For configuration **and** endpoint declarations, a null/empty/whitespace selection is `UseProviderDefault` with a null selection id and an omission body (no `reasoning_effort`, no `chat_template_kwargs`, no `reasoning`); an explicitly selected advertised default still dispatches its exact value, and an explicit unsupported selection rejects before dispatch |
| Canonical mapping invariant (all typed controls) | On `openai_chat_effort`, `codex_responses_effort`, `anthropic_adaptive` and `google_thinking`, every canonical tier/level id must carry its own canonical value — the full cross-product of mismatched pairs is rejected, while opaque ids may still carry an explicit admitted value (effort string, numeric budget) and the documented disables stay (`off`/`none` effort, `off: 0` and `off: 'off'` Google zero budget, `off: false` adaptive). On the generic `toggle_effort` wire a canonical effort label may not hide either Boolean, while genuine `on`/`off` and honest custom Boolean ids stay admissible |
| Declared canonical Google Minimal (actual body) | A declaration selecting `minimal` on the `gemini` route emits `extra_body.google.thinking_config.thinking_level: minimal` (exact canonical value, never remapped) with no flat `reasoning_effort`, in exactly one request |
| Canonical effort ids on kwargs wires | `minimal`/`low`/`medium`/`high`/`xhigh`/`max` reject **both** Boolean values (no effort label may hide an unspecified enabled/default Boolean); genuine `on`/`off`, honest custom Boolean ids and the exact Qwen `low`/`medium`/`xhigh` mappings stay admissible |
| Declaration validation | A fake-off value or an unknown wire id is rejected with an actionable configuration error instead of being silently accepted; a canonical effort id must carry its own canonical value (no remap/elevation), and a tier id must not hide a disable |
| Hosted Boolean Off metadata | `moonshotai/kimi-k2.6` and `qwen/qwen3.5-122b-a10b` mark their documented `off` choice as an actual disable (`isOff`), with **no** invented default |
| Protocol admission of a kwargs declaration | `nim_kimi_thinking`/`nim_qwen_thinking` require the normalized OpenAI-compatible Chat protocol **and** an eligible serializer dialect: an Anthropic or native-Ollama protocol rejects them even when the configured API-mode string is `chat`/`chat_completions`, and an endpoint declaration on such a route is non-selectable and rejects before dispatch with zero requests |
| Google level no-remap (all canonical tiers) | Every canonical effort-tier id crossed with every admitted Google string level: only the exact matching level is accepted; `xhigh`/`max` reject every level (including their own name, which is not an admitted level); genuinely opaque ids may still map to an admitted level and numeric budget tiers stay valid |
| Serializer compatibility of a kwargs declaration | `nim_kimi_thinking`/`nim_qwen_thinking` are non-selectable (and reject before dispatch with zero requests) on the aggregator envelope, a Responses route, a Messages route and native Ollama; a legitimate generic/custom Chat route and the hosted NIM Chat catalog stay selectable |
| Canonical effort vocabulary | A declaration may use the full documented effort enum including canonical `minimal` and `max`; the declared values reach Chat `reasoning_effort`, the aggregator `reasoning.effort` and the Responses `reasoning.effort` exactly, and Default omission stays empty |
| Invalid typed values | A non-admitted effort/level, a negative budget, a non-positive Anthropic budget or a directive the envelope cannot carry raises a typed serialization failure while the body is built — never a silent omission, remap or dispatch |
| Compatible subset provenance | The generic-carrier positive effort ladder is derived from the existing exact DeepSeek/Kimi authorities (verified aliases included, native-only `off`/defaults excluded); case/namespace/variant negatives stay unknown |
| Request hygiene | Exactly one HTTP request per dispatch: no request-time probe, and omission emits no thinking field |

## Automated anchors

- `agent/test/core/provider_thinking/nim_thinking_wire_test.dart` (hosted contracts, template kwargs, negatives, incompatible mode, declaration validation, self-hosted declaration, one-request-per-dispatch)
- `agent/test/core/provider_thinking/provider_kind_wire_matrix_test.dart` (53 fixture rows plus identity/negative groups, 110 tests total): each row asserts the descriptor's documented `status`, `kind`, option set and `default_option_id` as independent literals, then the literal per-option captured-body expectations, including the hosted NIM rows and the reclassified generic carriers. The test mirrors runtime factory selection and drives the real production adapters with a `MockClient`; it does not invoke the runtime adapter factory, and the daemon wiring is verified separately.
- `agent/test/core/provider_thinking/project_thinking_coverage_test.dart` (registry/template policy mapping incl. `nvidia → nim_thinking`, native/partner dialect loop, carrier reclassification)
- `agent/test/core/provider_thinking/provider_thinking_test.dart` (aggregator disable/admission codec rules, template policy mapping)
