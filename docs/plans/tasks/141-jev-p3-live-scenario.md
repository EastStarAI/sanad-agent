---
title: "Task 141 — Jev P3: First Live Decision-Layer Scenario"
description: "Close the two P1 review findings (endpoint and model overrides, requests-per-minute and USD brake) and run one multi-step Sanad UI scenario on the isolated Test Home under a hard US$1 ceiling, with the direct-routing rule published in Client Tester and a recorded kill-criteria verdict."
status: in progress
current_gate: G4 pending a live run
remaining_estimate: 15%
base_commit: d9a6621d
depends_on: "Task 99 (decision harness), Jev Sanad Conversation Runner, and the P1 findings in docs/qa_maintenance/jev_sanad_ui_automation.md"
---

# Task 141 — Jev P3: First Live Decision-Layer Scenario

## Goal

Run one multi-step Sanad UI scenario live with its decidable steps answered by the decision model instead of the testing agent, under a requests-per-minute limit and a hard per-run US$ ceiling, so the P3 kill criteria are measured from the trace rather than argued.

## Locked Decisions and Scope

Locked by the requester:

1. **F-06 endpoint and model overrides.** `JevClient` takes its base URL and model from configuration or the environment; `https://api.typesafe.ai/v1/systemone` and `jev-latest` stay the defaults.
2. **F-10 rate and cost brake.** `DecisionLayer` and `JevDecisionModel` gain a requests-per-minute limit and a per-run USD ceiling. Tripping either one stops the loop and escalates to the agent.
3. **First live scenario.** One multi-step UI scenario on the isolated Test Home `~/.sanad-test` (TH1); decidable steps routed directly to the decision model; a total budget of US$1.00 enforced by the brake; no cost or speed benchmark.
4. **API key.** Supplied by the user in the process environment as `TYPESAFE_API_KEY`. Agents never enter, echo, print, or persist it: no value in this file, the trace, logs, commits, or the PR body. Preflight proves presence only.
5. **Skill rule.** `sanad-client-tester` states: "if a step can be done by the decision model, route it there directly, without LLM thinking".

Decided here because the brief leaves them open:

- Environment keys are `TYPESAFE_API_URL` and `TYPESAFE_MODEL`. Explicit constructor arguments win over the environment, and the environment wins over the class constants, so the existing `JevClient.API_URL` test seam keeps working.
- The brake refuses instead of sleeping: a call that would cross either limit returns an escalation with reason code `rate_limited` or `cost_ceiling_reached`. Both codes join `guard.REASON_CODES`, so `test_documented_guard_codes_match_the_code` forces them into the QA page and the routing reference.
- One price constant owns the estimate (`USD_PER_MILLION_INPUT_TOKENS = 0.042`, currently inside `smoke.py`); `smoke.py` and the brake import the same value.
- Spend uses `ModelChoice.metadata["input_tokens"]`; a reply without usage is charged a documented conservative estimate and marked estimated, so an omitted field cannot bypass the ceiling.
- Dispatch stays with the agent: the layer admits, the agent performs exactly one `sanad-dev ui` action per admitted step. No new loop runner unless G4 proves the manual cadence is the blocker.
- Wall clock and escalation rate are kill-criteria evidence, not benchmarks: no before/after comparison and no cost or throughput target.

Out of scope: browser scenarios, three-family escalation statistics, provider or model alternatives beyond what F-06 enables, and any change to guard ordering, candidate extraction, or mode classification.

## Gates

### G0 — Discovery and baseline

- [x] Re-read the P1 findings and kill criteria, and record exactly where the overrides and the brake attach in `jev_client.py`, `model.py`, and `layer.py`.
- [x] Record pre-change baselines: `python3 -m unittest discover -s .agents/skills/sanad-client-tester/tests` (115 pass), `python3 -m unittest discover -s .agents/skills/jev-dual-brain-automation/tests` (29 pass), `fvm dart run scripts/lint_wiki.dart` (exit 0).
- [x] Confirm TH1 (`~/.sanad-test`, worktree `.agent/worktrees/test-home`) is free for the live run and that key presence can be proven without printing the value.

G0 record:

| Item | Finding |
| --- | --- |
| P1 findings | `docs/qa_maintenance/jev_sanad_ui_automation.md` §"Deferred to P3" (two findings) and §"Kill criteria" (four criteria), re-read before any edit |
| Override attachment | `jev_client.py`: the `JevClient.API_URL` class constant and the `model` constructor default are the only origin/model sources, and `ask` reads `self.API_URL` and sends `self.model`, so resolution belongs in `__init__`. `model.py`: `JevDecisionModel.__init__` derives its model from its argument or `client.model`, and `from_environment` is the single Jev construction point for `build_model("jev")` |
| Brake attachment | `layer.py`: `DecisionLayer.__init__` is the injection point, and the seam between `evaluate_pre` and `self.model.choose(...)` in `decide` is the only place that runs after the screen guards and before the provider call; `ModelChoice.metadata` already carried `usage.input_tokens`, and `smoke.py` held the duplicate price constant |
| Baselines | client-tester 115 pass, jev 29 pass, `lint_wiki` exit 0 (all three reproduced before the first edit) |
| TH1 state | **Not free.** A live `sanad-dev` runtime is already up from `.agent/worktrees/test-home` (launcher pid 64865, agent port 58107, started 12:39 local), and a delegate coding worker (pid 14979) runs with that path as its execution root. Nothing was stopped or started here; the G4 live tester must reset `test/test-home` to the candidate SHA and confirm with `sanad-dev status` there before the run |
| Key preflight | `[ -n "$TYPESAFE_API_KEY" ] && echo present` proves presence without echoing the value; it reported absent in this implementer's environment, which is expected because G4 supplies it |

