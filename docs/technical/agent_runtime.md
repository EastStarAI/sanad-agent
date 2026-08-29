---
title: "معمارية تشغيل الوكيل المحلي"
description: "تصميم محرك تشغيل الوكيل (sanad-agent) وتركيب موجه النظام (System Prompt) للـ KV-Cache والتأمين الأمني."
---

# معمارية تشغيل الوكيل المحلي | Local Agent Runtime & Prompt Assembly Spec

This document details the internal runtime architecture of the Dart-based `sanad-agent` local daemon, including its prompt assembly mechanics, security gates, and environment-adaptive execution layer.

---

## 1. System Prompt Assembly (Three-Tier Model)

To maximize Large Language Model (LLM) processing efficiency, `sanad-agent` organizes its system prompt structure into three distinct tiers. This layout aligns with **KV-cache / Prefix-cache** mechanisms in modern LLM providers (e.g. Anthropic, OpenAI, local engines like Ollama).

By placing static instruction blocks at the top and highly volatile contents at the bottom, the API gateway can reuse cached prefix evaluations across sequential chat turns, significantly lowering latency and cost.

```
┌────────────────────────────────────────────────────────────┐
│                        STABLE TIER                         │
│   (Agent identity, SOUL.md, Persona, Environment hints)   │
│   • Changes: Never during a session                        │
├────────────────────────────────────────────────────────────┤
│                       CONTEXT TIER                         │
│   (Workspace path, local AGENTS.md laws, loaded skills)    │
│   • Changes: Only on workspace switch                      │
├────────────────────────────────────────────────────────────┤
│                       VOLATILE TIER                        │
│   (Date-only timestamp, session metadata, memory snapshot) │
│   • Changes: Every turn                                    │
└────────────────────────────────────────────────────────────┘
```

### 1.1. Stable Tier (Persona & Soul)
- **Identity Resolution:** Resolved via `AgentContextAssembler`. Callers do not need to inject a system message manually.
- **Soul Customization:** Lazily loads `~/.sanad/SOUL.md` on the first invocation. If missing, it falls back to a default helpful coding persona.
- **Prompt Injection Security Gate:** Before loading `SOUL.md` or workspace text, the runtime runs a sanitization check searching for common injection phrases (e.g., `ignore previous instructions`, `system prompt override`). If detected, the block is discarded and replaced with a warning flag.
- **Length Truncation:** To protect token budgets, if a custom Soul file exceeds the 20,000 character limit, it undergoes **Head+Tail Truncation** (preserving 70% head and 30% tail with a middle marker) rather than a simple hard cut.

### 1.2. Context Tier (Local Laws & Skills)
- **Workspace Ingestion:** Managed via `RuntimeContextBuilder`. Reads root `AGENTS.md` and child directory laws inside the targeted folder structure.
- **Instruction budgets:** Restricts total character limits. If files exceed limits, head+tail truncation isolates the middle part, preserving directory constraints and skill summaries.
- **No Volatile Variables:** The context builder must not include time stamps or turn indices, ensuring the assembled block remains byte-identical between messages.

### 1.3. Volatile Tier (Turn Metadata & Memory)
- **Date-Only Precision:** To prevent cache misses on every minute, the system time is formatted as a date-only stamp (`YYYY-MM-DD`). 
- **Active Metadata:** Includes the current `session_id`, `model_name`, and `provider`.
- **Short-Term Memory:** Stashes localized context and history keys extracted from the database or state repositories.

### 1.4. Provider usage snapshots

`MetricsTracker` keeps accumulated usage for internal turn-level accounting and a
separate latest-invocation view for presentation. The latest view is replaced
whenever a provider response carries usage. It normalizes provider aliases but
does not infer absent totals, retain fields from an older invocation, or combine
values across tool rounds.

After a model invocation completes, `AgentRunner` creates one immutable
`context_usage` projection for its model step. `SessionTurnExecutor` persists
that projection on the matching assistant message and in session metadata, then
sends it with the eligible tool-use or terminal event. Context occupancy uses
the provider-reported input value and the exact active model's context-window
limit. Cached input remains an independent provider-reported value and is not
used to rewrite any other field.

---

## 2. Environment Adaptability (`EnvironmentHints`)

The daemon runs natively across Windows, macOS, Linux, and WSL (Windows Subsystem for Linux). It uses a dynamic supervisor (`EnvironmentHints`) to adjust execution behaviors.

