---
title: "97k: ميزانيات منع التراجع والتقرير المقارن"
status: planned
current_gate: G0
remaining_estimate: "100% of this task; historical work is reconciled in G0"
platforms: windows-first
parent_plan: docs/plans/97-windows-first-agent-client-performance.md
depends_on: "97e, 97f, 97g, 97h, 97i, 97j"
---

# 97k — ميزانيات منع التراجع والتقرير المقارن

## Goal

تثبيت ضمانات الأداء وتكلفة الاختبارات قبل القبول التفاعلي الأخير.

## Locked scope and ownership

- تُراجع جداول النقل في الخطط الأربع المتقاعدة بندًا ببند قبل الإغلاق: تشمل hosted wrapper smokes وfork-secret safety وعدم غياب lane/count evidence ونجاح المجموعة الكاملة مرتين لكل OS، ومراجعات الأمن وPOSIX mode/atomicity/architecture والتوثيق. لا يسقط أي التزام بمجرد اختصار الخطة الجديدة.

- التصميم والقبول العام: `docs/plans/97-windows-first-agent-client-performance.md`.
- الأسطح/المراجع المالكة: `docs/qa_maintenance/windows_first_performance_qa.md`، `docs/qa_maintenance/test_suite_performance_qa.md`، `AGENTS.md`، `client/AGENTS.md`.
- التنفيذ والقياس على Windows؛ لا تُستبدل أدلته بنتائج جهاز أسرع. تحقق بقية المنصات بعد نجاح Windows في 97k/97l.
- لا إعادة تنفيذ إصلاح مدمج أو منافسة مهمة نشطة؛ مراجعة المصدر والأدلة الحالية أولًا.
- لا إضعاف للأمان أو durability أو ترتيب الأحداث أو حداثة الواجهة. تغيير كبير منخفض العائد يؤجل بقرار موثق، لا إغلاق زائف.

## Gates

### G0 — التحقق وخط الأساس

- [ ] مراجعة العقود الأقرب والكود والاختبارات وحالة الاعتماديات، وتحديد reproduction حتمي.
- [ ] تسجيل baseline ومعايير الأداء الرقمية المعتمدة من 97a قبل تعديل الكود أو إضافة الاختبارات.

### G1 — العمل المحدد

- [ ] جمع نتائج before/after لكل مهمة على Windows بنفس الجهاز والبيانات ووضع البناء؛ تقرير p50/p95 وCPU/GPU والطلبات والbytes.
- [ ] اختبارات حتمية للـrequest count والتقدم وticker/ownership/event parity؛ timing thresholds على جهاز مضبوط لا assertion هش على CI مشترك.
- [ ] قياس المجموعة القديمة قبل/بعد منفصلة عن زمن الاختبارات الجديدة وFVM؛ تبرير كل زيادة ورفض زيادة غير مبررة.
- [ ] بعد نجاح Windows، تشغيل تحقق macOS/Linux المطلوب للحدود المشتركة والأمنية؛ قياس هاتف/فحص تحميل الأجهزة ضمن القبول الأخير. لا إغلاق متطلب قديم بادعاء أنه اختياري.

### G2 — التحقق والأدلة

- [ ] format/analyzer عبر FVM ينجحان قبل الاختبارات؛ focused tests ثم full fast/integration بحسب نطاق التغيير.
- [ ] قياس before/after على Windows وفق `docs/qa_maintenance/windows_first_performance_qa.md`، مع زمن الاختبارات القديمة والجديدة منفصلًا.
- [ ] تحديث وثائق التقنية/QA المالكة، ومراجعة العقود وتعديلها عند تغير قانون دائم فقط؛ تحديث Graphify عند تعديل الكود.
- [ ] تحديث current_gate وremaining_estimate وحالة الأب عند إغلاق كل بوابة مع دليل؛ التحقق التفاعلي الشامل لا يغلق قبل 97l.

## Acceptance criteria and success scenarios

- [ ] تقرير مكاسب مستقل لكل metric مع العينات والضوضاء والمهام المؤجلة وأسبابها؛ لا نسبة تحسن إجمالية مختلقة.
- [ ] كل regression له اختبار أو ميزانية ومالك؛ المنصات غير المتاحة تسجل blocked لا passed.

## Definition of Done

- [ ] جميع معايير القبول مثبتة باختبارات/قياسات قابلة للتكرار وليس فحص الكود فقط.
- [ ] تسجيل ملفات الاختبارات المنفذة فعلًا ونتائجها وزمنها، ومراجعة diff والأسرار والمخرجات المولدة.
- [ ] توثيق المتبقي أو التأجيل وأثره على القبول النهائي؛ لا نسبة تحسن بلا baseline صالح.
- [ ] لا commit أو push أو تغيير runtime source قبل التفويض المناسب؛ الخطة مراجعة؛ يبدأ التنفيذ على Windows وفق الاعتماديات وميزانيات 97a، وإذن التسليم الحالي لا يشمل commits التنفيذ اللاحقة.

## Evidence

Pending Windows execution. No implementation or performance result is claimed by this planning file.
