---
title: "Remote Workspace Folder Management QA"
description: "Regression matrix for the confined remote workspace picker, managed-root confinement, and preserved local native picker behavior."
---

# Remote Workspace Folder Management QA

Remote cloud restoration is owned by
[Remote Device Control QA](remote_device_control_qa.md) G3. This page keeps the
local picker matrix and the client projection checks.

## Current Product Boundary

- Same-device desktop workspace selection continues to use the operating
  system native folder picker.
- Remote users may select existing registered workspaces for conversations.
- Remote Add New Workspace opens the in-app folder browser (folders only),
  confined to the device Home's `<SANAD_HOME>/workspaces` root (Task 123). The
  user can browse, create, rename and delete folders there and pick any
  nested folder; "Use This Folder" is disabled at the root.
- Every browse and folder command targets the device being configured, not
  the active session's device.
- Renaming or deleting a folder that is or contains a workspace is refused
  with `workspace_in_use`.
- Workspaces registered outside the root keep working for chat and tools but
  cannot be browsed or changed from the cloud.
- Remove workspace deletes the database record only; folders, files, sessions,
  and messages remain untouched.
- Change Path follows Remove workspace: any online device may change a
  workspace's folder, and a device reached over the cloud targets only folders
  inside its own Sanad workspaces root.

## Automated Coverage Matrix

| Area | Required behavior | Owner |
|---|---|---|
| Root follows the Home | The managed root is `<SANAD_HOME>/workspaces` of the runtime Home, including a custom Test Home | `agent/test/interfaces/runtime/managed_workspace_confinement_test.dart` |
| Security table S1-S20 | Each rejection case has its own test over every path-taking request | same file |
| Handler replies | Starred cases reply `error` with the right `code` and no filesystem change; `name`/`path` exclusivity | `agent/test/interfaces/platforms/sanad_gateway/handlers/workspace_command_handler_test.dart` |
| Cloud managed admission | Every remote workspace command is forced managed, even with `managed_remote: false` | `agent/test/interfaces/server_sanad_gateway_platform_security_test.dart` |
| Daemon pick | Root browse, folder create and nested pick through a real daemon, kept across restart | `agent/e2e_test/remote_device_control_e2e_test.dart` |
| Wrong device | Mismatched `device_id` returns `wrong_device` with no mutation | security test |
| Allowed queries | `list_workspaces` remains allowed so remote users can choose an existing workspace | security test |
| Remote create UX | Conversation composer opens the browser, not the native picker or a name prompt, and creates from the picked path | `client/test/widget/conversation_input_panel_rebuild_test.dart` |
| Device targeting | Sidebar browse, folder create and workspace create go to the sidebar device, not the active session device | `client/test/widget/device_workspace_sidebar_structure_test.dart` |
| Dialog | Pick disabled at the root; localized en/ar strings; LTR path line in RTL; coded error messages | `client/test/widget/workspace_browser_dialog_test.dart` |
| Transport | Path-only `create_workspace`; coded failures for browse and folder errors | `client/test/unit/services/device_conversation_commands_test.dart` |
| Record removal | `workspace.remove` returns the correlated workspace id, removes the list/cache projection, and preserves the directory plus session rows | existing |
| Local picker | A confirmed same-desktop local device still opens the native picker and can create or relocate a workspace using the selected path | `conversation_input_panel_rebuild_test.dart` (unchanged test) |
| Client projection | A workspace created from the sidebar/cache appears in the composer selector on its first opening without a close/reopen cycle | existing |

## Manual Regression Scenarios

### Remote connection (two devices over the cloud)

1. Connect a Client over the cloud to a second device and add a workspace for
   it. The in-app browser opens at that device's `<SANAD_HOME>/workspaces`,
   with no `..` row, and "Use This Folder" is disabled.
2. Create nested folders, rename one, and create then delete a scratch folder
   through the red confirmation. Verify each change on the device, inside the
   root only.
3. Pick a nested folder. The workspace appears with the folder name; a session
   in it runs tools with that folder as the working directory.
4. Try renaming an ancestor of the new workspace: the dialog shows the
   localized `workspace_in_use` message.
5. Choose Remove workspace, verify the confirmation explains record-only
   removal, then confirm that the folder/files and conversation records remain.
6. Change Path opens the confined browser for the remote device: the notice
   states the in-root scope, the browser starts at the workspace's current
   folder, one confirmation names the picked folder, and the workspace follows
   it; cancel sends nothing.
7. Switch the interface to Arabic: the dialog mirrors, while the path line
   stays left to right.

### Local connection

1. On a confirmed same-desktop local device, add a workspace.
2. Verify the native folder picker opens, not the in-app browser.
3. Select a folder and verify the workspace is created and selectable.
