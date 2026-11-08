---
title: "Community and Contribution Governance"
description: "Operating model for Discord, Discussions, Issues, plans, pull requests, labels, protected review, and public-repository handoff."
---

# Community and Contribution Governance

## Source-of-Truth Routing

Discord owns fast help, community conversation, showcases, and announcements. GitHub Discussions own ideas, RFCs, and architectural Q&A before adoption. GitHub Issues and Projects own actionable status, priority, assignee, milestone, and dependencies. Tracked task plans own scope, risks, decisions, gates, and acceptance only for large or high-risk changes. Current product and technical docs own behavior after merge. Pull requests own the implementation diff, evidence, and review.

A question may move from Discord to support, a reproducible report to an Issue, and an idea to a Discussion. No durable technical decision or vulnerability report remains in Discord.

## Triage Model

Every new Issue starts with `needs-triage` and one `type/*` label supplied by its form. A maintainer adds at least one component, exactly one priority, and one size during triage. Platform labels are conditional. `ready-for-contributor` means scope, acceptance, and dependencies are clear; `good-first-issue` additionally means no architectural decision is pending.

`.github/labels.yml` is the versioned label source. The sync helper validates that names are unique, colors are six-digit hexadecimal values, descriptions are non-empty, and required groups are complete. Its default mode is non-mutating. SANAD-11 applies it after reviewing the target public repository. Labels are not deleted automatically.

Protected positive-review labels are restricted to users with triage/write permission. Governance and `.github/` changes require `maintainer-reviewed`; auth/security boundaries require `security-reviewed`; release, signing, installer, and updater changes require `release-reviewed`. Public CI runs on code events only (`opened`, `synchronize`, `reopened`, `ready_for_review`), so label changes never restart or cancel it.

A protected label is honoured only after `Verify protected review labels` re-reads it, and that re-verification is dispatched on demand rather than on every label event, because GitHub created one run per label event even when several labels changed in a single call. The maintainer or coordinator who applies or removes a protected label dispatches the small `Protected label review` workflow immediately afterwards:

```bash
gh workflow run protected-labels.yml -f pr_number=<N>
```

Then watch it with `gh run list --workflow protected-labels.yml --limit 1` followed by `gh run watch <run-id> --exit-status`. The workflow requires a positive pull request number, verifies that the pull request exists and is open in this repository, waits for the latest Public CI run of the current head SHA, and re-runs only its `Verify protected review labels` job; GitHub re-runs the dependent `All required checks pass` job, which keeps every other job's result from that same run. The protected-label job reads the pull request's labels at run time, never from an event payload, so a removed label turns the gate red on the same dispatch. Dispatching requires write access, which is the authorization boundary, and a dispatch run uses this repository's own token, so fork pull requests are re-verified the same way. A protected label that was never followed by a dispatch leaves the previous aggregate result stale.

## Pull Request and Branch Model

Human pull requests use Conventional Commits titles and squash merge. Direct pushes, force pushes, branch deletion, and unresolved conversations are blocked on `main`. One stable aggregate check, `All required checks pass`, is the branch-protection context. Path classification runs only affected agent, client, documentation, release, and security lanes; classification failure does not silently skip validation. Pushes to `main` run all lanes. Test lanes are sharded matrices and the aggregate depends on every shard; [Public CI Pipeline and Merge Queue](continuous_integration.md) owns the job layout, the shard and cache design, and the queue runbook.

Once the owner enables the merge queue, a queued entry is built by the same workflow through its `merge_group` trigger: classification and every lane run against the merge-group diff, the queued pull request's protected labels are re-checked from the queue head ref, and the same aggregate gates the queue. A merge group that cannot be attributed to exactly one pull request fails closed, so the queue keeps one pull request per build. The merge agent updates the branch, resolves conflicts, verifies the head, and enqueues with `gh pr merge <number> --squash --match-head-commit <sha>`; the coordinator only reviews and dispatches.

Fork pull requests use `pull_request`, read-only repository contents, and no signing or deployment secrets. Publication workflows are manually or tag triggered and protected separately.

During the initial single-maintainer phase there is no generic approval-count requirement. Protected review labels provide positive review for sensitive paths. After an independent maintainer joins, SANAD-11 changes protection to one required approval plus CODEOWNERS review.

## Public GitHub Handoff

SANAD-11 consumes these local artifacts:

- `.github/labels.yml` and the dry-run-first sync helper;
- `.github/discussion-categories.yml` and Discussion templates;
- `.github/branch-protection.yml`;
- Issue Forms, pull-request template, and CODEOWNERS;
- the stable CI aggregate check and protected-path gates.

The live application sequence is: create the repository, enable Private Vulnerability Reporting and Discussions, create categories, dry-run then apply labels, verify form destinations, apply repository merge settings and branch protection, open a no-secrets fork test, and confirm that a dispatched protected-label re-verification reruns the protected review job while any other label change starts no run at all. Live category IDs and repository rule identifiers are not stored in the source manifest.

## Discord Handoff

The official server name is **Sanad Agent** (rebranded from the earlier
`Sanad Agent Community` label by the owner on 2026-07-28). The Discord
server ID is `1531380371588124724` and the project-owned permanent invite
is `https://discord.gg/RPTJ2X9rn`, configured to never expire and to land
in `#help-and-support`. `discord-community.yml` defines the initial
categories, channels, roles, channel overrides, routing, and safety
controls. Owner-account 2FA is enabled; enforcing 2FA on future Maintainer
or Moderator accounts is not part of the SANAD-10 acceptance scope. The
owner must choose a suitable verification level, configure anti-spam/rate
limits, grant bots least
privilege, test the project-owned permanent invite in a logged-out
browser session, and keep moderation/audit channels private.

The GitHub feed in `#github` is read-only. Its channel-scoped webhook is stored only as the `DISCORD_WEBHOOK_URL` repository secret and is exposed only to the final send step. The tracked notification workflow runs on pushes to protected `main` and on completion of the Stable release workflow: a main push is posted only when GitHub associates it with a merged pull request, while a Stable Release is posted from the completing release run, because a Release published with the repository token starts no workflow of its own. [Release, Signing, and Deployment Architecture](release_and_signing.md#release-announcement-handoff) owns the Production-ordering rule and the announce-once ledger. Payloads disable mentions and contain only the public title, link, and actor identities hydrated from the complete public pull-request or Release record. Raw Issues, CI runs, security events, fork activity, and direct or emergency pushes are intentionally excluded. Contributor opportunities may be selected manually for `#contributors`.

## Repository Maintainer Skill Boundary

`sanad-repository-maintainer` is a public procedure for human maintainers and development agents working on this repository. It describes role-based access rather than assuming authority from a username: public/read access supports inspection, triage access supports ordinary work classification, write or maintain access supports review-branch and eligible merge operations, and administrative surfaces require the corresponding live repository permission.

Read-only inspection is the default. An agent requires explicit action-specific human authorization before every mutation, and every maintainer must preserve tracked governance, protected checks, fork safety, and secret boundaries. Mutable IDs are discovered from GitHub rather than stored. Release publication, signing, distribution, and production operations use separately reviewed procedures and are not defined by this skill.
