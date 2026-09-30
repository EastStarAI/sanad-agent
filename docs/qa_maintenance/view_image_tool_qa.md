---
title: "View Image Tool QA"
description: "Regression matrix for typed results, user attachments, View Image conversation media, local/remote security, recovery, and pruning."
---

# View Image Tool QA

## Result and compatibility matrix

| Scenario | Required result |
|---|---|
| Text-only result | Exact legacy text survives constructor, guard, message JSON, checkpoint, event, and provider request. |
| Mixed text/image result | Order, MIME, dimensions, detail, error state, and tool-call identity survive JSON v1 round trip. |
| Legacy message/checkpoint | Content-only history remains readable; no table migration or invented image block. |
| Divergent `content`/typed projection | Rejected before persistence. |
| Invalid base64/MIME/dimensions/version | Controlled local error or persisted-data marker; never sent unchecked. |

## Catalog, path, and input matrix

| Scenario | Required result |
|---|---|
| No workspace and no admitted attachment | `view_image` absent. |
| No workspace with admitted image attachment | Tool present and restricted to the session attachment grant. |
| Valid workspace | Tool present with `path` and the four-value `detail` enum. |
| Internal relative path | Resolves from workspace without approval. |
| External path/default mode | Suspends before stat/read and requires canonical `view_image` approval. |
| External path/full access | Executes without prompt while preserving canonical classification. |
| Traversal or symlink escape | Classified by final canonical target and cannot bypass approval. |
| PNG/JPEG/WebP with misleading extension | Magic MIME controls behavior. |
| Empty/corrupt/text/animated/multi-frame | Typed terminal failure with no image block. |

## Locked boundary matrix

Test boundary-1, boundary, and boundary+1 for each numeric limit.

| Policy | Value |
|---|---:|
| file input | 20 MiB |
| decoded pixels | 40,000,000 |
| hard longest edge | 7,900 px |
| base64 per image | 4 MiB |
| images per batch | 4 |
| base64 per batch | 12 MiB |
| worker concurrency | 2 |
| worker timeout | 15 s |

Detail assertions: `low=768`, `auto=2048`, `high=4096`, and `original` preserves verified source bytes/MIME/dimensions or fails. No mode enlarges. Opaque resized images use JPEG quality 85; alpha images use PNG compression 6. No temp file remains after success, error, or timeout.

## Provider matrix

| Adapter | Required request behavior |
|---|---|
| Codex Responses | Ordered `input_text`/`input_image` inside `function_call_output.output`, original `call_id`; `original` maps to wire `high`. |
| Anthropic | Ordered text/image blocks inside the matching `tool_result`, original `tool_use_id`, valid alternation/merge. |
| OpenAI-compatible Chat | Text projection plus one omission marker; no `image_url` or base64. |
| Ollama/custom/missing | Same text-only projection; no retry/failover or canonical-history mutation. |
| Rich-to-text failover | Destination request degrades locally; source history remains rich and unchanged. |

Both sync and stream paths use the same builder and pass identical assertions.

## Recovery, projection, and pruning

| Scenario | Required result |
|---|---|
| Crash after tool completion before history append | Resume promotes the persisted result exactly once. |
| Crash after atomic promotion | Tool message exists and rich checkpoint copy does not. |
| Source file changes/deletes | Resume uses stored bytes and never reopens/re-executes the completed call. |
| Corrupt persisted image | Deterministic unavailable marker; no provider bytes and no replay. |
| Current/incomplete loop | Image cannot be pruned. |
| Latest three completed assistant turns | Images remain unless 24-MiB retained cap requires oldest-first pruning. |
| Older/over-budget history | Image becomes the exact processed marker once; text/order/identity remain. |
| Events/logs/plugins/history query | Bounded text/status only. |
| Request dump | Deep-copy marker contains safe MIME/size only; live payload still contains the valid image. |

## User attachment admission matrix

| Scenario | Required result |
|---|---|
| `+` beside Permission Mode | Opens File Picker once and preserves composer focus/text. |
| Paste image / drag file / picker file | Enters the same ordered draft attachment pipeline. |
| File at 5 MiB | Accepted after client and agent validation. |
| File at 5 MiB + 1 byte | Rejected before user-turn acceptance regardless of type. |
| Fifth file / aggregate above 20 MiB | Rejected with draft and prior ready attachments preserved. |
| Clipboard image without path | Materialized in the agent-owned store before turn acceptance. |
| Remote client-local path | Never enters daemon history or model projection; bytes stage first. |
| Incompatible hosted capability | Fails closed with draft retained and no command-embedded bytes. |
| Interrupted/hash-mismatch transfer | Retryable failure; no canonical message or durable partial file. |
| Folder on remote client only | Not recursively uploaded in v1. |

## Conversation and edit matrix

| Scenario | Required result |
|---|---|
| Sent user message | Ordered image thumbnails/file cards appear above text in live and history views. |
| Image activation | Opens accessible Lightbox without exposing path or reusable credential. |
| Enter Edit | Existing attachments appear ready immediately and are not uploaded again. |
| Add/remove then Cancel | Original canonical bubble and attachment ownership remain unchanged. |
| Save with pending/failed new file | Save disabled or controlled failure; original bubble remains. |
| Save & Retry success | New attachment set becomes canonical exactly once. |
| Device/session switch | Transient attachment/edit state cannot bleed into another owner. |

## View Image timeline media matrix

| Scenario | Required result |
|---|---|
| Live/history tool result | Title is `View Image`; thumbnail appears directly below it. |
| Near/far viewport | Hydration starts only near viewport and cancels on disposal/switch. |
| Local route | Authenticated Local Gateway returns only the bound media. |
| Remote route | Compatible hosted capability returns media only to the authorized requester. |
| Wrong user/device/session or expired identity | No bytes returned. |
| Pruned/expired media | Stable row shows `Image no longer available`. |
| Event/cache JSON | Contains metadata and opaque `media_id`; no base64, private path, or public URL. |

## Daemon-backed proof

Use an isolated daemon and deterministic provider fixture that declares `imageToolResults`. First admit an attachment and prove the initial provider request contains user text plus the agent-local path projection but no attachment bytes. The fixture then asks for `view_image`, inspects the next request image block, and returns an answer available only in the pixels. Repeat locally and through the compatible remote contract, including restart after tool completion, Edit without re-upload, interrupted transfer, and source deletion before recovery. Execute port-binding tests with `--concurrency=1`; unit, widget, and codec suites remain parallel.

## Security checklist

- [ ] Authorization precedes every file-byte read.
- [ ] Canonical target owns approval scope.
- [ ] No remote or data-URI input path exists.
- [ ] No binary enters logs, events, approvals, exceptions, plugin payloads, or history queries.
- [ ] Declared extension cannot override magic MIME.
- [ ] Batch and per-image budgets are deterministic in tool-call order.
- [ ] Worker timeout terminates isolated processing and leaves no artifact.
- [ ] Stale run cannot append a result to a newer owner.
- [ ] Text fallback cannot start a provider retry loop.
- [ ] User attachment bytes never enter the provider request before an explicit tool call.
- [ ] Client-local remote paths never become agent/model paths.
- [ ] Attachment and media access is isolated by user, device, and session.
- [ ] Partial transfers, expired media, and session deletion leave no unauthorized durable artifact.
