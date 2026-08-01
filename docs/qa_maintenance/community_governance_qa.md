---
title: "Community Governance QA"
description: "Static and live verification matrix for labels, templates, contribution skills, protected CI, Discord routing, and public-repository governance."
---

# Community Governance QA

## Local Static Gates

| Area | Expected evidence |
|---|---|
| Labels | Unique names, exact required groups, six-digit colors, non-empty descriptions, and no default form label outside the manifest |
| Label sync | Default dry-run makes no GitHub call; apply uses forced upsert and never deletes unmanaged labels; two simulations are identical |
| Forms | All YAML parses; blank Issues are disabled; forms route security privately and warn users to redact secrets or diagnostics |
| Discussions | Categories and templates distinguish Ideas & RFCs, Q&A, Show and Tell, and maintainer-only announcements |
| PR template | Linked Issue, bounded verification, platforms, security/privacy, docs, screenshots, rollback, duplicates, and optional AI disclosure are covered |
| Skills | Frontmatter is valid, repository paths resolve, no active skill mentions the retired project manager, and every sensitive mutation requires explicit authorization |
| CI | Path classifier, common-ancestor check, protected labels, label-event reruns, fork-safe permissions, stable aggregate job, and checksum-verified secret scanning without organization-license secrets are present; only exact reviewed synthetic credential-test paths are allowlisted |
| VS Code | The three tracked JSON files parse, remain allowlisted, contain no machine paths, and expose no shortcuts for ownership-sensitive runtime mutations |
| Governance text | No CLA/DCO/sign-off requirement remains in active public guidance; single-maintainer and independent-maintainer protection modes are explicit |
| Brand assets | README has no unapproved interface screenshot; unconsumed legacy logos are absent; build-required icons stay present until an approved canonical source can replace them atomically |

The repository validator and simulations are owned by `scripts/community/`. They are deterministic and do not mutate GitHub.

## Contributor Journey Simulation

1. A quick setup question routes to Discord or Q&A, not an implementation Issue.
2. An architectural idea routes to Ideas & RFCs.
3. A maintainer records an accepted direction and opens an Issue.
4. A large or sensitive change receives an Epic and tracked plan; a small focused change does not.
5. The contributor opens a focused pull request with a Conventional Commits title and bounded verification.
6. CI runs affected lanes, protected path labels are supplied by an authorized maintainer, and the aggregate check passes.
7. A human squash merge preserves human attribution and closes the linked Issue.

A vulnerability diverges at step 1 to Private Vulnerability Reporting and must not enter any public simulation payload.

## SANAD-11 Live GitHub Matrix

- Dry-run labels against the empty public repository, apply them, rerun, and verify no unintended changes.
- Render every Issue Form and Discussion template in GitHub.
- Verify Private Vulnerability Reporting and every contact link.
- Open documentation-only, agent-only, client-only, release-sensitive, and security-sensitive test pull requests.
- Verify unaffected lanes are skipped safely while the aggregate succeeds only when every affected lane succeeds.
- Add each protected review label from an authorized account and verify the failed gate reruns.
- Open a fork pull request and verify no signing, deployment, or environment secret is exposed.
- Apply branch protection and confirm direct push, force push, deletion, merge commit, rebase merge, and unresolved-conversation merge are blocked.

## Discord Live Matrix

- Confirm `DISCORD_WEBHOOK_URL` exists as a repository secret while its value is absent from source, logs, and evidence.
- Merge one approved pull request and confirm exactly one public-title/link notification appears in `#github`; a direct push without an associated merged pull request produces no message.
- Publish a controlled Release only under SANAD-12 and confirm exactly one release notification; workflow dispatches, Issues, CI runs, security events, and fork activity produce none.
- Confirm notification payloads suppress all mentions even when a public title contains mention syntax.
- Verify role permissions with a non-owner test account. Owner-account 2FA
  remains enabled; future Maintainer/Moderator 2FA is not a SANAD-10 gate.
- Confirm ordinary members cannot write to announcements, rules, or the GitHub feed.
- Confirm moderators can execute the warning/timeout/ban ladder and record a private appeal.
- Test question-to-support, idea-to-Discussion, and bug-to-Issue routes.
- Confirm security and conduct reports are redirected privately without reposting details.
- Confirm the permanent invite is project-owned, non-expiring, and valid from a logged-out browser.
- Verify every public website, app, GitHub, and Discord link with hostname-valid TLS; a response obtained only by bypassing certificate verification fails this gate.

## SANAD-12 Release Matrix

Verify the Windows `1.0.0` download and release notes say **Unsigned Windows build**, publish matching SHA-256 and manifest data, and never advise disabling platform protection. Signed platforms must verify their signatures from the protected tagged workflow. SignPath remains a post-v1 application with no claim of acceptance or instant SmartScreen reputation.
