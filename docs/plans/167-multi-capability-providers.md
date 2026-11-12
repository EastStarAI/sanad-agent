---
title: "Plan 167: Multi-Capability Providers (Chat, Transcription, Web Search, Image Generation)"
description: "Extend provider instances to multiple capabilities with cloud transcription, web search, and Codex/OpenAI image generation through one management surface."
status: "pending"
current_gate: "Ready for 167a"
priority: "high"
depends_on: "Plan 29 template/instance runtime; Plan 83 secret isolation; local dictation runtime"
related_to: "docs/technical/provider_protocol.md; docs/technical/local_dictation.md; docs/technical/web_search_runtime.md; docs/technical/multimodal_tool_results_and_view_image.md"
reference_grounding: "required for tasks 167e-167h and 167j"
issue: "https://github.com/EastStarAI/sanad-agent/issues/414"
---

# Plan 167: Multi-Capability Providers

## 1. Objective

A provider instance today is implicitly single-capability: one wire protocol, one
default model, one runtime-wide default. This plan makes capability a first-class
dimension of the provider model so that:

- one connection can serve more than one capability without a second credential;
- speech-to-text, web search, and image generation enter the same catalog, the
  same storage, the same protocol, and the same editor;
- every capability has its own default instance, readiness, and test policy;
- the user never meets a second provider-management path.

## 2. Required outcomes

- The Providers surface stays the only provider editor. Its list gains a
  capability filter; the Add action inside Dictation settings opens that same
  picker with the transcription filter preselected.
- A curated template declares its capabilities and the user cannot change them.
  Only the reserved `custom` template lets the user choose, and only among
  capabilities that share one base URL and one credential.
- Transcription ships with both modes: full-batch final text and genuine
  streaming partials, distinguished in the UI the way local rows already are.
- Local transcription remains the default source on every device.
- Deleting the default instance of a capability, or disabling the capability
  that currently holds the default, is refused until another default exists.
- Search joins the model as curated templates only; the keyless built-in engine
  remains the default when no search instance is configured.
- Image generation ships through Codex OAuth and OpenAI API, reusing each
  existing provider instance and credential, not a second login/key or editor.
- Image support is validated for Sanad's provider integration, not for each
  user's account. No account-eligibility check or generation probe gates setup,
  selection, or use; actual request failures are ordinary execution errors.
- Existing curated instances acquire newly shipped capabilities automatically,
  without reconnecting, manually declaring known support, or changing defaults.
- Generated originals remain available through authenticated conversation media
  after model-context image pruning.
- Existing instances, sessions, and pre-update clients keep working; an absent
  capability means chat.

## 3. Locked decisions

| # | Decision | Source |
|---|---|---|
| D1 | One management surface; no parallel provider editor | Owner, 2026-11-11 |
| D2 | Curated capabilities are fixed; only `custom` is user-chosen | Owner, 2026-11-11 |
| D3 | Custom may combine chat + transcription only; search is never custom | Owner, 2026-11-11 |
| D4 | Batch and streaming transcription both ship in the first release | Owner, 2026-11-11 |
| D5 | Local transcription stays the default | Owner, 2026-11-11 |
| D6 | One adapter per vendor; no universal audio or search protocol | Verified vendor variance |
| D7 | One default per capability; delete/disable of a default is refused | Owner, 2026-11-11 |
| D8 | Readiness and test are per capability, not per card | Owner, 2026-11-11 |
| D9 | No migration of the legacy search key; DuckDuckGo stays the default | Owner, 2026-11-11 |
| D10 | No vendor SDK becomes a dependency; adapters are ours | Owner, 2026-11-11 |
| D11 | Reference hierarchy: neutral multi-vendor runtime first, vendor SDKs second, docs last | Owner, 2026-11-11 |
| D12 | Transcription mode is a model fact, not a template fact | Verified vendor model behavior |
| D13 | Image generation includes Codex OAuth and OpenAI API in the first release, behind one extensible contract | Owner, 2026-11-12 |
| D14 | Advertise validated provider image support; no per-user entitlement test or generation probe is required | Owner, 2026-11-12 |
| D15 | Derive known curated capabilities automatically for new and existing instances; preserve chat routing and existing defaults | Owner, 2026-11-12 |

