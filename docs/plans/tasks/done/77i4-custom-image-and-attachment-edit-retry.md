---
title: "Task 77I4: Custom Chat image input and image-message edit/retry (Consolidated into 77I5)"
status: "consolidated"
consolidated_into: "docs/plans/tasks/77i5-unified-provider-model-capabilities.md"
current_gate: "Consolidated into 77I5"
remaining_estimate: "Consolidated"
depends_on: "77I2 checkpoint; CI evidence"
---

# Goal

> [!NOTE]
> This task has been superseded and consolidated into the active unified execution plan: [77i5-unified-provider-model-capabilities.md](77i5-unified-provider-model-capabilities.md).
> All active gates, execution boundaries, and reviewer acceptance are tracked exclusively in 77I5.

Repair image-message edit/retry behavior and close the custom OpenAI-compatible image-input gap inside the existing Plan 77 worktree. Consolidated with provider-name and thinking repairs in 77I5.

## Ownership and boundaries

Orchestrator owns checkpoint commits/pushes, GitHub checks, review and live tests. agy worker owns implementation and returned fixes after CI baseline verification; only one writer in this worktree. No merge, deployment, source switch, Home mutation or unapproved provider configuration/resource cleanup. Preserve tested Codex/Go/Anthropic wire behavior, canonical history, requester/session attachment grants, pruning, bounded media and privacy.

Custom image capability cannot be guessed from display/model name. Worker first studies Hermes and proposes minimal authority resolution for custom endpoints/models. Major schema/config/UI/architecture changes require explicit user approval before implementation. Coordinate any shared provider-instance changes with the separate main task; do not implement thinking controls here.

## Gates

### G0 — Checkpoint
- [x] Review current public/private WIP, exclude secrets/env/bytecode/raw evidence and update task status.
- [x] Authorized public checkpoint commit/push, then focused private Backend/gitlink checkpoint commit/push.
- [x] Watch Public CI and private integration on exact checkpoint commits, triage failures before new code.

G0 evidence: public checkpoint `939b251c7c8cbcd0ff1e8717d06937907f09c388`, Public CI run `38330026737` succeeded. Private checkpoint `0673634cf1d718f5b831191b09a0ea46e81ae85f` could not trigger PR CI because main conflicts prevented pull_request execution. User authorized a private-branch main merge; scoped delegated reconciliation retained attachment limits/admission and adopted main's additive-key compatibility. Independent full Backend suite: 336 passed, 5 skipped. Merge checkpoint `c8dc3f2ca353bb1f98706fd10ac5620ec3ea2050`, private CI run `38332147689` succeeded; public gitlink remains `939b251`. Neither PR was merged and no deployment/source handoff occurred.

### G1 — Delegated diagnosis and proposal
- [x] Read current contracts and Hermes image/custom-provider reference; report a concrete supported custom-route approach and approval questions.
- [x] Diagnose actual edit/retry paths for messages with image attachments, local and hosted, retaining immutable original attachments until authoritative acceptance.
- [x] Add red regressions for established failures, including failure/cancel preservation and no duplicate admission/re-execution.

### G2 — Implementation and independent review
- [x] Implement bounded attachment edit/retry repairs (preserving existing attachments without re-upload, adding/removing attachments, Cancel, failed admission/replay, original message/history preservation, authoritative acceptance, and no duplicate turn/tool execution).
- [ ] (Awaiting User Approval) Implement custom image input support per approved Deliverable B proposal.
- [x] Reuse existing canonical image codec (`ToolResultWireCodec`); no raw path image URLs, blanket vision, retry from omission or source-history mutation.
- [x] Worker analyzer/focused/E2E-as-needed tests pass with fixture-owned isolation; docs/contracts/graph updated.
- [ ] Reviewer independently reruns gates and returns defects until resolved.

