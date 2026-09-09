---
title: "Task 51: Message Replay Soft Rewind and Idle Hardening"
description: "إغلاق فجوات Task 49 عبر soft rewind ذري، وهوية turn ثابتة، واشتراط idle authoritative قبل Edit/Retry دون حذف التاريخ الأصلي."
status: "completed"
current_gate: "Gate F — completed"
review_remaining: "0%"
priority: "high"
scope: "Sanad agent replay persistence/protocol and Flutter conversation replay recovery"
depends_on: "Task 49 completed behavior, Task 31 authoritative session state, Task 36 queue/steer/stop recovery"
coordinates_with: "Task 50 cancellation hardening"
---

# Task 51: Message Replay Soft Rewind and Idle Hardening

## 1. المشكلة

نفذت Task 49 تجربة Edit/Retry، بوابة الإيقاف، تأكيد آثار الأدوات، واستخدام
المزود والنموذج الحاليين. لكن عقد replay الحالي ما زال يصف إزالة أو `truncate`
للرسالة المستهدفة وذيلها. هذا يفقد التاريخ الأصلي ويجعل التعافي والتدقيق عرضة
للفجوات إذا نجح تعديل التاريخ ثم فشل قبول الجولة البديلة.

كذلك يجب ألا تكون `terminal cancellation` وحدها بوابة كافية لبدء الجولة الجديدة:
كل حالة غير `idle`، بما فيها `queued` و`stopping`، يجب أن تنتهي إلى snapshot
authoritative تؤكد `idle`. وبعد الانتظار يجب إعادة التحقق من هوية الرسالة وحد
الجولة ومراجعة التاريخ حتى لا ينفذ أمر replay قديم فوق حالة أحدث.

توجد فجوة أهلية إضافية من Task 49: رسالة `steer` تظهر في timeline كحدث user
وتحمل `request_id`، ولذلك قد تعرض الواجهة Edit/Retry عليها باعتبارها آخر رسالة
مستخدم. لكن steer ليست بداية turn مستقلة؛ إنها input تابعة لجولة المستخدم
الأصلية وقد تكون محفوظة كسجل user بعلامة steer أو معاد بناؤها من metadata داخل
tool result. معاملتها كحد replay مستقل قد يفشل في العثور على الحد، أو يقطع
الجولة من موضع غير صحيح، أو يصنف أدوات سبقت steer على أنها آمنة خطأً.

## 2. الهدف

1. استبدال الحذف أو `truncate` بـ**Soft Rewind** ذري يحفظ الرسالة الأصلية وكل
   أحداث الجولة القديمة كسجلات غير نشطة.
2. عدم بدء Edit Send أو Retry إلا بعد وصول الجلسة إلى `idle` authoritative،
   دون قبول حالة terminal وسيطة كبديل.
3. تثبيت هوية الرسالة والجولة والطلب والتشغيل، مع revision متزايدة لتاريخ
   الجلسة وحماية compare-and-swap من الأوامر القديمة.
4. جعل تعطيل الذيل وقبول الرسالة البديلة عملية ذرية: إما ينجحان معًا أو يبقى
   التاريخ الأصلي ظاهرًا وفعالًا دون تغيير.
5. الحفاظ على سلوك Task 49 المعتمد: inline Edit، الإلغاء عند navigation، تأكيد
   `unsafe|unknown` قبل أي Stop، واستخدام route الحالية عند الإرسال النهائي.
6. قصر Edit/Retry على أحدث **root user turn** مؤهلة، ومنع عرضهما أو قبولهما
   على pending/delivered/embedded steer مهما كان شكل تخزينها أو إعادة بنائها.

## 3. قرارات التصميم الملزمة

### 3.1 هوية التاريخ والجولة

- لكل سجل رسالة `message_id` ثابت لا يتغير بسبب hydration أو pagination.
- كل أحداث محاولة تنفيذ واحدة تحمل `turn_id` واحدًا.
- `request_id` يعرّف قبول طلب المستخدم أو أمر replay الجديد، و`run_id` يعرّف
  محاولة runtime الفعلية؛ لا يستخدم أي منهما بدل الآخر.
