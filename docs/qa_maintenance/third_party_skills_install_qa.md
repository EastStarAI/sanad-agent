---
title: "Third-Party Skills Install QA"
description: "Regression matrix for sanad skills add/remove/update: source parsing, archive safety, provenance, collisions with bundled and hand-copied skills, and scope precedence."
---

# Third-Party Skills Install QA

## Scope

Verifies `sanad skills` as the user-installed path for third-party Agent Skills.
Product-bundled lifecycle behavior stays in
[Bundled Product Skills QA](bundled_product_skills_qa.md); this matrix covers only
content the user fetched themselves.

Run every case against a throwaway Home so a real installation is never touched:

```bash
export SKL_HOME="$(mktemp -d)"
sanad skills add <source> --home "$SKL_HOME"
```

## Source resolution matrix

| Scenario | Expected result |
|---|---|
| `owner/repo` | Accepted; provenance records `owner/repo`. |
| `owner/repo@tag` | Accepted; the recorded ref is the tag. |
| `https://github.com/owner/repo/tree/main/skills/one` | Accepted; ref `main`, sub-path `skills/one`. |
| Existing local directory | Installed with no network access. |
| `git@github.com:owner/repo.git` | Rejected with guidance to clone first and pass a local path. |
| Non-GitHub host | Rejected before any request. |
| Missing path that is not `owner/repo` | Rejected as malformed, not silently treated as a slug. |

## Archive safety matrix

| Scenario | Expected result |
|---|---|
| Entry containing `..` | Rejected; nothing written. |
| Absolute entry path | Rejected; nothing written. |
| Symlink or hardlink entry | Rejected; nothing written. |
| Payload beyond the size caps | Rejected before extraction completes. |
| Executable files in the archive | Installed with the executable bit preserved. |
| Archive without any `SKILL.md` | Rejected naming the expected layouts. |

## Install, collision, and provenance matrix

| Scenario | Expected result |
|---|---|
| Multi-skill source without `--skill` | Fails and lists the available skill names. |
| `--skill <name>` | Installs only that skill. |
| Target already exists without `--force` | Fails, exit 1, existing content unchanged. |
| Same command with `--force` | Replaces the directory and refreshes the digest. |
| Declared `name` differs from its folder | Rejected. |
| Successful install | `.sanad-skills.json` gains one entry with source, ref, digest, timestamp. |
| `sanad skills list` | Shows name, scope, active/shadowed, and the recorded source. |
| Workspace copy of the same name | Listed as active; the user copy is `shadowed`. |

## Removal and update matrix

| Scenario | Expected result |
|---|---|
| `remove <name>` for an installed skill | Directory and provenance entry removed. |
| `remove` with traversal or root segment (`..`, `.`, `../other`) | Refused with invalid name error, exit 1; filesystem untouched. |
| `remove` where target is a symbolic link | Refused; link and target untouched, exit 1. |
| `remove` resolving outside skills root | Refused; filesystem untouched, exit 1. |
| `remove` for a hand-copied skill without `--force` | Refused with guidance. |
| `remove --force` | Deletes the directory, never touches other skills. |
| `remove` for a bundled product skill | Refused; the product owns it. |
| `update` immediately after install | Reports `Up to date`, no rewrite. |
| `update` after the source changes | Reinstalls and reports the change. |
| `update` when local edits are present without `--force` | Skipped with local edits message; files and provenance unchanged. |
| `update --force` when local edits are present | Replaces content with remote version and records new digest. |
| `update` with an empty provenance file | Fails with a clear message, exit 1. |

## Pre-activation security screening matrix

| Scenario | Expected result |
|---|---|
| Clean skill package | Installed; provenance records `scan: clean`. |
| Staged package piping download to shell (`curl ... \| sh`) | Refused with finding listed; exit 1, nothing written. |
| Staged package with credential path access (`.ssh/id_...`) | Refused with finding listed; exit 1, nothing written. |
| Staged package with destructive commands (`rm -rf /`) | Refused with finding listed; exit 1, nothing written. |
| Staged package with `chmod 777` | Refused with finding listed; exit 1, nothing written. |
| Staged package with instruction override phrasing | Refused with finding listed; exit 1, nothing written. |
| Staged package with secret harvesting phrasing | Refused with finding listed; exit 1, nothing written. |
| Flagged package installed with `add --allow-flagged` | Installed; provenance records `scan: flagged`. |
| Binary file in skill package (e.g. icon/binary) | Skipped by scanner rather than misdecoded; installed intact. |

## Failure and isolation matrix

| Scenario | Expected result |
|---|---|
| GitHub 404 | Exit 1 with the repository and ref named, plus `--ref` guidance. |
| Network unreachable | Exit 1 with the transport error, nothing written. |
| Corrupt `.sanad-skills.json` | `list` still shows skills; add/update report a parse error. |
| `--workspace <path>` install | Files land in `<path>/.sanad/skills`, Sanad Home untouched. |
| `--workspace <registered name>` install | Resolved to that workspace's root; files land in its `.sanad/skills`. |
| `--workspace <unknown value>` | Refused with a not-found message listing known workspaces, nothing written. |
| Interrupted install | No partial skill directory; only the temp directory is discarded. |

## Performance notes

Install is a single HTTPS fetch plus a staged write. It must not walk, hash, or
rewrite unrelated skills, and `list` must stay a single directory scan per root
with no network access.
