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

`ToolExecutionResult` schema version 1 contains an immutable ordered block list, `isError`, and an optional closed `ToolResultErrorCode`. Blocks serialize with explicit `text` or `image` discriminators and are represented by `ToolTextBlock(text)` or `ToolImageBlock(dataBase64, mimeType, width, height, detail)`. Detail wire values are `low`, `auto`, `high`, and `original`; error codes use bounded snake-case wire values and are rejected when unknown or attached to a non-error result.

Every result contains at least one non-empty text block. `displayText` is a deterministic getter derived from text blocks after `ToolOutputGuard`; it is not serialized as a second source of truth. An image block is valid only when base64 decodes, MIME is PNG/JPEG/WebP, dimensions are positive and match validated metadata, and the common image policy has accepted it.

`Message.toolResult` is permitted only for `MessageRole.tool`. New tool messages persist both the typed result and the compatibility `content=displayText`; typed content is authoritative and serialization rejects a divergent projection. Old messages with only `content` remain valid and require no database migration.

User messages may carry immutable ordered typed attachment references independently from text, and only user-role messages may own them. Schema v1 closes attachment/media identity, safe basename, normalized MIME, byte size, lowercase SHA-256, image/file kind, Agent-local reference, and available/unavailable status. Durable Agent history retains the local reference for later tools; `UserAttachmentPolicy.publicProjection` removes it for event/history/cache consumers while preserving order and safe metadata. The same policy owner enforces 5 MiB/file, 4 files/message, and 20 MiB aggregate with closed non-echoing error codes. Attachment bytes, base64, open metadata, client-local paths, and absolute Agent paths are forbidden in public projections.

## Text-tool compatibility

`BaseTool.executeResult` returns `Future<ToolExecutionResult>`; `execute` is the legacy text-only compatibility projection. A text constructor wraps existing outputs without changing their characters. MCP and platform bridges may remain string-returning internally, but their `CallbackTool` boundary normalizes the string before it reaches the coordinator. Exceptions become one text-only error result with an established closed error code; no code infers image/error semantics by stringifying a rich result.

## `view_image` contract

The schema is `view_image(path: string, detail?: low|auto|high|original)`, with `auto` as default. It is local-only, read-only, and restart-replay-safe. It is cataloged when a workspace exists or the session has an admitted attachment scope; it is absent only when neither source scope exists. URL, data URI, multiple paths, OCR, generated images, animated content, and temporary output files are excluded.

Authorization order is canonicalize, classify, authorize, then stat/read. An internal target proceeds directly. An external canonical target requires a decision scoped to `view_image` or `full_access`. Caller spelling, extension, or a symlink cannot weaken the classification.

The runtime catalog resolves admitted attachment paths through a daemon-owned session callback rather than generic turn metadata. With a workspace, the tool source is workspace-scoped; without one, exact canonical files from that callback form the only readable scope. An attachment grant neither authorizes siblings nor widens workspace policy. External workspace approval is keyed as `external_workspace_path::view_image::<canonical-target>` and uses the established permission checkpoint owner before file bytes are opened. Success orders a safe dimensions/MIME/detail summary before the image block; failures contain text only and a closed error code.

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

`ImagePolicy` is the single implementation owner for these limits and boundary predicates. `ImageWorker` accepts bytes only, validates format/frame/dimensions before constructing a success, and moves byte ownership across isolates with transferable typed data. One process-wide FIFO semaphore admits at most two workers. Each admitted operation owns a killable isolate; the 15-second timeout kills it immediately and releases the permit without writing source or normalized bytes to disk. Closed failures distinguish unsupported/corrupt input, oversized input/output, processing failure, and timeout without echoing bytes or private paths.

The coordinator applies the image-count and aggregate payload ceilings in tool-call order. A result crossing the remaining batch budget becomes `batch_image_budget_exceeded` with text only.

## User attachment admission

