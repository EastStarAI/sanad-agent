---
title: "المهمة 78: تطابق رسائل Steer والطابور وتغيير المزود وضبط طلبات فتح المحادثة"
description: "إصلاح دورة حياة Pending Steer والطابور وStop، وضمان تطابق موضع الأحداث بين البث والتاريخ، ومنع طلبات الوكيل المكررة عند فتح المحادثة دون الإضرار بتجربة المستخدم."
status: "pending"
current_gate: "البوابة A — تثبيت العقود وإعادة الإنتاج"
priority: "critical"
depends_on: "Task 31 authoritative execution snapshots, Task 36 authoritative steer/queue/stop recovery, conversation live/history parity"
file_budget: 30
design_contract: "docs/technical/agent_interface_runtime.md"
qa_contract: "docs/qa_maintenance/task36_authoritative_steer_queue_stop_recovery_matrix.md"
remaining_estimate_percent: 100
---

# المهمة 78: تطابق رسائل Steer والطابور وتغيير المزود وضبط طلبات فتح المحادثة

## 1. المشكلة

توجد مجموعة مترابطة من العيوب في عرض وإدارة مدخلات المستخدم غير المنفذة، وفي
تطابق المحادثة الحية مع تاريخها، وفي عدد الطلبات التي يرسلها العميل إلى الوكيل
عند فتح المحادثة:

1. حذف رسالة `Pending Steer` قد ينجح لدى الوكيل بينما تبقى الرسالة عالقة في
   الواجهة.
2. رسالة `Pending Steer` تدخل timeline العادية فور قبولها، فتظهر أحيانًا فوق
   أدوات نُفذت بعدها رغم أنها لم تدخل model history بعد.
3. عند الانتقال إلى محادثة أخرى ثم العودة، يعيد history hydration الرسالة في
   موضع مختلف وأصح؛ أي إن العرض الحي والتاريخي غير متطابقين.
4. حالة `delivering` لا تُعامل دائمًا كمدخل غير منفذ، ولذلك قد تظهر بجوارها
   أزرار `Edit` و`Retry` الخاصة برسالة تاريخية قابلة لإعادة التشغيل.
5. رسالة الطابور تظهر بصورة صحيحة، لكن زر حذفها لا يزيلها وقد يترك صفها في
   حالة تحميل دائمة.
6. بعد `Stop` تُعاد مدخلات `Pending Steer` والطابور إلى draft، وتُنظف قاعدة
   بيانات الوكيل، لكن طابور العميل قد يبقى ظاهرًا.
7. إشارة تغيير المزود تظهر في موضعها أثناء البث، لكنها قد تظهر في موضع خاطئ أو
   تختفي عند إعادة فتح المحادثة من التاريخ.
8. فتح محادثة واحدة يطلق طلبات ثانوية متكررة أو غير ضرورية، مثل
   `workspace.get_policy` و`model.snapshot` و`provider.usage.support` و
   `provider.usage.get`، إضافة إلى طلب التاريخ الضروري، دون امتلاك ميزانية
   طلبات أو إبطال cache قائم على revisions.

هذه المشكلات ليست مستقلة: السبب المشترك هو غياب فصل واضح بين **المدخل المعلق**
و**حدث timeline المنفذ**، واعتماد بعض Widgets على طلب البيانات مباشرة، وعدم
وجود عقد موحد كافٍ لترتيب mutation outcomes وlive events وhistory hydration.

---

## 2. نتائج الاستكشاف المثبتة

### 2.1 حذف رسالة الطابور

يرسل الوكيل نتيجة `session.queued_message_delete_result` في الحقل `outcome`،
بينما يقرأ العميل الحقل `state`. نتيجة ذلك أن العميل يرى نتيجة مجهولة ولا يحذف
الصف ولا ينهي progress الخاص به.

### 2.2 حذف Pending Steer

يعتمد العميل على وصول `session.pending_steer_changed` منفصل لإزالة الرسالة،
بينما `session.pending_steer_cancel_result` لا يزيل stale projection عند
`cancelled` أو `already_cancelled`. فقد أحد الحدثين أو اختلاف ترتيبهما يترك
الرسالة عالقة، وهذا يخالف مصفوفة Task 36 الحالية.

