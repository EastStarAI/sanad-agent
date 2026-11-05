# Run-session permission picker

## Goal

A `sanad run` session shows its own permission mode in the Client as soon as it
is created, and a Client message never strips the permissions that session was
started with.

## Owner decisions (2026-11-05, fixed)

1. The Agent emits a complete `session_created` projection for a first turn that
   only targets an execution root: `workspace_id = exec_root:<root>`,
   `workspace_path`, `metadata.execution_root`, and
   `metadata.permission_mode = full_access` when the owner turn carried
   `allow_all_tools`. The session's `workspace_id` column is persisted with the
   same identity so the row and the projection agree.
2. The Client applies only the keys it owns from `session_updated`: the
   `workspace*` fields and the permission keys `metadata.execution_root`,
   `metadata.allow_all_tools`, `metadata.permission_mode`. It never replaces the
   rest of `metadata` wholesale.
3. A turn that omits `execution_root` / `allow_all_tools` inherits the values
   stored on the session, so a Client message into a run session keeps terminal
   and workspace permissions at the same root and prompts for nothing.
4. The picker shows the mode the Agent enforces. A change writes the session's
   own override (`set_session_permission_mode`) as well as the workspace policy,
   so selecting a non-full mode really clears `allow_all_tools` and selecting
   Full access really sets it. The display-only downgrade set is removed.
5. A session whose targeting resolves to no path keeps the picker hidden; it
   never borrows another workspace's mode.
6. `conversation_bottom_actions.dart` shares the composer's single
   `ComposerPermissionGate` instead of re-deriving the condition.
7. The picker tooltip names the session's execution path.

## Verification

- [x] `agent/`: `run_session_permission_projection_test.dart` covers the created
      projection, the durable row, permission inheritance across a Client turn,
      "no approval prompt" execution at the same root, and the session
      permission command (including owner-only widening).
- [x] `client/`: `session_cubit_test` covers owned-key merging on
      `session_updated` and that a partial update keeps them;
      `session_full_access_toggle_test` covers the real session mode and that a
      change names the session; `conversation_input_composer_toggle_test` covers
      the tooltip path and the hidden picker for a path-less session.
- [x] Focused analyzers and both full fast suites pass.
