---
title: "Task 77e1: Attachment Model and Policy"
status: "pending"
priority: "high"
depends_on: "77d3"
current_gate: "R0"
remaining_estimate: "100%"
evidence_id: "77e"
---

# Task 77e1: نموذج المرفق والسياسة المركزية

## Goal

إضافة عقد typed موحد لمرفقات رسائل المستخدم وسياسة قبول مركزية تثبت حد 5 MiB لكل ملف و4 ملفات/20 MiB لكل رسالة دون إدخال bytes في الأحداث العامة.

## Locked scope

- attachment identity، الاسم الآمن، MIME، الحجم، SHA-256، kind، agent-local reference، media identity، والحالة حقول مغلقة versioned.
- `Message` تسمح attachments فقط لرسائل user وتحافظ على ترتيبها؛ النص يبقى مستقلًا.
- client wire/cache projections لا تحمل absolute path أو bytes.
- legacy user messages بلا attachments تبقى صالحة بلا migration جدولي.
- الحد `5 MiB` لكل ملف مهما كان النوع؛ `4` ملفات و`20 MiB` إجماليًا للرسالة.

## Gates

### R0 — Reference and ownership
- [ ] حل packet `77e` وتسجيل fingerprint.
- [ ] تحديد المالك canonical للنموذج والسياسة بين core/interface/client cache دون duplicate authority.

### G1 — Typed model
- [ ] إضافة schema/version/validation وJSON round trip.
- [ ] رفض attachments على غير user message ورفض divergence أو الحقول المفتوحة.
- [ ] إضافة legacy parsing بلا migration.

### G2 — Policy
- [ ] إضافة constants مركزية وحدود boundary-1/boundary/boundary+1.
- [ ] توحيد error codes الآمنة للحجم والعدد والإجمالي والmetadata التالفة.

### G3 — Projections and docs
- [ ] إضافة safe event/history/cache projection منفصلة عن agent-local storage reference.
- [ ] تحديث التصميم التقني وschema/QA المرتبطة.

## Acceptance criteria

- [ ] ملف 5 MiB يقبل و`5 MiB + 1 byte` يرفض مهما كان MIME.
- [ ] الرسالة الخامسة أو aggregate فوق 20 MiB ترفض حتميًا قبل execution.
- [ ] JSON يحافظ على order/identity/name/MIME/size/hash دون bytes/private path.
- [ ] legacy history تبقى قابلة للقراءة.

## Definition of Done

- [ ] analyzer للـAgent والـClient حسب الملفات المتأثرة.
- [ ] focused model/policy/cache tests ناجحة.
- [ ] الوثائق وQA محدثة.
- [ ] `graphify update .` ناجح.
- [ ] تحديث current gate ونسبة المتبقي عند إغلاق كل بوابة.
