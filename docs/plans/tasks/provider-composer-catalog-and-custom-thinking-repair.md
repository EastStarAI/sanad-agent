---
title: "Provider composer catalog refresh and custom thinking support (Historical Donor Task)"
status: "consolidated"
consolidated_into: "docs/plans/tasks/done/77i5-unified-provider-model-capabilities.md"
current_gate: "Consolidated into 77I5"
remaining_estimate: "Consolidated"
---

# Goal (Historical Donor Task)

> [!NOTE]
> This task has been consolidated into the archived unified execution plan: [77i5-unified-provider-model-capabilities.md](done/77i5-unified-provider-model-capabilities.md).
> All active gates, execution boundaries, and reviewer acceptance are tracked exclusively in 77I5.

Fix provider display-name freshness in composer without a Client restart, and support controlled thinking for custom providers using explicit, validated route semantics.

## Ownership and Consolidation

- User authorized consolidation of this donor catalog repair and custom thinking research into the unified Plan 77 worktree.
- The unified plan is archived in `docs/plans/tasks/done/77i5-unified-provider-model-capabilities.md`.
- No separate PR or independent main branch execution: changes are delivered and reviewed as part of the unified capabilities plan.
- The donor worktree remains preserved as a read-only historical reference.

## Evidence and scope

- User reports new custom provider names missing from composer until restart, while thinking remains Unavailable after restart.
- Known source lead: nonempty shared provider display-name cache may be reused without mutation invalidation.
- Custom thinking currently resolves unknown; Unavailable means control support is unknown, not that the model cannot reason. Image support, visible reasoning and configurable reasoning effort are separate capabilities.
- Hermes is the primary reference for multi/custom-provider behavior. Reference behavior is not automatically compatible with Sanad's contracts.

## Thinking proposal — Hermes-grounded research & design

### 1. Root Cause: Why Custom Provider Thinking Resolves "Unavailable"
In Sanad Agent (`agent/lib/core/provider_thinking/thinking_route_policy.dart`, lines 35–42), provider instances that do not match hardcoded recognized template IDs fall back to `_unknownTemplate` with `thinkingPolicyId: 'unknown'`. This routes to `UnknownThinkingPolicy` (`agent/lib/core/provider_thinking/unknown_thinking_policy.dart`), which returns `ThinkingControlDescriptor.unknown()`.

In the Flutter client (`client/lib/features/conversations/presentation/utils/route_thinking_control.dart`, lines 193–194), `ThinkingCapabilityStatus.unknown` maps directly to `RouteThinkingSelectorState.unavailable`. In `RouteThinkingModeSelector` (`client/lib/features/conversations/presentation/widgets/conversation_input/route_thinking_mode_selector.dart`, line 192), `unavailable` renders the thinking chip disabled with the label "Unavailable".

This state survives client and daemon restarts because custom provider instances currently possess no schema mechanism to declare or discover thinking capability descriptors.

**Important Domain Distinction**:
"Unavailable" in the composer indicates that *user-configurable thinking controls* are unknown/unavailable. It does **not** mean the underlying model cannot reason. For example, models like DeepSeek-R1 reason natively and emit `<think>` blocks on custom OpenAI-compatible endpoints; they function correctly without thinking parameters, but their thinking mode cannot be toggled or configured via the composer chip.

### 2. Reference Grounding: Hermes Agent (Primary Reference)
Inspected `refrence_projects/hermes-agent`:
- **Canonical Effort Ladder & Monotonic Wire Clamping** (`refrence_projects/hermes-agent/agent/reasoning_effort.py`):
  Hermes defines a standardized effort ladder. It maps requested effort to provider-specific wire vocabularies.
  - Key Invariant 1: Unset stays unset. It never invents an arbitrary reasoning parameter when none was requested.
  - Key Invariant 2: In `clamp_effort`, if the requested level is supported, or if the supported vocabulary is unknown/empty, the request passes through unchanged without modification.
  - Key Invariant 3: Clamping targets the nearest *weaker* supported level so clamping never escalates cost; `"none"` disables reasoning and is never a degradation target for an enabled ask.
- **Per-Model Configuration Precedence** (`refrence_projects/hermes-agent/hermes_constants.py`):
  Per-model configuration takes precedence over global provider defaults.
- **Custom Route Configuration** (`refrence_projects/hermes-agent/hermes_cli/web_routers/config_env.py`):
  Custom endpoints explicitly declare their API mode and store per-model detail with canonical model and reasoning effort.
