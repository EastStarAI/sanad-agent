---
title: "Extend sanad-dev Client Startup Timeout"
description: "Allow slow macOS and desktop cold builds to complete before the managed launcher terminates the Client."
---

# Extend sanad-dev Client Startup Timeout

## Problem

The managed launcher currently allows only 90 seconds for a Flutter Client to expose its VM-service identity. A valid cold desktop build can exceed that window on slower machines, causing `sanad-dev` to terminate both processes and Flutter to report `BUILD INTERRUPTED` with exit code `-15`.

## Change

- Define one five-minute Client startup timeout shared by launch, managed component start, source switch, rollback, and manual restoration.
- Keep the component-control request window longer than Client startup so managed additions can use the complete five minutes.
- Keep the timeout bounded while allowing cold desktop builds to finish.
- Add focused regression coverage for the timeout contract.
- Document the slow-build behavior in the runtime ownership and QA guides.

## Definition of done

- Every managed Client startup and restoration path uses the shared five-minute timeout.
- A Client that is still building after 90 seconds is not terminated before the five-minute deadline.
- Static analysis and the focused `sanad-dev` startup-probe tests pass.
