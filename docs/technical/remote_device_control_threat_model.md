---
title: "Remote Device Control Threat Model"
description: "Trust boundaries, hosted ownership evidence, MCP payload handling, managed workspace roots, and gate-linked pass/fail tests for Task 82."
---

# Remote Device Control Threat Model

Owning task: `docs/plans/tasks/82-secure-remote-device-control-workspaces-and-mcp.md`.

This page is the G0 security record for remote Agent update, restart, managed
workspace creation, and redacted MCP management. Later gates implement against
this model; they do not reopen these trust decisions.

## Actors and trust boundaries

| Actor | Trust | May do | Must not do |
|---|---|---|---|
| Account owner (User) | Authenticated Portal session on a Client | Send typed `device_command` envelopes targeting a device they own | Supply filesystem authority, release URLs/checksums, MCP tokens as protocol truth, or force-kill a daemon |
| Client | Untrusted presentation | Route through `DeviceCommandClient` / `DeviceConnectionCoordinator` with `device_id` + `request_id` | Choose local vs cloud transport in Settings/Workspace/MCP pages; call Local Gateway lifecycle on a cloud device; call hosted `/api/mcp` |
| Hosted Gateway | Trusted relay and inventory | Authenticate app and daemon sockets; prove User owns the target before relay; return private responses | Persist command payloads, MCP secrets, workspace trees, or become mutation authority |
| Remote Agent | Final authority | Admit, preview, persist, mutate, redact, and return typed results on its host | Accept cloud commands from any socket other than its registered authenticated Gateway connection; follow client-supplied paths/URLs as authority |
| Local Gateway | Same-device trusted loopback | Existing local workspace/MCP/update/restart HTTP | Remain the only restart/update path after G2; be reachable from Web/mobile |
| Host OS / supervisor | Process persistence | Restart a supervised Agent after a safe drain | Be assumed present; unsupervised Agents must reject remote restart/update-apply before exit |
| Attacker (other tenant, stolen Client session, malicious MCP server, filesystem adversary) | Untrusted | Attempt wrong-device, offline, traversal, symlink, stale confirmation, secret extraction, SSRF, log scraping | Succeed without a User session that owns the live device, or escape daemon-owned roots and redaction |

Sensitive classes: Device Credential and P-256 key, User tokens, MCP bearer /
header / env / OAuth secrets, Sanad Home files (`auth.json`, `mcp_secrets.json`,
provider credentials), host filesystem outside allowed roots, release
artifacts, session and tool payloads.

## Current product boundary (G0 freeze record)

At G0 the cloud adapter rejected these commands on both `execute_command` and
`protocol_event` before session registration or bridge dispatch:

**Workspace (6):** `create_workspace`, `workspace.relocate`,
`browse_workspace_tree`, `workspace.create_folder`, `workspace.rename_folder`,
`workspace.delete_folder`. Code:
`remote_workspace_management_disabled`. `list_workspaces` remained allowed.

**MCP (14):** `list_mcp_servers`, `save_mcp_server`,
`delete_mcp_server`, `replace_mcp_config`, `inspect_mcp_server`,
`preview_mcp_import`, `export_mcp_servers`, `read_advanced_mcp_server`,
`preview_advanced_mcp_server`, `save_advanced_mcp_server`, `start_mcp_oauth`,
`get_mcp_oauth_status`, `cancel_mcp_oauth`, `complete_mcp_oauth`. Code:
`remote_mcp_management_disabled`.

G3 replaced the workspace freeze with managed-remote admission. G4 replaced
the MCP freeze except `replace_mcp_config`, which remains
`remote_mcp_management_disabled` on cloud. Cloud MCP mutations require a
revision fingerprint and one-time confirmation ticket. Nested `secrets` maps
are redacted in daemon command logs and Client socket diagnostics.

The later `workspace.remove` command joins managed-remote admission as a
metadata-only mutation. It cannot reach filesystem deletion and does not
cascade into conversations.

Retained local owners: `SanadProtocolBridge` workspace/MCP handlers,
`LocalWorkspaceRuntimeService`, `AgentUpdateService`,
`DaemonRestartCoordinator`, Local Gateway `POST /restart` and `POST /update`.
Cloud-origin turns still execute configured MCP tools through
`PermissionManager`.

Regression owner:
`agent/test/interfaces/server_sanad_gateway_platform_security_test.dart`.

## Hosted ownership evidence

Public source does not contain Gateway implementation. G0 inspected the private
hosted Gateway used by this product (read-only) against the public wire
contract in `communication_protocols.md`.

Proven:

