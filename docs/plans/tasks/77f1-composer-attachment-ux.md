---
title: "Task 77f1: Composer Attachment UX"
status: "pending"
priority: "high"
depends_on: "77e3"
current_gate: "R0"
remaining_estimate: "100%"
evidence_id: "77e"
---

# Task 77f1: تجربة مرفقات Composer

## Goal

إضافة pipeline موحدة للصق والسحب وFile Picker مع زر `+` في يسار الـcomposer بجوار Permission Mode، وعرض attachment rail قابلة للإزالة وإعادة المحاولة.

## Locked scope

- زر `+` يقع على يسار Permission Mode selector ويفتح platform File Picker.
- paste image، drag/drop، والpicker تستخدم draft attachment controller واحدة.
- image tile تعرض thumbnail/name/size/status/remove؛ generic file card تعرض icon/name/size/status/remove.
- الحالات `validating|uploading|ready|failed`؛ Send يتعطل حتى ready.
- رفض فوري فوق 5 MiB أو فوق 4 ملفات/20 MiB، مع واجهة إنجليزية فقط.
- remote capability غير متاحة تعطل الإرفاق برسالة واضحة ولا تستخدم command fallback.

## Gates

### R0 — UX grounding
- [ ] حل packet `77e` وتسجيل fingerprint.
- [ ] مراجعة composer وPermission Mode وdraft ownership contracts.

### G1 — Entry points
- [ ] إضافة زر `+` بالموقع والقابلية للوصول المطلوبة.
- [ ] توحيد picker/paste/drop في controller/repository flow واحدة.
- [ ] الحفاظ على keyboard focus والنص بعد كل إضافة/إزالة.

### G2 — Rail and state
- [ ] إضافة responsive attachment rail والصور المصغرة/file cards.
- [ ] عرض progress/failure/retry/remove دون optimistic sent row.
- [ ] حفظ draft attachment state بعزل device/session.

### G3 — Tests and visual proof
- [ ] widget tests للموقع والنقر والpicker/paste/drop والحدود.
- [ ] responsive/accessibility tests وgolden عند ملاءمة البنية الحالية.
- [ ] تحقق مرئي في تطبيق Flutter ظاهر قبل التسليم.

## Acceptance criteria

- [ ] الضغط على `+` بجوار Permission Mode يفتح File Picker مرة واحدة.
- [ ] المداخل الثلاثة تنتج نفس rail ونفس validation.
- [ ] ملف 5 MiB يقبل و5 MiB+1 يرفض مع بقاء النص.
- [ ] فشل remote upload يبقي attachment والنص قابلين لـRetry/Remove.

## Definition of Done

- [ ] `fvm flutter analyze` ناجح.
- [ ] focused widget/state tests ناجحة.
- [ ] تحقق مرئي محلي موثق.
- [ ] product/design/QA docs محدثة.
- [ ] `graphify update .` ناجح.
- [ ] تحديث gate ونسبة المتبقي.
