---
title: "Remote Workspace Folder Management QA"
description: "Regression matrix for managed-remote workspace create/browse and preserved local native picker behavior."
---

# Remote Workspace Folder Management QA

Remote cloud restoration is owned by
[Remote Device Control QA](remote_device_control_qa.md) G3. This page keeps the
local picker matrix and the client projection checks.

## Current Product Boundary

- Same-device desktop workspace selection continues to use the operating
  system native folder picker.
- Remote users may select existing registered workspaces for conversations.
- Remote workspace creation is name-based under `SANAD_HOME/workspaces`.
- Remote browse and folder mutations stay inside managed/registered roots and
  require daemon preview tokens for recursive delete and relocate.
- Workspace Overview does not expose the retained remote folder browser.
- Remove workspace deletes the database record only; folders, files, sessions,
  and messages remain untouched.
- Change Path remains same-desktop local only.

## Automated Coverage Matrix

| Area | Required behavior |
|---|---|
| Cloud managed create | `create_workspace` with a name dispatches as `managed_remote` without session registration. A client path is rejected. |
| Cloud browse | Empty `browse_workspace_tree` lists allowed roots only, not `/` or Home. |
| Cloud folder ops | create/rename/delete stay inside allowed roots; delete/relocate need a preview token. |
| Wrong device | Mismatched `device_id` returns `wrong_device` with no mutation. |
| Allowed queries | `list_workspaces` remains allowed so remote users can choose an existing workspace. |
| Remote create UX | Conversation and Sidebar use a name dialog, not the native picker. |
| Remote browser | Workspace Settings has no Browse folders action; the constrained dialog and daemon commands remain covered for future File Tree use. |
| Record removal | `workspace.remove` returns the correlated workspace id, removes the list/cache projection, and preserves the directory plus session rows. |
| Local picker | A confirmed same-desktop local device still opens the native picker and can create or relocate a workspace using the selected path. |
| Client projection | A workspace created from the sidebar/cache appears in the composer selector on its first opening without a close/reopen cycle. |

## Manual Regression Scenarios

### Remote connection

1. Connect to a remote device and open the workspace selector.
2. Verify existing registered workspaces remain selectable.
3. Choose Add New Workspace, enter a name, and verify a managed workspace is created without typing a path.
4. Open Workspace Settings and verify Browse folders is absent.
5. Choose Remove workspace, verify the confirmation explains record-only
   removal, then confirm that the folder/files and conversation records remain.
6. Change Path remains unavailable as a native host picker on the remote device.

### Local connection

1. On a confirmed same-desktop local device, add a workspace.
2. Verify the native folder picker opens.
3. Select a folder and verify the workspace is created and selectable.
