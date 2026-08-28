---
title: "Plan 50: Run-Scoped Cancellation and Stop Parity"
description: "خطة مظلة لجعل Stop يقطع طلبات المزود والأدوات والعمليات الفرعية فورًا، ويثبت terminal events متطابقة بين البث الحي والتاريخ المستعاد."
status: "pending"
priority: "critical"
related_to: "Plan 54 durable background terminal tasks and session wakeups"
reference_grounding: "required for tasks 50a-50f"
---

# Plan 50: الإلغاء الفعلي المتدرج وتطابق حالة Stop

## 1. الحالة والهدف

- الحالة: `pending` — الخطة جاهزة للمراجعة قبل بدء 50a.
- الأولوية: حرجة؛ الخلل قد يترك session في `stopping` وعمليات خارجية orphan.
- النطاق: Sanad Agent runtime، provider transports، tool execution، shell process trees، canonical events، وFlutter conversation projection.
- أسلوب التنفيذ: خطة مظلة تنجز عبر المهام `50a` إلى `50f` في `docs/plans/tasks/`.
- قيد الحجم: تستهدف كل مهمة فرعية تعديل 8–14 ملفًا، ولا تتجاوز 15 ملفًا دون تحديث هذه الخطة وموافقة المراجع.

الهدف هو تحويل Stop من flag يلاحظ بعد انتهاء العمل إلى إلغاء فعلي يقطع المورد الجاري، ثم ينشر نتيجة نهائية واحدة قابلة للاستعادة:

```text
Stop accepted
  -> invalidate run
  -> cancel provider/tool resource
  -> verify cleanup or report bounded cleanup failure
  -> persist cancelled work + terminal events
  -> emit terminal tool events
  -> emit stopped
  -> publish idle
```

## 1.1 الوقائع المثبتة

1. `AgentRunner.requestStop` يضبط flag فقط ولا يقطع Future أداة أو اتصال مزود.
2. `ActiveRun.requestStop` ينتظر `StreamSubscription.cancel`، وقد يظل هذا الانتظار مرتبطًا بالـFuture الجاري.
3. `ToolContext` لا يحمل cancellation scope.
4. provider adapters تنتظر `send` أو SSE stream دون handle يملكه الـrun لإغلاق الاتصال.
5. `shell_execute` يعزل process group عبر `setsid` ويقتل children وgrandchildren عند
   timeout على Linux، لكنه لا يربط هذا الاحتواء بعد بـStop، ولا يوفر controller
   موحدة أو ضمانًا مكافئًا لبقية المنصات.
6. حدث `stopped` في العميل ينهي thinking، لكنه لا يحول tool events الجارية إلى حالة terminal.
7. النتيجة المتأخرة قد تحفظ في التاريخ بعد invalidation من دون أن تصل إلى live projection، فتختلف الواجهة عن reload.

## 1.2 قاعدة التسليم والدمج

- يُنفَّذ Plan 50 بالكامل داخل **worktree معزول** واحد (فرع تجميعي مثل
  `feat/plan-50-run-cancellation`)؛ لا تُدمج أي مهمة فرعية أو gate على
  `main` أثناء التنفيذ.
- تُنفَّذ المهام `50a`–`50f` على نفس الفرع التجميعي داخل الـworktree، مع
  commits مرحلية اختيارية لكل gate مكتمل.
- لا يُفتح PR إلى `main` إلا بعد إغلاق **50f**، تجميع كل التغييرات في فرع
  واحد، ونجاح التحقق الكامل (analyzer + اختبارات مركزة + سيناريوهات QA
  المطلوبة).
- يبقى `main` نظيفًا حتى مراجعة بشرية وموافقة صريحة على PR التجميعي.

## 1.3 قاعدة إدارة التقدم

- كل مهمة تبدأ بـGate R0 للتأصيل الخارجي قبل أول Gate تنفيذية. الحزمة المفقودة
  أو القديمة تشغّل مسار authoring/refresh أولًا، ولا تسجل المهمة `blocked` إلا
  بعد استنفاد الاستكشاف أو التنزيل أو التحديث الآمن وبقاء مانع حقيقي.
- يبقى سجل المصدر والقرارات التفصيلية خارجيًا؛ ملفات Sanad المتتبعة تحمل
  invariants والعقود والاختبارات المحايدة فقط.
