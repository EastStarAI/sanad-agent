---
title: "Input Files and Media Presentation"
description: "Unified paste/drop/picker file routing with composer path tokens, user-message newline and file-chip rendering, inline-edit image previews, a responsive view_image gallery, screenshot-as-media parity, and remote attachment disclosure."
status: in_review
current_gate: G-live (coordinator live acceptance on a Test Home)
remaining_estimate: 15%
port_base_commit: adc128ec
port_branch: feat/114-port
evidence_id: "114-input-media"
evidence_fingerprint: "sha256:4372c21c241d96d7b56042f56f93b79b5a851f9914bcb72305a2191332612f0e"
---

# Plan 114 — Input Files and Media Presentation

## Goal

Fix the reported post-Plan-77 defects and land one coherent input/media behavior: clipboard and drag & drop behave identically for every file, non-image files on a same-machine agent become friendly path tokens instead of hidden attachments, images keep working as attachments, user messages preserve typed newlines and render file references as icon chips, editing a message shows its image previews, consecutive `view_image` results render as a responsive gallery, `system_screenshot` delivers its image to the model and the UI like `view_image`, and remote non-image attachments are disclosed to the model with a remote-side reference.

## Locked decisions

- **One routing matrix for paste, drop, and the `+` picker** (no separate behaviors):
  - Image with provider-safe format (`image/png`, `image/jpeg`, `image/webp`, `image/gif`) and ≤ 5 MiB → draft attachment (existing upload/admission pipeline).
  - Image with a provider-safe format but > 5 MiB on a same-machine agent → path token (no rejection). Remote → clear rejection (existing attachment error UX).
  - Image with any other format (HEIC/TIFF/BMP/SVG/…) → path token on a same-machine agent; on a remote agent → draft attachment (and on the wire it is treated as a file reference, never an image part — see 114f).
  - Non-image file on a same-machine agent → path token.
  - Non-image file on a remote agent → draft attachment (≤ 5 MiB; above the limit → clear rejection).
  - If a same-machine agent lacks attachment capability, a safe-format image ≤ 5 MiB falls back to a path token instead of failing.
  - No count cap on path tokens; the user may reference as many files as desired.
- **Same-machine semantics**: routing uses the active agent's same-machine identity (`DeviceConfig.isLocalCandidate`, i.e. matching `hardwareId`), not local-socket connectivity (`isLocalReachable`); mobile clients always count as remote; unknown/absent hardware identity counts as remote (safe default).
- **Reference token format (pinned)**: the composer inserts a token that exports on send as `[<file name>](file:///<percent-encoded absolute path>)` (via `Uri.file(...).toString()`). The token is rendered in the composer as the existing file-type icon (`FileExtensionIcon`) plus the file name; the raw path is never shown as plain text.
- **Paste capture must not depend on the iOS/web-only clipboard-events path**; the repair targets a platform-portable capture that reads all common image formats and file URLs, keeps ordinary text paste untouched, and is proven by live macOS acceptance plus widget tests.
- **The historical raw-path drop behavior is replaced, not kept**: one drop target routes per the matrix above; the duplicate drop target and raw `insertDroppedPathsAsText` usage are removed; the drag visual state is preserved on the surviving target.
- **Image-part projection is format-gated**: only PNG/JPEG/WebP/GIF attachments may become `image_url`/image parts on the wire; every other file (including exotic image formats) is delivered as a reference line with an agent-side path plus one-line tool guidance, and never leaks a client-side path.
- **User messages preserve typed newlines**: Shift+Enter line breaks render as real line breaks in the conversation history.
- **Screenshot parity**: `system_screenshot` returns an image block plus its existing human-readable summary; the client renders it exactly like a `view_image` result (thumbnail + lightbox), and the model receives the image content through the existing generic tool-image projection.
- Local commits on the port branch were authorized for the SRP port; push, pull request, and merge still require explicit user authorization.

## Task breakdown

