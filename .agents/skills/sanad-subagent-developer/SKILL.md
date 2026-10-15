---
name: Sanad Subagent Developer
description: Standard operating procedure for isolated coding, verification, and Pull Request delivery by a focused Sanad subagent.
---

# Sanad Subagent Developer Protocol

Execute one well-defined task in an isolated worktree, prove its Definition of Done, and return a reviewable result without contaminating another active runtime.

## Role Boundaries

You are the scoped **implementer** in the three-role workflow (orchestrator / implementer / independent reviewer). You own the assigned change inside its worktree and brief: implement, verify, and report. You do not perform the final independent review, and you do not stand in for the orchestrator or run its review/CI-repair work. Merge, Ready conversion, protected labels, and destructive cleanup remain authorization boundaries unless the brief granted them up front.

## 1. Read the Plan and Create Isolation

1. Read the assigned task plan from `docs/plans/tasks/<task_id>-<task_name>.md`.
2. Load `.agents/skills/sanad-agentic-developer/SKILL.md` and follow its isolated-worktree mode.
3. Create and enter the dedicated worktree before editing, testing, or launching processes:

   ```bash
   git worktree add .agent/worktrees/<task_id>-<branch_name> <branch_name>
   ```

4. Use `sanad-dev` from inside that worktree for runtime work. Do not offset ports, set `SANAD_STATE_HOME`, construct a relative `SANAD_HOME`, or edit tracked runtime configuration manually. The launcher allocates worktree-specific daemon/VM ports, creates one worktree-scoped `SANAD_HOME`, isolates client preferences, and selects the matching runtime automatically.
5. Use direct component commands only when diagnosing `sanad-dev` itself or one process in isolation.

## 2. Targeted Coding

1. Modify only the scope established by the task plan and the nearest owning contracts.
2. Read every applicable `AGENTS.md` before editing its directory.
3. Use FVM for every Flutter/Dart command, keep paths workspace-relative, and preserve established ownership boundaries.
4. Update the corresponding active page under `docs/` in the same task. Update an `AGENTS.md` only when a durable law, invariant, or ownership boundary changes or becomes stale.
5. Do not overwrite unrelated dirty work already present in the assigned worktree.

## 3. Verification

1. Run the relevant analyzer before completion.
2. Run focused tests covering the changed behavior and failure/recovery paths.
3. Run the full fast suite only for broad or shared-surface changes.
4. Run E2E/integration tests only when mocks cannot validate a real daemon/client, socket, restart, persistent-state, provider, or worktree-runtime boundary.
5. Use `sanad-dev run --driver` plus `.agents/skills/sanad-client-tester/SKILL.md` when live UI verification is required. Local and cloud connections are enabled by default; append `--no-cloud` for explicit local-only verification.
6. Preserve command exit status while bounding successful analyzer/test output to the final five lines. Rerun only a failing command without filtering when diagnosis needs full output.
7. Record exact commands, outcomes, skipped coverage, and unresolved uncertainty.

## 4. Pull Request Delivery

1. Review the complete diff and confirm the task DoD before committing.
2. Commit in the isolated worktree with a descriptive task-referenced message.
3. Push the branch to origin.
4. Open the pull request as a **Draft** after the first accepted gate so CI runs on every push; converting it to Ready and merging remain authorization boundaries unless the brief granted them up front. Follow `sanad-pull-request-lifecycle` for title, labels, and handoff.

## 5. Project Tracking and Handoff

1. Update the owning task plan checklist, progress, evidence, and unresolved decisions only after verification.
2. Report the PR link, a concise technical summary, exact verification, and one outcome: `Succeeded`, `Failed`, or `Unsure` with justification.
3. Do not merge or remove the worktree until human review authorizes cleanup.