### 2.1. WSL (Windows Subsystem for Linux) Detection
- **Detection Method:** Inspects environment variables (`WSL_DISTRO_NAME`, `WSL_INTEROP`) or reads `/proc/version`.
- **Path Translation:** Translates path targets between the Windows host (e.g. `C:\Users\username\...`) and the WSL mount system (e.g. `/mnt/c/Users/username/...`).

### 2.2. Windows Native Shell Guidance
- **Shell Rule:** On native Windows, terminal tool executions route through the native Command Prompt interpreter (`cmd.exe`). Unix-like hosts continue to use `sh`.
- **Command Resolution:** Windows commands use normal `PATHEXT` lookup, so globally installed batch launchers such as `fvm.bat` can be invoked as `fvm`. Commands execute from a temporary batch wrapper so nested quotes reach `cmd.exe` unchanged.
- **Syntax Adjustments:** The runtime prompt tells the model to use cmd syntax and native Windows paths. It does not advertise PowerShell cmdlets or POSIX-only shell syntax on native Windows.

---

## 3. Tool Discovery and MCP Architecture

`sanad-agent` hosts its own local tool execution registry and integrates with the Model Context Protocol (MCP) to access external modules.

```
                     ┌───────────────────────┐
                     │   Agent Loop Runner   │
                     └───────────┬───────────┘
                                 │
                     ┌───────────▼───────────┐
                     │ Local Tool Registry   │
                     └─────┬───────────┬─────┘
                           │           │
         ┌─────────────────▼─┐       ┌─▼─────────────────┐
         │ Built-in Commands │       │    MCP Clients    │
         │ (Files, Terminal) │       │ (SQLite, Git, etc)│
         └───────────────────┘       └───────────────────┘
```

- **Runtime Query Interface:** The client requests tool specs and folder structures directly from the daemon via Socket.IO endpoints (e.g. `browse_workspace_tree`). The client is treated as a presentation layer and does not read local folders or parse `.agent/skills/` configurations itself.
- **Workspace Tools:** `LocalRuntimeCatalog` assembles per-turn workspace tools from dedicated handlers in `agent/lib/capabilities/runtime/workspace_tools/`:
  - `file_read`, `file_write`, `file_edit`, `search_glob`, `search_grep`, and `shell_execute` each run from their own handler class.
  - `search_grep` normalizes regex alternation patterns so both grep-style escaped pipes (`\|`) and raw pipes (`|`) are treated as regex alternation. The `glob` parameter uses `grep -r --include` semantics: it matches both full relative paths and basenames, and expands brace alternatives such as `*.{dart,ts}`. Malformed regex patterns fall back to literal search.
  - Workspace search tools are `restartReplaySafe` since they are read-only.
- **Offline / Local Engine Support:** The daemon operates fully in offline environments when paired with local LLM engines (Ollama, LM Studio, or llama.cpp). Tool execution and wizard validation connect via fast HTTP version checks to avoid trigger-happy timeouts caused by local GPU/VRAM spin-up latency.
- **Wizard Setup:** The configuration wizard cleans imported API keys of common non-ASCII characters or smart quotes (which crash standard HTTP client headers) and uses arrow-key selection to discover models.

## 4. Provider Instance Routing (Plan 29)

The runtime resolves the LLM adapter from a `RouteSignature` keyed by
`provider_instance_id` (UUID). The routing contract is **fail-closed**:

- A turn/session may carry an explicit `provider_instance_id`. The runtime looks
  up that instance by UUID and throws a clear error if it is missing — there is
  **no fallback to OpenAI or any other provider** (criterion 13).
- When no instance id is supplied, the runtime uses the **default instance only**
  (`ProviderInstanceRepository.findDefault()`). It does **not** fall back to the
  first repository row. A missing default produces a clear "no default provider
  instance is set" error rather than silently routing through an unrelated
  account (criterion 24).
- Each instance gets its own cached adapter; two instances of the same template
  never share a credential or adapter. Invalidation is per-instance after an
  edit, so editing one account never disturbs the others.
- The reserved `custom` template is still routed by the persisted instance
  protocol. A custom instance saved as `anthropic_compatible` must build an
  Anthropic-shaped adapter/profile end-to-end (`/messages`, `x-api-key`,
  Anthropic model normalization) instead of falling back to the template's
  default OpenAI-style API mode.
- `status == 'ready'` means credential + endpoint + model are all resolved. A
  credential-only change (OAuth token saved, API key replaced) does **not** mark
  an instance ready until a model is also selected (`markReadyIfComplete`).

---

## 5. Durable Work State Machine & Restart Restoration (Plan 30)

### Authoritative Run Ownership

