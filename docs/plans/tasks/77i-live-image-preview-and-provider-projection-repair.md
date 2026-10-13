---
title: "Task 77I: Live Image Preview and Provider Projection Repair"
status: "in_progress"
priority: "high"
current_gate: "G3 — final parent acceptance audit; 77I2 Go projection complete"
remaining_estimate: "10% — fresh upload/draft cleanup and Go verified; remaining parent acceptance/lightbox/protection audit not closed"
depends_on: "77g2; current attachment/media contracts"
---

# Task 77I — Image previews and provider projection

## Goal

Make admitted user-image previews and successful `view_image` thumbnails immediately visible and equivalent after history reopening, and prevent capable Chat Completions routes from silently losing tool images.

## Locked scope

- Continue in the existing Plan 77 source/worktree and selected managed local test environment; do not create another stack, switch source, merge, commit/push, deploy or remove resources without separate authorization.
- Preserve primary/peer runtimes, volumes, selected Home and authentication boundaries. Public diagnostics contain no credentials, raw identities, local image paths or image bytes.
- Diagnosed defects: D1 user-image card remains Unavailable; D2 successful `view_image` lacks live thumbnail but history reopening restores it; D3 current Chat Completions projection drops images before provider submission. D4 reopened tool image works on local macOS but fails on hosted Web; D5 submitted New Conversation attachments survive in the originating draft cache; D6 real composer maps omit MIME hints required by hosted upload-start. Do not conflate D3 with provider rejection.
- Codex user reproduction shows successful visual interpretation: it is the known-good provider baseline, not evidence that previews are correct.
- Keep canonical rich tool history, path-free public metadata, requester/device/session media authorization, bounded cache and cancellation intact. No widget-build fetching, credentialed wildcard CORS or client filesystem shortcuts.
- Chat Completions image support requires protocol-valid projection plus explicit capability evidence; unknown/text-only routes remain fail-closed. No speculative blanket vision enablement based on model name.
- Existing `77g2` deterministic gate evidence remains historical; live feature acceptance stays open until this task's verification succeeds.

## Gates

### G0 — Exact diagnosis
- [x] Correlate managed macOS/Web runtime, current image admission and actual model/tool results with bounded redacted diagnostics.
- [x] Identify the first failed D1 boundary: authoritative availability, media authorization/route, loader lifecycle, or rendering.
- [x] Identify D2 live/history metadata divergence with a regression fixture.
- [x] Review D3 adapter capability/wire contracts; record a supported implementation or explicit remaining limitation.

### G1 — Repair with regression coverage
- [x] Repair originating-draft cleanup with submitted-ID scoping and retain failures/unrelated drafts.
- [x] Make hosted upload-start compatible with real composer admission maps without inventing local-schema fields.
- [x] Default-expand view_image and containing tool group unless the user explicitly collapses it; preserve ordinary-tool behavior and manual choices.
- [x] Add failing regression coverage for each diagnosed boundary before applying the focused repair.
- [x] Restore user-image preview and live/history tool-image parity without weakening ownership or privacy.
- [x] Complete the authorized protocol/capability-safe Chat Completions image projection in [77I2](77i2-openai-compatible-tool-image-projection.md). OpenCode Go live acceptance passed with correlated redacted image input and a blind visual fixture; other providers remain separately live-untested.
- [x] Update closest owning contracts only for changed invariants and update corresponding technical/QA documentation.

### G2 — Automated verification
- [x] Relevant Agent/Client analyzers clean.
- [x] Focused unit/widget suites pass; supported-provider and integration suites remain in the next item.
- [x] Real daemon-backed media integration runs sequentially with isolated state: local 6/6 and hosted process 1/1 passed.

### G3 — Live acceptance
- [ ] Reload/restart only matched test components through `sanad-dev` after automated gates pass.
- [ ] macOS: send a real image; original bubble renders image/lightbox without navigation; one `view_image` call renders its image immediately.
- [ ] Web/remote: same conversation previews work without Local Gateway access; reopen preserves both thumbnails.
- [ ] Codex sees image content; validate any newly supported Chat Completions route with actual request projection and a controlled visual test.
- [ ] Zero cross-owned/unverifiable Clients and protected primary/peer identities unchanged; document remaining defects honestly.

## Acceptance criteria

- [ ] Available admitted images never display permanent Unavailable due to a wrong media-kind lookup or transport selection.
- [ ] Successful live tool events preserve the same media descriptor as their hydrated history counterparts.
- [ ] Navigation/rebuild creates no extra resource fetch for unchanged identity; failed/cancelled/unauthorized media remains bounded and fail-closed.
- [ ] Provider requests contain images only through a validated supported projection, never raw filesystem paths; unsupported routes receive the explicit omission marker.
- [ ] Existing attachment-only send, replay, rich-history persistence and media privacy tests stay green.

## Definition of Done