### 2.3 موضع Pending Steer

يحول `DeviceConversationStore` السجل المعلق فورًا إلى `CanonicalEvent` من نوع
`userMessage` داخل timeline نفسها. الأدوات اللاحقة تُضاف تحته، مع أن الرسالة لم
تُسلّم بعد. عند إعادة فتح المحادثة يعيد الوكيل بناء الرسالة المنفذة من
`steer_messages` في history، فتظهر في موضع آخر.

### 2.4 أزرار Edit وRetry

تتعرف الواجهة على `pending` فقط كحالة غير نهائية. حالة `delivering` قد تمر إلى
منطق replay، فتظهر أزرار لا يجوز عرضها قبل أن تصبح الرسالة حدثًا تاريخيًا
منفذًا.

### 2.5 Stop والطابور

يوجد تنظيف للـqueue داخل `applyStopRecovery`، لكن تقارب الواجهة يعتمد على وصول
حدث استرجاع draft نفسه. حدث `stopped` أو execution snapshot لا يضمنان حاليًا
تنظيف queue projection بصورة مستقلة، ولذلك يمكن أن تبقى واجهة قديمة رغم نظافة
الحالة الدائمة.

### 2.6 تغيير المزود

يحفظ الوكيل route transitions بصورة دائمة، لكنه يعيد إدخالها في history بعد
آخر صف يحمل `request_id` نفسه. أغلب صفوف الأدوات والمساعد لا تحمل هذا المعرّف،
فتُربط الإشارة غالبًا برسالة المستخدم الأولى لا بالـmodel step أو الأداة التي
حدث عندها الانتقال. أما fallback الزمني فيقارن أوقاتًا حقيقية بأوقات history
مصطنعة. كما أن history يعرض حاليًا `autoFailover` فقط، ويجب تثبيت سياسة ظهور
انتقالات `user` و`recovery` بدل تركها ضمنية.

### 2.7 طلبات فتح المحادثة

- `get_session_history` طلب صحيح عند غياب snapshot حديث أو الحاجة إلى
  authoritative resynchronization.
- `workspace.get_policy` يُستدعى من أكثر من lifecycle path دون cache/revision
  guard واضح يكفي للتنقل المتكرر.
- تحميل أسماء المزود و`model.snapshot` مكرر داخل أكثر من Widget، والـcache
  محلية لعمر الـWidget.
- `ProviderUsageCubit.onInstancesLoaded` يمكن استدعاؤه من أكثر من واجهة عند
  mount، ويعيد `provider.usage.support` ويلغي sequences سابقة حتى لو لم تتغير
  هوية المزود.
- الاختبارات المركزة الحالية تمر، لكنها لا تغطي payload الحقيقي لحذف queue،
  ولا ترتيب pending delivery الحي، ولا Stop daemon-backed، ولا ميزانية الطلبات.

---

## 3. الهدف

إنشاء مسار authoritative واحد يحقق ما يلي:

1. تمثيل `Pending Steer` و`delivering` كمدخلات معلقة مرتبطة بالجلسة وليست
   أحداثًا منفذة داخل timeline.
2. إبقاء هذه المدخلات في منطقة ثابتة أسفل المحادثة حتى إلغائها أو تسليمها
   الفعلي، مع بقائها بعد التنقل وإعادة الاتصال.
3. عند التسليم، إزالة المدخل من المنطقة المعلقة وإدخاله مرة واحدة في timeline
   عند موضعه canonical الحقيقي، بحيث يتطابق البث مع history.
4. جعل حذف Pending Steer وحذف queue وStop عمليات authoritative وidempotent لا
   تترك صفوفًا أو progress عالقة.
5. حفظ وعرض انتقالات المزود في الموضع نفسه live وبعد فتح التاريخ.
6. تقليل طلبات فتح المحادثة إلى الحد الضروري بواسطة مالكي state مركزيين، وطلب
   موحد in-flight، وcache ذات freshness/revision، مع عرض فوري من cache وتحديث
   خلفي لا يحجب المستخدم.

