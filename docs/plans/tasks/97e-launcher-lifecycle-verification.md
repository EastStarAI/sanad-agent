---
title: "97e: الملكية والاسترداد ودورة الحياة"
status: planned
current_gate: G0
remaining_estimate: "100% of this task; historical work is reconciled in G0"
platforms: windows-first
parent_plan: docs/plans/97-windows-first-agent-client-performance.md
depends_on: "97c, 97d"
---

# 97e — الملكية والاسترداد ودورة الحياة

## Goal

التحقق من stale recovery المدمج وعزل مشكلة Job Object دون إضعاف الاحتواء.

## Locked scope and ownership

- جميع negative cases ومعايير القبول غير المثبتة من stale-launcher المتقاعد مملوكة هنا. توفيق مراجعة الأمن والتسليم السابق بدل إنشاء PR مكرر؛ أي تغيير جديد يحتفظ بمتطلبات الحماية.

- التصميم والقبول العام: `docs/plans/97-windows-first-agent-client-performance.md`.
- الأسطح/المراجع المالكة: `docs/plans/done/sanad-dev-stale-launcher-recovery.md`، `docs/technical/sanad_dev_runtime_ownership.md`.
- التنفيذ والقياس على Windows؛ لا تُستبدل أدلته بنتائج جهاز أسرع. تحقق بقية المنصات بعد نجاح Windows في 97k/97l.
- لا إعادة تنفيذ إصلاح مدمج أو منافسة مهمة نشطة؛ مراجعة المصدر والأدلة الحالية أولًا.
- لا إضعاف للأمان أو durability أو ترتيب الأحداث أو حداثة الواجهة. تغيير كبير منخفض العائد يؤجل بقرار موثق، لا إغلاق زائف.

## Gates

### G0 — التحقق وخط الأساس

- [ ] مراجعة العقود الأقرب والكود والاختبارات وحالة الاعتماديات، وتحديد reproduction حتمي.
- [ ] تسجيل baseline ومعايير الأداء الرقمية المعتمدة من 97a قبل تعديل الكود أو إضافة الاختبارات.

### G1 — العمل المحدد

- [ ] توفيق بوابات ملف stale recovery مع أدلة الدمج والاختبار الحي السابق.
- [ ] اختبار no-components/Agent-only/Client-only/both وPID reuse وnonce mismatch وforeign Home/source وخروج جزئي ورفض daemon.
- [ ] فصل agent-origin kill-on-close عن تشغيل الطرفية البشرية؛ لا breakaway عام ولا kill يدوي ولا cleanup ضمني داخل run.
- [ ] إذا ثبت احتياج lifecycle handoff جديد، إنتاج قرار تصميم ومراجعة أمنية مستقلة قبل تنفيذه؛ تبقى بوابته معلقة بدل ادعاء الحل.

### G2 — التحقق والأدلة

- [ ] format/analyzer عبر FVM ينجحان قبل الاختبارات؛ focused tests ثم full fast/integration بحسب نطاق التغيير.
- [ ] قياس before/after على Windows وفق `docs/qa_maintenance/windows_first_performance_qa.md`، مع زمن الاختبارات القديمة والجديدة منفصلًا.
- [ ] تحديث وثائق التقنية/QA المالكة، ومراجعة العقود وتعديلها عند تغير قانون دائم فقط؛ تحديث Graphify عند تعديل الكود.
- [ ] تحديث current_gate وremaining_estimate وحالة الأب عند إغلاق كل بوابة مع دليل؛ التحقق التفاعلي الشامل لا يغلق قبل 97l.

## Acceptance criteria and success scenarios

- [ ] لا signal أو حذف lease قبل ثبوت الملكية والخروج؛ الفشل يبقي الأدلة ويعود nonzero.
- [ ] اختبارات دورة الحياة الآلية خضراء على Windows؛ دورة Agent+Client التفاعلية الكاملة محفوظة للبوابة الأخيرة.

## Definition of Done

- [ ] جميع معايير القبول مثبتة باختبارات/قياسات قابلة للتكرار وليس فحص الكود فقط.
- [ ] تسجيل ملفات الاختبارات المنفذة فعلًا ونتائجها وزمنها، ومراجعة diff والأسرار والمخرجات المولدة.
- [ ] توثيق المتبقي أو التأجيل وأثره على القبول النهائي؛ لا نسبة تحسن بلا baseline صالح.
- [ ] لا commit أو push أو تغيير runtime source قبل التفويض المناسب؛ الخطة مراجعة؛ يبدأ التنفيذ على Windows وفق الاعتماديات وميزانيات 97a، وإذن التسليم الحالي لا يشمل commits التنفيذ اللاحقة.

## Evidence

Pending Windows execution. No implementation or performance result is claimed by this planning file.
