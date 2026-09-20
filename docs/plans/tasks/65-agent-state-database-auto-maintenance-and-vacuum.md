---
title: "Task 65: Agent State Database Auto-Maintenance and Vacuum"
description: "تنظيف عناصر العمل الطرفية القديمة، وفصل تنظيف الأيتام عن استعادة التشغيل، واسترداد مساحة state.db دورياً وفق عتبات آمنة ومحددة."
status: "in_progress"
current_gate: "Gate F — CI verification"
remaining_estimate: "5%"
priority: "high"
depends_on: "Task 64 sanad-dev Bootstrap and Complete Component Logs (completed)"
file_budget: 12
design_contract: "docs/technical/agent_database_schema.md"
qa_contract: "docs/qa_maintenance/agent_state_database_maintenance_qa.md"
---

# Task 65: Agent State Database Auto-Maintenance and Vacuum

## 1. الهدف

منع النمو غير المحدود لقاعدة بيانات الوكيل المحلية `state.db` عبر صيانة آمنة
لا تؤخر جاهزية الـdaemon: يستعيد الوكيل العمل ويفتح منصات الاتصال أولاً، ثم ينفذ
التنظيف تدريجياً أثناء الخمول، ويؤجل الضغط الكامل إلى حد إيقاف آمن:

1. الإبقاء على تنظيف عناصر العمل التي لم تعد جلستها موجودة، مع نقله من مسار
   استعادة التشغيل إلى مالك صيانة مستقل.
2. حذف عناصر العمل الطرفية (`completed` و`cancelled`) التي مر على آخر تحديث لها
   14 يوماً، دون حذف الجلسات أو الرسائل.
3. تشغيل `VACUUM` الكامل فقط عندما تكون فائدته كبيرة ومسموحاً به زمنياً.
4. احتواء أي فشل في الصيانة حتى لا يمنع إقلاع الـdaemon أو يغيّر تصنيف العمل
   القابل للاستعادة.

هذه المهمة تعالج تضخم سجلات التنفيذ و`continuation_metadata`؛ سجل المحادثة في
`messages` يبقى محفوظاً بالكامل.

---

## 2. نتائج تدقيق المستودع (المصدر الحالي هو المرجع)

### 2.1 حقائق مؤكدة

- `state.db` مملوكة لاتصال واحد من `AgentStateDatabase`، وتشترك فيه مستودعات
  الجلسات والعمل الدائم والمزوّدين.
- `SessionWorkItemRepository.cleanupOrphanedWorkItems()` **مستدعاة في الإنتاج
  حالياً** من `SessionRecoveryRestorer.restorePersistedState()`؛ لذلك العبارة
  السابقة بأنها مستخدمة في الاختبارات فقط كانت غير صحيحة.
- استدعاء تنظيف الأيتام الحالي مختلط بمسؤولية استعادة `queued/running/waiting`
  ويستطيع فشله إسقاط مسار الاستعادة كله. يجب فصله، لا إضافته مرة ثانية.
- `session_work_items.session_id` يحمل `ON DELETE CASCADE` مع تفعيل
  `PRAGMA foreign_keys = ON`. يبقى تنظيف الأيتام دفاعاً لبيانات legacy أو قواعد
  أُنشئت/عُدّلت سابقاً مع تعطيل القيود.
- لا توجد حالياً صيانة دورية ولا تخزين لطوابع نجاح الصيانة ولا تنفيذ `VACUUM`.
- جدول `provider_model_cache` هو stale-while-revalidate fallback، ولا يملك
  `last_accessed_at`. حجمه محدود بعدد instances/cache keys، وحذفه وفق
  `fetched_at` قد يزيل fallback صالحاً عند انقطاع الشبكة.
- لا توجد PRAGMA حالية لـ`auto_vacuum` أو `incremental_vacuum`؛ هذه المهمة تعتمد
  `VACUUM` الكامل وفق عتبات، ولا تغيّر نمط الصفحات.

### 2.2 تفسير قياسات التضخم

القياس المحلي الذي أظهر قاعدة تقارب 300MB وارتفاع متوسط
`continuation_metadata` هو دليل تشخيصي، وليس ثابتاً عاماً أو شرط قبول. يجب أن
تثبت الاختبارات السلوك بعدد الصفوف والصفحات، لا أن تفترض حجماً بعينه لقاعدة
المستخدم.

