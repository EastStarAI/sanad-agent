# Sanad Agent Contract

## Scope
This contract applies to `agent/`.

## Mission
- Implement only behavior explicitly requested or already established by source and current contracts; do not invent policy during maintenance.
- Keep the daemon runtime-authoritative for execution, provider state, tools, recovery, persistence, and client-facing runtime queries.
- Preserve clear dependency direction from entry-point composition to interfaces, engine, capabilities, evolution, core, and infrastructure owners.
- Keep local and cloud transports independent while sharing canonical protocol behavior.
- Keep architecture in `docs/` and operational procedures in agent skills; do not duplicate either in runtime contracts.

## Package Boundaries
- `agent/bin/` owns CLI, daemon, setup, service, and supervisor composition only.
- `agent/lib/core/` owns configuration, identity/auth, provider runtime, shared models, and dependency composition contracts.
- `agent/lib/engine/` owns provider-neutral model execution, adapters, prompt assembly, tools loop, steering, and model-step state.
- `agent/lib/capabilities/` owns tool/skill/MCP catalogs, runtime context, permission policy, and tool execution contracts.
- `agent/lib/evolution/` owns sessions, memory, scheduling, titles, and durable runtime state.
- `agent/lib/interfaces/` owns platform adapters, gateway delivery, admission/orchestration, and canonical client protocols.
- `agent/lib/infrastructure/` owns OS/platform and voice infrastructure implementations.
- `agent/lib/plugins/` owns generic lifecycle hooks only.

## Critical Cross-Domain Invariants

### Execution and Recovery Authority
- `SessionRunOrchestrator` is the sole admission and active-run authority. Durable work state decides running versus queued; in-memory busy, queue, suspension, and cancellation maps are projections only.
- Every turn is owned by session id, work-item id, immutable run id, and generation. Only the current owner may emit callbacks, commit terminal state, clear busy ownership, or drain queued work.
- Final delivery occurs only after a successful idempotent durable terminal commit for the exact owner.
- Stop invalidates the active owner before awaiting cancellation and atomically releases recovery, durable work, and owned queued state without deleting newer-generation input.
- Retry, resume, route change, and automatic failover require an atomic claim of the current durable owner; stale or concurrent losers are controlled no-ops.
- Crash recovery replays only tools whose own persisted contract explicitly marks restart re-execution safe; ambiguous work becomes visible and controllable blocked recovery.
- A resumable daemon shutdown must cross the global checkpoint drain and exit without session-wide Stop so startup recovery retains safe non-terminal work. Destructive shutdown requires an explicit cancellation mode and terminalizes owned work before exit.

### Engine and Context Authority
- `AgentRunner` is the single owner of conversation history, current-turn boundary, model loop, latest usage projection, and model-step lifecycle.
- Engine runtime collaborators mutate history through callbacks and cannot keep parallel history or current-turn state.
- `AgentContextAssembler` emits one system message ordered stable identity, workspace context, then volatile memory/date/runtime metadata.
- Provider adapters remain stateless and own wire translation only. Provider-specific endpoint/codec behavior must not leak into the runner.
- Context-pressure recovery after daemon restart may reuse persisted provider input usage only after the active adapter remeasures the exact historical request prefix; the next request must still prove a strict wire extension on the same route.
- Visible reasoning, final content, opaque provider continuation state, finish reason, and tool calls remain distinct typed data across streaming and persistence.

### Protocol and Platform Authority
- `GatewayManager` routes typed delivery policy; it does not inspect event names to infer delivery or runtime meaning.
- `SanadProtocolBridge` dispatches/translates shared local/cloud canonical protocol. Focused handlers own workflows and receive dependencies explicitly rather than resolving hidden runtime owners.
- Local and cloud Sanad transports remain independent adapters. Failure of one cannot stop the other or terminate the daemon event loop.
- The cloud path is outbound; the local daemon path is an inbound loopback server on a configured dynamic port.
- Runtime-rich turn input enters through typed interface models with explicit device, session, request, workspace, provider/model, thinking, origin, and delivery intent.
- Workspace browsing, MCP, skills, slash commands, provider runtime, device settings, and session queries are daemon-owned services; clients render results but never become their source of truth.

