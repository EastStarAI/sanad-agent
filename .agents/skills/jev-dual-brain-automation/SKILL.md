---
name: jev-dual-brain-automation
description: Build or run fast, confidence-gated browser and Sanad UI automation where deterministic code owns workflow state and TypeSafe Jev supplies narrow semantic judgments. Use for multi-step agent-browser flows, sanad-dev ui testing, repetitive forms, search/navigation, message verification, or UI automation that needs structured state, probabilities, no-repeat safety, event-driven waiting, circuit breakers, and System 2 escalation. Trigger even when the user asks for resilient or high-speed UI testing without naming Jev.
compatibility: Requires Python 3.9+, TYPESAFE_API_KEY, and either agent-browser or a driver-enabled Sanad runtime.
---

# Jev Dual-Brain Automation

Use Jev as a fast judgment primitive inside a workflow owned by software. Jev is not an agent: it does not own phases, retries, irreversible actions, arithmetic, dates, safety policy, or completion.

## Ownership model

| Owner | Responsibilities |
| --- | --- |
| Deterministic code | Phase order, structured state, candidate IDs, thresholds, exact dates/numbers, action execution, irreversible-action admission, event subscriptions, timeouts, assertions, and audit history |
| Jev (System 1) | One narrow semantic Choice, Score, or Noul judgment over supplied state |
| System 2 | Diagnose blockers, ambiguity, unknown screens, low confidence, oscillation, and policy-sensitive decisions |
| UI adapter | Observe the current surface and execute an exact action selected by code |

Do not ask Jev to “complete the task,” infer a multi-step plan, calculate totals, compare exact dates, or decide whether a risky action is allowed. Ask one snap judgment per question and compose the answers in code.

## Required workflow

1. **Define phases before acting.** Mark submit, send, purchase, delete, permission, and similar effects as irreversible.
2. **Observe structured state.** Include the goal, current phase, screen/page mode, relevant candidates, completed phases, and bounded action history as named JSON fields.
3. **Prune candidates deterministically.** Send stable IDs and concise descriptions. Never let Jev invent a selector.
4. **Classify hierarchically when decisions depend on each other.** First classify page/screen mode. In a later request, ask for the action among candidates valid for that mode. Questions in one request are independent; one answer cannot condition another answer in the same batch.
5. **Inspect the complete answer.** Choice and Score return probabilities plus confidence. Route low confidence or an invalid target to System 2 before acting. Noul is itself a yes probability and has no separate confidence field.
6. **Reserve the phase before an irreversible action.** A completed phase cannot re-enter. An attempted irreversible phase cannot be retried automatically after an ambiguous result.
7. **Snapshot immediately before acting.** Execute one exact adapter action, once.
8. **Wait for events, not repeated model calls.** Subscribe to navigation, lifecycle, response, or UI-transition events and block until a relevant event or timeout. Do not poll Jev while waiting.
9. **Verify after the event.** Use deterministic assertions for exact strings, IDs, dates, counts, and numeric values. Use a separate narrow Jev judgment only for semantic evidence.
10. **Escalate fail-closed.** Stop on low confidence, blockers, invalid candidates, unchanged UI, repeated targets, oscillation, timeout, or unknown state. Give System 2 bounded state, candidates, phase ledger, and recent actions.

Use `scripts/workflow_engine.py` for confidence admission, monotonic phases, no-repeat execution, event-driven waiting, and bounded escalation records. Use `scripts/jev_client.py` for typed answers. The browser and Sanad scripts are adapters, not autonomous goal loops.

## Jev request pattern

Prefer structured objects over prompt-shaped strings:

```python
from scripts.jev_client import JevClient
from scripts.workflow_engine import DecisionPolicy, admit_choice

client = JevClient()
response = client.ask(
    state={
        "goal": "Open the device Skills page",
        "phase": "select_settings_section",
        "screen_mode": "settings_navigation",
        "completed_phases": ["open_settings"],
        "candidates": {
            "nav_tile_skills": "Skills settings navigation tile",
            "nav_tile_mcp": "MCP settings navigation tile",
        },
    },
    questions={
        "target": {
            "type": "choice",
            "instructions": "Which candidate directly opens device Skills?",
            "criteria": {
                "nav_tile_skills": "Directly opens Skills",
                "nav_tile_mcp": "Opens MCP servers instead",
            },
        },
        "blocked": {
            "type": "noul",
            "instructions": "Is a blocker preventing safe interaction?",
        },
    },
)

if response.answer("blocked", "noul").noul >= 0.5:
    raise RuntimeError("Escalate blocker to System 2")

decision = admit_choice(
    response.answer("target", "choice"),
    state_candidates,
    DecisionPolicy(min_confidence=0.85),
)
```