Every live session turn has an internal monotonically increasing `generation`,
one immutable `run_id`, and the exact durable `work_item_id` claimed for that
turn. `SessionTurnExecutor.ActiveRun` is the ownership token: a turn callback
may broadcast output or mutate queue, durable execution, recovery, or busy
state only while that exact object is still the current non-invalidated owner
and its generation matches the session's latest generation. Looking up the
current run by `session_id` is not sufficient to authorize a callback produced
by an older request.

Stop invalidates A synchronously before awaiting stream cancellation. Work that
already belonged to A is cleared before that await; a message B received during
the await is therefore preserved in the next FIFO generation. A's `finally` is
not allowed to release or drain B. Provider HTTP cancellation is only a resource
optimization: late provider completion remains safe because chunk, reasoning,
tool, final, error, checkpoint, and recovery transitions pass the same run
ownership gate.

Conversation title generation is a post-terminal metadata job, not provider
turn output. Automatic first-message snippets are persisted with
`title_status = pending`; the eager client creation command carries its visible
snippet with `title_is_placeholder = true` so it does not become an explicit
title accidentally. An omitted or false marker keeps a supplied title explicit
and final for backward compatibility. Manually renamed, generated, fallback,
and legacy titles are also `final`. Every successful terminal completion checks this
authoritative state, including resumed/recovered turns, then continues title
work independently so title latency cannot delay final delivery or turn
cleanup. The write is one SQLite compare-and-set requiring both the captured
placeholder and `pending` status. A manual rename, deletion, or newer winner
therefore prevents both the mutation and `session_updated` event. Daemon startup
also scans pending sessions with a persisted user/assistant exchange and
restarts interrupted title work; hydration delivers recovered titles without
requiring the pre-restart transport connection. Live execution permits at most
one in-memory title request per session; durable compare-and-set remains the
cross-restart winner authority.

A live title request uses an immutable snapshot of the exact provider adapter
object, provider instance, and normalized model that completed the final LLM
request. The snapshot removes only the turn-scoped rate-limit/recovery wrapper,
preventing the background request from retaining the completed turn's
cancellation token or runtime-notice callbacks. Startup recovery resolves the
persisted session route because adapter objects cannot be serialized. Requests
use the first 500 characters of the user message plus final assistant response
and ask for a stable 3–7 word title in the user's language. `TitleService`
applies a 30-second Future timeout independently of adapter behavior and asks
for a 500-token output bound. If a structured HTTP 400 response explicitly
rejects the protocol's output-token field, the service records that adapter
capability and retries once without the optional bound; unrelated HTTP errors
do not retry. Any non-empty cleaned title is valid, including one- or
two-character titles. Empty or failed responses retain Sanad's bounded
user-message fallback.

`RuntimeRecoveryService` scopes cancellation tokens and stopped reasons by
`session_id + run_id`, while retaining the latest run identity as a tombstone.
Consequently a late retry, failure, or notice from A cannot replace B's recovery
state, and B cannot erase the stopped reason that A needs to exit its own retry
loop. `AgentRunner` receives the orchestrator-owned run id once and preserves it
across provider retries, tool continuations, and recursive model calls.

To achieve runtime hardening and durable state, the local agent daemon uses SQLite as a first-class state machine:

### 5.1. Session Work Items Table
Every execution turn is represented by a record in the `session_work_items` table. It tracks states (`queued`, `running`, `waiting`, `blocked`, `resuming`, `completed`, `cancelled`) and contains continuation checkpoints (cached tool execution outputs plus per-tool replay-safety metadata). A partial unique index ensures at most one active execution per session, and the repository enforces an explicit transition graph instead of allowing arbitrary `fromState == current row` updates. The persisted payload is always redacted before storage so request metadata, bearer tokens, and tool arguments/results cannot leak raw secrets into SQLite.

`SessionExecutionStateCoordinator` atomically derives the authoritative
`session_execution_snapshots` row from those work items. An active item takes
priority over queued followers; otherwise the oldest queued item represents the
aggregate. Normal queue claims enter `running`, restored/retry claims enter
`resuming`, and terminal completion returns to `queued` when followers remain
instead of reporting a false `idle`. Clearing a runtime recovery notice is
independent and never changes the execution snapshot.

Stop records `stopping` before awaiting provider cancellation and captures the
then-owned work item IDs. Completion cancels only that captured set. Work that
arrives while cancellation is pending belongs to a newer generation and remains
queued or becomes active after recomputation. Success, error, checkpoint, and
recovery callbacks carry the captured `work_item_id`; they never rediscover an
owner with a session-wide active-item lookup. The generation gate and durable
owner check together make stale terminal callbacks harmless.

