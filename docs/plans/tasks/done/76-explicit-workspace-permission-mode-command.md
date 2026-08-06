# Task 76 — Explicit Workspace Permission Mode Command

## Goal

Make `workspace.set_permission_mode` the only Sanad protocol command that can
change a Workspace permission policy. Turn commands must not mutate the policy
implicitly.

## Scope

- Remove `permission_mode` ingestion from `think` and `steer`.
- Resolve the target path for `workspace.set_permission_mode` from the
  daemon-registered `workspace_id`.
- Ignore any legacy `workspace_path` supplied by a client.
- Keep both `default` and `full_access` available through the explicit command.
- Preserve the existing local/client request shape during migration.

## Verification

- [x] `think` and `steer` discard `permission_mode`.
- [x] The explicit command changes a registered Workspace to `full_access`.
- [x] The explicit command changes it back to `default`.
- [x] A forged `workspace_path` cannot redirect the policy write.
- [x] An unknown `workspace_id` fails without writing a policy.
- [x] Focused tests, formatting, and Dart analysis pass.
