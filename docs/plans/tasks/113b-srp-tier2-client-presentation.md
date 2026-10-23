---
title: "SRP Tier 2 — Client Presentation Decomposition"
description: "Split the oversized Client presentation, transport, and cubit hosts into cohesive widget libraries and coordinator owners while every key, semantics node, and driver-visible behavior stays byte-identical, and the risky wave is cut to the files the next features will touch."
status: pending
current_gate: "Wave 1 dispatchable (five move-only targets)"
remaining_estimate: 100%
base_commit: 35097c4b
tier_branch: none — one pull request per item
---

# SRP Tier 2 — Client Presentation Decomposition

## Goal

Turn the remaining oversized Client files into small cohesive libraries without changing a single
rendered pixel, selector, or emitted state, and keep them small with the size ratchet.

Scope: `client/` only — presentation, the conversation transport, and the two remaining data owners.
`shared/` and `release/contract/` are out of scope.

This is the Client half of the third SRP round. `done/110` and `done/113a` already split
`SessionMessagesCubit` into `SessionInterventionCoordinator` and `SessionWorkspaceCoordinator`,
`ConversationCacheStore` into four owners, and `SanadSocketService` into connection/transport/media
owners. What remains is presentation and three data owners.

## Verified starting point (2026-10-23, `origin/main` @ `35097c4b`)

| Fact | Evidence |
|---|---|
| 13 Client `lib` files exceed 1,000 lines | `client/test/guards/file_size_ratchet_guard_test.dart` allowlist |
| Splits regrow without a rule | `session_messages_cubit.dart` landed at 1,559 in #237 and is 1,571 now (Plans 83, 84, 124) |
| No `part`/`part of` anywhere in `client/lib` | zero files; the repo uses separate libraries |
| The report's folders do not exist | no `presentation/pages/`, `presentation/dialogs/`, or `components/` anywhere; settings "pages" already live under `widgets/` |
| The report's Client test command is wrong | `fvm dart test test/interfaces/sanad_gateway/` is an Agent suite; Client transport coverage is `device_conversation_commands_test.dart`, `compact_session_delayed_result_test.dart`, `hosted_attachment_relay_e2e_test.dart` |
| No Client PR is open | only #280 (supervisor) is open and it touches no `client/lib` file |
| No golden tests exist | `client/test` has none, so widget moves are checked by keys, selectors, and the suites |

## Binding decisions

| Decision | Landing |
|---|---|
| C1. Folder order | components stay flat (`conversation_input/composer_*.dart`); settings pages go to `widgets/settings_pages/`; no `pages/`, `dialogs/`, or `components/` folders |
| C2. Cubit strategy | one cubit per feature; decomposition is helper coordinators with typed callbacks, never extra cubits |
| C3. Diff engine | stays Client-local in `widgets/tools/diff/`, with pure-Dart parser unit tests |
| C4. MCP cubit | not now — MCP screens are move-only; a cubit is its own plan unless a feature touches MCP OAuth (none does) |
| C5. Keys and semantics | every `Key`/`ValueKey` string, `Semantics` label/flag, and tooltip stays byte-identical; the two path-reading tests are retargeted in the same PR |
| 1–2. Size ratchet | `client/test/guards/file_size_ratchet_guard_test.dart`, 13 allowlisted files, 1,000-line limit, generated output excluded; one law in `AGENTS.md` §3 and one Client Definition-of-Done line |
| 3. Move-only | behavior fixes are follow-up PRs listed below |
| 5. Old paths | high-fan-in transports/cubits keep their path as a façade; low-fan-in UI files are deleted with imports updated in the same PR |
| 6. Verification | Wave 1: analyze + focused suites + full Client fast suite. Wave 2: that plus one `sanad-dev ui` check. Wave 3: live acceptance before merge |
| 7. Delivery | one PR per item, tracked here |
| 8. Feature coordination | file locks below |

## Key and semantics preservation rule

The driver finds widgets by `ValueKey` string first, then by text/semantics, and optionally by
`widget.runtimeType.toString()`. Snapshots emit `"type"` including private class names.