### G1 — F-06 endpoint and model overrides

- [x] `JevClient` resolves base URL and model from arguments, then `TYPESAFE_API_URL` / `TYPESAFE_MODEL`, then today's constants.
- [x] `JevDecisionModel.from_environment` passes the URL through so `build_model("jev")` needs no scenario edit.
- [x] No key material in a new code path, error text, or repr.
- [x] Focused tests: environment override, argument precedence, default when unset, redirect still refused.

### G2 — F-10 rate and cost brake

- [x] One brake owner holds the requests-per-minute window and the per-run USD ceiling, wired into `DecisionLayer.decide` before the model call.
- [x] Tripping either limit returns an escalation (`rate_limited`, `cost_ceiling_reached`) carrying the limit, observed value, spend, and remaining budget; no model call happens after the trip.
- [x] `JevDecisionModel` exposes the spend inputs the brake needs (input tokens, model name), and the duplicated price constant is replaced by the shared one.
- [x] Tests: RPM trip, ceiling trip before an over-budget call, missing usage charged conservatively, refused call leaves the model uncalled.

### G3 — Skill routing rule

- [x] Confirm whether `sanad-client-tester` already states the direct-routing rule. **Finding: it does not** — `SKILL.md` routes on "chosen from a known, finite set" and never says to route directly without LLM thinking, so this task adds the rule.
- [x] Add the rule verbatim to the `## Decision-layer routing rule` section of `SKILL.md`, keeping the file inside its 100-line contract-test bound (currently 71).
- [x] Align `references/decision-layer-routing.md` and the "Routing rule" section of `docs/qa_maintenance/jev_sanad_ui_automation.md`, and extend eval 7's expected output.

### G4 — First live scenario on TH1

- [ ] Declare the phases and which are decidable before running: settings navigation, model picker selection, device switch, and one conversation send, each checked against the mode keyset.
- [ ] Load the candidate into TH1's own worktree (`.agent/worktrees/test-home`): stay on branch `test/test-home`, run `git reset --hard <candidate sha>` (never detach HEAD), then apply the lightest `sanad-dev` restart there and confirm ownership and SHA with `sanad-dev status`. Never start a second runtime on `~/.sanad-test` from another worktree.
- [ ] Prove `TYPESAFE_API_KEY` is present without printing it; stop before any model call when absent.
- [ ] Execute the scenario with the brake armed at US$1.00 and the requests-per-minute limit; route every decidable step to the model and dispatch exactly one `sanad-dev ui` action per admitted step.
- [ ] Escalate, never retry, on a guard refusal, `model_unavailable`, `model_contradiction`, `rate_limited`, or `cost_ceiling_reached`.
- [ ] Leave TH1 running unless no remaining work needs it, and confirm no sibling runtime was touched.

### G5 — Evidence, verdict, and documentation

- [ ] Record from the trace: decisions attempted, admitted, and escalated with their reason codes and rate; per-decision wall clock; estimated spend; any wrong action.
- [ ] Evaluate the kill criteria one scenario can answer (escalation rate, per-decision wall clock, every escalation explained) and state the numbers with a continue or stop recommendation.
- [ ] Record that the 20-run irreversible statistic and the three-family escalation rate are not answerable here, and name the next owner.
- [x] Update `docs/qa_maintenance/jev_sanad_ui_automation.md`: both "Deferred to P3" findings move to implemented, plus the brake knobs, both new reason codes, and the live evidence. (The live-evidence items stay unchecked until G4 runs.)
- [x] Add this task to the task list in `docs/llms.txt`, and hand-update the QA page's index line only if its frontmatter description changes. Do not run `scripts/generate_llms_txt.dart`: it excludes `docs/plans/`, so regenerating deletes the hand-maintained task entries. (The task was listed when the plan landed and the QA page description is unchanged.)

## Acceptance Criteria

- [x] Given only `TYPESAFE_API_URL` set, when the client asks a question, then the POST targets that origin with no source edit, and with it unset both defaults are unchanged.
- [x] Given a run that would cross the USD ceiling, when the next decision is requested, then no model call is made and the loop returns `cost_ceiling_reached` with spend and remaining budget.
- [x] Given more requests than the per-minute limit, then the next decision returns `rate_limited` and the loop stops instead of sleeping or retrying.
- [ ] Given the live run, when it ends, then every decidable phase step was answered by the model, every admitted action was dispatched exactly once, and every escalation names a reason code the docs explain.
- [ ] Given the run's total, estimated spend is at or below US$1.00 as computed by the brake.
- [x] `sanad-client-tester` states the direct-routing rule, and no line of it, the QA page, the routing reference, or the trace contains a key or an entered value.
- [ ] Kill-criteria numbers and the resulting continue or stop recommendation are recorded.

## Definition of Done

- [x] Both Python suites and `fvm dart run scripts/lint_wiki.dart` pass with bounded output and recorded exit codes.
- [x] Tests cover both overrides and both brake trips, and the documented reason-code tables match `guard.REASON_CODES`.
- [x] Owned documentation is updated in the same change: QA page, routing reference, Client Tester skill, `docs/llms.txt`.
- [x] `graphify update .` is run and the graph stays current.
- [ ] Live evidence carries no secret, entered value, absolute path, or raw provider payload.
- [x] Delivered as one focused PR with no Co-Authored-By or "Generated with" attribution.

## Current Status

- Current gate: G4 pending a live run (G0–G3 implemented and verified; G5 documentation updated except the live evidence).
- Remaining estimate: 15% (the live scenario and its recorded verdict).
