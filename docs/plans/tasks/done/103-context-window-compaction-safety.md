---
title: "Task 103: Context Window Resolution and Compaction Safety"
status: "completed"
current_gate: "G3"
priority: "critical"
---

# Task 103: Context Window Resolution and Compaction Safety

## Goal

Resolve the compound failures in local model context calculation and premature context compaction by:
1. Ensuring correct context window detection for Ollama and local models (preventing fallback to 8,192 or 4,000 for 128k/131k models like `gemma4:e2b`).
2. Prioritizing live model probing (`/api/show`) over stale/inaccurate catalog cache in `OllamaAdapter`.
3. Making model name parsing in `ModelMetadata` resilient to separator variations (e.g., `gemma4` vs `gemma-4`, `llama3.1` vs `llama3`).
4. Making `calculateEffectiveInputWindow` adaptive for small context windows to avoid swallowing the input budget with fixed reservations.
5. Preventing futile auto-compaction attempts when fixed overhead (system prompt + tools) already exceeds the effective input budget.
6. Increasing provider watchdog timeouts (`connectTimeout: 90s`, `firstByteTimeout: 120s`) in `ProviderWatchdogConfig` to handle local model cold-starts gracefully.
7. Verifying the fix end-to-end using `sanad-client-tester` with `home = ~/.sanad-test`, adding Ollama via UI, and testing multi-turn conversations.

## Locked Decisions and Scope

- Work isolated in worktree `.agent/worktrees/103-context-window-compaction-safety` on branch `feature/103-context-window-compaction-safety`.
- `ModelMetadata.getLimitForModel`: Normalize separators (`-`, `_`, `.`) during lookup and add canonical entries for `gemma4`, `gemma3`, `gemma2`, `llama3.1`, etc.
- `OllamaAdapter.getContextLimit`: Query `/api/show` live to read exact `context_length` from GGUF metadata before falling back to cached catalog entries or static metadata, and cache probed limits in memory.
- `calculateEffectiveInputWindow`: Bound total reservations (`outputReservationTokens + safetyBufferTokens`) so they do not exceed a proportional ceiling (35% of `window`) on smaller windows, preventing budget starvation.
- `AgentRunner._maybeAutoCompactProspectiveTurn`: Guard against impossible compaction when fixed request overhead (`systemPromptTokens + runtimeContextTokens + toolSchemaTokens`) exceeds or meets `effectiveInputBudget`.
- `ProviderWatchdogConfig`: Default `connectTimeout` set to 90 seconds and `firstByteTimeout` set to 120 seconds to prevent premature client timeout on local hardware during model loading.
- Automation test keys added to `model_selection_view.dart` and `model_picker_dialog.dart`.
- Verification protocol:
  1. Static analysis (`fvm dart analyze` in `agent/`, `fvm flutter analyze` in `client/`).
  2. Targeted unit tests in `agent/test/` (ModelMetadata, Adapters, ContextCompactionEngine, ProviderRequestTransport).
  3. Interactive UI verification via `sanad-dev run --driver --home ~/.sanad-test`, adding Ollama provider through the client UI, and executing multi-turn conversation scenarios with `gemma4:e2b`.

## Gates

### G0 — Discovery and Root Cause Reproduction
- [x] Trace root cause in logs, `state.db`, and `request_dumps`.
- [x] Identify `gemma4:e2b` matching `'gemma'` (8192) in `ModelMetadata` due to hyphen mismatch.
- [x] Identify `OllamaAdapter` prioritizing `modelContextLimitLookup` over `/api/show`.
- [x] Identify fixed 5120-token reservation causing 3072 input budget vs 4700 fixed overhead.
- [x] Identify `projectionStillOverBudget` failure in `ContextCompactionEngine`.

### G1 — Implementation
- [x] Update `ModelMetadata` in `agent/lib/core/models/model_metadata.dart` to support separator-insensitive lookup and `gemma4`/`gemma3`/`gemma2` entries.
- [x] Update `OllamaAdapter.getContextLimit` in `agent/lib/engine/adapters/ollama_adapter.dart` to probe `/api/show` live before catalog lookup and cache probed results.
- [x] Update `calculateEffectiveInputWindow` in `agent/lib/engine/context/request_pressure_snapshot.dart` with proportional reservation ceiling for smaller windows.
- [x] Add guard in `AgentRunner._maybeAutoCompactProspectiveTurn` (`agent/lib/engine/agent_runner.dart`) to skip compaction when non-compressible overhead exceeds budget.
- [x] Update `ProviderWatchdogConfig` (`connectTimeout = 90s`, `firstByteTimeout = 120s`) in `agent/lib/engine/adapters/provider_watchdog_config.dart`.
- [x] Add test keys to `client/lib/features/provider_setup/presentation/widgets/model_selection_view.dart` and `client/lib/features/conversations/presentation/widgets/conversation_input/model_picker_dialog.dart`.

### G2 — Unit and Integration Testing
- [x] Add unit tests for `ModelMetadata.getLimitForModel` covering `gemma4:e2b`, `gemma-4`, `llama3.1:8b`, etc. (`agent/test/core/models/model_metadata_test.dart`).
- [x] Add unit tests for `OllamaAdapter.getContextLimit` verifying live probe priority and fallback behavior.
- [x] Add unit tests for `calculateEffectiveInputWindow` verifying reservation bounding.
- [x] Add unit tests for `AgentRunner` compaction preflight guard.
- [x] Run `fvm dart analyze` in `agent/` (0 issues).
- [x] Run `fvm flutter analyze` in `client/` (0 issues).
- [x] Run targeted agent tests: `fvm dart test test/core/models/model_metadata_test.dart test/engine/adapters/provider_request_transport_test.dart test/engine/context_compaction_engine_test.dart` (All 46 tests passed).

### G3 — Live Interactive Client Verification (`~/.sanad-test`)
- [x] Launch driver-enabled matched runtime from worktree: `sanad-dev run --driver --home ~/.sanad-test`.
- [x] Verify runtime status via `sanad-dev status`.
- [x] Using `sanad-dev ui`, navigate to Settings / Providers and add the local Ollama provider (`http://localhost:11434`, model `gemma4:e2b`). Verified in `~/.sanad-test/state.db` that `provider_model_cache` stored 256,000 limit.
- [x] Open ModelPickerDialog from `model_selector_btn`, tap `model_option_gemma4:e2b`, verified active model updated to `gemma4:e2b`.
- [x] Create a new session, send first message ("مرحبا"), verified assistant response rendered cleanly in UI.
- [x] Send second message ("شكرا لك، هل يمكنك أن تخبرني باختصار كيف تعمل مساحات العمل؟"), verified that NO context compaction was triggered and assistant response completed in 11 seconds.
- [x] Verified full multi-turn conversation flow without any `context_compaction.failed` error banner or red tiles.

## Acceptance Criteria

- [x] `gemma4:e2b` resolves to its true context length (131,072 / 256,000) instead of 8,192.
- [x] Multi-turn conversation does NOT trigger false context compaction after message 2.
- [x] No `context_compaction.failed` error tile or red banner appears during normal conversation.
- [x] Probed Ollama context limits are cached and used authoritatively.
- [x] All unit tests pass and analyzer reports 0 issues.
- [x] Interactive verification on `~/.sanad-test` succeeds end-to-end.
