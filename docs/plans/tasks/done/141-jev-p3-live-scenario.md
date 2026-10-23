---
title: "Task 141 — Jev P3: First Live Decision-Layer Scenario"
description: "Close the two P1 review findings (endpoint and model overrides, requests-per-minute and USD brake) and run one multi-step Sanad UI scenario on the isolated Test Home under a hard US$1 ceiling, with the direct-routing rule published in Client Tester and a recorded kill-criteria verdict."
status: done
current_gate: complete
remaining_estimate: 0%
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

- [x] Declare the phases and which are decidable before running: settings navigation, model picker selection, device switch, and one conversation send, each checked against the mode keyset.
- [x] Load the candidate into TH1's own worktree (`.agent/worktrees/test-home`): stay on branch `test/test-home`, run `git reset --hard <candidate sha>` (never detach HEAD), then apply the lightest `sanad-dev` restart there and confirm ownership and SHA with `sanad-dev status`. Never start a second runtime on `~/.sanad-test` from another worktree.
- [x] Prove `TYPESAFE_API_KEY` is present without printing it; stop before any model call when absent.
- [x] Execute the scenario with the brake armed at US$1.00 and the requests-per-minute limit; route every decidable step to the model and dispatch exactly one `sanad-dev ui` action per admitted step.
- [x] Escalate, never retry, on a guard refusal, `model_unavailable`, `model_contradiction`, `rate_limited`, or `cost_ceiling_reached`. No refusal occurred, so the policy was never exercised: 11 phases, 11 decisions, 11 dispatches, 0 re-requests, 0 retries.
- [x] Leave TH1 running unless no remaining work needs it, and confirm no sibling runtime was touched.

G4 record (2026-10-23, one pass, one operator, no retries):