---

## 4. القرارات والمعايير المعمارية الملزمة

- الوكيل هو المالك الوحيد لتصنيف delivery وحالة queue وpending delivery وStop
  وموضع الحدث المنفذ.
- العميل لا ينشئ optimistic queue أو delivered timeline event ولا يستنتج نجاح
  mutation من الضغط على الزر.
- raw `request_id` هو هوية mutation والمصالحة؛ لا يستخدم `user_<id>` كهوية نقل.
- `pending` و`delivering` ليستا رسالتين تاريخيتين قابلتين لـEdit أوRetry.
- pending lane تكون projection داخل store/domain ومحددة بالـdevice والـsession؛
  لا تمتلكها Widget ولا تضيع بإعادة بنائها.
- الانتقال إلى `delivered` لا يثبت موضع timeline اعتمادًا على `received_at`
  وحده. يجب استخدام sequence أو event anchor دائم صادر من الوكيل.
- queue cleanup مستقل عن امتلاك draft recovery؛ كل العملاء يرون الحالة المشتركة
  فارغة، بينما العميل المالك وحده يسترجع النص إلى draft.
- Widgets تعرض state ولا تطلق daemon requests من `initState` أو
  `didChangeDependencies` أو rebuild للحصول على provider metadata أو usage.
- الطلبات المشتركة تُدمج بمفتاح هوية واضح، وتستخدم stale-while-revalidate،
  وتُبطل عند revision/event معروف لا عند كل تنقل.
- لا يجوز أن يؤدي تحسين الموارد إلى تأخير timeline أو مسح cached content أو
  إظهار spinner عام لبيانات ثانوية.

---

## 5. معايير القبول

- [ ] حذف Pending Steer يزيلها بعد نتيجة authoritative لكل من `cancelled` و
      `already_cancelled`، ولا يعيدها حدث قديم أو hydration متأخرة.
- [ ] نتيجة `delivery_in_progress` أو `already_delivered` لا تدعي الحذف، وتُظهر
      الحالة الصحيحة دون progress دائم.
- [ ] `not_found` أو نتيجة غير معروفة تطلق مصالحة authoritative محدودة ولا
      تغير رسالة أخرى.
- [ ] حذف queue يقرأ عقد `outcome` الصحيح، وينهي progress، ويزيل الصف عند
      `deleted` أو `already_removed` دون تكرار أو حذف صف آخر.
- [ ] رفض حذف queue بعد بدء التنفيذ يعيد الأزرار إلى حالة قابلة للفهم ولا يدعي
      نجاح الحذف.
- [ ] كل Pending Steer تظهر مرة واحدة في منطقة ثابتة أسفل timeline، مرتبة حسب
      الهوية/وقت الاستلام authoritative، وتبقى هناك أثناء وصول أدوات جديدة.
- [ ] التنقل من الجلسة A إلى B ثم العودة إلى A يحافظ على pending lane الخاصة بـA
      ولا يسربها إلى B.
- [ ] إعادة اتصال العميل أو إعادة تشغيل الوكيل لا تفقد Pending Steer ولا
      تضاعفها، وتلتزم بأحدث revision.
- [ ] لا تظهر `Edit` أو `Retry` في حالتي `pending` و`delivering`؛ ويظهر إجراء
      الحذف فقط عندما تسمح الحالة به.
- [ ] بعد تسليم Steer فعليًا، تختفي من pending lane وتظهر مرة واحدة في timeline
      بعد الحدث الفعلي الذي سُلّمت عنده، وبالهوية نفسها live وhistory.
- [ ] فشل حفظ history بعد reservation لا يعرض الرسالة كـdelivered ولا يفقد
      إمكانية استرجاعها.
- [ ] إشارة تغيير المزود لها event identity وموضع دائم، وتظهر بالنص والموضع
      نفسيهما أثناء البث وبعد التنقل أو إعادة تشغيل العميل.
- [ ] سياسة ظهور انتقالات `autoFailover` و`user` و`recovery` موثقة ومختبرة، ولا
      تختفي إشارة مطلوبة بسبب مصدرها.
