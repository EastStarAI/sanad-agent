---
title: "Task 43b: OpenCode Go Thinking Mode Integration and Selector UX"
status: "completed"
current_gate: "G7"
remaining_estimate: "0% (0/8 gates)"
priority: "high"
branch: "feat/task-43-provider-aware-thinking-mode"
---

# Task 43b: OpenCode Go Thinking Mode Integration and Selector UX

## Goal

Enable thinking mode controls for OpenCode Go reasoning models, resolve the default thinking effort to "Medium" (eliminating ambiguous "Default" labels), add stable UI testing keys, render a leading checkmark indicator in front of the currently active selection in the thinking mode popup, expand OpenAI / Codex reasoning effort tiers to support `xhigh` ("Extra High") and `max` ("Max"), and unify immediate session persistence across Model, Provider, and Thinking Mode selections.

## Locked Decisions and Scope

- **Worktree Boundary:** Work executed and verified inside `.agent/worktrees/43-provider-aware-thinking-mode` on branch `feat/task-43-provider-aware-thinking-mode` using custom home `~/.sanad-test`.
- **OpenCode Go Policy Binding:** Assign `thinkingPolicyId: 'openai_chat_effort'` to `opencode-go` in `agent/lib/engine/adapters/provider_registry.dart` to opt into Task 43 reasoning effort controls under `chat_completions`.
- **Model Recognition Heuristics:** Update `agent/lib/core/provider_thinking/openai_reasoning_models.dart` to support reasoning controls when `context.templateId == 'opencode-go'` with `supportsReasoningOutput == true`, and expand heuristic patterns for OpenCode Go models (`deepseek-v`, `deepseek-flash`, `kimi`, `glm`, `qwen`, `minimax`, `mimo`, `hy`, `longcat`).
- **Default Thinking Level ("Medium"):** Set `defaultOptionId: 'medium'` and mark the `medium` option with `isProviderDefault: true` in `agent/lib/core/provider_thinking/openai_effort_thinking_policy_base.dart`.
- **Client Fallback Resolution:** Implement `effectiveSelectionId` and refactor `labelForSelection` in `client/lib/features/conversations/presentation/utils/route_thinking_control.dart` so that when `selectionId` is null, it resolves to `defaultOptionId`, `isProviderDefault`, or `'Medium'` rather than displaying `"Default"`.
- **UI Stable Keys:** Add `Key('thinking_mode_option_${entry.id}')`, `Key('thinking_mode_title_${entry.id}')`, and `Key('thinking_mode_check_${entry.id}')` in `RouteThinkingModeSelector`, and preserve `route_thinking_mode_selector_button`, `route_thinking_mode_unavailable`, and `route_thinking_mode_hidden`.
- **Active Option Visual Checkmark:** Render a leading checkmark icon (`Icons.check`) in front of the currently active selection in `RouteThinkingModeSelector` with placeholder spacing on unselected items to preserve vertical text alignment.
- **Reference Grounding (Hermes Agent):**
  - Live wire testing from `refrence_projects/hermes-agent` confirms OpenAI Codex wire vocabulary: `"Supported values are: 'none','low','medium','high','xhigh'"`.
  - For `gpt-5.6`, `gpt-6`, `astra`, `daybreak`: wire vocabulary extends to include `'max'`.
  - `ultra` is a UI-level tier (Hermes-internal product tier); no API wire accepts `ultra` directly. Requests for `ultra` clamp down to `max` (or `xhigh` when `max` is not supported).
  - `light` and `minimal` are UI aliases clamping to `low`.
- **Expanded Reasoning Tiers:** Add `'xhigh': 'Extra High'` and `'max': 'Max'` to `openAiEffortTierLabels`. For models supporting max (`gpt-5.6`, `gpt-6`, `astra`, `daybreak`), offer `['low', 'medium', 'high', 'xhigh', 'max']`. For general reasoning models (`gpt-5.4`, `gpt-5.5`, `o3`, `codex`, etc.), offer `['low', 'medium', 'high', 'xhigh']`. Restrict `o1` to `['medium', 'high']`.
- **Unified Immediate Session Persistence:** When the user changes Model, Provider, or Thinking Mode in an active conversation, all three immediately update the session preferences on both the daemon and client state, persisting across navigation so that returning to the conversation retains the selected route options.