- لكل جلسة `history_revision` متزايدة تُحدّث داخل معاملات تغيير التاريخ.
- يحمل أمر replay على الأقل:
  `session_id + target_message_id + target_turn_id + target_request_id + expected_history_revision`.
- الرسالة البديلة تحصل على `message_id`, `turn_id`, `request_id`, و`run_id`
  جديدة، مع مرجع `replays_turn_id` أو `supersedes_turn_id` إلى الجولة القديمة.
- لا يسمح fallback بالنص أو timestamp عند غياب الهوية؛ تعاد نتيجة typed ولا
  يتغير التاريخ.

### 3.2 Soft Rewind

- عند القبول، تصبح رسالة المستخدم المستهدفة وكل الأحداث النشطة التابعة لها
  بعدها `inactive/superseded` بدل حذفها.
- تحتفظ السجلات القديمة بالمحتوى، reasoning، tool calls/results، provider state،
  metadata، والترتيب الأصلي لأغراض التدقيق والتعافي.
- history العادية، timeline، وسياق النموذج تعرض السجلات النشطة فقط.
- لا تعيد Retry تشغيل tool results القديمة؛ إنها تنشئ محاولة جديدة وقد تعيد
  تنفيذ الأدوات بعد التأكيد المطلوب.
- لا تصبح السجلات القديمة فعالة تلقائيًا بعد reconnect أو cache hydration.

### 3.3 ترتيب العملية

الترتيب الملزم عند Retry أو Edit Send هو:

1. تصنيف replay safety والتحقق من هوية الهدف.
2. طلب تأكيد المستخدم إذا كان التصنيف `unsafe|unknown`؛ الرفض لا يرسل Stop ولا
   يغير التاريخ.
3. إيقاف/إلغاء العمل المملوك للجلسة إذا كانت حالتها
   `queued|running|waiting|blocked|resuming|stopping`.
4. انتظار snapshot جديدة تؤكد `idle` تحديدًا.
5. إعادة قراءة الهدف و`history_revision` والتأكد أنه ما زال آخر user turn فعالة.
6. تنفيذ Soft Rewind وقبول الرسالة البديلة ذريًا، ثم زيادة revision.
7. dispatch مرة واحدة باستخدام provider/model/thinking المختارة حاليًا.

فتح محرر Edit فقط يبقى تغيير UI محليًا ولا يرسل Stop. يبدأ الترتيب السابق عند
ضغط `Send`. أما Retry فيبدأ preflight مباشرة.

### 3.4 Queue وSteer

- لا تختلط queued message أو pending steer مع الجولة البديلة.
- يستخدم الإلغاء مسار Task 36 authoritative، ويحافظ على أي نص قابل للاستعادة
  كمسودة وفق عقد Stop recovery بدل إسقاطه بصمت.
- إذا ظهر user turn أحدث أثناء الانتظار، يفشل replay بنتيجة `stale_turn_boundary`
  ولا يعطل أي سجل.
- لا يمس الإلغاء work أو queue في جلسة أخرى.

### 3.5 أهلية Steer وملكية الجولة

- steer ليست turn مستقلة ولا يجوز استخدامها كـreplay boundary حتى لو ظهرت
  كـ`EventKind.userMessage` أو حملت `request_id` مستقلة.
- يضاف تصنيف canonical دائم لمدخل المستخدم، مثل
  `input_kind: root_turn|steer` أو `turn_role: root|steer`؛ لا تعتمد الأهلية على
  `role=user` أو موضع الحدث أو وجود `request_id` فقط.
- daemon هو المالك النهائي للأهلية ويعيد outcome typed مثل
  `target_not_replayable_input` لأي pending/delivered/embedded steer، حتى لو
  أرسل client قديم أو تالف الأمر مباشرة.
- client يعرض Edit/Retry على أحدث root user turn مؤهلة فقط. pending steer تحتفظ
  بإجراء Cancel/Delete الخاص بها، ولا تجمع بينه وبين إجراءات replay.
- latest-turn validation تتجاهل steer كمرشح root مستقل، لكنها تعدها جزءًا من
  ذيل الجولة الأصلية عند Soft Rewind.
