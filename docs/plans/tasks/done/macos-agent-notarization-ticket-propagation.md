---
title: "macOS Agent Notarization Ticket Verification"
description: "Bind Apple notarization acceptance deterministically to the exact signed macOS Agent executable without relying on delayed local ticket caches."
---

# macOS Agent Notarization Ticket Verification

## Problem

Both hosted macOS Agent submissions were accepted by Apple, but the immediate
raw-executable `codesign --test-requirement '=notarized'` lookup failed. A fresh
local arm64 submission reproduced the result through the proposed 120-second
retry and again through an extended ten-minute retry. Apple’s notary log still
reported `Ready for distribution`, status code zero, no issues, and ticket
content for the exact submitted executable.

The local online-ticket cache is therefore not a reliable release gate for this
raw CLI. Increasing its timeout would retain a nondeterministic failure without
adding trust.

## Change

Keep Developer ID signature verification, Hardened Runtime, entitlement checks,
binary execution/version verification, and `notarytool submit --wait`
acceptance mandatory. Fetch the authoritative notary log with a bounded retry,
then require:

- status `Accepted` and status code `0`;
- no reported issues;
- a `ticketContents` entry using SHA-256;
- exact architecture equality with `lipo -archs`;
- exact case-normalized `cdhash` equality with the signed executable.

This binds Apple’s accepted ticket to the exact bytes produced by the release
job and fails closed on a missing log, rejection, issue, architecture mismatch,
or hash mismatch.

## Evidence

Local macOS 26 arm64 submission `62b83964-8910-4f08-9882-8d5f18e31c5c`
returned `Accepted`. The old query failed for ten minutes; the replacement gate
matched the log’s arm64 SHA-256 ticket entry to the signed binary’s `cdhash` and
passed. No credential values or private signing material entered repository
evidence.

## Definition of Done

- The workflow still requires successful Developer ID verification and
  `notarytool submit --wait` acceptance.
- The authoritative log is fetched only with bounded retries.
- Ticket architecture and `cdhash` must match the exact signed binary.
- Missing, rejected, issued, or mismatched evidence fails closed.
- Workflow syntax, release checks, and a real macOS submission pass.