## Gates

### G0 — Discovery and Root Cause Analysis
- [x] Trace why OpenCode Go models displayed "Unavailable" in the route thinking mode selector (absence of `thinkingPolicyId` triggered Task 43 Gate A fail-closed rule to `unknown`).
- [x] Trace why the active thinking mode selector button initially showed "Default" instead of a real thinking level ("Medium").
- [x] Identify missing keys for popup menu items and lack of checkmark indicator for the active option.
- [x] Investigate reference project `refrence_projects/hermes-agent` for Codex wire reasoning levels (`xhigh`, `max`) and UI tiers (`light`, `ultra`).

### G1 — Agent Daemon & Thinking Policy Implementation
- [x] Add `thinkingPolicyId: 'openai_chat_effort'` to `opencode-go` in `agent/lib/engine/adapters/provider_registry.dart`.
- [x] Support reasoning controls for `opencode-go` and expand heuristic matching in `agent/lib/core/provider_thinking/openai_reasoning_models.dart`.
- [x] Specify `defaultOptionId: 'medium'` and `isProviderDefault: id == 'medium'` in `agent/lib/core/provider_thinking/openai_effort_thinking_policy_base.dart`.
- [x] Restart agent daemon via `./scripts/sanad-dev restart agent` and refresh model cache in `state.db`.

### G2 — Client Selector UX, Keys, and Indicator
- [x] Add `effectiveSelectionId` and update `labelForSelection` in `client/lib/features/conversations/presentation/utils/route_thinking_control.dart` to resolve `Medium`.
- [x] Add option keys (`thinking_mode_option_*`), title keys (`thinking_mode_title_*`), and checkmark keys (`thinking_mode_check_*`) in `client/lib/features/conversations/presentation/widgets/conversation_input/route_thinking_mode_selector.dart`.
- [x] Add leading checkmark `Icon(Icons.check)` for the active option with alignment placeholder for inactive options.
- [x] Remove temporary diagnostics while preserving stable widget keys.

### G3 — Verification & UI Automation
- [x] Add unit test coverage in `agent/test/engine/adapters_test.dart` and `agent/test/core/provider_thinking/provider_thinking_test.dart`.
- [x] Add unit test coverage for `effectiveSelectionId` and `labelForSelection` in `client/test/unit/conversations/route_thinking_control_test.dart`.
- [x] Run `fvm flutter analyze` in `client/` (0 issues).
- [x] Run `fvm dart analyze` in `agent/` (0 issues).
- [x] Run focused unit test suites (all 112 agent tests + 23 client tests passed).
- [x] Live UI verification with `sanad-dev ui`:
  - Verified `route_thinking_mode_selector_button` displays `"Medium"`.
  - Verified `thinking_mode_check_medium` appears in front of "Medium" in the popup menu.
  - Verified interactive switching to "High" and back to "Medium", with checkmark updating dynamically.
- [x] Captured visual proof screenshots in `scratch/`.
### G4 — Expanded Reasoning Effort Tiers (`xhigh`, `max`) and Legacy Clamping
- [x] Expand `openAiEffortTierLabels` with `'xhigh': 'Extra High'` and `'max': 'Max'`.
- [x] Update `effortOptionIdsForModel` to return `['low', 'medium', 'high', 'xhigh']` for general reasoning models, and `['low', 'medium', 'high', 'xhigh', 'max']` for `gpt-5.6`+, `astra`, `daybreak`.
- [x] Update legacy aliases in `thinking_selection_aliases.dart` to map `light`, `minimal`, `ultra`, `extra-high`, and clamp `ultra`/`max` when unsupported.
- [x] Add unit test assertions in `agent/test/core/provider_thinking/provider_thinking_test.dart`.
- [x] Rebuild/restart agent and client, refresh model cache for Codex provider.
- [x] Verify via UI driver (`sanad-dev ui`) that `Extra High` (`thinking_mode_option_xhigh`) is rendered and selectable in Codex models with active checkmark.
- [x] Captured visual proof screenshots for Codex and OpenCode Go thinking selector menus in `scratch/`.