---

## 3. القرارات المثبتة

### 3.1 نقطة الاستدعاء وملكية المسؤوليات

- يضاف `AgentStateMaintenanceService` تحت `agent/lib/evolution/db/` ويُسجل في
  `agent/lib/core/di.dart` باستخدام اتصال `AgentStateDatabase` المشترك.
- يجدول `agent/bin/daemon.dart` الصيانة مرة واحدة بعد اكتمال DI وlogging وdurable restore و`GatewayManager.start()` وبعد طباعة إشارة الجاهزية. تنتظر الخدمة 30 ثانية والخمول قبل أي SQL للصيانة.
- `agent/bin/` يملك الاستدعاء واحتواء الخطأ فقط؛ لا يملك SQL أو سياسة الاحتفاظ.
- تزال دعوة `cleanupOrphanedWorkItems()` من `SessionRecoveryRestorer` بعد نقلها
  إلى خدمة الصيانة، حتى لا توجد صيانة مكررة أو SQL-maintenance ضمن مالك
  استعادة التشغيل.
- لا تفتح الخدمة اتصال SQLite ثانياً ولا تعيد إنشاء `AgentStateDatabase`.

### 3.2 فصل تنظيف الأيتام عن الصيانة المقيدة زمنياً

- تتجاهل استعلامات الاستعادة orphan rows عبر join مع `sessions` دون حذف مسبق.
- بعد الجاهزية والخمول تكتشف الخدمة هويات الأيتام وتحذفها في دفعات محدودة، مع إعادة التحقق من غياب الجلسة داخل كل transaction.
- يظل SQL داخل `SessionWorkItemRepository`، ويعيد كل batch عدد الصفوف المتأثرة.
- فشل التنظيف يُحتوى ولا يؤثر في الاستعادة أو daemon الجاهز.

### 3.3 سياسة الاحتفاظ بعناصر العمل الطرفية

- الثابت الافتراضي: `terminalWorkItemRetention = Duration(days: 14)`.
- يحذف فقط:

  ```sql
  DELETE FROM session_work_items
  WHERE state IN ('completed', 'cancelled')
    AND updated_at < ?
  ```

- cutoff هو `nowUtc - 14 days` بصيغة UTC ISO8601 متوافقة مع القيم الحالية.
- المقارنة **حصرية** (`updated_at < cutoff`): الصف عند الحد تماماً لا يحذف.
- لا تشمل السياسة مطلقاً `queued`, `running`, `waiting`, `blocked`, أو
  `resuming` مهما كان عمرها.
- لا تحذف `sessions`, `messages`, `session_execution_snapshots`, notices، pending
  steers، stop-recovery outcomes، route transitions، suspended checkpoints، أو
  scheduled tasks.
- لا تضف إعداد user-facing أو environment variable لمدة الاحتفاظ في هذه
  المهمة. تبقى القيم ثوابت مركزية قابلة للاختبار لتجنب توسيع سطح الإعدادات.

### 3.4 حالة الصيانة والـthrottling

ينشئ `AgentStateDatabase` جدولاً صغيراً يملكه مستودع صيانة مخصص:

```sql
CREATE TABLE IF NOT EXISTS agent_maintenance_state (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
```

المفاتيح المعتمدة فقط:

- `last_terminal_prune_succeeded_at`
- `last_vacuum_succeeded_at`
- `vacuum_pending`

القواعد:

- terminal prune مستحقة عند غياب الطابع أو مرور 24 ساعة على آخر نجاح.
- `VACUUM` لا تُنفذ أكثر من مرة كل 7 أيام.
- كل الطوابع UTC ISO8601، وتمثل **نجاحاً** لا مجرد محاولة.
- قيمة مفقودة أو malformed أو مستقبلية تُعامل على أنها مستحقة؛ لا يُسمح لطابع
  مستقبلي بمنع الصيانة إلى أجل غير معلوم.
- حذف terminal rows يتم في transactions محدودة مستقلة. التقدم الجزئي آمن وidempotent، ولا يتقدم `last_terminal_prune_succeeded_at` حتى تكتمل كل الدفعات.
- عند نجاح prune بلا صفوف محذوفة، يُحدّث طابع النجاح لمنع إعادة المسح المكلف.
- `last_vacuum_succeeded_at` لا يُكتب إلا بعد عودة `VACUUM` بنجاح؛ إذ لا يجوز
  تشغيل `VACUUM` داخل transaction.
