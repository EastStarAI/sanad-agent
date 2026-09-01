---
title: "Agent Interface and Runtime Architecture"
description: "Architecture of gateway routing, active-run orchestration, Sanad protocol translation, recovery, and local/cloud platform adapters."
---

# Agent Interface and Runtime Architecture

## Layer Map

The interface domain connects runtime execution to CLI, local daemon, and cloud
gateway transports. Its primary layers are:

1. typed gateway events, responses, origin, and delivery models;
2. `GatewayManager` registration and response routing;
3. `SessionRunOrchestrator` admission and active-run coordination;
4. focused runtime collaborators for queueing, execution, recovery, and durable
   state transitions;
5. platform adapters for CLI, local WebSocket/HTTP, and cloud Socket.IO;
6. the shared Sanad protocol bridge and focused command/query handlers.

## Runtime Orchestration

`SessionRunOrchestrator` is the platform-neutral admission boundary. Each turn
has immutable ownership composed from session, work item, run id, and generation.
In-memory busy, queue, and cancellation maps are projections; durable work state
owns admission and restart recovery.

`SessionQueueCoordinator` manages FIFO and route rewrites.
`SessionTurnExecutor` binds stream callbacks to an active run and delegates model
execution to `AgentRunner`. `SessionRecoveryRestorer` reconstructs queued,
waiting, blocked, and interrupted work after daemon startup. Shared request and
route helpers remain stateless so collaborators do not depend back on the
orchestrator.

Final delivery follows a successful idempotent terminal commit for the exact
owner. Automatic failover is bounded to one model invocation: every instance
that fails before streaming is excluded from the remainder of that invocation,
so multi-provider routing advances without revisiting an exhausted route and
falls back to controllable recovery when no qualified candidate remains. Stop
invalidates the active owner before awaiting cancellation, clears runtime
recovery and durable work, then allows later input to enter a new generation. Interrupted tools resume automatically only when their persisted checkpoint marks
every executing operation replay-safe. An explicit user Retry or Change Provider
may instead close each ambiguous non-idempotent tool with a neutral
unknown-outcome result and continue the model loop; it never re-executes the
side effect.

A restart may repair a missing continuation checkpoint only for the narrow
pre-provider window: the exact owned user message is already durable and there
is no provider-in-flight marker, executing tool, completed result, or deferred
result. The repair is persisted as `initial_model_request` with an audit marker.
Every other missing or unknown checkpoint remains ambiguous and controllably
blocked. A failed resume publishes no `final_answer`.

## Controlled Daemon Restart

Controlled restart establishes a global drain across every active session.
New turns are queued durably, while queued successors, restored work, retries,
and automatic resumes cannot claim execution until the drain is cancelled or
the replacement process restores them. A provider request already in flight is
a restart blocker: the daemon waits for it to complete and persist. The
configured timeout is an observation window, not permission for an ordinary
restart to interrupt a provider request; provider-only windows repeat until
the request reaches a safe checkpoint. At that boundary the active run is
parked: it cannot begin another provider request or tool batch while the drain
owns admission. Provider admission atomically checks the drain and commits the
durable plus in-memory in-flight markers without an asynchronous gap, so the
restart safety scan cannot accept a checkpoint that the same run immediately
invalidates. Only `force=true` may revalidate the
exact work-item, run, and generation owner, cancel that stream, record blocked
recovery, and proceed with restart. A stale timeout snapshot cannot cancel a
request that already completed. Startup never replays an
interrupted request automatically. The durable `model_request_in_flight` marker
makes an unexpected crash or forced exit fail closed rather than silently
replaying an unknown provider outcome; a definitive live failure such as rate
limit restores the preceding safe checkpoint and retains its normal recovery
policy. Retry or Change Provider is explicit and atomically restores the
recognized `checkpoint_before_model_request` while claiming the work as
`resuming`; an absent or unknown predecessor remains blocked without invoking
the provider.
The default safety timeout is 60 seconds and callers may provide
`timeout_seconds` between 1 and 3600. Each provider-only timeout repeats the
ordinary wait described above. Any other timeout fails without exiting unless
`force=true` was explicitly supplied.

The restart endpoint emits one response. For ordinary callers it waits until
all active work is restart-safe, flushes the success response, then exits. If
the response cannot be flushed, the prepared restart is abandoned, the drain
is released, and the daemon remains available. A restart invoked by a daemon
tool carries requester session and tool-call
identity: the pre-response safety scan excludes only that exact tool while all
other sessions must be safe; after the response, the daemon waits for the
requester result to reach an `after_tool_result` checkpoint before exiting.
Restart evaluation runs independently from HTTP acceptance, so health,
permanent stop, and unrelated WebSocket traffic remain available during the
wait. Permanent stop cancels the pending restart and owns the only subsequent
exit.

An unresolved interactive tool is already restart-safe when every unfinished
tool-call id is covered by a durable `awaiting_permission` checkpoint and no
provider request is in flight. Ordinary restart exits from that boundary
without waiting for the user, cancelling the tool, or requiring force. Startup
then changes the preserved running owner to `waiting` and republishes the same
Ask User or permission request identity. Partial coverage never hides another
unresolved tool in the same batch; that batch remains a restart blocker.

