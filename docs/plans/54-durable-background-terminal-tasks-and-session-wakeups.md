---
title: "Plan 54: Durable Background Terminal Tasks and Session Wakeups"
description: "تحويل أوامر shell الطويلة إلى مهام خلفية مملوكة وقابلة للتفاعل، مع بث حي وإيقاظ typed steer وواجهات مراقبة محلية وعامة."
status: "pending"
current_gate: "Ready for 54a"
priority: "high"
depends_on: "Plan 50 complete; Task 36 authoritative steer/queue; Task 31 execution snapshots"
related_to: "Task 34 partial-stream recovery; Tasks 51-53 conversation history and compaction"
reference_grounding: "required for tasks 54a-54h"
---

# Plan 54: المهام الطرفية الخلفية الدائمة وإيقاظ الجلسات

## 1. الهدف وحدود الإصدار الأول

تمكين `shell_execute` من تحرير جولة الوكيل عندما يستمر الأمر أكثر من حد قابل
للتهيئة، مع بقاء العملية تحت ملكية daemon وإرجاع `task_id` يمكن للوكيل والمستخدم
استخدامه لعرض المخرجات، إرسال stdin، أو الإلغاء.

القيمة الافتراضية هي `background_after_ms = 30000`. كل أمر يتحول تلقائيًا إلى
الخلفية عند بلوغها ما لم يغير الوكيل القيمة بالزيادة أو النقص؛ `0` يعني النقل
الفوري. يبقى `timeout_ms` حد التشغيل الكلي المستقل، ولا يعاد تفسيره كمهلة
انتظار foreground.

في الإصدار الأول:

- سجل المهمة ومخرجاتها وحالتها دائم في `state.db` وruntime state home.
- العملية نفسها **لا تستمر كعملية قابلة للاستئناف بعد daemon restart**.
- graceful shutdown يلغي الأشجار أولًا؛ crash watchdog ينهيها عند فقد المالك.
- startup يحول أي سجل غير نهائي من مالك سابق إلى `interrupted`، ولا يعيد ربط
  PID قديمة ولا يعيد تنفيذ command تلقائيًا.
- client restart أو navigation لا يوقف المهمة ما دام daemon نفسه يعمل.

## 1.1 النتائج المطلوبة

- جلسة الوكيل تعود إلى `idle` بعد handoff ناجحة دون قتل command.
- المستخدم أو الوكيل يستطيعان متابعة output من cursor ثابت والتفاعل مع PTY.
- اكتمال المهمة أو انتهاء timer يوقظ الجلسة، أو يدخل typed pending steer إذا
  كانت مشغولة؛ لا يدخل queue ولا يبدأ run موازية.
- Stop للجلسة لا يلغي background tasks. الإلغاء صريح عبر الأداة أو الواجهة.
- لا تحذف جلسة لها مهام نشطة إلا بعد موافقة المستخدم ونجاح إلغائها.
- لا توجد process أو task بلا `session_id` وowner generation موثقة.

## 1.2 إدارة التقدم وبوابات التنفيذ

- كل مهمة تبدأ بـGate R0 للتأصيل الخارجي قبل أول Gate تنفيذية. الحزمة المفقودة
  أو القديمة تشغّل مسار authoring/refresh أولًا، ولا تسجل المهمة `blocked` إلا
  بعد استنفاد الاستكشاف أو التنزيل أو التحديث الآمن وبقاء مانع حقيقي.
- يبقى سجل المصدر والقرارات التفصيلية خارجيًا؛ ملفات Sanad المتتبعة تحمل
  invariants والعقود والاختبارات المحايدة فقط.
- لا تبدأ مهمة قبل اكتمال dependencies المباشرة وExit الخاصة بها.
- لكل مهمة Gate واحدة `in_progress`؛ لا تنتقل للتالية دون verification مسجلة.
- إذا تجاوزت مهمة 15 ملفًا أو احتاجت قرارًا جديدًا، تتوقف وتحدث الخطة أولًا.
- العمل المتوازي يملك ملفات منفصلة؛ أي تقاطع في owner/schema يعود إلى 54a.
- لا commit أو push ضمن الخطة إلا بطلب المستخدم.
- العقد التقني الحاكم للسلوك هو
  [Background Terminal Task Runtime](../technical/background_terminal_task_runtime.md).

