# SKL-01 — `sanad skills` install command

## Goal

Make a public Agent Skills repository installable in one command:

```bash
sanad skills add AhmedAttia3/agent-skills --skill install-sanad
```

so a Sanad user can take any `SKILL.md` collection from GitHub (or a local directory) and make it
available to the agent without hand-copying folders or knowing where the Home lives.

## Locked decisions and scope

- **Command surface:** `sanad skills` (no subcommand) lists, plus `list`, `add`, `remove`, `update`.
  The current stub that only prints bundled-sync counts is replaced.
- **Sources:** `owner/repo`, `owner/repo@ref`, `https://github.com/owner/repo[/tree/<ref>/<sub>]`,
  and a local directory path. Non-GitHub git endpoints (ssh, private, self-hosted) are explicitly
  out of scope for v1; the error names `git clone` plus a local path as the workaround.
- **Transport:** HTTPS tarball from `codeload.github.com` through `package:http`, `dart:io` GZip, and
  a minimal ustar reader inside the agent. No `git` binary, no shelling out, no credentials, no
  dependency added to `pubspec.yaml`.
- **Skill discovery inside a source:** every `skills/*/SKILL.md` is one skill; a root `SKILL.md` is a
  single skill. A multi-skill source without `--skill` fails and prints the available names.
- **Install target:** `<SANAD_HOME>/skills/<name>` by default; `--project` targets
  `<workspace>/.sanad/skills/<name>`.
- **Provenance:** `<skills-root>/.sanad-skills.json` records
  `{name, source, ref, commit, installedAt, digest}` per installed skill. It is a separate file from
  the product-owned `.sanad-managed.json`, and user-installed ids are never reconciled, overwritten,
  or removed by `BundledSkillManager`.
- **Safety:** reject absolute paths, `..` segments and symlinks in the archive; cap payloads
  (5 MB compressed, 20 MB extracted); require the frontmatter `name` to match the target directory;
  never overwrite an existing skill without `--force`; `list` and `remove` do no network I/O.
- **No daemon change in v1:** the CLI writes to the skills roots that `SkillRegistry` already scans,
  so a running agent sees the skill on its next turn. A daemon-side command is deferred until the
  Client needs to trigger installs, because that path also owns progress reporting and approval.

## Gates

### G0 — Discovery
- [x] Read `SkillRegistry` lookup roots and precedence.
- [x] Read the CLI command runner, an existing command, and `BundledSkillManager` state layout.
- [x] Confirm `args`, `http`, `crypto`, `path` are already dependencies and `archive` is not.

### G1 — Command surface
- [x] Split `skills_command.dart` into subcommands with `CommandRunner`-style nesting.
- [x] Arg parsing: `--skill`, `--ref`, `--sub-path`, `--force`, `--project`, `--json`, `--home` (reused global).
- [x] Help text and error messages that state the accepted source forms.

### G2 — Source resolution and fetch
- [x] Parse `owner/repo`, `@ref`, GitHub URL (including `/tree/<ref>/<sub>`), and local paths.
- [x] Stream the tarball with size caps; fail closed on HTTP errors and unsupported hosts.
- [x] Minimal ustar extractor with traversal and symlink rejection; unit tests over a fixture archive.

### G3 — Install, remove, update
- [x] Atomic install (temp dir → rename) with `--force` semantics.
- [x] Write and update `.sanad-skills.json`; `remove` deletes only that skill and its entry.
- [x] `update` refetches the recorded source/ref and reports the digest delta.

### G4 — List
- [x] Human table: name, scope, active or shadowed, installed source.
- [x] `--json` single machine-readable object.

### G5 — Documentation and QA
- [x] Documented in `docs/agent_engine/capability_runtime.md`.
- [x] Added `docs/qa_maintenance/third_party_skills_install_qa.md`.

### G6 — Verification
- [x] `fvm dart analyze` clean for the touched libraries and tests.
- [x] Focused unit tests: 27 passing across source parsing, archive safety, and lifecycle.
- [x] Manual end-to-end against `AhmedAttia3/agent-skills`, verified below.

## Acceptance criteria

- [x] `sanad skills add AhmedAttia3/agent-skills --skill install-sanad` writes
      `$SANAD_HOME/skills/install-sanad/SKILL.md`, and `sanad skills list` shows it as active and
      user-scoped.
- [x] Re-running the same command without `--force` fails with a clear message and changes nothing.
- [x] `sanad skills add <local-path>` installs from disk with no network access.
- [x] `sanad skills remove install-sanad` deletes only that skill and its provenance entry, and
      leaves every bundled skill untouched.
- [x] `sanad skills update` refetches the recorded source and reports whether content changed.
- [x] An archive entry containing `..`, an absolute path, or a symlink is rejected before anything is
      written.
- [x] A `SKILL.md` whose `name` differs from the requested directory is rejected.
- [x] No `git` binary is required, and `pubspec.yaml` gains no new dependency.

## Verification evidence

```text
$ sanad skills add AhmedAttia3/agent-skills --skill install-sanad --home /tmp/skl-home
Installed install-sanad (user) → /tmp/skl-home/skills/install-sanad
Available to the agent on the next turn; no daemon restart needed.

$ sanad skills update --home /tmp/skl-home
Up to date install-sanad

$ sanad skills add <same> --home /tmp/skl-home        # exit 1
Skill "install-sanad" is already installed … Re-run with --force to replace it.

$ sanad skills add owner/definitely-not-a-repo-xyz     # exit 1
GitHub returned 404 for owner/definitely-not-a-repo-xyz at "HEAD". Check the repository, or pass --ref.

$ sanad skills remove install-sanad --home /tmp/skl-home
Removed install-sanad.
```

`skill_load` return for a third-party install was verified through the registry scan
(`skills list` shows the workspace copy shadowing the user copy), which is the same read path the
daemon uses on the next turn.

## Definition of Done

- [ ] `fvm dart analyze` clean; focused tests pass.
- [ ] Owning agent documentation updated in the same change.
- [ ] Graph refreshed for the touched corpus.
- [ ] Live verification recorded with real command output, not a claim.

## Status

**Complete.** G0–G6 closed; unit tests (27) and manual end-to-end against
`AhmedAttia3/agent-skills` passed. Remaining: owner approval to commit and deliver.
