---
title: "Task 143 — Remote Change Path through the confined browser"
description: "Offer Workspace Settings → Change Path for a device reached over the cloud by reusing the Task 123 confined folder browser and the Agent's existing preview-ticketed workspace.relocate, with an in-root notice, one confirmation line naming the resolved target, and a specific out-of-root message."
status: in_progress
current_gate: "G5 closed — implementation, tests, guards, full fast suite, and docs done; G6 delivery in progress"
remaining_estimate: "~10% (CI and coordinator live acceptance)"
base_commit: 23b7a825
depends_on: "Task 123 (confined remote browser, done); Task 140 (settings pages split, done)"
delivery: own PR
---

# Task 143 — Remote Change Path

## Goal

A Client inspecting a device reached over the cloud can change that workspace's folder from Settings →
Workspace → Change Path, using the same confined in-app browser Task 123 shipped, and only into a folder
strictly inside the device Home's managed workspaces root. The same-desktop local device keeps the native
macOS picker unchanged.

Client only. No Agent, protocol, or Gateway change.

## Verified starting point (2026-10-24, `23b7a825`)

| Fact | Evidence |
|---|---|
| The Agent already relocates remotely end to end: managed confinement, preview, ticket, `stale_confirmation` | `agent/lib/interfaces/runtime/workspace_file_system_coordinator.dart` (`resolveManagedDirectory`, `requireManagedWorkspaceDirectory`); `agent/lib/interfaces/runtime/local_workspace_runtime_service.dart:243-275`; `agent/lib/interfaces/platforms/sanad_gateway/handlers/workspace_command_handler.dart:124-168` |
| Relocate is metadata only: one `workspaces.path` update, no folder is moved, sessions survive by UUID | `agent/lib/interfaces/runtime/local_workspace_runtime_service.dart` (`_relocateWorkspaceUnchecked`) |
| A running turn keeps the root it captured when its catalog was built; only the next turn re-resolves it | `agent/lib/capabilities/runtime/local_runtime_catalog.dart:225-259` (`_resolveTargetWorkspacePath`) |
| Rejections reach the Client as a coded `error` (`path_not_allowed`, `workspace_in_use`, `stale_confirmation`) | `agent/lib/interfaces/platforms/sanad_gateway/handlers/support/agent_event_envelope.dart:43-58`; `client/lib/features/conversations/domain/models/workspace_command_failure.dart` |
| The transport already performs the preview → ticketed retry for `workspace.relocate` | `client/lib/features/conversations/data/transport/workspace_commands.dart:182-215` |
| The cache patches the workspace only from the authoritative reply | `client/lib/features/conversations/data/repositories/conversation_cache_repository.dart:401-413` |
| Only two Client gates block remote Change Path: the button gate and the picker's local-only branch | `client/lib/features/settings/presentation/screens/settings_screen.dart:414`; `client/lib/utils/workspace_picker_helper.dart:29-46` |
| The browser is hard-wired to "a folder that *becomes* a workspace": no mode, CTA "Use This Folder", disabled at the root | `client/lib/features/conversations/presentation/widgets/workspace_browser_dialog.dart:303,529` |
| Managed browse with an empty path opens the root; a `workspace_id` scope rewrites `root_path` to the workspace folder, so it cannot serve a relocate target picker | `agent/lib/interfaces/runtime/workspace_file_system_coordinator.dart:126-165` |
| No test covers Settings Change Path | `grep -rn "Change Path" client/test` returns nothing |

## Binding decisions (2026-10-24)

| # | Decision |
|---|---|
| D1 | Offer remote Change Path: **option A**, reusing the Task 123 confined browser. Option B is rejected (the native picker stays for local); option C is rejected. |
| D2 | Target scope is unchanged on the Agent: strictly inside `<SANAD_HOME>/workspaces`. The UI says so before the user picks. |
| D3 | One explicit confirmation line naming the resolved target, then send. The Agent's preview ticket stays invisible. |
| D4 | The browser opens at the workspace's current folder when it is inside the root, otherwise at the root. |
| D5 | In-flight work is allowed, with no new lock. A running turn keeps the old folder until its next turn. |
| D6 | Localize only the strings this adds or changes, through `client/lib/l10n/app_en.arb` and `app_ar.arb`. |
| D7 | Out-of-root target: the specific copy "This device can only change to a folder inside its Sanad workspaces root" (en + ar) instead of the daemon reason. |
| D8 | Same-desktop shape is unchanged: `isLocalReachable` keeps the native picker. The same-device cloud-only shape stays unsupported (`docs/technical/communication_protocols.md` §3.2). |

