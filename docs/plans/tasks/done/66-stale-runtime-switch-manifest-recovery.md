---
title: "Stale Runtime Switch Manifest Recovery"
status: "completed"
---

# Stale Runtime Switch Manifest Recovery

## Problem

A runtime-switch manifest can remain in `requested`, `draining`, or `starting`
after its owning launcher exits. A later healthy managed launcher then remains
usable for status/reload but every source switch is blocked forever by the
orphaned manifest.

## Design

- Treat an active-status switch manifest as live only when its launcher id and
  runtime nonce match the currently validated managed launcher lease.
- Atomically terminalize an active manifest owned by another launcher as
  `failed` before accepting a new switch request.
- Never discard an active manifest that still matches the live launcher.
- Repair only the manifest; do not signal or stop any process.

## Definition of Done

- Unit tests cover matching-owner refusal and mismatched-owner stale recovery.
- Existing switch-manifest and runtime ownership tests pass.
- Analyzer passes.
- Runtime documentation describes stale-manifest recovery.
