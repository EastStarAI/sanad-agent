---
title: "Conversation Event Live/History Parity QA"
description: "Focused verification for model-step segmentation, tool identity, opaque event IDs, and canonical history hydration."
---

# Conversation Event Live/History Parity QA

## Required fixture

Use one redacted turn containing three model invocations and two tool calls:

```text
thought A -> tool A use/result -> thought B -> tool B use/result -> thought C -> final
```

All items share one `run_id`. The three assistant segments have distinct `model_step_id` values. Each tool pair shares one `tool_call_id`, and the two calls differ.

## Assertions

1. Live reasoning deltas merge only inside their model step.
2. A later step or tool never overwrites an earlier completed projection.
3. Final cleanup removes only the matching running final-step projection.
4. Reconstructed history has the same semantic order and identities as live events.
5. A `session_route_transition` with a UUID `event_id` hydrates without numeric conversion or a Retry screen.
6. Legacy rows without segment fields receive bounded deterministic fallbacks and do not collapse an entire run.
7. A transient history failure logs redacted device/session/generation correlation, shows a generic message, and Retry can load the valid snapshot.
8. `tool_use` marks its producing model-step thought completed; after several thought/tool segments, Stop removes only the final unfinished `model_step_id` and preserves every earlier completed thought.
9. A recovery-only Stop without `model_step_id` clears runtime controls without deleting conversation events.
10. Daemon-backed E2E uses a unique temporary `SANAD_STATE_HOME` per daemon and the deterministic `e2e-provider/e2e-model`; it must not open the user's `state.db` or contact a configured provider.
11. A leading tagged-reasoning stream emits confirmed reasoning before the closing tag or post-tag final content arrives; split closing markers never leak into either surface.
12. The same incremental fallback covers provider-specific supported markers such as MiniMax `<mm:think>`, without branching in the provider-neutral runner.
13. Local/cloud fan-out translates one response independently but updates the in-flight snapshot once at the stream source; two chunks hydrate as `A + B`, never `A + A + B + B`.
14. A late steer completes the pre-steer running row as a visible thought before the steer continuation starts, and history hydration reproduces the same order.
15. Running thought Markdown is exercised through the progressive renderer in widget tests; tests do not silently replace it with the completed-document renderer.
16. Live and history tool execution events maintain identical error status parity (a tool failing with an error in the live run is hydrated as a tool error event in history).
17. User Stop during a running tool publishes `tool_result.status = cancelled` live and hydrates the same run/generation/revision, reason, cleanup outcome, start time, and terminal time after reload; repeated Stop or late success does not add a second terminal revision, and `stopped` defensively closes any same-run tool that missed the terminal packet without leaving a spinner.
18. After a Local Gateway session is bound to a logical conversation device id, an unrelated hardware-scoped command on the same WebSocket cannot retag subsequent `tool_use`, `tool_result`, execution-state, or final-answer events. The client EventRouter receives them on the original session device stream without requiring navigation or history hydration.
19. An automatic failover renders its `session_route_transition` notice after the last row the user saw live (for a failover after a tool step: after that tool result, before the next model output). Reloaded history places it in the same position with the same `route_<session>_<revision>` identity, text and `auto_failover` source; a live-plus-reload merge keeps one notice. Paged history shows it once, on the page holding its anchor. User and recovery route changes produce no notice either live or in history.
20. A continued fork child keeps `session.forked` between the copied prefix and the post-fork turns on reload and on every page edge, and opens like any session rather than at the marker.
21. Live `thought_stream` and `reasoning_stream` deltas carry `stream_seq` starting at `1` per stream key (`kind` + `model_step_id ?? run_id`), increasing by exactly `1`; a new model step or a new run starts its own key at `1`, and reasoning deltas never advance the ordinary-text key.
22. One response serialized for the local and the cloud transport carries the identical `stream_seq`, `event_id`, `run_id`, `model_step_id`, and text; repeated translation of the same response neither shifts nor consumes an ordinal.
23. The in-flight projection reports `stream_seq` = the last delta its text includes plus `snapshot: true`, and a producer that stamps no ordinal leaves the field absent; no history row and no durable column carries stream sequence metadata.
24. `session.stream_state` answers from the in-flight projection only: a running stream returns the snapshot, an idle stream and a session this daemon does not own both return `absent` with a typed reason, and a request without a whole `session_id` fails typed as `invalid_request` without touching history.
25. A suspended-resume continuation publishes provider reasoning as `reasoning_stream` and ordinary text as `thought_stream`, and begins a fresh model step, so its keys start at `1` under a new step identity instead of reusing a checkpoint key; its terminal answer carries no ordinal and no key claims continuity across a restart.
26. Two family events of one session are delivered in emission order even when the first send is slow, two sessions are delivered independently, a failing delivery never blocks the next event of that session, the local copy still precedes the cloud copy, and no ordering entry survives its delivery.
27. A Client that receives numbered deltas applies a contiguous ordinal immediately, drops a duplicate or stale ordinal, and holds a delta that arrives ahead of its predecessor until the predecessor arrives, then applies both in sequence order.
28. A gap that the reorder window cannot close produces exactly one `session.stream_state` request per session, never more than once per cooldown and never while one is in flight; an `absent` answer leaves the last good text in place, reloads no history, and does not invent a row.
29. The reorder window stays inside its bounds: exceeding 32 buffered deltas, 64 KiB of buffered text, or 8 stream keys per session drops the buffered text instead of growing, and the timeline keeps the text it already applied.
30. A snapshot event replaces the running text exactly and adopts its watermark, so a later delta at or below that watermark is dropped and the next ordinal still appends.
31. After a terminal event seals its step, a late delta of that step produces no new bubble and never appends to the closed stream, while a new step streams normally.
32. A stream whose deltas carry no ordinal keeps plain arrival order for its lifetime, and a peer that never declares `stream_sequence_v1` loses no event.
33. Interleaved deliveries of one stream from the local and the cloud transport converge on one bubble with the same text as a single ordered delivery.
34. A repair answer that returns after the session was switched or reset, after a turn terminal, or after disposal is discarded whole: it injects no text into the new conversation and opens no bubble for the finished turn.
35. A delta without an ordinal never discards a pending sequenced delta and never clears the key's watermark: the window, the repair capability, and the already-applied text survive, and the key stays sequenced afterwards.
36. A peer that never declares `stream_sequence_v1` is never asked for a repair while ordering still works on an ordinal it happens to send; the tracked-session window is bounded and evicts the least recently used session.

