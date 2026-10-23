# Decision-layer routing

Compare the decision layer with the testing agent that drives `sanad-dev ui`, not
with `sanad-dev ui` itself: the CLI is only the hands, and the agent is the brain
that currently pays for every step.

Today every UI step costs a full agent turn: a snapshot read, a reasoning pass over
tens of thousands of tokens, and another action call. The decision layer answers
the same bounded step with one closed-choice judgment over about 450 tokens. When a
scenario, or a stretch of one, can be decided that way, route those steps to the
layer and keep the agent out of the loop. The agent returns only on uncertainty or
a guard refusal.

## Cost and latency

| | Decision-layer step | Agent step |
| --- | --- | --- |
| Measured latency | **p50 342 ms, p95 957 ms, mean 411 ms** (P0 replay, n=48) | ≈**11 s** composed from measured parts: two `sanad-dev ui` invocations at 4.5–5.5 s CLI bootstrap each (a2 obstacle R2) plus one model turn (1.5 s mean for a fast chat model, a3 §1.2) |
| Reported range | **0.3–1 s** | 8–20 s (a3 §6.1, same composition) |
| Cost | **≈$0.00006 per step** (1,501–1,735 input tokens at the documented $0.042/M) | the same step carries the screen plus skill context: 30–60 k tokens per turn (a3 §6.1 model), roughly 70–140× the decision payload |
| Determinism | 24 of 24 decisions identical across repeated runs, 0 errors in 49 calls | sampling, context, and phrasing vary between runs |
| Replay | every step is a JSONL trace line | a transcript must be re-read |

So a decision-dense stretch of 20 steps costs about 8 s and $0.0012 with the layer,
against roughly 220 s and a correspondingly large context spend with the agent.
The real prize is not the headline latency: it is that re-runs are nearly free and
every step is reviewable.

A later end-to-end smoke over these fixtures (8 decisions on `jev-1.14.0`) recorded
6 correct admissions, 0 wrong actions, and 2 refusals by design, at p50 333 ms and
≈$0.000046 per decision, with candidate tables of 4–30 entries.

Sources: the P0 decision replay (b10 `REPORT.md`: criteria C4, C5, C6 and §2) and
the a2 live-test obstacle audit (obstacle R2, §2). Both live in the delegation run
archive for the live-tooling effort; they are not part of this repository, so the
numbers above are the durable record.

## USE the decision layer

Route a step to the layer when the next action depends on the current screen but is
chosen from a known, finite set:

- navigation between known destinations (`nav_tile_*`, settings back, sidebar shell);
- picking one listed option: a model option, an `ask_user` option, a conversation
  search result, a permission option;
- confirming or dismissing a reversible dialog;
- waiting for a state to settle, where the decision is "which of these now";
- fixed form flows in which each step is a listed control.

## KEEP the agent

- Judging visual or semantic correctness ("does this answer address the question",
  "does anything look broken").
- Unknown or unclassifiable screens: the classifier returns `unknown` and the layer
  refuses. Do not invent candidates for it.
- Authoring free text: the layer types only values supplied by code, and the model
  never generates the value.
- Diagnosing a failure: an escalation is evidence, not a bug report.
- Any irreversible step the scenario has not explicitly pre-authorized.
- Exploratory review where the candidate set is unknown by definition.

## Module layout

```text
.agents/skills/sanad-client-tester/scripts/decision_layer/
  modes.py        deterministic screen-mode classifier + detail refinement
  actions.py      the action table: scope per mode, tap/type, preconditions, irreversibility
  candidates.py   mode-scoped extractor: stable ids, enabled filter, structural pre-filter, cap 32, abstain/reobserve
  observation.py  one immutable snapshot with generation/status/fingerprint provenance
  guard.py        the code-owned precondition guard and its stable reason codes
  model.py        DecisionModel interface, DecisionContext/ModelChoice, fake, Jev, default deadline
  escalation.py   bounded escalation payload + resume contract
  trace.py        JSONL step trace, replay, summary
  layer.py        the step pipeline, phase re-entry, provider-failure isolation, dispatch-time revalidation
  cli.py          `decide` (with `--explain`) and `smoke`
  bridge.py       the only module that imports the Jev skill primitives
tests/fixtures/   24 sanitized captured snapshots + labelled decisions
```

Only `model.py` knows what Jev is. `bridge.py` is the only module that imports the
`jev-dual-brain-automation` primitives (`admit_choice`, `CircuitBreaker`,
`DecisionPolicy`); the guard, extractor, and classifier never see a provider.

## Screen-mode keyset

The classifier is a deterministic keyset over the snapshot. Overlay-first
precedence, and `unknown` rather than a guess.