- Every `Key('…')`/`ValueKey` string, `Semantics` label/flag, and tooltip is **byte-identical** after
  a move. Never re-key a widget to make a split easier.
- Contract-pinned keys that no PR may touch: settings `workspace_security_*` and
  `settings_back_to_conversations_btn`; message bodies `user_message_body:<eventId>` and
  `assistant_message_body:<eventId>`; timeline `chat_messages_list`,
  `conversation_timeline_scroll`, `fixed_conversation_activity_bar`, `agent-event-entrance:<id>`,
  `tool-group:<id>`, `ValueKey(event.id)`; composer `chat_input`, `send_message_btn`,
  `stop_message_btn`, `model_selector_btn`, `permission_mode_selector_button`,
  `composer_permission_mode_*`, `draft_attachment_*`, `attachment_error*`, `voice_chat_btn`.
- A formerly private widget that becomes a public library class changes only the snapshot `type`
  field and the type census. That is acceptable, must be named in the PR body, and must not change a
  key, semantics node, or layout.
- Tooling and tests match only framework/public type names. No test, script, or doc references a
  private class name of a target file; renaming one is safe but still declared.
- Path-reading contract tests are retargeted in the same PR as their move:
  `client/test/tool/settings_update_contract_test.dart` (reads `settings_pages.dart`) and
  `client/test/unit/scripts/flutter_driver_cli_test.dart` (reads `lib/driver_main.dart` in six
  assertions). `client/test/unit/bloc/conversation_bloc_imports_test.dart` pins the
  `session_cubit.dart` and `session_messages_cubit.dart` paths, so those paths do not move.
- Rebuild-count assertions (`conversation_input_panel_rebuild_test`) mean a move must not change
  widget identity or element re-creation. Move bodies; do not re-wrap trees.

## Wave map

| Item | Wave | Target | New units | Preconditions |
|---|---|---|---|---|
| 113-01 / R1 | 1 | `settings/presentation/widgets/settings_pages.dart` (2,018) | `widgets/settings_pages/` (10 files) | none |
| 113-02 / R2 | 1 | `widgets/conversation_input/conversation_input_composer.dart` (1,634) | 8 flat `composer_*.dart` | none |
| 113-03 / R3 | 1 | `widgets/tools/file_tool_tile.dart` (1,469) | `widgets/tools/diff/`, `widgets/tools/code_highlighting.dart` | none |
| 113-04 / R4 | 1 | `widgets/user_message_tile.dart` (1,233) | 3 flat attachment/link files | none |
| 113-05 / R8 + R9 | 1 | `mcp/presentation/screens/{add_mcp_server_screen,mcp_server_management_screen}.dart` (1,178 / 1,055) | `mcp/presentation/widgets/` | none |
| 113-06 / R5a | 2 | `data/transport/conversation_commands.dart` (1,420) | `command_response_errors.dart`, `workspace_commands.dart` | none |
| 113-07 / R12 | 2 | `lib/driver_main.dart` (1,035) | `lib/driver/` (3 files) | 113-01…113-05 merged |
| 113-08 / R10 | 2 (conditional) | `provider_setup/presentation/bloc/provider_setup_cubit.dart` (1,119) | 2 coordinators | provider work upcoming |
| 113-09 / R11 | 2 | `conversations/domain/stores/device_conversation_store.dart` (1,058) | `pending_steer_projection.dart` | none |
| 113-10 / R5b | 3 | `data/transport/conversation_commands.dart` (same file) | `conversation_history_commands.dart` | 113-06 merged, 54g not started |

Wave 1 items are file-disjoint and run concurrently. 113-06 and 113-10 share one file and are
serialized; 113-07 touches the tester backbone, so it lands after Wave 1 and gets its own live check.

---

## Wave 1 — move-only presentation splits

### 113-01 / R1 — `settings_pages.dart`

