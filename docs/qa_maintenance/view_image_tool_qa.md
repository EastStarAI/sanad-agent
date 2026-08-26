---
title: "View Image Tool QA"
description: "Locked regression matrix for typed results, secure image loading, provider projection, recovery, and pruning."
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
| No workspace | `view_image` absent. |
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

## Daemon-backed proof

Use an isolated daemon and deterministic provider fixture that declares `imageToolResults`. The fixture asks for a checkerboard image whose answer is absent from path and prompt, inspects the next request image block, and returns the visual answer. Repeat with restart after tool completion and delete the source file before recovery. Execute this port-binding test with `--concurrency=1`; unit and codec suites remain parallel.

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
