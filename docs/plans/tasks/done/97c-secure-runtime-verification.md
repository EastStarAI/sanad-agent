---
title: "97c: استكمال التحقق من الكتابة الآمنة"
status: completed
current_gate: closed
remaining_estimate: "0% for 97c; protected review authorization and cross-platform verification remain owned by integration and 97k/97l"
platforms: windows-first
parent_plan: docs/plans/97-windows-first-agent-client-performance.md
depends_on: "97a"
---

# 97c — استكمال التحقق من الكتابة الآمنة

## Goal

إثبات الإصلاح المدمج وتغطية الفجوات الأمنية/الأدائية المتبقية فقط على Windows.

## Locked scope and ownership

- Current user authorization: final independent review/repair/closure uses Sanad with ChatGPT `gpt-5.6-sol`, execution rooted in this task worktree and the primary Sanad Home. Accepted scoped work may be committed/pushed on this task branch; hand off the accepted commit for Plan97 integration rather than writing concurrently in the aggregation worktree. No protected review label or runtime source switch is authorized. This supersedes the historical planning-only delivery restriction below.

- تفاصيل الالتزامات الأمنية والقياسات المنقولة بالكامل موجودة في سجل secure-runtime-file القديم؛ helper nonzero يترجم إلى native-backend failure حيث لم يعد helper مستخدمًا، مع بقاء invariant نفسه.

- التصميم والقبول العام: `docs/plans/97-windows-first-agent-client-performance.md`.
- الأسطح/المراجع المالكة: `docs/plans/done/sanad-dev-windows-secure-runtime-file-performance.md`.
- التنفيذ والقياس على Windows؛ لا تُستبدل أدلته بنتائج جهاز أسرع. تحقق بقية المنصات بعد نجاح Windows في 97k/97l.
- لا إعادة تنفيذ إصلاح مدمج أو منافسة مهمة نشطة؛ مراجعة المصدر والأدلة الحالية أولًا.
- لا إضعاف للأمان أو durability أو ترتيب الأحداث أو حداثة الواجهة. تغيير كبير منخفض العائد يؤجل بقرار موثق، لا إغلاق زائف.

## Gates

### G0 — التحقق وخط الأساس

- [x] مراجعة العقود الأقرب والكود والاختبارات وحالة الاعتماديات، وتحديد reproduction حتمي (سباق الحذف الفوري للمستهلك على Windows).
- [x] تسجيل baseline ومعايير الأداء الرقمية المعتمدة من 97a قبل تعديل الكود أو إضافة الاختبارات (Win32 FFI cold 34.38ms, warm p50: 4.63ms, p95: 8.54ms مقابل >12,000ms لـPowerShell).

### G1 — العمل المحدد

- [x] توفيق ملف المهمة القديم مع الإصلاح المدمج والأدلة المتاحة، دون افتراض اكتمال CI أو المراجعة من رسالة commit.
- [x] قياس hardening/new/replace/append/read وعدد العمليات p50/p95 بارد/دافئ؛ لا إعادة backend المنفذ.
- [x] استكمال ACL والروابط والهروب من الجذر والقراءة/الكتابة المتزامنة والملف المقفول والحذف المباشر وتنظيف كل فشل داخل العملية. لا يدّعي الإغلاق أن قتل العملية قسرًا ينفّذ `finally`؛ قد يترك ملفًا مؤقتًا عشوائي الاسم لكنه يبقى owner-only وغير منشور، وقد صُححت الوثيقة التقنية كي لا تدّعي خلاف ذلك.
- [x] تحديث حالات الاختبارات القديمة التي تفترض PowerShell helper لتختبر الفشل الأصلي للـFFI؛ لا إسقاط assertion أمني.

### G2 — التحقق والأدلة