## Work

### W1 — one picker, two routes

`WorkspacePickerHelper.pickWorkspacePath` gains `remoteBrowser` (`WorkspaceBrowserCallbacks?`) and
`remoteStartPath`. A device that is not local-reachable but is online delegates to the existing
`openRemoteFolderBrowser`; one dialog, one path, no second picker. A missing `remoteBrowser` keeps today's
refusal so a future caller cannot silently drop the pick.

### W2 — the dialog carries the change mode

`WorkspaceBrowserDialog` gains `mode` (`createWorkspace` | `changePath`) and `initialPath`. In change mode the
CTA reads "Change to This Folder" (from `AppLocalizations`, not a caller-supplied literal), the CTA stays
disabled at the root, a notice states the in-root scope (D2), and the first load starts at `initialPath`,
falling back to the device root when that folder is outside the root or gone (D4). Create mode is unchanged.

### W3 — Settings wiring, gate, out-of-root copy

- `settings_screen.dart` passes `WorkspaceBrowserCallbacks.forDevice(_cache, selected)` bound to the
  **inspected** device, never the active conversation's.
- The gate becomes `isOnline`, matching Remove Workspace; a local-reachable device still takes the native
  picker through the same helper (D8).
- The flow lives in one presentation owner (`settings_pages/workspace_change_path.dart`): pick → one
  confirmation line naming the resolved target (D3) → `relocateWorkspace` → error mapping, where
  `path_not_allowed` renders the D7 copy and every other code keeps the daemon reason.

### W4 — tests

New `client/test/widget/settings/workspace_change_path_test.dart`:

- the Change Path action is offered for an online remote device and absent offline, and the page renders the
  button only when the action exists;
- a local-reachable device still takes the native-picker branch and never opens the browser;
- a remote pick opens the browser with callbacks bound to the inspected device, at the workspace's current
  folder, and cancel sends nothing;
- a pick plus confirm sends exactly `workspace_id` + `new_path`, then the ticketed retry;
- `path_not_allowed` renders the D7 copy; another coded rejection keeps the daemon reason.

Regressions: the dialog's create mode (existing suite) and the helper's three existing callers (composer,
sidebar, schedules editor). Localization: en + ar, with an RTL pump of the dialog in change mode.

### W5 — docs in this PR

`client/lib/features/settings/AGENTS.md` (replace "Remote Change Path is not offered here"),
`client/lib/features/conversations/presentation/AGENTS.md` (the shared-picker paragraph),
`docs/technical/workspace_identity_protocol.md` (Client UX),
`docs/technical/workspace_folder_mutation_protocol.md` (Client + relocation semantics, with the D5 note),
`docs/technical/remote_device_control_threat_model.md` (no new authority class),
`docs/qa_maintenance/workspace_identity_relocation_qa.md` (remote Change Path rows).

## Security

- No new authority class. Workspace commands carry no narrower owner flag; an owner can already create,
  rename, and recursively delete folders inside the root from the cloud (`workspace_command_handler.dart`),
  so relocating a workspace record stays inside the authority Task 123 already ships (D1, study §4).
- Confinement is Agent-owned and unchanged: the target must resolve to an existing directory strictly inside
  `<SANAD_HOME>/workspaces`, with no link at any component, and never the root itself.
- The Client never assembles the target path: it returns a path the device itself reported in a
  `workspace_tree` reply, and the Agent revalidates it at preview and again at execution.
- The dialog stays folders-only and discloses nothing outside the root; the new copy reveals only that the
  root is the bound, which `list_workspaces` already implies.
- The preview ticket stays invisible to the user (D3); no token, fingerprint, or Home path is rendered.
- Out-of-root and in-root states are decided by the Agent's replies, not by Client-side path arithmetic.

## Live acceptance outline (coordinator-owned, two cloud Test Homes)

Never a same-device local-gateway-off shape; no `~/.sanad`, no port 58085. Outline: TH1 Client cloud-connected
to TH2 opens Settings → Workspace → Change Path, sees the in-app browser at the workspace's current folder,
picks a new folder, confirms the named target, and TH2's `list_workspaces` and a `pwd` tool call follow; an
over-the-cloud relocate to `/`, `$HOME`, the TH2 Home, `<root>/../x`, a NUL path, a symlink, and the root each
return `path_not_allowed` with the localized copy and no disk change; a second Client keeps the old path until
its next refresh (D5 evidence); Arabic pass of the CTA, notice, and out-of-root copy.

