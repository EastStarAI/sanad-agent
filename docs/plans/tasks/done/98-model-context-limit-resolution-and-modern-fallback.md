---
title: "98: Model context-limit resolution and safe fallback"
status: completed
current_gate: G2
platforms: all
parent_plan: none
depends_on: none
---

# 98 — Model context-limit resolution and safe fallback

## Goal

Resolve the active model's context window from authoritative route-scoped metadata so Codex GPT-6 sessions do not spuriously compact at 4K, while unknown or small local models remain fail-closed.

## Locked decisions and scope

- Context-window precedence remains: exact `config.yaml` override, revision-matched instance catalog, adapter/provider metadata, known static metadata, then a conservative unknown-model fallback.
- `CodexResponsesAdapter` receives the runtime-owned `ModelsDevService`; no duplicate metadata service or adapter state is introduced.
- Positive GPT-6 context metadata may be inherited only by a forward-compatible GPT-6 alias created from the live GPT-6 template that supplied it.
- Missing, malformed, zero, or negative metadata is not converted into an inflated limit.
- Unknown OpenAI-compatible and Ollama models retain the established `4000` fallback. A generic `257000` fallback is rejected because it is unsafe for genuinely small or unknown local models.
- No Client behavior, provider output policy, or broad compaction architecture change is included.
- The isolated review and PR lifecycle in the current user authorization supersedes the earlier instruction to work in the primary checkout and stop before commit.

## Gates

### G0 — Preservation and independent review

- [x] Preserve the exact primary allowlisted diff, untracked plan, base, index state, file hashes, and source snapshot outside the repository.
- [x] Copy only the scoped emergency files into the isolated review worktree and verify matching hashes.
- [x] Review provider/catalog/static/fallback precedence and compaction impact.
- [x] Compare proposed GPT-6 capacities with current public provider metadata.

### G1 — Bounded repair and regressions

- [x] Wire `ModelsDevService` into the Codex Responses adapter composition path.
- [x] Correct GPT-6 known metadata and constrain live-catalog inheritance to GPT-6 aliases.
- [x] Keep unknown OpenAI/Ollama fallback conservative and ignore invalid Ollama metadata.
- [x] Add focused coverage for provider metadata, missing metadata, invalid metadata, and unknown/small-model fallback.
- [x] Update the provider protocol design documentation.
- [x] Run format, analyzer, focused tests, and graph maintenance.

### G2 — Independent verification

- [x] Review the final task-only diff and verification evidence.
- [x] Confirm no Client, dependency, generated-output, or unrelated Plan97 change is present.
- [x] Record only independently reproduced evidence.

## Acceptance criteria

- [x] A Codex Responses route can resolve GPT-6 metadata through the injected `ModelsDevService`.
- [x] Exact configuration and revision-matched live catalog values retain precedence.
- [x] GPT-6 forward-compatible aliases inherit only a positive live GPT-6 template window; missing metadata remains unresolved.
- [x] Known `gpt-6-astra`, `gpt-6-sol`, and `gpt-6-luna` metadata matches current provider evidence at `1,050,000` context tokens.
- [x] Unknown OpenAI-compatible and Ollama models resolve conservatively to `4000`; malformed, zero, and negative Ollama values do not inflate the limit.
- [x] Focused Agent tests and `fvm dart analyze` pass.

## Review evidence

The copied implementation was not accepted as-is:

1. The proposed global `257000` fallback could delay compaction beyond a small or unknown local model's real window.
2. The proposed `gpt-6-luna = 272000` value contradicted both the current public `models.dev` response and the preserved local public metadata cache, which report `1,050,000` context, `922,000` input, and `128,000` output for the listed GPT-6 variants.
3. The original regression used static metadata and therefore did not prove that runtime composition actually injected `ModelsDevService` into `CodexResponsesAdapter`.
4. The original task's claimed analyzer/test/client/runtime results are implementer claims only and are not reused as independent reviewer evidence.

## Independent verification

All commands used the FVM-managed SDK. Full output is retained outside the repository under the task's authorized artifact root.

| Check | Result | Elapsed | Evidence log |
|---|---:|---:|---|
| `fvm dart test test/core/provider_runtime/agent_runtime_service_test.dart` | 18 passed | 14.727s | `test-runtime-service-20260923-01.log` |
| `fvm dart test test/engine/adapters/codex_models_service_test.dart` | 5 passed | 6.862s | `test-codex-models-20260923-02.log` |
| `fvm dart test test/engine/adapters_test.dart` | 44 passed | 9.897s | `test-adapters-20260923-02.log` |
| `fvm dart test test/engine/context_compaction_engine_test.dart` | 31 passed | 10.207s | `test-context-engine-20260923-01.log` |
| `fvm dart analyze` | No issues | 13.458s | `analyze-20260923-02.log` |
| `graphify update .` | Exit 0 | 45.768s | `graphify-update-20260923-01.log` |

The first Codex-model test run failed because the copied fixture still asserted the rejected `272000` value; the reviewer corrected the fixture to the externally verified `1050000` value and the rerun passed. No Client analyzer or Client test result is claimed because this task changes no Client code.

## Definition of Done

- [x] Source, focused tests, provider design docs, and the required graph maintenance command are consistent.
- [x] Verification records exact commands, exit status, elapsed time, and external log paths.
- [x] The completed plan is ready for archival in the task-only PR.