Terminal delivery is commit-gated. Before streaming, the claimed work item is
bound to the exact `run_id + generation`. When the model stream finishes,
`SessionExecutionStateCoordinator` is the single owner that revalidates
`session_id + work_item_id + run_id + generation`, idempotently records the
assistant result, and performs `running|resuming -> completed` in one SQLite
transaction. `SessionTurnExecutor` may emit the final transport event only
after that owner returns `committed`. A `stale_owner` or
`recovery_owns_state` result is silent; it cannot produce a final answer or a
follow-on error. A persistence failure produces one controlled error before
any final and leaves the work item non-terminal for restart recovery.

`waiting -> completed` and `blocked -> completed` remain forbidden. If
recovery wins before terminal commit, it retains the durable state and the
completed stream content is not tagged as a committed terminal result. The
same rule prevents an older generation from closing or delivering the result
of a newer work item.

Message admission is also database-owned. The active-work read and the choice
between a new `running` item and a `queued` follower occur in one transaction;
the partial unique active-work index remains the final invariant and removes
any need for artificial active-row ordering. In-memory busy/suspended maps are
only projections: `running`, `resuming`, `waiting`, or `blocked` durable work
also makes the session busy. If another connection wins the active-row race,
admission retries as queued rather than exposing a SQLite uniqueness error.
An unexpected platform command Future is contained by `GatewayManager`, which
returns one controlled command error while keeping the daemon event loop live.
During Stop, an expected recovery transition surfaced by stream cancellation is
contained inside `SessionRunOrchestrator`; Stop remains authoritative and
continues cancelling durable work so the execution snapshot reaches `idle`
instead of remaining at `stopping`.

### 5.1.1. Authoritative queue and pending-steer ownership (Task 36)

`SessionRunOrchestrator` is the single admission classifier. Incoming message
commands carry `auto` or `queue` intent, not a client assertion that a steer or
queue already exists. The orchestrator reads the execution snapshot and the
current `ActiveRun` together:

- `auto` targets the exact `ActiveRun.agentRunner` only while its owner remains
  `running` or `resuming`, has not begun Stop, and still matches the session,
  run id, and generation.
- `auto` becomes a normal turn if the old run ended before admission.
- `queue` remains FIFO behind older non-terminal work but becomes a normal turn
  if no predecessor remains.
- waiting, blocked, queued, and stopping projections are not steerable runners.

The raw user `request_id` survives every classification and mutation. Queue
promotion removes the durable queued work item and creates the pending-steer
record in one transaction before injection into the same active runner. Queue
delete likewise cancels only a still-queued item and recomputes the execution
snapshot atomically. Duplicate promotion/delete requests return the current
outcome and never execute text twice.

The durable pending-steer repository, rather than `SteerCoordinator`, owns
lifecycle truth. The coordinator remains an engine buffer keyed by request id
and exposes typed snapshot, cancellation, reservation, delivery, and Stop-drain
operations. It never opens the database. The runtime persists `pending` before
classification confirmation, then buffers it only after revalidating the run
owner.

Delivery reserves `pending -> delivering` with a compare-and-set transition.
Cancellation competes for `pending -> cancelled` at the same boundary, so one
operation wins. After the engine has incorporated the steer at a safe model
boundary and saved the correct history, the runtime may commit `delivered` and
publish its new revision. A history-save failure cannot publish delivered;
recovery retains the text for a later explicit outcome. Old run/generation
callbacks are silent and cannot deliver or cancel records belonging to a newer
owner.

Pending steers remain distinct from work items: they are additional user input
to one active turn, not parallel turns. Their timeline projection therefore
does not imply model delivery. History exposes delivered steering metadata,
while runtime hydration separately supplies still-pending records; clients
merge both by raw request id and latest revision.

### 5.1.2. Stop barrier and draft recovery (Task 36)

Stop synchronously establishes its barrier before awaiting stream cancellation.
At that boundary it captures pending steers that have not won delivery and
queued work items that have not been claimed. It then cancels only that captured
set, leaving requests admitted after the barrier to the next generation.
Captured pending inputs retain receipt order, followed by queued inputs in FIFO
order.

The resulting draft-recovery payload is durable and keyed by the Stop request
id. It remains available after transport loss or daemon restart until the
initiating client acknowledges that the recovered text was persisted to the
session draft. Outcome replay and acknowledgement are idempotent. The daemon
never auto-sends recovered text, and shared queue-clear broadcasts do not grant
another client ownership of the initiating client's local draft.

