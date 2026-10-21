---
id: 122
title: New-conversation draft loses its provider after a Client restart
status: done
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

- [x] Red→green tests:
  - the codec round-trip keeps the provider;
  - startNewChat with a provider-less cached session does not produce a half route;
  - restoring a provider-less draft falls back to the device route;
  - a draft that already persisted half a route heals on load.
- [x] Focused client analyzer and tests; owning client AGENTS.md updated if a rule changes.
- [x] Coordinator review.
- [x] Live check on Test Home: leave the app on a new draft, restart the client, and see the provider name and the thinking menu. Live r1 failed (defects D1–D3, see Round 2); live r2 passed (below).
- [x] PR and merge under the user's authorization (one-run discipline).

## Round 2: live acceptance r1 defects

User rules: a route or provider default never overwrites or persists over the user's choice; only an explicit user action writes a thinking or route preference. A user-initiated New chat keeps taking the open session's provider, model and thinking.

| Defect | Root cause | Fix |
| --- | --- | --- |
| D1 (cases 2, 4a): restart replaced a user-picked draft route and thinking | Startup `startNewChat` had nothing selected and seeded the draft from the last-selected session unconditionally | With nothing open, a persisted complete draft route and its thinking win; the last session seeds the route only without one. "Copied" and "user-changed" drafts are not distinguished (no new state), so the complete draft always wins |
| D2 (case 4c): New chat from a NULL-thinking session wrote `max` into the draft and the device preference | The draft re-resolved the route default and admitted it through `selectThinkingMode` (a user-choice path that writes the device preference); the composer then persisted the next-send value into the draft | Draft admission is in memory only (`admitRouteThinkingMode`). `SessionMessagesCubit` keeps explicit thinking apart from the admitted next-send value, and the draft persists only `explicitNextMessageThinkingMode`. The draft also re-resolves when its carried value changes without a route change |
| D3 (case 4c): a NULL session showed a carried `High`; a draft on the same route showed `Max` | For an existing conversation with no stored selection the control fell back to the composer's carried value, so any valid carried value (sibling or device level) was shown and sent | An existing conversation resolves from its own stored selection only; NULL shows and admits the route default |

Route/thinking preference consistency: the device thinking preference is written only by an explicit pick, and the route preference only by an explicit model pick, so they may name different models (a Low picked on flash stays the preference after picking glm). That is never sent as a wrong level: the control re-resolves the carried value against the active route and admits the route default in memory when the route does not offer it; a route with no control or unknown evidence omits thinking; the agent revalidates at turn admission.

Gates (round 2):
- [x] Red→green: D1 startup draft wins; New chat copies explicit High / NULL route (`session_cubit_test`); D2 real stack (no draft or device write, Max shown and carried) and composer draft persistence; D3 NULL session over a carried High; draft explicit pick returns across an unsupporting model.
- [x] 106b/older tests that encoded draft admission through `selectThinkingMode`, or a NULL session showing a carried value, were updated to the new rule.
- [x] Coordinator review and live re-check of cases 2, 4a and 4c: analyzer clean, 153 focused tests, full client suite passed (+1683).

### Live acceptance r2 (Test Home, Production profile, one real send)

All five cases PASS; no `update_session_preferences` appeared in the Agent or Client logs at any point.

| Case | Steps | Result |
| --- | --- | --- |
| 1 (D1: cases 2, 4a) | Draft on flash + Low while the last-selected session is pro + High; restart the Client | Chip shows flash and Low; the draft keeps flash/low; the device preference stays low. PASS |
| 2 (standing New chat rule) | Open a glm + High session, then New chat | Chip shows glm and High; the draft is glm/high; the device preference stays low. PASS |
| 3 (D3) | Open the glm + High session, then a session with no stored thinking | Chip shows glm and Max; the stored row stays NULL; no preference write. PASS |
| 4 (D2) | New chat from the session with no stored thinking | Chip shows glm and Max; the draft's thinking stays null; the device preference stays low. PASS |
| 5 | (b) Send from the case 4 draft; (a) on a draft, flash + Low, switch to glm, then back to flash | (b) The provider request carried `reasoning_effort=max` and the new session stored `max`. (a) glm shows Max while the draft keeps low; returning to flash shows Low. PASS |

Observation (not a defect against this task's rules): opening an existing conversation from a draft already rewrites the persisted new-conversation draft route to that conversation's route before New chat is pressed.