- تعتمد الاختبارات clock محقونة؛ لا تستخدم sleeps أو توقيت الجدار الحقيقي.

### 3.5 سياسة `VACUUM` المثبتة

بعد تنظيف الأيتام ومحاولة terminal prune، تقرأ الخدمة:

```sql
PRAGMA page_size;
PRAGMA page_count;
PRAGMA freelist_count;
```

وتحسب:

- `reclaimableBytes = page_size * freelist_count`
- `freeRatio = page_count == 0 ? 0 : freelist_count / page_count`

يُنفذ `VACUUM` فقط إذا تحققت الشروط كلها:

1. آخر `VACUUM` ناجحة غائبة أو أقدم من 7 أيام؛
2. `reclaimableBytes >= 64 * 1024 * 1024`؛
3. `freeRatio >= 0.20`؛
4. لا توجد transaction مفتوحة؛
5. `vacuum_pending=true` وبعد safe controlled restart drain وflush للاستجابة وقبل خروج العملية القديمة.

لا يشترط أن يكون الفراغ قد نشأ في الإقلاع الحالي؛ يجوز استرداد صفحات حرة
متراكمة من حذف سابق. لا تُشغّل `VACUUM` لمجرد حذف صف واحد أو عدة صفوف صغيرة.

يملك `AgentStateDatabase` primitives إحصاء الصفحات وتنفيذ `VACUUM` لأنها عمليات
على الاتصال/الملف كله، بينما يملك service قرار السياسة. لا تبني SQL path آخر
ولا تستخدم CLI `sqlite3` ولا shell process.

### 3.6 كاش الموديلات خارج النطاق بقرار صريح

- لا تحذف المهمة أي صف من `provider_model_cache`.
- لا تضف `last_accessed_at` ولا تغيّر عقد stale-while-revalidate.
- إذا أثبت قياس مستقبلي أن الكاش مصدر تضخم فعلي، ينفذ ذلك في مهمة مستقلة تحفظ
  offline fallback وتعرّف access semantics صراحة.

### 3.7 احتواء الفشل والسجلات

- wrapper ما بعد الجاهزية يلتقط أخطاء حل الخدمة والتنفيذ ويسجل warning موجزاً دون التأثير في daemon.
- فشل prune يترك طابع النجاح مستحقاً؛ الدفعات الملتزمة تبقى محذوفة بأمان وتستكمل المحاولة اللاحقة الباقي.
- فشل `VACUUM` عند controlled exit يترك `vacuum_pending=true` ولا يلغي restart المقبولة.
- لا تدخل payloads أو `continuation_metadata` أو مسار `SANAD_HOME` في السجلات.
- عند تنفيذ عمل فعلي، يسجل summary واحد فقط: orphan count، terminal count، قرار
  vacuum، والمساحة القابلة للاسترداد. حالات skip الاعتيادية تكون `fine` أو بلا
  سجل لتجنب ضوضاء الإقلاع.

---

## 4. النطاق غير المشمول

- حذف الرسائل أو الجلسات أو scheduled tasks أو الذاكرة.
- حذف أو ضغط أجزاء من `continuation_metadata` لعنصر غير طرفي.
- تغيير عقود restart/retry/stop أو state transition graph.
- تنظيف `provider_model_cache` أو recent model selections.
- إضافة صفحة إعدادات أو أوامر CLI للصيانة اليدوية.
- فتح اتصال SQLite ثانٍ أو إضافة worker/isolate يلتف على مالك الاتصال المشترك.
- تغيير SQLite إلى `auto_vacuum=INCREMENTAL`.
- تشغيل الصيانة على قاعدة المستخدم الحية؛ قياس الأداء يستخدم نسخة متسقة معزولة ومصرحاً بها فقط.

---

## 5. تصميم التنفيذ المتوقع

### 5.1 APIs والمالكون

1. **`AgentStateDatabase`**
   - ينشئ `agent_maintenance_state` idempotently.
   - يوفر primitive typed لقراءة page statistics وprimitive لتنفيذ `VACUUM`.
   - يمنع/يرفض vacuum إذا كانت transaction مملوكة له مفتوحة.