| المهمة | الحالة | Gate الحالية | سقف الملفات | شرط الانتقال |
|---|---|---|---:|---|
| 54a Contracts/Storage | `pending` | Ready for R0 | 14 | Plan 50 complete |
| 54b PTY Supervisor | `pending` | Waiting | 14 | 54a complete |
| 54c Shell/Agent Tools | `pending` | Waiting | 14 | 54a و54b complete |
| 54d Timer/Wake | `pending` | Waiting | 14 | 54a complete |
| 54e Protocol/Security | `pending` | Waiting | 14 | 54b–54d complete |
| 54f Session Panel | `pending` | Waiting | 14 | 54e complete |
| 54g Activity Monitor/Delete | `pending` | Waiting | 14 | 54e complete |
| 54h Integration QA | `pending` | Waiting | 12 | 54a–54g complete |

## 2. قرارات التصميم الحاكمة

1. **Plan 50 هي الأساس:** process controller و`RunCancellationScope.release()`
   يكتملان أولًا. Plan 54 لا تضيف مسار قتل منافسًا.
2. **Claim قبل release:** يحفظ background owner claim ويبدأ supervisor قبل
   تحرير registration الخاصة بالـrun. فشل handoff يبقي العملية foreground.
3. **Process containment منذ spawn:** لا يعتمد الإلغاء على wrapper PID أو
   PPID enumeration وحدها.
4. **سجل دائم، عملية غير مستأنفة:** persistence للتدقيق والعرض والتعافي، لا
   لتبني process مجهولة بعد restart.
5. **PTY supervisor مالك وحيد:** process، stdin، resize، output journal، timeout،
   cancellation، والterminalization تمر عبر owner واحدة.
6. **Cursor authoritative:** كل byte output يملك absolute cursor. replay يسبق
   live activation، وتُحجز chunks الجديدة حتى اكتمال replay.
7. **Typed steer لا synthetic user message:** completion/timer/recovery أحداث
   نظام typed تستخدم admission وCAS الآمنين في Task 36، لكنها لا تظهر كرسالة
   مستخدم ولا تدخل FIFO queue.
8. **One active run per session:** wake أثناء busy تحفظ pending steer وتضبط
   advisory `pendingWake`; المنسق يفتح drain لاحقة فقط عند safe boundary.
9. **Terminal before wake:** flush output ثم terminal DB transition ثم event ثم
   wake admission. لا يرى الوكيل snapshot أقدم من الحالة التي أيقظته.
10. **Secrets خارج النموذج:** secure user stdin تذهب client → daemon → PTY
    مباشرة، ولا تدخل model context أو history أو logs أو task journal.
11. **لا orphan ownership:** حذف session وdaemon shutdown يفشلان بوضوح إذا لم
    يثبت cleanup؛ لا يستخدم cascade لحذف سجل بينما process ما زالت حية.
12. **بروتوكول Sanad أولًا:** نستخدم canonical device events والsocket الحالية
    مع cursor. لا تنشأ WebSocket PTY منفصلة أو tickets في v1 بلا قياس يثبت الحاجة.
13. **Admission محدودة بلا queue خفية:** supervisor لها حالات
    `accepting | draining | stopped` وحدود مركزية لكل session/device. تجاوز الحد
    يعيد `capacity_exceeded`، وdraining تعيد `daemon_draining` بدل قبول task ستقتل.
14. **PTY semantics صريحة:** adapter تدعم DSR،normal/application cursor modes،
    bracketed paste،keys،submit،EOF،وresize أو تعلن capability غير متاحة.
15. **الصمت إشارة لا حكم:** يحفظ `last_output_at` ويعرض تنبيه احتمال انتظار
    input. لا تلغى task بسبب الصمت إلا إذا ضبط الوكيل `no_output_timeout_ms`
    صراحة؛ القيمة الافتراضية `0` وتعني disabled.

