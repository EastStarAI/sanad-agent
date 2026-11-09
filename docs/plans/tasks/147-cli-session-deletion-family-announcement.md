---
title: Task 147 — CLI session deletion must reach every connected Client
description: Root cause, failing-first regression coverage, and the Agent family announcement for session deletion.
status: implemented
---

# Task 147 — CLI session deletion must reach every connected Client

## Goal

A session deleted through the `sanad` CLI (or any transport other than the Client that owns the request) disappears from every connected Sanad Client immediately, without a Client restart.

## Locked decisions and scope

- **Root cause.** `SessionQueryHandler.buildDeleteSessionEnvelope` (`agent/lib/interfaces/platforms/sanad_gateway/handlers/session_query_handler.dart`) deletes the session and returns a single `session_deleted` envelope as the command response. `buildAgentEventEnvelope` (`agent/lib/interfaces/platforms/sanad_gateway/handlers/support/agent_event_envelope.dart`) stamps that response with `DeliveryPolicy.origin`, and `LocalDaemonServerPlatform.sendResponse` resolves `origin` to the one socket bound to that session (`_sessionClients[sessionId]`, fail-closed when absent). Nothing ever calls `GatewayManager.publishFamilyEvent` for a deletion, so a CLI-originated delete reaches the CLI's own socket and no other Client.
- **Fix owner.** The Agent protocol handler that performs the deletion announces it, using the same family seam already used by the schedule and secret command families; `SanadProtocolBridge` supplies `GatewayManager.publishFamilyEvent` through one shared helper.
- **Client stays unchanged.** `SessionCubit` already applies an unsolicited `session_deleted` payload that carries only `session_id` (no `request_id`), and `ConversationCacheStore.applySessionDeleted` is idempotent, so a duplicate delivery of the requester's own ack plus the family copy is safe.
- **Correlation is preserved.** The requester still receives its correlated `origin` acknowledgement with `request_id`; the family announcement carries only `session_id`, so it can never release another client's acceptance wait or look like a reply to its request.
- **Out of scope.** Session title and permission updates (`session_updated`) keep their current requester-scoped `request_id` correlation. Client identity/cache work, and dictation or voice sources, are untouched.

## Gates

### G0 — Root cause
- [x] Trace the CLI delete command to the canonical `delete_session` command (`agent/lib/cli/runner/commands/session/delete_command.dart`).
- [x] Prove the response scope is `origin` and that no family announcement exists for deletion.
- [x] Confirm the Client ignores nothing: `session_deleted` with only `session_id` already removes the conversation and clears selection.

### G1 — Failing-first regression coverage
- [x] Add `agent/test/interfaces/session_deleted_family_broadcast_test.dart` asserting one family-scoped `session_deleted` reaches both the local and the cloud Sanad client platforms beside the requester's ack.
- [x] Run it against the unfixed Agent and record the failure (`local clients received no session_deleted event`).

### G2 — Fix at the owning layer
- [x] Give `SessionQueryHandler` an explicit `broadcastFamilyEvent` dependency and announce the deletion after the durable delete.
- [x] Supply that dependency from `SanadProtocolBridge` through one shared `_publishFamilyEvent` helper (also reused by the secret and schedule families).

### G3 — Verification and documentation
- [x] `fvm dart analyze` in `agent/`; `fvm flutter analyze` in `client/`.
- [x] Focused Agent tests: the new regression test plus `agent/test/interfaces/`.
- [x] Focused Client tests covering `session_deleted` application.
- [x] Update `agent/lib/interfaces/platforms/sanad_gateway/AGENTS.md`, `docs/technical/communication_protocols.md`, and the deletion QA matrix.

### G4 — Delivery
- [x] Isolated worktree `.agent/worktrees/lt-stale-client-rows` from `origin/main`, focused commit, review-only pull request with CI green.
- [ ] Live verification of the CLI delete against a connected Client (owner-run; not executed inside this task).

## Acceptance Criteria

- [x] Given a connected Client and a session deleted through the `sanad` CLI, when the delete completes, then the Agent publishes one `session_deleted` event with `delivery.scope = platform_family` to every `sanad_client` platform instance.
- [x] Given the same delete, when the requester receives its response, then that response is still the correlated `origin` acknowledgement for its own `request_id`.
- [x] Given the family announcement, then it carries only `session_id`, so it names no request and cannot release another Client's in-flight send.
- [x] Automated coverage: `agent/test/interfaces/session_deleted_family_broadcast_test.dart` fails before the fix and passes after it.
- [x] No Client source change was required; existing Client coverage already removes a session on an unsolicited `session_deleted`.

## Definition of Done

- [x] Analyzer clean in `agent/` and `client/`.
- [x] Focused Agent and Client tests pass.
- [x] Owning contract and protocol documentation describe deletion as a family announcement.
- [x] `graphify update .` run for the changed Agent sources.
- [ ] Live CLI-delete acceptance against a running Client: owner-run, because this task must not start or stop runtimes.

## Current status

G0–G3 are complete with automated evidence. G4 is delivered as a review-only pull request; the live acceptance check remains with the runtime owner.