- عند replay للجولة الأصلية، تصبح كل steers التابعة لها superseded مع بقية
  أحداث الجولة ولا يعاد حقنها تلقائيًا؛ إعادة حقنها عند tool boundaries القديمة
  ليست replay صحيحة.
- إذا احتوت الجولة الأصلية على steer واحدة أو أكثر، يعيد preflight علامة
  `contains_steers` ويطلب تأكيدًا واضحًا بأن رسائل التوجيه التابعة لن تعاد
  تلقائيًا، حتى إن كان تصنيف الأدوات `safe`.
- tool replay safety تُحسب على **كامل الجولة الأصلية** من root user boundary،
  لا من موضع steer ولا من request ID الخاصة بها، حتى لا تُستبعد أدوات سبقتها.

## 4. بوابة التنفيذ

- [x] مراجعة وثائق Task 49 الحالية وتحديد كل موضع يصف delete أو `truncate`.
- [x] اعتماد تمثيل `active/superseded` وعلاقة supersession قبل تعديل التخزين.
- [x] اعتماد ملكية `message_id`, `turn_id`, `request_id`, `run_id`, و`history_revision`.
- [x] تحديد المعاملة الذرية التي تجمع Soft Rewind مع قبول الجولة البديلة.
- [x] تحديد migration/backfill للسجلات الحالية دون مطابقة بالنص أو timestamp.
- [x] توثيق outcomes الجديدة أو المعدلة قبل تغيير client/agent contract.
- [x] اعتماد تصنيف root/steer canonical لكل صور steer القديمة والحالية.

### 4.1 القرارات المعتمدة

العقد الحالي (Task 49) ما زال يحذف التاريخ: `TurnReplayService.truncateAtTarget`
يعيد كتابة القائمة حتى قبل الهدف، والبروتوكول والـQA يصفان `truncate` للعميل.
هويات الـtimeline الحالية هي فهرس hydration (`++index`) وليست `message_id`.
`canReplay` يعتمد على آخر حدث user يحمل `request_id`، فيشمل steer.

التمثيل المعتمد قبل تعديل التخزين:

- أعمدة `messages`: `message_id`, `turn_id`, `history_status`,
  `superseded_by_turn_id`, `input_kind`, `request_id`, `run_id`.
  `messages.id` يبقى مؤشر الترتيب الفيزيائي فقط.
- `sessions.history_revision` مستقل عن revision التنفيذ و`route_revision`.
- القراءة العادية: `history_status = active`. المسار الداخلي للتدقيق يطلب
  superseded صراحة.
- المعاملة الذرية: CAS لـ`history_revision`، تعليم الهدف وكل السجلات النشطة
  بعده `superseded` مع `superseded_by_turn_id` للـturn البديلة، إدراج رسالة
  المستخدم البديلة `active` بهويات جديدة، ثم زيادة revision. أي فشل يعيد
  rollback. الـdispatch يحدث بعد الـcommit فقط.
- backfill حسب ترتيب `id` داخل كل جلسة: UUID مخزّن لكل صف، `turn_id` جديد عند
  كل root user، و`input_kind=steer` من `metadata.steer` أو `steer_messages`.
  لا مطابقة بالنص أو الوقت. السجل بلا `request_id` مرئي وغير قابل لـreplay.
- outcomes الجديدة موثّقة في
  `docs/technical/message_turn_replay_protocol.md` قبل تغيير الشيفرة:
  `target_not_replayable_input`, `identity_incomplete`,
  `history_revision_mismatch`, `steer_reinjection_confirmation_required`.

## 5. النطاق المرحلي

### Gate A — Persistence identity and migration

- [x] إضافة الهوية الثابتة وحقول النشاط/supersession ومراجعة التاريخ المطلوبة.
- [x] backfill deterministic للسجلات القابلة للهجرة، ووسم legacy غير القابل
      للتحديد كغير قابل لـreplay بدل التخمين.
- [x] جعل القراءة العادية تعيد السجلات النشطة فقط مع مسار داخلي صريح للتدقيق.
- [x] ضمان أن pagination والترتيب يعتمدان مفاتيح ثابتة ولا يعيدان سجلات superseded.