## 4. Capability model

**Vocabulary.** `chat`, `transcription`, `search`, `image_generation` for this
plan; `text_to_speech` is reserved for a later plan and must not be enumerated
yet. Image generation is output creation, not a chat model's image-input/vision
capability; neither implies the other.

**Template declares, instance selects.**

- A curated template carries an immutable capability set plus, per capability,
  its wire binding (protocol, default endpoint, default models, mode).
- Curated effective capabilities follow shipped template declarations. An
  idempotent reconciliation adds new support to existing instances with no new
  credential, UUID, default, or account-verification result. Explicit execution
  settings, including any disable flag, are retained; support stays read-only.
- The `custom` template carries no fixed set: the user selects a compatible
  subset. Compatibility is structural, not cosmetic — capabilities may only be
  combined when they share base URL and credential. In practice that means
  `{chat}`, `{transcription}`, `{chat, transcription}`.
- Search is excluded from `custom` because every search vendor differs in auth
  header and response shape; there is no standard to bind against.
- Image generation is curated-only in this release. Production declarations
  ship with the validated bindings, not speculatively in the foundation tasks.
  Additional compatible providers require verified binding reuse and an explicit
  catalog entry, never an inference from OpenAI-compatible chat.

**Per-capability state.** Each enabled capability owns independent
`default_model` (where models exist), readiness, verification result, and
default flag. A credential is shared by the instance, never stored per
capability.

**Image support and readiness.** Support comes from the maintained provider
integration declaration. Image configuration readiness checks the binding and
required local configuration only: no entitlement endpoint, sample generation,
chat-model discovery, or previous successful image request. Account verification
is explicitly not required, not recorded as a fabricated successful test. An
actual permission/quota/auth failure remains a sanitized request error and does
not erase support or block unrelated chat. Other capabilities retain their own
verification policies.

**Model dimension is optional.** Search has no model. The model projection,
selection, and cache paths must therefore treat "no models" as a valid
capability rather than an empty model list that looks unready. Image bindings
may expose selectable models or a server-managed model; neither depends on the
selected chat model/cache. Requested model/size/quality and provider-reported
facts stay distinct, and unknown actual values are not presented as confirmed.

## 5. Wire reality: one adapter per vendor

There is no universal audio protocol. Verified variance:

| Layer | Variance |
|---|---|
| Transport | HTTP multipart; JSON WebSocket; binary WebSocket; gRPC-only |
| Auth | `Authorization: Bearer`; `Token`; `x-api-key`; query parameter |
| Configuration placement | URL query; first message; per-chunk message |
| Event vocabulary | interim/final; partial/committed; turn events; `is_final` |
| Audio contract | encoding, sample rate, endpointing, turn detection |

The only genuinely standardized family is **OpenAI-compatible batch
transcription**, which OpenAI and Groq share and which the `custom` transcription
capability binds to. Everything else is a vendor adapter.

Consequence for the design: a template carries vendor identity and binding data,
never a guessed wire. Adding a vendor later is code plus one catalog entry.

**Mode is a model fact, not a template fact.** Inside one vendor, models differ:
some are realtime-only and reject server-side turn detection, others are batch
and emit a single final. The catalog row therefore carries the mode, and the
template only declares what its adapter can speak.

**One engine seam, two shapes.** The recognition seam exposes a full-batch
recognizer and a streaming recognizer over the same events. A batch-only vendor
is presented as streaming by a wrapper that segments with the local speech gate
and VAD, exactly as the local batch mode already behaves. That keeps one
downstream path for session, lease, caps, and insertion.

### 5.1 Reference hierarchy

1. **Architectural reference:** a neutral multi-vendor agent runtime — one base
   contract, batch and streaming on the same seam, a vendor-neutral transcript
   event, per-model capability flags, and a batch-to-stream wrapper built on VAD.
   It answers *how to unify*, never *what a vendor expects*.
2. **Wire reference:** per-vendor official SDKs — exact field names, auth headers,
   message envelopes, audio contract, and event-to-text mapping. They track the
   vendor API as it changes. Where an OAuth wire has no official SDK, pinned
   working runtime source and behavior tests establish the binding instead;
   uncertainty is recorded, never replaced by a guessed standard.