### G5 — Session Thinking Mode Persistence & Non-destructive Default Fallback
- [x] Trace root cause of thinking mode reverting to initial selection (e.g. `low`) upon switching conversations and returning:
  - Identified `SessionQueryHandler.buildSessionPreferencesEnvelope` dropping requests when `model` is omitted and ignoring `thinking_mode` in payload.
  - Identified `_revalidateSelection` in `route_thinking_mode_selector.dart` wiping thinking mode to `null` (defaulting to `medium`) when `descriptor` is transiently null or unselectable.
  - Identified lack of session-level synchronization in `SessionCubit` (`agentSessions` and `selectedSession` retained stale initial `thinkingMode`).
- [x] Implement daemon-side persistence for `thinking_mode` in `agent/lib/interfaces/platforms/sanad_gateway/handlers/session_query_handler.dart`:
  - Allow preference updates when `thinking_mode` is provided (even if `model` is null).
  - Update `_sessionManager.updateSessionModeling(sessionId, thinkingMode: ..., clearThinkingMode: ...)`.
  - Emit `sessionUpdated` or `sessionPreferencesUpdated` with updated `thinking_mode`.
- [x] Safeguard client selection revalidation in `client/lib/features/conversations/presentation/utils/route_thinking_control.dart` and `route_thinking_mode_selector.dart`:
  - `isValidSelection` returns `true` when `descriptor == null || !descriptor.isSelectable` so missing descriptors are not treated as invalidation evidence.
  - `_revalidateSelection` returns early without resetting selection when `descriptor == null || !descriptor.isSelectable`.
  - `_currentSelectionId` properly falls back to `session?.thinkingMode`.
- [x] Implement synchronous session thinking mode update in `client/lib/features/conversations/presentation/bloc/session_cubit.dart`:
  - Add `applyThinkingMode(sessionId, thinkingMode)` updating `selectedSession`, `agentSessions`, and `conversationCacheRepository`.
  - Support `session_preferences_updated` alongside `session_updated` in `_handleGlobalSessionEvent`.
  - Extract `provider_instance_id` in `_onSessionUpdated`.
- [x] Integrate session thinking mode updates in `SessionMessagesCubit` and `ConversationInputCubit`:
  - Synchronize active session thinking mode in `setNextMessagePreferences`, `updateSessionPreferences`, and `sendMessage`.
  - Call `updateSessionPreferences` from `ConversationInputCubit.selectThinkingMode` when an active session exists.
- [x] Verification:
  - Add unit test coverage for session thinking mode updates and persistence.
  - Run `fvm flutter analyze` and `fvm dart analyze`.
  - Fix `sanad-dev switch` runtime launcher bug where `SANAD_DEV_WORKSPACE_HASH` was not passed to the switched agent environment, causing target health timeout and rollback.
  - Fix `ProviderModelCacheService` bug where `evidenceSource` was passed as `'live'` for network-fetched model lists, which caused profile-based reasoning descriptors (OpenAI, Codex, OpenCode Go) to falsely expire after 5 minutes with `thinking_capability_unknown`.
  - Verify interactively via `sanad-dev ui` across conversation switches (e.g. `Low` -> `High` preserved when navigating away and returning).
  - Capture visual proof screenshot in `scratch/thinking_mode_high_persisted_verified.png`.

