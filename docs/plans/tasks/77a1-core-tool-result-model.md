---
title: "Task 77a1: Core Tool Result Model"
status: "pending"
current_gate: "R0"
depends_on: "Approved Plan 77"
file_budget: 10
evidence_id: "77a"
evidence_fingerprint: "sha256:477c6a964da28b0914da3cb0f52881421561ccd9f8afd859fc6833380353bc43"
design_contract: "docs/technical/multimodal_tool_results_and_view_image.md"
---

# Task 77a1: نموذج نتيجة الأداة في Core

## Goal

إضافة النموذج serialized المقفل ودمجه اختياريًا في `Message` دون تغيير حد تنفيذ الأدوات الحالي بعد.

## Locked scope

- الأنواع في `agent/lib/core/models/`، schema version 1، blocks sealed، وprojection مشتقة.
- `Message.toolResult` لرسالة tool فقط؛ typed payload authoritative وlegacy content يبقى صالحًا.
- لا `dynamic details` ولا provider/workspace logic.

## Gates

### R0 — Evidence
- [ ] resolver يعيد fingerprint المثبت ويقرأ packet 77a.

### A1 — Types
- [ ] إضافة result/block/detail/error enums والتحقق من MIME/base64/dimensions/version.
- [ ] منع نتيجة بلا text block ومنع `content` المتعارضة.

### A2 — Message JSON
- [ ] إضافة `toolResult` وcopyWith/generated JSON.
- [ ] إثبات legacy content-only parsing وtyped round trip وترتيب blocks.

### A3 — Contract and verification
- [ ] تحديث `agent/lib/core/AGENTS.md` لعقد الرسالة الغنية.
- [ ] تشغيل generator ثم analyzer والاختبارات المركزة.

## Acceptance criteria

- [ ] malformed typed payload تفشل قبل persistence.
- [ ] legacy Message تعود دون تغيير وظيفي.
- [ ] `displayText` لا تخزن كحقيقة ثانية.

## Definition of Done

- [ ] `cd agent && fvm dart run build_runner build --delete-conflicting-outputs`
- [ ] `cd agent && set -o pipefail; fvm dart analyze 2>&1 | tail -5`
- [ ] `cd agent && set -o pipefail; fvm dart test test/core/models/tool_execution_result_test.dart test/core/models/message_test.dart 2>&1 | tail -5`
- [ ] تحديث الخطة وسجل gate وreference parity.

## Expected files

`agent/lib/core/models/tool_execution_result.dart`, `message.dart`, generated JSON, focused tests, `agent/lib/core/AGENTS.md`, والوثائق المالكة.

