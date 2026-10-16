---
title: "Task 103a — Navigation Integrity Repair"
status: completed
current_gate: G3
remaining_estimate: 0%
parent: docs/plans/done/103-conversation-navigation-integrity.md
---

# Task 103a — Navigation Integrity Repair

Parent: [Plan 103](../../done/103-conversation-navigation-integrity.md). Read the parent for the
live evidence, the approved decisions, and the locked scope.

## Goal

Make the sidebar Back/Forward controls resolve the conversation the user actually came
from — across conversations and across devices — by giving navigation exactly one owner
and by never rewriting a destination from a partial cache projection.

## Delivery model

Implement in the **primary checkout** (the live Client's source root) so the fix can be
hot-reloaded and verified interactively before any isolation step. Do not restart, reload,
or stop the running runtime — the orchestrator owns live verification. Move the accepted
work into the `fix/103a-navigation-integrity-repair` worktree/branch only after live
acceptance.

## File-level scope

1. `client/lib/features/conversations/presentation/bloc/session_cubit.dart`
   - Add one destination resolver used by both startup restore and device switch
     (typed per-device last destination; New Conversation when none exists).
   - Add the device-switch intent: switch the active agent, await the cache context
     switch, then `historyController.navigateTo(resolved)`.
   - `startNewChat` returns the resolved `ConversationDestination` (including the
     restored `workspaceId`).
2. `client/lib/features/conversations/presentation/widgets/sidebar/device_workspace_sidebar.dart`
   - Replace the bare `setActiveAgent` device selection with the typed switch intent.
   - `newConversationIn` navigates with the destination returned by `startNewChat`.
3. `client/lib/features/home/presentation/screens/home_screen.dart`
   - Delete the `knownSessions.every(...)` → `replaceCurrent(newConversation)` block. Keep
     the already-selected early return.
   - Route sessions are presented as-is (reuse the matching selected session, otherwise the
     typed placeholder); a genuinely missing session surfaces the existing failure/retry
     presentation.
   - The conversations-list branch navigates with the resolved destination, never a
     workspace-less location.
   - The selection `BlocListener` may not force a route while a user Back/Forward is in
     flight; keep only the presentation transitions that genuinely create a session
     (for example, the first send in a New Conversation).
4. `client/lib/core/navigation/navigation_history_controller.dart`
   - Expose one stack-reconciliation entry point on the controller and make
     `GoRouterHistorySync.reconcileFromRoute` delegate to it; delete the duplicated inline
     implementation in `HomeScreen`.
5. `client/lib/core/presentation/app/app_shell.dart`
   - Clear navigation history when the authenticated identity changes (sign-out or a
     different account).
6. `client/lib/core/navigation/nav_trace.dart`
   - Keep as the debug-only diagnostic surface; document it. Do not add a runtime flag.

## Tests

- New `client/test/widget/conversation_navigation_back_forward_test.dart`:
  - Back to a session absent from the loaded pages stays on that session.
  - Device switch makes URL, history, selection, and displayed conversation agree; Back and
    Forward then move predictably.
  - New Conversation round-trip keeps Forward enabled and adds one entry per navigation.
- Extend `client/test/unit/bloc/session_cubit_test.dart`: destination resolver and
  `startNewChat` return value, including the restored workspace.
- Keep `client/test/unit/core/navigation/navigation_history_controller_test.dart` green.

## Gates

### G1 — Single authority
- [x] One reconciliation implementation; unused duplicate removed.
- [x] Device switch is one typed navigation after the cache context switch.
- [x] Selection listener cannot override user Back/Forward.

### G2 — Destination integrity
- [x] Cache absence never rewrites a destination; deletion fallback is the only automatic
      New Conversation fallback.
- [x] `startNewChat` returns the resolved destination and all callers use it.
- [x] History cleared on identity change.

### G3 — Verification and docs
- [x] `fvm flutter analyze` clean in `client/`.
- [x] New widget test and extended unit test pass.
- [x] Full fast suite run once for this shared surface.
- [x] `docs/technical/client_conversation_navigation.md`, `client/lib/core/AGENTS.md`, and
      `client/lib/features/conversations/presentation/AGENTS.md` updated.
- [x] `git diff --check` passes.

## Acceptance criteria

- [x] Back reaches the previously viewed conversation even when it is outside the loaded
      sidebar pages.
- [x] After a device switch, URL/history/selection/display agree, and Back/Forward move
      predictably and visibly.
- [x] No `branch=FALLBACK-NEW-CONVERSATION` appears in a live two-device matrix.
- [x] Same-device Back/Forward keeps the current correct baseline behavior.

## Live acceptance evidence (2026-10-16, primary-checkout runtime, two online devices)

Implementation by delegated Sanad worker (`OpenCodeGo / deepseek-v4.1-flash`), session
`b4e1f7a3-5c2d-4a91-9f36-8d7e2c1b0a54`; review, gate re-runs and live acceptance by the
orchestrator. Hot reload on the live Client (VM 51894).

1. **Evicted-session Back (D1).** Opened a page-2 session `a604f4bc` via `load-more`, moved to
   another session, forced a section refresh through a device round-trip (rows 16 → 6, the
   session disappeared from the projection), then pressed Back:
   `ui.back dest=session(2f6a8b0a/a604f4bc) back=29 fwd=2` → `home.applyRoute branch=noop` →
   `session.selectSession session=a604f4bc`. No `FALLBACK-NEW-CONVERSATION`; the timeline key
   `conversation-timeline:a604f4bc-…` confirms the presented conversation.
2. **Device switch (D2).** Switch to `google-vps` now moves the URL to that device's resolved
   destination (`…/new?workspace=a1e0755c`) with `branch=noop` instead of leaving the URL on the
   previous device; Back then returns to the Macos session deterministically and switches the
   active device back.
3. **Same-device baseline.** `ui.back` → `nav.goBack` → `branch=noop`, then `ui.forward` →
   `nav.goForward` → `branch=noop`, with the forward stack preserved across both.
4. **Genuinely missing session.** Proven by the new widget test
   (`retry_history_load_button` + "Could not load this conversation."), not live-tested: the
   desktop UI has no path that opens a non-existent session URL.

Orchestrator gate re-runs: `fvm flutter analyze` clean; 117 focused navigation tests pass; the
full fast suite's only failure is pre-existing and environmental
(`test/release/android_signing_boundary_test.dart` asserts the absence of the local, gitignored
`client/android/key.properties`, dated 9 Aug).

## Out of scope

- Agent, socket protocol, cache pagination model, and sidebar projection changes.
- Commit, push, PR, merge, deployment, and worktree cleanup.
- Any per-device history scoping (rejected by decision 1).

## Evidence to return

- Diff summary per file with the reconciliation owner named.
- Exact analyzer/test commands with exit status and bounded output.
- Live `[NavTrace]` excerpt for each acceptance criterion, on two devices.
- One outcome: `Succeeded`, `Failed`, or `Unsure` with justification.
