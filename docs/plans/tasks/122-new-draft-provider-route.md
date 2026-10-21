---
id: 122
title: New-conversation draft loses its provider after a Client restart
status: in_progress
created: 2026-10-21
delivery: own PR from fix/122-new-draft-provider-route
---

# Task 122 — New Draft Loses Its Provider After Restart

## Problem

User report (2026-10-21). After a Client restart that lands on a new-conversation draft, the route chip shows "deepseek-v4.1-flash • Not reported": no provider name and an unknown thinking control. Sending is blocked until a model is re-picked, and the defect comes back after every restart. The diagnosis was read-only and the defect predates Task 106b: every file on the path is identical on main.

## Root cause

1. **The persisted conversation cache drops the provider.** `client/lib/.../conversation_cache_codec.dart` writes the provider as `model_provider`, but decoding uses `Session.fromJson`, which reads only `provider_instance_id` (`session.dart` ~66). After a restart, every cached sidebar session has no provider until it refreshes.
2. **The startup draft copies half a route.** `session_cubit.dart` `startNewChat` (~575–625) takes the last-selected session from that cache and writes the draft with the provider null, while keeping model and thinking.
3. **Restoring the draft wipes the valid provider.** `conversation_input_panel.dart` (~460, ~534) leads to `session_messages_cubit.dart` `replaceNextMessagePreferences` (~1425–1446), which clears the device's valid provider and keeps the model. That breaks the "provider and model survive together" rule. The provider-less draft is then saved again and replays on every restart. `home_screen.dart` (~404–412) does not repair it.

Evidence (private, scratchpad) is in the coordinator's diagnosis report `test-home/temp/106-live/diag-new-session-route.md`.

## Goal

A route is never half-applied: provider and model always travel together. The cache round-trip keeps the provider, and a draft with a model but no provider is never restored. Instead the device route, or the readiness default, applies.

## Gates

- [ ] Red→green tests:
  - the codec round-trip keeps the provider;
  - startNewChat with a provider-less cached session does not produce a half route;
  - restoring a provider-less draft falls back to the device route;
  - a draft that already persisted half a route heals on load.
- [ ] Focused client analyzer and tests; owning client AGENTS.md updated if a rule changes.
- [ ] Coordinator review.
- [ ] Live check on Test Home: leave the app on a new draft, restart the client, and see the provider name and the thinking menu.
- [ ] PR and merge under the user's authorization (one-run discipline).