#### Gate A Exit

- [x] restart وhistory hydration يحافظان على نفس الهويات وحالة النشاط.
- [x] لا تختفي السجلات القديمة من قاعدة البيانات بعد replay.

### Gate B — Atomic replay admission

- [x] توسيع `session.turn_replay` بهوية الهدف و`expected_history_revision`.
- [x] رفض أي target مصنفة steer قبل Stop أو history mutation، مع outcome typed.
- [x] تسلسل replay command لكل جلسة ومنع قبول أمرين متزامنين للهدف نفسه.
- [x] تنفيذ CAS داخل معاملة واحدة: revalidate target، soft rewind، إنشاء/قبول
      الرسالة البديلة، زيادة revision.
- [x] إذا فشل قبول الرسالة البديلة، rollback كامل يبقي الجولة الأصلية فعالة.
- [x] إنشاء typed outcomes لـrevision mismatch والهدف القديم وعدم الوصول إلى idle.

#### Gate B Exit

- [x] كل أمر مقبول ينتج محاولة بديلة واحدة فقط.
- [x] لا توجد حالة يصبح فيها التاريخ القديم غير نشط دون قبول بديل دائم.

### Gate C — Authoritative idle and client reconciliation

- [x] توحيد كل الحالات غير idle عبر stop/cancel scoped ثم انتظار `idle` فقط.
- [x] عدم اعتبار terminal work item أو cancellation acknowledgement تصريح dispatch.
- [x] إعادة التحقق من الهدف والـrevision بعد idle مباشرة وقبل المعاملة.
- [x] تحديث cache/live projection باستخدام الهوية وrevision بدل truncate متفائل.
- [x] إبقاء timeline الأصلية ظاهرة عند timeout أو stale boundary أو rollback.
- [x] الحفاظ على إلغاء inline Edit عند session/device/New Conversation navigation.
- [x] اشتقاق `canReplay` من أهلية root turn authoritative، لا من آخر user event.
- [x] عدم عرض Edit/Retry على pending steer أو delivered steer أو steer معاد بناؤها
      من tool-result metadata.

#### Gate C Exit

- [x] لا يبدأ provider run جديد قبل snapshot idle authoritative.
- [x] reconnect أو live event متأخر لا يعيد الجولة superseded ولا يكرر البديلة.

### Gate D — Side-effect and route parity

- [x] الحفاظ على تصنيف `safe|unsafe|unknown` قبل أي mutation.
- [x] حساب tool safety من root boundary عبر كامل الجولة بما فيها الأدوات السابقة
      واللاحقة لأي steer.
- [x] الرفض في confirmation لا يرسل Stop ولا يغير history revision.
- [x] طلب تأكيد مستقل عند `contains_steers` يوضح أن التوجيهات التابعة لن تعاد.
- [x] بعد الموافقة يستخدم dispatch provider/model/thinking الحالية في الطلب النهائي.
- [x] تغيير route أثناء نافذة التأكيد يُقرأ مرة أخرى عند الإرسال النهائي.

### Gate E — Verification and documentation

- [x] اختبارات DB: soft rewind، rollback، revision CAS، restart، legacy identity.
- [x] اختبارات agent: كل حالة غير idle إلى stop/cancel ثم idle ثم replay.
- [x] اختبارات race: replay مزدوج، رسالة أحدث أثناء الانتظار، snapshot قديمة، reconnect.
- [x] اختبارات queue/steer recovery وعدم التأثير على جلسة أخرى.
- [x] اختبارات أهلية UI لكل من root user، pending steer، delivered steer،
      embedded steer، وlate steer المحفوظة كرسالة user.
- [x] اختبارات daemon تثبت رفض target steer قبل Stop/mutation حتى مع client مباشر.
- [x] اختبار safety يثبت أن أداة unsafe سبقت steer لا تُستبعد من التصنيف.
- [x] اختبار replay للـroot يثبت supersede لكل steers التابعة وعدم إعادة حقنها.
- [x] اختبارات client cache/widget لعدم ظهور superseded وإبقاء الأصل عند الرفض.
- [x] تحديث وثائق product/technical/database/QA المتأثرة وإزالة وصف `truncate` القديم.

