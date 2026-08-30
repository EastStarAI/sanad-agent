---
title: "Remote MCP Management Boundary QA"
description: "Regression matrix for cloud MCP configuration management with redacted snapshots, confirmation tickets, and preserved MCP tool permission policy."
---

# Remote MCP Management Boundary QA

## Current Product Boundary

- MCP server configuration is available through both the local desktop
  connection and a cloud-admitted remote device.
- Cloud clients may list, inspect, add, edit, delete, import, export, read
  Advanced JSON, and run MCP OAuth flows through the daemon protocol relay.
  Root-document `replace_mcp_config` stays rejected as
  `remote_mcp_management_disabled`.
- Save, delete, Advanced save, STDIO inspect, and OAuth complete require a
  revision fingerprint and a one-time confirmation ticket. The Client consumes
  that ticket after the user already confirmed in the form.
- Snapshots, exports, errors, events, and diagnostic logs never include bearer
  tokens, secret headers, secret environment values, or OAuth tokens. Nested
  `secrets` maps are redacted in Client socket diagnostics and daemon command
  logs.
- Hosted `POST /api/mcp` is not a Client path.
- MCP servers remain part of per-turn tool discovery and execution for both
  local and cloud-origin conversations. Cloud-origin tool execution stays under
  `PermissionManager`.

## Automated Coverage Matrix

| Area | Required behavior |
|---|---|
| Cloud `list_mcp_servers` | Dispatches without session registration and returns a redacted snapshot. |
| Cloud save/delete | First request returns a preview ticket; mutation runs only after confirmation. A stale ticket after an intervening mutation fails closed. |
| Cloud `replace_mcp_config` | `execute_command` and `protocol_event` return `remote_mcp_management_disabled` before session registration or runtime access. |
| Wrong device | Non-matching `device_id` returns `wrong_device` with no MCP mutation. |
| Correlation | Every rejection and preview preserves the original `request_id`. |
| Secret redaction | Nested `secrets` maps are `***` / `[REDACTED]` in daemon `SecretsRedactor` and Client socket diagnostics. Snapshots use configured markers only. |
| Local management | Shared bridge and runtime paths remain unchanged; list, save, delete, secret replace/remove, import, Advanced revision, and OAuth regressions continue to pass. |
| Catalog refresh | Effective MCP tool specs invalidate when configuration fingerprints change, without a daemon restart and without changing permission policy. |
| Tool availability | No cloud-origin filtering is added to MCP catalog assembly or MCP tool execution. |

## Manual Regression Scenarios

### Remote connection

1. Open MCP configuration for an Online remote device.
2. List Device and Workspace scopes and confirm configured markers only.
3. Add a test server, inspect/test it, then edit and delete it. Confirm the
   remote Agent files change and the local Agent is untouched.
4. Attempt `replace_mcp_config` and verify it remains rejected.
5. Start a cloud-origin conversation whose selected workspace can use the MCP
   server. Verify tools remain discoverable and executable subject to the
   normal tool permission policy.

### Local same-device connection

1. List the global and workspace MCP configuration.
2. Add, inspect, update, and delete a test MCP server locally without an extra
   confirmation round-trip when the daemon is local.
3. Verify each operation still uses the shared daemon-owned handlers.
4. Verify the effective MCP tool catalog refreshes after the local change.

## Release Gate

Do not treat cloud MCP restoration as permission to write hosted
`/api/mcp`, accept root-document replacement, log secret values, or remove
permission prompts from MCP tools.
