---
title: "Workspace Identity, Rename, and Change Path Protocol"
description: "Stable workspace UUID, availability projection, rename, path repair, and client routing contract."
---

# Workspace Identity, Rename, and Change Path Protocol

## Identity Model

`workspace_id` is an immutable daemon-generated UUID. `display_name` is user-editable and `path` is the current normalized filesystem location. Neither property may replace the UUID in sessions, work items, protocol commands, routes, drafts, or client cache keys.

A workspace whose path is unavailable remains in `list_workspaces` with its UUID, display name, last known path, `is_missing: true`, and `availability: missing`. Historical sessions remain queryable. New execution against that workspace fails with an actionable reconnect message until Change Path succeeds.

## Commands

### `workspace.rename`

Request payload: `request_id`, `workspace_id`, and non-empty `display_name`.

Success event: `workspace.renamed`, carrying the correlated request id and complete authoritative `workspace` object. The filesystem path is unchanged.

### `workspace.relocate`

Request payload: `request_id`, `workspace_id`, and `new_path`.

Success event: `workspace.relocated`, carrying the correlated request id and complete authoritative `workspace` object. The daemon requires an existing directory, normalizes it, and rejects a path already owned by another workspace. Validation failures return a correlated `error` event, leave the prior workspace snapshot unchanged, and do not terminate the transport or daemon. Sessions and work items are not rewritten because their UUID remains stable.

## Client UX

A workspace row shows a missing-folder warning when unavailable and disables New Conversation for that workspace. A settings gear appears only while hovering the row. It opens `/settings?section=workspace&device_id=...&workspace_id=...`; Settings selects the exact inspection device and workspace without changing the active conversation device.

The Workspace Settings overview owns `Rename Workspace` and `Change Path`. Local reachable desktop devices use the native directory picker; remote devices use daemon-owned browsing. Mutation results update the conversation cache only after the correlated authoritative response. Each successful create, rename, relocate, or remove mutation invalidates older in-flight workspace-list generations for that device so a stale refresh cannot overwrite the confirmed result. A rejected mutation preserves the daemon-provided reason through the command and cache layers and displays it with the project's error toast; Settings does not replace it with a generic message or use a `SnackBar`.

## Legacy Cache Reconciliation

When a client cache still uses path ids and the daemon returns UUID workspaces, the cache matches the same stored path and remaps workspace pages, expansion state, New Conversation draft scope, and New Conversation destination to the UUID before removing stale keys.