- [ ] تنفيذ Stop مع Pending A/B وQueue C/D وDraft E يعيد النصوص إلى draft المالك
      مرة واحدة بالترتيب `A\nB\nC\nD\nE`، ويخفي pending lane والـqueue لكل
      العملاء بعد التأكيد authoritative.
- [ ] انقطاع النقل بين Stop وack ثم إعادة الاتصال لا يعيد صفوفًا قديمة ولا
      يضاعف draft recovery.
- [ ] فتح محادثة من cache حديثة لا يطلق `model.snapshot` أو usage support/get أو
      workspace policy مرة أخرى دون انتهاء freshness أو تغير revision.
- [ ] عند cache miss، لا يحجب عرض المحادثة سوى history اللازمة؛ provider usage
      وmetadata الثانوية تستخدم cached presentation وتحديثًا خلفيًا واحدًا.
- [ ] وجود أكثر من مستهلك لنفس provider metadata/usage ينتج طلبًا in-flight
      واحدًا لكل device/provider/operation.
- [ ] فتح A ثم B ثم A بالـworkspace والمزود نفسيهما يحقق ميزانية الطلبات
      المثبتة في Gate F ولا يسبب flicker أو فقد provider label أو usage قديمة
      بلا وسم.
- [ ] اختبارات unit/widget/protocol والاختبار daemon-backed الإلزامي تمر، مع
      تحديث design وproduct وQA docs والعقود الأقرب عند تغير invariants.

---

## 6. بوابات التنفيذ

### البوابة A — تثبيت العقود وإعادة الإنتاج

- [ ] توثيق payload الفعلية لكل من pending lifecycle/cancel result وqueue
      mutation وStop recovery وroute transition وhistory hydration.
- [ ] بناء جدول نتائج typed يحدد لكل outcome: الإزالة، إبقاء الصف، إنهاء
      progress، طلب hydration، ورسالة الخطأ المسموح بها.
- [ ] إعادة إنتاج عيوب حذف Pending Steer وحذف queue وStop في اختبارات تفشل قبل
      الإصلاح باستخدام payload الوكيل الحقيقية.
- [ ] إعادة إنتاج ترتيب `Pending -> Tool -> Tool -> Delivered` وإثبات اختلاف
      live عن history قبل الإصلاح.
- [ ] إعادة إنتاج route transition بعد tool/model step وإثبات موضع history
      الخاطئ أو الغائب.
- [ ] إضافة عدادات test gateway وتسجيل baseline لطلبات فتح المحادثة والتنقل
      `A -> B -> A`، مع فصل الطلبات blocking عن الخلفية.
- [ ] تثبيت سياسة ظهور مصادر route transition الثلاثة في وثيقة التصميم.

#### مخرج البوابة A

- [ ] كل عيب له اختبار أحمر أو دليل بروتوكول محدد، ولا يوجد إصلاح speculative.
- [ ] الهوية والمالك والـrevision والـanchor المطلوب لكل projection موثقة.
- [ ] baseline الطلبات مثبتة بأرقام قابلة للمقارنة في Gate F.

### البوابة B — توحيد mutation outcomes والحذف idempotent

- [ ] استبدال parsing النصي المتفرق بنماذج/Enums typed لنتائج pending وqueue.
- [ ] إصلاح عقد `outcome` الخاص بحذف queue عبر الوكيل والعميل والاختبارات.
- [ ] جعل `cancelled` و`already_cancelled` ينظفان stale pending projection بعد
      التأكيد authoritative مهما كان ترتيب lifecycle/result.
- [ ] معالجة `delivery_in_progress` و`already_delivered` و`stale_owner` و
      `not_found` دون حذف كاذب أو progress دائم.
- [ ] ربط pending operation state بالجلسة وraw request id، وتنظيفها عند
      navigation/hydration النهائي فقط وفق النتيجة الصحيحة.

#### مخرج البوابة B

- [ ] تكرار أو عكس ترتيب result/lifecycle يعطي الحالة النهائية نفسها.
- [ ] كل زر يعود من progress في كل terminal outcome.
- [ ] لا يمكن لنتيجة تخص جلسة أو request أخرى تغيير الصف النشط.