Paste, drag/drop, and File Picker create one ordered draft attachment model. The visible `+` action sits on the left side of the composer beside Permission Mode and opens the platform file picker. Draft items expose validating, uploading, ready, and failed states; Send or Edit Save cannot proceed while any item is not ready.

The central limits are 5 MiB per file regardless of type, four files per message, and 20 MiB aggregate. The client enforces these for immediate feedback, but the agent is authoritative and rechecks decoded byte count, count, aggregate size, safe filename, content/MIME, and SHA-256 before ACK. A clipboard image without a path is materialized as a file. Partial writes use a private temporary artifact followed by atomic promotion and are removed after cancellation, timeout, mismatch, or failure.

For a direct local route, an existing file on the agent device may resolve to its canonical path and receive an attachment-scoped session grant. For a remote route, a client-local path is never meaningful runtime input: bytes must be transferred and admitted into the agent-owned attachment store first. Hosted admission is enabled only by `supports_attachments=true`; optional versioned attachment metadata refines limits but is not an independent admission flag. Every upload/media wire envelope requires `version: "v1"`. Missing/incompatible support or envelope versions fail closed and leave the draft intact. Internal hosted-service implementation belongs to its private repository contract, not this public design.

Folders are not transferred recursively in v1. A folder reference is valid only when that path already exists on the agent device and ordinary workspace/external-path authorization permits browsing it.

### Agent attachment store

`AttachmentStore` uses `<SANAD_STATE_HOME>/attachments` as its fixed isolation root. In-progress uploads live under the private `.partial` child and accept bounded chunks only. Commit recomputes byte count and SHA-256, inspects PNG/JPEG/GIF/WebP/PDF/text magic/content rather than trusting declared MIME, creates an opaque UUID-owned directory, atomically renames `payload` on the same filesystem, and inserts metadata only when both the owning session and message already exist. Unix-like roots/directories/files are enforced as `0700`/`0600`; Windows relies on the protected user state-home boundary.

The `user_attachments` table stores opaque attachment/media IDs, exact session/message ownership, safe name, verified MIME/size/hash/kind, and a generated relative path. Its insert trigger rejects a message from another session. Runtime resolution requires the exact `(session_id, attachment_id)` pair and returns no sibling or workspace authority. Session deletion atomically cascades metadata and then removes owned directories; initialization removes interrupted partials, metadata whose message no longer exists, and promoted directories absent from metadata. All cleanup paths are idempotent, and closed failures contain neither caller filenames nor local paths.

### Hosted binary relay

The composer emits name/size/hash/base64 admission maps without a MIME hint. Hosted upload-start supplies `application/octet-stream` when no hint exists; the Agent still derives the durable MIME/kind from verified content, not the hint. The Client divides uploads into 256 KiB chunks, runs at most four uploads concurrently, and waits for the Agent's terminal accepted ACK before emitting `think` with ordered opaque `attachment_ids`. The Agent independently validates version, declared and actual size/hash, exact chunk count/order, file index/count, and turn-total bounds before committing to `AttachmentStore`. Cancel, disconnect, malformed sequence, mismatch, or rejection removes partial Agent state; no binary fallback through `device_command` or `device_event` exists.

Remote conversation media uses the same closed v1 envelope family in the reverse direction. `ConversationMediaLoaderResolver` selects the local authenticated repository or hosted repository below presentation; widgets receive only the typed cancellable loader. The Agent resolves media against durable exact-session history, revalidates attachment bytes, and streams bounded chunks. The hosted service owns user/device/session/hardware/requester binding, 120-second route expiry, two concurrent media streams, and 4 MiB/s with 8 MiB burst; only the requesting Client receives media frames. Redis/database/public events/logs contain relay metadata only.

