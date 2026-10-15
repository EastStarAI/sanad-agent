---
title: "99: تعافي بيئات التشغيل اليتيمة وأمان إعادة التشغيل التفاعلي في sanad-dev"
status: completed
current_gate: G2
remaining_estimate: "0% of this task; implementation and verification completed successfully"
platforms: windows-first
parent_plan: "none"
depends_on: "none"
---

# 99 — تعافي بيئات التشغيل اليتيمة وأمان إعادة التشغيل التفاعلي في sanad-dev

## Goal

معالجة الشلل والانسداد الكامل (Deadlock) في أداة `sanad-dev` الناتج عن موت مشغل بيئة التشغيل، ومنع `exit(1)` القاتل عند إعادة تشغيل الوكيل تفاعلياً بمفتاح `R`، وتمكين `--force` في `sanad-dev stop` من تحرير وتصفية العمليات وسجلات العقود اليتيمة (`orphaned runtimes`) بأمان ودون المساس بالورك تري المجاورة.

## Locked scope and ownership

- **الملكية والمسطح المعني:** حزمة `scripts/sanad_dev` (تحديداً `switch_controller.dart`, `developer_agent.dart`, `instance_selection.dart`, `runtime_stop.dart`).
- **سياق التسليم وتفويض المستخدم (PR Lifecycle & Delivery Authorization):**
  1. العمل معزول داخل ورك تري مستقلة وفرع مخصص `fix/99-orphaned-runtime-safety`.
  2. فوّض المستخدم صراحةً إتمام المراجعة النهائية، وتنفيذ `git commit` و `git push`، وإنشاء PR مستقل، ثم الدمج (Squash merge) بعد اجتياز فحوصات CI الخضراء.
  3. بعد الدمج فقط: مطابقة snapshot الأصلية خارج المستودع (`C:/Users/aatia/.sanad-delegations/task99/`)، وإزالة النسخة المحلية المطابقة وحدها وتحديث `main` في المستودع الرئيسي مع الحفاظ على أي تعديلات لاحقة ومجلد `.agent/`.
  4. تبقى بيئة العمل الرئيسية (`main`) دون أي مساس حتى ذلك الحين.
- **إثبات ملكية العمليات وحمايتها:**
  - التحقق الصارم من هوية عملية المشغل (`process identity`) ومطابقتها مع `launcherProcessIdentity` المسجلة في العقد قبل إنهاء الـ PID، لمنع قتل عمليات غريبة في حال تدوير الـ PIDs بواسطة نظام التشغيل (PID recycling).
  - التحقق الإلزامي من إثبات ملكية العمليات العميلة بالمعرف (`SANAD_DEV_LAUNCHER_ID`) و (`SANAD_DEV_RUNTIME_NONCE`) **معاً**؛ تطابق منفذ أو مسار فقط ليس إذنًا لقتل أي عملية.
  - حماية تامة لعملاء الورك تري الأخرى (`crossOwnedClients`) والعمليات التي لا تثبت هويتها واشتراط عدم المساس بها إطلاقاً.
  - عدم إضافة أي labels محمية دون تفويضها، وعدم تنفيذ stop/restart لأي runtime أو Client قيد التشغيل.

## Gates

### G0 — التحقيق وحصر المشكلة وتفريغ العمليات العالقة
- [x] فحص العمليات والمنافذ وتحليل سبب الشلل (PIDs: 1616 ميت، الوكيل 5816 و 22688، العميل 6968 و 19020).
- [x] إنهاء العمليات اليتيمة التابعة للورك تري الرئيسية وحذف ملف العقد العالق `dev/runtime-launcher-58085.json` لفك الانسداد.
- [x] التحقق من أن حالة الورك تري الرئيسية أصبحت `stopped` والورك تري الفرعية لا تزال `managed`.

### G1 — إصلاح الكود المصدري في sanad_dev
- [x] حماية إعادة التشغيل التفاعلي بمفتاح `R`/`r` في `switch_controller.dart` و `developer_agent.dart` بقفل (`_agentRestartInProgress`) لمنع الاستدعاء المتزامن المتكرر.
- [x] إضافة معيار `exitOnError` لـ `selectAgentInstance` و `handleAgentRestart` لمنع استدعاء `exit(1)` الصريح من قتل المشغل الحي أثناء مرحلة إعادة إقلاع الوكيل وتفريغ المنفذ.
- [x] تحديث `runtime_stop.dart` لتمكين خيار `--force` من تصفية العمليات اليتيمة المرتبطة بنفس مساحة العمل والمنفذ وإزالة سجلاتها بدلاً من الرفض العقيم.
- [x] فرض إثبات ملكية العمليات (`_collectProvenClientPids` و `processIdentity == launcherProcessIdentity`) قبل أي إنهاء للعمليات لمنع قتل عمليات نظام أو برامج أخرى أعيد استخدام معرفاتها.

### G2 — التحقق والاختبارات
- [x] تشغيل فحص التحليل الثابت `fvm dart analyze` على الحزمة: نجاح كامل (0 أخطاء و 0 تحذيرات).
- [x] إضافة واجتياز اختبارات انحدار في `sanad_dev_doctor_stop_test.dart`.
- [x] إضافة جناح اختبارات مستقل ومركز لأمان إثبات الملكية ومنع قتل العمليات الغريبة `sanad_dev_orphaned_runtime_stop_safety_test.dart` (3 اختبارات تغطي: مطابقة هوية المشغل، رفض إنهاء المشغل المدور، والتحقق من هوية العملاء وحماية العمليات الخارجية).
- [x] اجتياز جميع اختبارات حزمة `scripts/sanad_dev` (163 اختباراً ناجحاً و0 فاشل).
- [x] حفظ لقطة احتياطية snapshot وهويات الملفات في `C:/Users/aatia/.sanad-delegations/task99/`.
- [x] بقاء المستودع الرئيسي دون مساس.

## Acceptance criteria
- [x] لا يموت مشغل `sanad-dev run` عند الضغط على زر `R` أثناء إعادة إقلاع الوكيل بفضل `exitOnError: false` ومانع التكرار `_agentRestartInProgress`.
- [x] أمر `sanad-dev stop --force` قادر على إيقاف العمليات اليتيمة وإزالة العقد التالف بنجاح عند وجود `orphaned runtime`.
- [x] منع قتل أي عمليات خارجية أو عمليات تم تدوير أرقامها عبر فحص `processIdentity`.
- [x] الورك تري الفرعية تعمل دون أي تداخل في المنافذ أو البيانات.

## Definition of Done
- [x] اجتياز جميع اختبارات `scripts/sanad_dev` واختبارات فحص الحجم والتماسك `sanad_dev_size_guard_test.dart`.
- [x] بقاء التغييرات جاهزة في الورك تري `fix/99-orphaned-runtime-safety` دون عمل commit حتى اكتمال مراجعة agy والمستخدم.
- [x] توثيق التقرير النهائي وسياق التسليم.
