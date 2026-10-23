---
title: "Jev Sanad UI Automation"
description: "Hybrid contract for Jev-assisted Sanad Client automation: the conversation runner, the guarded decision layer, escalation, and the kill criteria."
---

# Jev Sanad UI Automation

## Scope and comparison baseline

Two tracked components drive a managed, driver-enabled Sanad Client with a fast
decision model:

1. `.agents/skills/sanad-client-tester/scripts/sanad_conversation_workflow.py` — the
   canonical one-message conversation runner.
2. `.agents/skills/sanad-client-tester/scripts/decision_layer/` — the guarded
   decision layer that routes a stretch of a scenario away from the testing agent.

Compare the decision layer with **the agent that drives `sanad-dev ui`**, not with
`sanad-dev ui` itself: the CLI is only the hands. Today every UI step costs a full
agent turn — a snapshot read, a reasoning pass over tens of thousands of tokens, and
another action call. The decision layer answers the same bounded step with one
closed-choice judgment over roughly 450 tokens.

`.agents/skills/sanad-client-tester/scripts/sanad_conversation_workflow.py` is the
only tracked entry point for the runner. Any `temp/` wrapper is an untracked,
environment-local convenience: it is not part of the repository contract, it does
not exist in a fresh worktree or CI checkout, and nothing in this document depends
on it.

## Ownership

| Owner | Responsibilities |
| --- | --- |
| Deterministic code | Screen-mode classification, candidate extraction and scope, action semantics, preconditions, irreversibility authorization, thresholds, dispatch-time revalidation, the step trace |
| Decision model (Jev or any other) | One narrow closed-choice judgment per step over the supplied candidate table |
| Testing agent (System 2) | Authoring, diagnosis, semantic and visual judgment, unknown screens, and every escalation |

The model never selects a device, invents a key, produces a typed value, retries a
send, authorizes an irreversible action, or decides that a task is complete.

## The conversation runner

The runner accepts an exact target device, either a new conversation or one visible
existing conversation, an exact provider/model pair, and one message. It verifies a
newly rendered response and can return to the conversation selected before
execution.

- deterministic code owns phases, exact selectors, one-shot conversation creation
  and send admission, event waiting, event-body verification, and return
  navigation; related actions in one phase use one Driver batch connection;
- Jev performs only a final semantic judgment that the newly rendered assistant
  response addresses the supplied message;
- missing, duplicate, hidden, or mismatched selectors fail closed instead of being
  guessed.

For a supported standard conversation request with all required inputs, the runner
is the fast path and should be the first execution command. Do not precede it with
separate `sanad-dev status`, UI snapshot/find, log reads, `--help`, or manual Jev
calls. The runner requires:

1. exactly one selected origin conversation captured before switching devices;
2. each device option resolved by `sidebar_device_item_<exact name>`;
3. for a workspace-bound new conversation, one exact `workspace-group:<id>` and
   `sidebar_new_conversation_btn:<id>`;
4. the active `Provider | model` inspected first, skipping the picker when it
   already matches;
5. a refusal to overwrite a non-empty composer;
6. new-conversation creation and send reserved as irreversible one-shot phases;
7. a `stop_message_btn` lifecycle wait plus message-body evidence, never polling;
8. one new exact `user_message_body:<eventId>` and a new non-empty
   `assistant_message_body:<eventId>`;
9. a Jev semantic probability of at least `0.75`;
10. origin restoration after success or failure, with the primary error preserved.

## The decision layer

The layer turns "what should I do on this screen" into a guarded, replayable step:

```text
snapshot ──► mode classifier ──► mode-scoped extractor ──► guard (pre)
                                                             │
                                          decision model ◄───┘
                                                │
                                    guard (post) ──► confidence filter ──► circuit breaker
                                                │
                                  admitted action / bounded escalation ──► JSONL trace
```

Module layout and the exact CLI invocations live in
`.agents/skills/sanad-client-tester/references/decision-layer-routing.md`; that
reference is also the agent-facing routing rule. This page owns the contract.

### What the model may and may not see

- Structured state with named fields: goal, phase, screen mode and detail, completed
  phases, recent actions, and the closed candidate table.
- Stable ids derived from widget keys, plus the descriptions extracted from the live
  tree.
- No entered text (only `[empty]`/`[filled]`), no secrets, no screenshots, and no
  conversation transcript.

### Measured behaviour on this surface

The P0 offline replay measured 24 captured states with 49 model calls:

| Metric | Result |
| --- | --- |
| Answerable top-1 (17 decisions) | 100 % |
| Trap decisions | 5 of 7 correct; **2 wrong** |
| Wrong-pick confidence | **0.96–0.98**, above every correct answer in the 0.85–0.95 band |
| Confidence saturation | 22 of 38 correct acting calls at exactly 1.00 |
| A floor that separates wrong from right | **none** (`separating_floors: []` for 0.50–0.99) |
| Latency | p50 342 ms, p95 957 ms (n = 48) |
| Cost | ≈$0.00006 per call (1,501–1,735 input tokens at $0.042/M) |
| Run-to-run stability | 24 of 24 decisions identical |

