---
title: "Workspace Identity, Rename, and Change Path Protocol"
description: "Stable workspace UUID, availability projection, rename, path repair, and client routing contract."
---

# Workspace Identity, Rename, and Change Path Protocol

## Identity Model

`workspace_id` is an immutable daemon-generated UUID. `display_name` is user-editable and `path` is the current normalized filesystem location. Neither property may replace the UUID in sessions, work items, protocol commands, routes, drafts, or client cache keys.

A workspace whose path is unavailable remains in `list_workspaces` with its UUID, display name, last known path, `is_missing: true`, and `availability: missing`. Historical sessions remain queryable. New execution against that workspace fails with an actionable reconnect message until Change Path succeeds.

## Path Resolution

Resolving a workspace id or path is always a read. One rule serves every daemon-side lookup — workspace policy queries, catalog and runtime-context targeting, session metadata, resume, and CLI lookups:

1. an explicit id resolves to its registered workspace;
2. a path resolves to the registered workspace whose root equals it or contains it, innermost first;
3. any other existing directory resolves to that path's synthetic `exec_root:<normalized_path>` identity;
4. an unknown id, a non-directory, or a missing path resolves to nothing.

A path never registers a workspace. Only an explicit `workspace.create` (a picked folder, a new folder, or a managed remote create), Change Path, or the legacy migration writes a `workspaces` row. A session created with only an execution root therefore stays a session with no registered workspace: opening it, reading its policy, or running a turn in it cannot make an empty workspace appear in the workspace list.

Rows registered implicitly by an older build remain ordinary registered workspaces after upgrade; the metadata-only `workspace.remove` deletes such a row without touching its folder, its files, or its sessions.

## Commands

### `workspace.rename`

Request payload: `request_id`, `workspace_id`, and non-empty `display_name`.

Success event: `workspace.renamed`, carrying the correlated request id and complete authoritative `workspace` object. The filesystem path is unchanged.

### `workspace.relocate`

Request payload: `request_id`, `workspace_id`, and `new_path`.

Success event: `workspace.relocated`, carrying the correlated request id and complete authoritative `workspace` object. The daemon requires an existing directory, normalizes it, and rejects a path already owned by another workspace. Validation failures return a correlated `error` event, leave the prior workspace snapshot unchanged, and do not terminate the transport or daemon. Sessions and work items are not rewritten because their UUID remains stable.

## Client UX

A workspace row shows a missing-folder warning when unavailable and disables New Conversation for that workspace. A settings gear appears only while hovering the row. It opens `/settings?section=workspace&device_id=...&workspace_id=...`; Settings selects the exact inspection device and workspace without changing the active conversation device.

The Workspace Settings overview owns `Rename Workspace` and `Change Path`. Change Path is offered only for local reachable desktop devices, through the native directory picker; a remote add-workspace uses the confined daemon-owned browser (Task 123). Mutation results update the conversation cache only after the correlated authoritative response. Each successful create, rename, relocate, or remove mutation invalidates older in-flight workspace-list generations for that device so a stale refresh cannot overwrite the confirmed result. A rejected mutation preserves the daemon-provided reason through the command and cache layers and displays it with the project's error toast; Settings does not replace it with a generic message or use a `SnackBar`.

## Legacy Cache Reconciliation

When a client cache still uses path ids and the daemon returns UUID workspaces, the cache matches the same stored path and remaps workspace pages, expansion state, New Conversation draft scope, and New Conversation destination to the UUID before removing stale keys.

## Execution Root Synthetic Workspaces and Permission Isolation

When a CLI execution runs with a temporary directory context via `--execution-root`, the runtime synthesizes an ephemeral workspace identifier with the prefix `exec_root:<normalized_path>`. The following isolation and security rules apply:

1. **Path Validation and Policy Writes:** Updating permission mode via `workspace.set_permission_mode` for an `exec_root:` target strictly validates and normalizes the target path using `WorkspacePathResolver.validateAndNormalizeExecutionRoot`. Non-existent paths, invalid entities, and traversal attempts are rejected immediately, preventing arbitrary policy files from being written to disk. Reading policy resolves the same normalized path read-only and never registers the folder as a workspace (see [Path Resolution](#path-resolution)).
2. **Explicit Workspace Precedence:** Turn requests specifying an explicit named `workspace_id` take absolute precedence over stale `execution_root` attributes stored in session metadata. A prior CLI execution root in session history never shadows an explicitly selected workspace.
3. **Turn-Scoped `allow_all_tools` Provenance:** Automatic tool approval flags (`allow_all_tools: true`) are evaluated on a per-turn basis from the originating request and are honoured only when transport ingress stamped the turn as owner authority (any authenticated client transport); an unverified transport loses the flag. Only the CLI sends it (`sanad run --yes`, locally or through the remote CLI relay); no Sanad Client, local or cloud, has an `allow_all_tools` control. Session metadata `permission_mode` never grants approval. They are not persisted into session metadata to silently escalate permissions on subsequent turns.
4. **Authoritative Workspace Deny Rules:** Explicit `deny` entries in the Agent-owned workspace policy remain authoritative and take precedence over `allow_all_tools` and workspace `full_access`. Policy is keyed by the workspace UUID (or `exec_root:` key) and bound to its current root; see [Execution Trust and Permission Authority](execution_trust_and_permission_authority.md).
5. **Safe Default Trust State:** Ephemeral execution root workspaces and unconfigured workspace trust states default safely to `untrusted` rather than granting blanket trust.
6. **Client Localization:** Permission mode selectors and tooltips in the Client UI are localized using `AppLocalizations` (`workspacePermissionModeDefault`, `workspacePermissionModeFullAccess`, `workspacePermissionModeTooltip`, `workspacePermissionModeTooltipWithRoot`), preventing hardcoded English literals in presentation widgets.
7. **Multi-turn Producer-to-Payload Propagation & Downgrade:** When a session previously executed with `allow_all_tools: true`, subsequent turns with an omitted flag or explicit `false` revoke the grant immediately and reset derived `permission_mode` from `full_access` back to `default_mode`. Stale execution roots from previous turns do not leak into the payload when an explicit workspace is selected.
8. **Client Workspace Cache Authority Isolation & In-Place Session Revocation:** In `SessionMessagesCubit`, per-turn `allow_all_tools` grants inspect the active session metadata directly rather than polluting the workspace-level `_permissionModesByWorkspaceId` cache, preventing other sessions sharing the workspace from inheriting unauthorized `fullAccess`. In-place session metadata updates (grant revocation or expiration) on the active session re-evaluate permission modes and workspace mappings immediately and emit updated state.