- [x] format/analyzer عبر FVM ينجحان قبل الاختبارات؛ شغّل المراجع المستقل الاختبارات المركزة فقط بحسب النطاق (11 اختبارًا ناجحًا في نحو 1.2 ثانية داخل الاختبار).
- [x] قياس matched parent/current على Windows وفق `docs/qa_maintenance/windows_first_performance_qa.md`، مع 3×30 عينة دافئة لكل تنفيذ وعزل FVM عن زمن الحالة.
- [x] تحديث وثائق التقنية/QA المالكة ومراجعة العقود؛ لا يوجد Graphify corpus في هذه الـworktree كي يحدّث.
- [x] تحديث current_gate وremaining_estimate وحالة الأب مع الدليل؛ التحقق التفاعلي الشامل يبقى في 97l.

## Acceptance criteria and success scenarios

- [x] لا subprocess خاص بـPowerShell في مسار Windows الإنتاجي، والنتيجة أقل كثيرًا من ثانيتين: في إعادة المراجعة المستقلة كان p50 للكتابة المتكافئة 14.926–16.638ms وp95 ‏19.723–21.347ms.
- [x] owner-only وatomic publication وwrite-through محفوظة، وحذف المستهلك الفوري لا يحول نجاح النشر إلى فشل زائف. تبقى `security-reviewed` label مطلوبة للدمج ولا يملك هذا التفويض إضافتها.

## Definition of Done

- [x] جميع معايير القبول مثبتة باختبارات وقياسات قابلة للتكرار، مع فصل القياس المتكافئ عن توصيف العمليات الحالي فقط.
- [x] تسجيل ملفات الاختبارات المنفذة فعلًا ونتائجها وزمنها، ومراجعة diff والأسرار والمخرجات المولدة.
- [x] توثيق المتبقي وأثره على القبول النهائي؛ لا نسبة تحسن بلا baseline صالح.
- [x] التفويض الحالي يجيز commit/push لهذا التغيير المقبول فقط؛ لم يحدث runtime source switch أو تعديل في worktree التجميع.

## Evidence

- **Windows host:** Intel Core i9-9880H, Windows 11 Pro 64-bit, Flutter 3.47.0, Dart 3.13.0.
- **Matched parent/current comparison:** ثلاث جولات، في كل منها عينة باردة و30 عينة دافئة، وبنفس الجهاز والـSDK والـpayload. Parent p50=13.338–15.846ms وp95=23.913–26.302ms؛ Current p50=14.926–16.638ms وp95=19.723–21.347ms. فرق الوسيط الصغير داخل ضوضاء p95 ولا يثبت regression، وكلاهما أقل كثيرًا من budget ‏2,000ms.
- **Current-only operation characterization (cold/p50/p95, ms; 1+30 samples):** directory-new 67.192/8.417/10.946؛ atomic-new 48.043/23.804/29.743؛ atomic-replace 31.808/25.654/36.387؛ append-new 10.418/18.731/29.303؛ read-existing 25.370/18.084/24.607. ليست هذه نسب before/after.
- **Independent verification:** `fvm dart analyze` نجح؛ `fvm dart test test/infrastructure/sanad_dev_secure_runtime_file_test.dart` نجح بـ11/11؛ formatting للملفين المعدلين لم يغيّر شيئًا. لم تُعد المراجعة تشغيل الـfull suite لأن التغيير محصور في الحد واختباره التكاملي المالك.
- **Security review:** فُحصت DACL المحمية، إزالة ACE الأجنبية، رفض junction/path escape، الذرية مع القراء/الكتاب، الوجهة المقفولة، تنظيف failure داخل العملية، native typed failures، والحذف الفوري. صُحح الادعاء الوثائقي: القتل القسري لا يضمن تنفيذ `finally`، لكنه لا ينشر partial destination؛ تبقى الوجهة السابقة بلا تغيير والملف المؤقت يُنشأ owner-only قبل كتابة payload.
- **Residual integration gates:** protected `security-reviewed` authorization، hosted POSIX/Windows lanes في 97k، والتحقق التفاعلي في 97l؛ لا تُسجل كعمل متبقٍ داخل 97c.
