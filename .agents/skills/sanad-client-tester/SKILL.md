---
name: Sanad Client Tester
description: Comprehensive testing and interactive verification protocol for the Sanad Flutter client, including analyzer, unit, widget, E2E, managed-runtime, and agent-driven UI testing through the Dart VM Service. Use whenever validating Client changes, controlling a driver-enabled Sanad UI, testing conversations or connection switching, or selecting the correct Client verification boundary.
---

# Sanad Client Tester

Use this skill to select and execute the smallest reliable verification boundary for the Sanad Flutter Client. The main file owns invariants and routing only; load the focused reference that matches the task instead of reading every procedure.

## Non-negotiable invariants

- Use `fvm` for every Flutter or Dart operation.
- Analyze before testing, then run focused unit/widget coverage; broaden only when the change surface requires it.
- Use `--concurrency=1` only for tests that bind ports or exclusive resources.
- Keep successful analyzer and test output to the final five lines while preserving exit status through `pipefail`; rerun only a failure unfiltered.
- Use `sanad-dev` for managed runtime discovery and control. Never infer ownership from process age, directory naming, or a hardcoded port.
- Before a UI action, inspect current state and resolve a unique stable key. Do not fall back to coordinates while a keyed target can be added or discovered.
- Treat create, send, delete, submit, and similar effects as one-shot phases. Never retry an ambiguous irreversible action automatically.
- Wait on lifecycle or UI events rather than snapshot/model polling, then verify the resulting state deterministically.
- Do not stop, restart, or mutate a runtime not proven to be owned by the current worktree. Runtime source switching requires explicit user authorization under the repository contract.
- Keep logs bounded and free of secrets or entered values.

## Canonical conversation fast path

When a request fits `scripts/sanad_conversation_workflow.py` and supplies its required device, conversation, provider/model, message, and return inputs, load only `references/jev-conversation-automation.md` and execute the runner immediately. Do not run separate `sanad-dev status`, `snapshot`, `find`, log reads, `--help`, or full `jev-dual-brain-automation` skill loading first. The runner's internal ownership resolution, snapshot, exact-key admission, one-shot phase ledger, event waits, Jev call, and return verification are the preflight and execution boundary.

Escalate to runtime/UI references and diagnostic commands only after a structured runner failure or when the requested workflow is outside the runner contract. Never retry an ambiguous send during escalation.

## Routing table

Load only the references needed for the requested task:

| Task | Required reference |
| --- | --- |
| Select analyzer, unit, widget, integration, or E2E coverage | [`references/automated-testing.md`](references/automated-testing.md) |
| Inspect or control a live driver-enabled Client | [`references/interactive-ui-testing.md`](references/interactive-ui-testing.md) |
| Launch, discover, isolate, restart, or stop a managed runtime/worktree | [`references/runtime-and-worktrees.md`](references/runtime-and-worktrees.md) |
| Verify local-to-cloud connection switching | [`references/connection-switching.md`](references/connection-switching.md) |
| Send and verify one conversation through deterministic orchestration plus Jev | [`references/jev-conversation-automation.md`](references/jev-conversation-automation.md) |
| Test multi-question `system.ask_user` parsing and navigation | [`references/multi-question-ui.md`](references/multi-question-ui.md) |

For manual or custom live UI work, load both `interactive-ui-testing.md` and `runtime-and-worktrees.md`. The canonical conversation fast path is the explicit exception: its bundled runner imports the reusable Jev layer programmatically, so loading the full Jev skill or manual UI/runtime references before execution is redundant. Load them only to design, modify, or diagnose custom automation.

## Boundary selection

1. Classify the change surface before running anything.
2. Prefer static analysis and focused deterministic tests.
3. Add full fast-suite coverage only for broad/shared changes.
4. Add integration/E2E only for real socket, daemon/client, persistence, port, runtime-isolation, or other system boundaries that mocks cannot validate.
5. Use a live driver-enabled Client last, when static tests cannot prove behavior or interactive/visual evidence is explicitly required.

## Bundled resources

- `scripts/sanad_conversation_workflow.py` — canonical parameterized conversation runner.
- `scripts/dual_brain_sanad_ui.py` — thin exact-key `sanad-dev ui` adapter; it does not plan goals.
- `tests/test_sanad_conversation_workflow.py` — focused deterministic runner tests.
- `evals/evals.json` — realistic routing scenarios for each specialized section.
