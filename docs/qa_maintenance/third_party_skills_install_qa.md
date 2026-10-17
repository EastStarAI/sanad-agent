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
| `remove` for a hand-copied skill without `--force` | Refused with guidance. |
| `remove --force` | Deletes the directory, never touches other skills. |
| `remove` for a bundled product skill | Refused; the product owns it. |
| `update` immediately after install | Reports `Up to date`, no rewrite. |
| `update` after the source changes | Reinstalls and reports the change. |
| `update` with an empty provenance file | Fails with a clear message, exit 1. |

## Failure and isolation matrix

| Scenario | Expected result |
|---|---|
| GitHub 404 | Exit 1 with the repository and ref named, plus `--ref` guidance. |
| Network unreachable | Exit 1 with the transport error, nothing written. |
| Corrupt `.sanad-skills.json` | `list` still shows skills; add/update report a parse error. |
| `--project` install | Files land in `<workspace>/.sanad/skills`, user Home untouched. |
| Interrupted install | No partial skill directory; only the temp directory is discarded. |

## Performance notes

Install is a single HTTPS fetch plus a staged write. It must not walk, hash, or
rewrite unrelated skills, and `list` must stay a single directory scan per root
with no network access.