Target clusters: `ProfilePage` (L38–224), `GeneralPage` + `_BackgroundSelectionGrid` (L225–937),
`EmptyDevicePage` + `DeviceOverviewPage` (L938–1,462), `AgentRestartConfirmationDialog` and
`DeviceRenameDialog`/`DeviceNameEditor` (L1,463–1,668), `ProvidersPage` (L1,669–1,742),
`SkillsPage` + `SkillList` (L1,743–1,819), `WorkspacePage` + `WorkspaceRemovalButton` (L1,820–2,018).

New files under `client/lib/features/settings/presentation/widgets/settings_pages/`:
`profile_page.dart`, `general_page.dart`, `background_selection_grid.dart`, `device_overview_page.dart`,
`empty_device_page.dart`, `agent_restart_confirmation_dialog.dart`, `device_rename_dialog.dart`,
`providers_page.dart`, `skills_page.dart`, `workspace_page.dart`.

- `settings_pages.dart` is deleted (decision 5, option B for UI files) and its small import fan-in is
  updated in the same PR: `settings_screen.dart`, `workspace_security_card.dart`,
  `client_cli_settings_card.dart`, `add_mcp_server_screen.dart`, and the widget tests that import it
  (`profile_page_test`, `agent_restart_confirmation_dialog_test`, `device_name_editor_test`,
  `workspace_removal_button_test`, plus `appearance_widgets_test`).
- Retarget `client/test/tool/settings_update_contract_test.dart` from `settings_pages.dart` to
  `settings_pages/general_page.dart` — the update-check copy it pins moves with `GeneralPage`.
- All 43 keys move verbatim. `_ColorDot` and other helpers stay private in their new file.

### 113-02 / R2 — `conversation_input_composer.dart`

New files, flat in `client/lib/features/conversations/presentation/widgets/conversation_input/`:
`composer_paste_capture.dart`, `composer_attachment_rail.dart`, `composer_container.dart`,
`composer_permission_mode_chip.dart`, `composer_model_chip.dart`, `composer_send_stop_button.dart`,
`composer_workspace_warning.dart`, `composer_helpers.dart` (`formatAttachmentBytes`,
`maybeInputCubit`).

- The largest piece is `_UnifiedComposerContainer` (L584–961, 16 constructor parameters); it moves as
  `ComposerContainer` with the same parameters and the same child order.
- `_ComposerPasteCapture`, `_AttachmentRail`, `_AttachmentErrorLine`, `_ModelChip`,
  `_PermissionModeChip`, `_SendStopButton`, `_WorkspaceWarning` become feature-specific public classes.
- `ComposerPasteIntent` is already public. Keys are driver-critical; none change.
- Tests: `composer_input_routing_and_paste_test`, `conversation_input_composer_toggle_test`,
  `conversation_input_panel_rebuild_test` (rebuild counts must not move).

### 113-03 / R3 — `file_tool_tile.dart`

New files: `widgets/tools/diff/unified_diff_parser.dart` (pure Dart, no Flutter imports),
`widgets/tools/diff/diff_block_view.dart`, and `widgets/tools/code_highlighting.dart` (highlight cache
plus span line splitting).

- `ParsedDiffLine` and the parser stop being methods of a private `State`; add direct unit tests for
  the parser (pairing, start-line parsing, context/removal/addition, malformed input).
- The highlight cache stays owned by the widget `State` and stays cleared on theme change.
- Per-tool renderers (read/write/edit/glob/grep/fallback) may stay in the tile in this PR; splitting
  them is a second, optional step in the same item.
- Keys `file_read_*` and both existing tests (`file_tool_multi_edit_diff_test`,
  `file_tool_markdown_toggle_test`) stay green. The 14 hard-coded English labels are **not** touched
  here — they are the localization follow-up.

### 113-04 / R4 — `user_message_tile.dart`

New files, flat beside the tile: `user_attachment_grid.dart` (`UserAttachmentGrid`,
`UserAttachmentCard`, public in their own library), `inline_edit_attachment_thumbnail.dart`, and
`user_message_link_builder.dart` (with `UserMessageFileChip`).

- The inline editor **view** stays in the tile until an inline-editor item is approved; only attachment
  rendering and the link builder move now.