### G3 — Interactive acceptance
- [ ] Reviewer verifies image attachment edit/retry on selected macOS/Web test Clients, with one-shot send ledgers and no retry after ambiguous outcomes.
- [ ] Exact custom model/provider sees pixels through an actually image-bearing request; text-only/unknown routes remain honest and safe.
- [ ] Regression smoke for already tested native protocols and draft cleanup remains green.
- [ ] Remaining estimate/gates and parent acceptance updated; no blanket claim of all-provider or whole-Plan success.

---

## Deliverable A: Diagnosis and Repair of Image Attachment Edit & Retry

### Concrete Failure Diagnosis
1. **Empty-text eligibility rejection in `TurnReplayService.inspect`**: When a root user turn contains attachments without text (empty or whitespace-only content), `inspect` unconditionally failed with `TurnReplayInspectionFailure.emptyMessage`. This prevented Retry and Edit on image-only messages.
2. **Missing attachment preservation in `TurnReplayService.admitReplacement`**: `admitReplacement` did not accept or populate `attachments` on the replacement message, resetting admitted turns to text-only.
3. **Missing attachment update in `SessionDB.commitSoftRewindAdmission`**: While `messages` was updated with the replacement user message, `user_attachments` remained staged (`status = 'staged'`, `message_id = null`), violating relational ownership and failing to reflect the new message ID.
4. **Early `empty_message` check in `SessionTurnReplayCommandHandler`**: The handler rejected empty messages before checking whether attachment edits or retry attachments existed, returning `outcome: 'empty_message'` for valid image turns. Furthermore, `replay.admitReplacement` was called without `attachments: replayAttachments`.
5. **Client inline edit guard in `brain_activity_view.dart`**: `onSubmitEdit` checked `if (text.isEmpty) return;` without checking `_editAttachments.isEmpty`, blocking users from saving edits on image-only messages.
6. **Client cubit null rejection in `session_messages_cubit.dart`**: When replaying with attachments, `session_messages_cubit` rejected `message == null` with `attachments_unsupported` instead of defaulting to empty text.
7. **Replay turn edit without `attachment_edits` crashing in `SessionTurnReplayCommandHandler`**: When `action == 'edit'` was submitted with omitted `attachment_edits`, `_stageReplayAttachments` threw a `FormatException`, returning `outcome: 'attachment_admission_failed'` and blocking text-only edits from succeeding on existing attached messages. Repaired to retain existing source attachments by default when `attachment_edits` is omitted.
8. **Cold history hydration tool name "Unknown Tool" & lost media preview in split pages**: In sessions with large image tool execution results (>1.7MB), `SessionDB.getPersistedMessagePage` byte-limiting (1MB chunk budget) splits the assistant message (with `toolCalls`) and the oversized tool result message onto separate pages. Previously, `SessionQueryHandler._buildHistoryEnvelope` evaluated only the in-page messages to resolve tool names. When an oversized tool result was hydrated cold on its own page, `_resolveToolContext` had no originating assistant message in `page.messages`, emitting `'tool': 'Unknown Tool'` and failing `ViewImageMediaProjection`, which lost the image preview.
9. **Bounded exact JSON tool call lookup in `SessionDB.findOriginatingToolCall`**: Replaced unbounded row scanning and substring/wildcard-sensitive `LIKE` search with an exact JSON `json_each` + `json_extract` SQLite query selecting only bounded tool-call and execution context columns (`m.id`, `m.turn_id`, `m.run_id`, metadata IDs, `tc.value AS tool_call_json`) with `LIMIT 2`. Enforces strict turn boundaries without cross-turn fallback when `turnId` is provided, and handles ambiguous duplicate active origins honestly by returning `null`.

### Red to Green Regression Test Evidence
- **`agent/test/interfaces/runtime/turn_replay_service_test.dart`**:
  - `root user turn with empty content but attachments is replay-eligible`: RED (failed with `emptyMessage`), now GREEN (0.0s).
  - `admitReplacement preserves attachments and commits them in transaction`: RED (missing parameter and persistence), now GREEN (0.0s).