3. **Confirmation only:** vendor documentation pages. They confirm behavior but
   are not pinnable evidence.

### 5.2 Copied-code rules

- Leaf mechanics only: field names, envelope shapes, event mapping, audio
  encoding. Never a session manager, retry policy, or logging layer — those
  conflict with our caps and our logging law.
- At most one self-contained function, converted to Dart and tested here. Code
  whose failure mode we cannot diagnose is not copied.
- A short attribution note above any copied block, and the source pinned to a
  revision in the evidence store.

### 5.3 Dependency decision

Evaluated and rejected: no vendor SDK becomes a dependency of the agent. The
available Dart clients are unofficial single-maintainer packages, Flutter-only,
or larger than the task they serve, and none of them removes the work that
matters — per-vendor normalization, session bounds, and capability state. The
agent keeps using only the HTTP and WebSocket support it already has.
Image bindings reuse shared mechanics where equivalent but retain explicit
Codex OAuth/OpenAI API auth and endpoint contracts; this is not a plugin system.

### 5.4 Image generation and durable media

- One provider-neutral request/result seam, selected by template binding data.
  The tool has no provider-name branching, and image execution is separate from
  the existing chat adapters.
- Resolve credentials through the existing instance resolver, including OAuth
  refresh and required account/client metadata. Never copy raw tokens into tool
  configuration, artifacts, or Client state.
- The first slice generates one image per call. Editing, masks, variations, and
  batch requests are deferred. Expose only supported options; server-managed or
  advisory settings are not guaranteed controls.
- `generate_image` uses the independent image default. It is cataloged when a
  configured image-capable instance exists, even without an image default, and
  otherwise is absent. No workspace or chat vision support is required. An unset
  default/stale configuration produces actionable setup feedback, not an implicit
  default or fallback to chat generation.
- Store validated originals as tool-owned media inside the existing Sanad Home
  boundary, not user-role attachments or merely inline model-history base64.
  Keep a typed byte-free reference and a text-compatible canonical result.
  Optional model-visible previews obey existing image-input evidence/budgets;
  text-only chat can still generate and display output without forced pixels.
- Extend existing authenticated local/hosted media retrieval, with explicit
  generated-media support negotiation. No public image URL, Client-owned durable
  store, new generic artifact subsystem, or binary generic device event.
- Original retrieval survives context pruning and restart. Fork/delete ownership,
  integrity, partial-write cleanup, and orphan reconciliation are tested.
- Generation is non-idempotent. Unknown post-dispatch outcomes never trigger
  automatic retry/replay/failover. Recovery reuses completed durable references,
  never regenerates a missing or already completed image.

## 6. Delivery tasks

Dependencies and delivery coordination live here, not in individual task files.

| Task | Responsibility | Depends on | User-visible |
|---|---|---|---|
| 167a | Capability vocabulary, declarations, persistence, migration/reconciliation | — | No |
| 167b | Per-capability default, readiness, test policy, delete/disable guard | 167a | Partial |
| 167c | Protocol, catalog, and CLI carry capability | 167a | No |
| 167d | Client provider surfaces: filter, capability step, per-capability card | 167b, 167c | Yes |
| 167e | Cloud transcription, batch family (OpenAI, Groq, custom) | 167b, 167c | Yes |
| 167f | Cloud transcription, streaming adapters (OpenAI, Deepgram, AssemblyAI) | 167e | Yes |
| 167g | Dictation settings: local/cloud filter, cloud rows, source selection | 167d, 167e, 167f | Yes |
| 167h | Search capability: curated templates, routing, default | 167b, 167c | Yes |
| 167j | Image contract, Codex/OpenAI bindings, validated catalog declarations | 167b, 167c | Partial |
| 167k | Tool-owned generated-image artifacts and durable references | 167a | No |
| 167l | `generate_image`, non-idempotent recovery, local/hosted media delivery | 167b, 167c, 167j, 167k | Partial |
| 167m | Generated-image Client cards, lightbox, original download | 167d, 167l | Yes |
| 167i | Contract docs, compatibility matrix, QA matrix, final acceptance | All | No |

