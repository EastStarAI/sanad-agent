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

## Focused Automated Verification

- `agent/test/capabilities/workspace_path_resolver_test.dart`
- `agent/test/capabilities/runtime_catalog_test.dart`
- `agent/test/capabilities/permission_manager_test.dart`

The permission-card copy is verified with the focused client analyzer and widget surface review; it must remain action-neutral rather than command-specific.
