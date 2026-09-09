---
title: "Task 66: Blocked Session Policy Audit and Suspended Recovery Convergence"
description: "تدقيق كل مسارات تحويل الجلسة إلى blocked، اعتماد السياسة مع المستخدم، وإعادة إنتاج وإصلاح تضارب force-stop مع system_ask_user عبر Agent وClient واختبار daemon-backed معزول."
status: "completed"
current_gate: "complete"
priority: "critical"
depends_on: "Plan 30 durable runtime recovery and Task 31 authoritative execution snapshots"
file_budget: 36
design_contract: "docs/technical/agent_interface_runtime.md"
qa_contract: "docs/qa_maintenance/plan30_runtime_recovery_matrix.md"
---

# Task 66: Blocked Session Policy Audit and Suspended Recovery Convergence

## 1. الهدف

منع تحويل أي جلسة إلى `blocked` بلا سبب حقيقي وقابل للتفسير، وإصلاح السيناريو
المرصود الذي تتعارض فيه حالة الجلسة بعد إغلاق قسري أثناء انتظار إجابة
`system_ask_user`:

1. يعرض الوكيل بطاقة سؤال وينتظر المستخدم.
2. لا يجيب المستخدم ويُنهى process بالقوة.
3. بعد restart تظهر الجلسة كمقاطعة و`blocked` رغم بقاء السؤال صالحاً.
4. يقبل النظام الإجابة ويستأنف التنفيذ، لكن تبقى بعض projections أو الواجهة
   `blocked` في الوقت نفسه.

المهمة ليست توثيقاً فقط. بعد موافقة المستخدم على مصفوفة Gate A، يجب إعادة
إنتاج السيناريو في runtime اختبارية معزولة وإصلاح أي خلل مثبت أو أي انتقال
`blocked` يخالف السياسة المعتمدة، ثم إثبات تقارب قاعدة البيانات والـdaemon
والـclient إلى حالة واحدة صحيحة.

---

## 2. تعريف `blocked` المثبت مبدئياً

`blocked` تعني:

> لا يستطيع النظام التقدم بأمان أو بصورة صحيحة دون تدخل صريح من المستخدم.

يشمل ذلك مبدئياً:

- خطر غير محسوم لتكرار side effect بعد crash/restart.
- checkpoint ناقصة أو غامضة لا يمكن استئنافها تلقائياً بأمان.
- auth أو billing أو provider/model/configuration تمنع التقدم ولا يوجد مسار
  تعافٍ تلقائي صالح.
- فشل transient استنفد كل مسارات التعافي التلقائي، لكنه يملك تدخلاً يدوياً
  واضحاً مثل Retry أو Change Provider أو Stop.

ولا يشمل:

- سؤال `system_ask_user` أو permission request ما زال ينتظر إجابة صالحة؛ هذه
  `waiting` مع pending suspended request.
- retry مؤقت يملك timer/owner صالحاً؛ هذه `waiting`.
- تنفيذ بدأ أو استؤنف فعلياً؛ هذه `running` أو `resuming`.
- عمل انتهى أو لم يعد له owner؛ هذه `idle` بعد التسوية، لا notice تاريخية.
- خطأ عام لم يُصنف بعد من دون إثبات أن تدخل المستخدم مطلوب؛ يجب تصنيفه أو توفير
  مسار تعافٍ، ولا تستخدم `blocked` كـcatch-all صامت.

هذا التعريف لا يصبح عقداً نهائياً للتنفيذ إلا بعد تقديم مصفوفة Gate A وموافقة
المستخدم الصريحة عليها.

---

## 3. نتائج التدقيق الأولي

### 3.1 السيناريو المرصود معروف من حيث الفئة

المصدر الحالي يحتوي بالفعل على دفاعات واختبارات تستهدف هذا النوع من الخلل:

- `SessionRecoveryRestorer` يصنف running work كـ`waiting` عندما تكون كل
  `currently_executing_tools` مملوكة لـcheckpoints غير محلولة.
- يوجد repair لمسار legacy يحول false-blocked interactive work عبر
  `blocked -> resuming -> waiting` ويحذف notice المقاطعة القديمة.
- `SuspendedResumeService` يسمح لأول إجابة بمطالبة `waiting` أو `blocked`، ثم
  ينتقل إلى `resuming` ويمسح stale recovery notice، ويشترط terminal commit إلى
  `completed` قبل final delivery.
- الاختباران الحاليان يمران:
  - `restart restores a suspended ask-user tool as waiting, not blocked`
  - `persisted ask-user answer completes durable work before final delivery`

لكن هذه التغطية لا تثبت بعد السيناريو الكامل عبر process force-kill، إعادة فتح
قاعدة on-disk، hydration إلى Client حقيقية، الإجابة من البطاقة، وترتيب
`runtime_notice_cleared` و`session.execution_state_changed` حتى `idle`.

### 3.2 `blocked` لها أكثر من مالك دخول

يجب ألا يقتصر التدقيق على `system_ask_user`. تشمل نقاط الدخول الأولية التي يجب
تتبعها إلى المصدر والاختبارات:

1. **مصنف فشل المزود** في `runtime_failure_reason.dart`:
   - auth، billing، timeout، networkError، tlsCertificate، invalidRequest،
     modelNotFound، toolRuntimeError، localRuntimeError، unknown.
2. **تغيير قرار recovery** في `RuntimeRecoveryService`:
   - force-blocking، استنفاد retry budget، promotion من waiting، واستعادة notice.
3. **فشل checkpoint/resume** في `ContinuationCheckpointCoordinator`.
4. **الاستعادة بعد restart** في `SessionRecoveryRestorer`:
   - tool غير آمن، interrupted resuming غير قابل للإعادة، waiting بلا owner مثبت،
     وفشل restore العام.
5. **أخطاء turn غير المتوقعة** في `SessionTurnExecutor` التي تحول العمل مباشرة
   إلى `blocked`.
6. **أي انتقال مباشر أو غير مباشر آخر** يظهر عبر البحث عن:
   - `SessionWorkState.blocked`
   - `SessionExecutionState.blocked`
   - `RuntimeNoticeStatus.blocked`
   - SQL أو deserialization أو migration ينتج القيمة `blocked`.
7. **Client projection**:
   - ترتيب أولوية pending question مقابل blocked notice/snapshot.
   - hydration من history ثم وصول live events بترتيب مختلف.
   - تجاهل snapshots القديمة بالـrevision.
   - إزالة notice وعدم إبقاء sidebar/input في attention state قديمة.

القائمة أعلاه seed للتدقيق وليست المصفوفة النهائية. Gate A مطالبة بإثبات أن كل
writer ومسار غير مباشر جرى حصره.

---

## 4. القرارات المثبتة للمهمة

