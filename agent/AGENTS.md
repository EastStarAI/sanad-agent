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
- `agent/tool/` owns release preparation and contract tooling. It is the single writer of tracked release-identity literals, including the `sanad-client` CLI version constant, so release identity is never advanced by hand.
- Generated-source tooling stays platform-neutral: manifest paths are validated in the POSIX context and joined with the platform separator, and every generated file or embedded asset is compared and hashed as canonical LF text, so Windows `core.autocrlf` checkout behavior can never report a clean tree as stale or embed different bytes per platform. `.gitattributes` pins `eol=lf` for those byte-sensitive paths.
- `agent/lib/plugins/` owns generic lifecycle hooks only.

## Critical Cross-Domain Invariants

### Execution and Recovery Authority
- `SessionRunOrchestrator` is the sole admission and active-run authority. Durable work state decides running versus queued; in-memory busy, queue, suspension, and cancellation maps are projections only.
- Every turn is owned by session id, work-item id, immutable run id, and generation. Only the current owner may emit callbacks, commit terminal state, clear busy ownership, or drain queued work.
- Final delivery occurs only after a successful idempotent durable terminal commit for the exact owner.
- Stop invalidates the active owner before awaiting cancellation and atomically releases recovery, durable work, its durable interactive-wait checkpoints, and owned queued state without deleting newer-generation input. A stop also releases the in-memory partial-stream (`in_flight`) projection of the owner it stopped, so no runtime or query projection may keep reporting a stopped session as `running`; a blocked or waiting recovery releases that projection for its own run in the same way.
- Retry, resume, route change, and automatic failover require an atomic claim of the current durable owner; stale or concurrent losers are controlled no-ops.
- Crash recovery never replays a started tool without a durable result. Owned recognized checkpoints receive a neutral unknown-outcome result and continue automatically; only ownerless, malformed, or unrecognized state becomes blocked recovery.
- A resumable daemon shutdown must cross the global checkpoint drain and exit without session-wide Stop so startup recovery retains safe non-terminal work. Destructive shutdown requires an explicit cancellation mode and terminalizes owned work before exit.
- A managed daemon stop (`DaemonRestartCoordinator.stop()`) preserves unresolved interactive user-input waits (`system_ask_user` and tool-permission prompts awaiting decision) with their durable checkpoints intact and transitions active work to durable `waiting` without synthetic tool results or session cancellation, so startup recovery restores the pending decision. Explicit user stop continues to terminalize interactive waits.

### Engine and Context Authority
- `AgentRunner` is the single owner of conversation history, current-turn boundary, model loop, latest usage projection, and model-step lifecycle.
- Engine runtime collaborators mutate history through callbacks and cannot keep parallel history or current-turn state.
- `AgentContextAssembler` emits one system message ordered stable identity, workspace context, then volatile memory/date/runtime metadata.
- Provider adapters remain stateless and own wire translation only. Provider-specific endpoint/codec behavior must not leak into the runner.
- Context-pressure recovery after daemon restart may reuse persisted provider input usage only after the active adapter remeasures the exact historical request prefix; the next request must still prove a strict wire extension on the same route.
- Visible reasoning, final content, opaque provider continuation state, finish reason, and tool calls remain distinct typed data across streaming and persistence.
- On echo-required Chat routes targeting thinking mode, same-route assistant tool turns replay the destination's interleaved reasoning field (empty string when the producer gave none) to satisfy provider protocol, while foreign and unrecorded turns remain unpadded.

### Protocol and Platform Authority
- `GatewayManager` routes typed delivery policy; it does not inspect event names to infer delivery or runtime meaning.
- `SanadProtocolBridge` dispatches/translates shared local/cloud canonical protocol. Focused handlers own workflows and receive dependencies explicitly rather than resolving hidden runtime owners.
- Local and cloud Sanad transports remain independent adapters. Failure of one cannot stop the other or terminate the daemon event loop.
- Hosted attachment/media admission requires `supports_attachments=true`; each relay envelope independently requires `version: "v1"`. Binary bytes travel only in bounded relay chunks and never in canonical commands/events, logs, or durable public state.
- The hosted relay must stay bound to the live cloud socket. `io.io()` reuses one cached `Socket` per host whose `dispose()` clears every listener, so disposing the cloud socket (authorization loss, shutdown) must also forget the relay binding; otherwise the identity check in `initialize()` keeps the relay detached and relay events are dropped silently for the life of the process.
- The cloud path is outbound; the local daemon path is an inbound loopback server on a configured dynamic port.
- Runtime-rich turn input enters through typed interface models with explicit device, session, request, workspace, provider/model, thinking, origin, and delivery intent.
- Workspace browsing, MCP, skills, slash commands, provider runtime, device settings, and session queries are daemon-owned services; clients render results but never become their source of truth.

