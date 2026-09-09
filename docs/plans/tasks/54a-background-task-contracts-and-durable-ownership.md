---
title: "Task 54a: Background Task Contracts and Durable Ownership"
description: "تثبيت نموذج task/owner/revision وجداول SQLite والمعاملات التي تمنع فجوة الملكية أو حذف session ذات عملية نشطة."
status: "pending"
current_gate: "Ready for R0"
priority: "critical"
depends_on: "Plan 50 complete; Task 31; Task 36"
file_budget: 14
reference_grounding: "required"
evidence_id: "54a"
design_contract: "docs/technical/background_terminal_task_runtime.md"
---

# Task 54a: Background Task Contracts and Durable Ownership

## 1. الهدف

إنشاء العقود الدائمة التي تستخدمها supervisor والأدوات والبروتوكول والواجهة،
مع claim/revision/terminal CAS واضحة ومنع أي task أو process بلا session مالكة.

## Gate R0 — External Reference Grounding

- [ ] حل `evidence_id` عبر workflow التأصيل الخارجي والتحقق من freshness.
- [ ] قراءة implementations والاختبارات الإلزامية وتسجيل مصفوفة
      `Adopt / Adapt / Reject` محلية ومحايدة المصدر.
- [ ] تحويل القرارات المقبولة إلى invariants واختبارات صريحة لهذه المهمة.
- [ ] عند غياب الحزمة أو قدمها، تشغيل authoring/refresh حتى تصبح `ready`.
- [ ] عدم بدء A0 قبل `ready`؛ لا تسجل `blocked` إلا لمانع غير قابل للتعافي.

### R0 Exit

- [ ] سجل التأصيل يحمل fingerprint والرموز والاختبارات المتحققة والقرارات.
- [ ] لا يحتوي أي ملف متتبع هوية المصدر الخارجي أو مساره؛ يبقى العقد سلوكيًا.

## 2. Gate A0 — Contract freeze

- [ ] تثبيت state machine والterminal precedence وowner kinds/generation.
- [ ] تثبيت العلاقة بين `background_after_ms` و`timeout_ms`.
- [ ] تثبيت claim-before-release وrollback عند فشل handoff.
- [ ] تحديد أن process لا تستأنف بعد daemon restart.
- [ ] تحديد command redaction وoutput retention ومصدر الإعدادات المركزية.
- [ ] تثبيت حدود concurrency لكل session/device ونتائج `capacity_exceeded` و
      `daemon_draining`؛ لا تنشأ FIFO process queue خفية.
- [ ] تثبيت `no_output_timeout_ms=0` كتعطيل افتراضي وفصل notice عن cancellation.

### A0 Exit

- [ ] لا تحتاج 54b–54e قرار schema أو ownership جديدًا.

## 3. Gate A1 — SQLite schema and repository

- [ ] إضافة `background_tasks` و`session_wake_triggers` داخل `state.db` نفسها.
- [ ] indices للجلسة والحالة وdue time وdedupe key.
- [ ] repository typed للcreate/claim/transition/list/cursor updates.
- [ ] حفظ `last_output_at`, attention state، وtermination reason المستقلة
      `no_output_timeout` دون جعل notice حالة terminal.
- [ ] compare-and-set بالـrevision وowner generation لكل transition متنافسة.
- [ ] migration/backfill idempotent واختبارات قاعدة بيانات حقيقية.

### A1 Exit

- [ ] restart يعيد السجلات بلا فقد، ولا يفتح اتصال SQLite ثانية.

## 4. Gate A2 — Ownership and deletion guards

- [ ] transaction تثبت background claim قبل السماح بـ`release()`.
- [ ] فشل claim يبقي Plan 50 registration فعالة.
- [ ] session deletion query ترفض non-terminal tasks وتعيد IDs/count typed.
- [ ] API لإلغاء جميع tasks المالكة ثم السماح بالحذف بعد terminalization.
- [ ] منع cross-session task lookup/mutation في repository boundary.

### A2 Exit / Definition of Done

- [ ] لا owner gap في اختبارات السباق والفشل.
- [ ] لا تحذف session أو task row بينما process ما زالت non-terminal.
- [ ] schema والعقود موثقة والمهمة داخل file budget.
- [ ] Reference parity audit يثبت أن التنفيذ والاختبارات يحققان كل قرار
      `Adopt/Adapt` مسجل، أو يعيد أي deviation إلى تصميم المهمة.

## 5. الملفات المتوقعة

- `agent/lib/evolution/db/agent_state_database.dart`
- models/repository جديدة تحت `agent/lib/evolution/db/runtime/` (3–4 ملفات)
- session deletion owner في interfaces/evolution (1 ملف)
- اختبارات database/repository/deletion (3 ملفات)
- أقرب `AGENTS.md` للملفات المعدلة
- `docs/technical/agent_database_schema.md`
- `docs/technical/agent_runtime.md`
- ملف المهمة والخطة الأم

## 6. سيناريو النجاح

تبدأ run وتملك process foreground. ينجح create+claim في transaction ثم يسمح
release. في سباق ثان تفشل claim، فتظل registration قابلة للإلغاء. محاولة حذف
session في الحالتين ترفض حتى تصبح كل tasks terminal.

## 7. سجل التقدم

```text
Date:
Gate/status:
Files changed:
Verification:
Findings:
Next gate:
```