- 22 keys move verbatim, including the contract key `user_message_body:<eventId>`.
- Tests: `user_message_tile_test`, `brain_activity_inline_edit_test`, `image_lightbox_test`,
  `brain_activity_view_scroll_test`, `message_edit_event_tile_test`, `message_body_inspection_test`.

### 113-05 / R8 + R9 — MCP screens (move-only, no cubit)

New files under `client/lib/features/mcp/presentation/widgets/`: `mcp_server_form_fields.dart`
(remote/stdio/key-value rows), `mcp_inspection_review.dart`, `mcp_server_card.dart` (with the status dot
and meta chips), `mcp_advanced_json_dialog.dart`.

- `AddMcpServerScreen` and `McpServerManagementScreen` keep their behavior, including today's OAuth
  polling. No `McpServerFormCubit` in this round (C4); the polling loop is a follow-up behavior PR.
- Eight keys and `mcp_server_form_test`, `mcp_server_management_screen_test` stay green.

---

## Wave 2 — data and tooling owners behind unchanged facades

### 113-06 / R5a — `conversation_commands.dart` workspace and folder commands

New files in `client/lib/features/conversations/data/transport/`: `workspace_commands.dart` (workspace
CRUD, folder CRUD, tree browse, slash lookup) and `command_response_errors.dart` (`responseError`,
`throwIfErrorResponse`, the `WorkspaceCommandFailure` mapping).

- `ConversationCommands` stays the façade, so `SocketConversationClient` is untouched and
  `conversation_commands.dart` keeps its path (decision 5, option A for this file).
- `client/lib/features/conversations/AGENTS.md` names the shared `_responseError` helper; update it to
  the new owner in the same PR.
- Session commands, history hydration, and `_CompactSettlement` stay in the host for 113-10.
- Tests: `device_conversation_commands_test`, `compact_session_delayed_result_test`,
  `hosted_attachment_relay_e2e_test`.

### 113-07 / R12 — `driver_main.dart`

New files in the existing `client/lib/driver/`: `driver_widget_filters.dart`,
`inspect_ui_extension.dart`, `interaction_extensions.dart` (tap, scroll, enter-text, reveal).

- `lib/driver_main.dart` stays the entry point path: `sanad-dev`, `docs/technical/flutter_vm_driver_cli.md`,
  the `sanad-client-tester` skill, and the interactive test harnesses all reference it.
- Retarget the six source-string assertions in `client/test/unit/scripts/flutter_driver_cli_test.dart`
  to the new owners (`interaction_extensions.dart` for the enter-text/input-channel assertions,
  `inspect_ui_extension.dart` for the census/selection assertions), and add one guard that
  `driver_main.dart` still registers all six extensions in the documented order.
- Live check is mandatory: `sanad-dev ui` inspect, find, tap, and enter-text on the affected surface.

### 113-08 / R10 — `provider_setup_cubit.dart` (conditional)

New files: `provider_auth_flow_coordinator.dart` (OAuth start/poll/cancel plus poll generations) and
`provider_model_selection_coordinator.dart` (discovery generation, select/confirm/refresh).

