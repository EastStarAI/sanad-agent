---
title: "97i: كفاءة تحميل المحادثات والصفحات"
status: planned
current_gate: G0
remaining_estimate: "100% of this task; historical work is reconciled in G0"
platforms: windows-first
parent_plan: docs/plans/97-windows-first-agent-client-performance.md
depends_on: "97h"
---

# 97i — كفاءة تحميل المحادثات والصفحات

## Goal

تقليل جلب القوائم والتاريخ مع الحفاظ على اكتمال القائمة والتمرير والترتيب.

## Locked scope and ownership

- التصميم والقبول العام: `docs/plans/97-windows-first-agent-client-performance.md`.
- الأسطح/المراجع المالكة: `client/lib/features/conversations/data/repositories/conversation_cache_repository.dart`، `client/lib/features/conversations/presentation/bloc/session_sidebar_cubit.dart`.
- التنفيذ والقياس على Windows؛ لا تُستبدل أدلته بنتائج جهاز أسرع. تحقق بقية المنصات المطلوب للدمج في 97l؛ 97k متابعة تقريرية غير مانعة بعد الدمج.
- لا إعادة تنفيذ إصلاح مدمج أو منافسة مهمة نشطة؛ مراجعة المصدر والأدلة الحالية أولًا.
- لا إضعاف للأمان أو durability أو ترتيب الأحداث أو حداثة الواجهة. تغيير كبير منخفض العائد يؤجل بقرار موثق، لا إغلاق زائف.

## Gates

### G0 — التحقق وخط الأساس

- [ ] مراجعة العقود الأقرب والكود والاختبارات وحالة الاعتماديات، وتحديد reproduction حتمي.
- [ ] تسجيل baseline ومعايير الأداء الرقمية المعتمدة من 97a قبل تعديل الكود أو إضافة الاختبارات.

### G1 — العمل المحدد

- [ ] تصنيف get_sessions: workspace منفصل أم نفس query/cursor مكرر أم load-more؛ التنسيق مع حدود 97b الحالية لمنع ازدواجية إصلاحات الاستئناف والهوية، دون الاعتماد على المهمة 96 المحذوفة.
- [ ] تمييز قائمة المحادثات عن صفحات تاريخ المحادثة؛ لا الاستدلال باسم endpoint فقط على مشكلة امتلاء viewport.
- [ ] تجربة زيادة 50% لأحجام 6/10 إلى 9/15 مقابل baseline؛ قياس عدد الطلبات والbytes والوقت والذاكرة والرسم.
- [ ] اختيار نتيجة التجربة فقط؛ لا فرض 50 عنصرًا ولا إحضار كل الأقسام إذا كان الحل الأرخص منع تكرار الطلب.

### G2 — التحقق والأدلة

- [ ] format/analyzer عبر FVM ينجحان قبل الاختبارات؛ focused tests ثم full fast/integration بحسب نطاق التغيير.
- [ ] قياس before/after على Windows وفق `docs/qa_maintenance/windows_first_performance_qa.md`، مع زمن الاختبارات القديمة والجديدة منفصلًا.
- [ ] تحديث وثائق التقنية/QA المالكة، ومراجعة العقود وتعديلها عند تغير قانون دائم فقط؛ تحديث Graphify عند تعديل الكود.
- [ ] تحديث current_gate وremaining_estimate وحالة الأب عند إغلاق كل بوابة مع دليل؛ التحقق التفاعلي الشامل لا يغلق قبل 97l.

## Acceptance criteria and success scenarios

- [ ] لا cursor متكرر جارٍ للقسم نفسه ولا محادثات مفقودة/مكررة؛ load-more يصل للنهاية الصحيحة.
- [ ] نجاح تجربة الأداء أو رفض الزيادة بتقرير؛ لا تغيير page size بلا مكسب مقاس.

## Definition of Done

- [ ] جميع معايير القبول مثبتة باختبارات/قياسات قابلة للتكرار وليس فحص الكود فقط.
- [ ] تسجيل ملفات الاختبارات المنفذة فعلًا ونتائجها وزمنها، ومراجعة diff والأسرار والمخرجات المولدة.
- [ ] توثيق المتبقي أو التأجيل وأثره على القبول النهائي؛ لا نسبة تحسن بلا baseline صالح.
- [ ] لا commit أو push أو تغيير runtime source قبل التفويض المناسب؛ الخطة مراجعة؛ يبدأ التنفيذ على Windows وفق الاعتماديات وميزانيات 97a، وإذن التسليم الحالي لا يشمل commits التنفيذ اللاحقة.

## Evidence

Pending Windows execution. No implementation or performance result is claimed by this planning file.
