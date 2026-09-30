---
title: "Task 77c1: Rich Provider Codecs"
status: "pending"
current_gate: "Waiting"
depends_on: "77a5"
file_budget: 10
evidence_id: "77c"
evidence_fingerprint: "sha256:2af004c77e76f850c34646defccb7fa1e87a55791873bc7337d05502b564761ad"
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
- [ ] حل packet 77c وقراءة mandatory codec tests.

### C1 — Responses
- [ ] builder مشتركة للـsync/stream تنتج text/image items مرتبة.
- [ ] malformed block تفشل قبل HTTP request.

### C2 — Anthropic
- [ ] nested blocks والmerge/alternation/healing تحافظ على pairing.
- [ ] `isError` يسقط إلى الحقل الرسمي.

### C3 — Verification
- [ ] exact request captures للنص والصورة والمختلط والهوية.

## Acceptance criteria

- [ ] كلا البروتوكولين يرى pixels ولا تتغير canonical Message.
- [ ] text-only messages تحتفظ بالwire الحالية.

## Definition of Done

- [ ] `cd agent && set -o pipefail; fvm dart analyze 2>&1 | tail -5`
- [ ] `cd agent && set -o pipefail; fvm dart test test/engine/adapters/codex_responses_adapter_test.dart test/engine/adapters_test.dart 2>&1 | tail -5`
- [ ] تحديث adapter contract والخطة وسجل parity.
