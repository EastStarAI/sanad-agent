# Capability Runtime Contract

## Scope
This contract applies to `agent/lib/capabilities/runtime/`.

## Per-Turn Assembly
- Build workspace-bound, MCP-bound, skill, web, and explicit platform tool context for every turn.
- Do not cache mutable workspace/MCP catalogs across turns without an identity/fingerprint invalidation boundary.
- Preserve local tool source, execution target, approval, workspace, availability, and replay metadata.
- Return the assembled catalog to the engine; do not execute the model loop here.

## Runtime Context
- `RuntimeContextBuilder` owns the engine context tier, not stable identity or volatile turn/date/provider metadata.
- Load closest workspace contracts first.
- Sanitize instruction content before prompt injection.
- Apply head-plus-tail truncation when instruction content exceeds budget.
- Omit tool inventories and per-turn timestamps from workspace context.
- Skill summaries and workspace instructions come from daemon-owned registries/files, never client discovery.

## Workspace Services
- Use focused handlers for read, write, edit, glob, grep, and tree operations; do not recreate a monolithic workspace service.
- Resolve and canonicalize every workspace-tool path before host access. Internal paths execute directly; external paths require an explicit `PermissionManager` decision unless workspace policy is `full_access`, and authorization remains bound to the canonical target.
- Recursive workspace search skips common generated/dependency trees and unreadable non-UTF-8 candidates rather than failing the entire query.
- Return host-root and parent navigation metadata for remote browsing rather than requiring client path inference.
- Workspace creation accepts explicit path and derives display name from basename when name is absent.

## Web Services
- Resolve provider choice and credentials from current `Config` for every execution so live settings mutations take effect.
- Do not capture mutable web-search configuration at service construction.
- Keep fetch/search result normalization and safety inside daemon runtime services.
