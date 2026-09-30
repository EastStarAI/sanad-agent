---
title: "Remote Device Control Protocol"
description: "Typed commands, admission errors, and correlation rules for remote Agent update, restart, workspaces, and MCP."
---

# Remote Device Control Protocol

Owning task: `docs/plans/tasks/82-secure-remote-device-control-workspaces-and-mcp.md`.
Threat model: `docs/technical/remote_device_control_threat_model.md`.

G1 introduces the shared contract. G2 wires update check/apply and supervised
restart. Every Online device supports these commands. The Agent does not
advertise and the Client does not read `supports_remote_update`,
`supports_remote_restart`, `supports_remote_workspace_management`, or
`supports_remote_mcp_management`.

## Transport

Every command uses `DeviceCommandClient` with an explicit `device_id` and a
fresh random `request_id`. `DeviceConnectionCoordinator` selects local or cloud
transport and resolves the protocol target identity: hardware id locally,
account device id in cloud. Settings, Workspace, and MCP pages must not choose
a socket or send the synthetic inventory id as protocol authority.

Cloud relay remains hosted-owned: the Gateway binds the authenticated User to
the live daemon connection before `execute_command`. The Agent cloud adapter
rejects a non-empty envelope `device_id` that does not match its registered id.

## Commands

| Command | Result | Notes |
|---|---|---|
| `device.update.check` | `device.update.check.result` | Read-only. No download. |
| `device.update.apply` | `device.update.apply.accepted` then progress/result | Requires `target_version`, `manifest_revision`, `manifest_fingerprint`, and a one-time `confirmation_token`. Client URLs/checksums are rejected. |
| `device.runtime.restart` | `device.runtime.restart.accepted` | Safe restart by default. An explicit boolean `force=true` permits supervised restart after a blocked checkpoint. Timeout must be positive when present. |

Workspace and MCP command names stay canonical. Cloud workspace commands are
admitted as managed-remote (name-based create, constrained browse, preview
tokens for delete/relocate). Cloud MCP commands dispatch without session
registration except `replace_mcp_config`, which stays rejected. Save, delete,
Advanced save, STDIO inspect, and OAuth complete require a revision fingerprint
and one-time confirmation ticket. Snapshots and logs never include secret
values. Hosted `POST /api/mcp` is not a Client path.

`workspace.remove` is a metadata-only workspace mutation. Its correlated
`workspace.removed` result carries the removed stable id; the Agent deletes no
directory, file, session, or message. The Client confirms that boundary before
sending the command.

Device Overview shows Check for updates, Update agent, and Restart agent for
every Online device via `DeviceCommandClient`. Presentation does not gate those
actions on capability flags and does not call `LocalDaemonController`.

Check returns `current_version`, `available_version`, and `status`
(`update_available` / `up_to_date` / `source_managed` / failure). An available
update includes a one-time `confirmation_token` plus `manifest_revision` (tag)
and `manifest_fingerprint` (commit). Apply reuses those fields; Client artifact
URLs are rejected. The updater rejects the apply if the fetched manifest tag or
commit changed after confirmation. A source-managed apply returns `device.update.result` without
exiting. A successful packaged apply returns `device.update.apply.accepted` and
then uses `DaemonRestartCoordinator`.

Restart returns `device.runtime.restart.accepted` before drain. Unsupervised
hosts return `service_unavailable` and do not exit. Force restart is a distinct
red confirmation action and sends `force=true`; it may interrupt active work
but still uses the supervised coordinator and durable recovery boundary.
Non-boolean force values and timeouts outside 1–3600 seconds are rejected.
Client success is Offline then Online, not disconnect alone.

## Admission errors

Every rejection is an `error` event that repeats `request_id` and `device_id`.

| Code | When |
|---|---|
| `wrong_device` | Envelope `device_id` ≠ registered device |
| `unsupported` | Unknown command, or a runtime outcome such as `source_managed` |
| `duplicate_request` | Same `request_id` already admitted |
| `stale_confirmation` | Missing, expired, consumed, wrong-device, wrong-operation, or wrong-fingerprint ticket |
| `confirmation_required` | Apply without a ticket, or a cloud MCP mutation without a confirmation ticket |
| `path_not_allowed` | Managed-remote path outside allowed roots, symlink, or protected root |
| `invalid_request` | Missing `request_id`, non-boolean `force`, unbounded timeout, or a remote create that sent a host path |
| `device_offline` | Client-side: target socket is not connected |
| `service_unavailable` | Restart/apply rejected because the Agent is not supervised |

Duplicate and stale tickets fail without mutation. Lost-success recovery
re-reads state; it does not retry the same destructive `request_id`.
