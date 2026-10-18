---
title: "Task 77c1: Rich Provider Codecs"
status: "complete"
current_gate: "complete"
remaining_estimate: "0%"
depends_on: "77a5"
file_budget: 10
evidence_id: "77c"
evidence_fingerprint: "sha256:2af004c77e76f850df9ab9b0abe23409cdcf470ecd3831c08cfc62c66823f85c"
---

# Task 77c1: Codecs الصورية الرسمية

## Goal

ترجمة canonical tool result إلى Codex Responses وAnthropic فقط مع هوية وترتيب صحيحين في sync/stream.

## Locked scope

- Responses: `function_call_output.output` array و`call_id`; original wire detail=`high`.
- Anthropic: nested content في `tool_result` و`tool_use_id`؛ لا detail.
- adapters لا تقرأ path ولا تعالج/تصغر bytes.

## Gates

### R0 — Evidence
- [x] حل packet 77c وقراءة mandatory codec tests.

### C1 — Responses
- [x] builder مشتركة للـsync/stream تنتج text/image items مرتبة.
- [x] malformed block تفشل قبل HTTP request.

### C2 — Anthropic
- [x] nested blocks والmerge/alternation/healing تحافظ على pairing.
- [x] `isError` يسقط إلى الحقل الرسمي.

### C3 — Verification
- [x] exact request captures للنص والصورة والمختلط والهوية.

## Acceptance criteria

- [x] كلا البروتوكولين يرى pixels ولا تتغير canonical Message.
- [x] text-only messages تحتفظ بالwire الحالية.

## Definition of Done

- [x] `cd agent && set -o pipefail; fvm dart analyze 2>&1 | tail -5`
- [x] `cd agent && set -o pipefail; fvm dart test test/engine/adapters/codex_responses_adapter_test.dart test/engine/adapters_test.dart 2>&1 | tail -5`
- [x] تحديث adapter contract والخطة وسجل parity.

## Progress log

### 2026-09-14 — R0 complete

- Status transition: `pending/Waiting` → `in_progress/C1`.
- Resolver: packet `77c` returned `ready`; corrected the stale tracked fingerprint to resolver authority `sha256:2af004c77e76f850df9ab9b0abe23409cdcf470ecd3831c08cfc62c66823f85c`.
- Mandatory codec implementations/tests, source revisions, and MIT licenses were inspected and recorded in the ignored run record.
- Adopted: protocol-specific mapping, exact identity/order, local malformed-payload rejection, and no canonical history mutation.
- Rejected: universal wire shapes, adapter path/image processing, and provider errors as validation.
- Remaining estimate: `75%`.
- Next gate: `C1 — Responses`.

### 2026-09-14 — C1 complete

- Added one shared, provider-neutral structured-result validator with a Responses mapper used by the common sync/stream request builder.
- Responses rich outputs preserve canonical block order and exact `call_id`, emit official `input_text`/`input_image` items, and map canonical `original` detail to wire `high`.
- Invalid structured results are rejected locally by canonical constructors and the Responses preflight before any HTTP request; adapters never read paths or transform bytes.
- Exact sync/stream request capture passed; focused analyzer and adapter suite passed (`61` tests).
- Remaining estimate: `50%`.
- Next gate: `C2 — Anthropic`.

### 2026-09-14 — C2 complete

- Anthropic tool results now use official nested text/image blocks while preserving exact `tool_use_id`; images use base64 `source` objects and omit unsupported detail.
- The existing alternation/healing pass still merges consecutive tool results and strips orphan tool calls without changing rich block order or pairing.
- Typed failures emit official `is_error: true`; successful and legacy text-only results do not gain a false field.
- Exact sync/stream captures and existing merge/healing coverage passed in the focused `61`-test suite.
- Remaining estimate: `25%`.
- Next gate: `C3 — Verification`.

### 2026-09-14 — C3 complete / task complete

- Exact request captures cover legacy text, image-bearing mixed results, canonical order, exact tool identity, Responses detail mapping, Anthropic nested sources, and typed error mapping on sync and stream paths.
- Canonical typed blocks remain unchanged after both protocol projections; adapters only build detached wire maps.
- Final focused analyzer passed with no issues; the required adapter suite passed all `61` tests.
- `graphify update .` completed (`23,656` nodes, `32,536` edges, `843` communities); the known zero-node data-file warning was non-blocking.
- Adapter contract, owning technical design, plan, and post-implementation reference parity record were updated. Tracked task scope is `9/10` paths.
- Remaining estimate: `0%`.
- Next task: `77c2 — Adapter Capability and Fallback`, gate `R0`.