### Gate F — Compaction replay guard

- [x] يعتبر آخر `context_compaction.completed` حدًا بسيطًا: لا تقبل Edit/Retry لأي root user message كانت موجودة قبله، دون تفريع source/tail.
- [x] يرفض daemon الطلب قبل Stop أو soft rewind بنتيجة typed `target_precedes_compaction`.
- [x] يخفي client إجراءات Edit/Retry للرسائل السابقة لآخر حدث ضغط مكتمل، مع بقاء daemon مصدر الحماية.
- [x] لا تمنع عملية ضغط failed/cancelled الرسائل اللاحقة أو السابقة من replay.
- [x] تغطي الاختبارات hydration والطلب المباشر من client قديم وعدم تغير التاريخ عند الرفض.

#### Gate F Acceptance

- [x] Given رسالة تسبق آخر ضغط مكتمل، when يعرض التاريخ أو يصل replay command مباشر، then لا تظهر الإجراءات ويرفض daemon دون mutation.
- [x] Given رسالة أُنشئت بعد آخر ضغط مكتمل، then تبقى أهلية Edit/Retry الحالية دون تغيير.

## 6. Definition of Done

- [x] Edit/Retry لا يحذفان تاريخ الجولة الأصلية فعليًا.
- [x] normal history وسياق النموذج لا يعيدان السجلات superseded.
- [x] لا dispatch قبل `idle` authoritative في أي مسار.
- [x] Soft Rewind وقبول البديل ذريان وقابلان للـrollback.
- [x] الهوية والـrevision تمنعان replay قديمة أو مزدوجة.
- [x] queued/steer النصية تُستعاد وفق Task 36 ولا تختلط بالجولة الجديدة.
- [x] لا تظهر Edit/Retry على أي steer ولا يقبل daemon steer كحد replay.
- [x] أحدث root user turn تبقى هي المرشح الصحيح حتى عند وجود steers تابعة بعدها.
- [x] replay للجولة ذات steers يتطلب إقرار إسقاط إعادة حقنها ويحسب tool safety
      على كامل الجولة.
- [x] تحذير آثار الأدوات وroute الحالية وسلوك inline Edit لا تتراجع.
- [x] تحليلات agent/client والاختبارات المركزة المناسبة ناجحة.

## 7. سيناريو النجاح

توجد جلسة `blocked` بعد تنفيذ أداة `unsafe`. يضغط المستخدم Retry، فيظهر التحذير
قبل أي Stop. بعد الموافقة تُلغى الجولة المملوكة، وتستعاد أي pending steer كمسودة،
وينتظر النظام snapshot `idle`. يعاد التحقق من الهدف والـrevision، ثم تُعلّم
الجولة القديمة ونتائج أدواتها superseded وتُقبل رسالة بديلة جديدة داخل معاملة
واحدة. بعد restart تظهر المحاولة الجديدة فقط في timeline، بينما تظل الجولة
القديمة محفوظة في قاعدة البيانات ولا يمكن لحدث متأخر إعادتها.

في نسخة السيناريو التي تحتوي steer بعد tool result، لا تظهر Edit/Retry على
فقاعة steer، ويرفض daemon استهداف request ID الخاصة بها دون Stop. تظهر الإجراءات
على root user turn فقط؛ وعند Replay لها يشمل تصنيف السلامة الأداة التي سبقت
steer، ويطلب النظام أيضًا تأكيد عدم إعادة حقن رسائل steer التابعة.

## 8. خارج النطاق

- Fork أو branch لمحادثة؛ تملكه Task 52.
- إتاحة Edit/Retry لأي turn أقدم من آخر user turn فعالة.
- دعم تعديل steer أو إعادة حقنها عند نقطة tool قديمة؛ يحتاج ذلك عقد replay خاصًا
  مختلفًا عن إعادة تشغيل root turn.
- جعل الأدوات ذات الآثار الجانبية idempotent.
- إعادة تصميم timeline أو composer خارج حالات replay الحالية.