2. **`SessionWorkItemRepository`**
   - يحافظ على `cleanupOrphanedWorkItems` كمالك SQL للأيتام ويجعله قابلاً
     للتركيب داخل transaction المشتركة إن احتاج التنفيذ.
   - يضيف `deleteTerminalWorkItemsOlderThan(cutoff, {transaction}) -> int`.

3. **`AgentMaintenanceStateRepository`**
   - المالك الوحيد لـ`agent_maintenance_state`.
   - يقرأ ويكتب الطوابع المعروفة دون map authority موازية.

4. **`AgentStateMaintenanceService`**
   - يملك policy، clock، ترتيب الخطوات، thresholds، ونتيجة typed قابلة للاختبار.
   - يستخدم قيم الإنتاج المثبتة افتراضياً، مع حقن clock والـdurations وعتبات
     vacuum في الاختبارات فقط؛ لا تتحول هذه القيم إلى إعدادات مستخدم.
   - يركب المستودعات عبر اتصال `AgentStateDatabase` نفسه.

5. **`daemon.dart`**
   - يستدعي wrapper محتوى للصيانة في الموضع المحدد، ثم يتابع restore/start.

### 5.2 نتيجة typed مقترحة

تعيد الخدمة نتيجة داخلية واضحة للاختبارات والسجل، مثل:

- `orphanedWorkItemsDeleted`
- `terminalWorkItemsDeleted`
- `terminalPruneRan`
- `vacuumDecision` (`executed`, `throttled`, `belowThreshold`, `failed`)
- `reclaimableBytesBeforeVacuum`

لا تجعل نتيجة الصيانة جزءاً من البروتوكول العام أو UI.

---

## Independent review (worktree)

- Gate A independently verified the initial design; its startup call placement was later rejected and superseded by Gate E performance evidence.
- Gate B independently verified: schema, page statistics, vacuum-in-transaction guard, prune SQL, maintenance repository, injected-clock service, orphan cleanup moved off `SessionRecoveryRestorer`, shared-connection DI, contained daemon wrapper, schema/QA/`AGENTS.md` updates. Class comment on `AgentStateDatabase` was stale and is now aligned.
- Gate C independently verified after adding vacuum 7-day throttle coverage, zero-row prune stamp coverage, and a wrapper test that continues restore/start after a throw. Focused analyzer and tests passed. The documented full-tree `dart format lib test` command still reports 16 pre-existing files outside this task; Task 65 Dart files are formatted.
- Gate D independently verified: schema §7, QA run/skip/fail matrix, no stale "orphan cleanup is test-only" claim, Graphify updated, handoff evidence recorded.
- Gate E performance review on the authorized 1.088GB fixture moved cleanup after readiness, made deletion idle-gated and bounded, and moved full vacuum to controlled exit. First-upgrade readiness stayed within the 5%/25ms gate and steady readiness improved slightly.

## Gate A — Audit and Decisions (مكتملة)

- [x] التحقق من الاتصال الواحد وملكية الجداول.
- [x] تصحيح حقيقة أن orphan cleanup تعمل في production startup حالياً.
- [x] اعتماد 14 يوماً لـ`completed` و`cancelled`.
- [x] استبعاد model cache حفاظاً على stale fallback.
- [x] اعتماد prune كل 24 ساعة و`VACUUM` كل 7 أيام بعتبتي 64MiB و20%.
- [x] اعتماد جدول metadata داخل `state.db` وطوابع نجاح منفصلة.
- [x] ~~تثبيت موضع الاستدعاء قبل الاستعادة وفتح transports.~~ نُسخ بقرار Gate E: الجدولة بعد الجاهزية.

### A Exit

- [x] كل حالات الحذف والـskip والفشل محددة بلا قرار معماري مؤجل.
- [x] لا يوجد حذف لحالة نشطة أو لرسائل المحادثة.

---

## Gate B — Implementation

