---
title: "Task 142 — Round C: Skills Consolidation"
description: "Consolidate the delegation, orchestration, and developer skills to one owner per procedure, merge the four GitHub-workflow skills into one sectioned sanad-github skill, and add the SKILL.md pointers and lessons the tooling rounds produced. Documentation only: implementation waits for the user to lock five decisions."
status: "pending — decisions under user review"
current_gate: G0 complete; D1–D5 PROPOSED, G1 blocked
remaining_estimate: 95%
base_commit: af89bf42
depends_on: "Rounds A/B live-tooling fixes (B1–B17), Task 141 (#300), and the delegate/supervisor pointer gaps recorded below"
---

# Task 142 — Round C: Skills Consolidation

## Goal

Give each skills procedure exactly one owning document, make every consolidated skill describe the tooling that shipped in Rounds A/B, and reduce the four GitHub-workflow skills to one sectioned `sanad-github` skill — with no duplicated procedure and no mutable facts.

Documentation only. This task runs now only to record grounded decisions; every skill, test, and script edit waits for G1.

## Locked Decisions and Scope

Locked by the requester:

- Round C is the last live-tooling round: skills are updated after the tooling, never before.
- Skills may only be changed once the user locks D1–D5. Nothing in `.agents/skills/` may be edited before G1.
- The inventory in G0 is produced (not planned) while writing this file, so the decisions are grounded in the real tree.
- Private-repository skills (`../.agent/skills/`, parent repo) are read-only here. No private skill file is edited in this task.

## G0 — Inventory (done, evidence below)

- [x] Count every in-scope `SKILL.md`, list owned procedures and overlaps, and resolve inbound references with `git grep`.
- [x] Locate the eval and test surface per skill (`evals/`, `tests/`, `test/`).
- [x] Resolve the private-repo boundary by reading the parent repo's symlink set.

| Skill | Lines | Owns | Overlaps | Inbound refs | Evals / tests |
|---|---|---|---|---|---|
| `sanad-delegate` | 349 | `sanad run` machine contract, params, `result.json`/`events.jsonl`, remote `sanad-client` topology and observation | supervisor §3 Sanad task spec; supervisor §5 follow | supervisor SKILL + `bootstrap.mjs`, `docs/agent_engine/sanad_delegate_relay.md`, `docs/qa_maintenance/client_cli_remote_relay_qa.md` | none |
| `delegate-task-supervisor` | 299 | bootstrap, workspace continuity, task specs, run topology, event-first wait, watch/status, result review | delegate (task spec), orchestrator (routing) | orchestrator, delegate, relay doc | `evals/evals.json`; `test/*.mjs` (6) |
| `sanad-orchestrator` | 69 | research/audit, task breakdown, repo-native tracking, execution routing, three-role workflow, merge + cleanup | agentic-developer §2 (plan contract), supervisor, subagent-developer, review/lifecycle | none in skills | none |
| `sanad-agentic-developer` | 233 | dev-mode choice, **§2 Task Plan Contract**, `sanad-dev` runtime control, flagged tracing, PR delivery | orchestrator Phase 2, subagent-developer §4, PR lifecycle | client-tester, orchestrator, subagent-developer | `evals/evals.json` |
| `sanad-subagent-developer` | 56 | isolated implementer role: isolation, targeted coding, verification, PR delivery, handoff | agentic-developer §1B + §5, PR lifecycle | orchestrator | none |
| `sanad-client-tester` | 73 | live UI test boundary, canonical runner, decision-layer routing, routing table, invariants | jev (Sanad integration), agentic-developer (runtime) | orchestrator, subagent-developer, `docs/qa_maintenance/jev_sanad_ui_automation.md` | `evals/evals.json`; `tests/` (11) |
| `jev-dual-brain-automation` | 148 | engine ownership, required workflow, request pattern, browser variant, confidence + breaker | client-tester (Sanad adapter) | client-tester skill, refs, and scripts | `evals/evals.json`; `tests/` (3) |
| `sanad-pull-request-lifecycle` | 97 | gate flow, label gate, prepare, verify, release route, CI repair, merge safety, pre-merge handoff | subagent-developer §4, agentic-developer §5, maintainer | subagent-developer, `scripts/community/validate_governance.rb` | none |
| `sanad-pull-request-review` | 45 | review procedure, findings format, repair authority, maintainability blockers, mutation boundary | orchestrator Phase 4b, maintainer | orchestrator, `validate_governance.rb` | none |
| `sanad-contribution-triage` | 46 | routing destinations, label taxonomy, mandatory issue labels, output, local simulation | maintainer | `validate_governance.rb` | none |
| `sanad-repository-maintainer` | 61 | repo state, permission boundary, protected review, managed surfaces, secret handling, exclusions | lifecycle, review, triage (umbrella) | `docs/operations/community_governance.md`, `docs/qa_maintenance/community_governance_qa.md`, `validate_governance.rb` | none |

Grounded constraints the inventory produced:

