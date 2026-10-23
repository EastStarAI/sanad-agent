# Agent Capabilities Contract

## Scope
This contract applies to `agent/lib/capabilities/`.

## Capability Ownership
- Own model-visible tool contracts, rich local specifications, registry/search, runtime catalog assembly, workspace/web execution, MCP, skills, and approval enforcement.
- `ToolSchema` remains LLM-facing only; runtime source, target, availability, workspace, approval, and replay metadata belong to `LocalToolSpec`.
- Tools needing rich metadata implement `ToolSpecProvider` rather than overloading schema fields.
- `ToolsRegistry` is both execution lookup and searchable catalog; do not maintain duplicate tool lists.
- `AgentRunner` executes an assembled catalog but must not construct workspace, MCP, skill, web, or platform catalogs.

## User Secrets Boundary

- `UserSecretVault` is the only owner of the Agent vault's `custom:` namespace: `store` (read-back verified), `names`, `remove`, `available`, and `resolve`. `resolve` exists only for the shell backend that injects explicitly requested names into one child process; nothing model-visible returns a value.
- `UserSecretCatalog` (`capabilities/secrets/user_secret_catalog.dart`) is the single read model behind the Settings → Privacy & Security page. It joins vault names with `user_secret_metadata`, and it **never calls `resolve`**: the page is write-only, so no reader of it can return a stored value. `agent/test/guards/secrets_value_read_guard_test.dart` fails if a value-reading call appears on that path.
- The catalog validates the name (`UserSecretVault.nameRejection`), the value (non-empty, at most `maxValueLength`, not a `[REDACTED:…]` sentinel), and the description (at most 256 characters) before the first mutation. Vault unavailability is a typed failure, never a silent success.
- Write ordering is vault first, metadata second: a verified vault write is never reported as a failure because metadata could not be written, and a refused vault write never gets a metadata row.
- `SecretAcquisition` records `source = agent_request` for every name a Task 84 card stored, because that path is what arrived. It records a name and an outcome only, never a value.

## Catalog Boundary
- `LocalRuntimeCatalog` owns per-turn assembly and rebuilds mutable workspace/MCP context each turn.
- The catalog delegates tool families to focused builders under `capabilities/runtime/tool_builders/`; a builder returns tools to the catalog and never registers itself or becomes a second registry.
- Platform tools enter only as explicit turn-scoped specifications and retain platform source/target metadata.
- Skill discovery/load and daemon-owned catalogs never move back into the client.
- Product-managed skills share `.agents/skills/` with developer skills, enter the executable only through the selective bundled-skills manifest, and reconcile into the active `SANAD_HOME/skills` through one daemon-owned lifecycle manager. Matching bundle revisions take a no-enumeration fast path; updates/removals never overwrite user-modified or user-deleted skills.
- Runtime prompts omit tool inventory prose and receive workspace context through the runtime context owner.

## Replay and Identity
- Tool restart replay defaults to unsafe and requires explicit opt-in by the tool contract.
- Carry tool-call identity through execution context, permission checkpoints, resumed results, persistence, and canonical history.
- Never infer replay safety from tool name or successful partial output.
- `ToolContext` may carry `runId`, `generation`, and `RunCancellationScope`; cooperative cancellation is opt-in via `isCooperativelyCancellable`.
- `shell_execute` owns its process tree through `ProcessTreeController` and must distinguish user cancellation from timeout in terminal output. On Windows, execution uses an ASCII start-gate wrapper with UTF-8 command payload to preserve non-ASCII arguments, and reports `exit_code` on natural completion. The wrapper invokes its helpers (`chcp.com`, `ping.exe`) by absolute path from `%SystemRoot%\System32\` so it does not depend on the child `PATH`, and resets `%errorlevel%` to 0 via `(call )` immediately before delegating to the payload so wrapper mechanics never leak into command exit status.

## Schedule Tool Boundary

- `schedule_task` is the only model surface over schedules. Its actions are `create`, `list`, `cancel`, `update`, `pause`, `resume`, and `run_now`; `create` and `update` accept an optional `name`, where a blank value means "absent".
- The tool never writes a schedule row itself: pause, resume, and run-now delegate to `CronScheduler`'s control methods, and a settings edit reaches the repository only through `updateScheduleSettings`. An absent `name` forwards that method's omission sentinel, never `null`.
- Control is always called with `ScheduleAuthority.model`, so a model turn may mutate only a `model`-owned row of its own conversation. A `user`-owned row, a foreign conversation's row, or an unknown id is rejected before anything mutates.
- The owner kind belongs to the tool family, not the payload: a `user` value in the arguments has no reader, and only a device-owner command family produces `owner_kind='user'`.
- `run_now` records `trigger='manual'` and leaves `next_run_at`, `last_run_at`, `last_status`, and `enabled` untouched. It never resumes a paused schedule.
- `resume` of an expired `once`, and `resume` or `run_now` of a model-owned schedule whose owning conversation is gone, surface as the stable message prefixes `schedule_expired` and `schedule_orphaned`. `ToolResultErrorCode` is transport-wide and never gains schedule-specific members.
- `list` is device-wide and shows each row's owner kind with its owning conversation or `device`, its `enabled` state, and its consecutive-failure count, bounded at `defaultListCap` with an explicit truncation note.

## Image Processing Boundary
- `capabilities/image/image_policy.dart` is the sole owner of image byte, pixel, edge, base64, detail, timeout, concurrency, and encoder limits.
- Accept image types from verified PNG/JPEG/WebP magic bytes and decoder metadata, never filenames or caller MIME claims; animated, multi-frame, corrupt, deceptive, and over-limit input fails closed.
- Decode, resize, and encode only in killable isolates behind the shared FIFO concurrency bound. The image worker accepts and returns bytes in memory and must never create temporary files.
- `original` preserves verified source bytes. Other detail modes never enlarge and may pass compliant bytes unchanged; required normalization uses PNG for actual transparency and JPEG for opaque pixels.
- `view_image` is registered independently of provider capability only when a workspace or daemon-owned admitted-attachment scope exists. It accepts one local path, is explicitly restart-replay-safe, and returns safe text before an image block.
- When `ToolContext.imageSupport` is `RouteImageSupport.unsupported` or `RouteImageSupport.unknown` (including omitted context), every image-producing tool fails closed before attaching a pixel block: `ViewImageHandler` returns `executionFailed` before isolate decoding, and `ScreenshotTool` keeps its capture summary text-only, so non-image or unverified routes never accept a pixel-bearing history entry that would fail downstream; test fixtures validating path, permission, or scope boundaries pass an explicit `ToolContext` with `RouteImageSupport.supported`.
- `ScreenshotTool` always saves the raw capture to `Downloads/AgentScreenshots` and reports that path in its summary, independent of model attachment. Its image block comes only from the shared image worker under the same policy limits, and a rejected, oversized, or undecodable capture degrades to a text-only success result instead of throwing.
- Workspace targets use `WorkspacePathResolver`; canonical external targets use the existing `PermissionManager` approval owner before stat or byte read. Attachment authority is exact-file and session-scoped, never workspace/full-access authority, and private attachment paths must not enter generic turn metadata.
