---
title: "97c: استكمال التحقق من الكتابة الآمنة"
status: planned
current_gate: G0
remaining_estimate: "100% of this task; historical work is reconciled in G0"
platforms: windows-first
parent_plan: docs/plans/97-windows-first-agent-client-performance.md
depends_on: "97a"
---

# 97c — استكمال التحقق من الكتابة الآمنة

## Goal

إثبات الإصلاح المدمج وتغطية الفجوات الأمنية/الأدائية المتبقية فقط على Windows.

## Locked scope and ownership

- تفاصيل الالتزامات الأمنية والقياسات المنقولة بالكامل موجودة في سجل secure-runtime-file القديم؛ helper nonzero يترجم إلى native-backend failure حيث لم يعد helper مستخدمًا، مع بقاء invariant نفسه.

- التصميم والقبول العام: `docs/plans/97-windows-first-agent-client-performance.md`.
- الأسطح/المراجع المالكة: `docs/plans/done/sanad-dev-windows-secure-runtime-file-performance.md`.
- التنفيذ والقياس على Windows؛ لا تُستبدل أدلته بنتائج جهاز أسرع. تحقق بقية المنصات بعد نجاح Windows في 97k/97l.
- لا إعادة تنفيذ إصلاح مدمج أو منافسة مهمة نشطة؛ مراجعة المصدر والأدلة الحالية أولًا.
- لا إضعاف للأمان أو durability أو ترتيب الأحداث أو حداثة الواجهة. تغيير كبير منخفض العائد يؤجل بقرار موثق، لا إغلاق زائف.

## Gates

### G0 — التحقق وخط الأساس

- [ ] مراجعة العقود الأقرب والكود والاختبارات وحالة الاعتماديات، وتحديد reproduction حتمي.
- [ ] تسجيل baseline ومعايير الأداء الرقمية المعتمدة من 97a قبل تعديل الكود أو إضافة الاختبارات.

### G1 — العمل المحدد

- [ ] توفيق ملف المهمة القديم مع الإصلاح المدمج والأدلة المتاحة، دون افتراض اكتمال CI أو المراجعة من رسالة commit.
- [ ] قياس hardening/new/replace/append/read وعدد العمليات p50/p95 بارد/دافئ؛ لا إعادة backend المنفذ.
- [ ] استكمال ACL والروابط والهروب من الجذر والقراءة/الكتابة المتزامنة والانقطاع والملف المقفول والحذف المباشر والتنظيف بعد الفشل.
- [ ] تحديث حالات الاختبارات القديمة التي تفترض PowerShell helper لتختبر الفشل الأصلي للـFFI؛ لا إسقاط assertion أمني.

### G2 — التحقق والأدلة

- [ ] format/analyzer عبر FVM ينجحان قبل الاختبارات؛ focused tests ثم full fast/integration بحسب نطاق التغيير.
- [ ] قياس before/after على Windows وفق `docs/qa_maintenance/windows_first_performance_qa.md`، مع زمن الاختبارات القديمة والجديدة منفصلًا.
- [ ] تحديث وثائق التقنية/QA المالكة، ومراجعة العقود وتعديلها عند تغير قانون دائم فقط؛ تحديث Graphify عند تعديل الكود.
- [ ] تحديث current_gate وremaining_estimate وحالة الأب عند إغلاق كل بوابة مع دليل؛ التحقق التفاعلي الشامل لا يغلق قبل 97l.

## Acceptance criteria and success scenarios

- [ ] لا subprocess خاص بـPowerShell للكتابة الآمنة، والنتيجة أقل من ثانيتين أو تحسن الوسيط 50% على القياس المتكافئ.
- [ ] owner-only وatomic publication وdurability محفوظة؛ مراجعة أمنية لأي تغيير جديد يمس الحد.

## Definition of Done

- [ ] جميع معايير القبول مثبتة باختبارات/قياسات قابلة للتكرار وليس فحص الكود فقط.
- [ ] تسجيل ملفات الاختبارات المنفذة فعلًا ونتائجها وزمنها، ومراجعة diff والأسرار والمخرجات المولدة.
- [ ] توثيق المتبقي أو التأجيل وأثره على القبول النهائي؛ لا نسبة تحسن بلا baseline صالح.
- [ ] لا commit أو push أو تغيير runtime source قبل التفويض المناسب؛ الخطة مراجعة؛ يبدأ التنفيذ على Windows وفق الاعتماديات وميزانيات 97a، وإذن التسليم الحالي لا يشمل commits التنفيذ اللاحقة.

## Evidence

Pending Windows execution. No implementation or performance result is claimed by this planning file.
