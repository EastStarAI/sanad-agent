---
title: "skl-02 — Third-Party Skill Install Hardening"
description: "Harden sanad skills add/remove/update against destructive path resolution, silent overwrite of user edits, and activation of unsafe third-party instruction content."
---

# skl-02 — Third-Party Skill Install Hardening

## Problem

`skl-01` shipped the `sanad skills add|list|remove|update` surface. Reference-grounded review
(`evidence_id: sha256:ab7085231eac3cecea9240c7e402098443a86f039b333693cdca912842dbaf75`) found three
weak points in that implementation:

1. `remove(name)` never validates `name` or the resolved target, so a caller-supplied segment can
   reach `Directory.deleteSync(recursive: true)` outside the skills root.
2. `update()` rewrites a skill whenever fetched content differs from the recorded digest, which is
   indistinguishable from a local edit, so user modifications are destroyed silently.
3. Nothing screens fetched instructions before activation; the archive reader is the only barrier.

## Goals

- Make every destructive path operation verify its target before acting.
- Make local modifications visible and protected, with an explicit override.
- Screen staged content for patterns that are never legitimate in a skill package, fail closed, and
  record the verdict.

## Non-goals

- No trust tiers, no registries, no signing, and no sandbox for skill scripts.
- No change to the fetch transport, archive reader, provenance file name, or the product-owned
  bundled state.
- Hiding skills that lack a usable description from the model-visible catalog is deferred.

## Gates

### G1 — Destructive path safety
- [x] `remove` validates the name against the same pattern as install.
- [x] The resolved target must be a strict child of the skills root: never the root itself, never a
      symbolic link, never a resolved path outside the root.
- [x] Refusals are explicit, exit non-zero, and leave the filesystem untouched.

### G2 — Local-edit protection
- [x] `update` compares the on-disk digest with the recorded install digest.
- [x] A mismatch is reported as a local edit and skipped, not overwritten.
- [x] `update --force` replaces it, and the new digest is recorded.
- [x] An unmodified skill still updates normally.

### G3 — Pre-activation content screening
- [x] Staged files are scanned before anything is written to the skills root.
- [x] Findings cover credential paths, remote-content-to-shell execution, encoded execution,
      outbound file upload, destructive filesystem commands, permission relaxation, instruction
      override, and secret harvesting.
- [x] A flagged package is refused by default with the findings listed.
- [x] `add --allow-flagged` installs it and records the verdict; clean installs record `clean`.
- [x] Binary content is skipped rather than misdecoded.

### G4 — Surface and documentation
- [x] `update` exposes `--force`; `add` exposes `--allow-flagged`; both are documented in help.
- [x] The owning agent documentation and the third-party install QA matrix describe the new
      behavior.

### G5 — Verification
- [x] `fvm dart analyze` clean in `agent/`.
- [x] Focused tests cover every gate, including regression tests for defects 1 and 2.
- [x] Manual end-to-end proof recorded in this task file.

## Acceptance criteria

- [x] A `remove` with a traversal segment, a symbolic link, or the skills root itself is refused.
- [x] Editing an installed skill and running `update` leaves the edit intact and says so.
- [x] The same command with `--force` replaces it and updates the recorded digest.
- [x] A package whose content pipes a remote download into a shell is refused; the same package
      installs with `--allow-flagged` and its provenance records a flagged verdict.
- [x] No new dependency in `agent/pubspec.yaml`.

## Manual End-to-End Proof

Executed against isolated throwaway Home:

```bash
# 1. Traversal remove refusal
fvm dart run bin/sanad_agent.dart skills remove ../outside --home "$SKL_HOME"
# Output: Invalid skill name "../outside". Use letters, digits, dots, dashes, and underscores, starting with a letter or digit. (exit 1)

# 2. Root remove refusal
fvm dart run bin/sanad_agent.dart skills remove . --home "$SKL_HOME"
# Output: Invalid skill name ".". Use letters, digits, dots, dashes, and underscores, starting with a letter or digit. (exit 1)

# 3. Clean skill add
fvm dart run bin/sanad_agent.dart skills add "$SKL_SRC/clean_skill" --home "$SKL_HOME"
# Output: Installed clean_skill (user) → .../home/skills/clean_skill

# 4. Local edit and update (skip)
echo "Local edit" >> "$SKL_HOME/skills/clean_skill/SKILL.md"
fvm dart run bin/sanad_agent.dart skills update --home "$SKL_HOME"
# Output: Skipped clean_skill (local edits; re-run with --force)

# 5. Update with --force
fvm dart run bin/sanad_agent.dart skills update --force --home "$SKL_HOME"
# Output: Updated clean_skill

# 6. Malicious skill refused by default
fvm dart run bin/sanad_agent.dart skills add "$SKL_SRC/bad_skill" --home "$SKL_HOME"
# Output: Skill "bad_skill" was flagged by security screening:
# flagged (1 finding(s)):
#   - SKILL.md:6 [remote-exec] Pipes remote content into a shell
# Re-run with --allow-flagged to install anyway. (exit 1)

# 7. Malicious skill accepted with --allow-flagged
fvm dart run bin/sanad_agent.dart skills add "$SKL_SRC/bad_skill" --allow-flagged --home "$SKL_HOME"
# Output: Installed bad_skill (user) → .../home/skills/bad_skill
# Provenance records: "scan": "flagged"

# 8. Symlink remove refusal
ln -s "$SKL_TEMP/outside_dir" "$SKL_HOME/skills/symlinked"
fvm dart run bin/sanad_agent.dart skills remove symlinked --force --home "$SKL_HOME"
# Output: Skill "symlinked" is a symbolic link; refusing to remove. (exit 1)
```

## Status

Implemented and verified in isolated worktree. Verification and delivery stay with the
orchestrator.