- [x] إضافة schema idempotent لـ`agent_maintenance_state`.
- [x] إضافة typed page statistics وguard يمنع `VACUUM` داخل transaction.
- [x] إضافة terminal prune API إلى `SessionWorkItemRepository` مع row count.
- [x] إضافة `AgentMaintenanceStateRepository` واختبارات parsing للطوابع.
- [x] إضافة `AgentStateMaintenanceService` بساعة محقونة ونتيجة typed.
- [x] نقل orphan cleanup من `SessionRecoveryRestorer` إلى service دون تكرار.
- [x] تسجيل service في DI عبر اتصال `AgentStateDatabase` المشترك.
- [x] ~~إضافة wrapper الإقلاع قبل restore/platform start.~~ أصبح wrapper بعد الجاهزية ويحتوي فشل الحل والتنفيذ.
- [x] تحديث `docs/technical/agent_database_schema.md` بجدول وسياسة الصيانة.
- [x] إضافة `docs/qa_maintenance/agent_state_database_maintenance_qa.md`.
- [x] تحديث أقرب `AGENTS.md` فقط إذا غيّر التنفيذ قانوناً دائماً أو جعل نصاً
      حالياً stale؛ لا تُستخدم العقود كسجل نشاط.

### B Exit

- [x] لا يملك `SessionRecoveryRestorer` أي استدعاء صيانة عامة.
- [x] لا يفتح أي مالك اتصالاً ثانياً بـ`state.db`.
- [x] جميع عمليات الحذف محصورة في الحالات والجداول المعتمدة.
- [x] فشل الصيانة لا يمنع استدعاء durable restore أو بدء الـdaemon.

---

## Gate C — Automated Verification

### 6.1 اختبارات repository/service المطلوبة

باستخدام in-memory DB حيث يكفي وtemporary on-disk DB لاختبارات الحجم فقط:

1. حذف `completed` و`cancelled` الأقدم من cutoff.
2. الاحتفاظ بالطرفي الأحدث من cutoff والواقع عند cutoff تماماً.
3. الاحتفاظ بكل حالات `queued/running/waiting/blocked/resuming` القديمة.
4. بقاء صفوف `sessions` و`messages` كما هي بعد prune.
5. تنظيف orphan legacy row مع تعطيل FK فقط داخل fixture ثم إعادة تفعيله.
6. أول تشغيل ينفذ prune، وتشغيل خلال أقل من 24 ساعة يتخطاه.
7. مرور 24 ساعة بالضبط يجعل prune مستحقة.
8. timestamp malformed أو مستقبلية لا تمنع التشغيل.
9. فشل transaction يعمل rollback للحذف والطابع معاً.
10. vacuum decision لا تنفذ تحت 64MiB أو تحت 20% حتى لو تحقق الشرط الآخر.
11. vacuum decision تنفذ عند مساواة العتبتين وبعد مرور 7 أيام.
12. نجاح `VACUUM` يحدّث طابعها، وفشلها لا يحدّثه.
13. guard يرفض `VACUUM` داخل transaction.
14. wrapper startup يكمل restore/start عند رمي service خطأ.
15. استدعاء startup مرة واحدة ولا يتكرر عبر مسار restorer.
16. `provider_model_cache` لا يتغير بعد الصيانة.

### 6.2 اختبار SQLite فعلي على القرص

- ينشئ الاختبار `Directory.systemTemp` و`AgentStateDatabase.atPath` فقط.
- يحقن عتبات vacuum صغيرة خاصة بالاختبار، ثم يزرع terminal work items ذات payload
  محدود يكفي لصنع freelist قابلة للقياس؛ لا ينشئ fixture بحجم 64MiB.
- يثبت أن prune يزيد `freelist_count`، وأن vacuum المؤهلة تقلل `page_count` أو
  حجم ملف الاختبار فعلياً، مع بقاء قيم الإنتاج 64MiB و20% مغطاة باختبار قرار
  منفصل لا يحتاج ملفاً ضخماً.
- يغلق الاتصال ويحذف temporary directory في `tearDown` حتى عند الفشل.
- لا يرث `SANAD_STATE_HOME` الحقيقية ولا يفتح `~/.sanad/state.db`.

### 6.3 أوامر التحقق المحددة

تنفذ من `agent/` مع حفظ exit status وعرض آخر خمسة أسطر افتراضياً:

```bash
set -o pipefail; fvm dart format --output=none --set-exit-if-changed lib test 2>&1 | tail -5
set -o pipefail; fvm dart analyze 2>&1 | tail -5
set -o pipefail; fvm dart test test/evolution/agent_state_maintenance_test.dart 2>&1 | tail -5
set -o pipefail; fvm dart test test/evolution/runtime_state_repositories_test.dart 2>&1 | tail -5
```