1. Client cloud commands use Socket.IO `device_command` with an explicit
   `device_id`. Conversation and settings actions do not send a raw
   `protocol_event` from the Client.
2. Gateway `CommandRouter.handle_device_command` admits only an authenticated
   `app` socket, requires `device_id`, looks up the live daemon connection for
   that id, and relays only when `target_conn.user_id == requester.user_id`.
3. Wrong-user relay is blocked and is covered by
   `backend/tests/unit/handlers/test_command_handler.py`
   (`test_command_route_blocks_unauthorized_user`). Offline devices receive a
   typed error; unauthenticated sockets are dropped.
4. Relayed envelopes strip `user_id` / `hardware_id` before `execute_command`
   is emitted to the daemon socket. The Agent accepts cloud traffic only on its
   registered Gateway connection after Device Authorization proof.
5. Capabilities reads use durable `DeviceRepository.get(device_id, user_id)`
   and return `DEVICE_NOT_OWNED` for another tenant
   (`test_app_cannot_read_another_tenants_capabilities`).

Accepted residual, not a G0 stop:

- Command relay binds to the **live daemon connection user_id**, not a second
  `DeviceRepository` lookup. Registration already bound that connection through
  Device Authorization. A private hosted follow-up may add the durable
  inventory check as defense in depth; Task 82 does not wait on it because
  relay already fails closed for a different tenant.
- G1 closed the original Agent-side gap: the cloud adapter now compares the
  envelope `device_id` with `_registeredDeviceId` and rejects mismatches before
  workspace, MCP, device-control, or session dispatch.

Any later hosted change that lets a Client command reach a daemon without this
user/device bind is a separate ownership handoff and stops secret or
destructive remote gates.

## MCP payload handling

Task 82 restores MCP **through the daemon protocol relay**, never through the
legacy hosted REST settings API.

| Path | Persists payload? | Logs payload? | Task 82 |
|---|---|---|---|
| Socket.IO `device_command` → `execute_command` | No. Routing registry stores only `user_id`, `device_id`, `request_id`, origin socket id | Application logs command name and device id, not the payload | Product path |
| Hosted `POST /api/mcp` `mcp_settings.config_json` | Yes, per-user JSON text | Test fixtures include command/args | **Forbidden.** Client has no caller; G4 must not add one |
| Client debug socket logs | No | Debug-only; credential-shaped keys and the nested `secrets` map are redacted | G4 redacts `secrets` and MCP secret mutations |

Secret mutations may proceed in G4 **only** on the daemon relay path, with
redacted snapshots, no hosted `/api/mcp` writes, and G6 secret canaries plus
log scans. Root-document `replace_mcp_config` stays rejected on cloud even
after G4. If hosted relay later stores or logs MCP payloads, G4 secret
mutations stop and become a private hosted handoff.

## Adopted managed workspace model

G0 adopts the plan locked decisions as the owner-approved filesystem model:

- Remote create is **name + optional description only**. The Agent creates a
  canonical directory under `SANAD_HOME/workspaces` via `SanadHomeBootstrap`
  (no symlink root, no client absolute path).
- Cloud browse visible roots: that managed root and registered workspace
  roots only. `/`, user Home, and `SANAD_HOME` internals are hidden.
- create/rename/delete folder stay inside one canonical workspace root after
  null-byte, traversal, and symlink rejection.
- Recursive delete and relocate require a daemon preview, redacted summary,
  and a short-lived one-time confirmation token bound to device, path, and
  operation. Stale or cross-device tokens fail without mutation.
- Arbitrary existing host-directory picker remains out of scope.
- Existing workspace UUIDs and conversation identity do not change.

Today local `createWorkspace` still accepts a host path and empty-path browse
lists OS roots (`/` or Windows drives). Cloud-admitted calls use managed-remote
mode instead: name-based create under `SANAD_HOME/workspaces`, allowed-root
browse, and preview tokens for delete/relocate.

## Capability-specific threats

### Remote update (`device.update.check` / `device.update.apply`)

- **Check:** read-only. Failures: unauthenticated, wrong-device, offline,
  `source_managed`, `unsupported`. Must not download or mutate.
- **Apply:** user-confirmed exact version + manifest revision/fingerprint.
  Agent uses `AgentUpdateService` and official release trust. Reject client
  URLs, checksums, downgrade, and unsupervised apply-that-exits. Success is
  Online + announced target version, not download or disconnect. Failure rolls
  back binary/service and preserves Sanad Home, credentials, workspaces, and
  MCP config.

### Remote restart (`device.runtime.restart`)