## 3. نموذج الحالة والملكية

```text
Foreground shell
  owner = run(sessionId, runId, generation)
  registration = Plan 50 cancellation scope
             |
             | background_after_ms elapsed
             v
Persist task + claim background owner + start supervisor/watchdog
             |
             | only after claim succeeds
             v
release foreground registration -> return task_id -> session may idle
             |
             +--> running_background
                     |
                     +--> cancelling --> cancelled
                     +--> completed
                     +--> failed
                     +--> timed_out
                     +--> interrupted (daemon owner lost)
```

قواعد الحالات:

- الحالات النهائية لا تعود إلى running ولا تستبدلها نتيجة متأخرة.
- كل انتقال يحمل `revision` متزايدة وowner generation.
- `cancelling` bounded؛ بعدها terminal أو cleanup failure typed، لا spinner دائم.
- `timeout_ms` يستخدم process controller نفسها ولا ينتج terminal ثانية بعد cancel.
- Stop العادية للـrun تتجاهل registration المحررة، بينما `cancel_task` يستهدف
  background owner الحالية.

## 4. نموذج البيانات المستهدف

### 4.1 `background_tasks`

الحقول الأساسية:

```text
id, session_id, origin_run_id, origin_tool_call_id
status, owner_kind, owner_generation, revision
display_command_redacted, working_directory
pid, process_started_at, containment_kind, containment_id
background_after_ms, timeout_at
no_output_timeout_ms, last_output_at, output_attention_state
output_cursor, retained_from_cursor, output_journal_ref
exit_code, terminal_reason, cleanup_outcome
created_at, backgrounded_at, terminal_at, updated_at
```

- `session_id` FK مملوكة ولا تسمح بحذف session أثناء non-terminal tasks.
- لا يحفظ raw command إذا احتوى أسرارًا؛ يحفظ display value منقحة فقط.
- journal تحت runtime state home بصلاحيات محلية ضيقة، مع memory ring وdisk
  rotation وحد مركزي للحجم والعمر.

### 4.2 `session_wake_triggers`

```text
id, session_id, kind
task_id nullable, timer_id nullable, dedupe_key
due_at nullable, task_revision nullable
payload_snapshot, state
target_run_id nullable, target_generation nullable
revision, created_at, delivered_at
```

الحالات: `scheduled | pending | delivering | delivered | suppressed | cancelled`.
يستخدم الجدول ledger دائمًا؛ `pendingWake` في الذاكرة مجرد advisory coalescing
ولا يحل محله.

## 5. عقود الأدوات

### 5.1 `shell_execute`

مدخل جديد:

```text
background_after_ms: integer >= 0, default 30000
no_output_timeout_ms: integer >= 0, default 0 (disabled)
```

- إذا انتهى command قبل الحد، تعاد نتيجة foreground الحالية.
- إذا نجح handoff، تعاد نتيجة typed تحتوي `task_id`, `status`, `cursor`,
  `output_preview`, و`backgrounded_at`.
- إذا كان `timeout_ms <= background_after_ms` قد ينتهي timeout قبل النقل؛ هذا
  سلوك مقصود وموثق.
- no-output timer تتجدد فقط عند output فعلية، وتنتج سببًا terminal مستقلًا إذا
  اختارها الوكيل؛ التنبيه البصري بالصمت لا يقتل العملية.

### 5.2 أدوات الوكيل

- `view_task(task_id?, cursor?)`: مع ID تعيد snapshot وoutput delta؛ دون ID
  تسرد مهام الجلسة المالكة فقط.
- `write_task(task_id, mode, data?)`: `mode` هي
  `text | keys | paste | submit | eof`; input غير سرية من الوكيل إلى PTY.
  `submit` تكتب `data` الاختيارية ثم Enter، و`eof` تغلق stdin دون payload.
  لا تسمح للوكيل بطلب secret مخزنة أو قراءة secure user input.