### Persistence and Identity Authority
- Durable sessions, work items, notices, pending input, provider metadata, and route transitions use one shared agent-state database connection with one repository owner per table.
- Admission, terminal commit, failover, stop cleanup, and cross-table execution transitions remain transactional through their aggregate owner.
- `hardware_id` is persistent local machine identity and is distinct from backend-assigned device ids.
- `run_id` owns execution, `model_step_id` owns one model invocation, `tool_call_id` pairs tool use/result, raw `request_id` owns command correlation, and opaque `event_id` owns one canonical semantic event. `message_id` owns one persisted history record, `turn_id` owns one execution attempt's history records, and `history_revision` owns compare-and-swap for active-history mutations. Never substitute these identities for one another, for SQLite row ids, or for hydration indexes.
- A live root `user_message` is published only after its durable history row commits, and it carries the same message/turn/request identity and replay eligibility that subsequent history hydration exposes.
- Sanad auth, provider OAuth, provider secrets, durable state, and mutable worktree state remain separate storage concerns.

### Provider and Capability Authority
- The provider runtime is the sole authority for templates, instances, credentials status, model discovery, readiness, defaults, rate limits, and failover policy.
- Provider setup is instance-first. Only a successfully verified current revision may be ready or default; metadata/credential changes that invalidate verification demote readiness.
- `ToolsRegistry` and `LocalRuntimeCatalog` are the canonical execution/search and per-turn capability owners. `AgentRunner` executes their output but does not construct workspace, MCP, skill, web, or platform catalogs.
- `PermissionManager` alone enforces sensitive approvals and persists suspension before waiting. UI/platform responses cannot bypass policy or grant ownership.

## Global Runtime Laws
- Use `fvm` for every Dart operation.
- Keep `SANAD_HOME` stable for machine identity, auth, provider credentials, base configuration, and durable user-owned files.
- `sanad-dev` linked-worktree runs provide one isolated `SANAD_HOME` containing identity, credentials, sessions, memories, and request dumps; they must remove inherited `SANAD_STATE_HOME`.
- External and test harnesses may still use `SANAD_STATE_HOME` to redirect mutable state without relocating identity or provider credentials.
- Source worktrees consume global Sanad configuration and must not create a competing repository-local `.env`.
- Do not create hidden scratch or temporary directories inside the repository.
- Missing provider configuration must not prevent daemon startup; fail lazily when an LLM operation actually requires a provider.
- Local/offline provider configurations remain valid and must not require an OpenAI-style key.
- Sensitive payloads, tokens, provider secrets, pending steer text, and recovered draft text must not enter logs.
- Platform failures and asynchronous command failures must be contained so one transport cannot terminate the daemon or other interfaces.

## Development and Testing Requirements
- Analyze every code change with the FVM-managed Dart analyzer before completion.
- Run focused unit tests for the changed owner and every directly affected contract boundary.
- Run the full fast suite for broad engine, interface, provider-runtime, persistence, capability-registry, or shared-model changes.
- Require daemon-backed E2E only when mocks cannot validate the boundary: local/cloud socket contracts, daemon bootstrap/lifecycle, persistent runtime state and restart recovery, provider readiness/model execution, worktree runtime isolation, or end-to-end session execution.
- When interface/runtime ownership changes affect the local daemon contract, add or update real daemon-backed coverage rather than relying only on mocks.
- Every spawned test daemon uses a unique temporary `SANAD_STATE_HOME`, cleans it after shutdown, and preserves the normal shared identity/configuration boundary.
- Daemon-backed tests use the deterministic E2E provider and must never inherit the live agent database, invoke the user's configured provider, or mutate user runtime state.
- Documentation-only contract changes require documentation generation/lint integrity but do not require Dart analysis or runtime tests unless source code also changes.

## Definition of Done
- Ownership and dependency boundaries remain intact with no duplicate state authority.
- Relevant focused tests cover behavior and failure/recovery paths.
- Analyzer and required test scope pass.
- Full-suite and E2E results are reported only when required by the blast-radius rules above.
- Runtime-law changes update the nearest contract and active design documentation in the same session.
