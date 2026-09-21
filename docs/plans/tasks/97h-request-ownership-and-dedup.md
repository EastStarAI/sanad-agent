---
title: "97h: ملكية الجلب ومنع استدعاءات إعادة البناء"
status: planned
current_gate: G0
remaining_estimate: "100% of this task; historical work is reconciled in G0"
platforms: windows-first
parent_plan: docs/plans/97-windows-first-agent-client-performance.md
depends_on: "97g"
---

# 97h — ملكية الجلب ومنع استدعاءات إعادة البناء

## Goal

تقليل استدعاءات العميل دون فقد أحداث أو تقادم غير معلن، وجعل إعادة البناء بلا آثار نقل.

## Locked scope and ownership

- التصميم والقبول العام: `docs/plans/97-windows-first-agent-client-performance.md`.
- الأسطح/المراجع المالكة: `client/lib/features/conversations/presentation/widgets/conversation_input/conversation_input_composer.dart`، `client/lib/features/conversations/presentation/widgets/conversation_input/conversation_bottom_actions.dart`، `client/lib/features/provider_setup/presentation/bloc/provider_usage_cubit.dart`.
- التنفيذ والقياس على Windows؛ لا تُستبدل أدلته بنتائج جهاز أسرع. تحقق بقية المنصات بعد نجاح Windows في 97k/97l.
- لا إعادة تنفيذ إصلاح مدمج أو منافسة مهمة نشطة؛ مراجعة المصدر والأدلة الحالية أولًا.
- لا إضعاف للأمان أو durability أو ترتيب الأحداث أو حداثة الواجهة. تغيير كبير منخفض العائد يؤجل بقرار موثق، لا إغلاق زائف.

## Gates

### G0 — التحقق وخط الأساس

- [ ] مراجعة العقود الأقرب والكود والاختبارات وحالة الاعتماديات، وتحديد reproduction حتمي.
- [ ] تسجيل baseline ومعايير الأداء الرقمية المعتمدة من 97a قبل تعديل الكود أو إضافة الاختبارات.

### G1 — العمل المحدد

- [ ] تتبع startup/device/session/send/edit/provider-page/resize/theme/rebuild مع device/resource/query/revision وrequest count دون payload سري.
- [ ] إزالة جلب البيانات من build/builders وpost-frame الناتج عن rebuild ومن إعادة تركيب responsive widgets؛ lifecycle لا يجلب إلا عند تغير المورد المنطقي.
- [ ] توحيد جلب model.snapshot وusage.support لدى المالك الحالي ومشاركة الطلب الجاري حسب device/query؛ حماية remount وحدها محليًا غير كافية.
- [ ] اعتماد authoritative invalidation/reconnect/user refresh مع stale projection واضحة؛ دمج responses فقط إذا فشلت البدائل الأبسط وأثبت القياس فائدة مع فصل المسؤوليات.

### G2 — التحقق والأدلة

- [ ] format/analyzer عبر FVM ينجحان قبل الاختبارات؛ focused tests ثم full fast/integration بحسب نطاق التغيير.
- [ ] قياس before/after على Windows وفق `docs/qa_maintenance/windows_first_performance_qa.md`، مع زمن الاختبارات القديمة والجديدة منفصلًا.
- [ ] تحديث وثائق التقنية/QA المالكة، ومراجعة العقود وتعديلها عند تغير قانون دائم فقط؛ تحديث Graphify عند تعديل الكود.
- [ ] تحديث current_gate وremaining_estimate وحالة الأب عند إغلاق كل بوابة مع دليل؛ التحقق التفاعلي الشامل لا يغلق قبل 97l.

## Acceptance criteria and success scenarios

- [ ] بعد تحميل نفس المورد، 20 دورة resize عبر compact/wide مع theme/rebuild/remount لا تنتج أي استدعاء Agent إضافي.
- [ ] مستهلكان لنفس الطلب الجاري يشتركان في طلب واحد؛ أجهزة أو queries مختلفة لا تتداخل.
- [ ] حدث تحديث أو تغيير جهاز أو refresh مشروع يجلب/يحدّث مرة حسب العقد؛ جميع الأحداث الضرورية تظهر مرتبة.

## Definition of Done

- [ ] جميع معايير القبول مثبتة باختبارات/قياسات قابلة للتكرار وليس فحص الكود فقط.
- [ ] تسجيل ملفات الاختبارات المنفذة فعلًا ونتائجها وزمنها، ومراجعة diff والأسرار والمخرجات المولدة.
- [ ] توثيق المتبقي أو التأجيل وأثره على القبول النهائي؛ لا نسبة تحسن بلا baseline صالح.
- [ ] لا commit أو push أو تغيير runtime source قبل التفويض المناسب؛ الخطة مراجعة؛ يبدأ التنفيذ على Windows وفق الاعتماديات وميزانيات 97a، وإذن التسليم الحالي لا يشمل commits التنفيذ اللاحقة.

## Evidence

Pending Windows execution. No implementation or performance result is claimed by this planning file.
