---
title: "Sanad Home Startup Performance"
description: "Keep SEC-02 filesystem enforcement fail-closed without scanning unrelated Home files or decoding terminal recovery history during daemon startup."
status: "completed"
design_contract: "docs/technical/user_data_protection_and_minimization.md"
qa_contract: "docs/qa_maintenance/local_gateway_and_sanad_home_security_qa.md"
---

# Goal

Restore bounded source-daemon startup when `SANAD_HOME` contains many request
dumps and terminal work items while preserving the SEC-02 owner-only filesystem
boundary and durable restart semantics.

# Pre-release simplification decision

Sanad has no installed-user legacy population. Startup therefore carries no
recursive migration framework or version marker. It prepares and secures the
configured roots, while every daemon-owned file is secured at its
creation/read/write boundary. Existing development data that is actually read
is tightened by that same access boundary.

# Implementation Gates

- [x] Prepare identity/state roots before configuration or database access
  without recursively enumerating their contents.
- [x] Let the supervised daemon child, not its lightweight parent, own root
  preparation before daemon composition.
- [x] Avoid spawning Unix `chmod` when the target already has its required mode.
- [x] Exclude completed/cancelled work-item payloads from startup recovery while
  preserving full-history repository queries for non-startup consumers.
- [x] Preserve symlink rejection, overlap rejection, atomic writes, and
  per-file permission enforcement on reads/writes.
- [x] Add focused regression coverage and update the design and QA contracts.

# Definition of Done

- [x] `fvm dart analyze` passes in `agent/`.
- [x] Focused Sanad Home, supervisor, durable repository, and recovery tests pass.
- [x] A real `sanad-dev run agent --config config/dev.json` reaches health with
  no recursive Home scan and no terminal-history hydration.
- [x] The source graph is refreshed with `graphify update .`.
