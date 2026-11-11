---
title: "Plan 167: Multi-Capability Providers (Chat, Transcription, Web Search)"
description: "توسيع مفهوم المزود من قدرة واحدة إلى قدرات مختارة لكل مثيل، وإضافة التفريغ الصوتي السحابي (دفعي وتدفقي) وقدرة البحث، مع إدارة واحدة وافتراضي مستقل لكل قدرة."
status: "pending"
current_gate: "Ready for 167a"
priority: "high"
depends_on: "Plan 29 template/instance runtime; Plan 83 secret isolation; local dictation runtime"
related_to: "docs/technical/provider_protocol.md; docs/technical/local_dictation.md; docs/technical/web_search_runtime.md"
reference_grounding: "required for tasks 167e-167h"
issue: "https://github.com/EastStarAI/sanad-agent/issues/414"
---

# Plan 167: Multi-Capability Providers

## 1. Objective

A provider instance today is implicitly single-capability: one wire protocol, one
default model, one runtime-wide default. This plan makes capability a first-class
dimension of the provider model so that:

- one connection can serve more than one capability without a second credential;
- a second capability family (speech-to-text) and a third (web search) enter the
  same catalog, the same storage, the same protocol, and the same editor;
- every capability has its own default instance, readiness, and test;
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

## 4. Capability model

**Vocabulary.** `chat`, `transcription`, `search` for this plan; `text_to_speech`
is reserved for a later plan and must not be enumerated anywhere yet.

**Template declares, instance selects.**

- A curated template carries an immutable capability set plus, per capability,
  its wire binding (protocol, default endpoint, default models, mode).
- The `custom` template carries no fixed set: the user selects a compatible
  subset. Compatibility is structural, not cosmetic — capabilities may only be
  combined when they share base URL and credential. In practice that means
  `{chat}`, `{transcription}`, `{chat, transcription}`.
- Search is excluded from `custom` because every search vendor differs in auth
  header and response shape; there is no standard to bind against.

**Per-capability state.** Each enabled capability owns independent
`default_model` (where models exist), readiness, verification result, and
default flag. A credential is shared by the instance, never stored per
capability.

**Model dimension is optional.** Search has no model. The model projection,
selection, and cache paths must therefore treat "no models" as a valid
capability rather than an empty model list that looks unready.

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

## 6. Delivery tasks

| Task | Responsibility | Depends on | User-visible |
|---|---|---|---|
| 167a | Capability vocabulary, template declarations, instance persistence, migration | — | No |
| 167b | Per-capability default, readiness, test, delete/disable guard | 167a | Partial |
| 167c | Protocol, catalog, and CLI carry capability | 167a | No |
| 167d | Client provider surfaces: filter, capability step, per-capability card | 167b, 167c | Yes |
| 167e | Cloud transcription, batch family (OpenAI, Groq, custom) | 167b, 167c | Yes |
| 167f | Cloud transcription, streaming adapters (OpenAI, Deepgram, AssemblyAI) | 167e | Yes |
| 167g | Dictation settings: local/cloud filter, cloud rows, source selection | 167e, 167f | Yes |
| 167h | Search capability: curated templates, routing, default | 167b, 167c | Yes |
| 167i | Contract docs, compatibility matrix, QA matrix, final acceptance | All | No |

`167a`–`167d` change no transcription or search behavior. They land first so the
later tasks are independent of each other.

## 7. Gates and progress

- **Gate R0** runs before the first executable gate: pinned vendor evidence for
  the transcription and search wires that the plan actually binds to, with an
  Adopt/Adapt/Reject record. A missing or stale packet triggers authoring first;
  a task is not marked blocked until authoring, refresh, discovery, and download
  have been exhausted.
- Each task defines its own gates with checkboxes, a definition of done, and one
  success test scenario.
- A task is not "done" while a contract doc or QA row it invalidates is stale.

## 8. Compatibility and migration

- Existing instance rows migrate to `{chat}` and keep their routing, so no
  session, model cache, or recent selection is invalidated.
- The single runtime-wide default becomes the chat default. Migration must not
  lose the current default or create two chat defaults.
- A pre-update client that omits capability in a provider command is served as
  chat; the agent never rejects the request for the missing field.
- A pre-update agent answers a capability-aware client with no capability data;
  the client must degrade to a chat-only surface instead of rendering an empty
  catalog.
- Secret storage, vault namespace, and instance UUID identity do not change.

## 9. Out of scope

- Text-to-speech, voice calls, and any audio output capability.
- Custom search providers and any generic search response-mapping language.
- Editing capabilities of curated templates.
- Migrating env-based search keys into instances.
- Changes to the local model catalog, local engines, or download pipeline.
- Rate-limit, auto-failover, or usage-window semantics beyond keeping them
  working per capability.

## 10. Risks

| Risk | Mitigation |
|---|---|
| Capability explosion in the model, protocol, and UI | Fixed closed vocabulary; one dimension, not a plugin system |
| A configured-but-broken capability shown as ready | Capability readiness requires its own probe; "configured" never means "verified" |
| Streaming vendor drift breaking a session mid-utterance | Bounded first-audio timeout, session byte/time caps, ordered teardown, one reconnect policy |
| Cloud transcription leaking audio or transcript into logs | Counts, codes, and durations only; existing logging law applies unchanged |
| Dictation source ambiguity (local vs cloud vs default) | One selection authority, dated projection, local default, explicit reason codes |
| Search routing silently changing today's behavior | Built-in engine stays default; an instance only takes over when explicitly made default |

## 11. Acceptance

- Every row of the linked Issue's acceptance criteria is demonstrated by a task
  report with its test evidence.
- The compatibility matrix in `167i` is filled from real runs, not assumptions.
- No contract doc contradicts the shipped behavior.
