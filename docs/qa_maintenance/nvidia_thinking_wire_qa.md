---
title: "NVIDIA NIM Native Thinking Wire QA"
description: "Focused coverage for the typed chat_template_kwargs toggles, the wire-dialect gate, and the self-hosted-only Qwen declaration on NIM routes."
---

# NVIDIA NIM Native Thinking Wire QA

## Scope

Validates the NIM Chat wire: the typed `chat_template_kwargs` Boolean serializer
and declaration validation, that a first-party native extension never leaks onto
a generic/local/custom Chat route, and that self-hosted-only facts stay behind an
explicit validated declaration.

Hosted NIM model controls come from the five-layer authority (settings →
provider-reported metadata → shipped defaults → models.dev → `unknown`; see
[Provider Protocol §2.3](../technical/provider_protocol.md)). The documented
hosted contracts are shipped-default data with route class `nim`, applied only
on the hosted catalog:
* `deepseek-ai/deepseek-v4-flash` / `-pro`: `none`/`high`/`max`, default `high`;
* `moonshotai/kimi-k3`: `low`/`high`/`max`, default `max`;
* `moonshotai/kimi-k2.6`: `chat_template_kwargs.thinking` on/off;
* `qwen/qwen3.5-122b-a10b`: `enable_thinking` on/off.

They are not Dart tables. A model name alone, hosted or self-hosted, never gains
controls.

## Matrix

| Scenario | Expected |
|---|---|
| Hosted documented ids (shipped `nim` records) | `deepseek-ai/deepseek-v4-flash`/`-pro` resolve `none`/`high`/`max` default `high` on `reasoning_effort` with no `thinking` envelope |
| Any `nvidia` model without a record in any layer (for example `qwen/qwen3.8-27b`, `deepseek-ai/deepseek-v4.1-flash`) | `unknown`, no options; an explicit selection is admitted with the provider default and sends no thinking field |
| Hosted contracts on an incompatible mode (Anthropic Messages route) | Advertise nothing |
| Aggregator (`openrouter`) | Unchanged `reasoning` envelope ownership, with only canonical admitted effort `none`, a zero Google budget and a typed false toggle as disables |
| Self-hosted `qwen/qwen3.8-27b` **without** a declaration | `unknown` on both the hosted route and generic routes; never added to the shipped NVIDIA fallback list |
| Self-hosted `qwen/qwen3.8-27b` **with** the explicit declaration (`wire: nim_qwen_thinking`, options `off`/`low`/`medium`/`xhigh`, default `xhigh`) | `low`/`medium`/`xhigh` reach `reasoning_effort`; `off` reaches `chat_template_kwargs: {enable_thinking: false}`; the declared default stays descriptor metadata and is dispatched only when explicitly selected |
| Provider-default omission (both authorities) | For configuration **and** endpoint declarations, a null/empty/whitespace selection is `UseProviderDefault` with a null selection id and an omission body (no `reasoning_effort`, no `chat_template_kwargs`, no `reasoning`); an explicitly selected advertised default still dispatches its exact value, and an explicit unsupported selection rejects before dispatch |
| Canonical mapping invariant (all typed controls) | On `openai_chat_effort`, `codex_responses_effort`, `anthropic_adaptive` and `google_thinking`, every canonical tier/level id must carry its own canonical value — the full cross-product of mismatched pairs is rejected, while opaque ids may still carry an explicit admitted value (effort string, numeric budget) and the documented disables stay (`off`/`none` effort, `off: 0` and `off: 'off'` Google zero budget, `off: false` adaptive). On the generic `toggle_effort` wire a canonical effort label may not hide either Boolean, while genuine `on`/`off` and honest custom Boolean ids stay admissible |
| Declared canonical Google Minimal (actual body) | A declaration selecting `minimal` on the `gemini` route emits `extra_body.google.thinking_config.thinking_level: minimal` (exact canonical value, never remapped) with no flat `reasoning_effort`, in exactly one request |
| Canonical effort ids on kwargs wires | `minimal`/`low`/`medium`/`high`/`xhigh`/`max` reject **both** Boolean values (no effort label may hide an unspecified enabled/default Boolean); genuine `on`/`off`, honest custom Boolean ids and the exact Qwen `low`/`medium`/`xhigh` mappings stay admissible |
| Declaration validation | A fake-off value or an unknown wire id is rejected with an actionable configuration error instead of being silently accepted; a canonical effort id must carry its own canonical value (no remap/elevation), and a tier id must not hide a disable |
| Protocol admission of a kwargs declaration | `nim_kimi_thinking`/`nim_qwen_thinking` require the normalized OpenAI-compatible Chat protocol **and** an eligible serializer dialect: an Anthropic or native-Ollama protocol rejects them even when the configured API-mode string is `chat`/`chat_completions`, and an endpoint declaration on such a route is non-selectable and rejects before dispatch with zero requests |
| Google level no-remap (all canonical tiers) | Every canonical effort-tier id crossed with every admitted Google string level: only the exact matching level is accepted; `xhigh`/`max` reject every level (including their own name, which is not an admitted level); genuinely opaque ids may still map to an admitted level and numeric budget tiers stay valid |
| Serializer compatibility of a kwargs declaration | `nim_kimi_thinking`/`nim_qwen_thinking` are non-selectable (and reject before dispatch with zero requests) on the aggregator envelope, a Responses route, a Messages route and native Ollama; a legitimate generic/custom Chat route and the hosted NIM Chat catalog stay selectable |
| Canonical effort vocabulary | A declaration may use the full documented effort enum including canonical `minimal` and `max`; the declared values reach Chat `reasoning_effort`, the aggregator `reasoning.effort` and the Responses `reasoning.effort` exactly, and Default omission stays empty |
| Invalid typed values | A non-admitted effort/level, a negative budget, a non-positive Anthropic budget or a directive the envelope cannot carry raises a typed serialization failure while the body is built — never a silent omission, remap or dispatch |
| Request hygiene | Exactly one HTTP request per dispatch: no request-time probe, and omission emits no thinking field |

## Automated anchors

- `agent/test/core/provider_thinking/nim_thinking_wire_test.dart` (template kwargs, negatives, incompatible mode, declaration validation, self-hosted declaration, one-request-per-dispatch)
- `agent/test/core/provider_thinking/layered_thinking_authority_test.dart` (layered authority and per-wire request bodies)
- `agent/test/core/provider_thinking/provider_thinking_test.dart` (aggregator disable/admission codec rules, template policy mapping)