For an ordinary user Stop, the initiating client generates and durably retains
a random `recovery_owner_token` before sending the command. The daemon stores
that token as the outcome owner but never serializes it or `claimed_by` in a
`user_stop` payload. Only an acknowledgement presenting the same token can
clear the outcome, so knowledge of the broadcast Stop request id is
insufficient for another client to apply or discard the draft recovery.

At daemon startup, `PendingInputRepository.reconcileAfterRestart()` resolves
every durable `pending` or `delivering` steer before ordinary runtime restore.
A delivering record already present in saved history becomes `delivered`;
otherwise the record becomes `recovered` and a durable outcome is created with
`recovery_reason = daemon_restart` and `claim_required = true`. The initial
event and history hydration advertise only an item count.

`session.stop_recovery_claim` uses its `command_request_id` as the claimant.
The repository atomically assigns `claimed_by` first-writer-wins, and the bridge
returns recovered text only to the winning claim with `claim_required = false`
and the same `claimed_by`. This replaces the missing pre-restart socket owner
without broadcasting draft text to all clients. The client persists its claim
id before sending the command, so a client restart can still recognize its own
winning response. Draft flush precedes acknowledgement; acknowledgement clears
the durable text while retaining an idempotent timestamped outcome, and is
accepted only with the winning claimant id.

Checkpoint metadata currently supports two explicit resume anchors:

- `initial_model_request`: resume from the persisted user message before any assistant/tool output is replayed.
- `after_tool_result`: resume from the history that already includes the assistant tool call plus tool results, trimming any partial duplicate assistant tail before the next model request.

Each checkpoint also records `resume_history_length`, `currentTurnStartIndex`, and the latest `currentModelRunId` so a restarted runner can rebuild the safe boundary without duplicating user echoes, tool results, or partial assistant output. Structured `completed_tool_outputs` persist the redacted `tool_call_id`, `tool_name`, tool `arguments`, `result`, `is_error`, and `sent_to_provider` flag for every completed call.

During a sequential tool batch, `resume_history_length` intentionally remains
at the earlier model-request boundary while the assistant message containing
the whole tool-call batch is already durable in conversation history. Explicit
manual Retry or Change Provider therefore restores that assistant batch before
repairing it. Results completed before interruption are reused, only started
unsafe calls with unknown completion receive a cause-neutral error result, and
calls that never started execute normally. The repaired history preserves the
original call order and contains exactly one tool result for every call before
the provider is invoked again. Automatic startup recovery does not enable this
manual repair and remains fail-closed for ambiguous unsafe execution.

All user-facing restart entry points share this checkpoint-preserving path. `daemon` and `start` commands always launch a supervisor parent in source and compiled-executable deployments; no environment setting enables or disables it. The terminal restart trigger sends the same controlled `/restart` request used by developer tooling and waits for the daemon child to exit; the supervisor then starts a replacement. Forced child termination is only a bounded fallback when the endpoint cannot respond.

### 5.2. Startup Recovery Flow
When the daemon restarts, `SessionRunOrchestrator.restorePersistedState()`:
0. Selects only `queued`, `running`, `waiting`, `blocked`, and `resuming`
   durable work. Historical `completed` and `cancelled` payload/checkpoint JSON
   remains queryable but is never read or decoded by startup recovery.
1. Re-hydrates any active `waiting` or `blocked` notices into the `RuntimeRecoveryService`.
2. Restores waiting timers using remaining time from `resume_at` to avoid resetting cooldown duration.
3. Reconnects restored `waiting` notices to a real auto-resume callback. When the timer expires (or when `resume_at` is already in the past), the runtime first claims the suspended work item, then emits the transient `resuming` → `cleared` transition and routes control back through `SessionRunOrchestrator.resumeSuspended()` exactly once. If the owner is missing or resume validation fails, the runtime must restore a controllable `blocked` notice instead of leaving the session silent.
4. Performs crash recovery for interrupted `running` and `resuming` execution:
   - A `resuming` work item is automatically reclaimed only when `owner_run_id`, `owner_generation`, a recognized checkpoint kind, and tool replay-safety metadata prove that exact continuation. Startup removes its stale pre-restart `resuming` notice, atomically claims the work again, and emits a fresh resuming lifecycle. Ownerless legacy rows remain blocked.
   - If no tool is executing and a `running` work item has a recognized `initial_model_request` or `after_tool_result` checkpoint, it is reinserted into the restored FIFO with explicit resume intent. Whether queue bootstrap runs it immediately or an earlier owner delays the drain, execution uses `resumeTurn()`/`AgentRunner.resumeStream()` and suppresses the user echo. This is the controlled-restart path: a persisted tool result is sent to the model without replaying the original user message or restart tool.
   - If the checkpoint marks every interrupted tool call as `tool_replay_safety=true`, the work item is transitioned to `queued` for automatic safe resumption.
   - If any interrupted tool call is missing that opt-in (or is explicitly unsafe), the execution is transitioned to `blocked` to protect the user's workspace, and a blocked notice is sent to the client to let the user choose between stop and manual retry.
