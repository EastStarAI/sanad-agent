---
title: "Task 50f: Cancellation Integration and Regression QA"
description: "إغلاق اختبارات النظام الحقيقي للإلغاء عبر المزود والأدوات والعميل والتعافي، وتوثيق نتائج Plan 50 النهائية."
status: "complete"
current_gate: "F4 complete"
priority: "high"
depends_on: "50b, 50c, 50d, 50e"
file_budget: 10
reference_grounding: "required"
evidence_id: "50f"
design_contract: "docs/technical/run_cancellation_and_process_ownership.md"
---

# Task 50f: Cancellation Integration and Regression QA

## 1. الهدف

إثبات أن primitive والـproviders والأدوات والبروتوكول والعميل تعمل كنظام واحد تحت hangs وraces وreconnect، ثم إغلاق الخطة بأدلة تحقق قابلة للتكرار.

## Gate R0 — External Reference Grounding

- [x] حل `evidence_id` عبر workflow التأصيل الخارجي والتحقق من freshness.
- [x] قراءة implementations والاختبارات الإلزامية ومراجعة سجلات التأصيل
      السابقة في مصفوفة `Adopt / Adapt / Reject` محايدة المصدر.
- [x] تحويل القرارات المقبولة إلى مصفوفة تحقق تكاملية صريحة.
- [x] عند غياب الحزمة أو قدمها، تشغيل authoring/refresh ومراجعة السجلات السابقة.
- [x] عدم بدء F0 قبل `ready`؛ لا تسجل `blocked` إلا لمانع غير قابل للتعافي.

### R0 Exit

- [x] سجل التأصيل يحمل fingerprint والرموز والاختبارات المتحققة والقرارات.
- [x] لا يحتوي أي ملف متتبع هوية المصدر الخارجي أو مساره؛ يبقى العقد سلوكيًا.

## 2. Gate F0 — Readiness audit

- [x] 50b–50e كلها `complete` ولا توجد Gate مفتوحة.
- [x] schemas وdeadline settings وterminal precedence متطابقة بين الوثائق والكود.
- [x] cancellation registration release contract مكتملة ومستقلة عن Plan 54.
- [x] لا توجد تغييرات إنتاجية غير موثقة في tasks السابقة.
- [x] تحديد E2E التي تحتاج منافذ وتشغيلها sequential فقط عند الحاجة الفعلية.

### F0 Exit

- [x] integration matrix ثابتة ولا تحتاج قرارات تصميم جديدة.

## 3. Gate F1 — Provider hang matrix

- [x] hang قبل headers ثم Stop.
- [x] hang بعد headers وقبل first byte.
- [x] SSE تتوقف بعد partial reasoning/content.
- [x] جلسة ثانية تواصل العمل أثناء إلغاء الأولى.
- [x] لا retry/failover/runtime notice بعد user cancellation.

### F1 Exit

- [x] كل provider path إنتاجية تنتهي داخل deadline وتحافظ على run isolation.

## 4. Gate F2 — Tool/process matrix

- [x] shell parent/child/grandchild وpre-commit-like hook.
- [x] TERM-resistant child ينتقل إلى KILL.
- [x] child يتفرع قرب Stop لا يفلت من containment المملوكة.
- [x] parent يخرج أثناء grace بينما يبقى child؛ التحقق يستمر حتى زوال المجموعة.
- [x] PID-reuse fingerprint mismatch ترفض kill دون استهداف عملية حقيقية غريبة.
- [x] timeout وStop يتسابقان دون نتيجة مزدوجة.
- [x] process تكتب أثناء TERM grace: pipes تُصرف بلا late progress أو deadlock.
- [x] لا PID orphan ولا CPU process متبقية بعد النجاح.
- [x] release بعد اكتمال foreground process تمنع kill متأخر، بينما failure قبل
      release يبقي process قابلة للإلغاء.

### F2 Exit

- [x] process-tree cleanup مثبت على المنصات المدعومة أو موثق بحاجز منصة صريح.

## 5. Gate F3 — Client/recovery matrix

- [x] live tool cancellation ثم navigation والعودة.
- [x] daemon/client reconnect أثناء stopping/terminalization.
- [x] multi-client Stop وterminal event واحدة.
- [x] success متأخرة تخسر terminal compare-and-set بعد cancellation ولا تزيد
      revision أو تعيد فتح spinner.
- [x] late progress packets بعد stopped تُرفض ولا تعود الأداة إلى running.
- [x] رسالة جديدة بعد Stop ورفض late events القديمة.
- [x] restart hydration تعرض cancelled نفسها.

### F3 Exit

- [x] live/history/reconnect projections متطابقة ولا spinner دائم.

## 6. Gate F4 — Final regression and handoff

- [x] تحليل agent وclient ناجح.
- [x] الاختبارات المركزة والجناح السريع المناسب ناجحة.
- [x] E2E النظامية المطلوبة ناجحة دون port collisions.
- [x] تحديث technical/product/QA وAGENTS والخطة الأم ولوحة التقدم.
- [x] تسجيل كل finding وإرجاعه إلى المهمة المالكة بدل توسيع F4 عشوائيًا.

### F4 Exit / Definition of Done

- [x] جميع معايير القبول الكلية في Plan 50 مغلقة.
- [x] إغلاق Plan 50 لا يتطلب أي جدول أو أداة أو UI من Plan 54.
- [x] لا عملية معلقة ولا session trapped ولا live/history mismatch في matrix.
- [x] الخطة جاهزة لمراجعة المستخدم قبل commit/push/PR.
- [x] Reference parity audit يثبت أن التنفيذ والاختبارات يحققان كل قرار
      `Adopt/Adapt` مسجل في 50a–50f، أو يعيد deviation إلى المهمة المالكة.

## 7. الملفات المتوقعة

- E2E agent/runtime fixture files (2–3)
- client integration/widget test files (1–2)
- `docs/qa_maintenance/plan50_cancellation_regression_matrix.md` (جديد)
- `docs/qa_maintenance/MOC.md`
- `docs/technical/agent_runtime.md`
- `docs/technical/communication_protocols.md`
- ملف المهمة والخطة الأم

## 8. سيناريو النجاح النهائي

يعلق provider قبل الرد، ثم تعلق shell tree متعددة المستويات في run أخرى. Stop لكل جلسة يقطع موردها وحده داخل deadline، ينشر cancelled/stopped/idle بالترتيب، لا يترك process، وتبقى الواجهة والتاريخ متطابقين بعد reconnect وreload.

## 9. سجل التقدم

```text
Date: 2026-08-29
Gate/status: F4 complete after review repair
Files changed: daemon-backed cancellation E2E, execution snapshot publication,
  runtime/interface contracts, and the Plan 50 QA matrix
Verification: agent/client analyzers and fast suites; focused cancellation,
  durable-state, interface, widget, and sequential daemon-backed E2E suites
Findings: the original closeout had no real live-shell Stop proof and allowed
  idle to publish before cancelled/stopped. Added provider and shell system
  cases and deferred only the committed snapshot publication to restore order.
Next gate: user review before the combined 50e/50f commit
```
