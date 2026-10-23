---
title: "SRP Tier 2 — Agent and Scripts Decomposition"
description: "Split the remaining oversized Agent owners into cohesive per-responsibility files behind unchanged public APIs, cut the risky runtime wave to the files the three next features will touch, and enforce the size ratchet so no host regrows."
status: pending
current_gate: "Wave 1 dispatchable (six move-only targets)"
remaining_estimate: 100%
base_commit: 35097c4b
tier_branch: none — one pull request per item
---

# SRP Tier 2 — Agent and Scripts Decomposition

## Goal

Give every remaining oversized Agent owner exactly one responsibility, without changing behavior,
protocol, payload, persistence, or UI, and keep the host files from regrowing by enforcing the size
ratchet in CI.

Scope: `agent/`, `scripts/` (no split needed — already modular), and
`.agents/skills/delegate-task-supervisor/scripts/` (Track S only, after #280).

This is the third SRP round. `done/agent-large-file-responsibility-refactor.md` and
`done/110` + `done/113a` already decomposed the runner, orchestrator, gateway bridge, socket and cache
owners. This round covers what those rounds left in place, and it starts with the guard that the two
prior rounds lacked.

## Verified starting point (2026-10-23, `origin/main` @ `35097c4b`)

| Fact | Evidence |
|---|---|
| The second round merged two days before this plan | `adc128ec` (#237), plans `done/110` and `done/113a` |
| Files regrew after that merge | compaction engine 1,511 → 2,026 in one commit (`#247`); `agent_state_database` 1,487 → 1,635; orchestrator 1,767 → 1,847; query handler 1,406 → 1,482; workspace handler 1,148 → 1,225; runner 2,016 → 2,025 |
| 24 Agent `lib` files exceed 1,000 lines | `agent/test/guards/file_size_ratchet_guard_test.dart` allowlist |
| Two Agent files that the source report missed are the real outliers | `session_query_handler.dart` has one 610-line method; `supervisor.mjs` is 4,837 lines today and 5,528 after #280, with one 1,632-line function |
| The report's Agent test path does not exist | it says `test/interfaces/sanad_gateway/`; the suites live in `test/interfaces/platforms/sanad_gateway/` |
| A written contract forbids splitting the workspace/MCP owner by convenience | `agent/lib/interfaces/platforms/sanad_gateway/AGENTS.md` ("Keep workspace and MCP commands in the single workspace command owner …") — amended by item 138-07 only |

## Binding decisions

Every decision below is already approved and is not re-opened here.

| Decision | Landing |
|---|---|
| 1. Size ratchet | `agent/test/guards/file_size_ratchet_guard_test.dart` — landing in this PR, 24 allowlisted files, 1,000-line limit for everything else |
| 2. Rule placement | one law in `AGENTS.md` §3 plus an Agent Definition-of-Done line; not in the private root contract |
| 3. Move-only PRs | every item here moves bodies verbatim; behavior fixes go to their own task |
| 4. Extracted units | separate libraries, feature-specific public names, `@internal` where not reusable, no `part`; typed callbacks where state ownership matters |
| 5. Old import paths | `core/config.dart` and `agent_state_database.dart` keep their path as re-export/facade; low fan-in files update all importers in the same PR; public class names never change |
| 6. Verification bar | per-wave bar below |
| 7. Delivery shape | one PR per item, tracked by this plan; disjoint items run in parallel |
| 8. Feature coordination | file locks below |
| 9. Scope before features | all of Waves 1–2, then only the Wave-3 files the next features touch |
| 10. Implementer | Sanad implements; an independent reviewer signs every PR; agy only on stall |
| 11. Plan identity | this plan plus `113b-srp-tier2-client-presentation.md`, with this documentation/guard PR first |
| A1 | split `workspace_command_handler` and amend the gateway contract (138-07) |
| A2 | `AgentRunner` untouched this round — deferred |
| A3 | per-domain schema modules called in today's exact order, no versioning change (138-11) |
| A4 | `supervisor.mjs` as Track S, after #280 merges |
| A5 | `provider_command_handler` characterization tests in Wave 1 (138-06) |
| A6 | `oneshot_runner` and `compaction_engine` deferred |

## Wave map

| Item | Wave | Target | New owners | Parallel lane | Preconditions |
|---|---|---|---|---|---|
| 138-01 / R3 | 1 | `core/config.dart` (1,257) | `core/config/` | config | none |
| 138-02 / R4 | 1 | `cli/runner/commands/session_command.dart` (1,853) | `cli/runner/commands/session/` | CLI | 125/134 branches checked |
| 138-03 / R12a | 1 | `capabilities/runtime/local_runtime_catalog.dart` (1,071) | `capabilities/runtime/tool_builders/` | capability | none |
| 138-04 / R12b | 1 | `engine/llm_request_dumper.dart` (1,080) | `engine/llm_payload_sanitizer.dart` | engine | none |
| 138-05 / R7a | 1 | test-only schema snapshot | `test/evolution/` fixtures | persistence | none |
| 138-06 / A5 | 1 | test-only provider characterization | `test/.../handlers/` | gateway | none |
| 138-07 / R1 + A1 | 2 | `handlers/workspace_command_handler.dart` (1,225) | 4 handlers + `handlers/support/` | gateway A | none (contract amendment included) |
| 138-08 / R5 | 2 | `sanad_protocol_bridge.dart` (1,327) | `protocol/canonical_command_translator.dart`, `handlers/session_control_command_handler.dart` | gateway A | 138-07 merged |
| 138-09 / R2 | 2 | `handlers/session_query_handler.dart` (1,482) | `handlers/session_history/` | gateway B | none |
| 138-10 / R6 | 2 | `engine/adapters/base_openai_adapter.dart` (2,016) | `engine/adapters/openai_compatible/` | engine | none |
| 138-11 / R7b | 2 | `evolution/db/agent_state_database.dart` (1,635) | `evolution/db/schema/`, `evolution/db/migrations/` | persistence | 138-05 merged |
| 138-12 / R11 | 3 | `interfaces/runtime/session_run_orchestrator.dart` (1,847) | 3 runtime owners | runtime | Wave 1–2 done |
| 138-13 / R10 | 3 | `interfaces/runtime/session_turn_executor.dart` (1,267) | 2 runtime owners | runtime | Wave 1–2 done |
| 138-14 / R8 | 3 | `sanad_gateway/local_daemon_server_platform.dart` (1,430) | `sanad_gateway/local_daemon/` | transport | Wave 1–2 done |
| Track S | after #280 | `supervisor.mjs` (4,837 → 5,528) | 6 script modules + `supervisor-worker/` | scripts | #280 merged |

Wave 1 and Wave 2 are disjoint except the two gateway lanes; all six Wave-1 items are file-disjoint
and can run concurrently.

---

## Wave 1 — move-only, low risk

### 138-01 / R3 — `core/config.dart`

- Clusters: `Config` (L12–415); `CompactionPolicy`, `ModelAwareCompactionPolicy`,
  `CompactionRecoveryPolicy` (L416–512); `ThinkingControlOverride` (L513–989);
  `ModelCapabilityOverride`, `ModelAwareRuntimePolicy` (L990–1257).
- New files: `agent/lib/core/config/compaction_policy.dart`,
  `agent/lib/core/config/thinking_control_override.dart`,
  `agent/lib/core/config/model_aware_runtime_policy.dart`.
- `agent/lib/core/config.dart` keeps `Config` and `export`s the three owners. Its path is a
  **package-root anchor** for `test/guards/cli_help_contract_test.dart`,
  `test/guards/oneshot_standalone_probe_contract_guard.dart`, and
  `test/guards/test_daemon_provider_startup_contract_guard.dart`; it must not move.
- 106 importers stay untouched. Focused tests: `test/core/config_test.dart` plus every
  thinking/model-policy suite that imports `core/config.dart`.

### 138-02 / R4 — `session_command.dart`

- Clusters: `SessionCommand` (L54–338) and ten subcommands — list, show, stop, compact, answer,
  permission, steer, retry, new, delete.
- New files under `agent/lib/cli/runner/commands/session/`: `session_subcommand_base.dart`
  (`SessionSubcommandBase`, the public form of `_BaseSessionSubcommand`),
  `list_command.dart`, `show_command.dart`, `stop_command.dart`, `compact_command.dart`,
  `answer_command.dart`, `permission_command.dart`, `steer_command.dart`, `retry_command.dart`,
  `new_command.dart`, `delete_command.dart`.
- `SessionNewCommand` extends `SanadCommand`, not the base class; preserve that.
- `session_command.dart` keeps `SessionCommand` and exports the subcommands.
- Command options do not change, so
  `fvm dart run tool/generate_cli_relay_grammar.dart --check` must stay green and
  `agent/test/fixtures/cli_relay_grammar.json` must stay byte-identical.
- Before dispatch, check the open CLI branches for Tasks 125/134 and confirm they do not touch this
  file.
- Focused tests: `test/cli/session_command_test.dart` (2,536), `test/guards/cli_help_contract_test.dart`,
  `test/cli/*acknowledgement_test.dart`.

### 138-03 / R12a — `local_runtime_catalog.dart`

- New files under `agent/lib/capabilities/runtime/tool_builders/`: `workspace_file_tools.dart`,
  `web_tools.dart`, `ask_user_tool.dart`, `view_image_tool.dart`, `secret_tools.dart`,
  `platform_tool_specs.dart`.
- `LocalRuntimeCatalog` stays the canonical per-turn capability owner and still builds the list;
  the builders are invoked by it and do not become a second registry.
- Tool names and JSON schemas are model-visible: add a snapshot assertion over every tool name and
  schema (`test/capabilities/tool_schema_snapshot_test.dart`) so a move cannot reword a schema.
- Focused tests: `test/capabilities/runtime_catalog_test.dart`, `file_tool_responsiveness_test.dart`,
  and the 15 importing suites.

### 138-04 / R12b — `llm_request_dumper.dart`

- New file: `agent/lib/engine/llm_payload_sanitizer.dart` (key masking, image metadata, MIME sniffing,
  string sanitization — L793–1,080 of the host).
- `LlmRequestDumper.sanitizePayloadForTesting` stays as a forwarder.
- Security law applies: no part of a credential may survive sanitization.
- Focused tests: `llm_request_dumper_secrets_test.dart`, `llm_request_dumper_test.dart`,
  `compaction_dumper_isolation_test.dart`.

### 138-05 / R7a — schema snapshot characterization (test-only)

- New: `agent/test/evolution/agent_state_schema_snapshot_test.dart` and fixtures under
  `agent/test/evolution/fixtures/agent_state/`.
- Snapshots `sqlite_master`, `PRAGMA table_info`, and `PRAGMA index_list` for a fresh database and for
  three legacy fixtures: pre-workspace-UUID, pre-attachments-v2, pre-112 schedules.
- This test must pass before and after 138-11. It does not introduce `user_version`; versioned
  migrations stay a separate, unapproved task.

### 138-06 / A5 — `provider_command_handler` characterization (test-only)

- New: `agent/test/interfaces/platforms/sanad_gateway/handlers/provider_command_handler_test.dart`.
- The handler has 1,122 lines and zero direct tests; it is only reached through
  `sanad_bridge_provider*_test.dart`. Cover command routing, validation errors, readiness projection,
  and the secret-free snapshot shape before anyone splits it.

---

## Wave 2 — gateway, engine, and persistence lanes

### 138-07 / R1 + A1 — `workspace_command_handler.dart` and the contract amendment

Target: `agent/lib/interfaces/platforms/sanad_gateway/handlers/workspace_command_handler.dart` (1,225).

| New unit | Owns |
|---|---|
| `handlers/workspace_command_handler.dart` | workspace list/create/remove/tree, folder mutations, workspace security policy (`get_policy`, `set_permission_mode`) |
| `handlers/mcp_command_handler.dart` | MCP config CRUD, import/export, advanced JSON, OAuth start/status/complete/cancel, inspection |
| `handlers/capability_discovery_command_handler.dart` | skills and slash-command discovery |
| `handlers/computer_use_command_handler.dart` | computer-use permissions |
| `handlers/support/managed_command_admission.dart` | the shared managed/cloud admission decisions and confirmation-fingerprint helpers used by all four handlers |
| `handlers/support/agent_event_envelope.dart` | `buildAgentEventEnvelope`, so handlers stop importing the bridge (removes today's handler → bridge back-edge) |

Single-owner rules that the split must not break:

- Cloud admission semantics (`cloud_admitted`, `remote_mcp_management_disabled`) stay in one place.
- `_mcpFingerprintSalt` is minted per handler instance today. The MCP handler is its only owner after
  the split; two owners minting separate salts would silently change confirmation behavior.
- Workspace policy mutation stays reachable only through the explicit policy command.

**Contract amendment** — `agent/lib/interfaces/platforms/sanad_gateway/AGENTS.md`, replacing the law
"Keep workspace and MCP commands in the single workspace command owner unless architecture
documentation explicitly replaces that ownership; do not fragment it by convenience." with:

> Separate owners hold the gateway command families: `WorkspaceCommandHandler` owns workspace
> list/create/remove/tree, folder mutations, and workspace security policy; `McpCommandHandler` owns
> MCP configuration, import/export, OAuth, and inspection; `CapabilityDiscoveryCommandHandler` owns
> skills and slash discovery; `ComputerUseCommandHandler` owns computer-use permissions. Shared
> managed/cloud admission decisions live in exactly one support owner that all four use.
> `WorkspaceMcpCoordinator` remains the single MCP runtime owner, and the MCP confirmation-token salt
> has exactly one owner — the MCP handler; never mint a second salt or duplicate an admission decision.

Focused tests: `test/interfaces/platforms/sanad_gateway/handlers/workspace_command_handler_test.dart`
(737), `test/interfaces/remote_device_control_g6_security_test.dart`,
`test/interfaces/sanad_bridge_test.dart`, and the rest of
`test/interfaces/platforms/sanad_gateway/`.

### 138-08 / R5 — `sanad_protocol_bridge.dart` (serialized after 138-07)

- New: `agent/lib/interfaces/platforms/sanad_gateway/protocol/canonical_command_translator.dart`
  (data table plus the few special cases for the 78-case command switch) and
  `handlers/session_control_command_handler.dart` (the inline session-control cases: pending-steer
  cancel, queued delete, stop-recovery acknowledgment and siblings) with explicit constructor
  dependencies — the gateway contract forbids `getIt` in handlers.
- The bridge stays dispatch-only and keeps `translateResponse`/`buildAgentEventEnvelope`.
- Risk: command authority stamping and request-id correlation
  (`test/interfaces/platforms/sanad_gateway/command_authority_test.dart`). Serialized after 138-07
  because both change bridge wiring.

### 138-09 / R2 — `session_query_handler.dart`

- New: `agent/lib/interfaces/platforms/sanad_gateway/handlers/session_history/session_history_projector.dart`
  (history projection with explicit inputs) and
  `handlers/session_history/history_row_placement.dart` (index helpers for fork markers, route
  transitions, compaction lifecycle rows).
- The handler keeps envelope assembly; `_buildHistoryEnvelope` stops being one 610-line method.
- Contract-sensitive: payload order, stable event ids, `TerminalAssistantClassifier` classification,
  and synthetic-row placement. Move first, change nothing.
- Focused tests: `test/interfaces/route_transition_anchor_test.dart`,
  `compaction_history_parity_test.dart`, `history_terminal_classification_test.dart`,
  `session_informational_event_order_test.dart`, `session_fork_command_handler_test.dart`,
  `compaction_failure_containment_test.dart`.

### 138-10 / R6 — `base_openai_adapter.dart`

- New: `agent/lib/engine/adapters/openai_compatible/model_discovery.dart` and
  `.../thinking_control_discovery.dart` — pure static extractors for model discovery/labels and for
  the vendor thinking-control rules (Kimi, LM Studio native, OpenRouter).
- Keep `BaseOpenAIAdapter.kimiThinkingControlFromDiscovery` as a static forwarder (a test calls it),
  keep the subclass overrides (`OllamaAdapter`, `CodexResponsesAdapter`), and keep sync and stream on
  the one request builder that `adapters/AGENTS.md` requires.
- Focused tests: `nim_thinking_wire_test`, `layered_thinking_authority_test`, `opencode_go_*`,
  `di_live_default_adapter_test`, and the rest of the 28 importing suites.

### 138-11 / R7b — `agent_state_database.dart` schema modules (after 138-05)

- New under `agent/lib/evolution/db/schema/`: `sessions_messages_schema.dart`,
  `attachments_schema.dart`, `scheduling_schema.dart`, `workspaces_schema.dart`,
  `runtime_work_schema.dart`, `provider_schema.dart`, `compaction_schema.dart`,
  `maintenance_schema.dart`, each exposing `static void apply(Database db)`.
- New: `schema/schema_migration_support.dart` (`safeAddColumn`, `tableExists`, `columnExists`) and
  `agent/lib/evolution/db/migrations/workspace_identity_migration.dart`.
- `_createSchemaAndMigrate` becomes an explicit ordered list calling those modules in exactly today's
  order. No `PRAGMA user_version`, no table rebuild reordering, and `readOnlyAtPath` still never
  migrates.
- Keep `AgentStateDatabase.migrateScheduledTasks` as a forwarder (three test uses) and keep the class
  path: 112 test files import it.
- Focused tests: `agent_state_database_{retry,isolation,concurrency}_test.dart`,
  `scheduled_tasks_migration_test.dart`, `session_lineage_schema_test.dart`, `codex_migration_test.dart`,
  plus 138-05's snapshot on fresh and legacy fixtures.

---

## Wave 3 — runtime splits cut by the next features

Wave 3 is not a fixed list. It contains only the files that Task 54 and the two unwritten features
will touch; everything else in the study's Wave 3 stays deferred.

| Grep target | Needed by | Wave | Why |
|---|---|---|---|
| `handlers/workspace_command_handler.dart` | none | 2 | 54a–54h never touch workspaces or MCP; the A1 split is Wave 2 because Wave 2 finishes before features |
| `handlers/session_query_handler.dart` | 54g | 2 | `buildDeleteSessionEnvelope` (L1,082) is where `delete_session` runs `_sessionManager.deleteSession`; 54g G2 needs the non-terminal preflight and cancel-all before that deletion |
| `sanad_protocol_bridge.dart` | 54e, Notifications | 2 | 54e adds task commands/events to the command dispatch and gateway-owned handlers; notifications add a canonical event the bridge translates |
| `session_run_orchestrator.dart` | 54d, internal sub-agents | 3 | 54d names this exact path for typed wake admission; the orchestrator is the sole admission/active-run authority any nested sub-agent run must pass |
| `session_turn_executor.dart` | 54d | 3 | `commitPendingSteerDelivery` (L1,086–1,174) is the `delivering → delivered` CAS that a typed wake promotion extends |
| `local_daemon_server_platform.dart` | Notifications | 3 | `sendResponse` plus `DeliveryScope` fan-out (L1,168–1,305) is the delivery path a new notification event uses for local and remote desktop; web/mobile consume the same canonical event through cloud egress |
| `capabilities/runtime/local_runtime_catalog.dart` | 54c, internal sub-agents | 1 | the catalog is the canonical per-turn capability owner, so background-task tools (54c C2) and internal sub-agent tools register there |
| `engine/context/context_compaction_engine.dart` | none | deferred | Task 118 owns the file (`in_progress`); no next feature touches it |
| `engine/agent_runner.dart` | internal sub-agents (risk) | deferred | A2: it was decomposed two days ago; today's `delegate_task_tool.dart` constructs an `AgentRunner` directly, and correcting that is the feature's own PR, not a split |

### 138-12 / R11 — `session_run_orchestrator.dart`

- New: `agent/lib/interfaces/runtime/session_input_classifier.dart` (the pure immediate/queued/steer
  classification from L930–1,256, returning a typed decision while the orchestrator performs every
  mutation), `session_command_outcome_publisher.dart` (L585–716), and
  `session_compact_admission.dart` (L716–865).
- The orchestrator keeps sole admission and active-run authority, generation ownership, stop
  invalidation, and the `steer_only → no_active_turn` law.
- Feature dependency: 54d ("Waiting for 54a") lists this file; it must not be split while 54d is in
  flight, so this item is its gate. Internal sub-agents need the same admission gate for a nested run.
- Verification: Wave-3 bar, including `compaction_queue_integration_test`,
  `compaction_preflight_integration_test`, `gateway_manager_error_containment_test`,
  `session_turn_replay_command_handler_test`, and daemon-backed E2E.

### 138-13 / R10 — `session_turn_executor.dart`

- New: `agent/lib/interfaces/runtime/turn_event_publisher.dart` (tool events, thought/reasoning
  deltas, in-flight snapshot, completed steer segment — L872–1,086) and
  `session_title_refresher.dart` (L1,203–1,267).
- `commitPendingSteerDelivery` stays in the executor: it owns the durable steer delivery commit.
- Feature dependency: 54d D2 promotes a typed wake "at the first safe boundary with CAS
  delivering/delivered", which is this owner.
- Event ordering is contract-level (live root `user_message` only after the durable commit; media
  completion after durability). Verify with `attachment_replay_boundary_test`,
  `thinking_selection_rejection_test`, `pre_start_failure_queue_release_test`,
  `media_tool_event_ordering_test`, `session_informational_event_order_test`.

### 138-14 / R8 — `local_daemon_server_platform.dart`

- New: `agent/lib/interfaces/platforms/sanad_gateway/local_daemon/http_control_routes.dart`
  (`/health`, `/update`, `/logs`, `/restart`, `/shutdown`, `/stop`, `/auth/*`, `/capabilities`) and
  `local_daemon/local_media_stream_handler.dart` (attachment and `view_image` media streaming).
- The platform keeps socket lifecycle, authentication, response fan-out, delivery scopes, and voice.
- Feature dependency: Notifications needs a canonical event delivered to local and remote desktop
  clients through the existing delivery scopes; that change lands on top of the extracted routing so
  `/restart`, `/shutdown`, and `/stop` keep their own tests.
- Verification: daemon-backed E2E plus a live Test-Home check of restart, stop, shutdown, media.

---

## Track S — `supervisor.mjs` (starts after #280 merges)

`#280` (B16, `fix/supervisor-follow-session-after-exit`) is open and rewrites this file. Do not touch
`supervisor.mjs` before it merges; today it is 4,837 lines, after #280 it is 5,528, and `workerCommand`
alone is 1,632 lines. #267 already added `supervisor-events.mjs` and `supervisor-retry.mjs`, which this
track continues.

Target layout under `.agents/skills/delegate-task-supervisor/scripts/`:

| New module | Owns |
|---|---|
| `supervisor-spec.mjs` | `validateTask` / `validateSpec` |
| `supervisor-registry.mjs` | run identity, registry, paths |
| `supervisor-windows.mjs` | Windows broker and handshake |
| `supervisor-control.mjs` | `sendControlRequest`, add/enqueue/continue/steer/retry/cancel/close |
| `supervisor-views.mjs` | status, inspect, timeline, logs, view, watch |
| `supervisor-worker/*.mjs` | the `workerCommand` split: scheduler loop, launcher, follower, reconcile |

Two PRs, in order: pure modules first, worker second. Tests:
`.agents/skills/delegate-task-supervisor/test/{supervisor_test,retry_policy_test,process_guard_test,bootstrap_test}.mjs`.
Track S is independent of Waves 1–3 and has no feature dependency.

---

## Deferred

| Item | Why |
|---|---|
| A2 `engine/agent_runner.dart` | decomposed in #237; the remainder is the dispatch loop the runtime contract assigns to the host, host-interface accessors created by that split, and callback adapters. The report's three proposed classes duplicate existing owners and would break "the runner solely owns `history`". Revisit only if the callback adapters become a measured problem |
| A6 `cli/oneshot/oneshot_runner.dart` | changed by #278, and `test/guards/oneshot_standalone_probe_contract_guard.dart` asserts on this file's source text, so moving code out would silently weaken the guard |
| A6 `engine/context/context_compaction_engine.dart` | Task 118 (`in_progress`) owns the file; no next feature touches it |
| `base_anthropic_adapter.dart` | runner-up from the study; no next feature touches it |
| `session_execution_state_coordinator.dart`, `compaction_boundary_repository.dart`, `schedule_model.dart`, `local_gateway_cli_client.dart`, `tool_execution_coordinator.dart`, `linux_service_manager.dart` | one cohesive owner each by contract; size is many cohesive methods, not mixed concerns |
| `handlers/provider_command_handler.dart` split | blocked on 138-06 characterization tests and has no next-feature need |
| `scripts/sanad_dev/**` | already decomposed, largest file 680 lines |
| `scripts/flutter_driver_cli/flutter_vm_controller.dart` | dev tooling changed by #266; its tests live in the Client package |

## Feature dependency gates (decision 9 and the 2026-10-23 user decisions)

Large features wait for the SRP work this table names. Task 54 (54a–54h) and the two unwritten
features do not start a work item before its prerequisite lands.

| Feature work item | Needs first |
|---|---|
| 54a background task schema | 138-11 (schema modules) — it adds `background_tasks` and `session_wake_triggers` to a class that is otherwise a single 1,635-line DDL block |
| 54c shell handoff and task tools | 138-03 (catalog builders) — the task tools register in the canonical per-turn capability owner |
| 54d timer wake and typed pending steer | 138-12 and 138-13 — the orchestrator admission path and the steer delivery CAS |
| 54e background task protocol | 138-08 and the Wave-2 gateway lane — task commands/events are translated by the bridge and handled by gateway handlers |
| 54f conversation background task panel | Client `113b` Wave 1–2 (its integration point is the composer host; no Agent split) |
| 54g global activity monitor and owned session deletion | 138-09 (delete envelope) and client `113b` 113-10 (the transport file that owns `deleteSession`) |
| Notifications (agent → client, local/remote/web/mobile) | 138-14 and 138-08 — the notification is a canonical event delivered through the gateway fan-out |
| Internal sub-agents (a Sanad-owned supervisor tool) | 138-03, 138-12 — tool registration plus run admission; `AgentRunner` stays untouched (A2) |

## File-lock coordination (decision 8)

- Every open SRP PR declares its complete file set in the PR body and in the progress ledger below.
  A feature PR may not modify a file that an open SRP PR owns; everything else proceeds normally.
- **Lock acquired when the PR opens, released when it merges or closes.** A move-only PR is small and
  short-lived by design; if a lock must live longer than a few days, the item is re-scoped rather than
  held.
- **No rebase across a lock.** Do not rebase an SRP PR onto changes it conflicts with; merge the
  conflicting change first or rebase the feature. Two owners editing one host at once is exactly how
  the previous round lost behavior.
- This plan's own first PR locks only documentation, contracts, and two new test files.
- A feature that needs a locked file waits for its release, or lands its change after the SRP PR
  merges. Feature work that would grow an allowlisted file must land net-zero or shrink it — the
  ratchet says so, not a reviewer.

## Verification bar per wave (decision 6)

| Wave | Bar |
|---|---|
| 1 | `fvm dart analyze` clean; the focused suites named per item; the full Agent fast suite once on the frozen candidate; `git diff --color-moved` review |
| 2 | Wave 1 bar plus the full fast suite (engine/interface/persistence changes are broad-surface) and a `graphify update .` run |
| 3 | Wave 2 bar plus daemon-backed E2E for the runtime/transport boundary and a live acceptance pass on an isolated Test Home (restart, stop, shutdown, media, steer, queue) |
| Track S | `node --test` (or the skill's existing runner) for the four supervisor suites; a live delegated run through `sanad-dev` after the worker split |

Every gate preserves its exit code and reports command, exit code, counts, duration, and log path with
a bounded final-five-line summary. Agent and Client suites never run concurrently on one machine.

## Size ratchet (decisions 1 and 2)

- `agent/test/guards/file_size_ratchet_guard_test.dart` fails any non-generated `lib/` file over
  1,000 lines that has no allowlist entry, and fails an allowlisted file that exceeds its recorded
  count.
- Generated output is excluded: `*.g.dart`, `*.freezed.dart`, `generated_*`.
- The allowlist holds 24 files today. A split lowers the number in the same PR; a file that drops
  under 1,000 loses its entry, and the guard fails on a dead entry so the list cannot rot.
- Shared with the Client: one law in `AGENTS.md` §3 and one Definition-of-Done line per package.
  The private root contract does not mirror it.
- `scripts/` and `.agents/` are outside the `lib/` guard by design; Track S is governed by its PR
  review and this plan.

## Progress ledger

One row per item, appended by the orchestrator. Only the orchestrator edits this section.

| Item | PR | Status | Files locked | Verification |
|---|---|---|---|---|
| docs + guard (this PR) | #283 | merged `7698d2aa` | `AGENTS.md`, `agent/AGENTS.md`, `client/AGENTS.md`, plans, `docs/llms.txt`, two guard tests | see PR |
| 138-02 / R4 | #285 | merged `a4431912` | `agent/lib/cli/runner/commands/session_command.dart`, `agent/lib/cli/runner/commands/session/`, `agent/test/guards/file_size_ratchet_guard_test.dart`, `agent/AGENTS.md`, `docs/technical/sanad_cli_architecture.md`, this plan | analyzer clean; 94 + 7 + 7 focused, 11 guard tests, full fast suite, relay grammar `--check` green with an unchanged fixture; host ratchet entry removed (1,853 → 129 lines, 23 entries) |
| 138-01 / R3 | #286 | merged `17ae4117` | `agent/lib/core/config.dart`, `agent/lib/core/config/compaction_policy.dart`, `agent/lib/core/config/thinking_control_override.dart`, `agent/lib/core/config/model_aware_runtime_policy.dart`, `agent/lib/core/AGENTS.md`, `agent/lib/engine/AGENTS.md`, `agent/test/guards/file_size_ratchet_guard_test.dart`, `docs/technical/context_compaction.md` | `fvm dart analyze` clean; `test/core/config_test.dart` 40; `test/core/provider_thinking/` + `test/core/provider_runtime/` 486 +1 skip; `test/engine/adapters/` + `test/tool/generate_model_capability_defaults_test.dart` 289; `test/guards/` 11; full fast suite result posted on the PR. Ratchet: `core/config.dart` 1257 → 418, allowlist entry removed |
| 138-04 / R12b | #288 | merged `1e2b7fa4` | `agent/lib/engine/llm_request_dumper.dart`, `agent/lib/engine/llm_payload_sanitizer.dart`, `agent/lib/engine/AGENTS.md`, `agent/test/guards/file_size_ratchet_guard_test.dart`, `docs/technical/agent_runtime.md`, `docs/technical/multimodal_tool_results_and_view_image.md`, this plan | analyzer clean; 3 + 37 + 9 focused, 11 guard tests, full fast suite; sanitizer bodies moved verbatim, masking unchanged; host ratchet entry removed (1,080 → 793 lines, 22 entries) |
| 138-05 / R7a | #289 | merged `09d5c34a` | `agent/test/evolution/agent_state_schema_snapshot_test.dart`, `agent/test/evolution/fixtures/agent_state/`, `docs/technical/agent_database_schema.md`, `.gitattributes`, this plan | analyzer clean; 11 characterization tests green on three consecutive runs; 11 guard tests; full fast suite 3,706 passed / 16 skipped |
| 138-03 / R12a — catalog builders | #287 | merged `e4f5fad1` | `agent/lib/capabilities/runtime/local_runtime_catalog.dart`, `agent/lib/capabilities/runtime/tool_builders/` (6 files), `agent/lib/capabilities/AGENTS.md`, `agent/lib/capabilities/runtime/AGENTS.md`, `agent/test/capabilities/tool_schema_snapshot_test.dart`, `agent/test/guards/file_size_ratchet_guard_test.dart`, this ledger | `fvm dart analyze` clean; `runtime_catalog_test`, `file_tool_responsiveness_test`, `tool_schema_snapshot_test` 37; 13 importing interface suites 175; `test/guards/` 11; full Agent fast suite 3698 passed, 16 skipped; moved lines confirmed by `git diff --color-moved`. Ratchet: `local_runtime_catalog.dart` 1,071 → 369, allowlist entry removed |
| 138-06 / A5 | #291 | in review (test-only) | `agent/test/interfaces/platforms/sanad_gateway/handlers/provider_command_handler_test.dart`, `agent/test/interfaces/platforms/sanad_gateway/handlers/provider_command_handler_projection_test.dart`, `agent/test/interfaces/platforms/sanad_gateway/handlers/support/provider_handler_harness.dart`, `docs/qa_maintenance/provider_setup_plan29_regression_matrix.md`, this plan | analyzer clean; 47 characterization tests (30 routing/readiness/lifecycle/auth + 17 snapshot/refresh/projection) green in 3 consecutive runs; 11 guard tests; full fast suite 3,742 passed + 16 skipped; no `agent/lib/` change |
| 138-11 / R7b | #292 | in review | `agent/lib/evolution/db/agent_state_database.dart`, `agent/lib/evolution/db/schema/` (9 files), `agent/lib/evolution/db/migrations/workspace_identity_migration.dart`, `agent/test/guards/file_size_ratchet_guard_test.dart`, `agent/lib/evolution/db/AGENTS.md`, `docs/technical/agent_database_schema.md`, this plan | `fvm dart analyze` clean; 138-05 snapshot 11 unchanged (baseline 11 before the first edit); focused persistence suites 30; `test/guards/` 11; full fast suite 3,756 passed / 16 skipped; all 143 SQL literals equal as a multiset and `git diff --color-moved=plain` shows 1,198 moved-from / 2,369 moved-to lines; host ratchet entry removed (1,635 → 370 lines, 19 entries) |
| 138-09 / R2 — session history | #296 | in review | `agent/lib/interfaces/platforms/sanad_gateway/handlers/session_query_handler.dart`, `agent/lib/interfaces/platforms/sanad_gateway/handlers/session_history/` (2 files), `agent/lib/interfaces/platforms/sanad_gateway/AGENTS.md`, `agent/test/guards/file_size_ratchet_guard_test.dart`, `docs/technical/agent_runtime.md`, `docs/technical/context_compaction.md`, this ledger | `fvm dart analyze` clean; `route_transition_anchor`, `compaction_history_parity`, `history_terminal_classification`, `session_informational_event_order`, `session_fork_command_handler`, `compaction_failure_containment` 37; `test/guards/` 11; full Agent fast suite 3,709 passed / 16 skipped; `graphify update .`; moved lines confirmed by `git diff --color-moved`. Ratchet: `session_query_handler.dart` 1,482 → 683, allowlist entry removed (19 entries) |
| 138-07 / R1 + A1 — workspace/MCP split | #293 | in review | `agent/lib/interfaces/platforms/sanad_gateway/handlers/workspace_command_handler.dart`, `agent/lib/interfaces/platforms/sanad_gateway/handlers/mcp_command_handler.dart`, `agent/lib/interfaces/platforms/sanad_gateway/handlers/capability_discovery_command_handler.dart`, `agent/lib/interfaces/platforms/sanad_gateway/handlers/computer_use_command_handler.dart`, `agent/lib/interfaces/platforms/sanad_gateway/handlers/support/`, `agent/lib/interfaces/platforms/sanad_gateway/sanad_protocol_bridge.dart` (wiring only), `agent/lib/interfaces/platforms/sanad_gateway/AGENTS.md`, `agent/test/guards/file_size_ratchet_guard_test.dart`, `agent/test/interfaces/platforms/sanad_gateway/handlers/workspace_command_handler_test.dart`, `agent/test/interfaces/remote_device_control_g6_security_test.dart`, `docs/technical/agent_runtime.md`, this ledger | `fvm dart analyze` clean; `workspace_command_handler_test` 27 + `remote_device_control_g6_security_test` 2; `handlers/` 112; `sanad_bridge_test` + `platforms/sanad_gateway/` 322; `test/guards/` 11; full Agent fast suite 3,756 passed, 16 skipped (after merging `origin/main`, whose #291 adds 47 provider-handler tests; the pre-merge base ran 3,709); `graphify update .` run; moved bodies confirmed by `git diff --color-moved`. Ratchet: `workspace_command_handler.dart` 1,225 → 541, allowlist entry removed. Contract amendment A1 applied verbatim |
| 138-10 / R6 | #294 | in review | `agent/lib/engine/adapters/base_openai_adapter.dart`, `agent/lib/engine/adapters/openai_compatible/model_discovery.dart`, `agent/lib/engine/adapters/openai_compatible/thinking_control_discovery.dart`, `agent/lib/engine/adapters/AGENTS.md`, `agent/test/guards/file_size_ratchet_guard_test.dart`, `docs/technical/provider_protocol.md`, this ledger | `fvm dart analyze` clean; all 28 importing suites green (111 + 285 + 36); `test/guards/` 11; full Agent fast suite 3,756 passed, 16 skipped after merging `origin/main`; moved bodies confirmed by `git diff --color-moved` and a sorted code-line multiset diff. Ratchet: `base_openai_adapter.dart` 2,016 → 1,515 |
| 138-08 / R5 — bridge command translation and session control | #299 | in review | `agent/lib/interfaces/platforms/sanad_gateway/sanad_protocol_bridge.dart`, `agent/lib/interfaces/platforms/sanad_gateway/protocol/canonical_command_translator.dart`, `agent/lib/interfaces/platforms/sanad_gateway/handlers/session_control_command_handler.dart`, `agent/lib/interfaces/platforms/sanad_gateway/AGENTS.md`, `agent/test/guards/file_size_ratchet_guard_test.dart`, `docs/technical/agent_runtime.md`, `docs/technical/agent_interface_runtime.md`, `docs/plans/tasks/139-client-schedules-screen.md`, `docs/plans/tasks/140-client-secrets-screen.md`, this ledger | `fvm dart analyze` clean; `task36_protocol_test` + `test/capabilities/command_authority_test.dart` 15; `sanad_bridge_test` 50; `test/interfaces/platforms/sanad_gateway/` 272; the 10 other bridge-importer suites 131; `test/guards/` 11; full Agent fast suite 3,756 passed, 16 skipped; `graphify update .` run; the translator accepts the same 84 commands with the same canonical type, session binding, and device-directed merge as the removed switch, and the four moved session-control bodies are token-identical apart from their injected dependencies. Ratchet: `sanad_protocol_bridge.dart` 1,325 → 813, allowlist entry removed (16 entries) |
| Track S1 — `supervisor.mjs` pure modules | #307 | in review | `.agents/skills/delegate-task-supervisor/scripts/supervisor.mjs`, `scripts/supervisor-core.mjs`, `scripts/supervisor-registry.mjs`, `scripts/supervisor-spec.mjs`, `scripts/supervisor-windows.mjs`, `scripts/supervisor-control.mjs`, `scripts/supervisor-views.mjs`, `scripts/supervisor-watch.mjs` (7 new), `.agents/skills/delegate-task-supervisor/SKILL.md`, `docs/agent_engine/sanad_delegate_relay.md`, this ledger | `node --test .agents/skills/delegate-task-supervisor/test/*_test.mjs` exit 0, 90 passed / 0 failed, equal to the `main` baseline recorded before the first edit (90/90); `node --check` on all eight changed `.mjs` files; `fvm dart run scripts/lint_wiki.dart` exit 0; `graphify update .`; `supervisor.mjs` 5,974 → 3,128 lines and every new module under 1,000 (largest `supervisor-views.mjs` at 822); 5,618 of 5,619 original body lines byte-identical, 67 `export ` prefixes, and one documented `SCRIPT_PATH` base change; the plan's five-module table needed `supervisor-core.mjs` (coordinator-approved shared layer) and `supervisor-watch.mjs` because views-with-watch is 1,416 lines |

## Definition of Done

- Every Wave-1 and Wave-2 item is merged, and every Wave-3 item that a feature needs is merged before
  that feature starts.
- Each target keeps one purpose and delegates every extracted responsibility to exactly one owner;
  public API reachable with unchanged names and signatures.
- No behavior, protocol, payload, persistence, UI, or localization change in any move-only PR.
- Analyzer clean and focused suites at or above baseline counts per item; full fast suite per wave.
- The owning `AGENTS.md` and `docs/technical/*` pages describe the final ownership, with stale
  statements removed.
- `graphify update .` after each code PR.
- The size ratchet is green, its allowlist includes only real files, and no number was raised.
