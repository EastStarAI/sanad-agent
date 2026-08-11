---
title: "Open-Source Launch Polish"
description: "Close workspace synchronization, first-run composer defaults, and platform status-bar gaps before the public announcement."
status: "implemented_pending_review"
scope: "Public Flutter client"
---

# Open-Source Launch Polish

## Goal

Deliver the final public-client launch polish in one focused pull request while
implementing and verifying each user-facing issue independently.

## Gates

### Workspace selector synchronization

- [x] Project authoritative `ConversationCacheRepository` workspace snapshots
      into the composer state.
- [x] Make a workspace created from the sidebar/cache available before the
      selector is opened; never depend on a popup-open refresh cycle.
- [x] Add focused regression coverage and update product, technical, contract,
      and QA documentation.

### First-run composer defaults

- [x] Default an unset thinking mode to `balanced` without replacing a saved
      returning-user choice.
- [x] When a provider route exists and no model preference is saved, select the
      daemon-owned default model instead of rendering an empty selector.
- [x] Cover new-user and returning-user paths.

### Desktop-only home status bar

- [x] Render the home status bar only on native desktop targets.
- [x] Keep it hidden on Web and mobile.
- [x] Add platform-focused widget coverage.

## Verification

- Run focused Flutter unit/widget tests for every gate.
- Run `fvm flutter analyze` after all client changes.
- Run broader fast tests only if shared-state blast radius warrants them.
- Run `graphify update .` after code changes.

No commit, push, or pull request is performed without explicit user approval.
