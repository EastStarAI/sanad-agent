---
title: "97j: مؤشرات نشاط ثابتة وخفض تكلفة رسم Windows"
status: planned
current_gate: G0
remaining_estimate: "100% of this task; historical work is reconciled in G0"
platforms: windows-first
parent_plan: docs/plans/97-windows-first-agent-client-performance.md
depends_on: "97h"
---

# 97j — مؤشرات نشاط ثابتة وخفض تكلفة رسم Windows

## Goal

إزالة الحمل المستمر الناتج عن مؤشرات الحركة على Windows مع إبقاء الحالة واضحة.

## Locked scope and ownership

- التصميم والقبول العام: `docs/plans/97-windows-first-agent-client-performance.md`.
- الأسطح/المراجع المالكة: `client/lib/features/conversations/presentation/widgets/sidebar/sidebar_conversation_row.dart`، `client/lib/features/conversations/presentation/widgets/tools`، `docs/product/client_interface.md`.
- التنفيذ والقياس على Windows؛ لا تُستبدل أدلته بنتائج جهاز أسرع. تحقق بقية المنصات المطلوب للدمج في 97l؛ 97k متابعة تقريرية غير مانعة بعد الدمج.
- لا إعادة تنفيذ إصلاح مدمج أو منافسة مهمة نشطة؛ مراجعة المصدر والأدلة الحالية أولًا.
- لا إضعاف للأمان أو durability أو ترتيب الأحداث أو حداثة الواجهة. تغيير كبير منخفض العائد يؤجل بقرار موثق، لا إغلاق زائف.

## Gates

### G0 — التحقق وخط الأساس

- [ ] مراجعة العقود الأقرب والكود والاختبارات وحالة الاعتماديات، وتحديد reproduction حتمي.
- [ ] تسجيل baseline ومعايير الأداء الرقمية المعتمدة من 97a قبل تعديل الكود أو إضافة الاختبارات، مع reproduction حي لمؤشر متحرك واحد صغير (`CircularProgressIndicator`) يثبت قفزة GPU المبلغ عنها من 0% إلى 100% ثم عودته عند اختفاء الحركة.

### G1 — العمل المحدد

- [ ] اعتماد بلاغ CPU +15–30% وGPU 0→100% مع مؤشر واحد واختفائه فور زواله كدليل مستخدم مثبت؛ القياس هنا لتحديد الحجم والتحقق لا لنفي المشكلة.
- [ ] إزالة الدوران والنبض المستمرين من حالات النشاط المعنية على Windows؛ نقطة خضراء ثابتة للجلسة العاملة بلا glow متحرك.
- [ ] حالات إنجليزية دقيقة Running/Completed/Failed/Cancelled/Waiting للأدوات، لا لون وحده ولا كلمة نجاح لأداة فشلت؛ مراجعة المؤشرات البديلة كيلا تنشئ ticker آخر.
- [ ] فحص آلية السياسة/الثيم الموجودة وإعادة استخدامها إن أمكن؛ مالك واحد فقط يحول platform إلى قرار دلالي مثل `allowContinuousActivityAnimation`، مع default ثابت على Windows وحركة المنصات الأخرى دون تغيير. لا framework جديد أو إعداد مستخدم إضافي.
- [ ] جميع المؤشرات المستهدفة تستهلك القرار أو مكونًا مشتركًا يستهلكه؛ ممنوع شروط Windows/OS داخل المستهلكين، وممنوع إنشاء AnimationController متكرر أصلًا في الوضع الثابت.
- [ ] اختبار السياسة مستقلًا واختبار المستهلكين بقيمتي القرار بغض النظر عن host OS؛ تغيير تعيين منصة أخرى إلى static في fixture يفعّل نفس السلوك دون تعديل widget. فصل build/paint/raster traces لالتقاط أي بقايا.

### G2 — التحقق والأدلة

- [ ] format/analyzer عبر FVM ينجحان قبل الاختبارات؛ focused tests ثم full fast/integration بحسب نطاق التغيير.
- [ ] قياس before/after على Windows وفق `docs/qa_maintenance/windows_first_performance_qa.md`، مع زمن الاختبارات القديمة والجديدة منفصلًا.
- [ ] تحديث وثائق التقنية/QA المالكة، ومراجعة العقود وتعديلها عند تغير قانون دائم فقط؛ تحديث Graphify عند تعديل الكود.
- [ ] تحديث current_gate وremaining_estimate وحالة الأب عند إغلاق كل بوابة مع دليل؛ التحقق التفاعلي الشامل لا يغلق قبل 97l.

## Acceptance criteria and success scenarios

- [ ] قرار platform-to-motion موجود لدى مالك واحد فقط؛ مراجعة المصدر تثبت عدم وجود فحوص منصة لهذا السلوك في المستهلكين.
- [ ] اختبار حقن السياسة static على منصة غير Windows ينتج نفس UI الثابت بلا ticker، دون تعديل كود المستهلكين.

- [ ] لا يبقى أي ticker/animation مستمر على Windows في الأسطح المشمولة، بما في ذلك `CircularProgressIndicator` صغير واحد؛ ليس القبول مقتصرًا على مؤشرات الأدوات أو الشريط الجانبي.
- [ ] إثبات حي before/after على الجهاز نفسه أن السيناريو الذي كان يقفز فيه GPU من 0% إلى 100% لم يعد يسبب القفزة بعد تطبيق السياسة الثابتة؛ تسجل قيم idle/activity/stabilized وCPU أيضًا، وتبقى حالات التنفيذ وaccessibility صحيحة.
- [ ] macOS/Linux لا تتغير سياستهما المرئية دون سبب مثبت؛ لا ادعاء إصلاح Flutter upstream غير محدد.

## Definition of Done

- [ ] جميع معايير القبول مثبتة باختبارات/قياسات قابلة للتكرار وليس فحص الكود فقط.
- [ ] تسجيل ملفات الاختبارات المنفذة فعلًا ونتائجها وزمنها، ومراجعة diff والأسرار والمخرجات المولدة.
- [ ] توثيق المتبقي أو التأجيل وأثره على القبول النهائي؛ لا نسبة تحسن بلا baseline صالح.
- [ ] لا commit أو push أو تغيير runtime source قبل التفويض المناسب؛ الخطة مراجعة؛ يبدأ التنفيذ على Windows وفق الاعتماديات وميزانيات 97a، وإذن التسليم الحالي لا يشمل commits التنفيذ اللاحقة.

## Evidence

Pending Windows execution. No implementation or performance result is claimed by this planning file.
