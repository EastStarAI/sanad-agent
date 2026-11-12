---
title: "Task 167j: Image Generation Contract and Codex/OpenAI Bindings"
description: "One extensible image-generation contract with first-release Codex OAuth and OpenAI API bindings and provider-validated support declarations."
status: "pending"
current_gate: "Ready for 167j-R0"
priority: "high"
parent_plan: "docs/plans/167-multi-capability-providers.md"
issue: "https://github.com/EastStarAI/sanad-agent/issues/414"
reference_grounding: "required"
file_budget: 18
---

# Task 167j: Image Generation Contract and Codex/OpenAI Bindings

## 1. Goal

Generate an image through either an existing Codex OAuth instance or an OpenAI
API-key instance behind one provider-neutral contract. Declare support after
validating Sanad's provider integration, never after testing each user's account.

## 2. Locked scope

- One request/result seam for prompt-to-image, one image per call. Result bytes
  are bounded and validated; failures are typed and sanitized.
- Two explicit bindings in the first release: Codex OAuth and OpenAI API. Shared
  image HTTP/normalization mechanics are reused only where actually equivalent.
- Template binding data selects transport/auth, endpoint, supported image options,
  and model policy. The tool does not branch on provider names.
- Resolve credentials and OAuth refresh through the existing instance resolver,
  preserving required account/client metadata without copying raw secrets into
  a tool, generated artifact, or Client payload.
- Image execution is separate from chat generation and chat-model discovery.
  A configured image binding does not require a selected/verified chat model.
- Publish production `image_generation` declarations for Codex and OpenAI only
  with their working, validated bindings. Existing instances acquire support
  automatically through the normal template reconciliation path.
- Audit existing curated templates: only explicitly validated image wires gain
  a declaration. Chat compatibility alone is not evidence, and an unaudited
  provider is not asserted to be image-capable or permanently unsupported.
- Further compatible providers can reuse this binding through a tested catalog
  entry; no generic plugin loader, SDK dependency, or custom mapping language.
- No per-user entitlement endpoint, automatic sample generation, or account-test
  prerequisite. Provider permission/quota refusals are ordinary execution errors.

## 3. Invariants

- Images and vision input are different capabilities.
- A server-managed model is explicit. Requested and provider-reported model,
  size, quality, and actual pixel dimensions never masquerade as each other.
- Only verified wire options are sent. Backend-ignored/advisory settings are not
  represented as guaranteed controls.
- Bound request time, response bytes, decoded pixels, and concurrency through
  centralized policy; no unbounded body buffering or retry loop.
- Response URLs, if part of a supported wire, are resolved only through a bounded
  outbound-safe download path. Private/internal redirects and arbitrary schemes
  fail closed; no raw provider URL is published as conversation media.
- Logs/dumps contain no credential, prompt text, response base64, or raw body.
- One dispatch attempt. Unknown post-dispatch outcomes are not retried or failed
  over; refreshing an expired credential before dispatch is not a second image
  attempt. An auth retry cannot silently repeat an already-dispatched request.

## 4. Gates and acceptance criteria

### R0 — Wire grounding

- [ ] Pinned evidence covers both bindings' endpoint, auth/refresh integration,
      identity headers, model/options behavior, response variants, and failures.
- [ ] Source and behavior tests are inspected directly, licenses reviewed, and
      Adopt/Adapt/Reject recorded in the ignored evidence store.
- [ ] Explicitly record what a fixture proves versus what needs authorized
      maintainer integration validation; no user-account probe is introduced.

### G1 — Shared contract and bindings

- [ ] One typed seam accepts generation inputs and yields verified bytes plus
      normalized metadata, or a bounded vendor-neutral error.
- [ ] Codex OAuth and OpenAI API fixtures exercise their real request contracts,
      including expired-token resolution and required metadata isolation.
- [ ] Both bindings work without calling a chat adapter or chat-model listing.
- [ ] Selectable/server-managed model behavior and requested/reported metadata
      are covered, including missing or ignored provider fields.

### G2 — Bounds and failures

- [ ] Malformed/empty/oversized responses, invalid image bytes, unsafe URLs,
      cancellation, timeouts, auth/permission/quota errors, and server errors have
      deterministic, sanitized outcomes and release owned resources.
- [ ] Boundary tests cover centralized request/response limits; real credentials
      and image payloads cannot leak through dumps or errors.
- [ ] A timeout after dispatch records an unknown outcome and sends no retry or
      fallback request. Catalog/setup/test paths send zero image requests.

### G3 — Integration validation and declarations

- [ ] Both first-release bindings have focused source-backed fixture coverage and
      recorded maintainer integration validation before support is advertised.
- [ ] Any live provider validation is separately authorized and its evidence says
      which binding worked, without tokens, private prompts, or raw response data.
- [ ] Existing-template audit records confirmed declarations versus unconfirmed
      wires; no unsupported provider inherits images from its chat protocol.
- [ ] Existing Codex/OpenAI instances gain the shipped declaration once, retaining
      UUID, credentials, chat default/cache, and no image default or account test.

## 5. Definition of Done

- [ ] Contract, binding/auth, bounds, sanitization, metadata, and reconciliation
      tests pass; both first-release providers are covered, not only Codex.
- [ ] Relevant Agent analyzer and focused tests pass using FVM; code changes
      include graph maintenance.
- [ ] `docs/technical/image_generation_runtime.md` is created for the shipped
      generation seam and provider-support semantics;
      `docs/technical/provider_protocol.md` and `docs/llms.txt` are updated.
- [ ] Evidence distinguishes fixture validation from separately authorized live
      validation; neither is a new per-user setup requirement.

## 6. Success test scenario

1. Use fixture-backed existing Codex and OpenAI instances with no usable chat
   discovery cache; route the same normalized image request through each.
2. Assert correct endpoint/auth/identity handling, one outbound generation, and
   a validated image result with honest requested/reported metadata.
3. Refresh an expired Codex credential before dispatch; assert no second login,
   raw token copy, or duplicated generation.
4. Inject permission/quota refusal and post-dispatch timeout; assert sanitized
   failures, no automatic second request, and unchanged support declarations.
5. In a separately authorized maintainer validation, confirm both provider wires
   work before advertising them; routine user setup performs no such validation.

## 7. Out of scope

Image editing/masks/variations, multiple images per request, user-account
entitlement checks, custom image providers, artifact storage, tool registration,
and Client conversation rendering.