Relay delivery depends on the Agent keeping the relay bound to its live cloud socket. The Socket.IO client library caches one `Socket` per host and clears every listener on `dispose()`, and the platform binds the relay only when the current socket differs from the socket it last bound. Disposing the cloud socket for lost Agent authorization therefore also forgets that binding, so the following `initialize()` re-attaches the relay even when the library hands the same cached instance back. Detection is behavioral: a media route created by the hosted service with no Agent `conversation_media_start`/`conversation_media_error` (route alive until Client cancel or expiry) means the relay is detached on the Agent side, while co-located Clients that use the local authenticated repository keep rendering the same media.

## Model projection for attachments

User attachment admission creates canonical typed references, not provider-specific parts. For a supported image model, the request-owned attachment reader revalidates store ownership, jail, availability, size, hash and magic MIME; the actual-mode codec serializes verified user image pixels directly. Wire image-part projection is gated to an exact provider-safe MIME set: `image/png`, `image/jpeg`, `image/webp`, and `image/gif`. Any other image MIME or alias (such as `image/jpg`, `image/heic`, `image/tiff`, or `image/svg+xml`) is treated as a file reference and is never sent as an image part. OpenAI Chat uses user `image_url`, Responses uses `input_image`, Anthropic uses image blocks and native Ollama uses ordered `images` arrays. Typed `view_image` results remain a separate, supported image source with preserved tool pairing. Unsupported or unknown pixel-bearing history halts before lossy HTTP dispatch; no auxiliary model or resend is used. History whose only image inputs use non-provider-safe MIME types contains no pixel projection at all, so it is disclosed as file references instead of halting.

Non-image attachments and non-provider-safe image files are disclosed on the model wire across all adapter families (OpenAI-compatible Chat, Anthropic Messages, OpenAI Codex Responses, and native Ollama) by the shared `UserAttachmentWireDiscloser`. Provider-history preparation keeps these attachments on the user message and no longer emits the former non-image text projection, so exactly one disclosure path exists per message. Each disclosed file becomes one reference line appended to the model-facing text content:

`[<safe name>](file:///<percent-encoded agent-side path>)`

followed once by the fixed English guidance sentence `Use your tools to read this file; it is available on disk.` The safe name is stripped of control runes, Unicode line separators (`U+2028`/`U+2029`), backticks, and square brackets and is bounded to 120 runes, so a hostile or exotic filename cannot break, extend, or inject into the reference line. The destination is a percent-encoded `file://` URI, so spaces and non-ASCII path segments stay inside one unbroken link destination.

The path always points inside the receiving Agent's `AttachmentStore` (`<SANAD_STATE_HOME>/attachments/<id>/payload`). The store honors the admitted store-relative reference only while it stays inside the store jail, and otherwise substitutes the canonical payload path derived from the opaque attachment id; a reference that cannot be jailed at all produces no line and no orphan guidance sentence. Client-side and other foreign absolute references are therefore never echoed onto the wire. Disclosure is metadata-only: it never reads payload bytes, extracts content, or mutates canonical history. Guidance must not recommend image inspection to an unsupported/unknown image route or infer pixels from filenames. The path-only deterministic fixture deliberately chooses `view_image` before receiving pixels; that fixture scenario is not a prohibition on supported direct image input. Request dumps, logs, public events and client history never expose attachment bytes; the model-facing text above is the only place an agent-side store path appears.

## Conversation rendering and edit

Sending captures the originating draft scope and exact submitted attachment IDs before asynchronous session creation. On accepted admission/dispatch, remove only those IDs from that scope, even after the selected session changes; preserve newer or unrelated drafts and retain the originating draft after failure. A sent user message renders attachment images/file cards above its text in original order. Images open an accessible lightbox; generic files use a bounded text preview up to 256 KiB when supported or an authenticated save flow. Loading is cancellable and bounded; unavailable or integrity-failed payloads preserve a stable card. The public model never exposes agent paths or reusable media credentials.