- Restart only through `DaemonRestartCoordinator`. Acknowledge before drain.
  Safe restart is the default; explicit user-confirmed `force=true` may
  interrupt blockers but still requires a supervised host and durable recovery.
  Reject non-boolean force, unsupervised hosts (`service_unavailable`), and
  unbounded timeout. Lost ack must not auto-retry. Success is accepted →
  Offline → Online → capability refresh.

### Remote workspaces

- Name-based create under managed root. Browse cannot walk above the allowed
  root. Destructive ops need preview + one-time token. Race, symlink, and
  root-delete attempts fail closed. Lost-success recovery re-reads snapshot
  rather than repeating delete.

### Remote MCP

- Split read-only list/inspect/export from secret and destructive mutations.
  STDIO is executable + args, never a shell line. HTTP/SSE keep current
  SSRF/header rules. OAuth stays daemon-owned with PKCE. Cloud-origin tool
  execution still goes through `PermissionManager`.

## Gate pass/fail tests

Each later gate must add or keep tests that fail closed on the negative cases
below. Names are the required outcomes; G1+ introduce the files that do not
yet exist.

### G0 — this record

- Pass: current cloud rejection tests still fail closed for all six workspace
  commands and all fourteen MCP commands, with `request_id` preserved and no
  session/runtime mutation.
- Fail: any blocked command reaches `LocalWorkspaceRuntimeService` or MCP
  settings.

Command: `agent/test/interfaces/server_sanad_gateway_platform_security_test.dart`.

### G1 — contracts and admission

- Pass: typed command/result/error models; no `supports_remote_*` capability
  keys; request/device correlation on local and cloud envelopes; admission
  tests for correct target, wrong-device, offline, duplicate request, stale
  confirmation; Agent rejects envelope `device_id` ≠ registered device.
  Every Online device may send the commands.
- Fail: UI-name parsing; new capability flags; missing correlation.

### G2 — update and restart

- Pass: check is read-only; apply uses `AgentUpdateService` with exact target
  and rollback; `source_managed`; no downgrade or candidate URL; restart
  returns accepted before drain; explicit force remains supervised;
  unsupervised/non-boolean-force/unbounded timeout rejected;
  lost ack is not a second restart; Client waits Offline→Online and target
  version; buttons on every Online device; no `LocalDaemonController` on cloud.
- Fail: disconnect treated as success; parallel kill/start path.

### G3 — managed workspaces

- Pass: managed root created without symlink; name-based create; browse
  limited to managed/registered roots; folder ops inside root; preview token
  for recursive delete/relocate; traversal/symlink/race/root deletion/stale
  token/wrong device/concurrent mutation/lost-success tests.
- Fail: empty browse lists `/` or Home; client-supplied absolute path becomes
  the workspace root on cloud.

### G4 — MCP management

- Pass: read-only vs secret/destructive admission; redacted snapshots; no
  secret in logs/errors/events/cache; revision fingerprint; no-shell STDIO;
  SSRF/header validation; catalog refresh without restart; Device vs Workspace
  precedence; `/api/mcp` unused; `replace_mcp_config` still rejected on cloud.
- Fail: nested `secrets` appearing in debug logs; hosted `config_json` writes.

### G5 — Client UX

- Pass: check/update/restart target the selected device; remote workspace
  create stays in the managed root while browser APIs remain constrained for
  future File Tree use; MCP forms with redaction and offline
  states; no presentation transport branching; widget tests for confirm,
  double-submit, reconnect, lost-success; English copy only.
- Fail: Settings calling `LocalDaemonController` for a cloud device.

### G6 — local security verification

- Pass: Agent and Client analyzers; focused auth/admission/restart/workspace/
  MCP tests; full fast suites; daemon-backed E2E restart/reconnect and
  persistent mutation; secret canaries; log scans; symlink/race/fail-injection;
  Graphify update. Owners:
  `agent/test/interfaces/remote_device_control_g6_security_test.dart`,
  `agent/e2e_test/remote_device_control_e2e_test.dart`.
- Fail: any secret canary in logs, errors, or export.

### G7 — live Task 81 remote device

- Pass: read-only preflight; check current/latest; isolated candidate
  apply/rollback; safe restart Offline→Online; managed workspace create and
  in-root folder ops with above-root reject; MCP add/inspect/edit/delete with
  redaction and child cleanup; operations hit the remote device, not the local
  Agent; sanitized evidence.
- Fail: mutating Stable before a separate release gate; evidence containing
  IP, token, credential, or user content.

### G8 — docs and delivery

- Pass: protocol, MCP, Settings, QA, and contracts match the implemented
  model; threat model still accurate; no commit/push/PR without owner approval.
- Fail: `workspace_folder_mutation_protocol.md` still describing only the
  temporary shutdown after restore.
