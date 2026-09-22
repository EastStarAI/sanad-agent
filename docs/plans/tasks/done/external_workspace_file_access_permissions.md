# External Workspace File Access Permissions

## Goal
Allow workspace file and search tools to operate on canonical paths outside the selected workspace when the workspace is in `full_access` mode, while requiring durable user approval in `default` mode.

## Scope
- Apply to `file_read`, `file_write`, `file_edit`, `search_glob`, and `search_grep`.
- Keep `shell_execute` outside this task.
- Preserve direct execution for paths inside the workspace.
- Treat absolute paths, relative `..` escapes, and symbolic-link targets consistently after canonicalization.

## Implementation
1. Extend workspace path resolution to classify canonical paths and permit an explicitly authorized external path without weakening the default boundary.
2. Add a shared external-path authorization gate that delegates policy and durable suspension to `PermissionManager` before any host access.
3. Key remembered decisions by tool and canonical target path while keeping original tool arguments available for safe resume and exposing only sanitized path/action details in the approval request.
4. Return absolute paths for external results and workspace-relative paths for internal results.
5. Generalize the client permission-card wording from commands to tool actions.
6. Document the runtime and user-facing behavior and add focused regression coverage.

## Definition of Done
- Internal paths execute without a new permission request.
- External paths execute without prompting in `full_access` mode.
- External paths in `default` mode execute only after once, session, or workspace approval and never after denial.
- Canonicalization prevents `..` and symbolic links from bypassing classification.
- Approval payloads expose the canonical target and operation but not write/edit content.
- Agent and client analyzers plus focused tests pass.
- The capability runtime, client interface, and QA documentation describe the behavior.