### 4.1 بوابة موافقة بشرية إلزامية

- Gate A تدقيق فقط: قراءة المصدر والاختبارات والوثائق وإنتاج مصفوفة كاملة.
- **تتوقف المهمة بعد Gate A** ولا يُعدل أي production code قبل موافقة المستخدم
  الصريحة على المصفوفة والسياسة المقترحة لكل حالة.
- لا تُعتبر الموافقة على هذا الملف موافقة مسبقة على نتائج Gate A؛ يلزم عرض
  النتائج الفعلية بعد التدقيق والحصول على موافقة جديدة.
- يجوز تعديل task/QA documentation في Gate A لتسجيل نتائج التدقيق فقط.

### 4.2 نطاق المراجعة

النطاق end-to-end ويشمل:

- Agent work-item transitions.
- runtime notices وأسبابها وأفعالها.
- authoritative execution snapshots وrevision ordering.
- suspended checkpoints وpermission/ask-user decisions.
- startup restore وforce-stop recovery.
- protocol publication عبر local/cloud canonical events.
- Client hydration، event ordering، attention state، sidebar، وبطاقة السؤال.
- daemon-backed E2E بقاعدة وruntime معزولتين.

### 4.3 بيئة إعادة الإنتاج

- يُعاد force-stop داخل test harness/runtime اختبارية معزولة فقط.
- تستخدم كل محاولة `SANAD_STATE_HOME` مؤقتة وفريدة ومزوّد E2E الحتمي.
- لا تفتح قاعدة المستخدم، ولا تستخدم provider حياً، ولا تنفذ `sanad-dev stop`
  أو `sanad-dev switch`.
- أي إعادة إنتاج على runtime المستخدم الحالية تحتاج طلباً وموافقة منفصلة صريحة
  في وقتها؛ هذه المهمة ليست تفويضاً بذلك.

### 4.4 شرط الإصلاح

بعد اعتماد Gate A:

- إذا أعاد E2E إنتاج التضارب، فالإصلاح واختبار الانحدار إلزاميان.
- إذا لم يعد السيناريو الأساسي يُنتج الخلل، لكن التدقيق وجد انتقالاً يخالف
  السياسة أو طريق خروج ناقصاً، فالإصلاح واختباره إلزاميان.
- لا تُغلق المهمة بعبارة “cannot reproduce” اعتماداً على unit tests الحالية
  وحدها؛ يجب إكمال daemon/client scenario المعزول.
- إذا اجتاز السيناريو الكامل ولم توجد مخالفة في أي مسار، لا يُضاف تغيير
  speculative؛ تُسلّم أدلة E2E والمصفوفة المعتمدة، ولا تُغلق المهمة كـno-op إلا
  بموافقة المستخدم الصريحة.

### 4.5 نتيجة تدقيق Gate A — 2026-08-31

حُصرت الكتابات المباشرة وغير المباشرة إلى `blocked` في أربعة ملاك فقط:

1. `RuntimeFailureReason.decision()` ثم
   `RuntimeRecoveryService.reportFailure()` لحالات المزود/runtime المصنفة.
2. `SessionRecoveryRestorer` لتصنيف العمل غير النهائي بعد restart وإصلاح legacy
   state أو حجبها.
3. `ContinuationCheckpointCoordinator` و`SessionTurnExecutor` عند فشل استعادة
   checkpoint أو حدوث استثناء غير مصنف في turn.
4. `SessionRunOrchestrator` و`SessionRecoveryCommandHandler` لحالات timeout في
   restart أو فقد owner/route أثناء فعل recovery صريح.

`SessionExecutionState.blocked` ليست كاتب سياسة مستقلًا؛
`SessionExecutionStateCoordinator` يشتقها من work item النشطة داخل transaction
ويزيد `revision`. كذلك لا يقرر Client الحجب: `SessionAttentionState` يعرض pending
question/permission أولًا، ثم blocked/fatal، لكنه يحتفظ بـruntime notices في سجل
منفصل لا يملك revision سلطويًا. لذلك تمنع execution revisions رجوع snapshot
قديمة، لكنها لا تمنع notice قديمة أو hydration متأخرة من إعادة مظهر blocked.

نتيجة التدقيق الخاصة بالسجل المبلغ عنه: صف work وصل إلى manual recovery بلا
`checkpoint_kind` معروف. `resumeSuspended()` نقله إلى `resuming`، ثم استدعى
`AgentRunner.resumeStream()`، فرفضه `restoreCheckpointForResume()` وحوله catch
العام إلى blocked مرة أخرى. لا يوجد حاليًا مسار repair يميز بين النافذة الآمنة
قبل أول provider invocation وبين provider/tool outcome مجهولة؛ ولذلك يعامل
الحالتين كأنهما خطر واحد.

سجل ثانٍ بتاريخ 2026-08-31 للجلسة
`653cccdf-3119-49a7-96fb-de24b982fa70` أثبت التسلسل نفسه مرتين متتاليتين:
`session.runtime_retry -> resuming -> unrecognized checkpoint -> blocked`.
المحاولة الثانية لم تغير أي durable evidence ولذلك أعادت الفشل نفسه، ما يثبت
أن Retry الحالي ليس طريق خروج فعليًا لهذه الحالة. كما نشر المسار
`final_answer` بعد فشل الاستئناف الأول، رغم عدم حدوث model continuation ناجحة؛
لذلك يشمل الإصلاح منع terminal/final publication من catch الفاشل، مع إبقاء
التشخيص حدث error/recovery typed فقط حتى ينجح claim والاستئناف أو التسوية.

## 4.6 Blocked-State Decision Matrix (Gate A)

الاختصارات في عمود الاختبارات: `failure_reason_test` =
`agent/test/core/provider_runtime/runtime_failure_reason_test.dart`،
`recovery_service_test` =
`agent/test/core/provider_runtime/runtime_recovery_service_test.dart`،
`runner_test` = `agent/test/engine/agent_runner_test.dart`، و`interfaces_test` =
`agent/test/interfaces/interfaces_test.dart`.

