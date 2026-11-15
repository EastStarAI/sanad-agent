---
title: "Task 167l: Generate Image Tool, Recovery, and Protected Media Delivery"
description: "Capability-routed image generation with non-replay-safe execution, durable media references, and authenticated local/hosted retrieval."
status: "pending"
current_gate: "Ready for 167l-G1"
priority: "high"
parent_plan: "docs/plans/167-multi-capability-providers.md"
issue: "https://github.com/EastStarAI/sanad-agent/issues/414"
file_budget: 18
---

# Task 167l: Generate Image Tool, Recovery, and Protected Media Delivery

## 1. Goal

Expose one optional `generate_image` tool that uses the selected image provider,
commits a durable generated-media reference, and delivers its image through the
existing protected local/hosted conversation-media paths without duplicate
non-idempotent generation.

## 2. Locked scope

- The runtime catalog registers the tool when at least one configured image-
  capable instance exists, even before an image default is selected; otherwise
  it is absent. This requires neither a workspace nor chat vision. It accepts a
  prompt and only binding-supported optional generation settings, not a raw
  credential, endpoint, provider URL, or arbitrary output path.
- Resolve the explicit image default, freeze instance/config identity for that
  dispatch, and use its bound provider contract. No image default is invented
  from the chat default or from the first available provider.
- A missing/invalid local configuration yields a typed setup reason. No account
  entitlement check, sample generation, or successful chat probe is required.
- Route through the existing permission/execution owner. Generation is a
  non-replay-safe, potentially quota-consuming action, not a read-only tool.
- On success, persist one tool result with safe text and generated-media
  reference before publishing a byte-free completion descriptor.
- The original is always displayable through media retrieval. Any optional
  model-visible preview follows existing image-input evidence/budgets; a text-only
  chat route receives an honest text/reference result, not forced pixels.
- Extend current local media retrieval and hosted binary relay contracts with a
  generated-image media kind and explicit support/version negotiation. Reuse
  authentication, byte limits, cancellation, integrity, and requester binding.
  Do not place binary payloads in generic device commands/events.

## 3. Invariants

- Generation dispatch is attempted once. Neither runner retry, restart replay,
  adapter retry, nor automatic provider failover can repeat an uncertain request.
- A durable completed result is reused verbatim after recovery. If dispatch may
  have happened but completion is absent, persist an actionable unknown-outcome
  failure rather than generating again; a new attempt is an explicit new action.
- Cancellation closes owned transport/staging and reports whether outcome is
  known; it never promises that a provider-side generation was rolled back.
- Missing media does not trigger regeneration.
- Retrieval requires exact account/user, device, session, media, purpose, and
  compatible transport scope; sibling sessions and expired routes receive no
  bytes. No provider URLs or Client/Agent filesystem paths become public.
- A generation failure remains visible as one typed tool failure and never
  changes the provider's maintained support declaration.
- An older hosted route lacking generated-media support fails with a typed
  compatibility reason, never a raw-byte fallback or cross-device route guess.

## 4. Gates and acceptance criteria

### G1 — Catalog, routing, and results

- [ ] With a configured image-capable instance, the tool is present even without
      a default or workspace; with none, it is absent. Schema follows supported
      binding options, never chat vision or raw endpoint/credential arguments.
- [ ] Missing image default/configuration produces a setup action with no network
      call; actual use resolves the existing credential only at dispatch.
- [ ] One image invocation leaves chat provider/model/default unchanged.
- [ ] Success publishes only after durable original/reference completion;
      typed errors are visible without depending on a later model answer.
- [ ] Text-only chat can generate/display an image without unsupported pixel
      insertion, and optional previews obey existing media budgets.

### G2 — Non-idempotent execution and recovery

- [ ] Permission denial/cancellation before dispatch sends zero provider requests.
- [ ] Completion-before-restart resumes with the same reference and no new image.
- [ ] Crash/timeout/cancellation after possible dispatch but before durable
      completion produces unknown-outcome feedback and zero automatic replay.
- [ ] Duplicate completion callbacks cannot create two canonical tool results or
      orphan a completed artifact.
- [ ] Explicit new user attempts remain distinct from recovery/retry of the old
      tool identity; no silent fallback provider is invoked.

### G3 — Protected media delivery

- [ ] Local and hosted loaders retrieve the original with equivalent closed,
      byte-free descriptors and integrity checks through existing media owners.
- [ ] Wrong user/device/session/media, unavailable files, invalid range/size,
      expired requester routes, and interrupted streams return no unauthorized
      bytes and release owned resources.
- [ ] Generated-media support is negotiated explicitly. Mixed-version endpoints
      preserve safe text/history and an actionable unsupported-route state.
- [ ] Metadata/log/history/frame scans prove bytes appear only in authorized
      binary transfer, never in generic command/event payloads or request dumps.

## 5. Definition of Done

- [ ] Catalog, permission, routing, recovery, publication-order, and authenticated
      local/hosted contract tests pass; real-port integration tests are isolated
      and sequential only where they share exclusive system resources.
- [ ] Relevant Agent analyzer and focused tests pass using FVM; code changes
      include graph maintenance.
- [ ] `docs/technical/image_generation_runtime.md`,
      `docs/technical/multimodal_tool_results_and_view_image.md`,
      `docs/technical/communication_protocols.md`,
      `docs/technical/run_cancellation_and_process_ownership.md`, and
      `docs/agent_engine/capability_runtime.md` describe the shipped contracts.
- [ ] Hosted-contract coverage uses the existing public/private boundary. Any
      hosted consumer change is recorded for its owning repository, not silently
      assumed complete by a public-only mock.

## 6. Success test scenario

1. Use an image-default fixture with a text-only chat route and invoke
   `generate_image`; assert exactly one generation and one durable reference.
2. Fetch the original through authenticated local and compatible hosted fixture
   routes; assert equivalent bytes/hash and zero bytes for a sibling session.
3. Restart after completion and assert no regeneration; separately interrupt
   after possible dispatch and assert unknown-outcome feedback, not a replay.
4. Inject a quota refusal and assert one sanitized tool failure while the provider
   still advertises support. Repeat with an older media route and assert a safe
   compatibility state with no binary fallback.

## 7. Out of scope

Provider-specific wire mechanics, account-entitlement tests, image editing,
automatic generation retries/failover, a new public file server, and Client
presentation widgets.