### البوابة C — Pending Steer lane مستقلة ومستمرة

- [ ] إضافة projection domain/store محددة بالـdevice والـsession لحالات
      `pending` و`delivering` بدل إدخالها مباشرة في `ConversationState`.
- [ ] توفير current snapshot وstream/selector مستقرين للـCubit دون store موازٍ.
- [ ] عرض lane أسفل timeline وفوق composer مع ترتيب ثابت وهوية raw request id.
- [ ] إبقاء الأدوات والأحداث الجديدة داخل timeline فوق lane المعلقة.
- [ ] دعم navigation وhistory hydration وreconnect وrevision ordering وStop
      recovery دون duplication أو تسرب بين الجلسات.
- [ ] تحديث `UserMessageTile`/العرض المخصص لإخفاء Edit وRetry في كل الحالات غير
      المنفذة، مع semantics إنجليزية واضحة للحالة والإلغاء.

#### مخرج البوابة C

- [ ] Pending Steer لا تغير موضعها عند وصول أي tool أو stream event.
- [ ] `A -> B -> A` يعيد lane الخاصة بـA فورًا من store/hydration.
- [ ] لا تحتوي timeline canonical على pending-only user events.

### البوابة D — تسليم Steer وموضع timeline canonical

- [ ] تصميم وإضافة anchor دائم للتسليم، مثل canonical sequence أو
      `after_event_id`، مع run/generation/request ownership اللازمة.
- [ ] حفظ anchor في transaction نفسها التي تثبت history delivery أو نشر الحدث
      فقط بعد نجاح الحفظ.
- [ ] نشر حدث delivered canonical يسمح للعميل بإزالة pending row وإدخال/دمج
      user event مرة واحدة في موضعها الحقيقي.
- [ ] جعل history hydration يعيد الهوية والanchor نفسيهما، وإزالة الاعتماد على
      timestamp للوصول إلى الموضع.
- [ ] تغطية delivery داخل tool result وdelivery كرسالة user مستقلة وفشل حفظ
      history وduplicate local/cloud events.

#### مخرج البوابة D

- [ ] التسلسل الحي والتاريخي متطابق عنصرًا بعنصر في السيناريوهات المغطاة.
- [ ] لا توجد لحظة يظهر فيها pending row ونسخة delivered ثانية معًا بعد
      المصالحة.
- [ ] anchor قديمة أو تخص generation أخرى لا تنقل رسالة حديثة.

### البوابة E — تطابق تغيير المزود وStop

- [ ] ربط route transition بموضع durable حقيقي داخل الجولة بدل آخر user
      `request_id` أو timestamps المصطنعة.
- [ ] حفظ ونشر event identity وrevision وdisplay names والسبب والanchor بطريقة
      متطابقة live/history.
- [ ] تطبيق سياسة مصادر route transition المعتمدة في Gate A.
- [ ] فصل queue/pending cleanup المشترك عن استرجاع draft الخاص بالعميل المالك.
- [ ] ضمان أن Stop أو snapshot/mutation اللاحقة تصفر projections القديمة حتى
      عند فقد حدث recovery الحي ثم reconnect.
- [ ] منع حدث متأخر من resurrection بعد Stop barrier أو route revision أحدث.

#### مخرج البوابة E

- [ ] إشارة المزود تظهر في الموضع نفسه قبل وبعد history reload.
- [ ] Stop ينتهي إلى queue فارغة وpending lane فارغة لكل العملاء.
- [ ] draft recovery يطبق مرة واحدة لدى المالك فقط ولا يعتمد عليه تنظيف
      projections المشتركة.

### البوابة F — ميزانية طلبات فتح المحادثة وحماية تجربة المستخدم

- [ ] نقل provider display/model metadata وusage fetch من Widget lifecycle إلى
      مالك مركزي واحد لكل نوع بيانات.
- [ ] إزالة الازدواج بين model chip وbottom actions وأي مستهلك آخر.
- [ ] إضافة request coalescing بمفتاح `device + resource identity + operation`.
- [ ] إضافة cache freshness وstale-while-revalidate وevent/revision invalidation
      لـworkspace policy وprovider metadata وusage.