| ID | Trigger / source owner | From + durable evidence | لماذا لا يتقدم تلقائيًا | الحالة/notice/actions ومسارات الخروج | restart + Client/stale cleanup | الاختبارات والفجوة | القرار المقترح |
|---|---|---|---|---|---|---|---|
| `BLK-PROVIDER-AUTH` | `auth` في `RuntimeFailureReason.decision`؛ الكتابة عبر `RuntimeRecoveryService.reportFailure` | `running/resuming -> blocked`؛ reason + provider/request/run | credential غير صالح ولا يفيده تكرار الطلب | blocked/error؛ Stop + Change Provider + Open Settings؛ الخروج provider change أو Stop | notice/work يعاد بناؤهما؛ Client يعرض action card | `failure_reason_test`, `recovery_service_test`, `runner_test`؛ ينقص restart exit E2E | **Keep** |
| `BLK-PROVIDER-BILLING` | `billing` بعد فشل/غياب auto-failover | نفس الملكية؛ quota/provider محفوظان | نفس الحساب لا يستطيع التنفيذ | blocked؛ Stop + Change Provider + Open Settings؛ failover/provider change/Stop | يبقى قابلًا للتحكم بعد restart | اختبارات classifier/runner موجودة؛ ينقص no-candidate restart | **Keep** |
| `BLK-PROVIDER-MODEL` | `modelNotFound` أو `invalidRequest` | provider/model/reason/request | route أو payload الحالي غير صالح deterministic | blocked؛ Stop + Change Provider، وOpen Settings عند الحاجة؛ route change/Stop | hydrate من daemon؛ يجب ألا تبقى notice بعد route claim | classifier/runner موجودان؛ exit/stale notice ناقصان | **Split**: model يحتاج Change Provider/Model؛ invalid request terminal diagnostic أو Retry فقط إذا تغير input/config، لا retry أعمى |
| `BLK-PROVIDER-TRANSIENT` | `timeout`, `networkError`, `tlsCertificate`, `toolRuntimeError`, `localRuntimeError`, `unknown` بعد نفاد السياسة أو عدم وجود retry budget | classified reason + آخر route + checkpoint الآمن | التقدم الآلي غير جائز فقط بعد استنفاد budget أو إذا بدأ stream/أصبحت النتيجة غامضة | blocked؛ Stop + Retry، وChange Provider حيث ينطبق؛ Retry يعيد claim من checkpoint | restart يحفظ السبب؛ clear بعد أول progress/terminal | coverage جزئية في الاختبارات الثلاثة؛ لا توجد matrix لكل reason/budget/stream-start | **Split**: transient قبل أي output ينتظر/retries؛ exhausted أو ambiguous فقط يبقى blocked؛ unknown catch-all يجب تصنيفه |
| `BLK-RETRY-BUDGET` | `rateLimit`, `upstreamRateLimit`, `overloaded` مع `forceBlocked` بعد نفاد retries في `AgentRunner._handleRuntimeFailure` | attempt/budget + reason + لا `resume_at` | timer التلقائي انتهى ولا توجد محاولة تلقائية متبقية | blocked؛ Stop + Retry + Change Provider؛ manual claim أو Stop | يبقى blocked عبر restart ولا يتحول إلى spinner بلا timer | runner/recovery tests موجودة؛ ينقص restart لكل family | **Keep** |
| `BLK-PROVIDER-FATAL` | `contextOverflow`, `payloadTooLarge`, `contentPolicyBlocked`; notice=`fatal` وwork يشتق blocked | reason + provider response المصنف | الطلب نفسه لا يمكن متابعته | fatal؛ Stop دائمًا، Change Provider حيث يسمح العقد؛ لا `resuming` وهمي | terminal-looking attention حتى Stop/new corrected input | classifier tests موجودة؛ exit semantics وClient copy ناقصان | **Split**: لا تسمية blocked في السياسة؛ أبقها fatal مع تسوية work واضحة بدل خلطها بـretryable blocked |
| `BLK-CRASH-PROVIDER-INFLIGHT` | startup يرى `checkpoint_kind=model_request_in_flight` في `SessionRecoveryRestorer` | work owner + model step + marker in-flight | نتيجة الطلب عند المزود مجهولة؛ replay قد يكرر طلبًا ذا continuation/tool output | blocked؛ Stop + Retry + Change Provider مع تحذير unknown outcome | restart آخر يبقي الدليل؛ Client يعرض تحذيرًا واحدًا | interfaces/provider-restart tests؛ ينقص SIGKILL حقيقي أثناء request | **Keep**؛ لا auto-replay |
| `BLK-CRASH-UNSAFE-TOOL` | `running` وفي `currently_executing_tools` أداة بلا completed result ولا replay-safe/deferred descriptor | tool id + replay-safety + owner | قد يكرر side effect | blocked؛ Stop + manual Retry/Change Provider يصلح history بنتيجة unknown ولا يعيد الأداة | يبقى حتى claim؛ clear/idle بعد terminal | `runner_test`, `interfaces_test`, `session_restart_checkpoint_test` | **Keep**؛ لا auto-replay |
| `BLK-CRASH-INTERACTIVE` | ask-user/permission غير محلولة صُنفت قديمًا blocked | suspended checkpoint يطابق كل executing tool ids | لا يوجد مانع؛ النظام ينتظر المستخدم بالفعل | **waiting** بلا interrupted notice؛ answer/deny/Stop -> resuming/completed أو cancelled | restart يعيد البطاقة؛ pending request تتقدم بصريًا ثم notice القديمة تُحذف | unit SQLite موجود؛ ينقص process-kill + reconnect/hydration E2E | **Remove/Reclassify** دائمًا إلى waiting |
| `BLK-INTERRUPTED-RESUMING` | startup يرى `resuming` بلا owner كامل، checkpoint معروف، أو replay-safety كافية | state + owner_run/generation + checkpoint metadata | لا يمكن إثبات أن claimant السابق لم يبدأ provider/tool | blocked مع Stop/Retry/Change Provider | restart لا يخمن owner؛ manual claim فقط | interfaces tests للـownerless/unsafe موجودة | **Split**: الدليل الغامض يبقى blocked؛ owner/checkpoint الآمن auto-resume |
| `BLK-MISSING-CHECKPOINT` | `ContinuationCheckpointCoordinator.restoreCheckpointForResume` يرفض null/unknown kind أو history length؛ يتكرر في `SessionTurnExecutor` catch | قد لا يوجد إلا work payload/request؛ `resume_failure_reason` يكتب بعد الفشل | الكود الحالي لا يميز pre-provider window الآمنة عن unknown outcome | حاليًا resuming ثم blocked بعنوان unsafe checkpoint؛ Retry يعيد نفس الفشل | يعاد حجب الصف إلى ما لا نهاية؛ Client يرى resuming ثم blocked كما في البلاغ | `runner_test` يثبت الرفض فقط؛ لا يثبت recovery مفيدًا | **Split/Reclassify**: إذا لا يوجد in-flight/tool/partial-output evidence، ابنِ `initial_model_request` من payload/history أو أعده كnew turn مرة واحدة؛ إذا يوجد دليل غموض انتقل إلى صف provider/tool المناسب؛ unknown kind غير قابل للتفسير يبقى blocked مع repair migration |
| `BLK-WAITING-OWNERLESS` | `SessionRecoveryRestorer` يحول waiting بلا timer-owner أو suspended owner مثبت | waiting row + notice/checkpoints غير كافية | callback آمن غير قابل للإثبات | حاليًا blocked generic؛ Stop/Retry/Change Provider | restart ثابت؛ notice generic | interfaces legacy tests جزئية | **Split**: interactive المطابق يصلح waiting؛ timer wait المفقود يعاد بناؤه من durable `resume_at`; الصف التالف فقط blocked |
| `BLK-TURN-UNEXPECTED` | catch العام في `SessionTurnExecutor.runTurn` | exception + active owner فقط؛ قد يكتب work blocked قبل تصنيف السبب | لا يوجد إثبات دائم بذاته أن تدخل المستخدم مطلوب | حاليًا generic blocked للـresume، وerror event لباقي الحالات | قد يترك notice/work متناقضين؛ client error قد يمسح pending request | coverage موزعة ولا توجد exhaustive catch matrix | **Remove/Split**: مرّر الأخطاء المعروفة إلى classifier؛ checkpoint error إلى صفه؛ invariant/persistence failure إلى fatal diagnostic، ولا blocked catch-all |
| `BLK-RESTORE-GLOBAL` | `SessionRecoveryRestorer.markRestoreFailureAsBlocked` بعد فشل startup restore العام | أي active nonterminal item + error غير مصنف | حماية من الصمت، لكن الخطأ قد يكون في جلسة أخرى أو parsing جزئي | generic blocked لكل item؛ Stop/Retry/Change Provider | يمنع الضياع لكنه يوسع blast radius؛ notices بلا revision | interfaces fallback tests موجودة | **Split**: عزل الفشل per-session/per-row؛ لا تحجب صفًا صالحًا بسبب صف آخر؛ corruption الحقيقي يبقى قابلًا للتحكم |
| `BLK-RESTART-TIMEOUT` | `SessionRunOrchestrator.interruptProviderRequestsForRestart` بعد انتهاء مهلة drain | exact work/run/generation + in-flight marker + restart flag | outcome عند المزود مجهولة إذا وقعت مقاطعة فعلية | **الـRestart العادي لا يقاطع طلب المزود ولا يخرج؛ يبقى pending حتى ينتهي الطلب ويصل runtime إلى checkpoint آمنة. Force Restart وحده يستطيع إلغاء الطلب، وعندها يبقى blocked مع Stop/Retry/Change Provider. Retry/Change Provider الصريحان يعيدان آخر `checkpoint_before_model_request` المعروف ذريًا ثم يبدآن طلبًا جديدًا** | startup لا يعيد الطلب تلقائيًا؛ manual claim فقط يزيل علامة المقاطعة | restart coordinator/checkpoint tests + live regression | **Split/Fix**: إزالة `providerOnlyTimeout` من صلاحيات restart العادي، وإصلاح manual retry من marker المزود الغامض |
| `BLK-RECOVERY-COMMAND` | Retry/Change Provider لا يجد saved work، provider بلا default model، أو claim يفشل في `SessionRecoveryCommandHandler` | command request + notice/route؛ أحيانًا لا active work | لا يوجد شيء صالح لـresume أو route ناقص | حاليًا generic blocked قد يصبح orphan notice؛ Settings/Provider/Stop | orphan cleanup يحذف notice عند startup لكن قد تبقى حيًا حتى restart | bridge provider tests جزئية | **Split/Remove**: route ناقص يبقى blocked على work المملوك؛ missing work يصبح idempotent command failure + idle/clear، لا orphan blocked |
| `BLK-CLIENT-STALE-PROJECTION` | live/hydrated runtime notice قد تصل بعد execution revision أحدث؛ `DeviceConversationStore` لا يرتب notices | request id فقط؛ execution snapshot لها revision منفصل | ليست حالة daemon حقيقية بل projection race | pending question تتقدم حاليًا، لكن notice blocked قد تعود بعد resuming/idle | execution stale payload مرفوض؛ notice stale ليست مرفوضة | registry tests موجودة؛ notice/hydration ordering variants ناقصة | **Remove**: اربط attention/notice بexecution revision أو authority token، وارفض/امسح notice الأقدم |

