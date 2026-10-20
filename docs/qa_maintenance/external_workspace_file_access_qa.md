---
title: "External Workspace File Access QA"
description: "Regression matrix for permission-aware file and search access outside the selected workspace."
---

# External Workspace File Access QA

## Coverage Matrix

| Scenario | Expected result |
|---|---|
| Any supported tool targets a canonical path inside the workspace | Executes without a new external-path permission request. |
| `file_read`, `file_write`, `file_edit`, `search_glob`, or `search_grep` targets an external path in `default` mode | The turn suspends and emits a permission request before host content access or mutation. |
| User approves once | The exact pending tool call resumes once with its original arguments. |
| User approves for the session | Later calls for the same tool and canonical target execute in that session without another prompt. |
| User approves for the workspace | The tool plus canonical-target grant persists in workspace policy. |
| User denies | No read/search/mutation occurs and the tool reports the denial. |
| Workspace mode is `full_access` | External access executes without a permission request. |
| Input escapes through `..` or an absolute path | Classification uses the same canonical external-path policy. |
| A workspace symlink targets an external path | The resolved target is treated as external; the workspace spelling cannot bypass approval. |
| A missing external write target has a symlinked ancestor | Authorization binds to the canonicalized destination before parent creation or write. |
| An authorized external directory is searched | Results use absolute paths and remain confined to that authorized canonical root. |
| A write/edit request is displayed for approval | The UI receives action and canonical path only; original content remains only in the durable resume checkpoint. |
| One parallel tool batch targets multiple external paths | Permission prompts are presented FIFO with at most one unresolved request for the session; resolving or denying one exposes the next and the turn does not retain hidden waiters. |
| Different sessions request external-path permission concurrently | Each session progresses independently; one session's pending prompt does not block another session. |
| `workspace.set_permission_mode` targets an `exec_root:` path | Validates and normalizes target directory on disk; non-existent path or traversal rejects without writing policy. |
| Turn-level `allow_all_tools: true` with explicit workspace policy `deny` | Explicit workspace policy deny entries take precedence and reject; `allow_all_tools` cannot bypass explicit deny rules. |
| Turn-level `allow_all_tools` isolation | `allow_all_tools: true` on an authorized CLI one-shot turn does not persist across subsequent turns; subsequent turns default to requiring normal permission checks. |
| Explicit `workspace_id` precedence over stale session `execution_root` | If a request provides an explicit workspace ID, tools bind to that workspace rather than an older execution root stored in session metadata. |
| Multi-turn turn-metadata producer-to-payload propagation | Prior turn with `allow_all_tools: true` followed by omitted flag or explicit `false` revokes grant, resets derived `permission_mode` to `default_mode`, and enforces explicit workspace precedence over stale Turn 1 `execution_root`. |
| SessionMessagesCubit public state flow downgrade | Explicit downgrade via `setWorkspacePermissionMode(defaultMode)` updates state and repository; grant revocation/expiry updates in active session re-emit state immediately. |
| SessionMessagesCubit cross-session workspace authority isolation | Switching from a session with `allow_all_tools: true` to a normal session sharing the same workspace does not leak `fullAccess` authority into workspace cache. |
| SessionMessagesCubit device-less local session isolation | Sessions with `deviceId == null` bind execution root workspaces only when the active agent is a local inventory device; switching to remote agent clears workspace binding. |

## Focused Automated Verification

- `agent/test/capabilities/workspace_path_resolver_test.dart`
- `agent/test/capabilities/runtime_catalog_test.dart`
- `agent/test/capabilities/permission_manager_test.dart`
- `agent/test/interfaces/platforms/sanad_gateway/handlers/workspace_command_handler_test.dart`
- `agent/test/interfaces/execution_root_runtime_test.dart`
- `agent/test/cli/run_delegation_test.dart`
- `client/test/unit/bloc/session_messages_cubit_permission_scope_test.dart`
- `agent/e2e_test/local_tool_permissions_e2e_test.dart` (authenticated local-daemon sequencing for a parallel external-read batch)

The permission-card copy is verified with focused client tests: known file actions use action-specific prompts and labeled canonical paths, unknown actions retain a generic fallback, and write/edit content remains absent from the display payload.
