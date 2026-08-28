---
title: "Run Cancellation and Process Ownership"
description: "العقد التقني لإلغاء جولة الوكيل إلغاءً محدود الزمن، ومقاطعة المزود والأداة، وامتلاك شجرة العمليات، وتثبيت نتيجة نهائية متطابقة حيًا وتاريخيًا."
---

# Run Cancellation and Process Ownership

## 1. الغرض

يعرّف هذا العقد السلوك المطلوب عند قبول Stop لجولة وكيل نشطة. لا يكفي ضبط
علامة منطقية أو الفوز بسباق انتظار؛ الإلغاء الناجح يقطع الموارد المملوكة،
يثبت نتيجة نهائية واحدة، ويعيد الجلسة إلى حالة مستقرة خلال حدود زمنية معلومة.

ترتيب السلطة هو:

```text
accept Stop
  -> invalidate run publication
  -> cancel owned provider/tool resources
  -> escalate and verify cleanup
  -> persist canonical terminal state
  -> publish terminal events
  -> publish stopped, then idle
```

## 2. هوية الجولة ونطاق الإلغاء

كل تشغيل نشط يملك `run_id` و`generation` ونطاق إلغاء واحدًا. يحمل النطاق:

- حالة `active | cancelling | cancelled | cleanup_failed | completed`.
- سبب الإلغاء وأول وقت لقبوله.
- registrations للموارد التي بدأت داخل الجولة.
- عملية إلغاء مشتركة تنضم إليها طلبات Stop المكررة.
- عملية Stop مشتركة على مستوى الجلسة تمنع طلبين متزامنين من تكرار terminalization أو حدث `stopped`.
- بوابة نشر تُغلق تزامنيًا عند invalidation.

كل registration تنتقل مرة واحدة:

```text
registered -> released
registered -> cancelling -> cancelled
registered -> cancelling -> cleanup_failed
```

`release` تعني انتقال الملكية أو اكتمال المورد، وليست إلغاءً. لا تنجح إلا بعد
اكتمال طبيعي أو إثبات مالك جديد. الوصول المتأخر إلى registration محررة أو
ملغاة عملية idempotent بلا side effect.

أي registration تصل أثناء cancellation تنضم إلى مهلة cleanup الأصلية. وإذا
اكتمل terminal report قبل وصول registration متسابقة، تُشغّل cleanup الخاصة بها
مرة واحدة فور التسجيل كي لا يبقى المورد orphan، من دون إعادة فتح التقرير النهائي.

## 3. الإلغاء المحدود والنتائج

قبول Stop لا ينتظر مزودًا أو أداة بلا حد. لكل طبقة deadline مستقلة، وتبقى
النتيجة النهائية typed:

- `cancelled`: توقف المورد وثبت cleanup.
- `timed_out`: انتهت مهلة التشغيل الأصلية واستخدمت مسار التنظيف نفسه.
- `cleanup_failed`: أغلقت الجلسة مسار النشر لكن تعذر إثبات زوال المورد.
- `ownership_lost`: لم تعد بصمة المورد تطابق الملكية المسجلة، لذلك لم يُرسل kill.

انتهاء deadline لا يثبت زوال المورد تلقائيًا. تبقى diagnostics والملكية
واضحتين، ولا تعرض الواجهة spinner غير محدود.

## 4. ملكية طلب المزود

كل provider turn تسجل handle يمكنها إغلاق request/stream والاشتراكات التابعة
لها. يغلق invalidation بوابة chunks والنتائج أولًا، ثم يبدأ transport cleanup.

تنطبق المحددات التالية:

- لا chunk أو usage أو finish callback من generation ملغاة تعدل المحادثة.
- إغلاق stream والـHTTP request وفك listeners جزء من cleanup.
- user Stop وwatchdog وفشل النقل تتنافس على terminal compare-and-set واحدة.
- Future متأخرة تُستهلك داخليًا لمنع تسريب خطأ غير معالج، دون نشرها.

## 5. ملكية الأداة والعملية

يحمل `ToolContext` هوية الجولة ونطاقها. تسجل الأداة cleanup قبل بدء side
effect، وتعلن إذا كانت لا تدعم الإلغاء التعاوني.

بالنسبة إلى shell، تنشأ containment مملوكة منذ spawn:

- Linux: process group مستقلة يقودها الأمر المملوك عبر `setsid sh -c`، مما
  يفصل جلسة الطفل عن جلسة الـ daemon تمامًا ويمنع وصول `/dev/tty`.