لأن التغيير يمس bootstrap وحدود persistent runtime state، يضاف اختبار daemon
backed مركز أو يحدّث اختبار قائم لإثبات ترتيب startup واحتواء الفشل. يستخدم
`SANAD_STATE_HOME` مؤقتاً وفريداً ومزوّد E2E الحتمي، ويشغّل بالتتابع فقط إن كان
يربط system ports:

```bash
set -o pipefail; fvm dart test --concurrency=1 test/evolution/agent_state_maintenance_test.dart --name "daemon-backed" 2>&1 | tail -5
```

المسار الفعلي هو `test/evolution/agent_state_maintenance_test.dart` (لا يربط
منفذ بوابة؛ `ENABLE_LOCAL_GATEWAY=false`). حارس ترتيب المصدر محدّث في
`test/guards/test_daemon_provider_startup_contract_guard.dart`.

### C Exit

- [x] تمر اختبارات الحدود، rollback، throttling، vacuum، وstartup containment.
- [x] يمر analyzer والاختبارات المركزة بالأوامر النهائية الموثقة.
- [x] لا تصل الاختبارات إلى قاعدة المستخدم أو مزوّد حي.

---

## Gate D — Documentation and Handoff

- [x] توثيق جدول maintenance، طوابع النجاح، retention، وvacuum thresholds في
      `docs/technical/agent_database_schema.md`.
- [x] توثيق matrix التشغيل/التخطي/الفشل في
      `docs/qa_maintenance/agent_state_database_maintenance_qa.md`.
- [x] إزالة أي ادعاء stale بأن orphan cleanup غير مستخدمة في production.
- [x] تشغيل `graphify update .` بعد تعديل الكود.
- [x] تسجيل الملفات الفعلية المعدلة وأوامر الاختبار ونتائجها في Handoff أدناه.

### D Exit / Definition of Done

- [x] ~~ينفذ daemon صيانة واحدة محتواة قبل restore وفتح transports.~~ نُسخ هذا القرار بقياس Gate E؛ الصيانة الثقيلة لا يجوز أن تكون في مسار الجاهزية.
- [x] تحذف فقط عناصر العمل الطرفية الأقدم من 14 يوماً.
- [x] تبقى عناصر العمل النشطة والجلسات والرسائل وكاش الموديلات دون حذف.
- [x] لا تعمل prune أكثر من مرة كل 24 ساعة بعد نجاحها.
- [x] لا تعمل `VACUUM` أكثر من مرة كل 7 أيام ولا دون 64MiB و20% صفحات حرة.
- [x] فشل أي مرحلة لا يمنع daemon من الاستعادة والإقلاع.
- [x] الوثائق والاختبارات وGraphify متزامنة مع التنفيذ.

---

## Gate E — Startup Performance Redesign (مكتملة)

### E.1 Evidence and superseding decisions

قياس AOT على نسخة SQLite متسقة من قاعدة مستخدم بحجم `1,088,159,744` بايت أثبت
أن التصميم الأول غير صالح للأداء: `main` وصل إلى الجاهزية خلال `483ms`، بينما
التنفيذ الأول استغرق `9.89s`. حذف 1,872 صفاً طرفياً وحده استغرق `3.51s` وحرر
نحو `380MB`، ثم نفذت `VACUUM` في المسار الحرج. لذلك تنسخ القرارات التالية أي
نص سابق يضع orphan cleanup أو terminal prune أو page statistics أو `VACUUM`
قبل جاهزية المنصات:

- startup restore يتجاهل orphan work items عبر join مع `sessions` ولا يحتاج
  حذفها مسبقاً.
- بعد `GatewayManager.start()` وإعلان الجاهزية، تنتظر الصيانة فترة سماح ثم تعمل
  فقط عندما لا توجد جولات أو queue أو recovery نشطة.
- orphan cleanup وterminal prune تنفذان على دفعات صغيرة محدودة، مع yield وإعادة
  فحص الخمول بين الدفعات. التقدم الجزئي آمن وidempotent؛ طابع النجاح لا يكتب
  إلا عند اكتمال المسح.