A forced timeout deliberately preserves ambiguous durable tool state for
startup recovery. Automatic startup remains fail-closed. Any later manual
recovery uses cause-neutral interruption text because the runtime may not be
able to distinguish forced restart, crash, process termination, or power loss.

## Gateway Delivery

`GatewayManager` registers independent `BasePlatform` adapters and routes typed
responses according to producer-owned delivery policy:

- origin routes only to the originating platform instance;
- platform-family synchronizes related transports such as local and cloud Sanad
  clients;
- hardware targets a known hardware identity within one family;
- device addresses the local client-to-daemon direction.

Unknown origins and invalid or missing delivery policies fail closed. External
platform families remain isolated from Sanad-client synchronization. A platform
initialization or asynchronous send failure is contained so other adapters and
the daemon event loop remain available.

## Platform Adapters

The cloud Sanad adapter is an outbound Socket.IO client responsible for cloud
registration, credential refresh, reconnect, and cloud-only capability
advertisement. The local daemon adapter is an inbound loopback HTTP/WebSocket
server whose port is runtime configuration. Both use the same protocol bridge
and preserve device, hardware, session, request, run, model-step, tool-call, and
event identities.

The CLI adapter is an origin-scoped platform. New adapters implement the common
platform lifecycle, event stream, descriptor, and response delivery boundary
without adding semantic family branches to `GatewayManager`.

## Sanad Protocol Bridge

`SanadProtocolBridge` dispatches and translates; it does not own domain command
workflows. Focused handlers own provider, session query, workspace/MCP, device
settings, recovery, and turn-replay commands. Dependencies are constructor
inputs, including optional runtime owners resolved by composition rather than by
handlers reaching through a service locator.

The bridge exposes canonical device-first envelopes to both Sanad transports.
Runtime-rich turn requests preserve workspace, provider/model, thinking mode,
request identity, and typed delivery intent. The daemon classifies accepted
input as immediate, queued, or steer from durable state plus the current active
run.

Session list/history, title, route transitions, runtime notices, queued input,
pending steer, draft recovery, provider runtime, workspace browsing, MCP,
skills, device settings, permissions, platform tools, replay, and context usage
share this bridge. Detailed field and event schemas remain in
`docs/technical/communication_protocols.md`,
`docs/technical/provider_protocol.md`, and
`docs/technical/message_turn_replay_protocol.md`.

## Suspension and Resume

`PlatformRuntimeBridge` converts runtime permission/platform-tool suspension
into canonical requests and resolves responses back into pending runtime work.
The first valid permission response claims resolution atomically. If in-memory
waiters were lost during restart, persisted suspension state is the fallback
owner.

An unresolved suspended checkpoint that matches every currently executing tool
call is authoritative evidence that the turn is waiting for user input.
Startup restores that work item as `waiting`; it must not classify the
interactive tool as an ambiguous interrupted side effect. The history healer
also preserves those unanswered tool calls until their checkpoint is resolved.
If an older daemon already wrote the false `blocked` state, startup reconciles
the matching unresolved checkpoint back to `waiting` and removes the stale
interruption notice.

This classification is stable across repeated force stops. Until a decision is
received, the same ask-user or permission request remains `waiting`; startup
does not synthesize a tool result, allocate a new request, or invoke the model.

`SuspendedResumeService` reconstructs runtime context, reapplies the persisted
permission decision, atomically claims `waiting` or `blocked` work as
`resuming`, and resumes the assistant stream through normal canonical
delivery. It restores the original run/generation owner and commits the work
item as `completed` before publishing the terminal response. Resume never uses
an ad-hoc transport side channel. Once the terminal commit succeeds, it also
reconciles the orchestrator projection: the restored suspension and stale busy
ownership are removed and the durable FIFO is allowed to drain. This prevents
an `idle` database snapshot from coexisting with admission that still queues
new messages.

Startup reconciles runtime notices against active non-terminal work before
hydration. A notice with no active work owner is deleted as orphan state, and a
global restore-failure fallback may block only sessions that still have active
work; terminal historical sessions remain idle.

Runtime notices and clears carry the current authoritative execution revision.
The Client rejects a notice older than its accepted execution snapshot, removes
an older notice when a newer snapshot arrives, and does not let a stale clear
remove a newer notice. History hydration binds legacy unversioned notices to the
execution revision delivered in the same envelope.

## History Pagination

`get_session_history` accepts an optional opaque `before_cursor` and a bounded
`limit`. The response returns canonical chronological messages plus
`next_cursor` and `has_more`. The cursor is a base64url-encoded JSON keyset made
from the oldest row's `(created_at, id)` pair; malformed cursors fail with
`invalid_before_cursor` instead of silently changing the requested page.

The database query orders by `(created_at DESC, id DESC)`, fetches one sentinel
row beyond the requested limit, and reverses the retained page before returning
it. This gives stable boundaries when messages share a timestamp and avoids
offset drift as new tail messages arrive. The initial request uses the same
protocol with no cursor, so the daemon never hydrates an unbounded transcript.

## History Projection

Live and reconstructed history use the same canonical identities and payload
shape. Reasoning remains distinct from final answer content. Tool use and result
pair by tool-call identity, model output segments by model-step identity, and
run id remains execution ownership rather than display identity. The latest
context-usage projection is restored without accumulating historical model
steps.