### 4.6.1 امتداد Terminal interruption ضمن نفس النطاق

كشف التدقيق الإضافي أن نتيجة Terminal المضللة لها سببان مستقلان:

| ID | Trigger / source owner | الدليل الحالي | الخلل | القرار المقترح |
|---|---|---|---|---|
| `TERM-HISTORY-HEALER` | daemon يبدأ ويرى assistant tool call بلا tool result؛ `agent/lib/engine/history_healer.dart` | لا يفحص سبب انقطاع العملية؛ كل tool call غير مجابة تُملأ نصيًا بـ`Tool execution cancelled by user.` | ينسب crash/OS shutdown/kill إلى المستخدم بلا دليل، ثم تصبح الرسالة جزءًا من history المرسلة للـLLM | **Remove/Split**: لا ينشئ healer إلغاءً بشريًا. يحافظ على suspended/deferred calls، ويحوّل shell المملوكة ذات سجل بدء إلى terminal typed بسبب `daemon_interrupted`; الأدوات الأخرى تتبع replay-safety/blocked policy |
| `TERM-TIMEOUT-OUTPUT` | `_ShellWaitTimedOut` في `ShellExecuteTool.execute` | stdout/stderr تجمعان في الذاكرة، ثم `_drainOutput` ينتظرهما ويهمل النص ويعيد `Command timed out...` فقط | يفقد كل output المفيدة قبل timeout | **Fix**: بعد cleanup تجمع النتيجة bounded وتعيد partial stdout/stderr ثم terminal reason=`timed_out`, timeout، وcleanup outcome في payload واحدة |
| `TERM-CANCEL-OUTPUT` | `_ShellWaitCancelled` وكل cancellation scope غير مفتوح | يعيد دائمًا `Command cancelled by user.` ويهمل output و`RunCancellationReason` | Stop البشري وrestart/crash/watchdog/timeout تُطمس في سبب واحد | **Split**: user Stop وحده=`cancelled_by_user`; shutdown/force/restart=`agent_interrupted`; watchdog=`timed_out`; cleanup failure/ownership loss typed، مع partial output المتاح |
| `TERM-STOP-TERMINALIZATION` | `ToolTerminalizationService` و`ToolTerminalRecord.cancelled` | terminal status لا يملك `timedOut/interrupted`؛ factory الافتراضي user_stop/message ثابتة | كل unresolved tool أثناء Stop تصير cancellation بشرية حتى إذا كان السبب مختلفًا | **Split**: terminal factory عامة وحالات/reasons منفصلة، وتستخدم سبب `RunCancellationScope` الفعلي؛ message مشتقة من reason لا ثابتة |
| `TERM-CRASH-DURABILITY` | foreground shell تحفظ PID/fingerprint/output buffers في الذاكرة فقط | checkpoint يحفظ tool id/start/replay safety، ولا يحفظ containment fingerprint أو incremental output | بعد crash لا يمكن إثبات قتل process orphan ولا إعادة partial output الصحيح | **Fix**: سجل تنفيذ shell دائم ومحدود يحفظ fingerprint والـcursor ومخرجات منقحة تدريجيًا؛ startup يتحقق من الهوية، ينهي containment المملوكة إن بقيت، ويثبت terminal `interrupted/outcome_unknown` مرة واحدة مع معاملات الاستدعاء الأصلية، ثم يرسل `tool use + tool result` الأصليين إلى الـLLM ليستكمل القرار من الحالة الصادقة |

