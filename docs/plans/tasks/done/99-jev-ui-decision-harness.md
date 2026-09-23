---
title: "Task 99 — General Jev UI Decision Harness"
status: ready_for_user_approval
current_gate: Complete — awaiting commit/push approval
remaining_estimate: 0%
---

# Task 99 — General Jev UI Decision Harness

## Goal

Turn the experimental Jev integration into a general, confidence-gated decision harness for browser and Sanad interactive testing, while making the Sanad Driver UI expose stable, verifiable message-body evidence.

## Locked Decisions and Scope

- Improve the existing `jev-dual-brain-automation` skill rather than create a flight- or messaging-specific skill.
- Code owns workflow state, irreversible-action admission, exact numeric/date operations, safety policy, deterministic assertions, and event-driven waiting.
- Jev supplies narrow semantic judgments over structured state and returns the full typed answer, including probabilities and confidence.
- Use hierarchical decisions when a child action depends on a page/screen classification; questions in one TypeSafe request remain independent.
- Every irreversible phase executes at most once. A completed phase cannot be re-entered because of later model classification.
- Low-confidence, blocked, unknown, repeated, oscillating, or no-transition states fail closed and escalate to System 2.
- Sanad automation uses stable keyed widgets and `sanad-dev ui`; coordinate actions are diagnostic fallback only.
- Add stable message-body selectors and snapshot text evidence for user and assistant Markdown. Clipboard inspection remains experimental evidence only and is not the durable solution.
- Preserve driver output safety: no secrets, no obscured text-field values, bounded snapshots, and no entered text echoed by action results.
- Update technical, QA, tester-skill, and Jev-skill documentation in the same change.
- Deliver all implementation and documentation through one focused pull request. Do not commit or push without user approval.

## Gates

### G0 — Discovery and contracts

- [x] Reproduce the original phase-loop failure and duplicate-action risk.
- [x] Prove confidence-gated flight search and booking-summary navigation.
- [x] Prove confidence-gated Sanad settings navigation.
- [x] Prove one-shot Sanad conversation creation, text entry, send, event-driven response completion, and exact response retrieval.
- [x] Identify missing message-body text/selector evidence in Driver snapshots.
- [x] Record the precise Client widget and inspector ownership points plus focused test locations.

### G1 — Jev client and generic harness

- [x] Repair the bundled Jev client and preserve complete typed answers, probabilities, confidence, and latency.
- [x] Support batched Choice, Score, and Noul questions without discarding response fields.
- [x] Implement reusable phase/state, confidence-routing, circuit-breaker, and System 2 escalation primitives.
- [x] Keep browser and Sanad adapters thin and free of scenario-specific route, date, or message constants.
- [x] Add focused deterministic tests for phase monotonicity, no-repeat safety, confidence rejection, no-transition detection, and event-driven waiting.

### G2 — Sanad Driver observability

- [x] Add stable message-body keys scoped by durable event identity for user and assistant text.
- [x] Make snapshot/find expose rendered message text for the supported Markdown/SelectableText boundary without duplicating wrapper rows.
- [x] Preserve existing redaction, bounded-output, and obscured-field rules.
- [x] Add widget/controller regression coverage for exact keyed message-body inspection and scoped lookup.

### G3 — Skill rewrite and evaluations

- [x] Rewrite `jev-dual-brain-automation/SKILL.md` around the verified software-owned workflow model.
- [x] Replace stale API guidance with live TypeSafe semantics: structured state, independent batched questions, probabilities, confidence routing, and jaggedness constraints.
- [x] Document browser and Sanad variants through progressive references rather than one scenario-specific script.
- [x] Add eval prompts and assertions covering browser form/search, Sanad navigation, Sanad messaging, low confidence, blockers, and post-send no-repeat behavior.
- [x] Compare the revised skill against the merged baseline and review the benchmark evidence.

### G4 — Documentation and verification

- [x] Update Flutter VM Driver technical and QA documentation.
- [x] Update the Sanad Client Tester skill for stable message-body inspection and event-driven response waiting.
- [x] Run format and analyzers with bounded output.
- [x] Run focused Client widget tests and standalone driver CLI tests.
- [x] Run skill/harness tests and evals.
- [x] Run live Driver verification from this worktree using its own managed runtime.
- [x] Run `graphify update .` and review the final diff.

## Acceptance Criteria

- [x] Given a broad safe candidate set, Jev returns a typed target with probabilities and confidence; the harness rejects a decision below its configured threshold.
- [x] Given an irreversible phase that already succeeded, later classification cannot execute that phase again.
- [x] Given a sent Sanad message, the harness waits on response lifecycle events without repeated Jev polling and never creates or sends again while waiting.
- [x] Given a rendered user or assistant message, `sanad-dev ui find` can locate a stable message-body key and return the rendered text without clipboard access.
- [x] Given a blocker, unknown state, repeated target, oscillation, or unchanged UI, the harness stops and emits a bounded System 2 escalation context.
- [x] Given exact dates, IATA codes, prices, counts, or arithmetic, deterministic code—not Jev—owns comparison and calculation.
- [x] Browser and Sanad scenarios use the same workflow engine with adapter-specific observation and execution only.
- [x] No tracked example contains an API key, secret, absolute repository path, or live user payload.

## Definition of Done

- [x] Code, tests, docs, and skill guidance agree on the same ownership model.
- [x] Relevant analyzers and focused tests pass with bounded output.
- [x] Skill evaluations demonstrate improved safety and correctness over the merged baseline.
- [x] Live Sanad verification proves stable message text and one-shot messaging behavior.
- [x] Graphify is updated.
- [x] Final diff is reviewed; commit, push, and PR creation remain pending explicit user permission.

## Verification Evidence

- Jev harness: 14 Python unit/contract tests passed; `compileall` passed.
- Client focused verification: 21 tests passed across message bodies, user messages, and Driver CLI; reasoning/EventTile tests passed separately.
- Client full fast suite: 1160 tests passed in 1m35s.
- Client analyzer: no issues found.
- Baseline contract comparison: merged baseline 0/12 versus revised skill 12/12 on the declared workflow-safety capabilities.
- Live worktree runtime: branch/source ownership matched, `.sanad-test` was used, and the runtime was stopped after verification.
- Live one-shot message: one conversation creation, one text entry, one send, blocked `wait-for` completion in 1282ms, and exact response `JEV_UI_HARNESS_OK_20260922`.
- Live exact-key inspection: both `user_message_body:<eventId>` and `assistant_message_body:<eventId>` returned exactly one element with rendered text and no clipboard use.
- Snapshot regression: internal Flutter `[#…]` text keys were removed from output; raw duplicate Text/RichText rows disappeared after Client restart.
- `git diff --check` and secret/absolute-path scans passed; Graphify was refreshed.