- [ ] منع `provider.usage.support` من التكرار لمجرد تبدل المحادثة مع بقاء device
      وinstance list وrevision بلا تغيير.
- [ ] عدم طلب model catalog الكامل لمجرد عرض اسم مزود متاح أصلًا في route
      metadata؛ يبقى تحميل catalog الكامل عند فتح picker أو invalidation حقيقية.
- [ ] تثبيت ميزانية آلية للطلبات:
  - [ ] cache hit حديث: لا طلبات blocking، ولا طلب metadata/usage/policy مكرر.
  - [ ] cache miss: `get_session_history` واحد، و`workspace.get_policy` واحد فقط
        إذا لم توجد policy صالحة.
  - [ ] المورد stale: background request واحد مع إبقاء cached UI ظاهرة.
  - [ ] مستهلكان متزامنان: daemon request واحد لا اثنان.
- [ ] اختبار التنقل السريع والردود المتأخرة وتغير device/provider/workspace دون
      عرض بيانات من scope قديم.

#### مخرج البوابة F

- [ ] عدد الطلبات لا يتجاوز الميزانية في الاختبارات الآلية.
- [ ] فتح المحادثة وعرض timeline لا ينتظر usage أو model snapshot.
- [ ] لا flicker ولا اختفاء label ولا spinner عام بسبب تحديثات ثانوية.

### البوابة G — التحقق الشامل والتوثيق

- [ ] إضافة unit tests للstores/reducers وrevision/outcome/anchor ordering.
- [ ] إضافة protocol tests تستخدم envelopes الفعلية الصادرة من الوكيل.
- [ ] إضافة widget tests للـpending lane والأزرار والـprogress والتنقل.
- [ ] إضافة daemon-backed E2E مع `SANAD_STATE_HOME` مؤقت ومزود E2E حتمي يغطي:
  - [ ] pending cancel وqueue delete؛
  - [ ] long tool ثم pending delivery وموضعها؛
  - [ ] provider switch داخل الجولة؛
  - [ ] Stop مع A/B/C/D/E؛
  - [ ] disconnect/reconnect ثم history parity.
- [ ] تحديث `docs/technical/agent_interface_runtime.md` أو وثيقة design أقرب
      بعقد pending lane وdelivery anchor وroute ordering.
- [ ] تحديث `docs/product/client_interface.md` بسلوك الواجهة المرئي.
- [ ] تحديث `docs/qa_maintenance/task36_authoritative_steer_queue_stop_recovery_matrix.md`.
- [ ] تحديث `docs/qa_maintenance/conversation_event_parity_qa.md` بترتيب Steer
      وتغيير المزود live/history.
- [ ] إضافة/تحديث QA لميزانية طلبات فتح المحادثة وإدراجه في `docs/llms.txt` إذا
      أُنشئت صفحة جديدة.
- [ ] مراجعة العقود المحلية الأقرب وتحديثها فقط إذا تغير invariant دائم.
- [ ] تشغيل analyzers والاختبارات المركزة ثم full fast suites وفق blast radius.
- [ ] تشغيل `graphify update .` بعد تغييرات الكود ومراجعة diff النهائية.

#### مخرج البوابة G / تعريف الإنجاز

- [ ] جميع معايير القبول مؤشرة ولها دليل اختبار أو توثيق واضح.
- [ ] البث الحي وhistory وreconnect تنتهي إلى projection واحدة متطابقة.
- [ ] لا pending/queue/progress عالق ولا duplicate user أو route event.
- [ ] ميزانية الطلبات مثبتة آليًا دون تراجع ملحوظ في تجربة المستخدم.
- [ ] نتائج التحليل والاختبارات مسجلة بمخرجات bounded وحالة خروج صحيحة.

### البوابة H — التسليم للمراجعة