السلوك المقترح الذي يصل إلى الـLLM بعد restart لا يعيد تنفيذ أمر shell:

```text
status: interrupted
reason: daemon_stopped_unexpectedly
outcome: unknown
partial_output: <bounded redacted stdout/stderr captured before interruption>
cleanup_outcome: <exited|escalated|ownership_lost|failed|unknown>
message: The command was interrupted because the agent stopped unexpectedly.
```

وعند timeout:

```text
status: timed_out
reason: execution_timeout
partial_output: <bounded redacted stdout/stderr captured before timeout>
timeout_ms: <configured value>
cleanup_outcome: <...>
```

بعد تثبيت هذه النتيجة في checkpoint/history، تستكمل الجولة بإرسالها إلى الـLLM
مرة واحدة. لا يعاد تشغيل command أثناء الاستعادة لأن `shell_execute` غير
replay-safe؛ يتلقى الـLLM الـtool use الأصلي ونتيجته المنقطعة ليقيّم الحالة. إذا لم
توجد أي bytes محفوظة، تبقى `partial_output` فارغة لكن السبب يظل صادقًا ولا
يتحول إلى user cancellation.

### 4.7 سياسة الخروج المشتركة المقترحة

- كل `blocked/fatal` يحتفظ بـStop فعلي، وRetry/Change Provider/Settings فقط إذا
  كان الفعل قادرًا على تغيير الدليل الذي سبب الحجب.
- claim الناجح ينجز ذريًا `blocked|waiting -> resuming` مع snapshot revision
  أحدث قبل نشر resuming notice.
- أول provider progress أو terminal commit يمسح notice المطابقة فقط؛ terminal
  commit يسبق final delivery، ثم تصبح execution `idle`.
- لا يسمح restart أو hydration بإحياء notice لا تملك active non-terminal work.
- `system_ask_user` أو permission غير المجابة تبقى durable `waiting` عبر أي عدد
  من Force Stop/restart. لا يبدأ timer أو Retry أو provider call، ولا ينشأ tool
  result أو interrupted/blocked notice أو error/final answer. يعاد نشر السؤال
  نفسه بالـrequest/tool-call identity نفسها، ولا يحدث تقدم إلا بإجابة/رفض/Stop
  صريح من المستخدم.
- لا يعاد تلقائيًا provider request ذو outcome مجهولة أو أداة side-effect غير
  آمنة. أما crash قبل أول provider/tool marker، أو بعد checkpoint مكتملة، فيجب
  أن يستعاد تلقائيًا دون تدخل المستخدم.
- يجب أن يختبر force-stop windows التالية على SQLite on-disk وdaemon حقيقية:
  بعد admission وقبل checkpoint، بعد initial checkpoint، أثناء provider request،
  أثناء streaming، قبل/أثناء/بعد safe tool، أثناء unsafe tool، أثناء ask/permission،
  أثناء resuming، وبعد terminal commit وقبل transport delivery.
- يجب أن تشمل نوافذ Terminal: output قبل force-kill، timeout بعد output، Stop
  بشري، crash بلا output، process descendant مقاومة لـTERM، ownership mismatch،
  وcrash بعد terminal persistence وقبل delivery. في كل حالة توجد terminal واحدة
  وتطابق live/history/LLM input بلا replay للأمر.

---

## 5. مخرجات Gate A المطلوبة: Blocked-State Decision Matrix

ينشئ المنفذ جدولاً داخل هذا الملف أو design contract، بصف واحد لكل طريق دخول
فعلي إلى `blocked`. كل صف يجب أن يحتوي:

| الحقل | المطلوب |
|---|---|
| Stable case ID | معرف ثابت مثل `BLK-PROVIDER-AUTH` |
| Trigger | الحدث/الخطأ الدقيق الذي يبدأ المسار |
| Source location | الملف، symbol، والمالك |
| From state(s) | الحالات المسموح التحويل منها |
| Durable evidence | البيانات التي تثبت سبب الحجب |
| Why auto-progress is unsafe/impossible | سبب عدم جواز waiting/retry/resume تلقائياً |
| Expected work state | blocked أو بديل مقترح |
| Expected notice | status/reason/title/actions وrun/request ownership |
| Required user action | الفعل الذي يستطيع فعلاً حل الحالة |
| Exit transitions | كل الطرق الخارجة ونتيجتها النهائية |
| Restart behavior | ما يحدث عند restart آخر |
| Client projection | البطاقة/sidebar/composer المتوقعة |
| Stale cleanup | كيف تمنع notice/snapshot القديمة من البقاء |
| Existing tests | أسماء الاختبارات الحالية والفجوات |
| Proposed decision | Keep / Reclassify / Remove / Split |

### قواعد تقييم كل صف

لا يُعتمد أي صف `blocked` إلا إذا:

1. كان السبب durable أو قابلاً لإعادة البناء بعد restart.
2. لم يوجد مسار تلقائي آمن يمكن تمثيله بـ`waiting`.
3. ظهر للمستخدم فعل واحد على الأقل قابل للتنفيذ يحل الحالة أو `Stop` آمن؛ وإذا
   كانت الحالة terminal فعلاً، تُراجع الحاجة إلى `fatal/idle` بدلاً من blocked.
4. كان transition وnotice وexecution snapshot في transaction/ordering يمنع
   projections المتناقضة.
5. كان له exit path مختبر يعيد الجلسة إلى `resuming ثم completed/idle` أو
   `cancelled/idle` دون notice قديمة.
6. لا يستطيع event قديم أو history hydration متأخرة إعادة `blocked` بعد revision
   أحدث.

---

## Gate A — Complete Audit and User Approval

- [x] تنفيذ بحث شامل لكل writers/readers للقيم الثلاث
      `SessionWorkState.blocked`, `RuntimeNoticeStatus.blocked`, و
      `SessionExecutionState.blocked`.
- [x] تتبع كل writer إلى trigger، durable owner، notice، protocol، client، وطريق
      الخروج؛ لا يكفي تعداد نتائج grep.
