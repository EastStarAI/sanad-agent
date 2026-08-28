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

## Automated ownership

- Agent translation/history coverage: `agent/test/interfaces/sanad_bridge_test.dart`
- Agent run and tool lifecycle: `agent/test/engine/agent_runner_test.dart`
- Tagged reasoning parser and OpenAI-compatible streaming: `agent/test/engine/adapters/tagged_reasoning_parser_test.dart`, `agent/test/engine/adapters_test.dart`
- Client mapping/state cleanup: `client/test/unit/models/canonical_event_test.dart`
- Client history hydration: `client/test/unit/services/device_conversation_commands_test.dart`
- Client failure/retry presentation: `client/test/unit/bloc/session_cubit_test.dart`
- Full local socket/runtime/history path: `client/e2e_test/local_dual_connection_e2e_test.dart`