- **Rejection Recovery Boundary** (`refrence_projects/hermes-agent/agent/turn_recovery.py`):
  Recovery is narrow and classified: it only triggers when matching specific upstream rejection patterns. It is bounded to a single retry. If an enabled reasoning request was rejected, it drops reasoning fields for the session, retrying with the route's default.

### 3. Secondary Comparison: OpenCode
Inspected `refrence_projects/opencode`:
- **Capabilities in Registry**:
  Models define static capabilities in a schema registry, including reasoning support and reasoning field metadata.
- **Wire Transforms**:
  Translates `reasoning_effort` per model based on declared capabilities. Differentiates OpenAI Chat (`reasoning_effort`), OpenAI Responses (`reasoning: { effort }`), and Bedrock/Anthropic (`reasoningConfig: { budgetTokens }`).
- **Turn Recovery Limitation**:
  OpenCode does not perform adaptive runtime turn-rejection recovery for arbitrary custom endpoints; if an upstream gateway rejects parameters with HTTP 400, the error surfaces directly to the caller.

### 4. Instance vs. Model Scope Authority
A single instance-level `thinkingPolicyId` alone is insufficient to govern reasoning controls:
- A custom provider instance represents a connection endpoint (e.g. `http://localhost:11434/v1` or private LiteLLM / OpenRouter proxy).
- A single custom endpoint frequently hosts heterogeneous models:
  1. Non-reasoning models (e.g. `llama-3-8b`, `gpt-4o`, `deepseek-chat`) where injecting `reasoning_effort` causes HTTP 400 rejection.
  2. Native reasoning models (e.g. `deepseek-reasoner` / `r1`) that generate reasoning traces natively (via CoT / `<think>` tags) without accepting explicit reasoning control parameters.
  3. Controllable reasoning models (e.g. `o1`, `o3-mini`, `claude-3-7-sonnet`, `qwq-32b`) that accept specific parameters (`reasoning_effort` or `thinking.budget_tokens`).

Therefore, policy authority must be structured across two levels:
1. **Endpoint/Instance Scope**: Provides transport and protocol baseline (`openai_compatible` vs `anthropic_compatible`) and base URL.
2. **Model Scope**: Authoritative ownership of thinking capability and policy.

**Default Policy: `unknown` / Provider-Managed (Pass-Through)**:
- The default for unconfigured custom models must remain **`unknown` / provider-managed** (`ThinkingCapabilityStatus.unknown` / `UseProviderDefault`).
- It must **not** default to `'none'` / `unsupported`:
  - Treating unconfigured custom models as `'none'` / unsupported would falsely claim the model cannot reason, and would risk injecting disable directives (e.g. `reasoning_effort: "none"`) that trigger HTTP 400 on endpoints where reasoning is mandatory or unsupported as a disable option.
  - Default pass-through ensures native reasoning models (`deepseek-reasoner`, `<think>` streams) function undisturbed without synthetic parameter interference.

### 5. Dialects, Constraints, and Lean Native Policy Reuse
Sanad Agent already has mature native policy classes and wire codecs in `agent/lib/core/provider_thinking/`:
- `OpenAiChatEffortThinkingPolicy`: Maps effort levels to `reasoning_effort: "low" | "medium" | "high"` on OpenAI `/v1/chat/completions`.
- `CodexResponsesEffortThinkingPolicy`: Builds `ResponsesReasoningDirective`; Responses wire uses `reasoning: { effort: "..." }`, not the Chat API's top-level `reasoning_effort`.
- `AnthropicThinkingPolicy`: Maps thinking budget to `thinking: { type: "enabled", budget_tokens: N }` on Anthropic `/v1/messages`.
  - **Anthropic Constraints**: `budget_tokens < max_tokens`, requires `max_tokens` to be explicitly set and greater than `budget_tokens`, and requires `temperature == 1.0` (or omitted). Setting `temperature != 1.0` with thinking enabled causes immediate HTTP 400 parameter validation failure.
- `UnknownThinkingPolicy`: Emits `const UseProviderDefault()`, leaving wire payloads completely untouched.
- `ThinkingRoutePolicy`: Resolves effective route templates and policy IDs.
- `ThinkingControlDescriptor`: Transport-neutral capability descriptor shipped with model snapshots.

**No Protocol or Model-String Guessing**:
- Never parse model name substrings (e.g. `r1`, `o1`, `think`) or guess wire parameters.
- Explicit configuration or provider-managed pass-through governs wire payloads.

