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

After that race was fixed, hosted validation reached the Windows compile step
and exposed an independent workflow parsing failure: the PowerShell backtick
continuations did not pass the define, entry point, or output arguments to Dart,
which reported `Missing Dart entry point`.

## Change

Keep the production replacement protocol unchanged. Make the native Windows
release test wait for both terminal evidence: the result file exists and the
detached replacement script has been removed. Retain explicit assertions for
the `started` status and script cleanup.

Invoke the Windows release compiler on one PowerShell line with an explicitly
quoted version define. A static workflow contract requires that complete command
and rejects the former backtick form.

## Definition of Done

- The focused native Windows handshake test passes locally.
- The complete Windows release/update test file passes locally.
- `fvm dart analyze` passes in `agent/`.
- A release-version Windows Agent executable compiles locally and on the hosted
  Windows release runner.
- The workflow contains no backtick-continued Windows Dart compile command.
- The release verification guide records both the race-safe terminal assertion
  and the hosted compile parsing boundary.