Live and history projection both use `UserAttachmentPolicy.publicProjection`; the Client mapper accepts only the closed safe metadata schema. Local retrieval is authenticated and bound to hardware device, session, and opaque media identity. Relative durable attachment references are resolved and verified through the owning `AttachmentStore`, never against process working directory. Before responding, the Agent locates the exact durable session reference and revalidates size and SHA-256; responses use a generic filename, `private, no-store`, and `nosniff`.

Edit restores existing attachments as ready opaque references without download or re-upload and allows add/remove/retry through a separate transient edit owner. New files are checked against the same 4-file, 5 MiB/file, and 20 MiB aggregate policy and remain transient until replay. The private authenticated replay command sends existing `reference_id` values plus validated new bytes; no bytes enter public events/history/cache/logs.

The Agent clones every retained existing payload internally into distinct replacement-admission ownership before dispatch. Partial, stale, or rejected staging deletes only unclaimed replacement payloads. The original canonical message and its payloads remain unchanged until daemon acceptance. Cancel or session/device navigation discards only transient edits; replay failure keeps the editor and draft available for retry, while acceptance clears them and dispatches one replacement turn.

## View Image timeline media

The canonical tool event is titled `View Image` and carries only opaque `media_id`, safe name, verified MIME, dimensions, and availability. `view_image` and a containing tool group default to expanded unless the user explicitly closes them. The thumbnail appears below the title, hydrates near the viewport, and opens the full image in the shared lightbox. When execution fails (e.g. unsupported model route, unknown capability, missing file, or permission denial), no media is emitted; the client preserves the target file basename in the header (e.g. `View Image: sample.png`), displays an error indicator, and renders the actionable failure explanation in the card body with error styling without relying on the model completion. Local clients fetch through the authenticated Local Gateway; remote clients use the compatible hosted media capability. Access is bound to user, target device, session, media identity, purpose, and expiry. Base64, absolute paths, and public URLs never enter the event.

After pruning or expiry, the row remains stable and renders `Image unavailable`. Hydration is cancellable on disposal or session/device switch and uses bounded transient cache storage.

### `system_screenshot` media parity

`system_screenshot` yields a `ToolImageBlock` alongside its existing human-readable summary: the raw capture is written to `Downloads/AgentScreenshots` and summarized with that path whenever the save succeeds, independent of model attachment, while the attachment is produced only through the shared bounded image policy worker (`package:image` decoding inside a killable isolate, allowed formats `image/jpeg`, `image/png`, `image/webp`, `detail: auto` normalization, 20 MiB input / 4 MiB base64 / pixel and edge limits). The capture is attached only when the frozen turn route capability is `supported`; on `unsupported` or `unknown` routes the result stays text-only with an explicit note, so a pixel-bearing history entry can never make later requests fail closed. Unsupported, corrupt, oversized, animated, or timed-out captures degrade to the same text-only result instead of failing the tool or starving the capture save. `ViewImageMediaMetadata.project` projects `system_screenshot` identically to `view_image`, deriving `media_id = SHA-256(session_id NUL tool_call_id NUL image_block_index)` and preserving availability, dimensions, MIME, and safe name; a text-only capture publishes no media descriptor. Wire projection remains generic through `ToolResultWireCodec`, delivering detached image context to supported vision models. The Flutter client renders `system_screenshot` using the same media tile, thumbnail preview, and zoomable lightbox as `view_image`, expanding by default and preserving running and error indicators; a completed capture without media metadata keeps the regular tool presentation with its summary and saved path instead of an unavailable-image surface.

For the local path, the Agent derives `media_id = SHA-256(session_id NUL tool_call_id NUL image_block_index)` and resolves it back against the session's durable typed tool result; it does not write a second media copy. `GET /media/view-image/<media_id>` is authenticated by the Local Gateway header and admits only the exact hardware device/session/media scope. It supports one valid byte range and responds with verified content type/length, `Accept-Ranges: bytes`, `Cache-Control: private, no-store`, `X-Content-Type-Options: nosniff`, and a safe inline filename. Invalid scope, methods, query, body, or ranges return no image bytes.

