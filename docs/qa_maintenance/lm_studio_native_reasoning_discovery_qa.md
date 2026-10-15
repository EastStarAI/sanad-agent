---
title: "LM Studio Native Reasoning Discovery QA"
description: "Focused matrix for bounded LM Studio native reasoning discovery from GET /api/v1/models into the declared descriptor and the actual Chat body."
---

# LM Studio Native Reasoning Discovery QA

## Scope

Verifies that an LM Studio route exposes only the finite thinking options the
local server declares for the exact model, that every advertised option reaches
the real OpenAI-compatible Chat request body unchanged, and that absent,
failing, malformed or ambiguous native evidence fabricates no control.

Out of scope for this page:

- Live LM Studio execution, real Home/credential/runtime mutation and model
  sends. All coverage here is deterministic and loopback-bound.
- The native `POST /api/v1/chat` protocol. Sanad keeps its existing
  OpenAI-compatible `/v1` transport; no protocol is inferred from discovery.
- `capabilities.vision`. It remains unexploited native evidence owned by the
  image-capability lane; LM Studio image support is unchanged here.

## Grounding

- `GET /api/v1/models` documents model-owned `capabilities.reasoning.allowed_options`
  (`off | on | low | medium | high`) and `capabilities.reasoning.default`, both
  absent when the model exposes no public reasoning configuration
  (`https://lmstudio.ai/docs/developer/rest/list`).
- LM Studio 0.4.8 documents `reasoning_effort` support on the OpenAI-compatible
  `v1/chat/completions` endpoint
  (`https://lmstudio.ai/changelog/lmstudio/lmstudio-v0.4.8`).
- `on` and `off` are native-only values. No exact documentation maps them onto
  `reasoning_effort`, so they are never advertised and never remapped to another
  value.

## Path under verification

`BaseOpenAIAdapter.getAvailableModels` (OpenAI-compatible `/v1/models` discovery
plus one native `/api/v1/models` evidence read) → `ProviderModelCacheService`
refresh → `ThinkingCapabilityAssembler` declared-endpoint tier → authoritative
cached descriptor → `ThinkingSelectionResolver` → `BaseOpenAIAdapter` actual
`/chat/completions` body.

Raw native evidence is stored separately from the derived declaration: the
verbatim `capabilities.reasoning` object stays under `model_metadata.lm_studio_reasoning`,
while `model_metadata.thinking_control` carries the finite declared control that
the existing declaration authority validates. No enriched descriptor is written
back into raw endpoint evidence.

## Matrix

| # | Scenario | Expected |
|---|---|---|
| 1 | Native declaration `allowed_options: [off, on, low, medium, high]`, `default: medium` | Raw `lm_studio_reasoning` evidence plus an `openai_chat_effort` declaration containing exactly `low`/`medium`/`high`; supported descriptor of kind effort with labels Low/Medium/High, `default_option_id: medium`, source `endpoint_declared` |
| 2 | Each advertised option selected | Actual body carries `reasoning_effort` equal to the selected native value with no value remap; no `thinking` envelope is invented; the wire model id is unchanged |
| 3 | Native `default: high` | The default selection reproduces the declared native default (`reasoning_effort: high`) instead of an invented tier |
| 4 | Native `default: on` (no evidenced wire value) | Options stay `low`/`medium`/`high`, `default_option_id` is absent, and the default selection omits `reasoning_effort` entirely |
| 5 | Native declaration `[off, on]` only | Raw evidence is retained, no declaration is produced, the descriptor stays `unknown`, an explicit level is rejected with `thinking_capability_unknown`, and nothing is dispatched |
| 6 | Malformed finite list (`bogus` value, mixed types, empty list, non-list `allowed_options`), default outside the declared list, non-string default, non-object `reasoning` | No declaration, no retained evidence, descriptor `unknown`, zero dispatch |
| 7 | Native probe HTTP failure, transport failure, or a non-object payload | Compatibility discovery is preserved (`live` source, same label and context), no declaration, descriptor `unknown`, and the request is still dispatched without any thinking field |
| 8 | Identity: exact `key`; `loaded_instances[].id`; case-distinct id; id absent from the native list; two native entries claiming one id | A declaration only for a single exact match; case-distinct, absent and ambiguous identities stay `unknown` with no declaration and no evidence key |
| 9 | Request assembly after a completed refresh | No additional native or compatibility endpoint probe; exactly one `/chat/completions` dispatch |
| 10 | One native entry repeats its `key` as one or more `loaded_instances[].id` values | Repeated aliases of the same entry count once, so the descriptor stays supported and selected High reaches the actual Chat body; two distinct native entries remain ambiguous |
| 11 | Native endpoint requires configured authentication | Reuse the same existing authentication and profile headers as compatibility model discovery; supported descriptor and selected High survive |
| 12 | Compatibility discovery already contains a thinking declaration conflicting with native evidence | Preserve the original compatibility declaration and its selected wire unchanged; do not overwrite it or attach competing native reasoning evidence |