- **`agent/test/interfaces/platforms/sanad_gateway/session_turn_replay_command_handler_test.dart`**:
  - `replay retry retains existing attachments and commits them as attached`: RED (length 0 vs 1), now GREEN (0.1s).
  - `replay retry on message with empty text and attachments succeeds`: RED (failed with `empty_message`), now GREEN (0.1s).
  - `replay edit with new attachment adds new and removes omitted`: RED (length 0 vs 1), now GREEN (0.1s).
  - `replay edit with invalid attachment upload fails admission without mutation`: GREEN (proves failed admission preserves history without mutation).
  - `replay edit with omitted attachment_edits on text-only message succeeds`: GREEN (0.1s).
  - `replay edit with omitted attachment_edits on message with attachments retains them`: GREEN (0.1s).
- **`agent/test/interfaces/sanad_bridge_test.dart`**:
  - `get_session_history resolves view_image name and preview when oversized >1MiB result is split onto separate page`: RED (resolved to `Unknown Tool` and null preview), now GREEN (0.0s).
  - `get_session_history resolves outside-page tool context with limit: 1 and cursor pagination`: GREEN (0.0s).
  - `get_session_history preserves multi-call batching and enforces session isolation`: GREEN (0.0s).
- **`agent/test/evolution/session_db_originating_tool_call_test.dart`**:
  - `resolves tool call with exact JSON matching and bounded fields`: GREEN (0.0s).
  - `exact matching handles SQL wildcard characters and quotes without regex/like errors`: GREEN (0.0s).
  - `enforces turn boundary strictly and does not fall back to different turn`: GREEN (0.0s).
  - `enforces strict session isolation with no cross-session matches`: GREEN (0.0s).
  - `parses multi-call batch correctly returning targeted tool call context`: GREEN (0.0s).
  - `resolves tool call even with JSON pretty formatting and extra whitespace`: GREEN (0.0s).
  - `handles ambiguous duplicate active origins honestly by returning null`: GREEN (0.0s).
  - `ignores superseded messages and respects active history status`: GREEN (0.0s).
- **`agent/test/engine/agent_runner_test.dart`**:
  - Pre-admitted replacement attachments survive runner commit and persisted reopen without duplicate user turn or tool re-execution: GREEN (0.1s).
- **`client/test/widget/brain_activity_inline_edit_test.dart`**:
  - `inline edit allows submitting image-only edit with empty text`: GREEN (0.1s).
  - `inline edit allows cancelling edit and restores original content`: GREEN (0.1s).
  - `inline edit allows removing attachment and shows validation error on submit when empty and no attachments`: GREEN (0.1s).
  - `failed admission preserves UI and original history on admission failure`: GREEN (0.1s).
  - `inline edit allows adding new attachment alongside retained attachment`: GREEN (0.1s).
  - `SessionMessagesCubit.replayTurn forwards null message as empty string when attachment edits present`: GREEN (0.1s).
- **`client/test/unit/services/socket_conversation_repository_test.dart`**:
  - `replayTurnWithAttachments forwards to client including empty message`: GREEN (0.0s).
- **`client/e2e_test/local_dual_connection_e2e_test.dart`**:
  - `three clients reconcile normal, steer, and replay history identically`: GREEN (4.0s).
- **Verification**: `fvm dart analyze` (0 issues), `fvm flutter analyze` (0 issues).

---

## Deliverable B: Custom OpenAI-Compatible Image-Input Authority Proposal (Unapproved Historical Proposal — Future Design Only)

> [!NOTE]
> This proposal is unapproved historical research. Active architecture alignment, auto-discovery evaluation, and unified capability planning are tracked in [77i5-unified-provider-model-capabilities.md](77i5-unified-provider-model-capabilities.md).