## Automated ownership

- Agent translation/history coverage: `agent/test/interfaces/sanad_bridge_test.dart`
- Stream ordinal allocation, every delta source, and the in-flight watermark: `agent/test/interfaces/runtime/stream_delta_sequencer_test.dart`, `agent/test/interfaces/stream_delta_publisher_test.dart`, `agent/test/evolution/session_in_flight_watermark_test.dart`
- Cross-transport payload parity for one response: `agent/test/interfaces/stream_delta_transport_parity_test.dart`
- Per-session family delivery order, isolation, failure containment, and cleanup: `agent/test/interfaces/gateway_family_delivery_order_test.dart`
- Narrow stream repair query: `agent/test/interfaces/session_stream_state_test.dart`
- Suspended-resume stream kind and ordinals: `agent/test/interfaces/suspended_resume_stream_delta_test.dart`
- Client ordering decisions, bounds, repair cooldown, snapshots, and sealing: `client/test/unit/stores/stream_delta_order_gate_test.dart`
- Client ingestion through the real event handler, store, and conversation state: `client/test/unit/services/stream_delta_ingestion_test.dart`
- Client capability declaration, mapper fields, and the repair command: `client/test/unit/services/stream_delta_contract_test.dart`
- Agent run and tool lifecycle: `agent/test/engine/agent_runner_test.dart`
- Agent informational-event placement and paging (fork marker, failover anchor, legacy fallback): `agent/test/interfaces/platforms/sanad_gateway/session_informational_event_order_test.dart`; live failover anchor through the runner: `agent/test/engine/route_transition_anchor_test.dart`
- Tagged reasoning parser and OpenAI-compatible streaming: `agent/test/engine/adapters/tagged_reasoning_parser_test.dart`, `agent/test/engine/adapters_test.dart`
- Client mapping/state cleanup: `client/test/unit/models/canonical_event_test.dart`
- Client history hydration: `client/test/unit/services/device_conversation_commands_test.dart`
- Client failover-notice live/history parity: `client/test/unit/stores/informational_event_parity_test.dart`; fork opening position: `client/test/widget/brain_activity_view_scroll_test.dart`
- Client Stop fallback and live terminal ordering: `client/test/unit/services/device_conversation_event_handler_test.dart`
- Client cancelled-state presentation: `client/test/widget/tool_group_tile_test.dart`
- Client failure/retry presentation: `client/test/unit/bloc/session_cubit_test.dart`
- Full local socket/runtime/history path: `client/e2e_test/local_dual_connection_e2e_test.dart` (validates session device binding against hardware identity, runtime notice recovery, pagination, and deterministic WebSocket conversation)
