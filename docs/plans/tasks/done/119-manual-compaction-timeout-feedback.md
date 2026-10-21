---
id: 119
title: Truthful feedback for slow manual compaction
status: completed
created: 2026-10-21
split_from: 106 (slot 1B)
delivery: own PR from fix/119-manual-compaction-timeout-feedback
---

# Task 119 — Truthful Feedback for Slow Manual Compaction

> Split from Task 106 slot 1B and delivered as its own PR.

## Goal

A manual compaction that is still running must never show a failure toast. The Client shows pending while the operation runs. Then it shows the real outcome: completed, failed with a reason, or rejected (for example busy or nothing to compact).

## Problem

- User report (2026-10-20): an error toast appears about 10–15 s after requesting compaction, while the same operation keeps running and later succeeds.
- Static mechanism, from the Task 106 compaction-toast triage (worktree-local evidence, not committed):
  - Client `ConversationCommands.compactSession` uses the gateway's 10 s default request timeout.
  - `request` converts a timeout to `null`, and an empty result reaches the failure-toast handling.
  - Agent `handleCompactCommand` awaits `runCompaction` before sending `session.compact_result`, so a slow summary always outlives the RPC.
- The user's actual runtime timing was not reproduced, so the mechanism is verified only statically.

## Boundaries

- Do not raise the global gateway timeout. Do not infer admission from silence, and never resend the compaction on timeout: one dispatch per request.
- Keep real failures visible. A late success must still update the timeline and history.
- Correlate results by session and request. Deduplicate late lifecycle events, so the same outcome is never shown twice.
- Changing admission to unawaited requires owner-valid proof of failure, busy and durability; otherwise keep the awaited result and fix the Client handling of timeouts.
- Localize new text in English and Arabic. Update the owning Client and Agent docs in the same change.

## Gates

- [x] Deterministic red→green tests for the delayed-result path: RPC timeout followed by a late success, a late failure, and busy or rejected.
- [x] Smallest owning-boundary repair, with focused analyzer and tests passing.
- [x] Coordinator manual review (3 rounds: pending/late-result correlation, settlement-leak fix, CLI docs, REPL one-dispatch).
- [x] Live acceptance on Test Home: a slow successful compaction shows no failure toast and does show completion. This takes one Test Home slot after 106b, in turn.
  - Focused evidence: client 35 + 29 tests, agent 65 tests green; Client and Agent analyzers clean.
- [ ] Commit and PR under explicit authorization; exact-SHA green CI. Merging is user-owned.

## Implementation Notes (writer, 2026-10-21)

- **Root cause confirmed from source:** the Client `ConversationCommands.compactSession` used the gateway's 10 s default, `SocketConversationCommandGateway.request` turns a timeout into `null`, the `{}` fallback parses as `outcome: failed`, and the composer showed the unexpected-error toast. The Agent `handleCompactCommand` awaits `runCompaction`, so `session.compact_result` carries the terminal outcome and arrives after a slow summary; the late result was dropped because its waiter was gone and the event handler ignores it.
- **Design:** Client-only repair; the Agent keeps the awaited result (no admission change, so no new failure, busy or durability proof is needed). A timeout becomes `pending` with a neutral en/ar notice. A listener registered before the single dispatch correlates the late result by session and request and settles once; a late failure or rejection is shown once and only for the session still shown; a late success relies on the lifecycle tile. No resend and no global timeout change. Without a result in 10 minutes the outcome is `unconfirmed`, never failed.
- **Owning docs:** `docs/technical/context_compaction.md` §4.3.3, `client/lib/features/conversations/AGENTS.md`, `docs/qa_maintenance/context_compaction_qa.md`.
- **CLI REPL `/compact` (approved scope addition):** the REPL called `LocalGatewayCliClient.compactSession` with the default `resendOnTimeout: true`, so a timeout sent `session.compact` a second time and reported `dispatched` as success. The daemon's `accepted` (completed) outcome also rendered as a warning. Now the REPL sends exactly one dispatch (`resendOnTimeout: false`), renders a timeout as a neutral still-running notice, renders `accepted`/`no_op` as completed, and renders other outcomes with their reason. The client default stays `true`: the only other production caller (`sanad session compact`) already passes `false`, and `local_gateway_cli_client_test.dart` explicitly covers the resend path.
- **CLI docs corrected:** `docs/technical/sanad_cli_architecture.md` (`session compact` row and REPL `/compact`) and `docs/qa_maintenance/cli_session_observability_intervention_qa.md` §6 now state that the daemon reply carries the terminal outcome, not admission.

## Live Acceptance (Test Home, round 1, 2026-10-21)

- Client composer `/compact`, slow path (summary 16.4 s): neutral info toast at +10.0 s, completed tile and `session.compact_result` at +16.5 s, zero error toasts, exactly one dispatch and one operation row.
- CLI REPL `/compact`, slow path (16.3 s): neutral still-running notice at +10.0 s, no success or error line, exactly one dispatch and one operation row.
- Not run live: fast `/compact` regression, late failure and late busy. These are covered by deterministic tests only.