### 1. Primary Reference Evidence (Hermes Agent)
In Hermes (`refrence_projects/hermes-agent`):
- Multimodal capability resolution does not rely on a single universal fail-closed flag:
  1. **Native provider override**: Built-in providers (OpenAI, Anthropic, Gemini) use adapter-level multimodal schemas where vision capability is known and enabled by default.
  2. **Auxiliary routing & local endpoint probes**: Local runtimes (such as Ollama) are probed via endpoint inspection (e.g. `/api/show`) to verify whether model architecture supports multimodal input.
  3. **Exact catalog-owned endpoint mappings**: Models mapped in authoritative registries (e.g. `models.dev` catalog) use exact model IDs, not heuristic regex pattern matching on model display names.
  4. **User configuration override**: Users can explicitly configure `supports_vision: bool` on their custom model or endpoint.
  5. **Graceful fallback**: When vision capability is absent or unsupported, Hermes routes image attachments through text/OCR transcription tools rather than sending raw pixel payloads to text-only endpoints or crashing with 400 Bad Request.

### 2. Comparison of Approaches for Sanad

| Aspect | Approach 1: Explicit Triplet Authority Declaration (Recommended) | Approach 2: Exact Trusted Catalog Mapping |
| :--- | :--- | :--- |
| **Authority Scope** | Explicit future capability declaration bound strictly to `(provider_instance_id, endpoint_url, model_id)`. | Central catalog or remote registry mapping known model IDs. |
| **Custom Route Support** | Full support for arbitrary self-hosted endpoints (e.g. vLLM, Ollama, OpenRouter, LiteLLM) without external catalog sync. | Fails closed on any uncataloged self-hosted IP, local proxy, or private model. |
| **Model Name Heuristics** | **None.** No string pattern guessing (e.g. `-vision`, `vl`, `4v`). | Requires maintaining pattern whitelists or catalog updates. |
| **Stale Policy Invalidation** | Modifying either `endpoint_url` or `model_id` immediately invalidates capability declaration back to default `false` (text-only). | Requires catalog re-fetch or manual whitelist update. |
| **Shared Wire Codec** | Uses existing shared `ToolResultWireCodec.chatMessages(..., supportsImageInput: ...)`. Chat tool content remains scalar; verified images are detached user context only after fully paired contiguous result batches. | Same. |

### 3. Proposed Authority Architecture for Sanad (Future Design Only)
1. **Ownership & Scope**:
   - Authority is scoped strictly to the triplet `(provider_instance_id, endpoint_url, model_id)`.
   - Proposed future representation: an explicit capability mapping on the provider instance configuration (e.g. `capabilities: {'image_input': bool}`).
2. **Endpoint Binding & Invalidation**:
   - The capability declaration is tied to the immutable endpoint URL of the instance.
   - Any modification to `endpoint_url` or `model_id` clears the capability flag to fail-closed (`false`) until re-confirmed.
3. **Unknown / Default Behavior**:
   - Default is strictly **fail-closed** (`false` / text-only).
   - If `image_input` is not declared or false, turns remain text-only; user attachments fall back to existing tool transcription (`view_image`) when available, preventing wire 400 Bad Request errors.
4. **API & UI Surface**:
   - Provider settings in Client UI will expose an explicit toggle under Model Settings: `Support Image Input (Vision)` for custom OpenAI-compatible models.
   - When enabled, `ToolResultWireCodec.chatMessages` projects verified image results as detached user context per the existing wire contract.
   - Scalar tool messages never receive raw pixel payloads; media privacy and loopback relays remain untouched.

### 4. Questions for User Approval Before Implementation
1. **Storage Structure**: Should `image_input` be stored as an explicit boolean field under future model definitions, or within an extensible `capabilities: Map<String, dynamic>` map on the provider instance?
2. **UI Exposure**: Should the custom model configuration dialog display an explicit checkbox (`"Supports Vision / Image Input"`) when adding/editing custom OpenAI-compatible models, defaulting to unchecked?
3. **Advisory Probing**: When adding a model, should Sanad attempt an advisory non-blocking probe (e.g., querying `/models` or `/api/show`) to suggest default vision capability, while keeping the user's manual toggle authoritative?
