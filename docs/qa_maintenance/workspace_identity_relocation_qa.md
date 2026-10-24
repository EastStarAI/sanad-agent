---
title: "Workspace Identity and Change Path QA"
description: "Regression coverage for UUID migration, missing folders, rename, Change Path, cache reconciliation, scoped Settings routing, and live remote Change Path tooling notes."
---

# Workspace Identity and Change Path QA

| Scenario | Expected result |
|---|---|
| Open a legacy path-keyed database | One UUID is generated per old path and session/runtime references migrate without data loss. |
| Legacy session path has no workspace row | Migration creates a missing workspace row and keeps the session grouped under it. |
| Rename or move a folder outside Sanad | Workspace and historical sessions remain visible with a missing-folder warning. |
| Start new work in a missing workspace | New Conversation is disabled and daemon execution fails closed until path repair. |
| Hover a workspace row | Settings gear appears; leaving the row hides it. |
| Open gear for a non-active device workspace | Settings selects the exact device/workspace inspection scope without changing the active conversation device. |
| Rename Workspace | Display name changes; UUID and filesystem path remain unchanged. |
| Change Path | Existing directory is accepted; UUID, sessions, and runtime associations remain unchanged. |
| Change Path on a device reached over the cloud | Settings opens the confined in-app browser at the workspace's current folder, a notice states that only folders inside the device's workspaces root can be targeted, one confirmation line names the resolved folder, and only then does `workspace.relocate` reach the device. Cancel sends nothing. |
| Remote Change Path to a folder outside the workspaces root | The device rejects the target with `path_not_allowed`; the toast shows the device-scope message rather than the daemon reason, and the workspace keeps its previous path. |
| Remote Change Path to a folder owned by another workspace, or to a symlink | The daemon's own reason is shown; the workspace keeps its previous path and nothing changes on disk. |
| Change Path while a turn is running in that workspace | The relocate is accepted; the running turn keeps the old folder and the next turn in the same conversation uses the new one. |
| Change Path on a same-desktop local device | The native macOS picker opens, with no in-app browser, exactly as before. |
| A second Client after another Client changed the path | It shows the previous path until its next workspaces refresh; no broadcast exists. |
| Change Path to a folder owned by another workspace | Daemon returns a correlated `error`; the project error toast says the folder is already connected to another workspace, the client retains the previous snapshot, and the transport/daemon remains available for later commands. No `SnackBar` is shown. |
| Remove Workspace while an older workspace-list refresh is in flight | The authoritative removal clears the workspace projection and invalidates the older generation; completing the stale refresh cannot restore the removed workspace. |
| Rename or Change Path while an older workspace-list refresh is in flight | The confirmed workspace snapshot remains visible and the stale list response is ignored. |
| Client cache contains old path ids | First UUID workspace refresh remaps pages, expansion, draft workspace, and New Conversation destination. |
| Browse workspace tree/MCP/skills after migration | Protocol uses UUID while daemon resolves the current path internally. |
| Restart with recoverable work | Work-item workspace UUID remains consistent and recovery does not fall back to an old path identity. |

## Remote Change Path live acceptance (Task 143)

The rows above are the product contract. These notes are for whoever re-runs them against a device reached
over the cloud; they record what the driver can and cannot exercise, not product defects.

### The out-of-root rows are automated-evidence only

No live tool can make the Client send an out-of-root target. The driver exposes `inspect_ui`, `enter_text`,
`scroll`, `tap`, `reveal`, and `auth_url`; the CLI adds `snapshot`, `find`, `auth-url`, `tap`, `enter-text`,
`scroll`, `wait-for`, `screenshot`, and `batch`. None can post a raw `workspace.relocate` payload. The UI
cannot produce one either: managed listings skip links, folder names are validated locally (`.` and `..`,
separators, and NUL are rejected), change mode has no path field, and the root cannot be the target. Do not
substitute a local relay: `relocateWorkspace(managedRemote: false)` takes `_normalizeExistingDirectory`
instead of `requireManagedWorkspaceDirectory`
(`agent/lib/interfaces/runtime/local_workspace_runtime_service.dart:813-814`), so it would move the workspace
rather than refuse the target.

Verify those rows through the suites instead:

- `agent/test/interfaces/runtime/managed_workspace_confinement_test.dart:277` — NUL, `..`, relative,
  outside-absolute (including `$HOME`), the filesystem root, a registered workspace outside the root, and
  every link component, at each preview/relocate/browse/create request.
- `agent/test/interfaces/platforms/sanad_gateway/handlers/workspace_command_handler_test.dart:592` — the same
  refusals as the coded `path_not_allowed` envelope on the cloud handler, including the managed root itself.
- `client/test/widget/settings/workspace_change_path_test.dart:358` — the remote-route copy on
  `path_not_allowed`, and the daemon reason on any other code.

Live, do prove what the driver can reach: the CTA is disabled at the root and enables only inside a child
folder, `workspace_browser_current_path` never leaves the root, and a cross-workspace target over the cloud is
refused with the daemon reason while the stored path and the disk stay unchanged.

### Obstacles worth keeping

1. **The sidebar can sit off-screen after returning from Settings.** In the driver environment its bounds went
to `x=-445` twice: the device switcher stays in the tree, so `tap --key sidebar_device_switcher_btn` reports
success and nothing changes, and the previously selected device stays selected. Read a `sanad-dev snapshot`
after any Settings detour and recover with `sanad-dev restart client` — a hot restart that keeps the client
pid and VM port.
2. **`enter-text` on `workspace_folder_name_input` reports "no observable effect"** although the folder is
created with the intended name, because the field's value is not re-readable through the inspector. Use
`--no-verify` deliberately; treat the created folder as the proof, not the warning.
3. **Navigation keys are localized in Arabic.** `nav_tile_general` becomes a label-derived key once Arabic is
selected, so restore the locale by reading the key from a snapshot rather than assuming the English one.
