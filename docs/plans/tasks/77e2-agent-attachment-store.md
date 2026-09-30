---
title: "Task 77e2: Agent Attachment Store"
status: "pending"
priority: "high"
depends_on: "77e1"
current_gate: "R0"
remaining_estimate: "100%"
evidence_id: "77e"
---

# Task 77e2: مخزن المرفقات المملوك للوكيل

## Goal

إنشاء مخزن محمي داخل Sanad Home يقبل ملفات محلية أو منقولة، يثبتها ذرّيًا تحت session ownership، ويعيد agent-local references صالحة للأدوات دون كشفها للعميل العام.

## Locked scope

- agent هو storage/path authority؛ client cache لا يملك الملفات.
- partial write يستخدم ملفًا خاصًا مؤقتًا ثم size/hash/content validation ثم atomic promotion.
- filename وMIME المرسلان advisory؛ الاسم ينظف ولا يحدد مسار التخزين.
- user attachment grant محدود بالمرفق والجلسة ولا يساوي workspace/full access.
- attachment يبقى ما دامت رسالته موجودة؛ session deletion وorphan cleanup يحذفانه حتميًا.
- remote recursive folders خارج النطاق.

## Gates

### R0 — Evidence and filesystem contract
- [ ] حل packet `77e` وتسجيل fingerprint.
- [ ] مراجعة Sanad Home وpermission/path contracts المالكة.

### G1 — Private staging
- [ ] إضافة create/write/commit/cancel API bounded دون path injection.
- [ ] تطبيق 5 MiB authoritative ceiling وSHA-256 وsafe-name/content inspection.
- [ ] ضمان owner-only permissions حيث يدعم النظام.

### G2 — Durable ownership and cleanup
- [ ] ربط attachment بالجلسة والرسالة دون orphan race.
- [ ] تنظيف partial timeout/cancel/failure وsession deletion.
- [ ] منع cross-session identity reuse.

### G3 — Tool path bridge
- [ ] إنتاج agent-local path/reference لا يظهر في events/logs.
- [ ] تمكين أدوات القراءة و`view_image` من استخدام grant المحدودة فقط.

## Acceptance criteria

- [ ] interrupted/invalid/hash-mismatch upload لا يترك ملفًا معتمدًا أو partial دائمًا.
- [ ] traversal واسم خبيث وMIME كاذب لا يغير storage root أو النوع المتحقق.
- [ ] مرفق جلسة لا يقرأ من جلسة أخرى.
- [ ] حذف الجلسة يزيل الملفات والmetadata idempotently.

## Definition of Done

- [ ] `fvm dart analyze` ناجح.
- [ ] focused store/path/permission/cleanup tests ناجحة.
- [ ] اختبارات Windows/macOS/Linux path semantics ممثلة.
- [ ] وثائق الحماية وQA محدثة.
- [ ] `graphify update .` ناجح.
- [ ] تحديث gate ونسبة المتبقي.
