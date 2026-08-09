---
title: "Windows Agent Release Handshake Race"
description: "Remove the timing race from the native Windows replacement release gate without weakening updater behavior."
---

# Windows Agent Release Handshake Race

## Problem

The hosted Windows Agent release gate can observe the updater result file after
PowerShell writes `started` but before the detached script completes its final
self-cleanup. The release test then fails on the still-present script even
though the replacement handshake succeeded.

## Change

Keep the production replacement protocol unchanged. Make the native Windows
release test wait for both terminal evidence: the result file exists and the
detached replacement script has been removed. Retain explicit assertions for
the `started` status and script cleanup.

## Definition of Done

- The focused native Windows handshake test passes locally.
- The complete Windows release/update test file passes locally.
- `fvm dart analyze` passes in `agent/`.
- A release-version Windows Agent executable compiles locally.
- The release verification guide records the race-safe terminal assertion.