5. Restores queued messages into the in-memory queue in strict sequence-based FIFO order.
6. Processes are run sequentially to prevent port collisions.

### 5.3. Persistence Ownership (Gate E)

The durable runtime state is persisted by four focused repositories in `agent/lib/evolution/db/runtime/` sharing the same `AgentStateDatabase` connection:

- `SessionWorkItemRepository` owns `session_work_items` — the single durable source of truth for queued and active work (work-item CRUD, FIFO claim, transition graph, route rewrite for queued and non-terminal items, orphan cleanup, cancel-all).
- `RuntimeNoticeRepository` owns `session_runtime_notices` — notice persistence and startup hydration.
- `LegacyRuntimeStateMigrator` owns the legacy `session_suspended_runs` and `session_pending_runs` tables for migration compatibility only; every public method is `@Deprecated`. Production code paths MUST NOT enqueue work through it.
- `RuntimeStateCleanup` owns the cross-table `clearAllForSession` path used by `Stop` and session deletion. It delegates to notice deletion + work-item cancellation + legacy purge against the same connection to preserve atomic semantics.

`PersistedRuntimeStateRepository` is a transitional facade that forwards every public method to its owning repository while still exporting the DTOs (`SessionWorkItem`, `PersistedSuspendedRun`, `PersistedPendingRun`, `PersistedRuntimeNotice`) and the `SessionWorkState` enum. The facade exposes `workItems`, `notices`, `legacy`, and `cleanup` getters so callers can migrate in place; it is removed only after all callers and tests have migrated to the focused repositories.

### 5.4. Final Responsibility Map (Large-File Refactor)

The four largest daemon files were split into focused units with single ownership. The split is behavioural-free — every contract in §5.1–5.3, the Plan 30 recovery protocol, and the wire protocol from [provider_protocol.md](provider_protocol.md) is preserved. Each extracted unit receives its dependencies explicitly via constructor injection and never reaches another runtime owner through the service locator.

#### Sanad Protocol Bridge (`agent/lib/interfaces/platforms/sanad_gateway/`)

`sanad_protocol_bridge.dart` (666 lines after the split, was 2633) is a **dispatcher and translator only**. Domain command logic lives in focused handlers under `handlers/`:

| Handler | Owns | Lines |
|---|---|---|
| `ProviderCommandHandler` | provider templates/instances/credentials/auth/model commands | ~974 |
| `SessionQueryHandler` | session history, list, title, preferences; runtime notice hydration | ~404 |
| `SessionRecoveryCommandHandler` | Plan 30 `runtime_retry` / `runtime_stop` / `runtime_continue_with_provider`; route confirmation (single consumer, therefore kept inside this handler). When a resumed owner is rate-limit waiting, a new recovery command reroutes and wakes that same owner rather than attempting a second claim. | ~330 |
| `WorkspaceCommandHandler` | workspace browse/create/tree, MCP server management, slash-command discovery, computer-use toggles, workspace policy (MCP is intentionally folded in — no independent state owner, so a separate handler would violate DRY) | ~355 |

Handlers receive `orchestrator`, `runtimeRecovery`, `config`, `agentRuntime`, `policyStore`, `envFileService` as **nullable** explicit constructor params; the bridge resolves them lazily and conditionally; handlers MUST NOT use `getIt`.

#### AgentRunner (`agent/lib/engine/`)

`agent_runner.dart` (1210 lines after the split, was 1919, −37%) owns the model loop, `history`, and `_currentTurnStartIndex` as the **single source of truth**. Cohesive details are delegated to collaborators under `engine/runtime/`:

| Collaborator | Owns | Lines |
|---|---|---|
| `ToolExecutionCoordinator` | tool batches (sequential/parallel), per-tool checkpoint persistence, safe replay on resume | ~496 |
| `ContinuationCheckpointCoordinator` | per-turn checkpoint build/restore on the active `SessionWorkItem`; Gate D.1/D.2/D.3 replay-safety rules | ~288 |
| `TurnRouteState` | per-turn provider/model route override; session-persisted route stays in `SessionManager` | ~252 |
| `SteerCoordinator` | pending steer queue (volatile), drain before LLM call, inject into tool messages, supersede late steer | ~221 |

