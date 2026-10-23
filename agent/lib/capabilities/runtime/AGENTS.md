# Capability Runtime Contract

## Scope
This contract applies to `agent/lib/capabilities/runtime/`.

## Per-Turn Assembly
- Build workspace-bound, MCP-bound, skill, web, and explicit platform tool context for every turn.
- `LocalRuntimeCatalog` remains the single per-turn assembler and the only place a turn's tool list is composed; it delegates each tool family to exactly one builder in `capabilities/runtime/tool_builders/` (`workspace_file_tools`, `web_tools`, `ask_user_tool`, `view_image_tool`, `secret_tools`, `platform_tool_specs`). Builders return tool instances to the catalog and never register themselves, cache a turn, or become a second registry.
- Tool names and JSON schemas are model-visible: a change to either is a contract change, and `test/capabilities/tool_schema_snapshot_test.dart` must move with it.
- The workspace- and attachment-scoped external-path approval gate has exactly one owner, `authorizeExternalWorkspacePath` in `workspace_file_tools.dart`; every tool that can reach a canonical path outside the selected workspace must pass through it, so approval key, permission class, and display arguments cannot diverge per tool.
- Do not cache mutable workspace/MCP catalogs across turns without an identity/fingerprint invalidation boundary.
- Preserve local tool source, execution target, approval, workspace, availability, and replay metadata.
- Every sensitive MCP tool executes through `PermissionManager` before `McpRuntimeManager`; denial prevents the server call, and once/session/workspace grants use the canonical approval owner.
- Return the assembled catalog to the engine; do not execute the model loop here.

## Runtime Context
- `RuntimeContextBuilder` owns the engine context tier, not stable identity or volatile turn/date/provider metadata.
- Load closest workspace contracts first.
- Sanitize instruction content before prompt injection.
- Apply head-plus-tail truncation when instruction content exceeds budget.
- Omit tool inventories and per-turn timestamps from workspace context.
- Skill summaries and workspace instructions come from daemon-owned registries/files, never client discovery.
- When no valid workspace is attached, emit one concise context sentence stating that file and terminal tools are unavailable and direct workspace-dependent requests to the upper-left workspace control.

## Workspace Services
- Use focused handlers for read, write, edit, glob, grep, and tree operations; do not recreate a monolithic workspace service. Migrated handlers own typed `executeResult` output and retain `execute` only as an exact text projection while the runtime catalog callback boundary remains textual.
- Resolve and canonicalize every workspace-tool path before host access. Internal paths execute directly; external paths require an explicit `PermissionManager` decision unless workspace policy is `full_access`, and authorization remains bound to the canonical target.
- Recursive workspace search skips common generated/dependency trees and unreadable non-UTF-8 candidates rather than failing the entire query.
- Project environment files are redacted by `ProjectEnvRedactor` in every model-visible read and search projection; search matches the redacted text so it cannot confirm a value.
- The catalog adds `system_request_secret`, `system_list_secrets` and `system_delete_secret` only for a turn with stamped `owner` authority. `system_ask_user` and `system_request_secret` suspend through the shared `InteractiveUserInput` checkpoint owner.
- The catalog adds `host_capability_discovery` only for a workspace turn with stamped `owner` authority, an `owner_only` policy, and no tool that already reaches the host `PATH`; otherwise the schema is omitted entirely.
- Return host-root and parent navigation metadata for remote browsing rather than requiring client path inference.
- Workspace creation accepts explicit path and derives display name from basename when name is absent.

## Web Services
- Resolve provider choice and credentials from current `Config` for every execution so live settings mutations take effect.
- Do not capture mutable web-search configuration at service construction.
- Keep fetch/search result normalization and safety inside daemon runtime services.
