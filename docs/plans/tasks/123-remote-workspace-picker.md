---
id: 123
title: Remote workspace picker confined to the managed workspaces root
status: planned
gate: design (awaiting user answers to the open questions)
created: 2026-10-21
parent_task: none
depends_on: []
delivery: own PR
---

# Task 123 — Remote Workspace Picker

## Goal

A Client connected to a device over the cloud (`managed_remote`) chooses a workspace through the in-app folder browser again. The browser starts at, and never leaves, the device Home's managed workspaces root (`<SANAD_HOME>/workspaces`, `~/.sanad/workspaces` on a normal Home). Inside that root the user can browse, pick any nested folder as the workspace, and create, rename and delete folders. The Agent enforces the confinement itself and never trusts the Client.

## User Requirement (2026-10-21)

- For remote (cloud, `managed_remote`) Clients, restore the old in-app popup that browses the Agent machine.
- Confine it to `~/.sanad/workspaces` on the Agent machine (the Home's managed workspaces root), never outside that root.
- Allow browsing, picking **any nested folder** as the workspace, and creating, renaming and deleting folders: the same behaviour as the old popup.
- It **replaces** today's name-only "New Workspace" popup for remote devices.
- A local connection keeps the native macOS file picker. That is correct and must not change.

## Findings

### Old popup history

| Commit | Date | What happened |
|---|---|---|
| `35334877` | 2026-08-01 | "Initial open-source release of Sanad Agent". Added `WorkspaceBrowserDialog` in `client/lib/features/conversations/presentation/widgets/workspace_browser_dialog.dart`. It was opened from `device_workspace_sidebar.dart` (`_pickWorkspacePath`, remote only; local used `getDirectoryPath`), `conversation_input_panel.dart` and `settings_screen.dart`. **No confinement**: an empty path listed the system roots (`_browseSystemRoots`), any absolute path could be browsed, and delete was a recursive delete of any non-root, non-symlink folder. |
| `7fcc5b77` | 2026-08-06 | "sec(gateway): disable remote workspace management and enforce local-only selection (#36)". A security freeze: the three call sites were removed, `client/lib/utils/workspace_picker_helper.dart` was added, remote use showed "must use a local connection", and the Gateway rejected the workspace and folder commands with `remote_workspace_management_disabled`. |
| `11790d1d` | 2026-08-30 | "feat(remote): secure device workspace and MCP control" ([Task 82](docs/plans/tasks/done/82-secure-remote-device-control-workspaces-and-mcp.md)). Remote create became name-only (`_promptRemoteWorkspaceName`, creating `SANAD_HOME/workspaces/<name>`), and the Agent gained `managed_remote` allowed-root browse and preview-token deletes. G9 removed the "Browse folders" button but **kept the dialog and the daemon commands** for a future file-tree feature. `WorkspacePickerHelper.openRemoteFolderBrowser` was added but has no callers. |

Last good wiring for reference: `git show 35334877:client/lib/features/conversations/presentation/widgets/sidebar/device_workspace_sidebar.dart` (around line 377).

### What exists on `adc128ec`

- **Dialog.** `WorkspaceBrowserDialog` is still there, nearly unchanged (also touched by `717c40f1`), and has 7 widget tests in `client/test/widget/workspace_browser_dialog_test.dart`. It shows the current path, a `..` row driven by the daemon's `parent_path`, folders only, per-row rename and delete, a red delete confirmation, a "New Folder" action, a truncation notice, a mutation error line, and "Cancel" / "Use This Folder". Its strings are hard-coded English.
- **Unwired helper.** `WorkspacePickerHelper.openRemoteFolderBrowser` returns `Future<void>` and drops the path the dialog pops (`workspace_browser_dialog.dart:404`).
- **Local/remote decision.** `workspace_picker_helper.dart:32,52`: `AppPlatform.isDesktop && device?.isLocalReachable == true`. `isLocalReachable` is set by `DeviceConnectionCoordinator.decorateAgent` (`device_connection_coordinator.dart:257-268`). The local branch must not change.
- **Agent commands** (`workspace_command_handler.dart`, the coordinator is `agent/lib/interfaces/runtime/workspace_file_system_coordinator.dart`):

| Command | Payload | Reply |
|---|---|---|
| `create_workspace` | `name`, `path?`, `description?` | `workspace_created` |
| `browse_workspace_tree` | `workspace_id?`, `path?` | `workspace_tree` (`root_path`, `path`, `parent_path`, `entries[]`, `truncated`) |
| `workspace.create_folder` | `parent_path`, `name` | `workspace.folder_created` |
| `workspace.rename_folder` | `path`, `new_name` | `workspace.folder_renamed` |
| `workspace.delete_folder` | `path`, then `confirmation_token`, `confirmation_fingerprint` | `workspace.delete_folder.preview`, then `workspace.folder_deleted` |
| `workspace.relocate` | `workspace_id`, `new_path`, token, fingerprint | `workspace.relocate.preview` / `workspace.relocated` |

- **Origin.** `ServerSanadGatewayPlatform._dispatchManagedWorkspace` (`server_sanad_gateway_platform.dart:547-583`) forces `managed_remote: true` for every command in `_remoteWorkspaceManagementCommands` (:38-48), which includes all of the above. A local-socket caller is never forced into managed mode.
- **Path-safety checks today, in managed mode:**
  - **NUL byte:** `_rejectUnsafePathString` (:623) throws an uncoded `FormatException`. It has no managed test.
  - **`..` segments:** these are collapsed by `normalizePath` (realpath), then a containment check runs. Names reject `.`, `..`, `/` and `\` (:404).
  - **Outside the roots:** `_assertAllowedRemotePath` (:545) returns `path_not_allowed`.
  - **Symlinks:** a final-component link is rejected with `followLinks: false`. Middle links are resolved before containment.
  - **Sanad Home internals:** hidden and rejected by `_isSanadInternalHidden` (:601). The `workspaces` subtree is exempt.
  - **Protected roots:** the managed root, Home, state home and registered workspace roots cannot be renamed or deleted (`_isProtectedRemoteRoot`, :579).
  - **Filesystem root:** rejected by `_isFileSystemRoot` (:468).
  - **Mutations:** all go through one serialized queue.

### Gaps against the requirement

1. **Confinement is wider than the managed root.** `_allowedRemoteRoots` (:519) is the managed root **plus every registered workspace path**, including host folders registered locally. Remote browse, folder mutation and relocate can therefore reach outside `<SANAD_HOME>/workspaces`.
2. **No nested pick.** Managed `create_workspace` rejects any `path` and only creates a direct child by name. There is no way to register an existing nested folder.
3. **Ancestors of workspaces are unprotected.** Only exact workspace roots are protected. Renaming or deleting an ancestor of a registered workspace silently breaks that workspace's path.
4. **Symlink listing leak.** Listing uses `followLinks: false`, but `_buildTreeEntry` normalizes the entry path with realpath. A link inside the root is reported as `type: file` with its **resolved target path**, which discloses host paths outside the root.
5. **Relative paths.** `normalizePath` resolves a relative input against the daemon's working directory. Containment rejects it today only by accident of where the daemon runs. It must be refused explicitly.
6. **Uncoded NUL rejection.** It surfaces as a generic error.
7. **Client.** The dialog is unwired, the helper discards the result, the strings are not localized, and a contract and a test assert that remote create never opens the browser.

## Design

### Agent and protocol (no new request types)

- **A1 — Strict managed root.** In managed mode the single allowed root is `ensureManagedWorkspacesRoot()`. Remove the registered-workspace union from `_allowedRemoteRoots` (or replace it with one `_managedRoot()`). This covers browse (path and empty path), the three folder mutations, managed create, and managed relocate `new_path`. Registered workspaces outside the root stay usable for chat and tools by workspace id. They are simply not browsable or mutable from the cloud (see Q1).
- **A2 — Empty-path browse.** In managed mode an empty `path` returns the managed root's own snapshot (`root_path == path == managedRoot`, `parent_path: null`) instead of a one-entry roots list, so the dialog opens directly inside the root. A `workspace_id`-scoped managed browse is allowed only when that workspace resolves inside the managed root; otherwise it returns `path_not_allowed`.
- **A3 — Nested pick through `create_workspace`.** Managed `create_workspace` accepts exactly one of `name` (today's behaviour, kept) or `path`; sending both, or neither, is `invalid_request`. A managed `path` must:
  - be absolute and NUL-free with no raw `..` segment;
  - resolve, after realpath, to an **existing directory strictly inside** the managed root (not the root itself);
  - not be a symlink at any component inside the root (compare the realpath with the lexical normalization);
  - not be in Sanad internals.

  The Agent registers the **resolved** path with the folder basename as the display name. If that path is already registered, the existing record is returned, matching `_storeWorkspace` today; a test confirms it. The Client never assembles a target path: it returns a `path` value that the daemon itself produced in a `workspace_tree` reply, and the daemon revalidates it anyway. The `runtime/AGENTS.md` law "never accept a client-assembled create target path" stays intact for folder creation. For workspace registration it is reworded to "a selected existing directory, revalidated by the daemon".
- **A4 — Protect workspace ancestors.** `workspace.rename_folder` and `workspace.delete_folder` (both preview and confirm) reject a folder that **is or contains** a registered workspace path, with a new code `workspace_in_use` (added to `WorkspaceCommandErrorCodes`). The exact-root protections stay. See Q3 for the alternative.
- **A5 — Listing hygiene.** In managed mode, `_buildTreeEntry` omits `Link` entities entirely and never realpaths an entry. Entry paths are built lexically as `p.join(listedDirectory, basename)`, and the listed directory is already validated.
- **A6 — Coded rejections.** In managed mode, NUL bytes, raw `..` segments and relative paths are rejected before normalization with `WorkspaceCommandException(pathNotAllowed)`. The local-mode behaviour is unchanged.
- **A7 — Revalidate at execution.** Each mutation reruns the full managed check inside the serialized queue, immediately before the filesystem call (create parent, rename source and destination, delete target, register path). The delete fingerprint already binds the confirmed target. The remaining check-then-act window applies only to a local attacker on the Agent machine, which is outside the remote threat model; this is recorded in `remote_device_control_threat_model.md`.
- **A8 — Origin stays Gateway-owned.** `managed_remote` comes only from `_dispatchManagedWorkspace`. A cloud payload that sends `managed_remote: false` is still managed. A regression test pins this.

### Client

- **C1 — Replace the name prompt.** In `WorkspacePickerHelper.promptCreateWorkspace`, the remote branch opens `WorkspaceBrowserDialog` and returns `WorkspaceCreateRequest(path: picked)`. Delete `_promptRemoteWorkspaceName` and its `debugRemoteWorkspaceName` hook, replacing the hook with a browser-pick debug hook. A new workspace by name is still possible: create a folder in the dialog, then pick it.
- **C2 — Return the pick.** `openRemoteFolderBrowser` becomes `Future<String?>` and takes the four device-scoped callbacks (tree, create, rename, delete). "Use This Folder" is disabled when the snapshot is the managed root (`parent_path == null && path == root_path`), which mirrors the Agent's rejection.
- **C3 — Target the right device.** Both callers (`conversation_input_panel.dart` `_pickAndCreateWorkspace` and `sidebar/device_workspace_sidebar.dart` `createWorkspace()`) route every browse and folder call to the **device being configured**, through the `(device, …)` methods on `ConversationCacheRepository`. They must not route through `SessionWorkspaceCoordinator.browseWorkspaceTree`, which follows the active session's device. The presentation layer still never picks the transport (Thin-Client Authority).
- **C4 — Localize.** Move every dialog string to `client/lib/l10n/app_en.arb` and `app_ar.arb` (title, New Folder, Rename, Delete, delete confirmation, Use This Folder, Cancel, truncation notice, the empty-folder state, and the errors for `path_not_allowed`, `workspace_in_use`, `stale_confirmation` and the generic failure). Check RTL layout of the path line and the `..` row.
- **C5 — Local path unchanged.** `isLocalReachable` keeps the native `getDirectoryPath`. Settings "Change Path" stays local-only (see Q4).

### Contracts and docs to update in the same PR

- `agent/lib/interfaces/runtime/AGENTS.md` (Workspace Filesystem Mutation), `agent/lib/interfaces/AGENTS.md` (Runtime Query Boundary), `agent/lib/interfaces/platforms/sanad_gateway/AGENTS.md` (the "allowed-root browse" bullet).
- `client/lib/features/conversations/presentation/AGENTS.md:51-53` (remote "sends no filesystem command"), `client/lib/features/settings/AGENTS.md:9-15` (folder browser "reserved for a future file-tree experience").
- `docs/technical/workspace_folder_mutation_protocol.md`, `docs/technical/remote_device_control_threat_model.md`, `docs/technical/workspace_identity_protocol.md`, `docs/technical/agent_runtime.md`.
- `docs/qa_maintenance/workspace_folder_management_qa.md` (lines 34-35), `remote_device_control_qa.md`, `workspace_identity_relocation_qa.md`, `docs/qa_maintenance/MOC.md`.
- `docs/product/client_interface.md`, `docs/product/features.md`, `docs/llms.txt`.

## Security Requirements (one rejection test each, managed mode)

Each case is tested at the coordinator or service level, and the starred (★) cases are also tested through `workspace_command_handler`, so the reply is an `error` with the right `code` and no filesystem change. Each request type that takes a path (browse, create_folder `parent_path`, rename `path`, delete `path`, create_workspace `path`, relocate `new_path`) is covered by a table-driven test over the inputs below.

| # | Input | Expected |
|---|---|---|
| S1 ★ | Path containing `\u0000` | `path_not_allowed` (coded, not `FormatException`) |
| S2 ★ | Raw `..` segment (`<root>/a/../../x`), even when it would normalize back inside | `path_not_allowed` |
| S3 | Relative path (`a/b`, `.`) | `path_not_allowed` |
| S4 ★ | Absolute path outside the root (`/tmp`, `$HOME`, `/Users`) | `path_not_allowed` |
| S5 | `/` (and a Windows drive root under the Windows path rules) | `path_not_allowed` |
| S6 ★ | A registered workspace that lives outside the managed root (both path and `workspace_id` browse) | `path_not_allowed` |
| S7 | Sanad Home, the state home, and a Home file (`<home>/config.yaml`, `<home>/<db>`) | `path_not_allowed` |
| S8 | A symlink inside the root pointing outside (target is a final component) | `path_not_allowed` |
| S9 | A path through a symlinked middle directory inside the root | `path_not_allowed` |
| S10 | A symlink inside the root pointing to another folder inside the root | `path_not_allowed` for pick and mutation; omitted from listings |
| S11 | Listing a folder containing links | links omitted; no entry path outside the root; no resolved target disclosed |
| S12 ★ | Pick the managed root itself as a workspace | `path_not_allowed` |
| S13 | Rename or delete the managed root | `path_not_allowed` (existing protected-root rule) |
| S14 ★ | Rename or delete a registered workspace root, and an **ancestor** of one | `workspace_in_use` |
| S15 | Folder names `.`, `..`, `a/b`, `a\b`, empty, or a NUL in the name (create and rename) | rejected (existing `validateFolderName`) |
| S16 | `create_workspace` with both `name` and `path`, or neither | `invalid_request` |
| S17 | Pick a file, not a directory; pick a missing path | `path_not_allowed` / not-found error, nothing registered |
| S18 | Delete confirm with a stale fingerprint after the target changed | `stale_confirmation` (existing; kept green) |
| S19 ★ | Cloud command carrying `managed_remote: false` | still handled as managed (S4 input still rejected) |
| S20 | Folder replaced by a symlink between preview and confirm | rejected at execution (A7; extends the existing fail-injection test) |

The positive local-mode regressions stay green: local browse from real host roots, local path create, and local rename/delete.

## Test Plan

- **Agent unit and service** (`agent/test/interfaces/.../local_workspace_runtime_service_test.dart`, coordinator tests): S1–S20, plus positives.
  - Empty-path managed browse returns the root snapshot.
  - Nested browse at depth 3 reports `parent_path` stepping back to the root, then `null`.
  - Create, rename and delete nested folders.
  - Pick a nested folder: registered with the resolved path and basename display name, idempotent on repeat.
  - A session in the picked workspace resolves its cwd to that folder.
- **Agent handler** (`workspace_command_handler_test.dart`): ★ cases, the `create_workspace` path/name exclusivity, and the `workspace_in_use` code reaching the reply.
- **Gateway** (`server_sanad_gateway_platform` tests): S19, and every command in `_remoteWorkspaceManagementCommands` still carries `managed_remote`.
- **Client widget**:
  - `workspace_browser_dialog_test.dart`: localized strings in en and ar, pick disabled at the root, and the `workspace_in_use` and `path_not_allowed` messages.
  - Rewrite `conversation_input_panel_rebuild_test.dart` `'creates a remote workspace by name without a host path'` into "opens the managed browser for a remote device and creates the workspace from the picked nested path".
  - Keep `'uses native folder picker for local agents when adding a workspace'` unchanged.
  - Add a sidebar remote-create test asserting the browse calls target the configured device, not the active session's device.
- **Client unit**: `device_conversation_commands_test.dart` — `create_workspace` sends `path` without `name` for a remote pick.
- **Analyzers**: `fvm dart analyze` (agent), `fvm flutter analyze` (client). Focused suites, then the full agent and client fast suites, since this is a shared surface.
- **No E2E port binding** is needed beyond the existing daemon workspace E2E, if it covers managed create. Otherwise add one daemon-backed case for the pick-and-register path.

## Live Acceptance

Both devices run the candidate build from this branch, each on its own Test Home started through `sanad-dev` (no main-Home changes). The TH1 Client is connected **over the cloud** to the TH2 device **"Sanad Agent Test2 (macOS)"**.

1. On TH1, add a workspace for "Sanad Agent Test2 (macOS)". The in-app browser opens (not the native picker and not the name prompt), showing TH2's `<SANAD_HOME>/workspaces`. `..` is absent at the root, and "Use This Folder" is disabled there.
2. Create `acc-123/parent/child`, rename `child` to `picked`, create and delete a scratch folder (with the delete confirmation). On TH2, verify each change on disk inside the root only.
3. Pick `acc-123/parent/picked`. The workspace appears on TH1 with display name `picked`. Start a session in it and run one bounded tool call that prints the working directory; it is the picked folder on TH2.
4. Negative from TH1 over the cloud, sent through the Client driver or the remote CLI relay, not the UI: browse `/`, `$HOME`, TH2's Home, `<root>/../`, a NUL path, and a symlink planted inside the root pointing to `/tmp`. Each returns `path_not_allowed` and nothing changes. Try renaming `acc-123/parent` (an ancestor of the new workspace): `workspace_in_use`.
5. Local regression: a Client connected **locally** to its own device opens the native macOS picker, unchanged.
6. Arabic UI pass of the dialog (RTL path line, `..` row, buttons).
7. Clean up `acc-123` through the dialog after removing the workspace record.

Record operation ids, screenshots and the on-disk listings in the Round Log.

## Gates

- [ ] G0 — User answers to Q1–Q5, recorded below.
- [ ] G1 — Agent: A1–A8 with S1–S20 red on `adc128ec`, then green; analyzer clean.
- [ ] G2 — Client: C1–C5; widget and unit tests; en/ar strings; analyzer clean.
- [ ] G3 — Contracts and docs listed above updated, with no stale "remote sends no filesystem command" or "reserved for a future file tree" text left.
- [ ] G4 — Independent review.
- [ ] G5 — Live acceptance (TH1 cloud → "Sanad Agent Test2 (macOS)") with evidence.

## Definition of Done

- Remote add-workspace opens the confined in-app browser; the name-only popup is gone; local add-workspace still uses the native picker.
- No managed request can read, list, create, rename, delete, register or relocate anything outside `<SANAD_HOME>/workspaces`, or the root itself where noted, proven by S1–S20.
- Any nested folder under the root can be picked and becomes a working workspace on the remote device.
- Renaming or deleting a folder that contains a registered workspace is refused with `workspace_in_use`.
- Listings never disclose a path outside the root.
- All dialog strings are localized in en and ar.
- Analyzers clean; focused and full fast suites green; owning AGENTS.md and docs updated; live acceptance recorded.

## Open Questions

- **Q1 — Remote access to existing outside-root workspaces.** Strict confinement (A1) means a workspace registered locally at, say, `~/Projects/app` can no longer be browsed, have folders created in it, or be relocated from the cloud. Chat and tools in it keep working. Is that acceptable? (Recommended: yes; it is what "never outside that root" says.)
- **Q2 — Nested and overlapping workspaces.** May the user pick `a/b` when `a` is already a workspace, or pick `a` when `a/b` is one? (Recommended: allow it, as the local native picker does.)
- **Q3 — Renaming a folder that contains a workspace.** Refuse with `workspace_in_use` (recommended; simple and safe), or rename and then rewrite the affected workspace paths? The second matches "same as the old popup" more closely but is a relocate in disguise.
- **Q4 — Remote "Change Path".** Settings "Change Path" stays local-only today. Should the same confined browser also serve remote relocate, limited to targets inside the root? (Recommended: a follow-up task, not this one.)
- **Q5 — Files in the dialog.** The old popup showed folders only. Keep it folders-only (recommended), or also list files read-only?

## Estimate

Medium.

| Part | Approximate size |
|---|---|
| Agent (A1–A8) | 250–350 lines |
| Agent tests | 400–500 lines |
| Client wiring, localization, error mapping | 200–300 lines |
| Client tests | 200–300 lines |
| Docs and contracts | ~10 pages touched |

That is about 1.1k–1.5k changed lines, roughly 2–3 writer rounds plus one review round and one live session.

## Round Log

(empty)