- [x] مراجعة كل `RuntimeFailureReason.decision()`، بما في ذلك الفرق بين waiting،
      blocked، fatal، وcleared.
- [x] مراجعة كل catch/fallback يستخدم unknown أو forceBlocked.
- [x] مراجعة startup restore وinteractive checkpoints وunsafe tool recovery.
- [x] مراجعة Client precedence بين pending question وblocked notice/snapshot.
- [x] إكمال Blocked-State Decision Matrix بكل الصفوف والاختبارات والفجوات.
- [x] تقديم ملخص عربي للمستخدم يبين لكل حالة: Keep / Reclassify / Remove / Split.
- [x] **التوقف وطلب موافقة المستخدم الصريحة.**

### A Exit — Human Gate

- [x] وافق المستخدم صراحة على كل صف أو طلب تعديله.
- [x] سجل تاريخ/ملخص الموافقة والقرارات النهائية في هذا الملف.
- [x] لم يبدأ أي production implementation قبل الموافقة.

اعتماد المستخدم بتاريخ 2026-08-31: «ابدأ التنفيذ فورًا»، بعد عرض المصفوفة
والقرارات الخمسة وإضافة نطاق Terminal وAsk User غير المجابة. القرارات النهائية:
لا replay تلقائي لنتيجة provider/tool الغامضة؛ shell المنقطعة تُسوّى بنتيجة
typed مع partial output وتستكمل الجولة مرة واحدة؛ user cancellation لا تستخدم
إلا لStop صريح؛ Ask User/permission غير المجابة تبقى waiting؛ وnotice القديمة
لا تتغلب على execution authority الأحدث. الاستعادة لا تتحكم في قرار النموذج
التالي ولا تمنع إعادة الأمر: مسؤوليتها حفظ وعرض زوج `tool use`/`tool result`
الأصلي بنفس `tool_call_id`، وأي استدعاء جديد من النموذج يبقى زوجًا مستقلًا.

---

## Gate B — Isolated Reproduction Before Fix

لا تبدأ هذه البوابة قبل A Exit.

### السيناريو الإلزامي

1. تشغيل daemon/client اختبارية بقاعدة on-disk مؤقتة ومزوّد حتمي.
2. بدء turn يصل فعلياً إلى `system_ask_user` وتظهر البطاقة للعميل.
3. التحقق قبل الإيقاف من:
   - checkpoint = `awaiting_permission`؛
   - work item تملك tool call والـrun/generation الصحيحين؛
   - UI تعرض pending question؛
   - لا توجد blocked notice.
4. قتل process قسرياً من test harness دون controlled shutdown.
5. تشغيل daemon جديدة على **نفس state home الاختبارية** وإعادة اتصال العميل.
6. إثبات الحالة بعد hydration:
   - work item = `waiting`؛
   - execution snapshot = `waiting`؛
   - pending question موجودة؛
   - لا interrupted/blocked notice؛
   - لا تنفيذ جديد قبل الإجابة.
7. إرسال إجابة البطاقة بنفس request/checkpoint identity.
8. إثبات التسلسل authoritative:
   - claim واحد فقط؛
   - `waiting -> resuming -> completed`؛
   - execution `waiting -> resuming -> idle` بrevisions متزايدة؛
   - حذف checkpoint بعد terminal commit؛
   - حذف/clear أي stale notice مرة واحدة؛
   - final answer واحدة؛
   - Client لا تعرض blocked في أي projection نهائية.
9. إعادة فتح history بعد النجاح لإثبات أن hydration لا تعيد blocked.

### Variants إلزامية

- قاعدة legacy يبدأ فيها نفس ask-user work كـ`blocked` مع notice مقاطعة قديمة.
- Force Stop ثم restart مرة ومرات متتالية من دون إجابة؛ تبقى DB والdaemon
  والClient جميعًا `waiting` وتظهر بطاقة واحدة فقط بلا provider/tool execution.
- إغلاق Client وحده وإعادة فتحه، ثم إغلاق النظام/daemon قسريًا وإعادة التشغيل،
  مع بقاء السؤال نفسه وعدم نشر `error` أو `final_answer`.
- إجابة تصل مباشرة بعد reconnect وقبل اكتمال history hydration.
- history blocked قديمة تصل بعد live resuming/idle event ويجب رفضها بالrevision.
- إجابتان متزامنتان لنفس السؤال؛ claimant واحد فقط ولا تضارب.
- permission request غير مجاب عنها، وليس `system_ask_user` فقط.

### B Exit

- [x] حفظ نتيجة reproduction الدقيقة وأول divergence بين DB/daemon/protocol/client.
- [x] ربط الخلل بصف/صفوف Gate A المعتمدة.
- [x] تحديد root cause قبل تعديل production code.

---

## Gate C — Policy and Convergence Fix

لا يبدأ الإصلاح إلا بعد B Exit، ويجب أن يكون أصغر تغيير يعالج root cause
والمصفوفة المعتمدة.

- [x] إصلاح الانتقالات المثبتة في البلاغات: missing checkpoint وinteractive
      suspension وshell interruption وstale Client notice.
- [x] منع catch-all من تحويل خطأ إلى blocked دون reason/action/owner صالح.
- [x] ضمان أن unresolved ask/permission checkpoint تملك `waiting` عند restart.
- [x] ضمان repair آمن لأي legacy false-block دون تجاوز unsafe-tool evidence.
- [x] جعل claim + work transition + execution snapshot ذرية عبر aggregate owner.
- [x] مسح stale notice بحدث واحد ذي ownership صحيح.
- [x] ضمان terminal commit قبل final delivery ثم execution `idle`.
- [x] ضمان تطابق `isError=true` لنتيجة timeout المنظمة عبر الحدث والـcheckpoint
      وhistory مع الاحتفاظ بالمخرجات الجزئية.
- [x] منع history أو event أقدم من إعادة blocked بعد revision أحدث.
- [x] إبقاء Client projection مشتقة من daemon authority دون heuristics موازية.
- [x] ضمان Stop/Retry/Change Provider/Open Settings تعمل فعلياً لكل حالة معتمدة.

### C Exit

- [x] لا يوجد production path إلى blocked خارج المصفوفة المعتمدة.
- [x] كل blocked لها سبب قابل للتفسير، تدخل مطلوب، وطريق خروج مختبر.
- [x] لا تتعايش pending question صالحة مع false blocked state.
- [x] لا تستمر blocked بعد استئناف ناجح أو completion/stop.

---

## Gate D — Verification

### Agent focused coverage