- فحص page statistics لا يحدث عندما يكون vacuum throttle غير مستحق.
- `VACUUM` الكاملة لا تعمل أثناء startup ولا أثناء خدمة المستخدم. عند تحقق
  العتبات يسجل `vacuum_pending`، وتنفذ فقط بعد controlled restart drain وبعد
  flush لاستجابة restart وقبل خروج العملية القديمة.
- إذا لم يحدث إيقاف آمن تبقى الصيانة pending؛ استرداد المساحة لا يعلو على
  جاهزية الوكيل أو سلامة العمل.

### E.2 Execution checklist

- [x] جعل recovery queries تتجاهل orphan work items دون حذف startup.
- [x] إزالة الصيانة المتزامنة من المسار السابق لـrestore/start.
- [x] إضافة post-ready idle/grace scheduler محتوى للفشل وقابل للإلغاء.
- [x] تحويل orphan/terminal deletion إلى bounded batches مع pause عند النشاط.
- [x] تسجيل vacuum pending بعد thresholds دون تنفيذها أثناء الخدمة.
- [x] تنفيذ pending vacuum عند حد controlled restart الآمن فقط.
- [x] تحديث عقود schema/runtime وQA بما يزيل قرارات startup القديمة.
- [x] إضافة اختبارات ترتيب الجاهزية، الخمول، batching، pause/resume، وvacuum
      shutdown boundary.

### E Exit / Acceptance

- [x] على fixture قاعدة 1.088GB، median readiness للفرع لا يتجاوز `main`؛ تحقق first-upgrade عند `+8.435ms / +2.04%` ضمن الهامش، وsteady-state أسرع `0.826ms / 0.24%`.
- [x] لا تنفذ `DELETE`, page statistics، أو `VACUUM` قبل إعلان الجاهزية.
- [x] بدء عمل مستخدم يوقف دفعات الصيانة قبل الدفعة التالية.
- [x] لا تعمل `VACUUM` أثناء خدمة transports؛ تعمل فقط بعد drain آمن، وتبقى
      pending عند غياب هذا الحد.
- [x] تبقى حالات العمل النشطة والجلسات والرسائل وكاش الموديلات دون حذف.
- [x] analyzer، الاختبارات المركزة، full Agent suite، daemon-backed، وGraphify
      مرت قبل إعادة المهمة إلى `done`.

---

## Gate F — Post-merge CI lock regression

كشف تشغيل `main` رقم `35489731298` أن اختبار الجاهزية كان يفتح
`AgentStateDatabase` ثانية بينما daemon ما زال يملك القاعدة، فيشغّل migrations
كتابية ويتسابق على قفل SQLite. هذا عيب في الاختبار لا في الصيانة.

- [x] إيقاف daemon وانتظار خروجه قبل فتح اتصال التحقق.
- [x] إبقاء إثبات أن الجاهزية سبقت الصيانة وأن الصف الطرفي لم يُحذف.
- [x] تحديث QA لتثبيت حد الملكية الحصرية أثناء الاختبار.
- [x] تمرير الاختبار المركّز خمس مرات، analyzer، وfull Agent suite محلياً.
- [ ] تمرير CI.

### F Exit / Acceptance

- [x] لا يفتح الاختبار اتصال SQLite ثانياً أثناء امتلاك daemon للقاعدة.
- [x] لم يظهر `SQLITE_BUSY` في خمسة تشغيلات متتالية للاختبار.
- [ ] جميع required checks تمر قبل الدمج.

---

## 7. الملفات المتوقعة

### ملفات code مرجحة

- `agent/bin/daemon.dart`
- `agent/lib/core/di.dart`
- `agent/lib/evolution/db/agent_state_database.dart`
- `agent/lib/evolution/db/agent_state_maintenance_service.dart` (جديد)
- `agent/lib/evolution/db/agent_maintenance_state_repository.dart` (جديد)
- `agent/lib/evolution/db/runtime/session_work_item_repository.dart`
- `agent/lib/interfaces/runtime/session_recovery_restorer.dart`
- `agent/test/evolution/agent_state_maintenance_test.dart` (جديد)
- اختبار daemon-backed قائم أو جديد يختاره المنفذ بعد مراجعة الاختبارات الحالية

### ملفات documentation مطلوبة

