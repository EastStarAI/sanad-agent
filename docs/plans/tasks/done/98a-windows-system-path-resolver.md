---
title: "98a: Shared Windows system-PATH resolver and process-launch integration"
status: complete
current_gate: G3
remaining_estimate: "0"
platforms: windows
parent_plan: none
depends_on: none
---

# 98a — Shared Windows system-PATH resolver and process-launch integration

## Goal

Ensure Windows Agent, Client, shell-tool, and STDIO MCP child processes can find
current OS-level tools even when the invoking terminal inherited a stale PATH,
without changing POSIX behavior or starting PowerShell for every child process.

## Locked scope and ownership

- `shared/windows_path/` owns one Pure-Dart resolver for current Machine+User
  Windows PATH values.
- The resolver performs one non-interactive PowerShell registry read, caches
  success or fallback for five minutes, and coalesces concurrent async reads.
- `sanad-dev` applies the resolver to managed Agent and Client launch
  environments.
- The Agent applies the same process-wide resolver directly to `shell_execute`
  and STDIO MCP launch environments, preserving behavior when it is started by
  a service, package, IDE, or another route outside `sanad-dev`.
- MCP keeps its safe inherited-key allowlist. Explicit per-server PATH remains
  authoritative.
- Windows PATH-key lookup is case-insensitive and each child receives one
  canonical `PATH` entry. The value is never logged or sent across a gateway.
- Non-Windows environments pass inherited PATH through unchanged.

## Gates

### G0 — Discovery and design review

- [x] Enumerate the managed launcher, shell tool, and STDIO MCP launch boundaries.
- [x] Reject launcher-only inheritance as insufficient for direct/service Agent
      starts.
- [x] Confirm owning contracts and existing runtime/QA documentation.

### G1 — Shared resolver

- [x] Add the `sanad_windows_path` Pure-Dart package.
- [x] Support injected async/sync readers and clock for deterministic tests.
- [x] Cache successful and failed reads and coalesce concurrent async reads.
- [x] Normalize `Path`/`PATH` without duplicate child-environment entries.

### G2 — Launch-boundary integration

- [x] Apply the resolver to `sanad-dev` Agent/Client environment composition.
- [x] Apply it directly to `shell_execute` while preserving `runInShell: false`.
- [x] Apply it to STDIO MCP environment composition without broadening the safe
      inherited-key allowlist.
- [x] Preserve explicit MCP server PATH overrides.

### G3 — Independent verification and delivery

- [x] Shared package analyzer and tests pass.
- [x] Agent analyzer and focused shell/MCP tests pass.
- [x] `sanad-dev` analyzer, focused test, and full package suite pass.
- [x] Owning technical and QA documentation is updated.
- [x] Diff review finds no secret, PATH logging, or gateway exposure.
- [x] Graphify maintenance is not applicable because this worktree has no
      `graphify-out/graph.json`.
- [x] Independently run a managed Windows Agent and prove a real shell child can
      resolve an OS-level tool absent from the invoking stale PATH.

## Acceptance criteria

- [x] Given a Windows environment with stale inherited `Path`, managed Agent and
      Client children receive the current Machine+User system PATH.
- [x] Given an Agent started outside `sanad-dev`, `shell_execute` and STDIO MCP
      child environments still receive the resolved system PATH.
- [x] Repeated or concurrent resolutions do not start one PowerShell process per
      command/server, including when registry resolution fails.
- [x] Explicit MCP server PATH configuration overrides the resolved default.
- [x] POSIX environment composition remains unchanged.
- [x] Automated tests use injected readers rather than relying on the developer
      machine's registry.

## Definition of Done

- [x] Relevant analyzers and focused/full package tests are green.
- [x] Architecture and QA pages describe ownership, caching, fallback, casing,
      allowlist, and override behavior.
- [x] No absolute developer paths, PATH contents, credentials, or private runtime
      details are committed.
- [x] Independent Windows managed-runtime smoke passes.
- [x] Task moves to `docs/plans/tasks/done/` in the delivery commit.