- `scripts/community/validate_governance.rb` is a **hard CI gate** on four of the names: it fails when `sanad-contribution-triage`, `sanad-pull-request-review`, or `sanad-pull-request-lifecycle` is missing or lacks `explicit authorization`, and it requires `sanad-repository-maintainer` at its exact path with five boundary strings and four forbidden private details.
- The decision-layer direct-routing rule already lives in `sanad-client-tester` (#300) and is pinned by `tests/test_skill_contract.py::test_the_direct_routing_rule_is_published`. It must be verified, never re-added.
- `sanad-client-tester` has a live ≤100-line contract test (`test_main_skill_is_a_bounded_router`); four of the seven route to a `references/` file already.
- Private repo `/Volumes/Storage/development/projects/desktop-agent/.agent/skills/` symlinks **`sanad-agentic-developer`, `sanad-orchestrator`, `sanad-subagent-developer`, `sanad-client-tester`** into this repo; its private-only skills are `n8n-updater`, `sanad-deployment-operator`, `sanad-project-manager`, `sanad-server-maintenance`. Any rename or removal of those four names dangles a private symlink and needs a named private follow-up owned by the user.
- Pointer gaps confirmed: `sanad-delegate` documents `session answer|permission|show|stop` but never `steer`, `retry`, or `cancel`; `delegate-task-supervisor` documents `--max-concurrency` at start but never `set-concurrency` or `queued_stall`.

## Decisions for User Review (all PROPOSED)

**D1 — GitHub skill merge.** Question: fold the four governance skills into one sectioned `sanad-github`, and what happens to the old names?
- A. One `sanad-github` with `lifecycle` / `review` / `triage` / `maintainer` sections; old names removed and every reference plus the `validate_governance.rb` gate repointed.
- B. One `sanad-github` plus four alias stubs that keep the old names and forward into a section.
- C. Keep `sanad-repository-maintainer` and `sanad-pull-request-lifecycle` separate; merge only triage + review into `sanad-github`.
- **Recommendation: A.** Reason: the validator is the only hard gate and it can be repointed once, while alias stubs keep four competing owners and defeat the round's purpose.

**D2 — Depth of consolidation for the seven.** Question: merge any of the delegation/orchestration/developer skills, or only de-duplicate?
- A. De-duplicate only: keep all seven names, move each duplicated procedure to one owner.
- B. Merge `sanad-subagent-developer` into `sanad-agentic-developer` as an implementer section; keep the other six.
- C. B plus merge `sanad-orchestrator` into `delegate-task-supervisor` into a single coordination skill.
- **Recommendation: B.** Reason: `sanad-subagent-developer` (56 lines) restates agentic-developer §1B/§5 with no unique procedure, while `sanad-orchestrator` owns a distinct role contract and both merged names are privately symlinked, so C costs two private follow-ups for no ownership gain.

**D3 — Where the coordinator rules live.** Question: where do "always-on supervisor watcher", "delegate long merge-following to a sanad merge agent", and "live checks only on TH1–TH3" belong?
- A. A section of `sanad-orchestrator/SKILL.md`.
- B. `sanad-orchestrator/references/coordinator-rules.md`, routed from a one-line SKILL.md entry.
- C. A private-only skill in the parent repo.
- **Recommendation: B.** Reason: the rules are stable policy several skills route to, and the router + reference pattern already keeps `sanad-client-tester` under 100 lines.

**D4 — Size bounds and existing contract tests.** Question: what bounds apply after consolidation, and do the current tests stay?
- A. Keep every current bound unchanged and add no new ones.
- B. Keep `sanad-client-tester` at its ≤100 contract test untouched, cap every other consolidated `SKILL.md` at ≤150 lines, and enforce that with one new test.
- C. Cap everything at ≤100 including client-tester.
- **Recommendation: B.** Reason: one ratchet test is cheaper than seven bespoke bounds, and it leaves #300's published contract test exactly as shipped.
- **Also proposed:** the required sections per merged skill are frontmatter, ownership boundary, procedure, and a "read current docs first" line — with no port numbers, commit SHAs, model ids, or paths that move.

**D5 — Evals.** Question: update the existing evals, add new ones, or neither?
- A. Update the five existing `evals/evals.json` files in place.
- B. A plus a new `sanad-github/evals/evals.json` and coordinator-routing evals for the merged sections.
- C. No eval work; rely on the contract tests.
- **Recommendation: B.** Reason: a merge changes routing, and evals are the only artifact that proves an agent reaches the right section instead of the removed name.

## Gates

### G1 — Lock the decisions (BLOCKED on user review)
- [ ] User locks D1–D5; record each outcome and its reason under "Locked Decisions and Scope" in the same session.
- [ ] Convert G2–G5 from conditional to fixed scope in this file before any `.agents/skills/` edit.

### G2 — Consolidate and refresh (BLOCKED on G1, D1/D2/D3)
- [ ] Apply the locked merges; every consolidated skill has one owner per procedure and no copied procedure.
- [ ] Keep the direct-routing rule only in `sanad-client-tester`; verify `test_the_direct_routing_rule_is_published` still passes instead of restating the rule elsewhere.
- [ ] Repoint `scripts/community/validate_governance.rb` and its boundary strings to the locked paths.
- [ ] Name the private-repo follow-up for each of the four symlinked names that changes, and do not edit the private repo.

### G3 — Add the missing pointers (BLOCKED on G1)
- [ ] `sanad-delegate`: `sanad session steer`, `sanad session retry`, and cancellation semantics, matching `agent/lib/cli/runner/commands/session/`.
- [ ] `delegate-task-supervisor`: `set-concurrency --max <n>` and the single `queued_stall` notice per task.
- [ ] AOT/Keychain rule: a compiled per-SHA exe run as the daemon waits on macOS Keychain approval, so run the daemon through `sanad-dev` and use exes only for client-side CLI calls. Source of truth: `docs/technical/sanad_cli_architecture.md` (§ why the vault is not free, `-25308`/`-25315`/`-25293`/`-128`, and `fvm dart run` identity).
- [ ] Gitleaks quirk — **found, not unknown**: CI must use the pinned open-source CLI, never the organization-licensed Action; the archive is SHA-256 verified; fixtures must not commit credential-shaped literals, and a `.gitleaksignore` fingerprint exists only for history that still holds an old literal. Sources: `scripts/community/validate_governance.rb`, `docs/qa_maintenance/release_verification.md`, `scripts/sanad_dev/AGENTS.md`.
- [ ] Remote-device refresh message — **not located as a distinct message**: record the two real strings from `client/lib/features/client_cli/cli/sanad_client_runner.dart` (the `Run "sanad-client devices" …` hint when `--device` is missing, and `No remote devices registered or available in Sanad Client.`), or take the user's exact wording at G1.

### G4 — Lessons and boundaries (BLOCKED on G1)
- [ ] Record that `sanad-dev` must run from a Test Home worktree with an explicit `--home <TH path>`, because a linked worktree otherwise resolves `~/.sanad/dev/homes/<worktree>`.
- [ ] Record that `sanad models` is cache-only and live discovery goes through gateway `provider.instance.test`.
- [ ] Record the brief-to-skill loading map: live-tester briefs load `sanad-client-tester`, PR-opening briefs load `sanad-pull-request-lifecycle`, task-writing briefs load `sanad-agentic-developer` §2.
- [ ] Record that live checks are delegated to testers on Test Homes TH1, TH2, and TH3, never on scratch Homes.
- [ ] Record the coordinator duties: a supervisor watcher runs at all times, and long chores such as merge-following are delegated to a sanad merge agent.
- [ ] Confirm the private/public boundary statement in the owning skill (root `AGENTS.md` §1.1): shared skills are symlinks, private-only skills stay in the parent repo.

### G5 — Verify and deliver (BLOCKED on G1)
- [ ] Run every skill suite and the governance validator.
- [ ] Run `fvm dart run scripts/lint_wiki.dart` and `git diff --check`.
- [ ] Confirm no dangling old-name reference remains outside historical plan records.
- [ ] Open a Draft PR; Ready and merge remain separate authorization boundaries.

## Acceptance Criteria

- [ ] Given the locked decisions, when the round closes, then no procedure is documented in two skills and every merged name has one owner.
- [ ] Given the old GitHub skill names, when `git grep` runs for each, then the only remaining hits are historical plan and QA records that intentionally preserve history.
- [ ] Given the refreshed skills, when a reader follows any skill entry point, then it names the current command or doc that owns the fact and holds no port, SHA, model id, or short-lived path.
- [ ] Given the pointer list in G3, when any consolidated skill is read, then `steer`/`retry`/`cancel`, `set-concurrency`, `queued_stall`, the AOT/Keychain rule, the gitleaks quirk, and the refresh pointer are all reachable.
- [ ] Given `sanad-client-tester`, when the round closes, then the direct-routing rule exists exactly once and its contract test passes unchanged.
- [ ] Given the four privately symlinked names, when a name changes, then the required private follow-up is named in the task record and no private file was edited.

## Definition of Done

- [ ] `python3 -m unittest discover -s .agents/skills/sanad-client-tester/tests -t .agents/skills/sanad-client-tester` passes.
- [ ] `python3 -m unittest discover -s .agents/skills/jev-dual-brain-automation/tests -t .agents/skills/jev-dual-brain-automation` passes.
- [ ] `node --test .agents/skills/delegate-task-supervisor/test/` passes.
- [ ] `ruby scripts/community/validate_governance.rb` passes.
- [ ] `fvm dart run scripts/lint_wiki.dart` exits 0, and `docs/llms.txt` indexes this file and any new skill reference file by hand.
- [ ] `git diff --check` is clean.
- [ ] `graphify update .` runs if any non-doc file changes; this planning PR changes documentation only.
- [ ] No skill or code file is touched by this planning PR.

## Status

`pending — decisions under user review`. G0 is complete and evidence-backed. G1–G5 are blocked until the user locks D1–D5; remaining estimate 95%.
