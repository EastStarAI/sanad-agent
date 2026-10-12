---
title: "Task 90 — OpenCode Conversation Session Affinity"
description: "Ensure every OpenCode model request carries one stable conversation-scoped affinity header."
status: completed
current_gate: complete
remaining_estimate: 0%
reference_grounding:
  evidence_id: "90"
  fingerprint: "sha256:168bb34d226100a2a658e07d626023e2b3d1ed6133e816b3c4bef96dbdc124d6"
---

# Task 90 — OpenCode Conversation Session Affinity

## Goal

Send OpenCode's required `x-opencode-session` header with one opaque, stable value per Sanad conversation so requests remain accepted and retain backend/cache affinity.

## Locked Decisions and Scope

- Use the durable conversation `sessionId` already carried by `LLMRequestOptions`; do not create a per-request identifier or retain adapter state.
- Apply the header only to the official OpenCode provider template or a custom provider whose normalized endpoint host is exactly `opencode.ai`.
- Build dynamic request headers in the adapter boundary, not in static `ProviderProfile.defaultHeaders` and not in `AgentRunner`.
- Cover streaming and non-streaming requests for OpenAI-compatible, Anthropic-compatible, and Responses adapters so future route changes cannot silently drop affinity.
- Preserve all existing authentication and static provider headers.
- Model discovery requests are outside scope because they are not conversation-bound model turns.
- No client/UI change is required.

## Gates

### G0 — Discovery and alignment
- [x] Confirm the missing header in current Sanad request builders.
- [x] Inspect pinned reference implementation and behavioral tests.
- [x] Resolve the source-neutral adapter ownership and test obligations.

### G1 — Dynamic affinity policy
- [x] Add a stateless OpenCode target/header policy using immutable per-call options.
- [x] Reuse the policy in every conversation-bound HTTP adapter path.
- [x] Preserve existing request header behavior for non-OpenCode providers.

### G2 — Regression coverage
- [x] Prove one session produces one stable header in sync and stream paths.
- [x] Prove distinct sessions remain distinct.
- [x] Prove unrelated providers receive no affinity header.
- [x] Prove exact-host custom OpenCode endpoints are covered without hostname spoofing.

### G3 — Documentation and verification
- [x] Update the adapter runtime contract and provider QA matrix.
- [x] Run formatter, focused tests, and `fvm dart analyze` with bounded output.
- [x] Run `graphify update .` and review the final diff.
- [x] Complete the reference-grounding audit record.

## Acceptance Criteria

- [x] Given an OpenCode request with session `S`, when either sync or stream transport sends it, then the HTTP request includes `x-opencode-session: S`.
- [x] Given repeated model steps in session `S`, every OpenCode request uses the same value.
- [x] Given sessions `S1` and `S2`, their OpenCode headers preserve those distinct identities.
- [x] Given a non-OpenCode provider, no `x-opencode-session` header is sent.
- [x] Given a custom endpoint hosted exactly on `opencode.ai`, the header is sent; a deceptive suffix host is rejected.
- [x] Existing authentication, static headers, streaming behavior, and request cancellation remain unchanged.

## Definition of Done

- [x] Implementation remains inside the adapter/provider-wire boundary and stores no session state.
- [x] Focused automated coverage passes for every affected adapter family.
- [x] `fvm dart analyze` passes.
- [x] Relevant design and QA documentation reflects the behavior.
- [x] Graphify is updated.
- [x] No commit or push occurs without explicit user approval.
