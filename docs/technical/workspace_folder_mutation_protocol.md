---
title: "Remote Workspace Folder Mutation Protocol"
description: "Remote workspace picking, browse, and confirmation-gated folder mutations confined to the Home workspaces root."
---

# Remote Workspace Folder Mutation Protocol

Owning tasks: `docs/plans/tasks/82-secure-remote-device-control-workspaces-and-mcp.md`
(managed-remote admission) and `docs/plans/tasks/done/123-remote-workspace-picker.md`
(strict root confinement and the in-app remote picker).
Threat model: [Remote Device Control Threat Model](remote_device_control_threat_model.md).

G3 replaces the cloud freeze. Local same-device native picker and path-based
create remain available. Cloud-admitted workspace commands run as
**managed remote**: the Agent injects `managed_remote=true` and does not
register a conversation session.

## Managed root

The identity Sanad Home prepare step creates `<SANAD_HOME>/workspaces` through
`SanadHomeBootstrap`. That directory must not be a symlink. The Agent derives
the root from the runtime Home on every call; it never assumes a fixed Home
directory name, so a Test Home moves the root with it.

Every managed-remote path is resolved by one coordinator check
(`WorkspaceFileSystemCoordinator.resolveManagedDirectory`). A path is accepted
only when it:

- is absolute, has no NUL byte, and has no raw `..` segment (even one that
  would normalize back inside);
- is the root, or lies inside it, after lexical normalization;
- names an existing directory, with no symbolic link at any component below
  the root.

Anything else is `path_not_allowed`; a missing folder is a not-found error.
Registered workspaces outside the root keep working for chat and tools by
workspace id, but they cannot be browsed, mutated, or relocated to from the
cloud.

## Create

Managed `create_workspace` takes exactly one of:

- **`name`**: creates (or reuses) the direct child `<root>/<name>`;
- **`path`**: registers an existing folder strictly inside the root (never the
  root itself), as returned by a managed `workspace_tree` reply. The daemon
  revalidates it and stores the resolved path with the folder basename as the
  display name. Repeating the pick returns the existing record.

Sending both, or neither, is `invalid_request`. Nested and overlapping
workspaces are allowed, the same as the local picker.

## Browse

Empty-path `browse_workspace_tree` on a managed-remote call returns the root's
own snapshot (`root_path == path == <root>`, `parent_path: null`), so the
client opens directly inside the root. A non-empty path must pass the resolver
above. `parent_path` steps back one folder and is null at the root, so the
client cannot climb above it.

A non-empty `workspace_id` is resolved strictly as a stored UUID and is
allowed only when that workspace resolves inside the root. Host paths are
never accepted as workspace identifiers.

Listings omit symbolic links entirely and build each entry path lexically
from the validated listed folder, so no link target or outside path is
disclosed. Files are still reported; the Client dialog shows folders only.

## Folder mutations

`workspace.create_folder`, `workspace.rename_folder`, and
`workspace.delete_folder` operate only inside the root, through the same
resolver. Rename and delete reject the root itself (`path_not_allowed`) and
any folder that is, or contains, a registered workspace (`workspace_in_use`);
paths of workspaces are never rewritten behind their records. Folder names
must be one segment (`.`, `..`, `/`, `\`, empty, and NUL are rejected), and an
occupied rename target is refused. The `workspace_in_use` rule applies to
local folder mutations as well.

Every mutation, including managed create, runs on the single serialized
mutation queue and revalidates its paths immediately before the filesystem
call. The remaining check-then-act window applies only to a local process on
the Agent machine, which is outside the remote threat model.

Recursive delete and `workspace.relocate` require a daemon preview:

| Command | Preview event | Confirm |
|---|---|---|
| `workspace.delete_folder` | `workspace.delete_folder.preview` | same command with `confirmation_token` and `confirmation_fingerprint` |
| `workspace.relocate` | `workspace.relocate.preview` | same command with those ticket fields |

The ticket is one-time, short-lived, and bound to device, operation, and
fingerprint. Stale, consumed, or cross-device tokens return
`stale_confirmation` without mutation. Lost-success recovery re-reads the
tree; it does not replay the same destructive `request_id`.

## Workspace record removal

`workspace.remove` deletes only the registered workspace row and returns
`workspace.removed` with the same `request_id` and `workspace_id`. The command
does not call filesystem deletion and does not delete or rewrite sessions or
messages that retain the historical workspace UUID. Cloud calls use the same
wrong-device and duplicate-request admission boundary as other managed
workspace commands. The Client requires an explicit confirmation explaining
the record-only behavior before sending it.

## Client

A remote add-workspace (Conversation composer and Sidebar) opens the in-app
`WorkspaceBrowserDialog`, not the operating-system picker and not a name
prompt. Every browse and folder call goes to the device being configured
(`WorkspaceBrowserCallbacks.forDevice`), never to the active session's device.
"Use This Folder" is disabled at the root; the picked folder is sent as
`create_workspace` `path`. Rejections render localized text keyed by the error
code (`path_not_allowed`, `workspace_in_use`, `stale_confirmation`, generic).
Change Path remains same-desktop local only; a remote Change Path through the
same browser is a separate follow-up.

## Local continuity

Local handlers still accept a host path for create/relocate and may browse
host roots. Those behaviors are not used for cloud-admitted calls.