- `snapshotGeneration` stays owned by the cubit — it is a contract law in `client/AGENTS.md`.
- This item runs **only if provider work becomes upcoming** (the study's condition). With no provider
  feature on the board, Wave 2 is complete without it and the item moves to the deferred list.
- Tests: `provider_setup_cubit_test` (31), `provider_setup_flow_test` (24).

### 113-09 / R11 — `device_conversation_store.dart`

New file: `client/lib/features/conversations/domain/stores/pending_steer_projection.dart` (pending
steer map, stop-recovered keys, reconcile/hydrate/cancel outcome), beside the existing
`SessionExecutionRegistry` and `SessionRouteRegistry`.

- Emit order and the eight broadcast controllers stay as they are. Tests: `turn_replay_projection_test`
  and the five other importing suites.
- This is also the store a future device-scoped notification projection would join, so it is
  decomposed before the features start.

---

## Wave 3 — cut by the next features

Wave 3 contains only the Client files that Task 54 and the two unwritten features will touch.

| Grep target | Needed by | Wave | Why |
|---|---|---|---|
| `data/transport/conversation_commands.dart` | 54g | 3 (`113-10`) | `deleteSession` (L1,322) lives here and 54g G2 adds the non-terminal preflight and cancel-all before deletion; delete is triggered from `sidebar_conversation_row.dart` → `session_cubit.deleteSession`. 113-06 already removes the workspace/folder half in Wave 2 |
| `presentation/bloc/session_messages_cubit.dart` | none | deferred | 54f's panel integrates at the composer host (`conversation_input_panel.dart`, where `QueuedMessagesBox` renders) over a new device-scoped task store; 54g deletes through `session_cubit`; notifications are cross-conversation; internal sub-agents surface as an ordinary tool call and result, which the existing tool tile already renders |
| `presentation/screens/brain_activity_view.dart` | none | deferred | 54f changes no timeline or scroll behavior, and no other next feature touches the viewport |
| `presentation/bloc/session_cubit.dart` | 54g (touched) | not a split item | 54g edits `deleteSession`, but the study keeps this cohesive cubit intact this round; the feature waits on the file lock instead |
| `widgets/conversation_input_panel.dart` | 54f (touched) | not a split item | 901 lines, under the limit; the task panel is added where `QueuedMessagesBox` already renders |
| `domain/stores/device_conversation_store.dart` | Notifications (possible) | 2 (`113-09`) | decomposed before the features so a notification/notice projection lands on an owned store |

### 113-10 / R5b — `conversation_commands.dart` history owner

- New file: `client/lib/features/conversations/data/transport/conversation_history_commands.dart`
  (initial/anchored/older/newer hydration, cursor state, `_historyHydrationGeneration`, in-flight
  de-duplication, retry and delayed-loading timer), with an owner test that fails if a stale
  generation is accepted.
- `ConversationCommands` stays the façade; its path and public API do not change.
- Reconnect-critical: stale generations must be rejected exactly as today, and the history payload
  order must not move.
- Feature dependency: 54g edits this transport file's deletion path, so 113-10 must merge (and release
  its lock) before 54g starts.

### Deferred out of Wave 3

| Item | Why |
|---|---|
| R6a/R6b `session_messages_cubit.dart` route-selection and history owners | No next feature touches the cubit: 54f hydrates a new device-scoped task store at the composer host, 54g deletes through `session_cubit`, notifications are cross-conversation, and internal sub-agents surface as an ordinary tool call and result. Revisit when a feature plan names the cubit |
| R7 `brain_activity_view.dart` stages (autofill policy, replay/fork actions, scroll coordinator) | No next feature changes the timeline or viewport; the scroll coordinator additionally needs live acceptance booked and a quiet file |
| R7 stage 2 inline-edit controller | Depends on 113-04 and R7 stage 1, and no feature needs it |
| `session_cubit.dart` | Cohesive owner imported by 23 test files and touched by active Plans 124, 43b, and 83h; 54g's deletion edit waits on the file lock instead |
| `model_picker_dialog.dart` (999), `home_screen.dart` (975), `socket_conversation_client.dart` (957), `conversation_input_panel.dart` (901) | Under the 1,000-line limit and already cohesive; tracked by the ratchet only |
| Diff parser as a `shared/` package | C3: the Agent does not render diffs and the highlighter is Flutter-bound; keep it Client-local |

---

## Follow-up behavior PRs (deliberately outside the moves)

These are defects found during the study. They are **not** part of any move PR (decision 3); each one
lands after the move that touches its file.

