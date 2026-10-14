# Windows PATH Resolution Contract

## Scope
This contract applies to `shared/windows_path/`.

## Ownership
- Own the logic that rebuilds the effective system PATH on Windows from the
  Machine and User registry values (via a single PowerShell read), so that
  spawned processes see tools installed at the OS level (Node.js, npm globals,
  etc.) even when the launching terminal inherited a stale PATH snapshot.
- Keep this package Pure Dart and independent of Client, Agent, Flutter, and
  developer-tool implementations.
- Cache the resolved value with a short TTL so repeated calls (per-command,
  per-MCP-server) do not spawn PowerShell each time.
- POSIX (and non-Windows) callers receive their inherited PATH unchanged; this
  package must never change behavior on non-Windows platforms.
- Never write the resolved PATH into logs, health endpoints, or across the
  HTTP/gateway boundary; it is a local host value only.