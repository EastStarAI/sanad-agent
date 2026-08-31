# Interface Runtime Contract

## Scope
This contract applies to `agent/lib/interfaces/runtime/`.

## Active Run Ownership
- Every turn is owned by immutable session id, work-item id, stable run id, and monotonically increasing generation.
- Only the current non-invalidated owner may broadcast callbacks, clear busy state, drain queues, persist execution state, or deliver a terminal result.
- Each `ActiveRun` owns one `RunCancellationScope`; Stop invalidates that scope synchronously before awaiting bounded cleanup.
- Stop invalidates ownership synchronously before awaiting cancellation; input received during that wait belongs to the next generation.
- Visible recovery is session-addressable, but cancellation, retry, stopped reason, and late-notice authority remain run-scoped.

## Admission and FIFO
- Durable active work owns admission; in-memory busy, suspended, and queue maps are projections only.
- Read active work and insert running-or-queued work atomically.
- Preserve strict FIFO for queued input and immediately drain queue-only sessions restored without a recovery notice.
- Queue promotion, deletion, route rewrite, and execution-snapshot recomputation commit through the execution aggregate owner.
- Steering targets the active run's runner and bypasses ordinary admission only through the dedicated steer lifecycle.

## Runtime Collaborators
- `SessionQueueCoordinator` owns queue projection, FIFO drain, and non-terminal route rewrites.
- `SessionTurnExecutor` owns active stream subscriptions, turn callbacks, tool event emission, exception routing, and post-terminal title scheduling.
- `SessionRecoveryRestorer` owns startup reconstruction and classification of queued, waiting, blocked, running, and resuming durable work.
- Shared request-id and route helpers remain stateless and must not import the orchestrator.
- `DeviceCommandAdmission` owns device-control admission: correlation against
  the daemon's registered cloud id or local hardware id, cross-transport
  duplicate `request_id`, confirmation tickets, explicit boolean force
  selection, and unbounded-timeout rejection. It also exposes `admitCorrelation` and
  `consumeConfirmation` for managed-remote workspace mutations and cloud-admitted
  MCP save/delete/inspect/complete. It does not inspect capability flags.
  `DeviceControlCommandHandler` executes update check/apply and supervised
  restart after admission.
- Runtime collaborators do not open database connections or duplicate table ownership.

## Terminal Commit
- Deliver final assistant output only after an idempotent durable commit validates the exact session, work item, run, generation, and expected running/resuming state.
- Stale, recovery-owned, or persistence-failed terminal outcomes do not deliver content.
- Rejected generated finals produce correlation-safe diagnostics without logging content.
- Terminal commit persists assistant state before transport publication.
- Live user echoes and final-answer publications use the committed history row's message/turn identity and eligibility fields; transport must not publish a pre-persistence copy that requires reconnect before Edit, Retry, or Fork becomes available.

## Stop, Retry, and Route Recovery
- Atomic stop clears notice, cancel token, suspended state, durable work, and queue ownership, then emits one authoritative clear/stop transition.
- Restored blocked work always exposes Stop, Retry, and Change Provider.
- Retry/resume must atomically claim waiting or blocked ownership before any provider call.
- A second concurrent claimant is an idempotent no-op; the first claimant owns route changes across runner, session, queue, persistence, and client confirmation.
- Provider/model changes rewrite every non-terminal work item, not queued rows only.
- Missing explicit model may use only the target provider's own default; otherwise remain blocked for explicit selection.
- Automatic failover requires the master enablement plus per-instance allowance and an atomic current-owner/current-notice/current-route claim.
- Failover candidates prefer same-template same-model, then another template supporting the exact same model; never fuzzy-match a replacement model.
- Preserve controllable recovery on stale claim or when no exact compatible candidate exists.

## Restart Recovery
- Persist continuation checkpoint kind, completed tool results, executing tools, replay-safety metadata, and owner identity.
- Controlled restart drains every active session in caller-selected observation windows. An ordinary restart keeps waiting across provider-only timeout windows until the in-flight provider request completes and persists a safe checkpoint; it never cancels that request. Only explicit force restart may interrupt the exact still-current work-item/run/generation owner and proceed with an unknown provider outcome. Other ordinary unsafe timeouts never exit.
- Once an active run reaches its first safe checkpoint under restart drain, it is parked there. The safety scan may accept restart only while every next provider admission is closed; an active run must not consume another provider request or invalidate the accepted checkpoint before exit.
- While restart drain owns admission, queue new work durably and do not promote queued, restored, retry, or auto-resume work until cancellation or the next process restores it.
- A tool-origin restart may exempt only its exact requester identity before the single response and must await that tool's durable post-response checkpoint before normal exit.
- A requester-bound deferred result is a valid post-response checkpoint only
  when its typed descriptor is durable; recovery must resolve its terminal
  launcher outcome into the same tool call instead of replaying the mutation.