### Persistence and Identity Authority
- Durable sessions, work items, notices, pending input, provider metadata, and route transitions use one shared agent-state database connection with one repository owner per table.
- The daemon and in-process standalone CLI acquire the same exclusive state-root ownership lease before opening the agent-state database; a second runtime fails closed and never competes for SQLite.
- A Home-selected CLI call (`--home` or `SANAD_HOME`) resolves its local-gateway endpoint from that Home's own runtime record (`.local_gateway_endpoint.json`, written by the daemon after it binds and removed on shutdown) and fails closed when the Home has no live or owner-alive record; it never falls through to the default port or the worktree port scan. Inherited `SANAD_GATEWAY_URL`, `LOCAL_GATEWAY_URL`, and `LOCAL_GATEWAY_PORT` never override a selected Home, and an explicit `--gateway-url`/`--port` target must prove the same `home_id` as the selected Home. A record and a `/health` answer are evidence, not authentication: a missing `home_id` is tolerated only on the default Home's port `58085` (pre-`home_id` daemons), never for a named Home and never for a mismatching value.
- An endpoint that answered and refused the credential is running, not absent: with a selected Home, an authentication rejection (`401`/`403`) from an explicit or recorded target is `home_identity_mismatch` with exit `78` and no WebSocket connect, while a target that never answered stays "not running" so `--standalone` still works. Endpoint-resolution failures carry their discovery code as `error_code` in the `--json` envelope, and a daemon removes its runtime record on clean shutdown only while that record still names its own pid.
- Only a starting daemon rotates a Home's local-gateway credential, and only after its ownership lease and before it listens: `.local_token.home` binds `.local_token` to that Home identity, and a missing or foreign binding migrates on the next daemon start. Every other caller (`sanad login`/logout exchange, the CLI, `sanad-dev`) reads the credential read-only and can neither create nor invalidate it; a credential bound to another Home is treated as absent rather than presented.
- Read-only CLI inspection (`sanad schedule list`) is not a runtime: it takes no lease and opens the agent-state database only through `AgentStateDatabase.readOnlyAtPath`, never migrating or writing it. Schedule mutations stay with the daemon's `CronScheduler`.
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
- E2E tests that initialize DI/SQLite or launch an agent process must set temporary `SANAD_HOME` and `SANAD_STATE_HOME` roots explicitly; Dart child processes must receive both variables instead of inheriting the caller's values.
- In-process suites that reach the runtime home boundary redirect it with `setSanadHomeOverride` and prepare that root before building the runtime, so a clean CI runner never depends on a developer machine's already prepared Sanad Home.
- Source worktrees consume global Sanad configuration and must not create a competing repository-local `.env`.
- Do not create hidden scratch or temporary directories inside the repository.
- Missing provider configuration must not prevent daemon startup; fail lazily when an LLM operation actually requires a provider.
- Local/offline provider configurations remain valid and must not require an OpenAI-style key.
- Sensitive payloads,tokens,provider secrets,pending steer text,recovered draft text,command payloads,event/final-answer content,custom Client names,and raw Client-instance identity must not enter logs;transport diagnostics are lifecycle/type/count metadata only.
- Platform failures and asynchronous command failures must be contained so one transport cannot terminate the daemon or other interfaces.

## Development and Testing Requirements
- Analyze every code change with the FVM-managed Dart analyzer before completion.
- Run focused unit tests for the changed owner and every directly affected contract boundary.
- Run the full fast suite for broad engine, interface, provider-runtime, persistence, capability-registry, or shared-model changes.
- Require daemon-backed E2E only when mocks cannot validate the boundary: local/cloud socket contracts, daemon bootstrap/lifecycle, persistent runtime state and restart recovery, provider readiness/model execution, worktree runtime isolation, or end-to-end session execution.
- When interface/runtime ownership changes affect the local daemon contract, add or update real daemon-backed coverage rather than relying only on mocks.
- Unit tests for retry, polling, scheduling, or asynchronous delivery inject deterministic wait/control seams or await the exact emitted event; they must not sleep through production backoff, polling intervals, or padded settling windows.
- A local loopback harness never treats a released probe port as owned: it binds each attempt on a freshly reserved ephemeral port and re-reserves on an address-in-use collision, so a concurrent suite can never fail it and no fixed port is acceptable.
- Tests may never open the real Sanad Home. Home-owning stores (agent-state database, secret vault, default secret store) fail closed under the Dart test runner without explicit isolation and for the OS user's real default Home; fix a failing test by isolating it, never by weakening that guard. Tests and E2E subprocesses never reach the OS credential vault through the default secret store, and the E2E runtime refuses to start on the real default Home or without a state root separate from its identity Home.
- Every spawned test daemon uses a unique temporary `SANAD_STATE_HOME`, cleans it after shutdown, and preserves the normal shared identity/configuration boundary.
- Daemon-backed tests use the deterministic E2E provider and must never inherit the live agent database, invoke the user's configured provider, or mutate user runtime state.
- Documentation-only contract changes require documentation generation/lint integrity but do not require Dart analysis or runtime tests unless source code also changes.

## Definition of Done
- Ownership and dependency boundaries remain intact with no duplicate state authority.
- Relevant focused tests cover behavior and failure/recovery paths.
- Analyzer and required test scope pass.
- Full-suite and E2E results are reported only when required by the blast-radius rules above.
- Runtime-law changes update the nearest contract and active design documentation in the same session.