### G6 — Unified Immediate Session Persistence (Model, Provider, and Thinking Mode)
- [x] Align payload handling in daemon `SessionQueryHandler.buildSessionPreferencesEnvelope` to extract `provider_instance_id` from either `'provider_instance_id'` or `'provider_id'`.
- [x] Update `SessionMessagesCubit.updateSessionPreferences` to immediately store `providerId` and `model` in `_nextMessageProviderByAgentId`, `_nextMessageModelByAgentId`, and persist via `preferencesRepository`.
- [x] Ensure `SessionCubit._onSessionUpdated` extracts provider instance IDs correctly from `provider_instance_id`, `provider_id`, or `model_provider`, updating the session model and provider in client cache and state.
- [x] Update `SessionMessagesCubit` and `ConversationInputCubit` to synchronize active session route changes synchronously so that navigating away and returning preserves the updated model, provider, and thinking mode uniformly.
- [x] Verification:
  - Run `fvm flutter analyze` and `fvm dart analyze` (both 0 issues).
  - Run focused unit tests for session preferences and route updates (`session_cubit_test.dart` all 54 tests passed).
  - Verify interactively via `sanad-dev ui` that changing model (`kimi-k2.7-code`) and thinking mode (`Low`) in an active conversation is preserved across session switches without sending a message.
  - Visual proof captured in `scratch/unified_session_persistence_verified.png`.

### G7 — Independent Pre-PR Review and Repair
- [x] Review the complete uncommitted repair diff against the original Task 43 fail-closed capability contract and the Task 43b acceptance criteria.
- [x] Preserve the rule that `supports_reasoning_output` alone never advertises selectable controls, including for unknown OpenCode Go models.
- [x] Repair provider-default clearing end to end: the Client sends a present empty `thinking_mode`, the daemon clears persistence, and the response emits `thinking_mode: null`.
- [x] Repair synchronous Client projection so explicit thinking-mode clearing updates the selected session and session list rather than becoming indistinguishable from an omitted update.
- [x] Repair `sanad-dev` source handoff so the target Agent receives target worktree markers before readiness and rollback restores the exact prior Agent environment.
- [x] Add regression coverage for OpenCode Go fail-closed recognition, daemon persistence clearing, Client clear projection, transport payload presence, and immutable switch environment derivation.
- [x] Verification:
  - Agent analyzer passed with 0 issues; full fast suite passed: 2059 tests, 14 skipped.
  - Client analyzer passed with 0 issues; full fast suite passed: 1306 tests.
  - `sanad-dev` analyzer passed; full package suite passed: 199 tests, 12 skipped.
  - Task 43 daemon-backed E2E passed: 4 tests with `--concurrency=1`.
  - `git diff --check` passed.

## Acceptance Criteria

- Given an OpenCode Go reasoning model (`kimi-k2.7-code` or `deepseek-v4-flash-vision-exp`), when viewed in the conversation composer, then the thinking mode selector is enabled (`isSelectable`) and does not show "Unavailable".
- Given no explicit thinking mode has been selected yet by the user, when the thinking mode chip is displayed, then it shows `"Medium"` instead of `"Default"`.
- Given the thinking mode popup menu is opened, then each option has a testable key (`thinking_mode_option_<id>`), and the currently active selection displays a leading checkmark icon (`thinking_mode_check_<id>`).
- Given a Codex or OpenAI reasoning model (e.g. `gpt-5.4`), the thinking mode selector displays `Low`, `Medium`, `High`, and `Extra High` (`xhigh`).
- Given a model supporting maximum reasoning (e.g. `gpt-5.6` or `astra`), the thinking mode selector displays `Low`, `Medium`, `High`, `Extra High`, and `Max` (`max`).
- Given legacy or UI aliases (`light`, `ultra`), migration resolves them safely to the nearest supported tier (`low` for `light`, `xhigh`/`max` for `ultra`).
- Given an active conversation where the user changes the thinking mode, model, or provider, when the user navigates to another conversation and returns, the conversation displays and preserves the last selected thinking mode, model, and provider rather than reverting to the previous state.
- Given a saved thinking mode selection, transient descriptor absence or model loading never deletes or wipes the saved selection to `medium`.
- Both `fvm flutter analyze` and `fvm dart analyze` pass with 0 warnings or errors.
- All focused unit tests in client and agent pass.

## Definition of Done

- All gates G0 through G7 completed.
- Code changes verified through automated tests and interactive UI driver control.
- Client and agent runtimes validated cleanly under `~/.sanad-test`.
- No lingering debug log statements in production code.