- unit tests لمصنف failure policy لكل reason.
- SQLite-backed tests لكل transition وrestart reconciliation.
- suspended answer tests تؤكد snapshot revisions وnotice clear، لا work row فقط.
- tests لكل catch/fallback وlegacy repair وstale-owner race.
- test SQLite on-disk يكرر startup reconciliation لسؤال غير مجاب أكثر من مرة
  ويثبت أن checkpoint لا تتغير إلى blocked/resuming ولا تُنشأ نتيجة أداة.

### Client focused coverage

- pending suspended request تتقدم بصرياً على stale blocked projection مؤقتاً،
  مع بقاء daemon revision هي authority النهائية.
- `session.execution_state_changed` الأحدث يمنع history الأقدم من الرجوع.
- notice cleared + idle removes blocked attention من composer/sidebar/session.
- reconnect/hydration ordering variants.
- unanswered Ask User تبقى بطاقة واحدة بعد reconnect/restart ولا تتحول إلى
  error/final/blocked attention.

### Daemon-backed E2E

- السيناريو الكامل في Gate B يصبح regression test دائم لا script يدوي فقط.
- كل process وstate home وport مؤقتة ومعزولة.
- force-kill يستهدف process الاختبار فقط.
- لا sequential execution إلا للاختبارات التي تربط ports، وتستخدم حينها
  `--concurrency=1`.

### أوامر التحقق

تنفذ الأوامر ذات الصلة فقط وفق الملفات الفعلية، مع output محدود وexit status
محفوظ:

```bash
# agent/
set -o pipefail; fvm dart analyze 2>&1 | tail -5
set -o pipefail; fvm dart test test/core/provider_runtime/runtime_failure_reason_test.dart 2>&1 | tail -5
set -o pipefail; fvm dart test test/interfaces/interfaces_test.dart 2>&1 | tail -5
set -o pipefail; fvm dart test --concurrency=1 <focused-agent-daemon-backed-test> 2>&1 | tail -5

# client/
set -o pipefail; fvm flutter analyze 2>&1 | tail -5
set -o pipefail; fvm flutter test <focused-attention-and-hydration-tests> 2>&1 | tail -5
set -o pipefail; fvm flutter test --concurrency=1 <focused-client-daemon-backed-e2e> 2>&1 | tail -5
```

يستبدل المنفذ placeholders بالمسارات الفعلية في Handoff ولا يتركها كدليل
تسليم.

### D Exit

- [x] كل اختبارات policy والمزامنة تمر.
- [x] force-stop E2E يمر من السؤال حتى final/idle وإعادة hydration.
- [x] لا تمس الاختبارات runtime أو قاعدة أو provider المستخدم.
- [x] analyzer للـAgent والـClient يمر.

---

## Gate E — Documentation and Handoff

- [x] تحديث `docs/technical/agent_interface_runtime.md` بالتعريف والمصفوفة
      المعتمدة دون نسخ تفاصيل الاختبار.
- [x] تحديث `docs/qa_maintenance/plan30_runtime_recovery_matrix.md` بالسيناريوهات
      النهائية وأسماء الاختبارات الفعلية.
- [x] تحديث `docs/technical/communication_protocols.md` فقط إذا تغير عقد أحداث
      notice/execution أو ordering.
- [x] تحديث أقرب `AGENTS.md` فقط إذا تغير قانون دائم أو أصبح نص موجود stale.
- [x] تشغيل `graphify update .` بعد code changes.
- [x] ملء Handoff بالأدلة والقرارات المعتمدة والنتائج.

### E Exit / Definition of Done

- [x] وافق المستخدم على المصفوفة قبل التنفيذ.
- [x] تمت مراجعة كل حالة تحول session/work/notice إلى blocked.
- [x] أُصلح السيناريو المرصود إن أعيد إنتاجه وأُصلحت كل مخالفة policy مثبتة.
- [x] كل blocked المتبقية ضرورية، قابلة للتفسير، ولها تدخل وطريق خروج يعملان.
- [x] DB/work item/notice/execution snapshot/protocol/client تتقارب بلا حالات
      متضاربة بعد restart أو answer أو retry أو stop.
- [x] force-stop daemon-backed E2E دائم يثبت السيناريو كاملاً.
- [x] الوثائق والاختبارات وGraphify متزامنة.

---

## Gate F — Ordinary Restart Provider Drain and Manual Retry Recovery

- [x] جعل restart العادي يستمر في الانتظار بعد كل timeout window عندما يكون
      المانع طلب مزود قيد التنفيذ، من دون إلغائه أو تحويل الجلسة إلى blocked.
- [x] إبقاء Force Restart وحده مالك مقاطعة طلب المزود بعد timeout.
- [x] جعل transport/CLI للـrestart العادي ينتظر رد التحضير النهائي بدل إنهاء
      الطلب محليًا بعد نافذة timeout الأولى.
- [x] إغلاق provider admission ذريًا مع drain: لا توجد `await` بين فحص ملكية
      drain وكتابة marker المزود، والـrun الذي يصل checkpoint آمنة يبقى parked
      ولا يبدأ provider request أو tool batch جديدة قبل خروج العملية.
- [x] عند Retry أو Change Provider الصريح بعد مقاطعة Force Restart، استعادة
      `checkpoint_before_model_request` المعروفة ومسح علامة المقاطعة داخل نفس
      انتقال `blocked -> resuming` قبل أي provider call.
- [x] اختبار الانتظار العادي، المقاطعة القسرية، manual retry، والـcheckpoint
      غير القابلة للإصلاح، ثم إعادة تشغيل runtime الحقيقية واستعادة الجلسة
      `34a49cf4-eb32-4513-b51a-c526e2671cb8` عبر أمر Retry الرسمي.

### Gate F Acceptance

- [x] لا ينتج restart عادي `Provider request interrupted for restart` مهما
      تجاوز طلب المزود نافذة timeout، ويخرج فقط بعد checkpoint آمنة.
- [x] بعد امتلاك drain للـcheckpoint الآمنة يبقى provider call count ثابتًا؛
      لا يكتب runtime request dump ولا يبدأ استدعاء مزود جديدًا في العملية
      القديمة، ويبدأ الاستدعاء التالي مرة واحدة فقط بعد التشغيل الجديد.
- [x] Force Restart يحتفظ بسلوك outcome المجهولة ولا يعيد الطلب تلقائيًا.
- [x] Retry اليدوي من الحالة المتضررة لا يكرر خطأ `recognized checkpoint kind`
      ويصل إلى terminal commit طبيعي.

---

## 6. الملفات المتوقعة

تحدد نهائياً بعد Gate A وB؛ القائمة الحالية نطاق مراجعة لا تفويض لتعديلها كلها:

### Agent

