---
title: "Task 102c — Desktop Background and System Tray"
status: pending
current_gate: G0
remaining_estimate: 100%
---

# Task 102c — Desktop Background and System Tray

## Goal

Keep Sanad Client operational after its desktop window closes and provide a
macOS/Windows tray menu for recent conversations, Client CLI state, and existing
local Agent start/restart controls.

## Locked scope

- macOS and Windows are in scope; Linux tray support is deferred.
- Closing hides the window and preserves Client connections. Explicit Quit owns
  application shutdown.
- The tray shows the latest five conversations and opens the selected
  conversation in the existing Client window.
- The tray exposes Client CLI enabled state and current local Agent availability.
- `Start Agent` appears when unavailable; `Restart Agent` appears when available.
  Both reuse `LocalDaemonController` behavior already owned by the Client.

## Gates

### G0 — Platform and lifecycle contract
- [ ] Select and validate one maintained tray integration for macOS/Windows.
- [ ] Define close/hide, reopen, explicit quit, startup, and failure behavior.
- [ ] Define recent-conversation ordering and safe display fallback.

### G1 — Background lifecycle
- [ ] Intercept desktop close and hide the window without disposing application
      state or sockets.
- [ ] Add explicit Show and Quit paths with deterministic cleanup.

### G2 — Tray projection and actions
- [ ] Render and refresh the latest five cached conversations.
- [ ] Show/toggle Client CLI enabled state through its settings owner.
- [ ] Show Agent availability and invoke existing Start or Restart behavior.
- [ ] Open a selected recent conversation through existing navigation state.

### G3 — Verification and docs
- [ ] Add lifecycle, menu projection, navigation, and daemon-action tests.
- [ ] Verify macOS interactively and verify the Windows native/build contract.
- [ ] Document background behavior, tray controls, and Linux deferral.

## Acceptance criteria

- [ ] Closing the window on macOS/Windows keeps Client sockets and CLI endpoint
      available; selecting Show restores and focuses the window.
- [ ] Explicit Quit releases tray, CLI ownership, sockets, and application state.
- [ ] The tray never shows more than five conversations and opens the selected
      device/session without changing another conversation implicitly.
- [ ] Agent unavailable shows Start; Agent available shows Restart; each action
      calls the existing controller once and refreshes status.
- [ ] Linux behavior remains unchanged and no unsupported tray is advertised.

## Definition of Done

- [ ] `fvm flutter analyze` passes in `client/`.
- [ ] Focused unit/widget/platform tests pass.
- [ ] macOS live verification and Windows build/static evidence are recorded.
- [ ] Product, user, and QA docs are current.
- [ ] `git diff --check` passes.
- [ ] No commit or push without explicit user approval.
