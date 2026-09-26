---
title: "Task 102c — Desktop Background and System Tray"
status: complete
current_gate: G3
remaining_estimate: 0%
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
- [x] Select and validate one maintained tray integration for macOS/Windows.
- [x] Define close/hide, reopen, explicit quit, startup, and failure behavior.
- [x] Define recent-conversation ordering and safe display fallback.

### G1 — Background lifecycle
- [x] Intercept desktop close and hide the window without disposing application
      state or sockets.
- [x] Add explicit Show and Quit paths with deterministic cleanup.

### G2 — Tray projection and actions
- [x] Render and refresh the latest five cached conversations.
- [x] Show/toggle Client CLI enabled state through its settings owner.
- [x] Show Agent availability and invoke existing Start or Restart behavior.
- [x] Open a selected recent conversation through existing navigation state.

### G3 — Verification and docs
- [x] Add lifecycle, menu projection, navigation, and daemon-action tests.
- [x] Verify macOS interactively and verify the Windows native/build contract.
- [x] Document background behavior, tray controls, and Linux deferral.

## Acceptance criteria

- [x] Closing the window on macOS/Windows keeps Client sockets and CLI endpoint
      available; selecting Show restores and focuses the window.
- [x] Explicit Quit releases tray, CLI ownership, sockets, and application state.
- [x] The tray never shows more than five conversations and opens the selected
      device/session without changing another conversation implicitly.
- [x] Agent unavailable shows Start; Agent available shows Restart; each action
      calls the existing controller once and refreshes status.
- [x] Linux behavior remains unchanged and no unsupported tray is advertised.

## Definition of Done

- [x] `fvm flutter analyze` passes in `client/`.
- [x] Focused unit/widget/platform tests pass.
- [x] macOS live verification and Windows build/static evidence are recorded.
- [x] Product, user, and QA docs are current.
- [x] `git diff --check` passes.
- [x] Commit and push executed per user pre-authorized commit policy.
