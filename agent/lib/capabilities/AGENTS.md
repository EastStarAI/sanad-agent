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
- `ToolContext` may carry `runId`, `generation`, and `RunCancellationScope`; cooperative cancellation is opt-in via `isCooperativelyCancellable`.
- `shell_execute` owns its process tree through `ProcessTreeController` and must distinguish user cancellation from timeout in terminal output.

## Image Processing Boundary
- `capabilities/image/image_policy.dart` is the sole owner of image byte, pixel, edge, base64, detail, timeout, concurrency, and encoder limits.
- Accept image types from verified PNG/JPEG/WebP magic bytes and decoder metadata, never filenames or caller MIME claims; animated, multi-frame, corrupt, deceptive, and over-limit input fails closed.
- Decode, resize, and encode only in killable isolates behind the shared FIFO concurrency bound. The image worker accepts and returns bytes in memory and must never create temporary files.
- `original` preserves verified source bytes. Other detail modes never enlarge and may pass compliant bytes unchanged; required normalization uses PNG for actual transparency and JPEG for opaque pixels.
- `view_image` is registered independently of provider capability only when a workspace or daemon-owned admitted-attachment scope exists. It accepts one local path, is explicitly restart-replay-safe, and returns safe text before an image block.
- Workspace targets use `WorkspacePathResolver`; canonical external targets use the existing `PermissionManager` approval owner before stat or byte read. Attachment authority is exact-file and session-scoped, never workspace/full-access authority, and private attachment paths must not enter generic turn metadata.