Independent review added scenario 10 after the original nine passed: the
unmodified candidate returned `unknown` instead of `supported` (exit 1). The
bounded correction counts distinct native entries by identity rather than
counting repeated aliases. Two additional independent red regressions then
proved that the native read omitted configured authentication and could replace
an existing compatibility declaration. Native discovery now shares the existing
model-discovery authentication headers, and enrichment leaves an already-present
compatibility declaration untouched (even if malformed), rather than promoting
or silently replacing its authority. All twelve focused scenarios and 228
focused/adjacent tests pass; Agent analysis reports no issues. This is source
acceptance only, not live execution.

## Verification steps

1. Run the focused regression file
   `agent/test/engine/adapters/lm_studio_native_thinking_discovery_test.dart`;
   all twelve scenarios must pass over the disposable Home, loopback `MockClient`
   and in-memory state database described below.
2. Confirm the original red baseline, not only the green result: with native enrichment
   absent, eight of the original nine scenarios fail (advertised-option discovery,
   descriptor delivery, per-option Chat bodies, default preservation, unmappable
   default, probe-failure preservation, identity/ambiguity, and probe
   boundedness). Scenario 6 is a negative-only check and passes in both states by
   design.
3. Re-run the owning neighbour suites when the adapter discovery path changes:
   the adapter, provider-thinking coverage, model-cache and runtime-service
   suites must stay green, since LM Studio shares the OpenAI-compatible adapter
   with the other chat kinds.

Automated coverage ownership: `agent/test/engine/adapters/lm_studio_native_thinking_discovery_test.dart`
owns native evidence parsing, exact/ambiguous identity matching, declaration
derivation, descriptor delivery through the production model cache,
`reasoning_effort` bodies for every advertised option, default preservation
versus omission, fail-closed malformed/probe-failure behavior, and the absence of
request-time endpoint probes. `agent/test/core/provider_thinking/project_thinking_coverage_test.dart`
retains the registry-wide claim that an unevidenced `lm-studio` model with no
native evidence stays `unknown`.

## Harness boundaries

The suite provisions one `Directory.systemTemp` Home through the sanctioned
Home override, one in-memory state database, and one loopback `MockClient` that
serves `/v1/models`, `/api/v1/models` and `/v1/chat/completions`. It never reads
or writes a real Home, credential, provider instance, runtime port, UI surface or
upstream model. Failure fixtures return an HTTP error, throw a transport
exception, or return a malformed payload, so "no fabrication" is proven by
absence of declaration and absence of wire fields rather than by a mocked
success path.

## Evidence limits

- Automatic mock-HTTP coverage only. No live LM Studio server was queried, so
  this page makes no claim about any specific installed model or about LM
  Studio's own removal/renaming of these native values in future versions.
- Only the `low`/`medium`/`high` intersection with the documented
  compatibility-Chat `reasoning_effort` is advertised. A model whose native
  declaration exposes only `on`/`off` therefore shows no selectable level here,
  which is intentional honesty, not a missing feature.
- The context-length probe for LM Studio is unchanged in behavior; it now shares
  one native base-URL derivation with discovery. Its own wire proof is owned by
  the existing context-limit coverage, not by this page.
- Full fast suites, live runtime acceptance and delivery gates remain owned by
  the parent task; this page covers only the bounded native-discovery lane.
