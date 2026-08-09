---
title: "macOS Agent Notarization Ticket Propagation"
description: "Keep the macOS release gate strict while allowing bounded time for an accepted notarization ticket to become queryable."
---

# macOS Agent Notarization Ticket Propagation

## Problem

Both hosted macOS Agent submissions were accepted by Apple, but the immediate
raw-executable `codesign --test-requirement '=notarized'` lookup failed. The
same check passed in earlier release probes, indicating a delay between accepted
submission processing and ticket lookup availability rather than a signing or
notarization rejection.

## Change

Keep Apple acceptance and the explicit raw-executable notarization requirement
mandatory. Retry only the ticket lookup for a short bounded interval, then fail
closed if no attempt succeeds.

## Definition of Done

- The workflow still requires `notarytool submit --wait` success.
- The explicit `=notarized` requirement remains mandatory for both Agent architectures.
- Retries are bounded and end in failure when the ticket stays unavailable.
- Workflow syntax and repository release checks pass locally.
- A macOS machine or hosted runner provides final `codesign` evidence.
