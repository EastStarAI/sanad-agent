---
title: "Task 77g1: Local Attachment Integration QA"
status: "pending"
priority: "high"
depends_on: "77f2"
current_gate: "R0"
remaining_estimate: "100%"
evidence_id: "77e"
---

# Task 77g1: إثبات المرفقات المحلية End-to-End

## Goal

إثبات رحلة paste/picker/drop إلى agent staging ثم model path/tool choice ثم user bubble وView Image وEdit عبر Local Gateway حقيقي ومعزول.

## Locked scope

- E2E daemon يستخدم SANAD_STATE_HOME مؤقتًا وprovider fixture حتميًا.
- لا يستخدم provider المستخدم أو database/runtime الحية.
- fixture يثبت أن bytes لا تصل للنموذج قبل tool call، ثم يختار `view_image` ويجيب من pixels.
- يغطي 5 MiB boundaries والحدود الإجمالية، restart، edit، cleanup، وmedia expiry.
- الاختبار الذي يربط ports يعمل `--concurrency=1` فقط.

## Gates

### R0 — Scenario and fixture
- [ ] حل packet `77e` وتسجيل fingerprint.
- [ ] بناء fixtures صغيرة لا تكشف بيانات حقيقية.

### G1 — Happy paths
- [ ] إثبات paste image وFile Picker وdrag/drop file.
- [ ] إثبات user bubble وView Image thumbnail/Lightbox.
- [ ] إثبات model path projection ثم tool choice.

### G2 — Failure/recovery
- [ ] boundary tests لـ5 MiB و4/20 MiB.
- [ ] interrupted admission يبقي draft وينظف partial.
- [ ] restart/history/edit existing attachment دون re-upload.
- [ ] session deletion وexpiry/unavailable behavior.

### G3 — Closure
- [ ] تشغيل analyzer/focused suites/E2E bounded output.
- [ ] تحديث QA وسجل الخطة ونسبة المتبقي.

## Acceptance criteria

- [ ] لا توجد provider bytes قبل `view_image` call.
- [ ] الرسالة لا تظهر sent قبل attachment ACK.
- [ ] live/history/edit تعرض metadata والصورة نفسها دون private path.
- [ ] كل failure يترك state قابلًا للفهم ولا يترك partial file.

## Definition of Done

- [ ] Agent/Client analyzers ناجحان.
- [ ] focused suites ناجحة.
- [ ] daemon-backed E2E المتسلسل ناجح.
- [ ] تحقق Flutter مرئي ظاهر موثق.
- [ ] `graphify update .` ناجح.
- [ ] تحديث gate ونسبة المتبقي.
