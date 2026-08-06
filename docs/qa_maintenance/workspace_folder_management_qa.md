---
title: "Remote Workspace Folder Management QA"
description: "Regression matrix for the temporary cloud workspace-management shutdown and preserved local picker behavior."
---

# Remote Workspace Folder Management QA

## Current Product Boundary

- Same-device desktop workspace selection continues to use the operating
  system native folder picker.
- Remote users may select existing registered workspaces for conversations.
- Remote workspace creation, relocation, host-path browsing, folder creation,
  folder rename, and folder deletion are temporarily disabled.
- The cloud adapter is the enforcement boundary; hiding the Flutter browser is
  presentation feedback, not the security control.

## Automated Coverage Matrix

| Area | Required behavior |
|---|---|
| Cloud `execute_command` | Each of the six suspended commands returns `remote_workspace_management_disabled`. |
| Cloud `protocol_event` | Each equivalent canonical event returns the same structured error. |
| Correlation | Every rejection preserves the original `request_id` and `session_id`. |
| No side effects | Rejected commands do not register a session channel, invoke workspace runtime methods, or touch the filesystem. |
| Allowed queries | `list_workspaces` remains allowed so remote users can choose an existing workspace. |
| Client warning | A remote picker attempt displays the temporary security message. |
| No remote browser | Conversation, Sidebar, and Settings use the shared helper, which returns no path remotely and never opens `WorkspaceBrowserDialog`. |
| Local picker | A confirmed same-desktop local device still opens the native picker and can create or relocate a workspace using the selected path. |

## Manual Regression Scenarios

### Remote connection

1. Connect to a remote device and open the workspace selector.
2. Verify existing registered workspaces remain selectable.
3. Choose the action to add a workspace and verify the security notice appears.
4. Verify no remote browser opens and no workspace is created.
5. Open Workspace Settings for the remote device and choose Change Path.
6. Verify the same notice appears and the stored path is unchanged.
7. Send each suspended command through a protocol test client and verify a
   correlated `remote_workspace_management_disabled` error is returned without
   a timeout.

### Local same-device connection

1. Open workspace selection for the confirmed local desktop device.
2. Verify the operating system native folder picker opens.
3. Select a directory and verify local workspace creation still completes.
4. From Workspace Settings, choose Change Path and verify the native picker and
   local relocation flow still work.

## Suspended Runtime Coverage

Keep the existing local unit tests for `LocalWorkspaceRuntimeService` and the
shared workspace handlers. They validate path normalization, name validation,
collision handling, symlink and root protection, request correlation, and
recursive deletion. These are local defense-in-depth tests for dormant shared
runtime behavior; they do not indicate that cloud filesystem management is
enabled.

## Release Gate

Do not restore the remote browser or remove the cloud rejection guard until a
new authorization design has been documented, reviewed, and covered by tests
for allowed roots, request origin, destructive confirmation, and filesystem
escape attempts.