`ViewImageMediaMetadata` in `core/models` derives the shared byte-free descriptor. Legacy live descriptor maps are revalidated against the closed safe schema before publication; retrieval projections inherit the same byte-free serialization rather than duplicating it. Engine completion publishes it only after final guarded tool-result persistence, preventing a live fetch from racing durable media availability; normal/resumed interface callbacks retain it without forwarding rich blocks. The Client mapper preserves the identical metadata map for live and hydrated rows, and maps typed failure text (`displayText` from `toolResult.blocks` or `output`) and error status into `CanonicalEvent`. A typed repository validator rejects malformed identity, unsafe names, unsupported MIME, non-positive dimensions, and unknown availability before retrieval. Local hydration uses the active hardware identity and owner-only credential header, enforces a 12 MiB response ceiling, coalesces in-flight loads, cancels transport when the last listener leaves, and retains at most 12 entries/24 MiB in an in-memory LRU. The timeline renders loading, unavailable, thumbnail, decode-failure, typed execution failure, and accessible zoomable lightbox states without owning HTTP or credential access.

### Responsive View Image Gallery

Consecutive media-bearing results (`view_image` and media-bearing `system_screenshot`) inside an expanded tool group render as a single responsive gallery (`ResponsiveMediaGallery` with `LayoutBuilder` + `Wrap`) instead of one image per row.
The column count dynamically adapts to available width using the pinned formula:
`columns = ((availableWidth + spacing) / (minItem + spacing)).floor().clamp(1, 4)`
`itemWidth = (availableWidth - spacing * (columns - 1)) / columns`
where `minItem = 160` and `spacing = 8`.
Each tile independently hydrates its media card via `ViewImageToolCard`, retaining 120-280px height constraints, aspect-ratio containment, unavailable/error/loading states, and tap-to-lightbox behavior. Isolated single media events and non-media tools preserve their individual `EventTile` presentation.
Gallery membership and the single-row media branch share one rule (`rendersAsMediaCard` on the client `ViewImageMediaEvent` extension): a media-bearing tool row that is running, failed, `view_image`, or carries media metadata. A completed text-only `system_screenshot` therefore keeps its regular summary row and splits a run. A card reloads only when its media identity, availability, session, status, or error state changes, never because a rebuilt parent passes a new loader instance.

## Provider capability and translation

`LLMAdapter` exposes one closed media capability: `textOnly` or `imageToolResults`. Wrappers delegate the exact inner value. Capability is protocol-owned in v1, not inferred from model names or learned from a failed request.

| Adapter/protocol | v1 capability | Projection |
|---|---|---|
| Codex Responses | `imageToolResults` | `function_call_output.output` with ordered `input_text`/`input_image` |
| Anthropic | `imageToolResults` | nested text/image blocks inside `tool_result` |
| deterministic E2E fixture | explicit test value | captures the same canonical blocks |
| OpenAI-compatible Chat | Native tool capability `textOnly`; separate model-owned image-input evidence | Scalar tool results; verified images in synthetic user context after a complete paired batch; unknown/unsupported pixel-bearing dispatch fails closed |
| Ollama | Native `/api/chat` with `images` array | Verified base64 images on user messages; detached synthetic user message with `images` array after a complete paired tool batch; preflight fails closed on unsupported or unknown model vision capability |
| Custom route | Actual configured protocol plus exact model evidence | Same verified projection as that protocol; custom endpoint identity is not a vision veto |
| Missing/unknown/unsupported image evidence | No pixel-bearing dispatch | Actionable local rejection; preserve source/history without lossy fallback |

