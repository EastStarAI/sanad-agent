---
title: "97g: جاهزية المزودين وتحميل الأجهزة"
status: planned
current_gate: G0
remaining_estimate: "100% of this task; historical work is reconciled in G0"
platforms: windows-first
parent_plan: docs/plans/97-windows-first-agent-client-performance.md
depends_on: "97f"
---

# 97g — جاهزية المزودين وتحميل الأجهزة

## Goal

منع العرض الكاذب لغياب الأجهزة أو المزودين أثناء التحميل وتحسين جاهزية Windows.

## Locked scope and ownership

- التصميم والقبول العام: `docs/plans/97-windows-first-agent-client-performance.md`.
- الأسطح/المراجع المالكة: `client/lib/features/devices/presentation/screens/onboarding_setup_screen.dart`، `client/lib/features/devices/presentation/bloc/device_state.dart`، `docs/product/settings_hub.md`.
- التنفيذ والقياس على Windows؛ لا تُستبدل أدلته بنتائج جهاز أسرع. تحقق بقية المنصات بعد نجاح Windows في 97k/97l.
- لا إعادة تنفيذ إصلاح مدمج أو منافسة مهمة نشطة؛ مراجعة المصدر والأدلة الحالية أولًا.
- لا إضعاف للأمان أو durability أو ترتيب الأحداث أو حداثة الواجهة. تغيير كبير منخفض العائد يؤجل بقرار موثق، لا إغلاق زائف.

## Gates

### G0 — التحقق وخط الأساس

- [ ] مراجعة العقود الأقرب والكود والاختبارات وحالة الاعتماديات، وتحديد reproduction حتمي.
- [ ] تسجيل baseline ومعايير الأداء الرقمية المعتمدة من 97a قبل تعديل الكود أو إضافة الاختبارات.

### G1 — العمل المحدد

- [ ] تقسيم bootstrap/DB/credentials/catalog/runtime_check/list/UI؛ إصلاح تأخر الوكيل قبل الاكتفاء بتغيير الواجهة.
- [ ] حالات typed واضحة loading/ready-empty/ready/error/stale، وعدم اعتبار timeout نتيجة فارغة authoritative.
- [ ] تمرير isLoadingFromBackend إلى شاشة اختيار الأجهزة ومسار التوجيه؛ اختبار الهاتف ضمن widget tests على Windows.
- [ ] تغطية بيانات مخزنة قديمة، بدء جديد، reconnect، استجابة متأخرة من جهاز سابق، وانتقال تحميل إلى فارغ صحيح.

### G2 — التحقق والأدلة

- [ ] format/analyzer عبر FVM ينجحان قبل الاختبارات؛ focused tests ثم full fast/integration بحسب نطاق التغيير.
- [ ] قياس before/after على Windows وفق `docs/qa_maintenance/windows_first_performance_qa.md`، مع زمن الاختبارات القديمة والجديدة منفصلًا.
- [ ] تحديث وثائق التقنية/QA المالكة، ومراجعة العقود وتعديلها عند تغير قانون دائم فقط؛ تحديث Graphify عند تعديل الكود.
- [ ] تحديث current_gate وremaining_estimate وحالة الأب عند إغلاق كل بوابة مع دليل؛ التحقق التفاعلي الشامل لا يغلق قبل 97l.

## Acceptance criteria and success scenarios

- [ ] لا Provider setup required لمجرد عدم انتهاء hydration، ولا No devices أثناء جلب القائمة.
- [ ] خطأ الجلب لا يمحو بيانات صالحة ولا يتسبب logout؛ التحميل واضح وغير متحرك على Windows ضمن السياسة المتفق عليها.

## Definition of Done

- [ ] جميع معايير القبول مثبتة باختبارات/قياسات قابلة للتكرار وليس فحص الكود فقط.
- [ ] تسجيل ملفات الاختبارات المنفذة فعلًا ونتائجها وزمنها، ومراجعة diff والأسرار والمخرجات المولدة.
- [ ] توثيق المتبقي أو التأجيل وأثره على القبول النهائي؛ لا نسبة تحسن بلا baseline صالح.
- [ ] لا commit أو push أو تغيير runtime source قبل التفويض المناسب؛ الخطة مراجعة؛ يبدأ التنفيذ على Windows وفق الاعتماديات وميزانيات 97a، وإذن التسليم الحالي لا يشمل commits التنفيذ اللاحقة.

## Evidence

Pending Windows execution. No implementation or performance result is claimed by this planning file.