| Mode | Proven by | Detail |
| --- | --- | --- |
| `permission_card` | `permission_option_*`, `permission_deny_submit_button` | `options`, `deny_comment` |
| `ask_user_card` | `predefined_option_<n>`, `custom_answer_option`, `clarifying_question_input`, `submit_question_answer_btn`, `back_to_options_btn` | `options`, `custom_input` |
| `model_picker` | `model_picker_search_input`, `model_picker_close_btn`, `model_option_*`, `recent_model_option_*` | `list`, `filtered` |
| `composer_popup` | `composer_permission_mode_*`, `thinking_mode_option_*`, `sidebar_device_item_*` | `permission_mode`, `thinking_mode`, `device_switcher` |
| `conversation_search` | `conversation_search_field`, `conversation_search_result:*` | `empty`, `results` |
| `settings` | `settings_back_to_conversations_btn`, `nav_tile_*`, `nav_device_*`, `nav_workspace_*` | page slug: `general`, `providers`, `mcp_servers`, `skills`, `overview`, `workspace`, `profile`, `device`, `navigation` |
| `conversation_running` | `stop_message_btn` | — |
| `conversation_idle` | `chat_input`, `send_message_btn` | — |
| `unknown` | none of the above | — |

The candidate table is scoped per mode: a permission card offers only its own
options, and the model picker offers only picker controls. That is what makes a
model list, a settings page, and a device page answerable at all; the screen-agnostic
table used in P0 silently removed the correct control on 2 of 24 states.

Two filters run before the model sees anything, and neither weakens the guard:

- a control reporting `enabled: false` is dropped;
- a control whose **structural** precondition fails on the snapshot is dropped and
  recorded in the trace as `pruned_ids`. The empty-field submit is the case that
  matters: with the field empty it is not a candidate at all, so the honest answers
  are `abstain` or "type into the field" instead of an escalation.

The guard still checks every precondition afterwards, on the live snapshot. The
pre-filter is a convenience in front of that gate, never a replacement for it.

## Guard rules

The guard runs **before any action is dispatched**, and again on a fresh snapshot at
dispatch time. A refusal is an escalation with a reason code, never an action. The
first failing rule wins, in this order:

| Reason code | Rule |
| --- | --- |
| `observation_not_ok` | the snapshot status is not `ok` |
| `not_settled` | the snapshot was captured while the tree was changing |
| `unknown_mode` | no declared mode matches the snapshot; never dispatch on a guess |
| `dialog_blocking` | an overlay owns the screen while the phase expects another surface |
| `mode_mismatch` | the phase's expected mode is not the live mode |
| `empty_candidate_table` | the mode is known but no declared control is valid |
| `phase_reentry` | the phase already completed an irreversible action and may not be decided again |
| `model_unavailable` | the decision model could not answer: network, timeout, HTTP error, redirect, or an unusable body |
| `model_contradiction` | the reply contradicted itself: probability keys, mass, or argmax disagree with the candidates |
| `model_abstained` | the model chose `abstain` |
| `model_reobserve` | the model asked for another observation |
| `invalid_target` | the selected id is not in the current table |
| `target_absent` | the control is gone from the live snapshot |
| `disabled_target` | the control reports `enabled: false` |
| `unclassified_target` | the control has no declared action rule |
| `precondition_failed` | a declared precondition failed: `field_filled:<key>`, `field_present:<key>`, `detail:<value>`, `mode:<value>` |
| `irreversible_not_authorized` | the action is irreversible and the phase did not pre-authorize that exact id |
| `low_confidence` | the confidence/selected-probability threshold was not met |
| `repeated_target` | the same target would be acted on a third time |
| `oscillation` | four prospective actions alternate between two targets |
| `no_transition` | the post-action fingerprint equals the pre-action fingerprint |
| `stale_observation` | reserved for an admission whose screen changed before dispatch |

Structural checks run before the confidence gate on purpose. P0 measured a wrong
action at **0.98** confidence ("submit the typed answer" while the field was
empty), so confidence cannot bound correctness here: it is a stall filter, never
the last gate. The field-state precondition is what makes that class of mistake
impossible instead of merely unlikely.

A provider failure is never an exception. `layer.decide` catches every failure the
model raises - network, timeout, HTTP status, redirect, malformed body, or a
self-contradictory reply - and returns an escalation instead. Its evidence carries
only the error class, the typed cause code, the HTTP status when there was one, and
the invariant a contradictory reply broke: never a response body and never a header.

## Irreversible actions

Irreversible means the action cannot be undone and creates an effect outside the
app's own state. Declared irreversible in `actions.py`:

| Class | Candidates |
| --- | --- |
| Send to an external party | `send_message_btn` |
| Delete | `delete_account_btn`, `remove_workspace_button`, `provider_instance_delete_*` |
| Permanent or "always" approvals | `permission_option_once`, `permission_option_session`, `permission_option_workspace`, `composer_permission_mode_*` except `default` |
| Sign out | `sign_out_btn` |
| Disruptive runtime operations | `device_restart_agent_button`, `device_apply_update_button` |

Each requires the phase to pre-authorize **that exact candidate id**; otherwise the
guard refuses with `irreversible_not_authorized`. Authorization is per phase, never
global, and it never survives a re-observation.

