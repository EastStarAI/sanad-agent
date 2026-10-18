---
title: "OpenRouter Reasoning Discovery QA"
description: "Focused matrix for bounded OpenRouter finite reasoning declaration discovery from the documented /models reasoning metadata into the declared descriptor and the actual Chat body."
---

# OpenRouter Reasoning Discovery QA

## Scope

Verifies that an OpenRouter route exposes only the finite effort options the
gateway documents for the exact model, that every advertised option reaches the
real OpenAI-compatible Chat request body with its exact documented value, and
that absent, malformed, ambiguous or unrepresentable evidence fabricates no
control and remaps no value.

Out of scope for this page:

- Live OpenRouter execution, real Home/credential/runtime mutation and model
  sends. All coverage here is deterministic and loopback-bound.
- Reasoning-output observation and persistence. Thinking output is not thinking
  control; a `reasoning` name coincidence, an output flag or a vendor name never
  authorizes a selectable control.
- Token-budget reasoning. `supports_max_tokens` is preserved as raw evidence
  only; no budget choice, default or bound is invented here.
- The aggregator Chat codec. The disable envelope
  (`reasoning.effort: "none"`) and the typed directive translation stay owned by
  the core writer; this page asserts the observed production body only.

## Grounding

Official aggregator authority:
`https://openrouter.ai/docs/guides/best-practices/reasoning-tokens.md`

- Each model in `GET /api/v1/models` may include a `reasoning` object
  describing which effort levels it accepts and whether reasoning is mandatory.
- `supported_efforts`: "Filter effort selectors to these values, returned in
  descending effort order (highest first). When `null`, all gateway effort
  values are accepted. When omitted, the model does not expose effort
  selection."
- `default_effort`: "Pre-select this effort when enabling reasoning. Maps to
  `reasoning.effort` in chat requests. If the value is `"none"`, treat it as
  `"reasoning off by default"` rather than pre-selecting disable when the user
  explicitly turns reasoning on."
- `default_enabled`: "Default on/off state when the user has not set
  `reasoning.enabled`."
- `supports_max_tokens`: "When present and `true`, show a token budget control
  and send `reasoning.max_tokens`". Omitted when the model does not support
  token-budget reasoning.
- `mandatory`: "When `true`, hide disable controls and do not send
  `effort: "none"` — the model rejects it."
- Documented effort values: `max`, `xhigh`, `high`, `medium`, `low`, `minimal`,
  `none`, where `none` "Disables reasoning entirely".
- "Non-reasoning models and dynamic router models (`openrouter/auto`,
  `openrouter/free`) omit the `reasoning` field."

## Path under verification

