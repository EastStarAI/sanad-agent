---
title: "Workspace Identity and Change Path QA"
description: "Regression coverage for UUID migration, missing folders, rename, Change Path, cache reconciliation, and scoped Settings routing."
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