- macOS: wrapper صغيرة تستدعي `setpgrp` قبل `exec sh -c`، فتمنح الأمر process
  group مستقلة قبل تنفيذ محتوى المستخدم.
- Windows: Job Object ذات `kill-on-close` هي containment الأساسية، ويستخدم
  `taskkill /T /F` fallback صريحًا فقط إذا تعذر إنشاء الـJob أو إلحاق العملية.
- تحفظ بصمة تضم PID وهوية وقت البدء الفعلية وهوية containment. يعاد فحص هوية
  البدء قبل الإشارة المتأخرة، لا مجرد اختبار أن رقم PID ما زال حيًا.

قيود إضافية على الأنظمة الشبيهة بـUnix لمنع تعليق الأوامر غير التفاعلية:

- **إغلاق stdin فورًا:** أوامر الوكيل غير تفاعلية؛ إغلاق stdin يمنع انتظار
  إدخال لوحة المفاتيح إلى الأبد (مثل `read` أو `git` قبل تكوين credentials).
- **تقليل مسارات المطالبات:** `GIT_TERMINAL_PROMPT=0` يمنع مطالبة git عبر
  الطرفية، و`SSH_ASKPASS_REQUIRE=never` يمنع ssh من تشغيل askpass.
- **إنهاء المجموعة المملوكة:** على Linux وmacOS تُرسل `TERM` ثم `KILL` إلى
  PGID السالبة التي أنشأها wrapper. استقلال هذه المجموعة عن مجموعة الـdaemon
  هو حد الأمان الذي يمنع وصول الإشارة إلى الوكيل أو المشرف.
- **الاكتمال الطبيعي:** خروج wrapper لا يحرر الملكية فورًا؛ يفحص controller
  containment ويُنهي أي descendants باقية قبل نشر نجاح الأداة وإغلاق pipes.

مسار الإنهاء:

```text
close publication
  -> TERM containment
  -> drain stdout/stderr during bounded grace
  -> KILL remaining containment
  -> verify exit and fingerprint
  -> terminalize once
```

فحص PPID أداة تشخيص أو fallback فقط؛ لا يمثل حد الملكية الأساسي. عدم تطابق
البصمة يمنع قتل PID ربما أعيد استخدامها.

## 6. النتيجة النهائية وتطابق العرض

تستخدم حالة الأداة النهائية schema canonical واحدة للبث الحي والتاريخ:

```text
tool_call_id, run_id, generation, revision
status, reason, message
cleanup_outcome, started_at, terminal_at
```

القواعد:

1. تغلق بوابة progress قبل بدء cleanup.
2. تستهلك output الداخلية المتأخرة دون نشر.
3. تثبت الرسالة وحالة tool terminal في معاملة منطقية واحدة.
4. ينبعث الحدث الحي من payload المثبتة نفسها.
5. يقبل reducer في العميل revision الأحدث فقط ويطبق الحدث idempotently.
6. حدث `stopped` دفاع أخير لإنهاء projection قديمة، لا بديل عن terminal event.

لهذا يجب أن تكون الشاشة الحالية، وإعادة الاتصال، والانتقال ثم العودة، وإعادة
تحميل التاريخ متطابقة من دون أن يكون navigation آلية إصلاح.

## 7. حدود Plan 54

العملية foreground تبقى مسجلة في نطاق الجولة افتراضيًا. يمكن لنظام المهام
الخلفية تحرير registration فقط بعد durable owner claim ناجحة. Stop الجولة لا
تستهدف registration محررة، بينما إلغاء المهمة الخلفية يستخدم المالك الجديد
ونفس process controller. لا يضيف هذا العقد سجل مهام خلفية أو wake timers.

## 8. محددات التحقق

- طلب مزود لا يرد ينقطع ضمن الحد ولا يمنع `idle`.
- أداة معلقة تنشر terminal واحدة ولا تنتظر timeout الأصلي.
- parent وchild وgrandchild تختفي بعد cleanup ناجح.
- child المقاومة لـTERM تختفي بعد escalation.
- exit وStop وtimeout المتزامنة لا تنتج أكثر من terminal.
- late output لا تعيد tool إلى running ولا تختلف بين live/history.
- repeated Stop وPID mismatch وcleanup failure لها نتائج ثابتة وقابلة للاستعادة.