- `cancel_task(task_id)`: إلغاء idempotent للشجرة عبر supervisor وإعادة outcome.
- `timer_to_wake(after_ms, task_ids?)`: one-shot trigger مرتبط بالجلسة؛ عند
  الاستحقاق يرفق snapshots بنفس schema المستخدمة في `view_task`.

كل أداة تتحقق من session ownership من `ToolContext`; لا يمكن لجلسة التحكم في
task جلسة أخرى حتى لو عرفت ID.

## 6. Wake وpending steer

```text
task terminal / timer due / restart reconciliation
             |
             v
persist or CAS session_wake_trigger
             |
       +-----+------+
       |            |
 session idle    session busy
       |            |
 start drain     retain typed pending steer
                    + set advisory pendingWake
                         |
                         v
                 next safe boundary/drain
```

- completion وtimer لنفس task تستخدمان `dedupe_key + task_revision`؛ إذا لم
  تتغير snapshot منذ wake سابقة يمكن suppress للtimer بدل تشغيل LLM بلا فائدة.
- عدة interrupted tasks بعد restart تدمج في recovery wake واحدة لكل session.
- وصول user message أثناء وجود wake pending لا ينشئ run ثانية؛ الحدث typed
  يترقى كـsteer في الجيل المالك أو أول safe boundary.
- فشل provider لا يفقد trigger؛ يبقى ledger قابلاً للمحاولة وفق owner واضحة،
  دون تحويله إلى user queue.

## 7. واجهة المستخدم

### 7.1 داخل المحادثة

فوق composer، بجوار/على نمط queued messages view:

- قائمة tasks الخاصة بالجلسة.
- status، مدة التشغيل، command منقحة، output preview حي.
- تنبيه غير نهائي عند طول الصمت: `No output; the task may be waiting for input.`
- فتح terminal viewer، Stop، وإرسال stdin.
- secure input mode لا يحفظ النص ولا يعكسه في state/history/logs.

### 7.2 Activity Monitor عام

في status bar أسفل الصفحة:

```text
Background tasks (3)
```

- الرقم هو عدد tasks غير النهائية عبر كل الجلسات على الجهاز المحدد.
- الضغط يفتح active tasks مع recent terminal tasks بحد retention واضح.
- يمكن الانتقال إلى المحادثة، عرض output، التفاعل، أو الإلغاء.

### 7.3 حذف المحادثة

- إذا لا توجد tasks نشطة: مسار الحذف الحالي.
- إذا وجدت: dialog إنجليزي يوضح العدد ويطلب `Cancel tasks and delete`.
- daemon يلغي tasks وينتظر terminalization ثم يحذف session transactionally.
- فشل cleanup يمنع الحذف ويعرض السبب؛ لا ينشئ orphan.

## 8. Shutdown وcrash وrestart

- graceful shutdown ينقل supervisor أولًا إلى `draining` فتفشل spawns الجديدة
  بنتيجة typed، ثم ينتظر active transitions ضمن drain deadline، وبعدها يلغي
  timers وكل task tree المتبقية قبل إغلاق قاعدة البيانات.
- POSIX watchdog يراقب owner lifetime عبر pipe/heartbeat وينهي containments عند
  فقدها ثم يخرج. Windows يستخدم Job Object kill-on-close حيث تتاح.
- عند startup، أي non-terminal record من owner generation سابقة تصبح
  `interrupted` بعد reconciliation؛ لا تعتمد process ولا تعاد command.
- ينشأ recovery wake واحدة لكل session متأثرة بعد تثبيت terminal records.
- PID fingerprint تمنع watchdog أو startup cleanup من قتل PID معاد استخدامها.

## 9. ترتيب التنفيذ

```text
                     Plan 50 complete
                            |
                           54a
                    Contracts + Storage
                       /           \
                      v             v
              54b Supervisor     54d Wake/Timer
                      |
                      v
              54c Shell + Tools
                       \           /
                        v         v
                    54e Protocol
                       /       \
                      v         v
             54f Session UI   54g Monitor/Delete UX
                       \       /
                        v     v
                         54h QA
```