Responses preserves `call_id`; `original` maps to wire `detail=high` while retaining original bytes. Its shared sync/stream builder emits a string for legacy text-only results and a non-empty ordered content array for rich results; structured output is validated locally before HTTP. Anthropic preserves `tool_use_id`, nests ordered canonical blocks under `tool_result.content`, does not serialize detail, and emits `is_error: true` only for typed failures. Its existing consecutive-result merge and alternation healing operate on the enclosing tool-result blocks without flattening nested content or changing pairing. Standard Chat tool messages never receive `image_url`, because the standard tool-message contract is text-only. `ToolResultWireCodec.chatMessages` instead emits verified images in an outbound-only user message after a fully paired contiguous tool-result batch. Native Ollama requests similarly avoid unsupported Chat parts; `ToolResultWireCodec.ollamaMessages` attaches verified base64 images directly to user messages and projects typed tool images into a detached synthetic user message following the completed tool batch.

For both OpenAI-compatible Chat and Ollama adapters, native transport capability does not bypass model image-input capability checks: `RouteCapabilityResolver` resolves model-only vision evidence (including `ollama_capabilities` from `/api/show` discovery) before dispatch. When pixel-bearing history is presented to an unknown or unsupported model, preflight halts closed with `LocalImageCapabilityException` before issuing any HTTP request, preventing lossy pixel drops. The existing omission marker describes legacy fallback when explicit omission degradation is permitted, not silent pixel omission.

Legacy explicit text-only compatibility projection retains the suffix `[Image omitted: active provider does not accept image tool results.]` once when an image block is omitted. This compatibility behavior does not authorize lossy live dispatch, canonical history mutation, transparent retry or failover.

The tool catalog is source-scope stable for a turn: `view_image` is present whenever a workspace exists or that session has admitted attachments, and absent only when neither scope exists. A new invocation on an unsupported or unresolved image route receives a distinct typed text-only failure before image processing. Supported routes receive validated pixels. Model-specific vision comes from the immutable admitted model capability; native discovered capability lists must be structurally valid before they become evidence.

## Persistence and recovery

Rich tool-image content is inline JSON in `Message.toolResult`; v1 adds no blob table for tool results. User attachment files are different: they live in an owner-protected agent attachment store and user messages retain typed references. An owner-bound completed tool result first enters `completed_tool_results_v2` in continuation metadata under a schema-v2 envelope carrying session, work-item, run, generation, and tool-call identity. The legacy `completed_tool_results` parser remains for text and non-owned checkpoints during migration.

`SessionExecutionStateCoordinator` owns the transaction that validates exact typed-result equality, appends the canonical tool message, bumps the history revision, removes its suspended checkpoint, and removes its rich checkpoint copy. A retry is idempotent only when that same typed result is already durable. `completed_tool_outputs` contains only bounded redacted text/status metadata and never rich bytes/base64. Each typed completion is saved immediately and the aggregate batch guard is saved again before promotion, so the checkpoint and canonical message cannot diverge. After a completed result is durable, restart/retry uses that inline snapshot and never reopens a changed or deleted path. A structurally malformed persisted result becomes `[Tool result unavailable: stored rich result is corrupt.]` and is not re-executed; an owner mismatch fails closed.

Daemon-backed QA interrupts the provider request only after it has received the completed rich result, then uses the controlled forced-restart contract and explicit runtime retry. The resumed provider request consumes the preserved `after_tool_result` snapshot after source deletion. Public `view_image` lifecycle logs omit arguments, while tool events and history-query tool inputs replace the local path with `[local image path redacted]`; approval remains the sole explicit path-review surface.

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
- `LLMRequestDumper` recursively replaces canonical, Anthropic and Responses typed-image payloads, plus native Ollama `images` entries regardless of string length, with `image_redacted` MIME/decoded-byte metadata in a deep copy. Data URIs become `[image payload redacted: mime=<mime>, bytes=<count>]`, raw base64 becomes the equivalent binary/unknown-MIME marker, no payload sample survives, and the live request is unchanged.
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
- Daemon-backed path-only local/remote fixtures prove no pixels before the explicit tool choice and answers derived from pixels unavailable in filename/prompt. Supported direct-image production paths separately prove verified pixels on first dispatch; unsupported/unknown routes prove zero lossy dispatch.