- [ ] Gate state and remaining estimate updated at every closure.
- [ ] Automated and live acceptance evidence recorded; no assertion based solely on model self-report.
- [ ] Documentation and graph maintenance updated for changed source.
- [ ] No commit/push or deployment without new authorization; leave selected test environment in the requested state.

## Initial evidence

- User reproduction: Codex interprets the uploaded JPEG successfully. User bubble remains Unavailable live and after reopening; tool image appears only after reopening.
- Recent Chat Completions request diagnostics show successful `view_image` text/omission markers and no image blocks. Source `base_openai_adapter.dart` calls `textOnlyToolResultContent`; this is a Sanad projection limitation, not observed provider rejection.
- Selected runtime is managed with macOS/Web Clients; zero cross-owned/unverifiable Clients. Task 77H is completed and is not reopened for feature defects.

### Additional user evidence

- Reopening: local macOS tool image renders; hosted Web renders Image unavailable. Treat hosted retrieval separately from live descriptor loss.
- view_image must be expanded by default, including a containing tool group so the preview is immediately discoverable; preserve explicit manual collapse.

### G0/G1 closure evidence

- D1: Local attachment retrieval treated a store-relative reference as a process-relative filename. The production-shaped relative-reference regression failed before repair and passed after routing verification through `AttachmentStore`.
- D2: Internal completion callbacks discarded the media descriptor; additionally publication preceded durable result availability. A shared core byte-free descriptor now survives normal/resumed callbacks, and image terminal publication follows final guarded persistence. The persistence-order regression failed before repair and now passes.
- D4: Actual Web diagnostics returned `sequence_conflict`. A deliberately blocked media declaration reproduced completion overtaking earlier frames. Backend per-Agent-route ingress serialization fixes this without weakening sequence/auth/scope validation; undeclared completion is rejected.
- Default expansion now applies to standalone image tools and containing groups with manual-collapse precedence. The default-thumbnail widget regression failed before repair and passed afterward.
- The initial read-only review confirmed D3 is a deliberate limitation of Sanad's current v1 projection, not evidence of provider/model incapability. Following the user's explicit request to investigate OpenCode Go, source and external research identified an existing OpenCode reference solution: keep string tool results and project extracted images as a synthetic user message after the tool-result batch. D3 remains open for scoped implementation and actual endpoint acceptance; it must not be closed as an unavoidable provider limitation.
- Focused baseline: Agent analyzer clean, runner 73 passed, local transport 23 passed; Client analyzer clean, image/user/group/scroll widgets 52 passed; private relay 31 passed. Live acceptance is still pending and no feature success is claimed from these tests alone.

### Additional live and fresh-upload evidence

- Existing admitted user image and hydrated tool thumbnail now render on both macOS and hosted Web, with no unavailable cards. A single new Codex turn on the existing conversation returned expected visual-object/word matches and its correlated provider request contains an image part without a request error; no navigation was used during that turn.
- Fresh Web File Picker upload into New Conversation reproduced a separate admission failure before any user message was persisted. Real composer maps do not contain `mime_type`; hosted start previously sent null, rejected by closed validation. The process E2E fixture had supplied a synthetic MIME field and masked this. Removing that field made the original fixture fail; generic transport hint fallback restores the real composer path. Agent content inspection is unchanged.
- D5 source cause is the cleanup of current `_draftScope` after an awaited send instead of captured originating scope. Corrected-capability fixtures detect the original cleanup failure and prove accepted/failed cross-scope behavior after repair. Input cubit suite now 38/38; real-shape hosted process E2E 1/1.
- Temporary privacy-safe receive diagnostics identified actual hosted `sequence_conflict` and were removed after diagnosis. Backend root readiness endpoint is `/`, not `/health`; Docker Desktop exposes source binds with a `/host_mnt` prefix. These verification-path corrections did not indicate a runtime outage.
- Historical note at this gate: fresh-upload live rerun and cleanup were still pending. Subsequent controlled macOS/Web runs verified fresh upload, visible user/tool thumbnails, reopening and empty subsequent New Conversation drafts. Parent lightbox/protection acceptance remains independently open.

### Authorized checkpoint and follow-up

- User now explicitly authorizes a public checkpoint commit/push followed by a focused private Backend/gitlink checkpoint commit/push and exact-commit GitHub Actions observation. This is a progress checkpoint, not whole-Plan completion or merge approval.
- Current local checkpoint checks: Agent normal fast suite 2175 passed/14 skipped and analyzer clean; Client analyzer clean and selected input/group/scroll tests 86 passed; Backend handler/registry tests 26 passed. Earlier daemon-backed/hosted acceptance evidence remains recorded separately.
- [77I4](77i4-custom-image-and-attachment-edit-retry.md) owns pending custom image input and image-message edit/retry diagnosis after CI. Provider-name freshness and custom thinking stay in the separate main-based task/PR.
