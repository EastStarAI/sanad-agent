---
title: "Multimodal Tool Results and View Image"
description: "Provider-neutral tool results, secure user attachments, tool-chosen image inspection, conversation media, durability, and binary-safety contract."
---

# Multimodal Tool Results and View Image

## Ownership

- `core/models` owns the transport-neutral serialized result types because they cross capability, engine, persistence, and adapter boundaries.
- `capabilities` owns result construction, image validation, path authorization, image policy, and `view_image` execution.
- `engine` owns execution ordering, text/image batch budgets, canonical history insertion, and provider-facing projection selection.
- provider adapters own wire translation only.
- evolution/runtime persistence owns atomic message/checkpoint mutation, user-attachment ownership, and history pruning.
- interfaces expose binary-free events/history plus authenticated attachment/media admission and retrieval contracts.
- the agent owns attachment bytes and executable paths. The client owns draft selection and transient rendering only; it never becomes durable media or filesystem authority.

## Canonical result model

`ToolExecutionResult` schema version 1 contains ordered sealed blocks, `isError`, and an optional closed `ToolResultErrorCode`. Blocks are `ToolTextBlock(text)` or `ToolImageBlock(dataBase64, mimeType, width, height, detail)`.

Every result contains at least one non-empty text block. `displayText` is a deterministic getter derived from text blocks after `ToolOutputGuard`; it is not serialized as a second source of truth. An image block is valid only when base64 decodes, MIME is PNG/JPEG/WebP, dimensions are positive and match validated metadata, and the common image policy has accepted it.

`Message.toolResult` is permitted only for `MessageRole.tool`. New tool messages persist both the typed result and the compatibility `content=displayText`; typed content is authoritative and serialization rejects a divergent projection. Old messages with only `content` remain valid and require no database migration.

User messages may carry ordered typed attachment references independently from text. Their durable/public projection contains opaque identity, safe name, verified MIME/size/hash, kind, and availability only. Agent-local executable paths remain private to the runtime projection; attachment bytes and absolute paths are forbidden in canonical conversation events and client cache JSON.

## Text-tool compatibility

`BaseTool.execute` returns `Future<ToolExecutionResult>`. A text constructor wraps existing outputs without changing their characters. MCP and platform bridges may remain string-returning internally, but their `CallbackTool` boundary normalizes the string before it reaches the coordinator. Exceptions become one text-only error result with an established closed error code; no code infers image/error semantics by stringifying a rich result.

## `view_image` contract

The schema is `view_image(path: string, detail?: low|auto|high|original)`, with `auto` as default. It is local-only, read-only, and restart-replay-safe. It is cataloged when a workspace exists or the session has an admitted attachment scope; it is absent only when neither source scope exists. URL, data URI, multiple paths, OCR, generated images, animated content, and temporary output files are excluded.

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

## User attachment admission

Paste, drag/drop, and File Picker create one ordered draft attachment model. The visible `+` action sits on the left side of the composer beside Permission Mode and opens the platform file picker. Draft items expose validating, uploading, ready, and failed states; Send or Edit Save cannot proceed while any item is not ready.

The central limits are 5 MiB per file regardless of type, four files per message, and 20 MiB aggregate. The client enforces these for immediate feedback, but the agent is authoritative and rechecks decoded byte count, count, aggregate size, safe filename, content/MIME, and SHA-256 before ACK. A clipboard image without a path is materialized as a file. Partial writes use a private temporary artifact followed by atomic promotion and are removed after cancellation, timeout, mismatch, or failure.

For a direct local route, an existing file on the agent device may resolve to its canonical path and receive an attachment-scoped session grant. For a remote route, a client-local path is never meaningful runtime input: bytes must be transferred and admitted into the agent-owned attachment store first. The hosted route advertises a versioned attachment/media capability; incompatible or absent capability fails closed and leaves the draft intact. Internal hosted-service implementation belongs to its private repository contract, not this public design.

Folders are not transferred recursively in v1. A folder reference is valid only when that path already exists on the agent device and ordinary workspace/external-path authorization permits browsing it.

## Model projection for attachments

User attachment admission does not create provider image/file parts. The runner gives the model the user's text followed by a bounded ordered projection containing safe name, kind, and the admitted agent-local path, with guidance to call `view_image`, file read, or directory browsing when needed. Attachment bytes enter a provider request only as the result of an explicit tool call. Request dumps, logs, public events, and client history never contain the private path projection or file bytes.

## Conversation rendering and edit

A sent user message renders attachment images/file cards above its text in original order. Images open an accessible lightbox; generic files use a safe preview when supported or an authenticated download. The public model never exposes agent paths or reusable media credentials.

Edit restores existing attachments as ready references without re-upload, allows add/remove through the same draft pipeline, and keeps the original canonical message unchanged until new admission and replay both succeed. Cancel discards only transient edits. Session/device navigation isolates and clears the transient edit owner according to the existing edit contract.

## View Image timeline media

The canonical tool event is titled `View Image` and carries only opaque `media_id`, safe name, verified MIME, dimensions, and availability. The thumbnail appears below the title, hydrates near the viewport, and opens the full image in the shared lightbox. Local clients fetch through the authenticated Local Gateway; remote clients use the compatible hosted media capability. Access is bound to user, target device, session, media identity, purpose, and expiry. Base64, absolute paths, and public URLs never enter the event.

After pruning or expiry, the row remains stable and renders `Image no longer available`. Hydration is cancellable on disposal or session/device switch and uses bounded transient cache storage.

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

The catalog is source-scope stable for a turn: `view_image` is present whenever a workspace exists or that session has admitted attachments, and absent only when neither scope exists. A text-only route may call it but receives the explicit omission projection. Model-specific vision metadata is not introduced in v1.

## Persistence and recovery

Rich tool-image content is inline JSON in `Message.toolResult`; v1 adds no blob table for tool results. User attachment files are different: they live in an owner-protected agent attachment store and user messages retain typed references. A completed tool result first enters `completed_tool_results_v2` in continuation metadata. The legacy `completed_tool_results` parser remains for text checkpoints during migration.

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

- Tool events, logs, approval payloads, plugin notifications, and history queries use safe text/status/media metadata only.
- User attachment and View Image events never carry bytes, data URI, absolute paths, or reusable media credentials.
- `LLMRequestDumper` recursively replaces image base64/data URIs with MIME/byte-count markers in a deep copy; the live request is unchanged.
- Generic character truncation never scans base64. Image and attachment budgets run before history insertion.
- Errors contain no bytes, data URI, file contents, absolute external paths, or stack traces.

## Verification obligations

- Type validation, JSON v1 round trip, legacy text parsing, and divergent projection rejection.
- Exact compatibility for every existing text tool and callback bridge.
- Workspace/external authorization, symlink/traversal, MIME deception, animated rejection, all numeric boundaries, timeout, and cleanup.
- Exact Responses/Anthropic payloads and text-only adapter fallback for sync/stream paths.
- Sequential/parallel/batch budgets, atomic checkpoint promotion, crash recovery, stale-run isolation, and changed/deleted source file.
- Three-turn and 24-MiB pruning, corrupt payload degradation, request-dump redaction, and binary-free interface projections.
- Composer `+`/picker, paste/drop parity, 5 MiB and 4/20 MiB boundaries, upload interruption, edit restoration, and local/remote capability failure.
- User-message and `View Image` live/history rendering, authenticated hydration, expiry, and cross-user/device/session denial.
- Daemon-backed local and remote runs proving attachment bytes are absent before tool choice and the final answer comes from pixels unavailable in filename/prompt.
