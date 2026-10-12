---
title: "Agent Turn Startup Performance QA"
description: "Regression matrix for metadata-only admission, atomic root-message append, revision-validated history reuse, and Windows long-session latency."
---

# Agent Turn Startup Performance QA

## Invariants

1. Route and admission metadata reads never depend on message-row JSON.
2. A normal root-user message is committed once before provider execution; retrying its raw request id returns the same canonical identity.
3. The ordinary append path never scans, replaces, or reserializes the unchanged historical prefix.
4. An in-memory history projection is usable only when its session id and `history_revision` match the persisted session record.
5. Recovery, replay, compaction, queued input, and steering retain their existing transaction and ordering owners.
6. `AgentRunner` remains run-scoped; history reuse does not authorize a daemon-wide runner singleton.

## Automated regression matrix

| Scenario | Expected result | Owner |
|---|---|---|
| A session has valid metadata and a deliberately malformed message payload | Session-record lookup succeeds without decoding that payload; full hydration remains the operation that detects malformed history | `agent/test/evolution/message_history_identity_test.dart` |
| Append a root user message to an existing multi-row history | Exactly one active row is appended; every prior row id and serialized message remains unchanged; ordering metadata and revision advance once | `agent/test/evolution/message_history_identity_test.dart` |
| Repeat append with the same non-empty raw request id | The first committed message, message id, and turn id are returned; row count and revision do not advance | `agent/test/evolution/message_history_identity_test.dart` |
| Reuse a history snapshot at the persisted revision | The same history projection is returned and becomes most recently used | `agent/test/evolution/memory_test.dart` |
| Mutate canonical history outside the manager after snapshot creation | Revision mismatch rejects the stale projection and reloads authoritative active rows | `agent/test/evolution/memory_test.dart` |
| Start more than eight distinct session histories | The least-recently-used projection is evicted; later access reloads it from persistence | `agent/test/evolution/memory_test.dart` |
| Commit a normal runner root message | Durable append returns the canonical identity and the runner adds it without full-history replacement/reload | `agent/test/engine/agent_runner_test.dart` |
| Retry, restart, replay, compaction, title generation, queue, steer, and stale-owner paths | Existing identity, recovery, and ordering outcomes remain unchanged | `agent/test/engine/agent_runner_test.dart`, `agent/test/interfaces/interfaces_test.dart` |

## Windows runtime evidence matrix

Use an isolated worktree runtime and a long session representative of the recorded 486-message baseline. Do not switch or restart another active runtime.

| Check | Evidence required |
|---|---|
| Warm repetition | Two completed root turns against the same long session plus one new-session control. A third long-session provider turn was waived at the user's request to avoid unnecessary context-token consumption and must not be claimed. |
| Start boundary | Timestamp of the Agent incoming-session event |
| End boundary | Timestamp of `AgentRunner` entering thinking/first provider preparation |
| Comparison | Each sample compared with the recorded 14.3–19.2 second range; do not combine long- and new-session samples into one median |
| Correctness | One durable root user row per request, stable retry identity, and no recovery or history-order regression |
| Isolation | Runtime source, isolated Home, ports, branch, and session id recorded so the result is reproducible without exposing machine-specific paths |

### Recorded Windows evidence

| Sample | Boundaries | Result | Interpretation |
|---|---|---:|---|
| Long session, first measured turn | `20:06:49.590` incoming → `20:06:59.812` thinking | 10.222s | Below baseline despite one-time healing of an unanswered historical tool call |
| Long session, clean warm reuse | `20:08:30.354` incoming → `20:08:35.935` thinking | 5.581s | Clean revision-validated reuse path; below baseline |
| New-session control | `20:10:13.504` matching request event → `20:10:18.478` thinking | 4.974s | Separate control, not a long-session sample; including the creation event at `20:10:13.466` gives 5.012s |

The isolated run used Agent port `58117`, Client VM Service port `51250`, and long-session id `72947eee-dd44-408b-a027-99d019546492`. Its copied test Home had a separate identity and no active execution state. The test also exposed delayed Windows provider readiness; that root Agent startup/list problem and the secondary premature Client setup screen are now owned by `docs/plans/tasks/97g-readiness-and-loading.md`; historical evidence remains in `docs/plans/done/agent-windows-intermittent-tool-and-history-latency.md`.

## Failure triage

- If metadata lookup fails on malformed message JSON, inspect for a hidden call to full session hydration.
- If a retry changes revision or identity, inspect append transaction ownership and raw `request_id` matching.
- If an external mutation is not observed, compare the persisted revision with the cached revision before inspecting LRU behavior.
- If latency remains near baseline after history regressions pass, continue in `docs/plans/tasks/97f-agent-responsiveness.md`; do not add workspace instruction, skill, or MCP caches without new measurements.