- `agent/lib/core/provider_runtime/runtime_failure_reason.dart`
- `agent/lib/core/provider_runtime/runtime_recovery_service.dart`
- `agent/lib/engine/runtime/continuation_checkpoint_coordinator.dart`
- `agent/lib/interfaces/runtime/session_recovery_restorer.dart`
- `agent/lib/interfaces/runtime/suspended_resume_service.dart`
- `agent/lib/interfaces/runtime/session_turn_executor.dart`
- `agent/lib/evolution/db/runtime/session_execution_state_coordinator.dart`
- اختبارات `agent/test/core/`, `agent/test/interfaces/`, وdaemon-backed test مناسب

### Client

- `client/lib/features/conversations/data/transport/conversation_event_handler.dart`
- `client/lib/features/conversations/domain/models/session_attention_state.dart`
- `client/lib/features/conversations/domain/stores/device_conversation_store.dart`
- focused unit/widget tests وdaemon-backed E2E مناسب

### Documentation

- `docs/plans/tasks/66-blocked-session-policy-audit-and-suspended-recovery-convergence.md`
- `docs/technical/agent_interface_runtime.md`
- `docs/qa_maintenance/plan30_runtime_recovery_matrix.md`
- `docs/technical/communication_protocols.md` عند تغير protocol فقط

---

## 7. Handoff Evidence

### Gate A approval

- **Matrix location:** القسم 4.6 في هذا الملف.
- **User-requested changes:** ضم صدق نتائج Terminal: منع نسبة crash/timeout إلى
  user cancellation، حفظ partial output، وterminalize/continue دون replay.
- **Explicit approval:** 2026-08-31 — «ابدأ التنفيذ فورًا».

### Reproduction and root cause

- **Isolated runtime:** `client/e2e_test/local_dual_connection_e2e_test.dart`
  يستخدم daemon processes و`SANAD_STATE_HOME`/`SANAD_HOME` مؤقتتين؛ يقتل process
  الاختبارية فقط بـSIGKILL ويعيد فتح نفس SQLite.
- **Observed divergence:** البلاغان أثبتا retry loop من `resuming` إلى checkpoint
  غير معروفة ثم `blocked`، مع `final_answer` زائفة. اختبارات الانحدار الجديدة
  فشلت أولًا أمام attribution العام لـuser cancellation وغياب repair الآمن.
- **Root cause:** checkpoint window قبل provider لم تكن مميزة عن outcome غامضة؛
  history healer نسب كل orphan إلى المستخدم؛ shell لم تحفظ fingerprint/output؛
  وruntime notice لم تحمل execution revision يمنع stale Client projection.

### Implementation and verification

- **Changed files:** Agent checkpoint/history/recovery/shell terminalization، Client
  notice ordering، الاختبارات الحتمية، والعقود التقنية والـQA القريبة.
- **Agent tests/analyzer:** `fvm dart analyze` بلا issues؛ الحزمة الكاملة
  `1386 passed, 13 skipped`، إضافة إلى focused checkpoint/shell/recovery suites.
- **Client tests/analyzer:** `fvm flutter analyze` بلا issues؛ الحزمة الكاملة
  `1167 passed, 1 skipped`، وfocused store/event tests `32 passed`.
- **Daemon-backed E2E:** اختباران، `2 passed`: Ask User بقي بنفس request بعد
  SIGKILL مرتين ثم استؤنف بإجابة واحدة؛ shell crash حفظ partial output، أنهى
  containment، وأثبت side-effect counter قيمة `1` من دون replay.
- **Graphify update:** `graphify update .` نجح: 21768 nodes و29580 edges.
- **Known limitations:** provider request ذو outcome مجهولة، وأداة unsafe غير shell
  بلا terminal evidence، تبقيان `blocked` عمدًا ولا تعادان تلقائيًا؛ هذه هي
  حدود الأمان المعتمدة وليستا fallback failures.

---

## Gate G — Interactive Ordinary-Restart and Admission Convergence Regression

أعاد البلاغ الحي فتح المهمة لأن الاختبارات السابقة أثبتت startup بعد Force Stop
لكنها لم تختبر أن الانتظار التفاعلي نفسه checkpoint آمنة للـRestart العادي، ولم
تثبت تنظيف projection الـorchestrator بعد إجابة مستعادة.

### القرارات المثبتة

- Ask User وطلب permission غير المجابين نقطة restart آمنة إذا كانت كل الأدوات
  غير المكتملة مغطاة بـ`awaiting_permission` ولا يوجد provider request جارٍ.
- Restart العادي لا ينتظر الإجابة ولا يحتاج Force ولا يصنع tool result؛ startup
  يعيد نفس الطلب كـ`waiting` بالهوية نفسها.
- بعد terminal commit للإجابة المستعادة، تزال ملكية suspension/busy الداخلية
  ويعود admission إلى durable state؛ الرسالة التالية turn جديدة طبيعية.
- نتيجة حذف queued message تستخدم `outcome` في command result، ويجب أن تختفي
  الرسالة من الواجهة عند `deleted` أو `already_removed`.

### التنفيذ والقبول

- [x] إضافة بوابة restart للانتظار التفاعلي الكامل مع fail-closed عند التغطية
      الجزئية لأدوات batch.
- [x] ربط terminal commit في `SuspendedResumeService` بتسوية projection لدى
      `SessionRunOrchestrator` وتصريف FIFO.
- [x] تصحيح Client لاستهلاك `outcome` من نتيجة حذف queued message.
- [x] اختبارات مركزة لـAsk User وpermission والتغطية الجزئية وتنظيف ownership
      وحذف الصف من الواجهة.
- [x] مرور analyzers والاختبارات المركزة النهائية وتحديث Graphify.
- [x] لا restart للعميل ولا اختبار تفاعلي قبل طلب المستخدم الصريح.

### Gate G Evidence

- Agent focused: `83 passed` في checkpoint/orchestrator suites؛ والحزمة الكاملة
  `1472 passed, 13 skipped`.
- Client focused: `26 passed` في event-handler suite؛ والحزمة الكاملة
  `1191 passed, 1 skipped`.
- Daemon-backed E2E: `F.2.9` مرّ عبر مزود HTTP حتمي وprocessين حقيقيين؛ قبل
  Restart كان `system_ask_user` معلقًا، وقَبِل `/restart` العادي الحالة كـ`safe`،
  ثم استُخدمت هوية الطلب نفسها بعد الإقلاع بلا tool result مصطنعة. بعد الإجابة
  اكتملت الجولة وقُبلت رسالة جديدة كـturn طبيعي (`1 passed`).
- `fvm dart analyze` و`fvm flutter analyze`: بلا issues.
- `graphify update .`: اكتمل إلى `22124 nodes` و`30117 edges`.
- لم تُعد تشغيل نسخة Agent أو Client، ولم يُنفذ اختبار UI تفاعلي في هذه الدورة.