- الحالات المسموحة: `pending`, `in_progress`, `blocked`, `in_review`, `complete`.
- تعمل كل مهمة على Gate واحدة فقط في الوقت نفسه.
- لا تبدأ Gate لاحقة قبل إغلاق Exit criteria للبوابة السابقة وتسجيل دليل التحقق.
- أي توسع يتجاوز 15 ملفًا يتطلب إعادة تقسيم المهمة قبل التنفيذ.
- كل مهمة تحدث أقرب `AGENTS.md` ووثائق technical/product/QA التي تملك السلوك المعدل.
- لا تغلق الخطة قبل نجاح 50f وتطابق live/history في سيناريوهات الإلغاء كلها.
- العقد التقني الحاكم للسلوك هو
  [Run Cancellation and Process Ownership](../technical/run_cancellation_and_process_ownership.md).

## 1.4 لوحة التقدم

| المهمة | الحالة | Gate الحالية | سقف الملفات | شرط الانتقال |
|---|---|---|---:|---|
| 50a Cancellation Core | `complete` | closed | 12 | اعتماد primitive وbounded stop contract |
| 50b Provider Interruption | `pending` | A0 | 14 | اكتمال 50a |
| 50c Tool/Shell Cancellation | `pending` | Waiting | 14 | اكتمال 50a |
| 50d Terminal Event Durability | `pending` | Waiting | 14 | اكتمال 50a و50c |
| 50e Client Live/History Parity | `pending` | Waiting | 14 | اكتمال 50d |
| 50f Integration QA | `pending` | Waiting | 10 | اكتمال 50b–50e |

## 2. قرارات التصميم الحاكمة

1. **هوية الإلغاء:** كل cancellation scope مرتبط بـ`runId` الثابت، مع session/work item metadata للتتبع فقط.
2. **إلغاء تعاوني وفعلي:** مجرد race أو flag لا يكفي؛ المورد المسجل يجب أن يملك cleanup يقطع socket/process/wait.
3. **Stop محدود:** لا يوجد await غير محدود داخل مسار Stop. النجاح ينتهي سريعًا، والفشل ينتقل إلى حالة واضحة قابلة للتحكم بدل spinner دائم.
4. **عدم الادعاء الكاذب:** لا تنشر `idle` لعملية ذات side effects قبل إثبات توقفها أو عزلها في cleanup failure authoritative.
5. **Terminal once:** كل tool call بدأت تحصل على نتيجة terminal واحدة: `done`, `error`, أو `cancelled`.
6. **Late-result isolation:** نتيجة run ملغاة لا تغير history أو snapshot أو run أحدث.
7. **Live/history parity:** الحدث الذي يغلق الأداة في البث الحي هو نفسه الذي يعاد بناؤه من قاعدة البيانات.
8. **Provider isolation:** إلغاء طلب مزود لجلسة لا يغلق اتصالات جلسات أخرى.
9. **Cross-platform process ownership:** shell process tree تدار عبر abstraction خاصة بالمنصة، لا عبر قتل wrapper فقط.
10. **قابلية تحرير التسجيل:** تسجيل cleanup يعيد handle قابلة لـ`release()` بصورة
    idempotent بعد انتهاء المورد طبيعيًا أو بعد نجاح handoff إلى مالك آخر. تحرير
    التسجيل لا يلغي المورد، لكنه يمنع scope القديمة من إلغائه لاحقًا.
11. **لا فجوة ملكية:** لا يحرر مورد من run الحالية قبل أن يثبت المالك الجديد
    claim ناجحة. إذا فشل handoff يبقى المورد foreground وتظل Plan 50 قادرة على
    إلغائه.
12. **احتواء العملية يبدأ عند spawn:** لا يبدأ shell wrapper ثم يحاول النظام
    اكتشاف أبنائه لاحقًا. ينشأ الأمر داخل process group مملوكة على POSIX أو
    Job Object/containment مكافئة على Windows منذ اللحظة الأولى.
13. **هوية العملية ليست PID فقط:** يحتفظ controller ببصمة إطلاق تشمل PID ووقت
    بدء العملية وهوية مجموعة/حاوية التشغيل. أي cleanup متأخر يرفض قتل PID أعيد
    استخدامها أو مورد لم يعد مملوكًا.