## 9. الملفات والوثائق المتوقعة

- `agent/lib/evolution/db/`
- `agent/lib/interfaces/runtime/`
- `agent/lib/interfaces/platforms/sanad_gateway/`
- `client/lib/features/conversations/`
- اختبارات agent/client المركزة
- `docs/product/message_edit_retry_ux.md`
- `docs/technical/message_turn_replay_protocol.md`
- `docs/technical/agent_database_schema.md`
- `docs/qa_maintenance/message_edit_retry_qa.md`

## 10. سجل التقدم

```text
Date: 2026-08-30
Gate/status: Gates A–E verified closed; Task 51 completed
Files changed:
  Gate B: pending steer request ids fail as target_not_replayable_input
    before Stop/mutation.
  Gate C: idle wait is fail-closed without a snapshot owner; replacement
    dispatch echo carries message_id/turn_id; e2e runtime now registers
    AgentStateDatabase + PersistedRuntimeStateRepository so idle is real.
  Gate D: no additional code; safety-before-Stop, steer-drop confirmation,
    and final-command route re-read hold.
  Gate E: graphify update after the review repairs.
Verification:
  fvm dart test test/evolution/message_history_identity_test.dart \
    test/interfaces/runtime/turn_replay_service_test.dart \
    test/interfaces/platforms/sanad_gateway/session_turn_replay_command_handler_test.dart
    -> All tests passed (33)
  fvm dart test e2e_test/sanad_gateway_platform_e2e_test.dart \
    --name "replays an edited latest turn" --concurrency=1
    -> All tests passed
  fvm flutter test test/unit/stores/turn_replay_projection_test.dart \
    test/unit/services/device_conversation_commands_test.dart \
    test/widget/message_edit_event_tile_test.dart
    -> All tests passed (47)
  graphify update . -> Rebuilt
Findings:
  Soft rewind is atomic with replacement. Idle wait no longer skips when
  snapshot state is missing. Steer is never a replay boundary. Truncate
  language remains only as historical Task 49 contrast.
Next gate: none — Task 51 implementation complete; review requested before Task 52
```

### مراجعة 2026-08-31

```text
Gate/status: Gate A review closed; Gate B review next
Remaining: 80% (Gates B-E)
Finding repaired:
  MessageHistoryIdentity.persist previously matched updates globally by
  message_id. Updates are now constrained by session_id, and a duplicate
  identity from another session fails atomically instead of mutating its row.
Verification:
  fvm dart test test/evolution/message_history_identity_test.dart
    -> All tests passed (8)
  fvm dart analyze lib test/evolution/message_history_identity_test.dart \
    test/voice/voice_engine_test.dart test/interfaces/interfaces_test.dart
    -> No issues found
  git diff --check -> passed
Next gate: Gate B — Atomic replay admission
```

```text
Gate/status: Gate B review closed; Gate C review next
Remaining: 60% (Gates C-E)
Findings repaired:
  Embedded steer identities now return target_not_replayable_input before
  Stop or mutation, matching pending and delivered steer behavior.
  Transaction-failure coverage now forces an in-transaction supersession
  failure and proves full rollback plus typed failed outcome.
Verification:
  fvm dart test test/interfaces/runtime/turn_replay_service_test.dart \
    test/interfaces/platforms/sanad_gateway/session_turn_replay_command_handler_test.dart
    -> All tests passed (30)
  fvm dart analyze lib/interfaces/runtime/turn_replay_service.dart \
    lib/interfaces/platforms/sanad_gateway/handlers/session_turn_replay_command_handler.dart \
    test/interfaces/runtime/turn_replay_service_test.dart \
    test/interfaces/platforms/sanad_gateway/session_turn_replay_command_handler_test.dart
    -> No issues found
  git diff --check -> passed
Next gate: Gate C — Authoritative idle and client reconciliation
```

