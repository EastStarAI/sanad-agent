---
title: "Multimodal Tool Results and View Image"
description: "Locked provider-neutral tool-result, image loading, provider translation, durability, and binary-safety contract."
---

# Multimodal Tool Results and View Image

## Ownership

- `core/models` owns the transport-neutral serialized result types because they cross capability, engine, persistence, and adapter boundaries.
- `capabilities` owns result construction, image validation, path authorization, image policy, and `view_image` execution.
- `engine` owns execution ordering, text/image batch budgets, canonical history insertion, and provider-facing projection selection.
- provider adapters own wire translation only.
- evolution/runtime persistence owns atomic message/checkpoint mutation and history pruning.
- interfaces expose binary-free events and history projections; the client has no image execution or storage authority.

## Canonical result model

`ToolExecutionResult` schema version 1 contains ordered sealed blocks, `isError`, and an optional closed `ToolResultErrorCode`. Blocks are `ToolTextBlock(text)` or `ToolImageBlock(dataBase64, mimeType, width, height, detail)`.

Every result contains at least one non-empty text block. `displayText` is a deterministic getter derived from text blocks after `ToolOutputGuard`; it is not serialized as a second source of truth. An image block is valid only when base64 decodes, MIME is PNG/JPEG/WebP, dimensions are positive and match validated metadata, and the common image policy has accepted it.

`Message.toolResult` is permitted only for `MessageRole.tool`. New tool messages persist both the typed result and the compatibility `content=displayText`; typed content is authoritative and serialization rejects a divergent projection. Old messages with only `content` remain valid and require no database migration.

## Text-tool compatibility

`BaseTool.execute` returns `Future<ToolExecutionResult>`. A text constructor wraps existing outputs without changing their characters. MCP and platform bridges may remain string-returning internally, but their `CallbackTool` boundary normalizes the string before it reaches the coordinator. Exceptions become one text-only error result with an established closed error code; no code infers image/error semantics by stringifying a rich result.

## `view_image` contract

The schema is `view_image(path: string, detail?: low|auto|high|original)`, with `auto` as default. It is local-only, workspace-required, read-only, and restart-replay-safe. URL, data URI, multiple paths, OCR, generated images, animated content, and temporary output files are excluded.

Authorization order is canonicalize, classify, authorize, then stat/read. An internal target proceeds directly. An external canonical target requires a decision scoped to `view_image` or `full_access`. Caller spelling, extension, or a symlink cannot weaken the classification.

The loader accepts static PNG/JPEG/WebP based on magic bytes. It rejects directories, empty/corrupt/deceptive/multi-frame content and applies the following central policy:

| Policy | Locked value |
|---|---:|
| dependency | `image: ^4.9.1` |
| worker concurrency | 2 |
| processing timeout | 15 seconds |
| input file ceiling | 20 MiB |
| decoded-pixel ceiling | 40,000,000 |
| hard longest edge | 7,900 px |
| per-image base64 ceiling | 4 MiB ASCII |
| per-batch image count | 4 |
| per-batch base64 ceiling | 12 MiB ASCII |

`low`, `auto`, and `high` cap the longest edge at 768, 2,048, and 4,096 pixels. They never enlarge. Bytes already inside dimension and payload ceilings may pass unchanged. Otherwise the worker resizes and encodes opaque content as JPEG quality 85 and alpha content as PNG compression 6. A result still above the payload ceiling fails.

`original` preserves the verified source bytes, MIME, and dimensions. It fails when any hard dimension/pixel/payload ceiling is exceeded; it never silently resizes. Decode/resize/encode runs outside the daemon event loop and leaves no filesystem artifact.

The coordinator applies the image-count and aggregate payload ceilings in tool-call order. A result crossing the remaining batch budget becomes `batch_image_budget_exceeded` with text only.

## Provider capability and translation

`LLMAdapter` exposes one closed media capability: `textOnly` or `imageToolResults`. Wrappers delegate the exact inner value. Capability is protocol-owned in v1, not inferred from model names or learned from a failed request.

| Adapter/protocol | v1 capability | Projection |
|---|---|---|
| Codex Responses | `imageToolResults` | `function_call_output.output` with ordered `input_text`/`input_image` |
| Anthropic | `imageToolResults` | nested text/image blocks inside `tool_result` |
| deterministic E2E fixture | explicit test value | captures the same canonical blocks |
| OpenAI-compatible Chat | `textOnly` | display text plus omission marker |
| Ollama/custom/missing/unknown | `textOnly` | display text plus omission marker |

Responses preserves `call_id`; `original` maps to wire `detail=high` while retaining original bytes. Anthropic preserves `tool_use_id` and does not serialize detail. Standard Chat tool messages never receive `image_url`, because the standard tool-message contract is text-only.

The fallback suffix is exactly `[Image omitted: active provider does not accept image tool results.]`, added once when at least one image block is omitted. It exists only in the provider request and does not mutate canonical history. It is a deterministic degradation, not an error eligible for transparent retry or failover.

The catalog remains workspace-stable: `view_image` is present whenever a workspace exists. A text-only route may call it but receives the explicit omission projection. Model-specific vision metadata is not introduced in v1.

## Persistence and recovery

Rich image content is inline JSON in `Message.toolResult`; v1 adds no blob table or sidecar file. A completed result first enters `completed_tool_results_v2` in continuation metadata. The legacy `completed_tool_results` parser remains for text checkpoints during migration.

`SessionExecutionStateCoordinator` owns the transaction that appends the canonical tool message and removes its rich checkpoint copy. `completed_tool_outputs` contains only bounded redacted text/status metadata. After a completed result is durable, restart/retry uses that snapshot and never reopens the path. A malformed persisted block becomes `[image data unavailable: invalid persisted payload]` and is not re-executed.

## Retention and pruning

Pruning runs after a successful assistant-message persistence:

1. protect every image in the current/incomplete tool loop;
2. preserve images belonging to the latest three completed assistant turns;
3. replace older image blocks with `[image data removed after model processing]`;
4. if retained base64 still exceeds 24 MiB, prune oldest completed-turn images until under the cap;
5. persist only when the idempotent transform changed history.

Surrounding text, order, tool-call identity, error state, and compatibility content remain valid. Pruning never produces an orphan tool result.

## Binary-safe projections

- Tool events, logs, approval payloads, plugin notifications, and history queries use `displayText` and status only.
- `LLMRequestDumper` recursively replaces image base64/data URIs with MIME/byte-count markers in a deep copy; the live request is unchanged.
- Generic character truncation never scans base64. Image budgets run before history insertion.
- Errors contain no bytes, data URI, file contents, absolute external paths, or stack traces.

## Verification obligations

- Type validation, JSON v1 round trip, legacy text parsing, and divergent projection rejection.
- Exact compatibility for every existing text tool and callback bridge.
- Workspace/external authorization, symlink/traversal, MIME deception, animated rejection, all numeric boundaries, timeout, and cleanup.
- Exact Responses/Anthropic payloads and text-only adapter fallback for sync/stream paths.
- Sequential/parallel/batch budgets, atomic checkpoint promotion, crash recovery, stale-run isolation, and changed/deleted source file.
- Three-turn and 24-MiB pruning, corrupt payload degradation, request-dump redaction, and binary-free interface projections.
- One daemon-backed run proving an answer from pixels unavailable in filename/prompt.
