---
title: "97l: القبول التفاعلي النهائي عبر sanad-dev"
status: planned
current_gate: G0
remaining_estimate: "100% of this task; historical work is reconciled in G0"
platforms: windows-first
parent_plan: docs/plans/97-windows-first-agent-client-performance.md
depends_on: "97e, 97g, 97h, 97i, 97j"
---

# 97l — القبول التفاعلي النهائي عبر sanad-dev

## Goal

إثبات التحسينات في استخدام فعلي للوكيل والعميل بعد نجاح الاختبارات الآلية.

## Locked scope and ownership

- التصميم والقبول العام: `docs/plans/97-windows-first-agent-client-performance.md`.
- الأسطح/المراجع المالكة: `docs/qa_maintenance/windows_first_performance_qa.md`، `.agents/skills/sanad-client-tester/SKILL.md`.
- التنفيذ والقياس على Windows؛ لا تُستبدل أدلته بنتائج جهاز أسرع. تحقق بقية المنصات بعد نجاح Windows في 97l؛ 97k متابعة تقريرية غير مانعة وتأتي بعد دمج Plan97.
- لا إعادة تنفيذ إصلاح مدمج أو منافسة مهمة نشطة؛ مراجعة المصدر والأدلة الحالية أولًا.
- لا إضعاف للأمان أو durability أو ترتيب الأحداث أو حداثة الواجهة. تغيير كبير منخفض العائد يؤجل بقرار موثق، لا إغلاق زائف.

## Gates

### G0 — التحقق وخط الأساس

- [ ] مراجعة العقود الأقرب والكود والاختبارات وحالة الاعتماديات، وتحديد reproduction حتمي.
- [ ] تسجيل baseline ومعايير الأداء الرقمية المعتمدة من 97a قبل تعديل الكود أو إضافة الاختبارات.

### G1 — العمل المحدد

- [ ] اتباع Sanad Client Tester: format/analyze ثم focused ثم full fast حسب النطاق ثم integration عند حدود النظام؛ التفاعل آخر بوابة.
- [ ] تشغيل زوج driver معزول وملكيته وبادج worktree عبر sanad-dev؛ snapshot/find/actions بالـkeys، دون runtime switch أو مساس بالتشغيل الأساسي.
- [ ] اختبار فتح العميل و20 resize وتغيير الأجهزة والمحادثات والإرسال والتعديل وصفحة المزود والتمرير والأداة البطيئة وStop واستئناف rate-limit وrestart/reload/stop.
- [ ] مقارنة السجل والواجهة معًا: أحداث ضرورية ظاهرة وحديثة ومرتبة دون تكرار، وقياس GPU منفصل في profile/release؛ فحص الهاتف عبر driver_main وVM endpoint صريح متاح.
- [ ] إنهاء التحقق المطلوب لبقية المنصات بعد قبول Windows، تنظيف التشغيل الذي أنشئ للاختبار فقط، وتحديث التقرير ونسبة المتبقي.

### G2 — التحقق والأدلة

- [ ] format/analyzer عبر FVM ينجحان قبل الاختبارات؛ focused tests ثم full fast/integration بحسب نطاق التغيير.
- [ ] قياس before/after على Windows وفق `docs/qa_maintenance/windows_first_performance_qa.md`، مع زمن الاختبارات القديمة والجديدة منفصلًا.
- [ ] تحديث وثائق التقنية/QA المالكة، ومراجعة العقود وتعديلها عند تغير قانون دائم فقط؛ تحديث Graphify عند تعديل الكود.
- [ ] تحديث current_gate وremaining_estimate وحالة الأب عند إغلاق كل بوابة مع دليل؛ التحقق التفاعلي الشامل لا يغلق قبل 97l.

## Acceptance criteria and success scenarios

- [ ] سيناريوهات Windows التفاعلية كلها ناجحة بالأدلة، وresize لا يصدر استدعاءات جلب.
- [ ] الوكيل يستقبل أوامر أثناء أداة بطيئة؛ لا حلقة checkpoint ولا empty flash ولا animation/ticker مستمر على Windows في الأسطح المشمولة.
- [ ] تحقق حي على الجهاز نفسه يثبت أن ظهور حالة النشاط التي كانت ترفع GPU من 0% إلى 100% — حتى مع `CircularProgressIndicator` صغير واحد — لم يعد يسبب القفزة بعد إصلاح 97j.
- [ ] القبول التفاعلي على المنصات المتأثرة مكتمل أو بوابة التسليم blocked بوضوح، مع خلاصة الأدلة المتاحة اللازمة لقرار الدمج؛ التقرير المقارن الشامل وميزانيات المتابعة تملكهما 97k بعد الدمج ولا يمنعان التسليم.

## Definition of Done

- [ ] جميع معايير القبول مثبتة باختبارات/قياسات قابلة للتكرار وليس فحص الكود فقط.
- [ ] تسجيل ملفات الاختبارات المنفذة فعلًا ونتائجها وزمنها، ومراجعة diff والأسرار والمخرجات المولدة.
- [ ] توثيق المتبقي أو التأجيل وأثره على القبول النهائي؛ لا نسبة تحسن بلا baseline صالح.
- [ ] لا commit أو push أو تغيير runtime source قبل التفويض المناسب؛ الخطة مراجعة؛ يبدأ التنفيذ على Windows وفق الاعتماديات وميزانيات 97a، وإذن التسليم الحالي لا يشمل commits التنفيذ اللاحقة.

## Evidence

Pending Windows execution. No implementation or performance result is claimed by this planning file.
