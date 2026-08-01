---
name: Sanad Repository Maintainer
description: Maintain the public Sanad Agent repository through its tracked governance, review labels, protected checks, fork-safety rules, and verified GitHub workflows.
---

# Sanad Repository Maintainer

Use this skill when maintaining `EastStarAI/sanad-agent`. It is written for human maintainers and for development agents acting on their behalf. Read-only inspection is safe by default. An agent must obtain explicit authorization from the responsible human before any GitHub mutation.

## Start With Repository State

1. Confirm the target repository, authenticated GitHub account, available repository role, default branch, and current commit.
2. Read `.github/GOVERNANCE.md` and the nearest tracked manifest or documentation page for the surface being maintained.
3. Compare tracked desired state with the live repository before proposing a mutation.
4. Report drift, missing permission, and rollback impact before changing live state.
5. Query the postcondition after every mutation; an accepted API request is not evidence that the intended state is live.

Never hardcode mutable rule, category, run, branch, webhook, or secret identifiers. Discover them from the target repository when needed.

## Permission Boundary

GitHub roles and organization policies may change. Verify the live permission instead of assuming it from a username.

- Public/read access may inspect metadata, Issues, Discussions, pull requests, checks, workflows, and other public repository state.
- Triage-capable maintainers may classify work and manage ordinary labels or Issue/Discussion state within project governance.
- Write or maintain access may update review branches and merge an eligible pull request when project policy and human authorization allow it.
- Administrative repository settings, branch protection or rulesets, Actions permissions, secrets, webhooks, security features, and organization-owned surfaces require the corresponding live administrative permission and separate action-specific authorization.

If the authenticated role cannot perform an operation, stop. Do not seek a bypass, weaker setting, alternate token, or unrelated organization permission.

## Pull Requests and Protected Review

1. Require a Conventional Commits title, common ancestry with current `main`, resolved conversations, and the latest successful `All required checks pass` result.
2. Map changed paths to `maintainer-reviewed`, `security-reviewed`, and `release-reviewed` using `.github/GOVERNANCE.md` and `.github/workflows/ci.yml`.
3. Apply a protected review label only after an authorized maintainer confirms the corresponding review. A label is review evidence, not a mechanism for hiding a failure.
4. Preserve read-only, secret-free execution for fork pull requests.
5. Merge only through the repository's enabled squash flow and only after the responsible maintainer authorizes the merge.
6. Verify the resulting default-branch commit, CI result, branch cleanup, and any bounded downstream notification.

Use short status queries. Do not leave indefinite watch or follow commands running.

## Managed Repository Surfaces

- Treat `.github/labels.yml`, `.github/discussion-categories.yml`, and `.github/branch-protection.yml` as desired-state manifests.
- Dry-run or compare first, apply only the intended drift correction, then verify idempotency.
- Preserve the stable aggregate check, current protected-review model, resolved-conversation requirement, force-push and deletion blocks, and documented merge policy unless an approved governance change explicitly replaces them.
- Keep Issue Forms, Discussion categories, support routes, CODEOWNERS, and public documentation consistent with their tracked sources.
- Keep the Discord feed limited to merged pull requests and published Releases. Do not add raw Issues, CI runs, security events, fork activity, or direct-push notifications.

## Secret and Security Handling

- Never read, print, copy, log, comment, or commit a secret value. Inspect only secret names and update metadata when necessary.
- Never place credentials in workflow inputs, artifacts, pull-request comments, or evidence files.
- Do not use `pull_request_target` to obtain secrets for fork code.
- Route undisclosed vulnerabilities through Private Vulnerability Reporting; do not recreate their contents in public Issues or Discussions.
- Security, webhook, or secret rotation requires explicit authorization and a bounded verification and rollback plan.

## Excluded Procedures

This repository-maintenance skill does not define release publication, signing, installer or update publication, Appcast management, TestFlight delivery, Web deployment, production deployment, DNS, or TLS procedures. Use the separately reviewed release or operations procedure that owns those actions.

When target identity, permission, review evidence, authorization, or rollback is ambiguous, stop before mutation and request the missing decision.