- 54b و54d يمكن تنفيذهما بالتوازي بعد 54a مع ملكية ملفات منفصلة.
- 54c تنتظر supervisor الفعلية وrelease contract من Plan 50.
- 54e يثبت wire contract بعد نضج task/wake outcomes.
- 54f و54g يمكن تنفيذهما بالتوازي بعد 54e.
- 54h لا يضيف سياسة؛ يعيد findings إلى المهمة المالكة.

## 10. المهام الفرعية

1. [54a: Background Task Contracts and Durable Ownership](tasks/54a-background-task-contracts-and-durable-ownership.md)
2. [54b: PTY Supervisor, Output Journal, and Crash Containment](tasks/54b-pty-supervisor-output-journal-and-crash-containment.md)
3. [54c: Shell Auto-Handoff and Agent Task Controls](tasks/54c-shell-auto-handoff-and-agent-task-controls.md)
4. [54d: Timer Wake and Typed Pending Steer Admission](tasks/54d-timer-wake-and-typed-pending-steer-admission.md)
5. [54e: Background Task Protocol, Replay, and Secure Input](tasks/54e-background-task-protocol-replay-and-secure-input.md)
6. [54f: Conversation Background Task Panel](tasks/54f-conversation-background-task-panel.md)
7. [54g: Global Activity Monitor and Owned Session Deletion](tasks/54g-global-activity-monitor-and-owned-session-deletion.md)
8. [54h: Background Task Integration and Regression QA](tasks/54h-background-task-integration-and-regression-qa.md)

## 11. معايير القبول الكلية

- [ ] command أطول من 30 ثانية تعيد `task_id` وتصبح الجلسة idle دون قتلها.
- [ ] command أقصر من الحد تبقى foreground وتحافظ على النتيجة الحالية.
- [ ] `timeout_ms` يلغي task حتى بعد handoff ويثبت terminal واحدة.
- [ ] view/replay/reconnect لا تفقد أو تكرر output bytes.
- [ ] agent وuser يستطيعان stdin؛ secure user input لا يظهر في model/history/logs.
- [ ] DSR/cursor modes/keys/paste/submit/EOF تعمل أو تعيد capability error واضحة.
- [ ] silent task تعرض attention notice ولا تُقتل افتراضيًا؛ timeout الاختيارية
      وحدها تنتج `no_output_timeout`.
- [ ] حدود session/device وdraining ترفضان spawn بنتيجة typed بلا hidden queue.
- [ ] Stop للجلسة لا يوقف task، بينما cancel_task/UI Stop يوقف الشجرة كاملة.
- [ ] completion/timer أثناء busy تصبح typed pending steer، لا queue ولا run موازية.
- [ ] navigation/client restart يحافظان على العرض من daemon snapshot.
- [ ] daemon restart لا يتبنى process قديمة؛ السجلات تصبح interrupted والعمليات
      تنتهي عبر shutdown/watchdog.
- [ ] حذف session ذات task نشطة يتطلب confirmation ويلغيها قبل الحذف.
- [ ] session/task ownership، PID reuse، output retention، والأسرار مغطاة
      باختبارات unit/integration/E2E مناسبة.

## 12. خارج النطاق

- استمرار أو إعادة تشغيل commands تلقائيًا بعد daemon restart.
- تبني عمليات أنشأها مستخدم أو daemon generation قديمة.
- remote/distributed background execution أو مشاركة task بين أجهزة.
- terminal multiplexing كامل شبيه tmux أو shell عامة مستقلة عن agent tasks.
- WebSocket PTY منفصلة أو ticket service قبل إثبات حاجة الأداء/الأمن إليها.
- تخزين password أو secret stdin لاستعادتها أو عرضها للوكيل.
- إلغاء task تلقائيًا لمجرد غياب output ما لم يطلب الوكيل مهلة صريحة.

## 13. سجل التقدم

```text
Date:
Task/Gate:
Status transition:
Owner/worktree:
Files changed:
Verification evidence:
Documentation updated:
Open findings/blockers:
Next gate/owner:
```