14. **Terminalization انتقال محروس:** فوز `cancelled`, `timedOut`, أو النتيجة
    الطبيعية يحسم عبر owner/run identity وانتقال ذري أحادي الاتجاه؛ flag في
    الذاكرة وحدها لا تكفي لمنع كتابة نجاح متأخر.
15. **فصل drain عن publication:** قبول cancellation يغلق فورًا بوابة نشر
    progress/output إلى conversation أو provider القديمة، لكنه لا يوقف drain
    الداخلي لـstdout/stderr اللازم لإنهاء العملية وتجنب امتلاء الأنابيب.

## 2.1 حد التكامل مع Plan 54

Plan 50 مستقلة وقابلة للإغلاق دون تنفيذ
[Plan 54](54-durable-background-terminal-tasks-and-session-wakeups.md):

- Plan 50 توفر cancellation registration قابلة للتحرير وprocess-tree controller
  قابلة لإعادة الاستخدام.
- Plan 50 لا تنشئ background task ولا تحفظ task state ولا توقظ session.
- كل process تبدأ foreground ومملوكة للـrun افتراضيًا.
- Plan 54 وحدها تملك durable claim ونقل العملية إلى background owner بعد نجاح
  الحفظ، ثم تستدعي `release()` على registration القديمة.
- لا تستخدم Plan 50 API أو flag خاصًا بميزة background غير موجودة؛ العقد عام
  ومختبر حتى إذا لم تنفذ Plan 54 مطلقًا.

## 3. نموذج الحالة المستهدف

```text
RunCancellationScope
  identity: sessionId + runId + workItemId
  state: active | cancelling | cancelled
  reason: userStop | timeout | shutdown | superseded
  resources:
    - provider request/stream handle
    - active tool cancellation registration
    - process tree controller
    - recovery/rate-limit waits
```

قواعد Stop:

- قبول Stop يبطل ملكية الـrun قبل أي await.
- يبدأ cleanup لكل الموارد المسجلة بالتوازي ثم يجمع تقريرًا محدود الزمن.
- provider cancellation لا يعاد تصنيفه كـnetwork failure ولا يدخل retry/failover.
- tool cancellation تحفظ output واضحًا مثل `Command cancelled by user.` دون انتظار tool timeout.
- tool progress/output بعد stop barrier تُرفض من publication gate، بينما يستمر
  drain الداخلي حتى يثبت cleanup.
- إذا فشل cleanup لمورد side-effect، تنشر حالة failure واضحة مع diagnostics بدل `stopping` غير محدودة.
- resource registration المحررة لا تدخل تقرير cleanup اللاحق، بينما registration
  غير المحررة تبقى قابلة للإلغاء كالمعتاد.

## 4. ترتيب التنفيذ

```text
                 50a Cancellation Core
                         |
              +----------+----------+
              |                     |
              v                     v
     50b Provider Transport   50c Tools / Shell Tree
              |                     |
              +----------+----------+
                         |
                         v
              50d Durable Terminal Events
                         |
                         v
                50e Client Projection
                         |
                         v
                 50f Integration QA
```

- 50b و50c مستقلتان بعد تثبيت API في 50a ويمكن تنفيذهما دون تقاطع إنتاجي كبير.
- 50d يثبت event/persistence contract بعد معرفة outcome الأدوات النهائي.
- 50e يستهلك العقد المثبت ولا يخمن حالة daemon.
- 50f لا يضيف سياسة جديدة؛ يغلق سيناريوهات النظام الحقيقي ويعالج findings فقط.

## 5. خطط المهام

1. [50a: Run Cancellation Core and Bounded Stop](tasks/50a-run-cancellation-core-and-bounded-stop.md)
2. [50b: Provider Request Interruption and Watchdogs](tasks/50b-provider-request-interruption-and-watchdogs.md)
3. [50c: Tool Cancellation and Shell Process Trees](tasks/50c-tool-cancellation-and-shell-process-trees.md)
4. [50d: Durable Terminal Tool Events](tasks/50d-durable-terminal-tool-events.md)
5. [50e: Client Stop and Tool Event Parity](tasks/50e-client-stop-and-tool-event-parity.md)
6. [50f: Cancellation Integration and Regression QA](tasks/50f-cancellation-integration-and-regression-qa.md)

## 6. معايير القبول الكلية

