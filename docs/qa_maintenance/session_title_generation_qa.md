---
title: "Session Title Generation QA"
description: "Regression coverage for first-exchange background title generation, stale-result rejection, and client synchronization."
---

# Session Title Generation QA

## Automated scenarios

1. A new internal session emits its final answer without waiting for title generation.
2. The eager Flutter first-send path transmits its visible snippet with `title_is_placeholder: true`; the daemon persists it as `pending`, while omitted/false markers preserve explicit titles as immediately `final` and never automatically replaced.
3. A pre-created or resumed session with a pending placeholder triggers generation after a successful terminal assistant response regardless of message count.
4. A title future that completes after `ActiveRun` cleanup still compare-and-sets the placeholder plus pending state and emits one `session_updated` event.
5. A manual rename performed while generation is pending changes the state to final and wins; the delayed generated title emits no event.
6. Deleting the session while generation is pending makes the delayed compare-and-set fail without recreating state.
7. Daemon startup regenerates a pending title from the first persisted user/assistant exchange; legacy sessions migrate as final, and a `final` title is never regenerated.
8. Startup recovery routes that request through the session's own persisted provider instance and model. A session whose provider route cannot be resolved is skipped without any provider call, and its title stays `pending`.
9. The request includes only the first 500 characters of each side, asks for a stable 3–7 word same-language topic/intent title, and carries a service-enforced 30-second timeout plus a 500-token output bound.
10. A structured HTTP 400 that explicitly rejects `max_output_tokens`, `max_completion_tokens`, or `max_tokens` retries once without the optional bound and caches that adapter capability; unrelated 400 responses do not retry.
11. After provider failover, the completed-turn snapshot and title request use the same provider adapter object, provider instance, and model; the background job neither calls the session-route resolver nor retains a completed turn's rate-limit/recovery wrapper.
12. Cleaning removes reasoning tags, quotes, prefixes, and trailing punctuation; any non-empty cleaned title is accepted, while empty/provider-failure output retains Sanad's user-message fallback.
13. Flutter consumes `session_updated` and replaces the visible cached/sidebar title; startup-recovered titles arrive through normal hydration.

## Test ownership

- Completed-turn route capture, including failover: `agent/test/engine/agent_runner_test.dart`
- Title prompt, adaptive output bounds, service timeout, exact-route consumption, startup recovery on the session's own provider route, unroutable-skip, finalized-title protection, cleaning, and fallback: `agent/test/evolution/title_service_test.dart`
- Pending/final persistence, atomic placeholder ownership, and deletion/manual-rename rejection: `agent/test/evolution/session_title_update_test.dart`
- `create_session` placeholder/final ownership, post-`ActiveRun` delivery, and stale-event suppression: `agent/test/interfaces/interfaces_test.dart`
- Flutter first-send placeholder intent: `client/test/unit/bloc/conversation_input_cubit_test.dart`
- Flutter command serialization: `client/test/unit/services/device_conversation_commands_test.dart`
- Flutter event projection: `client/test/unit/bloc/session_cubit_test.dart`