- Permanent stop supersedes any prepared or waiting restart and prevents the cancelled restart from issuing a later normal exit.
- A safe preparation may complete as a permanent supervised stop when an external launcher is taking ownership; this must preserve the checkpoint boundary while preventing the old supervisor from respawning.
- Resume interrupted tools automatically only when every executing operation explicitly declares restart replay safety and ownership metadata is complete.
- Unsafe, ownerless, or ambiguous interrupted work becomes blocked rather than guessed complete.
- A crashed foreground shell with owned persisted progress is terminalized once as `interrupted`, including bounded partial output and verified containment cleanup. Resume restores the original assistant tool call and its matching terminal result into canonical history before invoking the model; recovery itself does not replay the command. Missing or conflicting ownership remains blocked.
- Explicit manual Retry or Change Provider may close ambiguous unsafe tools with a neutral unknown-outcome result and continue, but must never replay their side effects.
- An unresolved suspended checkpoint covering every executing tool call is an interactive `waiting` owner, not an ambiguous interrupted-tool failure.
- Repeated startup while an interactive checkpoint is unanswered preserves the same request in `waiting`; it emits neither an interruption result nor a blocked notice.
- Restart-restored permission or clarifying input must claim durable `resuming` ownership and commit `completed` before terminal delivery.
- Startup may hydrate a runtime notice only when active non-terminal work owns it; terminal historical sessions cannot receive fallback recovery notices.
- Restored waiting work recreates a real auto-resume callback and claims suspended ownership before publishing resuming/cleared state.
- A failed resume preserves controllable ownership and cannot silently strand work.
- A crashed running checkpoint with explicit resume intent remains resume work through FIFO; ordinary queued messages remain new turns.

## Pending Steer and Draft Recovery
- Reserve pending steer durably before it enters history.
- Resolve delivery/cancellation exactly once by raw request id and owner run/generation.
- Failed history persistence rolls back in-memory mutation without losing text.
- A late steer that follows a completed assistant model step publishes that pre-steer segment as a completed thought before resetting terminal accumulation; live and history projections must not discard it.
- Restart never injects a pending steer into a new generation; unresolved pending/delivering rows become durable draft-recovery outcomes unless history proves delivery.
- Recovered text and owner tokens never enter logs or broadcast payloads.

## Latest-Root-Turn Replay
- Replay targets the latest active `root_turn` by `message_id`, `turn_id`, `request_id`, and `expected_history_revision`.
- Soft rewind and replacement-user acceptance commit atomically; the CAS
  transaction revalidates the target as the latest active root. History is
  never truncated, and rewind without a durable replacement is not admitted.
- Steer is not a replay boundary, including pending, delivered, and
  embedded steers. Dispatch waits for an authoritative `idle` snapshot
  after scoped stop. Missing snapshot state is not dispatch authority.

## Materialized Session Fork
- `session.fork` copies the active prefix through a durable terminal final answer in one transaction.
- Steer-superseded thoughts, incomplete/failed/cancelled rows, and tool-call asks are not forkable targets.
- The client sends source session and target identities only. The child starts idle with new message/turn identities.

## Workspace Filesystem Mutation
- Resolve stable workspace UUIDs to their current daemon-owned path before filesystem, MCP, skill, or permission access; a missing path remains visible but fails execution until repaired.
- Display-name rename never mutates the filesystem, and Change Path never rewrites session/work-item workspace ids.
- Remote workspace-picker mutations remain daemon-owned and operate on directories only.
- Create accepts an existing parent plus one validated child name; never accept a client-assembled create target path.
- Rename and delete reject filesystem roots, symbolic links, non-directories, missing paths, traversal names, and occupied rename destinations.
- Recursive delete requires an explicit client confirmation, but daemon validation remains authoritative regardless of client behavior.
- Workspace-record removal is metadata-only: it deletes the registered
  workspace row and never deletes the directory, files, sessions, or messages.

## Verification Boundary
- Runtime changes require focused tests for FIFO, stale ownership, stop, retry, route rewrite, terminal commit, and restart reconstruction.
- Persistent/restart behavior requires SQLite-backed simulation, and system-boundary changes require daemon-backed restart coverage.