| Task | Scope | Owner surface |
|---|---|---|
| 114a | Composer input: unified paste/drop/picker routing, paste repair, path tokens, rail start alignment | Client |
| 114b | User-message rendering: Shift+Enter newlines + file-link chips | Client |
| 114c | Inline-edit image previews for existing attachments | Client |
| 114d | Responsive `view_image` gallery for consecutive results | Client |
| 114e | `system_screenshot` as media (agent + client) | Agent + Client |
| 114f | Remote attachment disclosure on the model wire | Agent |

Dependency order: 114a is the anchor; 114b/114c/114d are independent client tasks; 114e is independent; 114f depends on the routing decisions only (matrix above) and may proceed in parallel.

## Grounding

- Evidence: `evidence_id: 114-input-media`, fingerprint `sha256:4372c21c241d96d7b56042f56f93b79b5a851f9914bcb72305a2191332612f0e` (packet and run records live in the ignored evidence store).
- Each task's R0 gate resolves the packet before implementation.

## Definition of Done (plan level)

- All tasks reach their gates with focused tests, analyzer clean, and live/visual verification recorded per task.
- `docs/` pages for affected surfaces are updated in the same sessions (composer input, user-message rendering, conversation media, agent screenshot tool).
- `graphify update .` runs after code changes.
- Delivery follows the repository PR lifecycle after explicit user authorization.

## Port to the SRP base (Task 110)

The original 114 work was built on `b02b9e62`. It was transplanted (not merged) onto `adc128ec` on `feat/114-port`, placing each change in its Task 110 owner, and every part was re-reviewed against its task file: no earlier "tested stage" claim was carried over without fresh review.

### Commits

| Commit | Part | Content |
|---|---|---|
| `aff1e56e` | 114f | Remote attachment disclosure and format-gated image parts |
| `8a0553ef` | 114e | Screenshot delivered as media through the wire and the UI |
| `11ec07a9` | 114b | Shift+Enter line breaks and inline file chips in user messages |
| `2d6a33b3` | 114a | Unified paste/drop/picker routing, paste repair, file tokens |
| `d5ea67aa` | 114c | Existing image previews in the inline edit rail (WIP completed) |
| `b51c2b55` | 114d | Responsive media gallery in tool groups (WIP completed) |
| `27f51657` | 114a | Web startup contract test pinned to the AppPlatform invariant |

### Ownership after the port

| Behavior | Owner |
|---|---|
| Image-only text projection for non-vision routes (non-images now reach the adapter discloser) | `agent/lib/engine/runtime/runner_context_projector.dart` (was `AgentRunner`) |
| Wire disclosure and the safe image-format gate | `agent/lib/engine/adapters/user_attachment_wire_discloser.dart`, called by the OpenAI, Anthropic, Codex, and Ollama serializers |
| Media-bearing tool set | `ViewImageMediaMetadata.mediaToolNames` (agent) and the `ViewImageMediaEvent` extension (client) |
| Deferred media event publication | `ToolExecutionCoordinator` (every completion path) |
| Paste/drop/picker routing matrix | `client/lib/features/conversations/presentation/utils/composer_input_router.dart` |
| File-reference link format, parse, and escaping | `client/lib/features/conversations/presentation/utils/file_reference_link.dart` |
| Media-card rule shared by the single row and the gallery | `rendersAsMediaCard` on `ViewImageMediaEvent` |

The client session cubit coordinators were not touched: 114 changes stay in composer, timeline widgets, and the input cubit.

### Review defects found and repaired

See each task file's progress log for locations and regression tests.