Batch questions only when they are independent judgments over the same state. If the action candidate set depends on the page mode, make two requests.

## Browser variant

Load and follow the `agent-browser` skill for browser mechanics.

1. Open or connect to the intended browser/profile.
2. Take an interactive snapshot and build candidates from current `@eN` references.
3. Classify the current page mode when needed.
4. Ask Jev to choose only among candidates valid for that mode.
5. Admit by confidence and risk threshold.
6. Re-snapshot, execute one click/fill/press, and wait for the browser transition.
7. Re-observe and verify. Keep dates, airport codes, prices, counts, and sorting comparisons in code.
8. Stop before purchase, booking continuation, submission, or another irreversible boundary unless the user explicitly authorized it.

Use `scripts/dual_brain_browser.py` as the thin observation/action adapter. Never derive a fill value from the last word of a goal or infer an action type from vague label keywords.

## Sanad variant

Load and follow the `Sanad Client Tester` skill. Use a driver-enabled, worktree-owned runtime.

1. Run `sanad-dev ui snapshot --interactive --compact --json` before every action decision.
2. Prefer exact stable keys. Do not degrade to coordinates while a keyed target exists.
3. Run `sanad-dev ui tap --key <key>` or `enter-text --key <key> --text <value>` exactly once.
4. Verify the transition with `snapshot` or `find` after the action.
5. For messages, reserve conversation creation and send as irreversible phases. Enter text once, verify `chat_input`, send once, then wait on response lifecycle events without Jev polling.
6. Inspect message evidence directly:
   - `user_message_body:<eventId>`
   - `assistant_message_body:<eventId>`
7. Compare exact expected response text in code. Do not use clipboard as the primary verification path.

Use `scripts/dual_brain_sanad_ui.py` only for exact observations and actions. The workflow engine owns phase and retry policy.

## Confidence and risk

Choose thresholds from measured evals and action consequences; do not treat one threshold as universal.

- Read-only navigation can use a lower validated threshold.
- Form mutation should require stronger evidence.
- Irreversible or externally visible actions require the highest threshold plus explicit policy/user authorization.
- Low confidence means “do not act,” not “pick the top option anyway.”
- Check the selected option's probability when distribution shape matters; retain the full probability distribution for diagnostics.

## Circuit breaker and escalation

Trip before another action when any condition holds:

- the same target would be selected three times;
- four actions alternate between two targets;
- the post-action fingerprint equals the pre-action fingerprint;
- an irreversible or completed phase would re-enter;
- no relevant event arrives before the deadline;
- the chosen target is absent or below threshold;
- a blocker, unknown mode, or unsafe boundary is detected.

Escalation context should include only bounded, non-secret evidence: reason code, goal, phase, candidate summaries, completed/attempted phases, current fingerprint, and recent actions. System 2 may repair the state, but code must re-observe and re-admit the next action; never clear irreversible history.

## Verification checklist

- [ ] Structured state uses named fields rather than one concatenated pseudo-prompt.
- [ ] Dependent classifications are sequential and hierarchical.
- [ ] Choice/Score probabilities and confidence are retained.
- [ ] Every action target comes from the current observation.
- [ ] Exact data and arithmetic remain deterministic.
- [ ] Irreversible phases are reserved and cannot repeat.
- [ ] Waiting is event-driven and contains no repeated Jev/UI polling loop.
- [ ] Every action has a fresh pre-observation and post-event verification.
- [ ] Low confidence and blockers escalate before action.
- [ ] Secrets, entered values in action output, and obscured fields are not logged.

## Resources

- `scripts/jev_client.py` — typed Choice, Score, and Noul HTTP responses.
- `scripts/workflow_engine.py` — confidence gates, phase ledger, circuit breaker, event waiter, and escalation contract.
- `scripts/dual_brain_browser.py` — thin `agent-browser` adapter.
- `scripts/dual_brain_sanad_ui.py` — thin `sanad-dev ui` adapter.
- `references/api_reference.md` — verified TypeSafe request/response semantics.
- `references/failure_modes_and_recovery.md` — failure taxonomy and System 2 recovery boundary.
- `evals/evals.json` — browser and Sanad acceptance scenarios.
