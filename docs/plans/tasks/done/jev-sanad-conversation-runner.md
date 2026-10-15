---
title: "Jev Sanad Conversation Runner"
description: "Task gates for the tracked deterministic Sanad UI conversation runner with narrow Jev verification."
---

# Jev Sanad Conversation Runner

## Goal

Provide a tracked runner owned by Sanad Client Tester that accepts a target device, either an existing or new conversation, provider, model, and message; sends exactly once through the active driver-enabled Client; verifies receipt of a response through the reusable Jev judgment layer; and optionally returns to the captured origin conversation. Retain the original `temp/` entry point as a compatibility forwarder, keep the Jev skill general, and use progressive disclosure in Client Tester.

## Execution gates

- [x] **G0 — Runtime and contract discovery:** Confirm the managed driver Client, UI selector contract, existing Jev harnesses, and temp tracking policy.
- [x] **G1 — Deterministic workflow:** Implement exact device, conversation, model, text-entry, send-once, response-wait, and return phases.
- [x] **G2 — Jev boundary:** Use Jev only for narrow semantic response verification or bounded ambiguity; deterministic code owns ordering, retries, and irreversible phases.
- [x] **G3 — Configuration surface:** Support explicit target device, new/existing conversation, provider, model, message, response timeout, and origin-return behavior.
- [x] **G4 — Safety:** Fail closed on duplicate/missing selectors, unknown origin device, phase re-entry, response timeout, or ambiguous send outcome.
- [x] **G5 — Verification:** Pass Python compilation and focused parser/state tests; inspect the live Client without sending another message.
- [x] **G6 — Documentation:** Record usage, limits, and promotion criteria in the QA guide.
- [x] **G7 — Fast-path batching:** Reuse one VM connection per multi-step phase and skip model selection when the exact provider/model is already active.
- [x] **G8 — Live retry:** Use the requested `OpenCode Go / deepseek-v4-flash`, verify the new event-scoped response in the same Driver batch, and return to the captured origin conversation.
- [x] **G9 — Workspace-aware creation:** Accept an exact workspace for new conversations only, expose a unique workspace-scoped New Conversation key, and skip reselection when an empty new composer already has that workspace.
- [x] **G10 — Linux workspace live run:** Ask `Sanad Agent (Linux)` for available worktrees in workspace `sanad-agent`, return to origin, and emit the assistant response directly from the runner.
- [x] **G11 — Guaranteed return recovery:** Attempt origin restoration after every workflow outcome, preserve the primary failure, and accept the successful in-batch text wait when a user message-body key is not mounted.
- [x] **G12 — Destructive recovery live run:** Reopen the existing Linux conversation, remove the explicitly authorized worktree, verify its absence, and prove automatic return without manual UI recovery.
- [x] **G13 — Skill promotion:** Track the canonical runner and focused tests under the Jev skill while retaining the `temp/` entry point as a thin compatibility forwarder.
- [x] **G14 — Discoverability and verification:** Reference the canonical runner from the Jev and Client Tester skills, update QA guidance, and pass canonical plus compatibility checks.
- [x] **G15 — Client Tester information architecture:** Reduce the main skill to durable invariants and a task-to-reference routing table.
- [x] **G16 — Progressive-disclosure references:** Extract automated testing, interactive UI, runtime/worktree, connection switching, Jev conversation, and multi-question guidance into focused files.
- [x] **G17 — Sanad implementation ownership:** Move the Sanad UI adapter, conversation runner, and focused tests under Client Tester while preserving the temp compatibility entry point.
- [x] **G18 — General Jev boundary:** Keep reusable Jev judgment/workflow/browser resources in the Jev skill and replace detailed Sanad ownership with concise cross-references.
- [x] **G19 — Verification and documentation:** Update canonical paths, pass both skill suites and compatibility checks, run diff validation, and refresh Graphify.
- [x] **G20 — Canonical fast path:** Define direct runner execution as the default for supported conversation scenarios, without redundant external preflight commands.
- [x] **G21 — Diagnostic escalation boundary:** Load runtime, interactive UI, full Jev guidance, snapshots, status, and logs only when the canonical runner fails or the scenario exceeds its contract.
- [x] **G22 — Routing regression coverage:** Add skill-contract and routing-eval assertions for one-reference, one-command standard execution with no preliminary `status`, `snapshot`, or log reads.
- [x] **G23 — Fast-path documentation and verification:** Update QA guidance, pass both skill suites and compatibility checks, validate diffs, and refresh Graphify.

## Acceptance criteria

1. A single CLI invocation can target a named device and either create a new conversation or open an exact existing conversation.
2. Provider/model selection is verified by exact rendered text before message entry.
3. Conversation creation and message send are reserved as one-shot phases and never automatically retried after an ambiguous result.
4. Waiting uses `sanad-dev ui wait-for`, not Jev or snapshot polling.
5. A new event-scoped assistant message body is present and non-empty after completion; Jev separately judges whether it addresses the supplied message.
6. Return-to-origin uses captured conversation identity plus an explicit or deterministically observed origin device; otherwise execution fails before the first irreversible phase.
7. The canonical Sanad implementation and focused tests are owned by `.agents/skills/sanad-client-tester/`; the original `temp/` entry point remains available as a compatibility forwarder.
8. Client Tester uses progressive disclosure: its main skill contains only durable invariants and routing, while focused references own procedural detail.
9. The Jev skill remains general and owns only reusable judgment, workflow-safety, and browser resources plus a concise Sanad integration pointer.
10. Both relevant skills and the QA guide identify the canonical entry point.
11. Supported standard conversation requests execute through one canonical runner command without separate `status`, `snapshot`, log, or full Jev-skill preflight.
12. Diagnostic references and commands are loaded only after a structured runner failure or when the requested scenario is outside the runner contract.

## Progress

- Completed gates: 24/24
- Remaining: 0%