A later end-to-end smoke over the curated fixtures (8 decisions, 8 calls, model
`jev-1.14.0`) recorded **6 correct admissions, 0 wrong actions, 2 refusals by
design** (the empty-field submit and an unauthorized account delete), p50 333 ms,
p95 433 ms, ≈$0.000046 per decision over 8,825 input tokens. The same smoke is the
only code path that spends real model calls; its budget is 20.

**Consequence, and the central law of this contract: confidence does not bound
correctness on this surface, so it can never be the last gate before an action.**
The layer therefore puts a code-owned guard in front of the model's output, gates
irreversible actions on an explicit per-phase authorization, and scopes the
candidate table per screen mode.

### Guard

The guard runs before any action is dispatched and is re-run on a fresh snapshot at
dispatch time. It refuses with a stable reason code instead of acting:

| Reason code | Rule |
| --- | --- |
| `observation_not_ok` | snapshot status is not `ok` |
| `not_settled` | the snapshot was captured while the tree was still changing |
| `unknown_mode` | no declared mode matches the snapshot; never dispatch on a guess |
| `dialog_blocking` | an overlay owns the screen while the phase expects another surface |
| `mode_mismatch` | the phase's expected mode is not the live mode |
| `empty_candidate_table` | the mode is known but no declared control is valid |
| `model_abstained` | the model chose `abstain` |
| `model_reobserve` | the model asked for another observation |
| `invalid_target` | the selected id is not in the current candidate table |
| `target_absent` | the control is gone from the live snapshot |
| `disabled_target` | the control reports `enabled: false` |
| `unclassified_target` | the control has no declared action rule |
| `precondition_failed` | a declared precondition failed (`field_filled:<key>`, `field_present:<key>`, `detail:<value>`, `mode:<value>`) |
| `irreversible_not_authorized` | the action is irreversible and the phase did not pre-authorize that exact id |
| `low_confidence` | the confidence/selected-probability threshold was not met |
| `repeated_target` | the same target would be acted on a third time |
| `oscillation` | four prospective actions alternate between two targets |
| `no_transition` | the post-action fingerprint equals the pre-action fingerprint |
| `stale_observation` | reserved for an admission whose screen changed before dispatch |

Ordering is part of the contract: structural checks run first, the confidence filter
last. A precondition failure on an empty text field is reported as
`precondition_failed` even when the model returned 0.98, and even when the model was
also uncertain.

### Irreversible actions

Delete, send to an external party, permanent or "always" approvals, sign-out, and
disruptive runtime operations (`device_restart_agent_button`,
`device_apply_update_button`) are never executed on the model's decision alone. They
require the phase to pre-authorize that exact candidate id; otherwise the guard
refuses with `irreversible_not_authorized`. Authorization is per phase and is
re-checked at dispatch.

### Escalation and resume

An escalation is a bounded payload with the reason code, goal, phase, screen mode
and detail, the candidate ids that were available, the selected id with its
confidence, the completed phases, the recent actions, and a snapshot reference
(mode, generation, fingerprint, element count). It carries no secret and no entered
value.

Resume contract:

1. Read `reason_code` and `guard` first; a precondition failure is a mechanical fact.
2. Re-observe the screen and rebuild the candidate table; do not replay the refused
   action.
3. Preserve completed and irreversible-attempted phases; never clear history.
4. Decide only the next safe, retryable step and re-apply the guard.
5. A second escalation in the same phase ends the run deterministically.

### Trace

Every decided step appends one JSONL line: step index, timestamp, goal, phase,
expected mode, classified mode with its evidence keys, the snapshot reference
(generation, fingerprint, element count), the full candidate id set, the ids removed
by the 32-item cap, the model name and latency, the selected id with confidence and
selected probability, the verdict, the reason code when refused, and the admitted
action. A trace is sufficient to re-judge every step without the model, and the
skill tests assert its shape.

## Routing rule

**Route to the decision layer** when the next action depends on the current screen
but is chosen from a known, finite set: navigation between known destinations,
picking one listed option, confirming a reversible dialog, waiting for a state, and
fixed form flows.

**Keep the agent** for visual or semantic judgment, unknown screens, free-text
authoring, failure diagnosis, exploratory review, and any irreversible step the
scenario has not pre-authorized.

Cost and latency basis: a decision step is 0.3–1 s and ≈$0.00006 (P0, measured);
an agent step is ≈11 s and carries 30–60 k tokens of context, composed from measured
CLI bootstrap (4.5–5.5 s per invocation) and model-turn latency. The agent step is
an estimate from measured components, not a direct measurement.

## Kill criteria

Stop the investment if, after the first live scenario, any of these holds:

- ≥15 % of decisions escalate on the three scoped scenario families;
- ≥1 wrong irreversible action above the floor in 20 runs;
- measured per-decision wall clock > 6 s;
- the trace cannot explain every escalation.

State the numbers, then extend or stop explicitly.

## Invariants

- The guard, the extractor, and the mode classifier never import a provider.
- The candidate table is closed, mode-scoped, capped at 32 including `abstain` and
  `reobserve`, and built only from declared controls; an undeclared control is
  invisible by design and fails closed as `unclassified_target`.
- Entered values, obscured fields, authentication URLs, and unrelated UI content are
  never sent to a model and never written to a trace.
- An ambiguous irreversible result is escalated, never retried.
- Wait on lifecycle or UI events; never poll the model or the snapshot.
