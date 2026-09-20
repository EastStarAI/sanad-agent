---
status: implementation_complete
current_gate: G2 verification
remaining_estimate: Graphify CLI availability and matched Windows runtime startup
---

# Windows Authentication Lock Reconnect Recovery

## Goal
Keep the Agent alive and restore cloud registration automatically when a transient desktop authentication lock contention occurs, while minimizing the Client's authentication-lock critical section.

## Locked Decisions and Scope
- Preserve the shared stable `auth.refresh.lock` serialization boundary and its bounded acquisition timeout.
- Treat lock acquisition timeout during cloud registration as a transient platform failure, not a daemon-fatal error.
- Retry registration only while the same cloud socket remains connected, and request a fresh Gateway challenge rather than reusing a possibly stale challenge.
- Keep credential persistence and refresh rotation serialized; move profile HTTP retrieval outside the Client file-lock critical section.
- Do not delete or replace the stable lock file, weaken cross-process exclusion, or expose credentials in logs.

## Gates

### G0 — Discovery and Regression Shape
- [x] Trace the timeout from Gateway reconnect through `AuthManager.reload()` and the shared native lock.
- [x] Identify Client network work performed while holding `auth.refresh.lock`.
- [x] Add focused regression tests for uncaught registration lock timeout and profile retrieval under lock.

### G1 — Implementation
- [x] Contain and retry transient registration lock timeout without terminating the daemon event loop.
- [x] Coalesce registration attempts and avoid replaying stale challenge nonces.
- [x] Move Client profile retrieval outside the authentication lock.
- [x] Update active technical and QA documentation.

### G2 — Verification
- [x] Run format and analyzers for Agent and Client changes.
- [x] Run focused Agent, Client, and shared-lock tests.
- [x] Attempt broader fast suites and classify unrelated baseline/environment failures.
- [ ] Update Graphify after code changes. Blocked because `graphify` is not installed on this Windows PATH and this checkout has no `graphify-out/graph.json`.
- [ ] Validate the matched Client/Agent behavior in an isolated FVM debug runtime on Windows. The FVM Windows Debug Client built and launched, but three `sanad-dev run --background` attempts exceeded the launcher's 360-second Agent-readiness window and were cleaned up; no daemon-fatal auth timeout appeared.

## Acceptance Criteria
- [x] Given `AuthManager.reload()` times out acquiring the auth lock during socket registration, the socket callback contains the failure rather than propagating it to the daemon event loop.
- [x] Given the lock becomes available after a timeout, registration retries while connected and requests a fresh challenge.
- [x] Given concurrent challenge callbacks arrive during contention, they coalesce and stale nonces are not replayed.
- [x] Given an external desktop auth exchange changes the User token, the Client releases `auth.refresh.lock` before starting profile HTTP retrieval.
- [x] Existing cross-process refresh serialization and credential persistence focused tests continue to pass.

## Definition of Done
- [x] Relevant source, tests, technical documentation, and QA matrix are updated together.
- [x] `fvm dart analyze` and focused Agent tests pass.
- [x] `fvm flutter analyze` and focused Client tests pass.
- [x] Shared auth-lock tests pass on Windows.
- [ ] `graphify update .` completes when the CLI is available.
- [ ] A matched isolated Windows debug runtime reaches ready once the independent launcher-readiness issue is resolved.