| Item | Result |
| --- | --- |
| Candidate | `origin/main` = `e5d7be44` (PR #300); `test/test-home` reset to it with HEAD never detached |
| Runtime | TH1 (`~/.sanad-test`) only: agent on 58107 plus one driver-enabled client from `sanad-dev run --driver`, left running at the candidate |
| Ownership proof | `sanad-dev status` → `Runtime source commit: e5d7be44…`, `Sanad home: ~/.sanad-test`, `Status: running`, `Clients: 1` |
| Sibling runtimes | `~/.sanad` (58085) and `~/.sanad-test-3` (58143) were not stopped, started, or signalled |
| Key preflight | `load_typesafe_key() is not None` → `True`; a boolean only, the file was never opened, copied, or printed |
| Brake | `max_usd=1.0` and `requests_per_minute=12` armed; neither limit was approached, so no `rate_limited` or `cost_ceiling_reached` appeared |

Declared phases, all declared before the first model call:

| # | Phase | Expected mode | Decidable |
| --- | --- | --- | --- |
| 1 | `open_settings` | `conversation_idle` | yes |
| 2 | `enter_settings_section` | `settings` | yes |
| 3 | `return_to_conversation` | `settings` | yes |
| 4 | `open_model_picker` | `conversation_idle` | yes |
| 5 | `select_model_option` | `model_picker` | yes |
| 6 | `reopen_model_picker` | `conversation_idle` | yes |
| 7 | `restore_model_option` | `model_picker` | yes |
| 8 | `open_device_switcher` | `conversation_idle` | yes |
| 9 | `select_device_item` | `composer_popup` (`device_switcher`) | yes |
| 10 | `seed_message` | `conversation_idle` | yes; the text value came from code |
| 11 | `send_message` | `conversation_idle` | yes, irreversible under an explicit per-phase authorization |
| 12 | `verify_response` | — | **no**; semantic verification stays with the agent |

Per-step summary (one decision and one dispatch each, in that order):

| # | Selected id | Conf. | Decision ms |
| --- | --- | --- | --- |
| 1 | `sidebar_general_settings_destination` | 0.92 | 893 |
| 2 | `nav_tile_sessions_&_devices` | 0.93 | 709 |
| 3 | `settings_back_to_conversations_btn` | 0.96 | 685 |
| 4 | `model_selector_btn` | 0.90 | 698 |
| 5 | `recent_model_option_deepseek-v4-pro` | 0.90 | 800 |
| 6 | `model_selector_btn` | 0.93 | 846 |
| 7 | `recent_model_option_deepseek-v4.1-flash` | 0.93 | 802 |
| 8 | `sidebar_device_switcher_btn` | 0.93 | 918 |
| 9 | `sidebar_device_item_Sanad Agent Test (macOS)` | 0.99 | 728 |
| 10 | `chat_input` | 0.94 | 716 |
| 11 | `send_message_btn` | 0.95 | 629 |

Every admitted step was dispatched exactly once with one `sanad-dev ui` invocation
(`tap` for ten steps, `enter-text` for the seeded message), each reporting
`verified: true` with `verification: tree`, and all eleven produced a tree
transition. The end states were read deterministically, not judged: step 3 returned
the pre-step-1 fingerprint (`336ee7ed57b7ccc3`), step 7 returned the same
fingerprint with `model_selector_btn` reading `OpenCode Go | deepseek-v4.1-flash`,
step 9 closed the device menu with the same device still selected, and step 11
produced exactly one new `user_message_body:*` plus one new non-empty
`assistant_message_body:*` containing the requested single word, with
`stop_message_btn` absent and `send_message_btn` restored.

Obstacles worth carrying into P4:

1. `sanad-dev restart agent` recycles the daemon in place and does not adopt new
   source; after a reset, only `stop` then `run` moves the runtime to the new SHA.
2. `sanad-dev status` can report `not started` while the pair is live; `sanad-dev
   inventory` is the ownership proof when the two disagree.
3. A launcher owned by an agent tool call dies with that call's timeout, taking the
   client down mid-build and leaving a stale launcher record that then fails as
   `Client failed to expose a matching managed identity`. `nohup` does not help; a
   detached new session does, and `sanad-dev doctor --fix` clears a stale record
   without signalling a process.
4. The agent log printed a macOS Keychain approval line while no dialog was rendered
   and nothing was approved; check for a `SecurityAgent` process before treating
   that line as a stop condition.
5. `TraceWriter` truncates its file when it is constructed, so a one-decision-per-
   process cadence keeps only the final line. The 11-line trace was rebuilt by
   replaying the recorded answers through the same layer code on the saved snapshots
   with a scripted offline model: no network, no key, no model call, no UI action,
   no cost, and it refuses to run if any step would decide differently. Latency and
   spend come from the live state file; the `spend_usd` field inside the rebuilt
   trace is the replay's synthetic charge, not provider spend.

### G5 — Evidence, verdict, and documentation

- [x] Record from the trace: decisions attempted, admitted, and escalated with their reason codes and rate; per-decision wall clock; estimated spend; any wrong action.
- [x] Evaluate the kill criteria one scenario can answer (escalation rate, per-decision wall clock, every escalation explained) and state the numbers with a continue or stop recommendation.
- [x] Record that the 20-run irreversible statistic and the three-family escalation rate are not answerable here, and name the next owner.
- [x] Update `docs/qa_maintenance/jev_sanad_ui_automation.md`: both "Deferred to P3" findings move to implemented, plus the brake knobs, both new reason codes, and the live evidence. (The live-evidence items are now filled from the G4 run.)
- [x] Add this task to the task list in `docs/llms.txt`, and hand-update the QA page's index line only if its frontmatter description changes. Do not run `scripts/generate_llms_txt.dart`: it excludes `docs/plans/`, so regenerating deletes the hand-maintained task entries. (The task was listed when the plan landed, and closing it removes that line because the file moves to `docs/plans/tasks/done/`; the QA page description is unchanged.)

G5 numbers, all computed by the brake and the trace:

| Metric | Value |
| --- | --- |
| Decisions attempted / admitted / escalated | **11 / 11 / 0**, escalation rate **0.0 %** against a 15 % kill threshold |
| Escalation reason codes | none to report |
| Per-decision wall clock | p50 **728 ms**, p95 **906 ms**, mean 766 ms, max **918 ms** against a 6 s kill threshold |
| Model latency | p50 348 ms, p95 449 ms, mean 363 ms, max 485 ms |
| Snapshot cost per step | p50 383 ms, p95 504 ms, mean 400 ms |
| Confidence | min 0.90, mean 0.935, max 0.99; no floor trip, no low-confidence escalation |
| Wrong actions | **0**; every admitted id was the declared phase target and every dispatch produced a transition |
| Irreversible actions executed | **1** (`send_message_btn`, pre-authorized per phase, recorded once) |
| Circuit-breaker trips | 0 (`repeated_target` 0, `oscillation` 0, `no_transition` 0) |
| Candidate table sizes | 10–30 live, never truncated; the replayed trace caps at 32 including `abstain` and `reobserve` |
| Total spend | **US$0.00053798** of the US$1.00 ceiling (0.054 %), 12,809 input tokens, 0 estimated calls, ≈US$0.0000489 per decision |
| Rate limit | `requests_per_minute=12` never approached |

Spend is exact rather than estimated: every reply reported `usage.input_tokens`, so
`brake.estimated_calls` stayed 0 and the run used 0.054 % of its ceiling.

| Kill criterion | Answerable here | Result | Verdict |
| --- | --- | --- | --- |
| ≥15 % of decisions escalate | yes | 0 of 11 = **0.0 %** | pass |
| ≥1 wrong irreversible action above the floor in 20 runs | **no** (n=1, one irreversible decision) | 0 wrong irreversible actions in this run | not answerable; needs the 20-run register |
| Per-decision wall clock > 6 s | yes | max **0.918 s**, p95 0.906 s | pass |
| Trace cannot explain every escalation | yes | 0 escalations; every decided step has a trace line | pass, vacuously true for escalations |
| Three-family escalation rate | **no** | one family exercised: settings navigation, picker selection, device switch, send | not answerable |

**Verdict: continue.** None of the four criteria this scenario can answer is close to
its threshold, so the decision layer is not the blocker for P4.

Two evidence debts are named rather than argued, because one scenario cannot produce
them:

1. The **20-run irreversible-action statistic** — next owner: the tester who runs the
   P4 multi-run register.
2. The **three-scoped-family escalation rate** — next owner: the P4 author who adds
   the two remaining families (permission card and `ask_user` card) to the live set.

Cadence observation for P4: the manual cadence cost ≈13.7 s per full step against a
0.77 s decision, so ≈92 % of each step was agent overhead rather than judgment;
every step was still dispatched exactly once with no divergence between the admitted
and the executed id. That is the evidence a loop runner would rest on, and the trace
truncation in obstacle 5 above is the first defect it must fix.

## Acceptance Criteria

- [x] Given only `TYPESAFE_API_URL` set, when the client asks a question, then the POST targets that origin with no source edit, and with it unset both defaults are unchanged.
- [x] Given a run that would cross the USD ceiling, when the next decision is requested, then no model call is made and the loop returns `cost_ceiling_reached` with spend and remaining budget.
- [x] Given more requests than the per-minute limit, then the next decision returns `rate_limited` and the loop stops instead of sleeping or retrying.
- [x] Given the live run, when it ends, then every decidable phase step was answered by the model, every admitted action was dispatched exactly once, and every escalation names a reason code the docs explain. (11 of 11 decidable steps were answered and dispatched exactly once; the run produced no escalation, so the reason-code clause is vacuous here.)
- [x] Given the run's total, estimated spend is at or below US$1.00 as computed by the brake. (US$0.00053798, exact from provider usage rather than estimated.)
- [x] `sanad-client-tester` states the direct-routing rule, and no line of it, the QA page, the routing reference, or the trace contains a key or an entered value.
- [x] Kill-criteria numbers and the resulting continue or stop recommendation are recorded. (**Continue**, with the 20-run and three-family statistics named as debts owned by P4.)

## Definition of Done

- [x] Both Python suites and `fvm dart run scripts/lint_wiki.dart` pass with bounded output and recorded exit codes.
- [x] Tests cover both overrides and both brake trips, and the documented reason-code tables match `guard.REASON_CODES`.
- [x] Owned documentation is updated in the same change: QA page, routing reference, Client Tester skill, `docs/llms.txt`.
- [x] `graphify update .` is run and the graph stays current.
- [x] Live evidence carries no secret, entered value, absolute path, or raw provider payload. (The record names the Test Home and sibling homes in `~` form, describes the trace as the coordinator run folder's untracked output, and carries no key, entered text, or provider body.)
- [x] Delivered as one focused PR with no Co-Authored-By or "Generated with" attribution.

## Current Status

- Status: **done**. G0–G3 shipped in PR #300; G4 ran live on TH1 on 2026-10-23 at
  `e5d7be44` with 11 decisions, 11 admissions, 0 escalations, 0 wrong actions, and
  US$0.00053798 spent; G5 records the numbers with a **continue** verdict.
- Remaining estimate: **0%**.
- Left open deliberately: the 20-run irreversible-action statistic and the
  three-family escalation rate, both belonging to P4 and named above.