A phase that recorded an irreversible action is finished: requesting it again is
refused with `phase_reentry` before any model call, because an irreversible effect
that already happened cannot be re-authorized. A completed *reversible* phase may
repeat freely - that is how a multi-step navigation works - and an irreversible
phase that was decided but never recorded as executed does not burn the phase.

Deliberately **not** irreversible: `permission_option_deny` and
`permission_deny_submit_button`. Denial refuses a capability, cannot create an
external effect, and is repeatable. Conversation creation is also not irreversible,
but it is a one-shot phase: never retry it after an ambiguous outcome.

## Running it

```bash
# Read a screen without spending a model call: mode, evidence, candidate table.
PYTHONPATH=.agents/skills/sanad-client-tester/scripts \
  python3 -m decision_layer decide \
  --snapshot .agents/skills/sanad-client-tester/tests/fixtures/snapshots/20-permission-card.json \
  --goal "Approve this file read for this one time only" --phase approve_once --explain

# Decide with a real model, authorizing exactly one irreversible control.
PYTHONPATH=.agents/skills/sanad-client-tester/scripts \
  python3 -m decision_layer decide --snapshot <snapshot.json> \
  --goal "Approve this file read for this one time only" --phase approve_once \
  --expect-mode permission_card --authorize permission_option_once \
  --trace .agent/decision-trace.jsonl

# Offline dry run with a scripted model: no network, no key.
PYTHONPATH=.agents/skills/sanad-client-tester/scripts \
  python3 -m decision_layer decide --snapshot <snapshot.json> --goal g --phase p \
  --model fake:abstain:1.0
```

Exit code `0` means admitted, `3` means escalated. `smoke` replays the fixture set
end to end with the real model and writes a trace plus a summary; it is budgeted to
eight decisions (sixteen calls).

One decision is bounded by a **4 s** default deadline (`DEFAULT_DECISION_TIMEOUT` in
`model.py`, `DEFAULT_TIMEOUT` in `jev_client.py`). P0 measured p50 342 ms and p95
957 ms, so four seconds is three times the slowest observed call and still short
enough to hand the step back to the agent. Override it per model, per client call, or
from the CLI with `decide --timeout <seconds>`; the smoke command accepts it too.

## Reading an escalation

A refusal returns a bounded payload; nothing in it is a secret or an entered value:

```json
{
  "reason_code": "precondition_failed",
  "detail": "clarifying_question_input is empty, so this action would have no effect",
  "goal": "Submit the custom answer",
  "phase": "submit_custom_answer",
  "screen_mode": "ask_user_card",
  "screen_detail": "custom_input",
  "candidate_ids": ["clarifying_question_input", "submit_question_answer_btn", "..."],
  "selected": "submit_question_answer_btn",
  "confidence": 0.98,
  "irreversible": false,
  "completed_phases": ["open_conversation"],
  "recent_actions": [{"phase": "open_conversation", "target": "unscoped:..."}],
  "snapshot": {"ref": "17-ask-user-custom-input.json", "generation": 115},
  "guard": {"precondition": "field_filled:clarifying_question_input", "filled": false}
}
```

Read it in this order:

1. `reason_code` and `guard` say what code objected to; a precondition failure is a
   mechanical fact, not a model error.
2. `mode` and `mode_detail` say what the screen actually was; a mismatch means the
   scenario's phase expectation is stale.
3. `selected` and `confidence` say what the model wanted; a high-confidence wrong
   answer is the case the guard exists for.
4. `candidate_ids` say what was even available; if the right control is missing, fix
   the action table or the fixture, not the model, and check `pruned_ids` in the
   trace for a control the structural filter removed.

A `model_unavailable` escalation means the provider failed, not the scenario: read
`guard.status` (429 and 5xx are retryable later, 401/403 are configuration) and
`guard.error_code` (`network`, `timeout`, `http_error`, `redirect`, `malformed`).
Nothing was dispatched, so the step can be re-observed and decided again. A
`model_contradiction` escalation names the invariant in `guard.invariant` and means
the reply was internally inconsistent; do not retry it into an action, hand the step
to the agent.

### Resume

1. Re-observe the screen and rebuild the table; do not replay the refused action.
2. Preserve completed and irreversible-attempted phases; never clear history, and
   never re-request a phase that a `phase_reentry` refusal named.
3. Decide only the next safe, retryable step, and re-apply the guard.
4. A second escalation in the same phase ends the run deterministically.

## What the layer does not do

- It does not dispatch actions; the caller performs exactly one driver action.
- It does not type content of its own or generate a value.
- It does not recover an unknown screen: that is an escalation by design.
- It does not decide task completion or judge rendered output.
- It does not retry an ambiguous irreversible action, ever.

## Kill criteria

Stop routing work to the layer if, after the first live scenario, any of these
holds: **≥15 %** of decisions escalate on the scoped scenarios; **≥1** wrong
irreversible action above the floor in 20 runs; measured per-decision wall clock
**>6 s**; or the trace cannot explain every escalation. Record the numbers, then
either extend or stop; "continue and see" is not an outcome.
