---
title: "97b: حلقة الاستئناف وهوية نتائج الأدوات"
status: planned
current_gate: G0
remaining_estimate: "100% of this task; historical work is reconciled in G0"
platforms: windows-first
parent_plan: docs/plans/97-windows-first-agent-client-performance.md
depends_on: "97a"
---

# 97b — حلقة الاستئناف وهوية نتائج الأدوات

## Goal

إيقاف عدم التقدم بعد استئناف rate-limit دون إعادة تنفيذ آثار جانبية مكتملة.

## Locked scope and ownership

- التصميم والقبول العام: `docs/plans/97-windows-first-agent-client-performance.md`.
- الأسطح/المراجع المالكة: `agent/lib/engine/runtime/tool_execution_coordinator.dart`، `agent/lib/engine/runtime/continuation_checkpoint_coordinator.dart`، `agent/lib/engine/agent_runner.dart`.
- التنفيذ والقياس على Windows؛ لا تُستبدل أدلته بنتائج جهاز أسرع. تحقق بقية المنصات بعد نجاح Windows في 97k/97l.
- لا إعادة تنفيذ إصلاح مدمج أو منافسة مهمة نشطة؛ مراجعة المصدر والأدلة الحالية أولًا.
- لا إضعاف للأمان أو durability أو ترتيب الأحداث أو حداثة الواجهة. تغيير كبير منخفض العائد يؤجل بقرار موثق، لا إغلاق زائف.

## Gates

### G0 — التحقق وخط الأساس

- [ ] مراجعة العقود الأقرب والكود والاختبارات وحالة الاعتماديات، وتحديد reproduction حتمي.
- [ ] تسجيل baseline ومعايير الأداء الرقمية المعتمدة من 97a قبل تعديل الكود أو إضافة الاختبارات.

### G1 — العمل المحدد

- [ ] تنسيق الملكية مع المهمة 96 في فرعها؛ استهلاك الإصلاح بعد مراجعته بدل إنشاء تنفيذ منافس.
- [ ] اختبار معرف أداة مكرر عبر خطوتي نموذج وعبر جولتين وبـarguments مختلفة؛ التفريق بين استدعاء جديد وإعادة تشغيل checkpoint نفسه.
- [ ] التحقق من التاريخ وHistoryHealer وربط النتيجة برسالة المساعد الصحيحة واستعادة notice/retry deadline؛ الاستجابة 200 ليست rate-limit مستمرًا.
- [ ] محاكاة restart أثناء الانتظار وأثناء أداة ذات أثر جانبي وبعد حفظ النتيجة، والتحقق من Stop ومنع مضاعفة الاستدعاءات.

### G2 — التحقق والأدلة

- [ ] format/analyzer عبر FVM ينجحان قبل الاختبارات؛ focused tests ثم full fast/integration بحسب نطاق التغيير.
- [ ] قياس before/after على Windows وفق `docs/qa_maintenance/windows_first_performance_qa.md`، مع زمن الاختبارات القديمة والجديدة منفصلًا.
- [ ] تحديث وثائق التقنية/QA المالكة، ومراجعة العقود وتعديلها عند تغير قانون دائم فقط؛ تحديث Graphify عند تعديل الكود.
- [ ] تحديث current_gate وremaining_estimate وحالة الأب عند إغلاق كل بوابة مع دليل؛ التحقق التفاعلي الشامل لا يغلق قبل 97l.

## Acceptance criteria and success scenarios

- [ ] كل استدعاء جديد ينفذ مرة، وcheckpoint المكتمل يعاد استخدامه لنفس الاستدعاء فقط.
- [ ] لا دورة طلبات متكررة بلا تقدم في السيناريو؛ لا إخفاء الخلل بحد تعسفي يوقف عملًا مشروعًا.

## Definition of Done

- [ ] جميع معايير القبول مثبتة باختبارات/قياسات قابلة للتكرار وليس فحص الكود فقط.
- [ ] تسجيل ملفات الاختبارات المنفذة فعلًا ونتائجها وزمنها، ومراجعة diff والأسرار والمخرجات المولدة.
- [ ] توثيق المتبقي أو التأجيل وأثره على القبول النهائي؛ لا نسبة تحسن بلا baseline صالح.
- [ ] لا commit أو push أو تغيير runtime source قبل التفويض المناسب؛ الخطة مراجعة؛ يبدأ التنفيذ على Windows وفق الاعتماديات وميزانيات 97a، وإذن التسليم الحالي لا يشمل commits التنفيذ اللاحقة.

## Evidence

Pending Windows execution. No implementation or performance result is claimed by this planning file.