- **114a:** attachment bytes read only through `dart:io` (empty attachments for web/data-backed files); Cmd/Ctrl+V captured even when the message field had no focus; pasted image names kept a mismatched suggested extension; web was not excluded from same-machine routing; file-token links did not escape label brackets or path parentheses, and draft restore failed on such paths; dead raw-path drop helper and external paste manager; duplicated rejection copy; a stale Web startup contract test.
- **114b:** chips and ordinary links were returned as non-text widgets, splitting the paragraph into separate wrap children and restyling ordinary links; "Read more" measured raw file URIs.
- **114c:** the WIP synthesized an attachment identity with a placeholder digest, ignored availability, and refetched when a rebuilt parent passed a new loader.
- **114d:** a third, divergent media predicate (a text-only screenshot could join a gallery); the extracted card refetched on a new loader instance.
- **114e:** the media tool names were duplicated across three agent and four client sites; the deferred-result completion path still deferred only `view_image`.
- **114f:** no behavioral defect; port adaptation for the changed OpenAI serializer signature; exactly-once disclosure assertions added.

### Live-found defects

- **114a (Test Home 3, candidate `389caede`):** after "Each attachment must be 5 MiB or smaller." appeared in the composer it could not be dismissed and stayed after the user removed attachments. Causes:
  - the rejected file never enters the rail, so there was nothing to remove for it;
  - no dismiss control existed;
  - a text-only send did not clear the error;
  - `ConversationInputCubit` cached the error with each draft scope, so returning to a session restored it;
  - the copy was hardcoded English with fixed 4 / 5 MiB / 20 MiB, even when the agent advertises other limits, and the inline editor duplicated the rule.

  Fix (114h on `feat/114-port`): a typed `DraftAttachmentError` from one `DraftAttachmentPolicy`, never cached per scope. It clears on remove, next successful add, send, scope change, and an explicit × (`attachment_error_dismiss`, `inline_edit_attachment_error_dismiss`), with localized en/ar copy stating the enforced limit. Red-first regressions:
  - `test/unit/bloc/conversation_input_cubit_test.dart` ("transient feedback" group): the scope-restore and text-only-send cases failed on the old code;
  - `test/widget/composer_input_routing_and_paste_test.dart` ("Attachment rejection feedback"): the old code showed `5 MiB` for a 1 MiB agent limit and had no dismiss;
  - `test/widget/brain_activity_inline_edit_test.dart` (inline dismiss/remove/next add).

  Red logs: `temp/114/114h-red-cubit.log`, `temp/114/114h-red-widget.log`. Follow-up (114i):
  - the inline editor now receives the presented device's `Capability` limits (`BrainActivityView.attachmentCapability`, wired by `HomeScreen` from `DeviceCapabilitiesCubit`);
  - its open-failure, read-failure, and "remove or retry before sending" messages are localized (en/ar);
  - tests: `test/widget/brain_activity_inline_edit_test.dart` covers a non-default 1 MiB limit and the localized open failure.
- **114g privacy follow-up (114i):** `ConversationMediaByteCache.shared` was never cleared, so hosted (cloud) media bytes fetched under one account could survive into the next session. `AppAuthListener`, the existing auth teardown owner, now calls `bindAccount(userId)` on `AuthAuthenticated` and `bindAccount(null)` on `AuthUnauthenticated` (sign-out, revoked or lost auth). A different account or sign-out drops every hosted entry; local device media is kept, mirroring `clearCloudUserScope`. Test: `test/unit/conversations/conversation_media_cache_test.dart` ("account binding").

### Verification (port worktree)

- `fvm dart analyze` (agent): no issues. `fvm flutter analyze` (client): no issues.
- Full agent suite: 3,038 passed, 14 skipped, 0 failed.
- Full client suite: 1,810 passed, 1 skipped, 0 failed with `-j 4`. Two default-parallelism runs each lost one file to a `flutter_tester` connection failure ("Invalid WebSocket upgrade request") under host load; both files pass alone.
- Daemon E2E (`--concurrency=1`): agent `view_image_tool`, `sanad_gateway_platform`, `platform_tool_execution` (17 passed); client `hosted_attachment_relay` (1 passed).
- `fvm flutter build macos --debug` succeeds (Swift monitor removal compiles).
- `graphify update .` run in the port worktree.
- Logs live in the ignored `temp/114/` folder of the port worktree.

### Remaining

- Coordinator-owned live acceptance on a Test Home for every part (see each task's live gate).
- Delivery (push and Draft pull request) after explicit authorization.