Collaborators read live state via `CheckpointContext` and mutate history via `ToolExecutionCallbacks` / `SteerCallbacks` — they never hold a `history` reference or create a parallel source of truth.

#### SessionRunOrchestrator (`agent/lib/interfaces/runtime/`)

`session_run_orchestrator.dart` (935 lines after the split, was 1732, −46%) is the lifecycle coordinator and the atomic owner of the `Stop` transition. Specialized lifecycle steps are in dedicated coordinators:

| Coordinator | Owns | Lines |
|---|---|---|
| `SessionQueueCoordinator` | in-memory `_pendingEvents`, SQLite queue persistence + route overrides on queued/non-terminal work | ~163 |
| `SessionRecoveryRestorer` | daemon startup recovery, crash classification (re-queue vs block by `tool_replay_safety`), timer/notice rehydration, queue-only bootstrap | ~371 |
| `SessionTurnExecutor` | single turn execution, listener subscriptions via `ActiveRun`, tool-event emission, exception routing, title-update delegation | ~483 |

`Stop` stays under direct Orchestrator coordination — separating it would risk double `clear` and distributed ownership, which the refactor plan explicitly forbids. Request-id extraction and provider/model route resolution live in the stateless `session_turn_request_helpers.dart` sibling, so the queue coordinator does not import the orchestrator and the runtime dependency graph remains acyclic.

#### Persistence Repositories (`agent/lib/evolution/db/`)

See §5.3 above. `persisted_runtime_state_repository.dart` (631 lines after the split, was 1092, −42%) is a transitional facade. The four owning repositories total 902 lines across the `runtime/` subdirectory, each sharing the same `AgentStateDatabase` connection.

#### Verification status

- `fvm dart analyze lib/` — 0 issues.
- `fvm dart test test/interfaces/ test/core/provider_runtime/ --concurrency=1` — 327 tests pass.
- `fvm dart test test/engine/ --concurrency=1` — 117 tests pass.
- `fvm dart test test/evolution/ --concurrency=1` — 67 tests pass (46 pre-existing + 21 new Gate E repository tests).
- No `getIt` calls remain inside any extracted handler, coordinator, or repository — confirmed by `search_grep "getIt(|GetIt"` across all four extracted directories (0 hits).
- No bidirectional imports between extracted units in the same layer (e.g. handlers do not import each other; `runtime/` collaborators do not import the orchestrator). Shared request-route helpers are stateless sibling functions rather than a child→parent import.

## Conversation ownership and segment identity

One active turn has one immutable `run_id`, generation, and durable work item. Those fields authorize callbacks, recovery, stop, terminal commit, and queue operations; they are not display keys.

Each provider invocation within that turn receives a fresh `model_step_id` before the request. Its reasoning deltas, assistant chunks, stored assistant message, and completed projection share that identifier. A tool loop, semantic follow-up, or steer that causes another provider invocation creates another step. Restart resume restores the checkpointed step so replay does not invent a second projection. Tool use and result share the provider's existing `tool_call_id`.

Automatic failover retains the same run owner but must atomically claim the durable waiting work as resuming before calling the replacement provider. Terminal output still follows the normal owned `resuming -> completed` commit.

The same ownership rule applies to a bounded automatic retry on the current route. After a transient failure moves durable work to `waiting` or `blocked`, the retry validates the exact work item, run, generation, and request before committing `resuming`. A stale or lost owner cannot call the provider again. The recovery notice remains `resuming` until the first real provider event (including reasoning or metadata) or terminal completion; it is not cleared merely because the retry timer elapsed. This keeps the execution snapshot, terminal commit, composer, and sidebar attention icon aligned.

## Diagnostic Request Dumps

`LLMRequestDumper` is an opt-in diagnostic boundary controlled by
`DUMP_REQUESTS`. It writes masked request/response structures under
`SANAD_STATE_HOME/request_dumps/`, or the normal Sanad state location when no
state override exists. Session and timestamp identify files for correlation.
Dumps include target, history, tools, and error structure while masking API keys
and credentials. They are mutable diagnostic state and follow worktree state
isolation rather than identity/configuration storage.

## File-Backed Memory

Long-term memory uses `SANAD_HOME/memories/MEMORY.md` and `USER.md`, with entries
separated by `§`. A session loads one frozen prompt snapshot. Memory-tool writes
update files immediately but become prompt-visible only to a later session.

Each target serializes its read-modify-write cycle and reloads disk state under
lock. A successful mutation flushes a same-directory temporary file before
atomically replacing the destination, so readers observe one complete version.
If a destructive mutation finds content that cannot safely round-trip through
the entry format, it leaves the source unchanged and returns recovery backup
information instead of normalizing or discarding the content.

