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

- [ ] حل `evidence_id` عبر workflow التأصيل الخارجي والتحقق من freshness.
- [ ] قراءة implementations والاختبارات الإلزامية ومراجعة سجلات التأصيل
      السابقة في مصفوفة `Adopt / Adapt / Reject` محايدة المصدر.
- [ ] تحويل القرارات المقبولة إلى مصفوفة تحقق تكاملية صريحة.
- [ ] عند غياب الحزمة أو قدمها، تشغيل authoring/refresh ومراجعة السجلات السابقة.
- [ ] عدم بدء F0 قبل `ready`؛ لا تسجل `blocked` إلا لمانع غير قابل للتعافي.

### R0 Exit

- [ ] سجل التأصيل يحمل fingerprint والرموز والاختبارات المتحققة والقرارات.
- [ ] لا يحتوي أي ملف متتبع هوية المصدر الخارجي أو مساره؛ يبقى العقد سلوكيًا.

## 2. Gate F0 — Readiness audit

- [ ] 50b–50e كلها `complete` ولا توجد Gate مفتوحة.
- [ ] schemas وdeadline settings وterminal precedence متطابقة بين الوثائق والكود.
- [ ] cancellation registration release contract مكتملة ومستقلة عن Plan 54.
- [ ] لا توجد تغييرات إنتاجية غير موثقة في tasks السابقة.
- [ ] تحديد E2E التي تحتاج منافذ وتشغيلها sequential فقط عند الحاجة الفعلية.

### F0 Exit

- [ ] integration matrix ثابتة ولا تحتاج قرارات تصميم جديدة.

## 3. Gate F1 — Provider hang matrix

- [ ] hang قبل headers ثم Stop.
- [ ] hang بعد headers وقبل first byte.
- [ ] SSE تتوقف بعد partial reasoning/content.
- [ ] جلسة ثانية تواصل العمل أثناء إلغاء الأولى.
- [ ] لا retry/failover/runtime notice بعد user cancellation.

### F1 Exit

- [ ] كل provider path إنتاجية تنتهي داخل deadline وتحافظ على run isolation.

## 4. Gate F2 — Tool/process matrix

- [ ] shell parent/child/grandchild وpre-commit-like hook.
- [ ] TERM-resistant child ينتقل إلى KILL.
- [ ] child يتفرع قرب Stop لا يفلت من containment المملوكة.
- [ ] parent يخرج أثناء grace بينما يبقى child؛ التحقق يستمر حتى زوال المجموعة.
- [ ] PID-reuse fingerprint mismatch ترفض kill دون استهداف عملية حقيقية غريبة.
- [ ] timeout وStop يتسابقان دون نتيجة مزدوجة.
- [ ] process تكتب أثناء TERM grace: pipes تُصرف بلا late progress أو deadlock.
- [ ] لا PID orphan ولا CPU process متبقية بعد النجاح.
- [ ] release بعد اكتمال foreground process تمنع kill متأخر، بينما failure قبل
      release يبقي process قابلة للإلغاء.

### F2 Exit

- [ ] process-tree cleanup مثبت على المنصات المدعومة أو موثق بحاجز منصة صريح.

## 5. Gate F3 — Client/recovery matrix

- [ ] live tool cancellation ثم navigation والعودة.
- [ ] daemon/client reconnect أثناء stopping/terminalization.
- [ ] multi-client Stop وterminal event واحدة.
- [ ] success متأخرة تخسر terminal compare-and-set بعد cancellation ولا تزيد
      revision أو تعيد فتح spinner.
- [ ] late progress packets بعد stopped تُرفض ولا تعود الأداة إلى running.
- [ ] رسالة جديدة بعد Stop ورفض late events القديمة.
- [ ] restart hydration تعرض cancelled نفسها.

### F3 Exit

- [ ] live/history/reconnect projections متطابقة ولا spinner دائم.

## 6. Gate F4 — Final regression and handoff

- [ ] تحليل agent وclient ناجح.
- [ ] الاختبارات المركزة والجناح السريع المناسب ناجحة.
- [ ] E2E النظامية المطلوبة ناجحة دون port collisions.
- [ ] تحديث technical/product/QA وAGENTS والخطة الأم ولوحة التقدم.
- [ ] تسجيل كل finding وإرجاعه إلى المهمة المالكة بدل توسيع F4 عشوائيًا.

### F4 Exit / Definition of Done

- [ ] جميع معايير القبول الكلية في Plan 50 مغلقة.
- [ ] إغلاق Plan 50 لا يتطلب أي جدول أو أداة أو UI من Plan 54.
- [ ] لا عملية معلقة ولا session trapped ولا live/history mismatch في matrix.
- [ ] الخطة جاهزة لمراجعة المستخدم قبل commit/push/PR.
- [ ] Reference parity audit يثبت أن التنفيذ والاختبارات يحققان كل قرار
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
Date:
Gate/status:
Files changed:
Verification:
Findings:
Next gate:
```