- [ ] مراجعة status/diff وعدم وجود ملفات مؤقتة أو تغييرات خارج النطاق.
- [ ] تحديث `status` و`current_gate` و`remaining_estimate_percent` في هذا الملف.
- [ ] عرض نتائج التحقق والمخاطر المتبقية على المستخدم.
- [ ] عدم تنفيذ commit أو push إلا بعد إذن المستخدم الصريح.
- [ ] بعد الإذن فقط: commit مركزة، push، وPull Request توضح المشكلة والعقود
      والتغييرات ونتائج التحقق.

#### مخرج البوابة H

- [ ] التغيير جاهز للمراجعة ولا يعتمد على حالة runtime المستخدم.
- [ ] لم يُنفذ `sanad-dev switch` أو `sanad-dev stop` دون موافقة منفصلة صريحة.

---

## 7. خارج النطاق

- إعادة تصميم شكل كل رسائل المحادثة أو tool groups خارج ما يلزم للـpending lane.
- تغيير سياسة اختيار المزود أو خوارزمية failover نفسها؛ النطاق هو حفظ وعرض
  الانتقال وترتيبه.
- polling دوري جديد للـusage أو provider metadata.
- جعل العميل مصدر الحقيقة لحالة التنفيذ أو queue أو delivery.
- استخدام runtime المستخدم أو قاعدة بياناته في E2E.

---

## 8. الملفات والمناطق المتوقعة

النطاق النهائي يثبت في Gate A، لكنه يتوقع مراجعة وتعديل ملاك الحدود التالية:

- `agent/lib/interfaces/runtime/session_run_orchestrator.dart`
- `agent/lib/interfaces/platforms/sanad_gateway/handlers/session_query_handler.dart`
- `agent/lib/evolution/db/runtime/pending_input_repository.dart`
- `agent/lib/evolution/db/runtime/session_route_transition_repository.dart`
- `agent/lib/engine/runtime/steer_coordinator.dart`
- `client/lib/features/conversations/data/transport/conversation_event_handler.dart`
- `client/lib/features/conversations/data/transport/conversation_commands.dart`
- `client/lib/features/conversations/domain/stores/device_conversation_store.dart`
- `client/lib/features/conversations/domain/stores/conversation_state.dart`
- `client/lib/features/conversations/presentation/bloc/session_messages_cubit.dart`
- widgets الخاصة بالـtimeline والـcomposer والرسالة المعلقة والطابور.
- `ProviderUsageCubit` ومالك provider runtime/workspace policy الأقرب.
- اختبارات Agent وClient وdaemon-backed والوثائق المالكة.

لا تُستخدم هذه القائمة لتجاوز `file_budget`: يجب استخراج helpers/owners مشتركة
وإزالة التكرار بدل إصلاح العرض نفسه في أكثر من Widget.

---

## 9. سيناريو النجاح النهائي

1. تبدأ جلسة وتنفذ Tool A.
2. يرسل المستخدم Steer S أثناء Tool A؛ تظهر S في pending lane أسفل المحادثة.
3. تنفذ Tool B وتبقى S أسفلها دون أن تبدو كرسالة منفذة.
4. ينتقل المستخدم إلى جلسة أخرى ثم يعود؛ تظهر S فورًا مرة واحدة في المكان
   المعلق نفسه.
5. عند safe delivery تحفظ S وتختفي من lane وتظهر بعد الحدث الذي استهلكها، دون
   duplicate، ويطابق ترتيب history هذا العرض.
6. تُرسل Queue Q ثم تُحذف؛ ينتهي progress وتختفي بعد النتيجة authoritative.
7. يحدث failover بعد Tool C؛ تظهر إشارة تغيير المزود بعد Tool C live وبعد
   إعادة فتح history.
8. تُضاف Pending A/B وQueue C/D وDraft E ثم يُضغط Stop؛ تختفي pending/queue،
   ويصبح draft `A\nB\nC\nD\nE` مرة واحدة فقط.
9. التنقل `A -> B -> A` مع cache حديثة لا يعيد model snapshot أو usage support
   أو workspace policy بلا invalidation، وتبقى timeline والlabels ظاهرة فورًا.

---

## 10. سجل التقدم

```text
التاريخ:
البوابة/الحالة:
نسبة المتبقي:
الملفات المعدلة:
التحقق:
النتائج أو المخاطر:
البوابة التالية:
```