| Item | Owner after the move | Fix |
|---|---|---|
| SkillsPage fetch in `build` | `settings_pages/skills_page.dart` (after 113-01) | `getIt<DeviceSkillsClient>().list(...)` is created inside `FutureBuilder(future:)`, so every rebuild refetches. Load once in a cubit/state owner and render state. Violates the "Render and Request Independence" law |
| Hard-coded English literals | `settings_pages/*.dart` and `file_tool_tile.dart` (after 113-01/113-03) | Move tab labels and page titles, and the 14 file-tool labels, into `app_en.arb` (plus `ar`). No Arabic literal in handwritten Dart |
| MCP OAuth polling | `mcp/presentation/…` (after 113-05) | `AddMcpServerScreen._authorizeOAuth` polls with a hard-coded `Duration(seconds: 2)` from widget state. Introduce the form cubit (C4's own plan) and a centrally configured interval |

## File-lock coordination

- Every open SRP PR declares its full file set; a feature PR may not edit a locked file. All other
  work continues.
- Lock on PR open, release on merge or close. No rebase across a lock: merge the conflicting change
  first, then rebase the feature.
- 113-06 and 113-10 share `conversation_commands.dart` and are serialized. 113-04 and any later
  inline-editor work share `user_message_tile.dart` and are serialized. 113-03 and 113-02 are
  independent.
- Feature work that would grow an allowlisted file must land net-zero or shrink it; the ratchet
  enforces the rule.

## Verification bar per wave (decision 6)

| Wave | Bar |
|---|---|
| 1 | `fvm flutter analyze` clean; focused widget/unit suites named per item; one full `fvm flutter test` on the frozen candidate; `git diff --color-moved` review |
| 2 | Wave 1 bar plus one `sanad-dev ui` inspect/find check of the affected surface (mandatory for 113-07, including tap and enter-text) |
| 3 | Wave 2 bar plus live acceptance of history hydration across reconnect and a conversation switch on an isolated Test Home |

Every gate preserves its exit code and reports command, exit code, counts, duration, and log path with
a bounded final-five-line summary. Client and Agent suites never run concurrently.

## Size ratchet

- `client/test/guards/file_size_ratchet_guard_test.dart` fails any non-generated `lib/` file over
  1,000 lines without an allowlist entry, and fails an allowlisted file above its recorded count.
- Generated output (`*.g.dart`, `*.freezed.dart`, `generated_*`) is excluded, and so is the
  `gen_l10n` output `lib/l10n/app_localizations*.dart`: it is written on every build, gitignored, and
  grows with the translation catalog rather than with a missing owner.
- The allowlist holds 13 files today. Each item above lowers or removes its entries in the same PR:
  113-01 removes `settings_pages.dart`, 113-02 lowers the composer, 113-03 lowers `file_tool_tile`,
  113-04 lowers `user_message_tile`, 113-05 lowers both MCP screens, 113-07 lowers `driver_main`,
  113-10 lowers `conversation_commands`. The guard fails on dead entries, so the list cannot rot.
- Numbers only go down. Never raise one to absorb growth.

## Presentation conventions recorded in `client/lib/features/AGENTS.md`

This PR adds the durable presentation-decomposition laws there (C1–C5): flat component files,
`widgets/settings_pages/` for settings pages, no `pages/`/`dialogs/`/`components/`, separate libraries
with feature-specific public names and `@internal` (no `part`), helper coordinators with typed callbacks
instead of extra cubits, the client-local diff owner, and the key/semantics preservation law.

## Progress ledger

One row per item, appended by the orchestrator.

| Item | PR | Status | Files locked | Verification |
|---|---|---|---|---|
| docs + guard (this PR) | | in progress | `AGENTS.md`, `agent/AGENTS.md`, `client/AGENTS.md`, `client/lib/features/AGENTS.md`, plans, `docs/llms.txt`, two guard tests | see PR |

## Definition of Done

- Every Wave-1 and Wave-2 item is merged; the Wave-3 item a feature needs is merged before that feature
  starts.
- Every moved widget keeps its keys, semantics, tooltip, and rendered structure; every emitted state
  and event order is unchanged.
- Public APIs reachable with unchanged names; path-pinned tests retargeted in the same PR; no `part`.
- `fvm flutter analyze` clean, focused suites at or above baseline counts, full Client fast suite per
  wave, and the size ratchet green with only real allowlist entries and no raised number.
- Owning contracts and `docs/technical/*` path references updated in the same PR; `graphify update .`
  after each code PR.
