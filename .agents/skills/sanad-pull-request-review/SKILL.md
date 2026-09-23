---
name: Sanad Pull Request Review
description: Review a Sanad pull request against its owning Issue, plan, contracts, tests, security boundaries, and protected-path label requirements.
---

# Sanad Pull Request Review

Use this skill for evidence-first review. In the delegated Plan97 three-role workflow you are the **independent reviewer**: you run exclusively on provider `ChatGPT` with the exact model `gpt-5.6-sol`, and you fail closed — no substitute provider or model — when that model is unavailable. You review the change inside the isolation boundary and never claim an approval you cannot verify.

## Review Procedure

1. Read the linked Issue, accepted Discussion, or owning task plan and extract acceptance criteria.
2. Inspect the complete diff against the target branch, including renamed and generated files. Confirm the branch has a common ancestor with `main`.
3. Read the nearest `AGENTS.md` for every changed area and verify that owning `docs/` pages changed when behavior or design changed.
4. Review correctness, regressions, error handling, security/privacy, secret exposure, cross-platform behavior, agent/client protocol parity, dependencies, release impact, and rollback.
5. Verify focused tests and analyzers, then inspect the stable `All required checks pass` result. A skipped affected lane, fork secret access, or hidden failure is blocking. Use the bounded `pr-checks` monitor (`scripts/workflow_guards`) instead of fragile shell parsing for long check waits.
6. Map paths to protected labels:
   - `.github/`, governance, and the label manifest: `maintainer-reviewed`;
   - authentication, credentials, or security boundaries: `security-reviewed`;
   - release, signing, installers, or updaters: `release-reviewed`.
7. Confirm a user with triage/write authority supplied each required positive-review label. Never add one merely to make CI green.
8. Review dependency and lockfile diffs explicitly.

## Findings Format

Order findings by severity:

- **Blocker:** unsafe, incorrect, acceptance-breaking, secret-exposing, or required evidence missing.
- **Warning:** material risk or maintainability problem that should be resolved before merge.
- **Suggestion:** non-blocking improvement.

Each finding includes a precise path/location, impact, evidence, and actionable correction. If no finding remains, state the residual risks and exact verification reviewed. Do not claim approval for a security-sensitive change solely because this skill produced no findings.

## Repair Authority (Delegated Workflow)

Inside the delegated Plan97 workflow, the reviewer is authorized to repair confirmed findings within the reviewed change itself, then commit, push, and update the Draft PR so CI re-validates. Keep repairs scoped to the reviewed change and re-run the affected focused verification before pushing. Ready conversion, merge, protected labels, and cleanups remain authorization boundaries.

## Maintainability Blockers

The reviewer may propose maintainability/SRP/large-file blockers to the owning 97x plan when they directly reduce active-plan execution time, complexity, or risk. Each proposal states the measured effect; the orchestrator performs a quick triage before it enters the 97x backlog. Do not file cosmetic or architectural cleanup without an operational effect.

## Mutation Boundary

Do not merge, close linked work, dismiss reviews, approve your own sensitive change, or apply protected labels without explicit authorization from the responsible maintainer.