`BaseOpenAIAdapter.getAvailableModels` (`GET /models` discovery of the
registered aggregator wire, including each item's `reasoning` metadata) →
`ProviderModelCacheService` refresh → `ThinkingCapabilityAssembler`
declared-endpoint tier → authoritative cached descriptor →
`ThinkingSelectionResolver` → `BaseOpenAIAdapter` actual `/chat/completions`
body.

Recognition is provider-kind identity, not URL substring guessing: only the
registered `openrouter` template consumes this schema. A custom/local/generic
Chat endpoint keeps its existing behavior, and no global model control is ever
inferred from a names-only model list.

Raw evidence is the verbatim discovery member already carried on the model item
(`model_metadata.reasoning`); the validated declaration is written separately to
`model_metadata.thinking_control`, which the existing declaration authority
parses. A declaration already owned by the compatibility discovery wire is left
untouched — aggregator enrichment never replaces or competes with it.

The route's own documented finite set always wins over static catalog
knowledge for that exact route: a discovered declaration is authoritative, an
unusable declaration publishes explicit `unknown` route evidence rather than
adopting an unrelated ladder (see below), and `openai_chat_effort` (typed) is the
only wire declared here.

## Mandatory, Disable and Default Rules

- `mandatory: true` means no Off option and no `effort: "none"` dispatch. The
  documented disable value is removed from the advertised set, and a stale
  explicit `Off`/`none` selection is rejected by existing admission with zero
  dispatch — never silently dropped, remapped or dispatched.
- `mandatory` is never inferred to be `false` from an omitted member: an omitted
  `mandatory` with `none` in the documented set still advertises Off.
- `default_effort: "none"` documents off-by-default, so it is never preselected
  as a disable; `default_enabled: false` likewise preselects nothing.
- A documented default stays truthful descriptor metadata (`default_option_id`)
  and is dispatched only when it is actually selected. An omitted, cleared or
  whitespace-only selection is always provider-default omission, including with a
  known `default_effort`; the shared resolver owns that contract, and discovery
  never turns omission into an explicit request field.
- An absent `default_effort` stays absent. `default_enabled` never implies a
  level from omission, and no active default is invented for an off-by-default
  route.

## Full documented effort vocabulary (repaired seam)

The typed `openai_chat_effort` declaration authority now validates against the
shared `ThinkingWireVocabulary.effortIds` (`none`, `minimal`, `low`, `medium`,
`high`, `xhigh`, `max`), which the aggregator Chat serializer consumes as well,
so declaration validation and serialization can never drift. Discovery therefore
uses that same shared admissibility instead of a local list: a finite documented
set is declared exactly as documented, and an explicit `null` (all gateway
values) is declared as all seven values in documented descending order.

Bounded consequences that are now proven rather than reported as a seam:

- `minimal` is declared truthfully beside `low`. The legacy alias migration in
  `migrateLegacyThinkingSelectionId` returns the id unchanged whenever the route
  actually advertises it, so selecting `minimal` sends `minimal` — it is never
  silently remapped to `low`.
- `max` is declared truthfully beside `xhigh`: neither promotes, clamps nor
  resets the other; each reaches the body with its own exact value.
- `none` stays the documented disable envelope (`reasoning: {effort: none}`),
  whether it is documented alone or inside a wider set.
- No documented value is copied, type-adapted, reduced to a partial ladder or
  aliased onto another tier, and no budget choice, default or bound is invented.

## Explicit route evidence vs. names-only discovery

The two discovery outcomes are deliberately different, and the tests that would
otherwise bless an unsafe native fallback were updated:

- **Names-only / no `reasoning` member** — absence of new evidence. Nothing is
  published, so existing authority and intrinsic model knowledge survive: an
  intrinsically evidenced catalog model keeps its documented ladder, and the
  synthetic unknown model keeps its unsupported answer.
- **`reasoning` member present but yielding no trustworthy declaration** — the
  wire's own evidence owns that exact route's control state. Discovery publishes
  explicit `unknown` route-control evidence (`thinking_control: {status: unknown}`,
  source `endpoint_declared`) instead of silently adopting an unrelated intrinsic
  ladder. This covers a missing effort member with `reasoning` present, an empty
  effort list, malformed values or flags, and a default inconsistent with the
  documented set. It does **not** apply to a well-formed explicit `null`
  (all-gateway-values), which is now a truthfully supported declaration.

Duplicate identity checks include both the presence and value of the raw
`reasoning` member. A mixed names-only/declared pair is ambiguous in either
response order and publishes unknown control evidence for both entries; the
names-only entry cannot revive a wider intrinsic ladder, and a stale Medium is
refused without dispatch when the only finite claim is High. An entirely
names-only response still publishes nothing, and existing compatibility
declarations stay untouched.

Explicit `null`, an empty list and an omitted effort member stay distinguishable
(all three publish or preserve different evidence), and no case invents a
default, option, budget choice or bound. Only `thinking_control` is published as
route evidence: model-owned image, reasoning-output, context and other
discovery facts stay untouched, a model-only configuration override still wins,
and a previously selectable tier is refused before dispatch.

## Matrix

| # | Scenario | Expected |
|---|---|---|
| 1 | Discovered `supported_efforts: [high, medium, low]`, `default_effort: low`, `default_enabled: true` | Live source; verbatim raw evidence; `openai_chat_effort` declaration with exactly those three options and `default_option: low`; supported effort descriptor with labels High/Medium/Low, `default_option_id: low`, source `endpoint_declared`; unrelated label/context/tool metadata untouched |
| 2 | Every advertised option selected on a route documenting `xhigh/high/medium/low` | Actual body carries `reasoning: {enabled: true, effort: <exact selected value>}`; no `reasoning_effort` leak; `supports_max_tokens: true` creates no budget field, option or default |
| 3 | Documented `default_effort` present | It stays truthful `default_option_id` metadata; an omitted, empty or whitespace-only selection is still provider-default omission with no `reasoning` field, and the documented value reaches the exact body only when it is actually selected |
| 4 | `default_effort` absent | `default_option_id` absent; Default is a real omission with no `reasoning` field at all |
| 5 | `default_effort: none`, `default_enabled: true` | Options keep `none` advertised as an Off option, `default_option_id` absent, Default omits the field, and selecting Off dispatches the documented disable envelope |
| 6 | `default_enabled: true` without a default effort | No effort default is implied; options are unchanged |
| 7 | `default_enabled: false` with a documented default effort | Options unchanged, nothing preselected, Default stays omission |
| 8 | `mandatory: true` with `none` documented | No Off option is advertised, a stale `Off`/`none` selection is rejected with zero dispatch, and a supported selection still reaches the exact body |
| 9 | `mandatory` omitted with `none` documented | Off remains advertised; mandatory is not inferred |
| 10 | Only `none` documented | Honest single-option effort control: Off advertised, nothing preselected, Default omits the field |
| 11 | `supported_efforts: null` (all gateway values) with a known `default_effort: high` | Supported declaration of all seven values in documented descending order (`max, xhigh, high, medium, low, minimal, none`), equal to the shared `ThinkingWireVocabulary.effortIds`, with `none` as the single Off option and `default_option_id: high`; each of the seven advertised values is dispatched and captured with its own exact envelope (`{enabled: true, effort: <value>}`, and exactly `none` as `{effort: none}`), with no flat `reasoning_effort` and correct model identity; omitted, empty and whitespace-only selections still omit every thinking field |
| 11a | Empty effort list; a present `reasoning` member with no effort member | Explicit `unknown` route-control evidence with raw evidence verbatim, an `unknown` descriptor from `endpoint_declared`, no options, no default, zero dispatch — never an unrelated ladder |
| 12 | Finite documented sets across the full vocabulary: all seven values, `max/xhigh/low`, `minimal/low`, `max/low`, `minimal/max` | Declared exactly as documented, in documented order, with no reduction, clamping, promotion or aliasing: `minimal` beside `low` stays `minimal` (no legacy alias remap), `max` beside `xhigh` stays `max` with no reset, `none` inside a wider set is the disable envelope, and each advertised value reaches the actual body |
| 13 | Malformed declarations (non-object `reasoning`, non-list/`bogus`/case-shifted/padded/duplicate/mixed-type effort lists, default outside the documented set or non-string, non-Boolean `mandatory`/`default_enabled`, mandatory with only `none`) | Explicit `unknown` route-control evidence, raw evidence verbatim, `unknown` descriptor from `endpoint_declared` with no options and no default, zero dispatch |
| 13a | The same malformed/no-effort declarations on an intrinsically evidenced model with image, tool and output facts on the item | Explicit `unknown` route evidence for the exact route; verbatim architecture/tool/context metadata, reasoning-output flag and label preserved; each previously selectable intrinsic tier (`low`/`medium`/`high`/`none`) refused with zero dispatch; a real Default omission still dispatches a normal request and adds no endpoint probe |
| 14 | No usable evidence on a synthetic unknown model; a names-only item whose id merely suggests reasoning output; the same absence on an intrinsically evidenced catalog model | The unevidenced synthetic model stays unsupported (`profile`) and the names-only item keeps its reasoning-output flag while advertising no control; the catalog model keeps its intrinsic options — proving the discovery path, not a static catalog coincidence |
| 15 | The same documented `reasoning` metadata served by a generic `custom` Chat endpoint | The item is still discovered, but the aggregator schema is not consumed: no declaration, `unknown` descriptor, zero dispatch — recognition is provider identity, not a URL substring |
| 16 | A declaration discovered for an intrinsically evidenced model id | The declared set is authoritative for that exact route (`endpoint_declared`), not the catalog ladder |
| 17 | The full documented vocabulary (a finite `max/minimal` set and an explicit `null` set) on a catalog-known exact route | The documented set is declared truthfully and is authoritative over the intrinsic catalog ladder for that route; an intrinsic tier outside the documented set is refused before dispatch, and `none` stays the canonical disable envelope |
| 17a | `mandatory: true` with `max/minimal/none` documented | The documented high tiers are kept (`max`, `minimal`) with no Off option, `none`/`off` are refused with zero dispatch, and a documented tier still reaches the exact body |
| 18 | Sibling namespace, case-distinct identity, conflicting duplicate items, identical duplicate items, and a mixed names-only/declared duplicate pair in either order | Each identity keeps only its own evidence; conflicting and mixed duplicates publish explicit `unknown` route evidence for every row (never an intrinsic ladder) with zero dispatch; entirely names-only identities stay untouched and identical duplicate evidence stays consistent |
| 19 | Compatibility discovery item already declaring `thinking_control` | The compatibility declaration is preserved verbatim and its selected wire value still reaches the actual body |
| 20 | Model-only `model_capabilities` override for the same model id, then removal | The override wins while present (source `config_override`, discovery evidence untouched), and the existing refresh boundary restores the discovered declaration after removal |
| 20a | Model-only override on a route whose `reasoning` evidence is unusable | The override still wins over the published `unknown` route evidence and its selected value reaches the exact body |
| 21 | Repeated explicit refresh with changed evidence, then a failing refresh | Evidence is replaced, never carried: the old enriched descriptor does not reappear as raw evidence, and a failing refresh fabricates nothing and dispatches no thinking field |
| 22 | Endpoint requiring the configured discovery authentication and profile headers | Discovery reuses the existing headers/auth path and still declares the documented control |
| 23 | Request assembly after a completed refresh | No additional model-list or catalog probe; exactly one Chat dispatch per send |

## Verification steps

1. Run the focused regression file
   `agent/test/engine/adapters/openrouter_reasoning_discovery_test.dart`. All 27
   test scenarios (27 documented matrix rows, several covering multiple
   sub-cases and value sets) must pass over the disposable Home, loopback mocks
   and in-memory state database described below.
2. Confirm the red baseline on the final literal expectations, not only the green
   result: with the aggregator enrichment removed the same file reports 24
   failures out of 27 (exit 1), while the three negative-only scenarios (absence
   of evidence, compatibility preservation, generic custom endpoint) pass by
   design.
3. Run `fvm dart analyze` in `agent/`.
4. Shared and neighbouring suites — the registry-derived coverage matrix, the
   shared resolver suites and the LM Studio native discovery suite — exercise
   this adapter but are owned elsewhere and are evaluated on the final
   integrated candidate. This page deliberately records no sibling pass/fail
   counts, because a count taken from a partially integrated snapshot would
   misrepresent the integrated result in either direction.

Automated coverage ownership:
`agent/test/engine/adapters/openrouter_reasoning_discovery_test.dart` owns
discovery-evidence parsing and strict validation, exact identity/ambiguity
handling, declaration derivation, descriptor delivery through the production
model cache, exact Chat bodies for every advertised option across the full
documented vocabulary (including `minimal` beside `low` and `max` beside
`xhigh`), default versus omission behavior, mandatory disable stripping and
refusal, explicit-`unknown` route evidence for unusable declarations,
compatibility-declaration preservation, model-only override precedence and
removal, evidence replacement across refreshes, and the absence of request-time
endpoint probes.

## Harness boundaries

The suite provisions one `Directory.systemTemp` Home through the sanctioned Home
override, one in-memory state database, one loopback `MockClient` serving
`/v1/models` and `/v1/chat/completions`, and one loopback mock catalog client for
the existing model-discovery catalog service. It never reads or writes a real
Home, credential, provider instance, runtime port, UI surface or upstream model.
The synthetic model ids are unknown to every shipped effort catalog, so a
supported descriptor can only come from the documented discovery declaration.

## Recorded evidence at this source revision

These are this discovery path's own focused receipts at this source revision;
they are not integrated, live or release evidence.

- Focused suite: **27 passed**, exit 0, seconds-scale (2-3 s on this machine).
- Red baseline with the aggregator enrichment removed: **3 passed / 24 failed**,
  exit 1, seconds-scale — the three negative-only scenarios (absence of evidence,
  compatibility preservation, generic custom endpoint) pass by design.
- `fvm dart analyze` in `agent/`: no issues, exit 0, 3 seconds.
- Scenario coverage includes the fixed conflict cases (explicit no-effort
  evidence, conflicting duplicate evidence, and partial/mixed names-only versus
  declared duplicate evidence in either response order), all of which publish
  explicit `unknown` route evidence for the exact route and refuse stale choices
  without dispatch.

## Evidence limits

- Automatic mock-HTTP coverage only. No live OpenRouter request was made, so
  this page claims nothing about any specific gateway account, model
  availability or future changes to the documented schema.
- The shared `ThinkingWireVocabulary` is the single source of truth for
  admissibility; the focused suite also asserts that the explicit-`null` (all
  values) advertised set equals `ThinkingWireVocabulary.effortIds`, so discovery
  and the typed wire cannot drift apart unnoticed.
- Shared, registry-derived and neighbouring native suites are owned by their
  respective areas and are verified on the final integrated candidate. This page
  records no sibling pass/fail counts and makes no claim about them.
- Budget support (`supports_max_tokens`) remains evidence only; no budget UI,
  choice, default or bound is introduced here.
- Full fast suites, live runtime acceptance, G4 closure and publication remain
  owned by the parent task; this page covers only the bounded aggregator
  discovery path.
