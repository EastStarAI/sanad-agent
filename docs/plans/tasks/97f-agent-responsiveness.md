---
title: "97f: استجابة الوكيل أثناء أدوات الملفات"
status: planned
current_gate: G0
remaining_estimate: "100% of this task; historical work is reconciled in G0"
platforms: windows-first
parent_plan: docs/plans/97-windows-first-agent-client-performance.md
depends_on: "97b"
---

# 97f — استجابة الوكيل أثناء أدوات الملفات

## Goal

منع تجميد استقبال الأوامر والتاريخ أثناء قراءة أو تعديل الملفات على Windows.

## Locked scope and ownership

- التصميم والقبول العام: `docs/plans/97-windows-first-agent-client-performance.md`.
- الأسطح/المراجع المالكة: `agent/lib/capabilities/runtime/workspace_path_resolver.dart`، `agent/lib/capabilities/runtime/workspace_tools/file_edit_handler.dart`، `agent/lib/capabilities/runtime/workspace_tools/file_read_handler.dart`.
- التنفيذ والقياس على Windows؛ لا تُستبدل أدلته بنتائج جهاز أسرع. تحقق بقية المنصات بعد نجاح Windows في 97k/97l.
- لا إعادة تنفيذ إصلاح مدمج أو منافسة مهمة نشطة؛ مراجعة المصدر والأدلة الحالية أولًا.
- لا إضعاف للأمان أو durability أو ترتيب الأحداث أو حداثة الواجهة. تغيير كبير منخفض العائد يؤجل بقرار موثق، لا إغلاق زائف.

## Gates

### G0 — التحقق وخط الأساس

- [ ] مراجعة العقود الأقرب والكود والاختبارات وحالة الاعتماديات، وتحديد reproduction حتمي.
- [ ] تسجيل baseline ومعايير الأداء الرقمية المعتمدة من 97a قبل تعديل الكود أو إضافة الاختبارات.

### G1 — العمل المحدد

- [ ] ربط طلب الأداة/التفويض/path/handler/persistence/socket/UI بقياسات monotonic ومعرف correlation؛ قياس الوصول لا spinner فقط.
- [ ] اختبار event-loop lag أثناء exact edit وfallback matching وقراءة ملف/مجلد، صغير وكبير، مع طلب تاريخ مستقل محلي/cloud.
- [ ] تحديد تكلفة typeSync/resolveSymbolicLinksSync ومعالجة النص وDB locks؛ مقارنة shell_execute كحالة ضابطة.
- [ ] إصلاح أصغر طبقة مثبتة؛ async IO أو عامل محدود للعمل الحسابي عند الحاجة فقط، مع حفظ الأذونات وترتيب الكتابة والإلغاء.

### G2 — التحقق والأدلة

- [ ] format/analyzer عبر FVM ينجحان قبل الاختبارات؛ focused tests ثم full fast/integration بحسب نطاق التغيير.
- [ ] قياس before/after على Windows وفق `docs/qa_maintenance/windows_first_performance_qa.md`، مع زمن الاختبارات القديمة والجديدة منفصلًا.
- [ ] تحديث وثائق التقنية/QA المالكة، ومراجعة العقود وتعديلها عند تغير قانون دائم فقط؛ تحديث Graphify عند تعديل الكود.
- [ ] تحديث current_gate وremaining_estimate وحالة الأب عند إغلاق كل بوابة مع دليل؛ التحقق التفاعلي الشامل لا يغلق قبل 97l.

## Acceptance criteria and success scenarios

- [ ] أمر مستقل يصل ويستجيب أثناء أداة بطيئة وقبل نهايتها؛ اختبار حتمي يثبت ذلك.
- [ ] p50/p95 الأدوات والتاريخ تحقق ميزانية 97a؛ فصل أي بطء تاريخ مستقل متبقٍ بدل افتراض سبب واحد.

## Definition of Done

- [ ] جميع معايير القبول مثبتة باختبارات/قياسات قابلة للتكرار وليس فحص الكود فقط.
- [ ] تسجيل ملفات الاختبارات المنفذة فعلًا ونتائجها وزمنها، ومراجعة diff والأسرار والمخرجات المولدة.
- [ ] توثيق المتبقي أو التأجيل وأثره على القبول النهائي؛ لا نسبة تحسن بلا baseline صالح.
- [ ] لا commit أو push أو تغيير runtime source قبل التفويض المناسب؛ الخطة مراجعة؛ يبدأ التنفيذ على Windows وفق الاعتماديات وميزانيات 97a، وإذن التسليم الحالي لا يشمل commits التنفيذ اللاحقة.

## Evidence

Pending Windows execution. No implementation or performance result is claimed by this planning file.
