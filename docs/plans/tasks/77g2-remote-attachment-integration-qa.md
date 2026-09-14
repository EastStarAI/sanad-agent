---
title: "Task 77g2: Remote Attachment Integration QA"
status: "pending"
priority: "high"
depends_on: "77g1, compatible hosted attachment/media capability"
current_gate: "R0"
remaining_estimate: "100%"
evidence_id: "77e"
---

# Task 77g2: إثبات المرفقات البعيدة End-to-End

## Goal

إثبات تكافؤ رحلة المرفق وView Image عندما يكون Flutter Client والوكيل على جهازين مختلفين عبر hosted relay متوافقة، دون إدخال تفاصيل تنفيذ الخدمة المغلقة في هذا المستودع.

## Locked scope

- الاختبار يتعامل فقط مع public capability/versioned contract.
- client-local path لا يصل إلى daemon history أو model request.
- transfer/admission يكتمل قبل قبول turn؛ interruption قابل لإعادة المحاولة.
- media fetch يصل إلى العميل الطالب فقط وفق user/device/session binding.
- incompatible/missing capability تفشل مغلقًا وتحفظ draft.
- remote recursive-folder upload خارج النطاق.

## Gates

### R0 — Cross-repository readiness
- [ ] حل packet `77e` وتسجيل fingerprint.
- [ ] توثيق إصدار capability المتوافق وإثبات نجاح اختبارات المستودع المغلق دون نسخ تفاصيله هنا.

### G1 — Remote happy path
- [ ] نقل ملف حتى 5 MiB واعتماده ثم إرسال user turn.
- [ ] إثبات model path الموجود على جهاز الوكيل واختيار `view_image`.
- [ ] إثبات user bubble وView Image thumbnail/Lightbox على العميل البعيد.

### G2 — Security and failures
- [ ] اختبار wrong user/device/session وexpired media identity.
- [ ] اختبار disconnect/retry/idempotency وcleanup.
- [ ] اختبار 5 MiB+1 و4/20 MiB وcapability mismatch.

### G3 — Closure
- [ ] تشغيل E2E المتسلسل والاختبارات العامة bounded output.
- [ ] تحديث QA والخطة ونسبة المتبقي.

## Acceptance criteria

- [ ] hosted path لا يضع bytes في `device_command` أو conversation events.
- [ ] لا تقبل الرسالة قبل agent admission ACK.
- [ ] غير المخول لا يحصل على media bytes.
- [ ] المحلية والبعيدة تنتجان timeline/model semantics متطابقة.

## Definition of Done

- [ ] analyzers وfocused suites ناجحة.
- [ ] remote daemon-backed E2E متسلسل ناجح.
- [ ] تحقق Flutter مرئي على remote route موثق.
- [ ] لا توجد تفاصيل داخلية خاصة بالخدمة المغلقة في diff العام.
- [ ] `graphify update .` ناجح.
- [ ] تحديث gate ونسبة المتبقي وإغلاق Plan 77 عند اكتمال الأدلة.
