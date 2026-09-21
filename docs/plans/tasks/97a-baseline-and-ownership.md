---
title: "97a: خط الأساس وتوفيق الأعمال السابقة"
status: planned
current_gate: G0
remaining_estimate: "100% of this task; historical work is reconciled in G0"
platforms: windows-first
parent_plan: docs/plans/97-windows-first-agent-client-performance.md
depends_on: "none"
---

# 97a — خط الأساس وتوفيق الأعمال السابقة

## Goal

تثبيت قياس Windows قابل للتكرار وملاك التغييرات قبل أي تحسين.

## Locked scope and ownership

- التصميم والقبول العام: `docs/plans/97-windows-first-agent-client-performance.md`.
- الأسطح/المراجع المالكة: `docs/qa_maintenance/windows_first_performance_qa.md`.
- التنفيذ والقياس على Windows؛ لا تُستبدل أدلته بنتائج جهاز أسرع. تحقق بقية المنصات بعد نجاح Windows في 97k/97l.
- لا إعادة تنفيذ إصلاح مدمج أو منافسة مهمة نشطة؛ مراجعة المصدر والأدلة الحالية أولًا.
- لا إضعاف للأمان أو durability أو ترتيب الأحداث أو حداثة الواجهة. تغيير كبير منخفض العائد يؤجل بقرار موثق، لا إغلاق زائف.

## Gates

### G0 — التحقق وخط الأساس

- [ ] مراجعة العقود الأقرب والكود والاختبارات وحالة الاعتماديات، وتحديد reproduction حتمي.
- [ ] تسجيل baseline ومعايير الأداء الرقمية المعتمدة من 97a قبل تعديل الكود أو إضافة الاختبارات.

### G1 — العمل المحدد

- [ ] توثيق حذف المهمة 96 وفرعها لعدم الدقة وغياب أي تنفيذ صالح، وتحويل اللوج الخام إلى timeline محايد وreproduction لـ97b دون استعادة الملف أو افتراض تشخيصه؛ مراجعة التغييرات المدمجة a087238 وc19bd57 واختبارها دون cherry-pick أو تنفيذ مكرر.
- [ ] تسجيل الجهاز وWindows وGPU/driver وFlutter/Dart المثبتين ووضع البناء وحجم البيانات والنقل؛ فصل debug-driver عن profile/release.
- [ ] قياس 30 عينة لكل حالة زمنية باردة/دافئة منفصلة، وخمول ثم مؤشر واحد ثم عدة مؤشرات، مع أحجام محادثات ثابتة.
- [ ] تثبيت p50/p95 المستهدفة وميزانية الطلبات والبيانات وCPU/GPU وزمن الاختبارات قبل التنفيذ؛ ميزانية الطلبات الناتجة عن resize/rebuild تساوي صفرًا.

### G2 — التحقق والأدلة

- [ ] format/analyzer عبر FVM ينجحان قبل الاختبارات؛ focused tests ثم full fast/integration بحسب نطاق التغيير.
- [ ] قياس before/after على Windows وفق `docs/qa_maintenance/windows_first_performance_qa.md`، مع زمن الاختبارات القديمة والجديدة منفصلًا.
- [ ] تحديث وثائق التقنية/QA المالكة، ومراجعة العقود وتعديلها عند تغير قانون دائم فقط؛ تحديث Graphify عند تعديل الكود.
- [ ] تحديث current_gate وremaining_estimate وحالة الأب عند إغلاق كل بوابة مع دليل؛ التحقق التفاعلي الشامل لا يغلق قبل 97l.

## Acceptance criteria and success scenarios

- [ ] جدول baseline مكتمل لكل سيناريو في وثيقة QA، مع بيانات مجهولة وخالية من الأسرار.
- [ ] تحديد تكلفة بدء FVM منفصلة وزمن المجموعة القديمة وأبطأ عشر حالات؛ لا بدء إصلاح دون baseline للسطح المعني.

## Definition of Done

- [ ] جميع معايير القبول مثبتة باختبارات/قياسات قابلة للتكرار وليس فحص الكود فقط.
- [ ] تسجيل ملفات الاختبارات المنفذة فعلًا ونتائجها وزمنها، ومراجعة diff والأسرار والمخرجات المولدة.
- [ ] توثيق المتبقي أو التأجيل وأثره على القبول النهائي؛ لا نسبة تحسن بلا baseline صالح.
- [ ] لا commit أو push أو تغيير runtime source قبل التفويض المناسب؛ الخطة مراجعة؛ يبدأ التنفيذ على Windows وفق الاعتماديات وميزانيات 97a، وإذن التسليم الحالي لا يشمل commits التنفيذ اللاحقة.

## Evidence

Pending Windows execution. No implementation or performance result is claimed by this planning file.
