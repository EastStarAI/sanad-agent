---
title: "Remote Workspace Folder Mutation Protocol"
description: "Managed-root remote workspace create, constrained browse, and confirmation-gated folder mutations."
---

# Remote Workspace Folder Mutation Protocol

Owning task: `docs/plans/tasks/82-secure-remote-device-control-workspaces-and-mcp.md`.
Threat model: [Remote Device Control Threat Model](remote_device_control_threat_model.md).

G3 replaces the cloud freeze. Local same-device native picker and path-based
create remain available. Cloud-admitted workspace commands run as
**managed remote**: the Agent injects `managed_remote=true` and does not
register a conversation session.

## Managed root

The identity Sanad Home prepare step creates `SANAD_HOME/workspaces` through
`SanadHomeBootstrap`. That directory must not be a symlink. Remote
`create_workspace` accepts a **name** and optional **description** only. A
client-supplied absolute path is rejected; the Agent creates
`SANAD_HOME/workspaces/<name>`.

## Browse

Empty-path `browse_workspace_tree` on a managed-remote call lists:

- the managed workspaces root
- registered workspace roots that are not already inside that managed root

A non-empty `workspace_id` is resolved strictly as a stored UUID. Host paths
are never accepted as workspace identifiers and cannot implicitly register a
new allowed root.

It does not list `/`, the user Home, or `SANAD_HOME` internals (credentials,
provider/MCP secrets, databases). Breadcrumb `parent_path` is null at an
allowed root so the client cannot climb above it. Paths with NUL bytes,
traversal, or symlink targets fail closed as `path_not_allowed`.

## Folder mutations

`workspace.create_folder`, `workspace.rename_folder`, and
`workspace.delete_folder` operate only inside an allowed root after
canonicalization. They reject filesystem roots, the managed root itself,
registered workspace roots, symbolic links, traversal names, and occupied
rename targets.

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

Remote create uses a name dialog, not the operating-system picker. The
constrained `WorkspaceBrowserDialog` and daemon tree/mutation APIs remain
implemented for a future conversation-side file tree, but Workspace Overview
does not expose a Browse folders action. Change Path remains same-desktop local
only; arbitrary host-directory selection stays out of scope.

## Local continuity

Local handlers still accept a host path for create/relocate and may browse
host roots. Those behaviors are not used for cloud-admitted calls.
