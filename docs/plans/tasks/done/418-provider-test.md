# Task 418 — Compatible provider Test and single failure notice

## Goal

Make the existing provider Test exercise a compatible request and show a single notice for a single failure.

## Locked scope

- Keep discovery first, generation only on explicit Test when a model is selected, and preserve the existing setup gate. Save-time key verification is tracked separately in #484.
- Use the shared adapter for request construction. Provide a one-shot opaque session identity where required and do not impose a universal output-token wire value. Report the sanitized actual generation endpoint when known.
- Keep the last real failure visible until newer proof; suppress duplicated presentation of the same cause, preserve fallback context, and do not revive an old warning after a successful Test or a model change.

## Gates

### G0 — Reproduction and ownership
- [x] Confirm the two incompatible generation requests and the duplicate persisted/transient display; local recovery after a successful retry is already observed.

### G1 — Implementation and regression coverage
- [x] Inspect the outgoing generation request at the adapter boundary for both confirmed routes and keep discovery-only setup unchanged.
- [x] Prove one notice for a matching failure and preserve distinct failures and success; cover stale notices after model changes and successful retries.

### G2 — Verification
- [x] Pass Agent and Client analyzers and focused tests (112 Agent tests and 61 Client tests, including size guards).
- [x] Update protocol and QA documentation; refresh the code graph and inspect the worktree diff.
- [x] Live Client Test passed on the configured ChatGPT model (12 models, 1.6 s) and OpenCode Go (`deepseek-v4.1-flash`, 35 models, 1.7 s) without model changes. Local outage, repeated Test and recovery are covered by deterministic fixtures; no live gateway was stopped.

## Acceptance criteria

- [x] ChatGPT Test uses the Responses route without the rejected one-token output field; OpenCode Test supplies an opaque affinity ID without creating a conversation (HTTP request fixtures).
- [x] An unreachable gateway causes one discovery notice, never a generation request, and a subsequent success clears that notice (Agent and Client fixtures).
- [x] A previous model's generation warning is not attributed to a new default; credential/discovery failures retain their own meaning.

## Status

G0–G2 complete. No changes to remote branches.
