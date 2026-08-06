---
title: "Remote Workspace Folder Mutation Protocol"
description: "Current cloud rejection boundary and suspended design for remote workspace filesystem management."
---

# Remote Workspace Folder Mutation Protocol

## Current Security Boundary

Remote workspace selection and filesystem management are temporarily disabled
on the cloud Sanad Gateway. The cloud adapter rejects these six commands before
registering a session channel or forwarding work to the shared protocol bridge:

- `create_workspace`
- `workspace.relocate`
- `browse_workspace_tree`
- `workspace.create_folder`
- `workspace.rename_folder`
- `workspace.delete_folder`

Both `execute_command` and `protocol_event` envelopes receive an `error` event
with the original `request_id`, the code
`remote_workspace_management_disabled`, and a user-presentable message. A
rejected request must not reach `LocalWorkspaceRuntimeService` or mutate the
host filesystem.

The boundary belongs to the cloud adapter because the same canonical protocol
and runtime handlers serve trusted same-device flows. The shared
`SanadProtocolBridge`, workspace handlers, local runtime service, and operating
system native picker remain unchanged.

## Client Behavior

The conversation composer, device workspace sidebar, and Workspace Settings
share one picker decision helper:

- A confirmed same-desktop local device opens the operating system native
  folder picker.
- Every other connection shows an English security notice and returns no path.
- The remote browser dialog is not opened and no remote workspace mutation is
  sent.

Existing registered workspaces remain available for remote conversation use.
Only creating a workspace, changing its path, browsing host paths, and mutating
folders through the remote picker are suspended.

## Suspended Historical Design

The codebase still contains transport-neutral workspace handlers and runtime
validation that previously supported a daemon-backed remote browser. That
design allowed the client to browse host roots and request folder creation,
rename, or recursive deletion before selecting a workspace. It is retained for
local runtime compatibility and future security redesign, but it is not an
active cloud product capability.

If this design is restored, it requires a separately reviewed authorization
model that constrains visible roots and filesystem mutations. Removing only the
client warning or only the cloud adapter guard is not sufficient to restore the
feature safely.

## Historical Runtime Validation

The suspended handlers reject invalid names, symbolic links, filesystem roots,
missing paths, and conflicting rename targets. Those checks remain useful as
defense in depth and are covered by local runtime tests, but they do not replace
the current cloud admission boundary.