- [ ] Stop يقطع provider request المعلق قبل headers أو أثناء SSE دون انتظار رد المزود.
- [ ] Stop يقطع tool Future القابلة للإلغاء ولا ينتظر `timeout_ms`.
- [ ] `shell_execute` تقتل process tree كاملة ولا تترك orphan child أو hook.
- [ ] عملية shell تدخل containment مملوكة قبل تنفيذ command، ثم تستخدم
      `TERM -> grace -> KILL -> verify` دون الاعتماد على اكتشاف PPID المتأخر وحده.
- [ ] cleanup المتأخرة تتحقق من process-start fingerprint ولا تقتل PID معاد
      استخدامها.
- [ ] مسار Stop يخرج خلال deadline محدد، أو ينشر cleanup failure قابلة للتحكم.
- [ ] كل tool جارية تصبح `cancelled` في البث الحي فورًا وبنفس الهوية.
- [ ] reload يعرض نفس terminal status والنص الموجودين قبل navigation.
- [ ] timeout أو provider result متأخر من run قديمة لا يستبدل cancellation.
- [ ] output تصل أثناء TERM grace لا تنشر progress جديدة ولا تدخل provider أو
      history القديمة، ولا تسبب deadlock في مجاري العملية.
- [ ] يمكن بدء رسالة جديدة بعد Stop دون انتظار Future القديمة ودون تسرب أحداثها.
- [ ] إلغاء Session A لا يؤثر على Session B أو طلب مزود مشترك معها.
- [ ] Stop المتكرر أو الصادر من عميلين idempotent ويولد terminal transition واحدة.
- [ ] `release()` idempotent، ولا تستدعي scope cleanup لمورد محرر بعد ذلك.
- [ ] فشل handoff افتراضي في الاختبار يبقي المورد تحت ملكية run وقابلًا للإلغاء.
- [ ] تحليلات agent/client والاختبارات المركزة وE2E المطلوبة ناجحة.

## 7. المخاطر وحواجزها

- **إغلاق client مشترك:** يمنع عبر request-owned transport أو handle scoped للـrun.
- **اعتبار race إلغاءً فعليًا:** كل مورد side-effect يجب أن يسجل cleanup ويثبت انتهاءه.
- **إصدار idle مبكر:** يمنع حتى terminal persistence، عدا مسار cleanup failure الصريح.
- **قتل PID أعيد استخدامه:** process controller يحتفظ بهوية المجموعة التي أنشأها ولا يقتل PID غير مملوك.
- **تفريع child أثناء tree walk:** containment المنشأة عند spawn هي الحد
  authoritative؛ تعداد شجرة PPID يستخدم للتشخيص أو fallback فقط، لا كضمان
  الملكية الأساسي.
- **نتيجة متأخرة تلوث التاريخ:** كل commit/event يتحقق من run ownership والحالة terminal.
- **إيقاف قراءة stdout مبكرًا:** publication تتوقف، لا قراءة مجاري النظام؛ drain
  يستمر داخل controller حتى exit/cleanup deadline.
- **تباعد المنصات:** process-tree tests تفصل POSIX وWindows behavior خلف contract واحد.
- **مورد بلا مالك أثناء handoff:** المالك الجديد يثبت claim أولًا، ثم تحرر
  registration القديمة؛ أي فشل قبل ذلك يبقي ملكية foreground.

## 8. خارج النطاق

- جعل كل أداة خارجية قابلة للإلغاء في هذه الخطة؛ الأدوات غير القابلة للإلغاء تعلن capability صريحة وتخضع للـbounded fallback.
- تغيير سياسات retry/failover إلا لمنعها بعد user cancellation.
- إعادة تصميم conversation timeline أو composer خارج status `cancelled` والرسالة المرتبطة بها.
- إلغاء عمليات remote بدأتها خدمة خارجية إذا لم يوفر بروتوكولها cancel API.
- تغيير semantics الخاصة بـdaemon shutdown أو hot restart إلا بقدر إعادة استخدام cancellation scope.
- إنشاء background tasks أو PTY supervisor أو task persistence أو wake timers أو
  أدوات `view_task/write_task/cancel_task`؛ تملكها Plan 54 بالكامل.

## 9. سجل التقدم والتسليم

```text
Date:
Task/Gate:
Status transition:
Owner/worktree:
Files changed:
Completed:
Verification evidence:
Documentation updated:
Open findings/blockers:
Next gate/owner:
```
