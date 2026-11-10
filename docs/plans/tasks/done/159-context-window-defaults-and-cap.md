# Built-in context-window defaults and the global cap

## Goal

Every model's context window is decided in one place, capped by a project-owned
ceiling, and reported with its provenance, instead of each adapter resolving its
own number and every unknown model falling back to a literal.

## Owner decisions (2026-11-10, fixed)

1. New `context.maxLimit` key. Built-in cap `358000`; a user value replaces it;
   `0` = no cap. The cap applies to shipped defaults and provider/catalog/models.dev
   values, never to a user `context.modelLimits` entry.
2. Shipped per-model defaults, each with a one-line reason and date:
   `gpt-6.1-sol: 258000`, `deepseek-v4.1-flash: 358000`. They merge key by key
   with the user's entries (user wins for its own key) and are capped.
3. Precedence: user per-model (uncapped) → shipped default → provider evidence
   (catalog, live probe, models.dev, known static metadata), capped.
4. Unknown window: a cloud route uses the cap; a local/self-hosted route whose
   live probe reports nothing uses `16000` (raised from today's 4000), still
   capped.
5. Shipped defaults also match the model id's segment after the last `/`;
   user-written keys stay an exact normalized match.
6. `context.maxLimit` values 1–8191 are rejected; `0` disables the cap.
7. One value per model everywhere: the effective (capped) window is what the
   catalog, `sanad models`, the Client indicator and compaction see. The raw
   provider value survives only as internal diagnostic evidence.
8. One generic built-in-defaults mechanism, reusable by another policy section.

## Gates

### G0 — Discovery
- [x] Read the owning contracts (`AGENTS.md`, `agent/AGENTS.md`, `agent/lib/core/AGENTS.md`, `agent/lib/engine/adapters/AGENTS.md`, `agent/lib/engine/runtime/AGENTS.md`).
- [x] Inventory every context-window resolver: `Config.contextModelLimit`, three adapter chains, `CompactionRequestFactory`, two orchestrator literals.
- [x] Record today's unknown-window fallbacks (4000 / 200000 / 128000 / bounded estimate).

### G1 — Policy owner
- [x] `builtin_policy_defaults.dart`: generic value + reason + date table, vendor-suffix lookup, key-by-key merge.
- [x] `context_window_policy.dart`: `ContextWindowSource`, `ProviderContextWindow`, `ContextWindowResolution`, the cap/local/floor constants, the shipped defaults, and the single resolution algorithm.
- [x] `model_aware_runtime_policy.dart`: `maxLimit` and `builtinContextModelLimits` fields, `effectiveContextMaxLimit`, `mergedContextModelLimits`, `resolveContextWindow`, strict `maxLimit` parsing with the 1–8191 floor, and `rejectUnknownKeys` accepting `maxLimit`.
- [x] `local_provider_routes.dart`: local engine templates and loopback endpoints in one owner.

### G2 — Adapters report evidence only
- [x] OpenAI-compatible (including Codex Responses) and Anthropic: extract provider evidence, resolve through `Config.resolveContextWindow`.
- [x] Ollama: probe/catalog/static evidence with the local fallback.
- [x] Discovery lists (live and fallback) publish the effective window and keep the raw value as internal evidence.
- [x] `ModelOption.contextWindowRaw` + `context_window_raw` in the cache; `ProviderModelProjection` strips it from the snapshot.
- [x] `AgentRuntimeService` prefers the raw catalog evidence and exposes `resolveUnresolvedContextWindow` for failure paths.

### G3 — Compaction and orchestration
- [x] `CompactionRequestFactory.resolveContextWindowTokens` no longer re-applies the user override or caps an adapter value twice.
- [x] `runner_compaction_orchestrator` and `runner_recovery_coordinator` replace `?? 128_000` with the same policy decision.

### G4 — Diagnostics
- [x] `sanad models` prints the effective window for every model and, for `--model`, one provenance line naming the layer and any cap reduction.
- [x] `sanad.models.v1` carries `context_window`, `context_window_source`, and `context_window_capped_from`.
- [x] No new log line anywhere.

### G5 — Verification
- [x] `test/core/config/context_window_resolution_test.dart` (20 cases).
- [x] `test/core/config_test.dart` schema, floor, and merge cases.
- [x] `test/core/provider_runtime/agent_runtime_service_test.dart` catalog/models.dev/built-in/`maxLimit: 0` outcomes.
- [x] `test/engine/runtime/compaction_request_factory_test.dart` precedence and no-double-cap.
- [x] `test/cli/models_command_test.dart` human and JSON provenance.
- [x] `test/engine/adapters_test.dart` cloud-unknown cap, local fallback, and cap-disabled variants.
- [x] `fvm dart analyze` clean.

### G6 — Documentation
- [x] `docs/technical/context_window_resolution.md` + `docs/llms.txt`.
- [x] `docs/agent_engine/context_compaction_design.md` config reference.
- [x] `docs/technical/provider_protocol.md` precedence and unknown-window rationale.
- [x] `agent/lib/core/AGENTS.md`, `agent/lib/engine/adapters/AGENTS.md`, `agent/lib/engine/runtime/AGENTS.md`.
- [x] `agent/config.example.yaml` and `docs/qa_maintenance/live_context_usage_indicator_qa.md`.

## Acceptance Criteria

- [x] Given a user `context.modelLimits` entry, when a turn resolves that model, then the window equals the user value exactly even above the cap.
- [x] Given no user entry for `gpt-6.1-sol`, when a provider advertises 1000000, then the resolved window is 258000 from the shipped default.
- [x] Given a provider value of 444000 and no user configuration, then the resolved window is 358000 with `cappedFrom = 444000`.
- [x] Given `context.maxLimit: 0`, then provider, shipped and catalog values are returned uncapped and a cloud unknown uses the adapter fallback.
- [x] Given a cloud model unknown from every source, then the window is the cap and the source is `unknown-cloud-cap`.
- [x] Given a local route whose probe reports nothing, then the window is 16000 (or the cap when lower) and the source is `unknown-local-fallback`.
- [x] Given `context.maxLimit` of `-1`, `1.5`, `"358000"`, `true`, or `4096`, then loading fails with an actionable `FormatException`.
- [x] Given `sanad models --model <id>`, then the output names `user`, `built-in`, `catalog`, `provider`, `unknown-cloud-cap`, or `unknown-local-fallback`, and `capped from <raw>` when the cap lowered the value.
- [x] Given a cached model, then `model.snapshot_result` carries one effective `context_window` and no `context_window_raw`.
- [x] Given a provider failure during manual compaction, then the window comes from the same policy (cap, or the local fallback) and never from a bare literal.

## Definition of Done

- [x] `fvm dart analyze` reports no issues.
- [x] The changed test files pass individually.
- [x] Documentation and contracts above are updated in the same change.
- [x] No secret, personal path, runtime or Test Home is touched.
- [x] PR opened against `main` without merging.

## Current status

`done` — G0–G6 closed; delivery tracked by the PR for
`feat(config): built-in context-window defaults and a global cap`.
