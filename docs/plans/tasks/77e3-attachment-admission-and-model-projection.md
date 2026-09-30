---
title: "Task 77e3: Attachment Admission and Model Projection"
status: "pending"
priority: "high"
depends_on: "77e2"
current_gate: "R0"
remaining_estimate: "100%"
evidence_id: "77e"
---

# Task 77e3: قبول المرفقات وإسقاطها للنموذج

## Goal

تمديد canonical conversation command لقبول مراجع المرفقات المعتمدة، انتظار staging ACK قبل قبول turn، وإعطاء النموذج نص المستخدم ومسارات الوكيل فقط دون direct attachment bytes.

## Locked scope

- local/cloud routes تستخدم command contract واحدة بعد اكتمال admission.
- remote client-local path يرفض ولا يترجم إلى agent path.
- model projection مرتبة ومحدودة: safe name، kind، agent-local path، وإرشاد استخدام الأداة المناسبة.
- لا تنشأ provider image/file parts تلقائيًا من user attachments.
- hosted transport capability/version عامة؛ تفاصيل تنفيذ الخدمة المغلقة لا توثق هنا.
- غياب capability عن remote route يفشل مغلقًا ويحافظ على draft.

## Gates

### R0 — Protocol alignment
- [ ] حل packet `77e` وتسجيل fingerprint.
- [ ] تثبيت typed admission/request/ACK/error contract للمسارين.

### G1 — Runtime admission
- [ ] التحقق من session/device/attachment ownership قبل قبول user turn.
- [ ] جعل acceptance ذرية مع attachment references والرسالة.
- [ ] ضمان idempotency عند ACK مفقودة أو retry.

### G2 — Prompt projection
- [ ] بناء projection نصية حتمية بعد user text وبترتيب المرفقات.
- [ ] منع bytes/data URI/client path من كل provider adapter request.
- [ ] إبقاء اختيار `view_image`/read/list للنموذج.

### G3 — Capability and recovery
- [ ] نشر ودعم attachment/media capability versioned.
- [ ] استعادة pending/failed admission كdraft قابل للمحاولة دون optimistic message كاذبة.

## Acceptance criteria

- [ ] لا تظهر user message نهائية قبل اعتماد كل attachment.
- [ ] provider fixture يثبت غياب bytes ووجود agent-local path ثم يختار `view_image`.
- [ ] replay بنفس identity لا ينشئ ملفًا أو رسالة ثانية.
- [ ] Gateway غير متوافق يعيد خطأ capability واضحًا ويحفظ draft.

## Definition of Done

- [ ] analyzer واختبارات interface/runner/admission المركزة ناجحة.
- [ ] daemon-backed contract test للمسارين مطلوب عند توفر hosted fixture.
- [ ] communication/provider/design docs محدثة بالعقد العام فقط.
- [ ] `graphify update .` ناجح.
- [ ] تحديث gate ونسبة المتبقي.