## Work split

| # | Item | Files | Size |
|---|---|---|---|
| W1 | Picker helper remote branch | `client/lib/utils/workspace_picker_helper.dart` | +35 |
| W2 | Dialog mode, CTA, notice, start folder | `workspace_browser_dialog.dart`, both ARB files | +60 |
| W3 | Settings wiring, gate, flow, D7 mapping | `settings_screen.dart`, `settings_pages/workspace_change_path.dart` | +90 |
| W4 | Tests | `client/test/**` | +300 |
| W5 | Docs and contracts | 6 pages | ~6 pages |

One writer round, one review, one coordinator-run live session. Size ratchet: no raised number, no new entry —
every touched file stays far below 1000 lines.

## Gates

### G1 — Task plan
- [x] This file committed on `feat/143-remote-change-path`.

### G2 — Picker and dialog (W1, W2)
- [x] `pickWorkspacePath` delegates to the confined browser for an online non-local device.
- [x] Change mode: CTA label, D2 notice, D4 start folder with a silent root fallback, root still disabled.
- [x] `fvm flutter gen-l10n` and `fvm flutter analyze` clean; dialog create-mode suite green.

### G3 — Settings wiring (W3)
- [x] Gate is `isOnline`; callbacks bound to the inspected device.
- [x] D3 confirmation names the resolved target; `path_not_allowed` renders the D7 copy.

### G4 — Tests (W4)
- [x] New Settings Change Path suite covers presence, binding, D4, cancel, send + ticketed retry, D7, and the
      local native-picker path.
- [x] Existing dialog, composer, sidebar, and schedules callers stay green; en/ar with an RTL pump.
- [x] `fvm flutter test test/guards/` green.

### G5 — Docs (W5)
- [x] The docs pages updated, with no stale "remote Change Path is a follow-up" or "local only" text left.
- [x] `fvm dart run scripts/lint_wiki.dart` from the repository root.

### G6 — Delivery
- [ ] No `Co-Authored-By` or "Generated with" line anywhere.
- [ ] PR opened to `main`; CI green.

## Acceptance criteria

- [ ] Given an online device reached over the cloud, when Settings → Workspace is opened, then Change Path is
      offered and opens the in-app browser rather than a native panel.
- [ ] Given the workspace's current folder is inside the root, when the browser opens, then it starts there;
      otherwise it starts at the root without an error.
- [ ] Given a chosen folder, when the CTA is pressed, then one confirmation names that folder before any
      command is sent, and the sent payload is exactly `workspace_id` + `new_path` (plus the invisible
      preview ticket on the retry).
- [ ] Given a target outside the root, when the Agent rejects it, then the D7 copy is shown and the workspace
      keeps its path.
- [ ] Given a same-desktop local device, then the native picker is used and the browser never opens.
- [ ] Automated coverage proves every item above without a live daemon.

## Definition of Done

- Analyzer clean; focused suites, guards, and one full Client fast suite green with recorded counts.
- `fvm flutter gen-l10n` regenerated and committed; en/ar strings complete.
- Owning `AGENTS.md` files and the documentation pages updated in this PR.
- `graphify update .` run after the code change.
- Live acceptance dispatched by the coordinator; this task closes on that evidence.

## Verification record (2026-10-24)

| Gate command | Result |
|---|---|
| `fvm flutter gen-l10n` (in `client/`) | exit 0 |
| `fvm flutter analyze` (in `client/`) | No issues found, exit 0 |
| `fvm flutter test test/widget/settings/workspace_change_path_test.dart test/widget/workspace_browser_dialog_test.dart` | 22 passed, exit 0 |
| `fvm flutter test test/unit/services/device_conversation_commands_test.dart test/widget/device_workspace_sidebar_structure_test.dart test/widget/schedules/schedule_editor_sheet_test.dart test/widget/conversation_input_panel_rebuild_test.dart` | 128 passed, exit 0 |
| `fvm flutter test test/guards/` | 6 passed, exit 0 |
| `fvm flutter test` (full Client fast suite) | 2365 passed, 3 skipped, exit 0 |
| `fvm dart run scripts/lint_wiki.dart` (repository root) | success, exit 0 |

No Agent, protocol, or Gateway file changed.
