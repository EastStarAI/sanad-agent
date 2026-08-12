# Agent Capabilities Contract

## Scope
This contract applies to `agent/lib/capabilities/`.

## Capability Ownership
- Own model-visible tool contracts, rich local specifications, registry/search, runtime catalog assembly, workspace/web execution, MCP, skills, and approval enforcement.
- `ToolSchema` remains LLM-facing only; runtime source, target, availability, workspace, approval, and replay metadata belong to `LocalToolSpec`.
- Tools needing rich metadata implement `ToolSpecProvider` rather than overloading schema fields.
- `ToolsRegistry` is both execution lookup and searchable catalog; do not maintain duplicate tool lists.
- `AgentRunner` executes an assembled catalog but must not construct workspace, MCP, skill, web, or platform catalogs.

## Catalog Boundary
- `LocalRuntimeCatalog` owns per-turn assembly and rebuilds mutable workspace/MCP context each turn.
- Platform tools enter only as explicit turn-scoped specifications and retain platform source/target metadata.
- Skill discovery/load and daemon-owned catalogs never move back into the client.
- Product-managed skills share `.agents/skills/` with developer skills, enter the executable only through the selective bundled-skills manifest, and reconcile into the active `SANAD_HOME/skills` through one daemon-owned lifecycle manager. Matching bundle revisions take a no-enumeration fast path; updates/removals never overwrite user-modified or user-deleted skills.
- Runtime prompts omit tool inventory prose and receive workspace context through the runtime context owner.

## Replay and Identity
- Tool restart replay defaults to unsafe and requires explicit opt-in by the tool contract.
- Carry tool-call identity through execution context, permission checkpoints, resumed results, persistence, and canonical history.
- Never infer replay safety from tool name or successful partial output.
