---
title: "Task 167m: Generated-Image Client Cards and Original Download"
description: "Generated-image live/history cards, shared lightbox and original retrieval, localized failures, and existing-provider setup entry points."
status: "pending"
current_gate: "Ready for 167m-G1"
priority: "high"
parent_plan: "docs/plans/167-multi-capability-providers.md"
issue: "https://github.com/EastStarAI/sanad-agent/issues/414"
file_budget: 16
---

# Task 167m: Generated-Image Client Cards and Original Download

## 1. Goal

Show generated images as durable conversation output with preview, shared
lightbox, and authenticated original download, reusing existing media components
rather than introducing another provider editor or image gallery subsystem.

## 2. Locked scope

- Map generated-media descriptors identically from live completion and hydrated
  history, with distinct generating, available, failed, unknown-outcome, and
  unavailable states.
- Reuse the existing typed media-loader boundary, bounded byte cache, media
  cards/gallery rules, lightbox, and platform-aware image save implementation.
  Extend closed media kinds deliberately; do not hardcode generation into HTTP
  calls inside widgets.
- Preview and original are different representations. Download explicitly
  retrieves the validated original when the lightbox currently holds a normalized
  preview; it must not silently save that preview as the original.
- Use current platform support: desktop/Web save through existing mechanisms;
  platforms without a supported save flow do not display a broken download
  action. Do not invent new mobile filesystem authority.
- Missing image configuration links to the existing Providers picker with the
  image filter and returns to the originating conversation/settings context.
- Provider support badges derive from daemon declarations and do not wait for
  an account test or successful generation. Real request errors are shown as
  execution feedback, not as removal of provider support.
- All interface text is localized in English and Arabic; stable driver keys
  expose cards, state, original action, and setup entry points.

## 3. Invariants

- The Client owns transient rendering only, never provider credentials, durable
  original storage, or account entitlement decisions.
- A text-only chat model can still display generated output.
- Descriptor/reference identity and integrity determine cache scope; previews and
  originals cannot collide, and account/device/session changes cannot reuse the
  wrong bytes or leave a stale stream active.
- Public descriptors and persisted Client metadata contain opaque IDs and safe
  metadata, not base64, private paths, provider URLs, or reusable media credentials.
  Authorized image bytes remain transient in the existing bounded media cache.
- Reopening a pruned conversation still offers its original while it exists;
  genuinely missing media renders an honest unavailable state, never a request
  to regenerate automatically.
- Unknown-outcome feedback does not automatically resend or imply that the
  provider performed no work. Any new generation is an explicit new action.

## 4. Gates and acceptance criteria

### G1 — Live/history presentation

- [ ] Generating/success/failure/unknown-outcome/unavailable cards have matching
      live/history identity and localized actionable copy.
- [ ] Successful media uses existing card/gallery/lightbox components, with safe
      MIME/dimensions and no filesystem/provider URL leakage.
- [ ] Completed typed tool failures are visible even without a final model answer.
- [ ] Image cards work with text-only chat and survive context-pruned history.

### G2 — Retrieval, original, and lifecycle

- [ ] Local and hosted typed loaders hydrate through the current media boundary;
      widgets never own HTTP authentication or transport selection.
- [ ] Original download preserves exact source bytes/hash, not preview bytes,
      follows existing safe filename/non-overwrite behavior, and reflects actual
      platform support.
- [ ] Preview/original cache identities are distinct; navigation, disposal,
      sign-out, and account/device/session switches cancel and isolate loads.
- [ ] Missing/corrupt/unsupported-route media yields a stable state and no
      automatic generation call, generic contact error, or raw provider body.

### G3 — Setup entry point and localization

- [ ] The setup action opens the existing image-filtered provider picker and
      returns correctly after save/cancel, with no second editor/login.
- [ ] Default/model configuration belongs to the provider editor; the image card
      never asks the user to manually declare known curated capabilities.
- [ ] No opening/rendering/setup action dispatches an image eligibility probe.
- [ ] Strings exist in both locales, RTL and keyboard behavior reuse the shared
      lightbox, and driver keys expose all new states/actions.
- [ ] Old agents/hosted routes without the needed capability render safe text or
      a compatibility state rather than a broken image action.

## 5. Definition of Done

- [ ] Widget and repository tests cover live/history parity, original-vs-preview
      bytes, typed errors, cache/navigation isolation, platform save behavior,
      filtered picker return, mixed-version routes, and both locales.
- [ ] Relevant Client analyzer and focused tests pass using FVM; code changes
      include graph maintenance.
- [ ] `docs/product/client_interface.md`, `docs/product/settings_hub.md`,
      `docs/technical/image_generation_runtime.md`, and the localization coverage
      report reflect the shipped behavior; the existing lightbox/media owner
      documentation is extended rather than duplicated.

## 6. Success test scenario

1. Render a successful generated-image fixture in a conversation with a text-only
   chat model; open the shared lightbox and save the original where supported.
2. Give the loader different preview/original fixtures; assert the saved hash is
   the original's. Prune model pixels, reopen history, and repeat successfully.
3. Switch device/session during hydration and assert cancellation and no stale
   image flash. Render typed failure and unknown-outcome fixtures without retry.
4. Follow missing-configuration feedback to the image-filtered existing provider
   picker; save/cancel and return without any eligibility/generation request.
5. Repeat interface assertions in both locales and against an older-route fixture.

## 7. Out of scope

A second provider editor, account-verification UI, provider wire logic, automatic
regeneration, new mobile save infrastructure, and image-editing controls.
