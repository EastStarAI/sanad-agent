# Capability MCP Contract

## Scope
This contract applies to `agent/lib/capabilities/mcp/`.

## Configuration Ownership
- Merge user and workspace MCP configuration in the daemon; workspace scope takes precedence for same-name entries.
- Persist client-requested mutations through the same settings owner used by runtime discovery.
- Clients consume refreshed daemon snapshots and never become configuration truth.
- Keep secret values out of snapshots, logs, protocol errors, export, and Advanced JSON.
- Store MCP credentials only through the owner-protected `McpSecretStore`; configuration files contain opaque references and non-secret metadata, including secret STDIO argument values associated with recognized credential flags.
- Import is preview-first and bounded; Advanced JSON is one-server-only with a reviewed revision before mutation.

## Runtime Manager
- Own discovery and execution for enabled stdio, SSE, and streamable-HTTP servers.
- Maintain persistent managed sessions rather than spawning and closing a server for each turn.
- Cache tool specifications by a fast fingerprint of merged effective configuration.
- Invalidate cache and rebuild connections when effective configuration changes.
- Recover dropped connections through managed reconnect and bounded retry without duplicating tool execution.

## Tool Catalog
- Namespace MCP tools to avoid collision with built-ins and other servers.
- Preserve MCP source/owner metadata in `LocalToolSpec`.
- Rebuild workspace-sensitive MCP tools per turn through `LocalRuntimeCatalog`.
- Inspection/testing queries must not mutate saved configuration unless an explicit mutation succeeds.
- OAuth discovery, PKCE, registration, callback listeners, token exchange, cancellation, expiry, and refresh credentials are daemon-owned; client-visible flow snapshots contain no token material.