**No Unrealistic Claims**:
- Explicit user configuration in the UI clarifies user intent, but is **not** independent proof that an upstream gateway will accept the request. Misconfigured effort levels, backend proxy limitations, or upstream version mismatches can still result in gateway rejections.

### 6. Rejection Recovery Boundary
- **Default Recommendation**: Fail safe and report cleanly without automatic turn retry.
  - Preserves Sanad's strict no-duplicate tool/turn policy.
  - A generic HTTP 400 cannot be presumed to be an idempotent, pre-execution error. Upstream proxies may have partially processed tokens, initiated downstream tasks, or errored post-execution.
  - Surfacing the rejection cleanly with descriptive guidance allows the user to adjust the model's thinking setting without risking side-effect duplication.
- **Optional Bounded Retry (Strict Pre-Execution Gate)**:
  - If user/reviewer specifically requests recovery, it must be bounded by strict invariants:
    1. Positively classified pre-execution parameter error (matching exact upstream parameter rejection strings for `reasoning_effort` or `thinking` before any generation started).
    2. Zero tool calls, external effects, or partial output chunks produced in the turn.
    3. Bounded to exactly 1 retry with reasoning parameters stripped (falling back to provider default).
    4. Session-scoped rejection caching so subsequent turns do not repeat the failing parameter.
    5. Explicit user confirmation before enabling such retry behavior.

### 7. Concrete Architectural Options & Recommendation

#### Option 1 (Recommended — Lean Model-Scoped Native Policy Reuse)
- **Mechanism**:
  1. Custom provider instance provides endpoint protocol baseline (`openai_compatible` vs `anthropic_compatible`).
  2. Default for custom models remains `unknown` / provider-managed (`UseProviderDefault`), leaving native reasoning undisturbed and composer chip showing default/pass-through state.
  3. Custom provider model settings allow users to optionally assign an existing native thinking policy (`openai_chat_effort`, `codex_responses_effort`, `anthropic_budget`) to specific models that support controllable reasoning parameters.
  4. Selected policy maps directly to existing `agent/lib/core/provider_thinking/` policy instances with zero parallel schema duplication.
  5. Rejection handling: Fail safe, surface clear diagnostic notice, no automatic turn replay by default.
- **Pros**: Zero guessing, reuses existing tested policies, preserves native reasoning for unconfigured models, respects turn execution safety.

#### Option 2 (Instance-Wide Coarse Policy Assignment)
- **Mechanism**: Add single `thinkingPolicyId` to `ProviderInstance` applying to all models on that instance.
- **Cons**: Brittle for mixed-model endpoints (e.g. `gpt-4o` + `o3-mini` on the same LiteLLM proxy); non-reasoning models fail on injected effort parameters.

#### Option 3 (Runtime Capability Probe on Setup)
- **Mechanism**: Send synthetic test requests during provider setup or model refresh to probe whether reasoning fields are accepted.
- **Cons**: Consumes user tokens, rate-limits on setup, fails ambiguously across heterogeneous models.

### 8. Material Decisions Requiring User Approval
1. **Target Architecture**: Confirm Option 1 (Lean Model-Scoped Native Policy Reuse with provider-managed default) as the approved architecture for G2.
2. **Rejection Recovery**: Confirm the default fail-safe rejection reporting policy (no auto-retry after HTTP 400).
3. **Quota Policy**: Confirm strict stop-and-report behavior on exhausted quota without automatic retry, model fallback, or account switching.

## Historical Progress in Donor Worktree
- **G0 completed**: Branch isolated from Plan 77.
- **G1 (Catalog Freshness) completed**:
  - `ProviderUsageCubit` decoupled `_catalogRevisions` from `_deviceRevisions`, preserved monotonic generation authority across `clearDevice`, and neutralized in-flight loads on authoritative snapshots.
  - `ProviderSetupFlow` synchronizes display names only when successful load/mutation advances `snapshotGeneration`.
  - Focused tests: 74/74 passed (`provider_usage_cubit_test.dart`, `provider_setup_flow_test.dart`, `conversation_input_panel_rebuild_test.dart`).
- **G1 (Thinking Proposal) completed**: Research documented and grounded in Hermes reference.
- **Consolidated into 77I5**: By user authorization, all subsequent architecture approval, capability implementation, and review proceed in `done/77i5-unified-provider-model-capabilities.md`.
