---
title: "Task 77f2: User Message Attachment and Edit UX"
status: "pending"
priority: "high"
depends_on: "77f1, 77f3"
current_gate: "R0"
remaining_estimate: "100%"
evidence_id: "77e"
---

# Task 77f2: عرض مرفقات رسالة المستخدم وتحريرها

## Goal

عرض الصور والملفات داخل user bubble واستعادة المرفقات بأمان في Edit & Retry دون إعادة رفع الموجود أو تغيير التاريخ عند فشل التعديل.

## Locked scope

- المرفقات تظهر بالترتيب فوق النص؛ images grid وgeneric file cards.
- الصورة تفتح Lightbox؛ الملف يفتح preview آمنة إن دعمت وإلا تنزيلًا مصادقًا عليه.
- لا تعرض البطاقة agent path أو media ticket أو storage identity الخام.
- Edit يعيد existing attachments كـready references دون re-upload، ويسمح remove/add.
- Cancel يعيد الأصل؛ Save & Retry ينتظر المرفقات الجديدة وreplay admission.
- attachment cleanup لا يحذف ملفًا ما زالت رسالة canonical تشير إليه.

## Gates

### R0 — Cache/edit ownership
- [ ] حل packet `77e` وتسجيل fingerprint.
- [ ] مراجعة conversation cache وmessage edit/retry contracts.

### G1 — Timeline projection
- [ ] تمديد domain/cache mapper للمرفقات typed والlegacy history.
- [ ] إضافة responsive image/file rendering وحالات unavailable.
- [ ] إضافة Lightbox/preview semantics ولوحة المفاتيح.

### G2 — Inline edit
- [ ] hydrate المرفقات الموجودة دون network upload.
- [ ] دعم add/remove/retry مع transient edit draft معزول.
- [ ] إبقاء canonical bubble دون تغيير حتى نجاح Save & Retry.

### G3 — Recovery and tests
- [ ] widget/cache tests للlive/history parity وإعادة فتح التطبيق.
- [ ] tests لـCancel، upload failure، stale edit، session/device switch.

## Acceptance criteria

- [ ] الرسالة تعرض thumbnail/file cards ثم النص بنفس الترتيب حيًا وبعد hydration.
- [ ] Edit يظهر المرفقات نفسها فورًا ولا يعيد رفعها.
- [ ] إزالة/إضافة ثم Cancel لا تغير الرسالة أو التخزين.
- [ ] Save failure يبقي وضع التحرير والأصل، والنجاح يعيد الجولة مرة واحدة.

## Definition of Done

- [ ] `fvm flutter analyze` ناجح.
- [ ] focused widget/cache/edit tests ناجحة.
- [ ] تحقق مرئي ظاهر للرسالة وEdit وLightbox.
- [ ] UX وQA docs محدثة.
- [ ] `graphify update .` ناجح.
- [ ] تحديث gate ونسبة المتبقي.
