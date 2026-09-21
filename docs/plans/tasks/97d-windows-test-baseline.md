---
title: "97d: موثوقية اختبارات أدوات التشغيل"
status: planned
current_gate: G0
remaining_estimate: "100% of this task; historical work is reconciled in G0"
platforms: windows-first
parent_plan: docs/plans/97-windows-first-agent-client-performance.md
depends_on: "97a"
---

# 97d — موثوقية اختبارات أدوات التشغيل

## Goal

إصلاح fixtures والتوقيت والتنظيف على Windows دون إضعاف سلوك المنتج.

## Locked scope and ownership

- جميع بنود G1–G4 من سجل cross-platform-test-baseline المتقاعد ضمن النطاق، بما فيها foreign shim/install --force وartifact fingerprint/executable/locked reuse؛ لا يكتفى بعناوينها المختصرة هنا.

- التصميم والقبول العام: `docs/plans/97-windows-first-agent-client-performance.md`.
- الأسطح/المراجع المالكة: `docs/plans/done/sanad-dev-cross-platform-test-baseline-reliability.md`، `docs/qa_maintenance/test_suite_performance_qa.md`.
- التنفيذ والقياس على Windows؛ لا تُستبدل أدلته بنتائج جهاز أسرع. تحقق بقية المنصات بعد نجاح Windows في 97k/97l.
- لا إعادة تنفيذ إصلاح مدمج أو منافسة مهمة نشطة؛ مراجعة المصدر والأدلة الحالية أولًا.
- لا إضعاف للأمان أو durability أو ترتيب الأحداث أو حداثة الواجهة. تغيير كبير منخفض العائد يؤجل بقرار موثق، لا إغلاق زائف.

## Gates

### G0 — التحقق وخط الأساس

- [ ] مراجعة العقود الأقرب والكود والاختبارات وحالة الاعتماديات، وتحديد reproduction حتمي.
- [ ] تسجيل baseline ومعايير الأداء الرقمية المعتمدة من 97a قبل تعديل الكود أو إضافة الاختبارات.

### G1 — العمل المحدد

- [ ] تصنيف كل فشل: منتج، fixture، startup، timeout، تنازع أو تسرب مورد؛ تصنيف unit/filesystem/OS/exclusive.
- [ ] إصلاح المسارات والملكية وUnicode/spaces/drive/UNC ضمن دعم المنتج؛ لا تعديل production لدعم fixture خاطئة.
- [ ] إثبات إغلاق journals وخروج العمليات وتحرير المنافذ دون sleeps ثابتة؛ التتابع فقط للموارد الحصرية.
- [ ] قياس wrappers/artifact reuse/AOT background args؛ تجهيز فحوصات المنصات الأخرى دون اشتراط تشغيلها قبل إغلاق Windows.

### G2 — التحقق والأدلة

- [ ] format/analyzer عبر FVM ينجحان قبل الاختبارات؛ focused tests ثم full fast/integration بحسب نطاق التغيير.
- [ ] قياس before/after على Windows وفق `docs/qa_maintenance/windows_first_performance_qa.md`، مع زمن الاختبارات القديمة والجديدة منفصلًا.
- [ ] تحديث وثائق التقنية/QA المالكة، ومراجعة العقود وتعديلها عند تغير قانون دائم فقط؛ تحديث Graphify عند تعديل الكود.
- [ ] تحديث current_gate وremaining_estimate وحالة الأب عند إغلاق كل بوابة مع دليل؛ التحقق التفاعلي الشامل لا يغلق قبل 97l.

## Acceptance criteria and success scenarios

- [ ] مجموعة sanad-dev كاملة خضراء على Windows مرتين دون تجاهل حالات Windows المدعومة.
- [ ] لا عملية أو منفذ أو journal lock أو lease مؤقت متسرب، ولا زيادة عامة للمهل.

## Definition of Done

- [ ] جميع معايير القبول مثبتة باختبارات/قياسات قابلة للتكرار وليس فحص الكود فقط.
- [ ] تسجيل ملفات الاختبارات المنفذة فعلًا ونتائجها وزمنها، ومراجعة diff والأسرار والمخرجات المولدة.
- [ ] توثيق المتبقي أو التأجيل وأثره على القبول النهائي؛ لا نسبة تحسن بلا baseline صالح.
- [ ] لا commit أو push أو تغيير runtime source قبل التفويض المناسب؛ الخطة مراجعة؛ يبدأ التنفيذ على Windows وفق الاعتماديات وميزانيات 97a، وإذن التسليم الحالي لا يشمل commits التنفيذ اللاحقة.

## Evidence

Pending Windows execution. No implementation or performance result is claimed by this planning file.
