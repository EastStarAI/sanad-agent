---
title: "Remote MCP Management Boundary QA"
description: "Regression matrix for disabling cloud MCP configuration management while preserving locally approved MCP tool use."
---

# Remote MCP Management Boundary QA

## Current Product Boundary

- MCP server configuration remains available through the local desktop
  connection.
- Cloud clients cannot list, inspect, add, edit, delete, or replace MCP server
  configuration.
- MCP servers configured by the user locally remain part of per-turn tool
  discovery and execution for both local and cloud-origin conversations.
- The cloud adapter is the enforcement boundary. Shared MCP handlers and the
  capability catalog remain transport-neutral.

## Automated Coverage Matrix

| Area | Required behavior |
|---|---|
| Cloud `execute_command` | The five MCP management commands return `remote_mcp_management_disabled`. |
| Cloud `protocol_event` | Each equivalent canonical event returns the same structured error. |
| Early rejection | Rejection occurs before session registration, bridge dispatch, settings reads, server inspection, or configuration mutation. |
| Correlation | Every rejection preserves the original `request_id` and `session_id`. |
| Local management | Shared bridge and runtime paths remain unchanged; their existing list, save, and delete regressions continue to pass. |
| Tool availability | No cloud-origin filtering is added to MCP catalog assembly or MCP tool execution. |

## Manual Regression Scenarios

### Remote connection

1. Attempt to open or refresh MCP configuration for a remote device.
2. Verify the request receives `remote_mcp_management_disabled` without a
   timeout and without starting or inspecting a server.
3. Attempt each configuration mutation and verify the local configuration files
   remain unchanged.
4. Start a cloud-origin conversation whose selected workspace can use an MCP
   server that was configured locally.
5. Verify its tools remain discoverable and executable subject to the normal
   tool permission policy.

### Local same-device connection

1. List the global and workspace MCP configuration.
2. Add, inspect, update, and delete a test MCP server locally.
3. Verify each operation still uses the shared daemon-owned handlers.
4. Verify the effective MCP tool catalog refreshes after the local change.

## Release Gate

Do not restore remote MCP configuration management until cloud-session
authorization, server-definition validation, secret handling, transport policy,
and destructive confirmation have been documented, reviewed, and covered by
tests. Do not interpret this temporary gate as permission to remove locally
configured MCP tools from cloud-origin turns.