- `docs/technical/agent_database_schema.md`
- `docs/qa_maintenance/agent_state_database_maintenance_qa.md` (جديد)
- `docs/plans/tasks/done/65-agent-state-database-auto-maintenance-and-vacuum.md`

لا تُنشأ الملفات الاختيارية إن أمكن تغطية المسؤولية بمالك قائم بوضوح، ويبقى
إجمالي التغيير ضمن `file_budget` ما لم يوثق المنفذ سبب تجاوزه قبل التوسع.

---

## 8. سيناريو النجاح

```text
Daemon startup
  Durable state restore (orphan rows ignored by live-session join)
  Gateway platforms start
Daemon ready
  30-second grace + idle
  Bounded orphan/terminal batches with yields
  free pages: 96 MiB / 31% -> vacuum_pending=true
Controlled restart
  safe drain + response flush
  pending VACUUM executes
  old process exits; new daemon reaches readiness without maintenance delay
```

وسيناريو الاحتواء الإلزامي:

```text
Daemon ready and serving
  deferred prune batch fails; warning emitted; success stamp remains due
Controlled restart
  pending VACUUM fails; marker remains pending; restart still exits
Next daemon startup
  restore/start/readiness remain independent from maintenance failure
```

---

## 9. Handoff Evidence (يملؤه المنفذ)

- **Changed files:**
  - `agent/bin/daemon.dart`
  - `agent/lib/core/di.dart`
  - `agent/lib/evolution/db/agent_state_database.dart`
  - `agent/lib/evolution/db/agent_state_maintenance_service.dart` (new)
  - `agent/lib/evolution/db/agent_maintenance_state_repository.dart` (new)
  - `agent/lib/evolution/db/runtime/session_work_item_repository.dart`
  - `agent/lib/interfaces/runtime/session_recovery_restorer.dart`
  - `agent/test/evolution/agent_state_maintenance_test.dart` (new)
  - `agent/test/guards/test_daemon_provider_startup_contract_guard.dart`
  - `agent/lib/evolution/db/AGENTS.md`
  - `agent/lib/evolution/db/runtime/AGENTS.md`
  - `agent/lib/interfaces/runtime/AGENTS.md`
  - `docs/technical/agent_database_schema.md`
  - `docs/technical/agent_runtime.md`
  - `docs/qa_maintenance/agent_state_database_maintenance_qa.md` (new)
  - `docs/qa_maintenance/MOC.md`
  - `docs/llms.txt`
  - `docs/plans/tasks/done/65-agent-state-database-auto-maintenance-and-vacuum.md`
- **Focused tests:** From `agent/`:
  - `fvm dart test test/evolution/agent_state_maintenance_test.dart` — 30 passed
  - `fvm dart test test/evolution/runtime_state_repositories_test.dart` — 22 passed
  - `fvm dart test test/interfaces/runtime/daemon_restart_coordinator_test.dart` — 14 passed
  - `fvm dart test test/guards/test_daemon_provider_startup_contract_guard.dart` — passed
  - `fvm dart test` — 1800 passed, 13 skipped
- **Analyzer/format:** `fvm dart analyze` — no issues. Focused Dart format check passed.
- **Daemon-backed verification:** sequential named test passed and proves `Daemon is running` precedes deferred deletion while queued work remains intact.
- **Large-fixture performance:** authorized read-only backup, 1,088,159,744 bytes, AOT, 25 alternating samples per side. First-upgrade median: `main=414.049ms`, branch=`422.484ms` (`+8.435ms`, `+2.04%`, within gate). Steady median: `main=346.422ms`, branch=`345.596ms` (`-0.826ms`, `-0.24%`). Deferred pass completed 1,872 terminal deletes after readiness, marked 380,420,096 reclaimable bytes pending, and did not shrink the serving file.
- **Graphify update:** `graphify update .` — rebuilt successfully (25113 nodes); HTML visualization skipped automatically above the 5000-node limit.
- **Known limitations/follow-ups:** provider model cache eviction intentionally excluded. File count exceeded the planned 12 because durable ownership required `AGENTS.md` updates in three owners, plus index updates (`docs/llms.txt`, `docs/qa_maintenance/MOC.md`) and a stale call-site sentence in `docs/technical/agent_runtime.md`. Daemon-backed coverage was added to the planned test file rather than a new file. Independent review added vacuum 7-day throttle and zero-row prune stamp tests.