```text
Gate/status: Gate C review closed; Gate D review next
Remaining: 40% (Gates D-E)
Findings repaired:
  Client replay eligibility now requires daemon-authored input_kind=root_turn
  and replay_eligible=true; complete identities alone no longer grant actions.
  Rapid SessionManager.createSession calls could collide because ids used
  millisecond timestamps. UUID session ids now preserve cross-session isolation.
  Added accepted-only history_revision reconciliation and reconnect/late-event
  non-resurrection coverage.
Verification:
  agent replay handler tests -> All tests passed (17)
  client focused state/bloc/navigation tests -> All tests passed (68)
  fvm flutter analyze -> No issues found
  focused agent analyze -> No issues found
  daemon-backed replay E2E --concurrency=1 -> All tests passed (1)
  git diff --check -> passed
Note:
  Full agent analysis currently reports five pre-existing Task 52 test lints;
  they are deferred until Task 51 Gate E/full verification to avoid reviewing
  Task 52 ahead of the requested order.
Next gate: Gate D — Side-effect and route parity
```

```text
Gate/status: Gate D review closed; Gate E review next
Remaining: 20% (Gate E)
Review result:
  Safety classification, confirmation-before-Stop, steer-drop confirmation,
  and final-command route handling match the gate contract.
Coverage added:
  Confirmation resubmission now proves provider/model/thinking are re-read
  from current client state after a route change during the prompt window.
Verification:
  agent replay service/handler tests -> All tests passed (30)
  client flow/command tests -> All tests passed (57)
  focused agent analyze -> No issues found
  fvm flutter analyze -> No issues found
  git diff --check -> passed
Next gate: Gate E — Verification and documentation
```

```text
Gate/status: Gate E review closed; Task 51 complete
Remaining: 0%
Documentation:
  Product, replay protocol, database schema, QA matrix, MOCs, and llms index
  consistently describe soft rewind with inactive retained history.
  QA now explicitly covers daemon-authored eligibility and rapid-session UUID
  isolation; remaining truncate wording is historical contrast or explicit denial.
Verification:
  fvm dart analyze -> No issues found
  fvm flutter analyze -> No issues found
  focused agent replay tests -> All tests passed (38)
  focused client replay/navigation/widget tests -> All tests passed (130)
  full agent fast suite -> All tests passed (1243; 12 skipped)
  full client fast suite -> All tests passed (1116; 1 skipped)
  replay daemon E2E --concurrency=1 -> All tests passed (1)
  git diff --check -> passed
Verification hardening:
  Replaced an unbounded response-count polling loop in the resume fallback test
  with a bounded two-response completion barrier; the isolated and full suites pass.
Next gate: none — Task 51 review complete; Task 52 review may begin
```

```text
Gate/status: interactive verification repair in progress
Remaining: 10% (live UI acceptance and temporary override removal)
Findings:
  Live daemon replay/fork commands persist correct root/final identities and the
  replay daemon E2E passes edit, retry, and fork against the isolated runtime.
  Hydrated final_answer rows omitted status=done, so Fork disappeared after
  navigation even though the live final event was eligible; history now emits
  the terminal status explicitly.
Interactive verification closed:
  The temporary eligibility override is removed. Authoritative history preserves
  final-answer message_id/turn_id through the client mapper, so Edit, Retry, and
  Fork remain visible from real daemon eligibility after hydration.
  Replay results project authoritative history_revision into both the selected
  session and cached session lists. One bounded retry recovers a revision mismatch
  without a false error toast.
  User-visible toasts remain open for five seconds, and every error toast is
  logged centrally by ToastUtils for diagnosis.
Visual acceptance:
  The user arranged and accepted the final-answer footer in explicit LTR order:
  response statistics, Fork, then Copy. The compact actions share a 28x28 button,
  15px icon, centered zero-padding layout, and onSurfaceVariant at 60% alpha.
Runtime evidence:
  Fork created and opened child session da45e671-d154-4ac2-9d07-8b3fb02a5045.
  Retry was accepted and produced LIVE_ALPHA. Edit recovered from revision 1,
  was accepted at revision 2, and produced LIVE_EDIT_OK without an error toast.
  Temporary identity/revision diagnostics were removed after success; the central
  error-toast warning remains as the durable diagnostic contract.
Remaining: 0% — Task 51 interactive verification complete.
```