Single mutations and one-target `operations` batches share the same store
owner. A batch validates all operations and final capacity before committing;
any failure leaves the original file unchanged. Mutation success is a compact,
terminal result containing status and capacity metadata rather than all memory
entries or an absolute path. Explicit `read` remains the only normal full-entry
response. Recoverable failures provide bounded live inventory or match previews,
and repeated maintenance failures become terminal after a per-turn limit so
memory work cannot suppress the user response.

The same memory-owned content scanner protects writes and startup prompt
snapshots. Unsafe source entries remain inspectable and removable on disk but
are replaced with a blocked marker in the frozen prompt snapshot.

## Context Compression

`ContextEngine` estimates approximately four characters per token and compresses
older history when the configured context threshold is exceeded. System messages
and recent conversation remain intact. Compression runs before plugin hooks so
plugins observe the final effective history, while `AgentRunner` remains the
only mutable history owner.

## Run Cancellation Core (Plan 50a)

Each active turn owns one `RunCancellationScope` keyed by immutable `runId`.
`ActiveRun` creates the scope, `AgentRunner` attaches to it for the turn, and
`SessionRunOrchestrator.requestStop` awaits bounded cleanup through the same
primitive.

Publication rules:

1. `invalidate()` closes the publication gate synchronously before any await.
2. Live assistant, reasoning, and tool events must check `isPublicationOpen`.
3. Late provider or tool output from a cancelled run is consumed internally only.

Cleanup rules:

1. Resources register a cleanup callback and receive a `release()` handle.
2. `cancel()` is idempotent and joins one bounded cleanup operation.
3. The default cleanup deadline is five seconds (`RunCancellationScope.defaultCleanupDeadline`), shared with `SessionRunOrchestrator.runStopCleanupTimeout`.
4. Deadline or cleanup failure becomes `cleanup_failed`; the session must not remain in `stopping` indefinitely.

See also `docs/technical/run_cancellation_and_process_ownership.md`.

## Tool and Shell Cancellation (Plan 50c)

`ToolContext` carries `runId`, `generation`, and the active `RunCancellationScope`.
`ToolExecutionCoordinator` builds that context for every sequential and parallel
tool call. Once publication closes it consumes late futures internally without
writing their results to checkpoints/history or starting the next sequential
tool, leaving Stop-owned terminalization authoritative.

`ShellExecuteTool` is cooperatively cancellable:

1. Spawns owned containment (`setsid` on Linux, `perl setpgrp` on macOS, and a
   kill-on-close Job Object on Windows; `taskkill /T /F` is fallback only).
2. Registers `ProcessTreeHandle` cleanup on the run scope before awaiting output.
3. Races natural exit, `timeout_ms`, and `whenCancelled` with one terminal compare-and-set.
4. Returns `Command cancelled by user.` for Stop and keeps timeout messaging separate.

`ProcessTreeController` performs `TERM → bounded grace → KILL → verify` and
records typed cleanup outcomes (`exited`, `escalated`, `ownershipLost`, `failed`).
The controller captures and rechecks an OS process-start identity before late
cleanup. Natural wrapper completion first removes surviving descendants, then
calls `release()` so a later Stop cannot target a reused PID.

## Durable Terminal Tool Events (Plan 50d)

Stop terminalizes every `currently_executing_tools` entry into one
`ToolTerminalRecord` with `status: cancelled` before emitting `stopped`.
`ToolTerminalizationService` submits the canonical checkpoint output and tool
history message to `SessionExecutionStateCoordinator`, which validates the
exact work item, run, generation, and non-terminal tool state and commits both
records in one SQLite transaction. Only records returned as newly committed
are appended to live runner history and published by `SessionRunOrchestrator`.
Repeated calls, a stale owner, or a tool that already has a terminal result are
no-ops and do not mint another revision.

Stop commits captured work cancellation before acknowledging completion, but
defers publication of the resulting execution snapshot. Clients therefore
observe each newly committed cancelled tool terminal first, then `stopped`,
then the final `idle` or newer-work `queued` snapshot. A client reconnecting
during bounded cleanup joins this same ordered terminal stream.

The execution checkpoint records each tool's start time when its executing
marker is created. Cancellation persists that time together with terminal
time, revision, reason, and cleanup outcome. Late tool completions are consumed
behind the synchronously closed publication gate and cannot reach checkpoint or
history writes. Live translation and history hydration expose the same durable
terminal identity fields.