`167a`–`167d` change no transcription, search, or image execution behavior. They
land first so the later tasks are independent of each other. The image slice
need not wait for transcription/search; `167i` remains final acceptance despite
retaining its identifier.

## 7. Gates and progress

- **Gate R0** runs before each source-dependent wire implementation, including
  images: pinned vendor evidence for the wires actually bound, with an
  Adopt/Adapt/Reject record. A missing or stale packet triggers authoring first;
  a task is not marked blocked until authoring, refresh, discovery, and download
  have been exhausted. Foundations do not wait for unrelated wire packets.
- Image support is advertised after source-backed tests and recorded maintainer
  integration validation, not individual user-account checks. Any live generation
  requires separate authorization; this planning amendment performs none and does
  not mark outstanding grounding or implementation gates complete.
- Each task defines its own gates with checkboxes, a definition of done, and one
  success test scenario.
- A task is not "done" while a contract doc or QA row it invalidates is stale.

## 8. Compatibility and migration

- Existing instance rows migrate to `{chat}` and keep their routing, so no
  session, model cache, or recent selection is invalidated.
- Idempotent template reconciliation then adds newly shipped curated capabilities
  automatically, including images for existing Codex/OpenAI instances. It does
  not reconnect, change custom selections/explicit settings, invent account-test
  success, or select a new capability default.
- The single runtime-wide default becomes the chat default. Migration must not
  lose the current default or create two chat defaults.
- A pre-update client that omits capability in a provider command is served as
  chat; the agent never rejects the request for the missing field.
- A pre-update agent answers a capability-aware client with no capability data;
  the client must degrade to a chat-only surface instead of rendering an empty
  catalog.
- Secret storage, vault namespace, and instance UUID identity do not change.
- Additive generated-media references preserve legacy text results without new
  unknown v1 block types. Mixed-version hosted routes fail safely if generated
  media is unsupported; unrelated chat-model verification never gates images.

## 9. Out of scope

- Text-to-speech, voice calls, and any audio output capability.
- Custom search/image providers and any generic response-mapping language.
- Editing capabilities of curated templates.
- Image editing, masks, variations, multi-image requests, or unverified additional
  image-provider declarations.
- Per-user image-entitlement checks, automatic generation probes, or a parallel
  image-provider login/editor/plugin system.
- Migrating env-based search keys into instances.
- Changes to the local model catalog, local engines, or download pipeline.
- Rate-limit, auto-failover, or usage-window semantics beyond keeping them
  working per capability; chat/search retry policies do not authorize replay of
  non-idempotent image requests.

## 10. Risks

| Risk | Mitigation |
|---|---|
| Capability explosion in the model, protocol, and UI | Fixed closed vocabulary; one dimension, not a plugin system |
| A configured-but-broken capability shown as verified | Explicit capability verification policy; image support/configuration never claims account-test success |
| Streaming vendor drift breaking a session mid-utterance | Bounded first-audio timeout, session byte/time caps, ordered teardown, one reconnect policy |
| Cloud transcription leaking audio or transcript into logs | Counts, codes, and durations only; existing logging law applies unchanged |
| Dictation source ambiguity (local vs cloud vs default) | One selection authority, dated projection, local default, explicit reason codes |
| Search routing silently changing today's behavior | Built-in engine stays default; an instance only takes over when explicitly made default |
| Existing accounts remain chat-only | Idempotent shipped-template reconciliation without reconnect/default mutation |
| Image options imply unsupported server control | Separate requested/reported facts and explicit server-managed model policy |
| Duplicate generation after timeout/restart | Non-replay-safe classification and durable completed references |
| Original disappears after pruning or crosses media ownership | Independent original ownership, authenticated retrieval, fork/delete and integrity tests |

## 11. Acceptance

- Every row of the linked Issue's acceptance criteria is demonstrated by a task
  report with its test evidence.
- The image amendment is covered for both Codex OAuth and OpenAI API, existing
  accounts, preserved chat defaults, zero account probes, original retention,
  protected retrieval, and no automatic replay of uncertain requests.
- The compatibility matrix in `167i` is filled from real runs, not assumptions.
- No contract doc contradicts the shipped behavior.
