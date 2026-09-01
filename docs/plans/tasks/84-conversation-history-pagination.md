# المهمة 84 — Pagination لسجل رسائل المحادثة الطويلة

## الحالة

- **الحالة:** اكتمل pagination وإصلاح تكافؤ أهلية Edit/Retry بين live history والـhydration والتحقق منهما.
- **الفرع:** `docs/task-84-conversation-history-pagination`.
- **البوابة الحالية:** G8 — مغلقة.
- **نسبة العمل المتبقي:** 0%.
- **التأصيل المرجعي:** Evidence ID `84`، fingerprint
  `sha256:9aa23d0f3a0007890d9ef01643ee633ea618f5ca48704ad54492340d51df9e28`.
- **حدود التسليم:** مصرح بالـ Commit والـ Push والـ PR والدمج بأمر المالك.

## الهدف

عرض المحادثات الطويلة بسرعة وبذاكرة ونقل محدودين عبر تحميل أحدث جزء من السجل
أولًا ثم جلب الصفحات الأقدم عند صعود المستخدم، مع الحفاظ على ترتيب الأحداث
ومجموعات الأدوات وموضع القراءة والأحداث الحية، ومنع أي نتيجة قديمة من تلويث
جلسة أو جهاز آخر.

## المشكلة الحالية

مسار `get_session_history` يقرأ كل رسائل الجلسة من SQLite، يحول السجل كاملًا إلى
أحداث canonical، ويرسله في استجابة واحدة، ثم يستبدل Client الـtimeline كاملًا.
هذا يجعل زمن الاستعلام وحجم النقل وعمل الـmapper وذاكرة Client ينمون مع عمر
المحادثة. كما أن الرسالة المحفوظة الواحدة قد تنتج عدة صفوف مرئية: reasoning،
thought، tool uses/results، وfinal answer، مع route transitions وcompaction
lifecycle مضافة بين الصفوف؛ لذلك لا يصح تقسيم الصفحة بعدد عشوائي من العناصر
المرئية.

## القرارات المثبتة

### 1. ملكية البيانات

- يظل Agent المصدر السلطوي لسجل المحادثة وترتيبه وحالة التنفيذ الحالية.
- يملك `SessionDB`/مالك جدول الرسائل استعلام الصفحات؛ لا ينفذ handler استعلام SQL
  موازيًا ولا يحمل السجل كاملًا ثم يقصه في الذاكرة.
- يملك Client domain/data حالة pagination والدمج. تطلب presentation نية
  **load older** فقط، ولا تحلل envelopes أو تدير cursor مباشرة.
- تُعزل الحالة بالمفتاح `deviceId + sessionId`، ولا تُقبل نتيجة بعد تغيير الجهاز
  أو الجلسة أو generation أو cursor المتوقع.

### 2. نموذج الصفحة والمؤشر

- الاستجابة الأولى هي أحدث tail محدود، مرتبة زمنيًا من الأقدم إلى الأحدث داخل
  الصفحة، وتحتوي `has_more` و`next_cursor` فقط عند وجود سجل أقدم.
- `next_cursor` قيمة opaque يملكها Agent، لا timestamp ولا offset مكشوفًا يعتمد
  عليه Client. يربط cursor على الأقل بالجلسة وموضع صف SQLite المستقر وrevision
  للسجل، ويُرفض إذا نُقل إلى جلسة أخرى أو أصبح غير صالح بعد rewrite/compaction.
- الاستعلام الأقدم يستخدم keyset pagination على `messages.id` والفهرس الحالي،
  ويعيد عددًا محدودًا دون قراءة بقية الجلسة.
- الحد الأساسي هو عدد رسائل persistence لا عدد `CanonicalEvent`s؛ كل الصفوف
  المرئية الناتجة من رسالة محفوظة مقبولة تُعاد معًا.
- يطبق Agent حدًا إضافيًا لحجم الاستجابة. إذا كانت مجموعة رسالة واحدة كبيرة،
  تبقى المجموعة متماسكة مع نتيجة typed/سياسة bounded موثقة، ولا تُفقد الرسالة
  أو يصبح cursor عالقًا.
- cursor لا يتقدم أو صفحة فارغة مع `has_more=true` تُعامل كـexhausted في Client
  مع تسجيل diagnostic نظيف، لمنع loop.

### 3. الهوية والترتيب

- يجب أن يملك كل حدث history هوية canonical ثابتة عبر إعادة التحميل والصفحات، لا
  id مبنيًا على index داخل الاستجابة.
- ترتبط الأحداث الناتجة من رسالة persistence بهوية مصدر ثابتة
  `(sessionId, messageRowId, semanticKind, ordinal)` أو مكافئ opaque.
- tool use/result وreasoning/thought/final answer لا تُقسم بصورة تفقد الربط أو
  تغير ترتيبها بين live وhistory.
- route transitions وcompaction lifecycle تُسند إلى صفحة واحدة فقط بهوية
  deterministic وموضع causal ثابت؛ لا تتكرر على حد الصفحتين ولا تختفي.
- الدمج في Client prepend فريد بالـevent id ويحفظ ترتيب Agent. timestamps للعرض
  فقط وليست سلطة pagination أو deduplication.

### 4. Tail السلطوي مقابل الصفحات الأقدم

- الاستجابة الأولى أو anchored hydration فقط تحمل الحالة الحالية: execution
  snapshot، queue، pending steers، Stop recovery، permission request، runtime
  notice، in-flight output، route/context projection.
- صفحة أقدم لا تمس هذه الحالات ولا تستبدل timeline؛ تضيف أحداثًا تاريخية فقط.
- الأحداث الحية التي تصل أثناء طلب صفحة أقدم تبقى محفوظة وتُدمج بعد الصفحة وفق
  هويتها canonical.
- refresh/reconnect للـtail يظل generation-aware ويصالح الأحداث الحية كما هو؛
  pagination التاريخية لا تصبح مسار live delta موازيًا.

### 5. فتح الجلسة واستعادة موضع القراءة

- يبقى الانتقال بين الجلسات atomic: تظل الجلسة المعروضة صالحة حتى نجاح tail أو
  anchored page للجلسة المطلوبة، والفشل لا يعرض خليطًا من جلستين.
- فتح جلسة active يبدأ من أحدث tail ويتبع آخر الأحداث وفق قواعد timeline الحالية.
- فتح جلسة idle ذات viewport anchor محفوظ يطلب صفحة تبدأ بصف persistence المالك
  للحدث وتضم السياق الأحدث بعده، ثم يستعيد الموضع. حتى anchor لأول رسالة لا يجوز
  أن يختزل المحادثة إلى رسالة واحدة. إذا حُذف/دُمج anchor أو صار cursor غير
  صالح، يعود بأمان إلى أحدث tail دون crash أو شاشة فارغة.
- لا يلزم في الإصدار الأول حفظ كل الصفحات المحملة عبر restart؛ يبقى anchor
  المستقر هو عقد الاستعادة، ما لم يثبت القياس ضرورة cache محدود للصفحات.

### 6. تجربة التحميل والـscroll

- عند قرب المستخدم من أعلى timeline وبوجود نية صعود حقيقية، يبدأ prefetch قبل
  الوصول للحافة، مع coalescing لطلب واحد لكل cursor.
- يحتفظ prepend بأول حدث مرئي ثابت وإزاحته pixel بعد layout، فلا تقفز القراءة
  إلى أعلى أو أسفل.
- لا تُعرض أزرار Show earlier/later أو Retry داخل timeline. يبدأ prefetch قبل
  وصول المستخدم إلى أي حد، وتعرض حالة loading غير تفاعلية فقط عند الحاجة.
- فشل التحميل يبقي السجل الحالي والموضع وcursor قابلين لإعادة المحاولة. حركة
  جديدة نحو الحد أو overscroll تعيد الطلب دون control يدوي أو loop ذاتي.
- إذا لم تملأ الصفحة الأولى viewport، يجوز auto-fill محدود لعدد صفحات/طلبات
  ثابت مركزيًا، ثم يظهر المسار اليدوي إن بقي سجل أقدم.
- `ListView`/sliver الكسول هو نقطة البداية. لا يضاف render-budget منفصل إلا إذا
  أثبت profiling أن widget construction ما زال غير محدود عمليًا.

## داخل النطاق

- استعلام SQLite محدود ومفهرس لأحدث/أقدم رسائل الجلسة؛
- typed cursor وعقد request/response مشترك للنقل المحلي والسحابي؛
- stable history event identity وتقسيم الصفحة قبل projection؛
- pagination state وprepend reconciliation داخل Client data/domain؛
- prefetch تلقائي ثنائي الاتجاه، overscroll retry، وviewport anchoring دون أزرار pagination؛
- anchored restore لموضع المحادثة idle؛
- اختبارات Agent وClient وdaemon-backed parity والتحقق البصري على محادثة طويلة؛
- تحديث وثائق البروتوكول والمعمارية والمنتج وQA والعقود القريبة عند تغير قانون
  دائم.

## خارج النطاق

- pagination لقائمة المحادثات في sidebar؛ فهي مملوكة بالفعل لعقد cache منفصل؛
- تغيير compaction policy أو حذف الرسائل القديمة؛
- search داخل كامل transcript؛ يمكنه استخدام anchor API لاحقًا دون توسيع هذه
  المهمة؛
- virtualization framework جديد أو render-cost engine دون قياس يثبت الحاجة؛
- حفظ سجل المحادثة كاملًا داخل Client persistence؛
- تغيير queue/steer/Stop أو provider execution semantics؛
- commit أو push أو PR أو merge تلقائي.

## البوابات

### R0 — التأصيل المرجعي والتدقيق الحالي

- [x] تثبيت نسختين مرجعيتين موثوقتين ومراجعة التراخيص والعقود القريبة.
- [x] فحص implementation والاختبارات لسجل tail، الصفحات الأقدم، stale results،
  viewport anchoring، progressive rendering، والجلسات الطويلة.
- [x] إنتاج Adopt/Adapt/Reject والتزامات محايدة عن المصدر في evidence packet.
- [x] تدقيق Sanad من SQLite إلى protocol وClient store وtimeline وتحديد فجوة
  full-history الحالية.
- [x] إثبات أن clipping داخل UI وحده غير كافٍ لأنه لا يحد SQL أو النقل أو mapper.

### G1 — عقد الصفحة والهوية والمؤشر

- [x] إضافة models typed لطلب tail/older/anchor واستجابة الصفحة وحالات cursor
  غير الصالح، مع توافق local/cloud.
- [x] تثبيت default page size عند 100 والحد الأعلى 200 وميزانية persisted page
  عند 1 MiB بعد fixture من 10,000 صف وtool fan-out ورسالة أكبر من الميزانية.
- [x] تصميم opaque cursor يربط session id وrow boundary وhistory revision دون
  كشف بيانات حساسة أو قبول cross-session replay.
- [x] تعريف stable canonical event id لكل نوع history fan-out ولكل route/
  compaction lifecycle event.
- [x] توثيق tail-only runtime projections وسلوك anchored fallback.
- [x] إضافة protocol/model tests للمدخلات الناقصة، cursor التالف، wrong session،
  stale boundary، limit bounds، والتوافق الخلفي المقصود.

**دليل إغلاق G1 — مغلقة:** `session_history_pagination_test.dart` يثبت typed
request/cursor والـcross-session/stale-boundary/limit/anchor/byte cases، واختبار
`sanad_bridge_test.dart` يثبت fan-out identity وتكافؤ envelope المشترك. Fixture
10,000 صف أعاد 100 صف ضمن 1 MiB؛ زمن أمر الاختبار الكامل المقاس 1.33 ثانية.

### G2 — استعلام SQLite محدود وإسقاط الصفحة في Agent

- [x] إضافة repository query لأحدث صفحة وصفحة أقدم باستخدام index وkeyset، دون
  `getPersistedMessages()` الكامل (يبقى anchor query لبوابة G5).
- [x] إرجاع الرسائل بترتيب chronological صحيح مع `has_more` وcursor متقدم.
- [x] إسقاط كل persistence message إلى مجموعة canonical كاملة ثابتة الهوية.
- [x] توزيع route transitions وcompaction lifecycle على الصفحات causal مرة واحدة.
- [x] إبقاء execution/queue/recovery/permission/notice/in-flight/context ضمن tail
  أو anchored hydration فقط.
- [x] منع page byte cap من تخطي record أو إبقاء cursor غير متقدم.
- [x] اختبارات repository/handler لحدود الصفحة، concurrent append، suffix rewrite،
  compaction، event fan-out، tool pairing، والرسالة الكبيرة.

**دليل إغلاق G2 — مغلقة:** repository tests تثبت keyset والappend/rewrite والـbyte
cap و10,000 صف، وbridge fan-out test يضم الصفحات دون duplicate ويحفظ tool group،
و`compaction_history_parity_test.dart` يثبت ظهور lifecycle مرة واحدة في الصفحة
الأقدم مع بقاء runtime snapshot في tail فقط. Route transitions تستخدم request-id
causal anchoring والـevent id الدائم نفسه عبر handler المشترك.

### G3 — Client data/domain pagination owner

- [x] توسيع `ConversationClient`/repository بعقد initial/older typed دون نقل
  cursor إلى presentation (يبقى anchor ضمن G5).
- [x] إضافة state للـcursor وhasMore في owner المربوط بالجهاز، وloading/error/
  generation في session presentation owner.
- [x] prepend فريد بالهوية مع ترتيب ثابت والحفاظ على live/pending projections.
- [x] coalesce للطلبات المتطابقة ورفض out-of-order/session-switch/device-switch/
  cursor-mismatch responses.
- [x] اعتبار no-progress exhausted ومنع loops.
- [x] ضمان أن older-page failure لا يمس الرسائل المعروضة أو tail runtime state.
- [x] اختبارات store/repository/cubit لكل race وmerge وفشل وإعادة محاولة.

**دليل إغلاق G3 — مغلقة:** `device_conversation_commands_test.dart` يثبت coalesce،
unique prepend، no-progress exhaustion، live reconciliation، ورفض الأجيال القديمة؛
`session_cubit_test.dart` يثبت guard الطلب الجاري وبقاء الرسائل وretry state عند
الفشل، وملكية client-per-device تعزل cursor والصفحات بين الأجهزة.

### G4 — Timeline UX وviewport anchoring

- [x] إضافة top prefetch يعمل فقط مع upward user intent وعلى مسافة قبل الحافة.
- [x] إزالة controls اليدوية واعتماد prefetch تلقائي ثنائي الاتجاه مع retry محدود.
- [x] حفظ centered event anchor وإزاحته عبر prepend واستعادته بعد layout دون
  مزاحمة tail-follow owner.
- [x] auto-fill محدود بثلاث صفحات عندما لا تملأ الصفحة الأولى viewport.
- [x] ربط session switch والresize والcompact window وإغلاق inline edit بقواعد
  geometry غير stale.
- [x] widget tests للـscroll intent والauto-fill والفشل المحدود وno-more دون
  ظهور pagination controls؛ وتبقى modality اليدوية ضمن G7.
- [x] قياس lazy mounting على fixture من 1,000 event وعدم إضافة render budget
  لأن centered slivers لا تبني الصفوف البعيدة.

**دليل إغلاق G4 — مغلقة:** `brain_activity_view_scroll_test.dart` يثبت pixel
ثابتًا للحدث المرئي بعد prepend، عدم بناء بداية fixture من 1,000 event، وauto-fill
ثنائيًا دون controls أو loop. إصلاح تصنيف prepend يمنع الصفحات الأقدم من أن
تعامل كرسالة user/live جديدة أو تعيد tail-follow.

### G5 — Anchored restore والتعافي

- [x] ربط viewport anchor المحفوظ بطلب anchor typed عند فتح جلسة idle.
- [x] استعادة الحدث داخل الصفحة الصحيحة ثم تطبيق pixel alignment الحالي.
- [x] fallback واضح إلى tail عند anchor مفقود أو compacted أو cursor stale.
- [x] منع anchored result من الفوز بعد انتقال المستخدم إلى جلسة/جهاز آخر.
- [x] اختبار restart/reconnect/cache hydration عبر suites الحالية، واختبار
  compaction/missing anchor عبر pagination والـwidget fixtures.

**دليل إغلاق G5 — مغلقة:** anchor event id ينتقل عبر Home → Cubit → repository
→ shared gateway request، وAgent يحوله إلى row-bound typed query. Widget test
يثبت إعادة فتح الحدث عند أعلى المحتوى بعد وصول الصفحة؛ missing/cross-session
anchor يبقي tail الحالي، وأجيال command/cubit تمنع الاستجابة بعد session/device
switch. اختبارات cache/restart القائمة ما زالت تمر.

### G6 — التحقق المتكامل والأداء

- [x] Agent analyzer واختبارات repository/handler/protocol المركزة تمر.
- [x] Client analyzer واختبارات data/domain/widget المركزة تمر.
- [x] full fast suites تمر لأن التغيير يعبر DB/protocol/store/presentation.
- [x] daemon-backed E2E بـ`--concurrency=1` يثبت local socket pagination؛ shared
  handler/bridge tests تثبت cloud-envelope parity دون بنية حية.
- [x] benchmark موثق يثبت bounded initial rows/bytes/map time لأول 100 و1,000
  و10,000 persistence messages وسجل tool-heavy.
- [x] `git diff --check` و`graphify update .` يمران.

**دليل إغلاق G6 — مغلقة:** Agent analyzer وfull suite (`1400 passed`, `13
skipped`) وClient analyzer وfull suite (`1176 passed`, `1 skipped`) نجحت. spawned-daemon
E2E مرر tail من 100 حدث ثم older page عبر Local Gateway الحقيقي. Fixture DB
يغطي 100/1,000/10,000 صف، والـbridge يغطي tool fan-out. `git diff --check`
وGraphify نجحا.

### G7 — التوثيق والتحقق البصري والتسليم

- [x] تحديث `docs/technical/communication_protocols.md` بعقد cursor/page/error.
- [x] تحديث `docs/technical/client_conversation_cache_schema.md` بملكية صفحات
  timeline منفصلة عن sidebar pagination.
- [x] تحديث `docs/product/conversation_navigation_ux_spec.md` بسلوك prefetch
  التلقائي واستعادة الموضع دون controls.
- [x] تحديث `docs/qa_maintenance/conversation_cache_recovery_qa.md` بمصفوفة long
  history والـraces والviewport.
- [x] تحديث أقرب `AGENTS.md` فقط إذا أضاف التنفيذ قانونًا دائمًا جديدًا.
- [x] إصلاح regression المكتشف تفاعليًا: anchor لأول رسالة يعيد الصفحة بدءًا منها
  مع سياق أحدث بدل timeline من رسالة واحدة، مع اختبار repository مركز.
- [x] إصلاح regression التنقل بعد تحميل أول رسالة: الاحتفاظ بحد أقصى لجلستين
  مكتملتين في الذاكرة ومصالحة tail السلطوي بالهوية بدل إسقاط الصفحات المحملة؛
  اللوج أثبت سابقًا سباق tail/anchor/older عند العودة والاختبار المركز يثبت عدمه.
- [x] إضافة pagination أحدث من الـanchor عبر cursor مستقل و`has_newer`، مع append
  فريد وprefetch تلقائي عند النزول؛ وهذا يجلب terminal tool rows الموجودة في
  الصفحات التالية بدل إبقاء الأداة `in progress` بلا نهاية.
- [x] إصلاح قفزة viewport إلى tail عند وصول صفحة older أثناء السحب، مع اختبار widget
  يعيد إنتاج التحميل عند حد الصفحة ويحفظ الحدث المرئي وإزاحته.
- [x] جعل Scrollable المحادثة قابلًا للاستهداف بثبات من `sanad-dev ui`، وإضافة
  تحقق يقارن ترتيب مفاتيح history المرئية مع تسلسل صفوف قاعدة البيانات.
- [x] تشغيل Client مرئي وفحص محادثتين طويلتين: الصعود والنزول عبر عدة صفحات،
  session switch ذهابًا وإيابًا، واستعادة الحدث نفسه لكل جلسة، مع فحص terminal
  tool rows ولقطات sanitized.
- [x] دمج tool run المرئي عبر reasoning تاريخي مخفي وحدود Show later، مع إبقاء
  الفواصل المرئية و`system_ask_user` حدودًا صريحة واختبار regression مطابق.
- [x] إزالة Show earlier/later وRetry controls من العرض، مع auto-fill ثنائي
  الاتجاه وprefetch/overscroll retry قبل الحواف واختبار حي لا يرى control.
- [ ] مراجعة diff والأداء والوثائق ثم طلب موافقة مستقلة قبل commit/push/PR.

**دليل G7 الحالي:** أعاد widget test الجديد القفزة قسرًا قبل الإصلاح ثم أثبت ثبات
نفس event/pixel بعد prepend، واختبار ثانٍ يثبت anchor مستقلًا عند التنقل بين
جلستين. في Client المرئي استُخدمت جلسة خاملة من 632 صفًا: طابق أول مفتاح UI
`history:...:29503510:user_message:0` قيمة `min(messages.id)=29503510`، وطابق
الحدث الأخير `answer_model_step_41d20694-c0f6-47f6-ad03-273452c2e77c` صف قاعدة
البيانات `29505164=max(messages.id)`. عند وصول صفحة older بقي
`answer_model_step_c1e8c39c-7681-4cf4-91eb-fbbef54a4bfc` ظاهرًا وتحرك 300px فقط
بقدر gesture المقصودة بينما اتسع المجال للأقدم. العودة للجلسة الخاملة أعادت
`answer_model_step_887327be-e436-4d95-89d1-ae470a002c1f` قرب أعلى viewport؛ فتح
الجلسة النشطة تجاهل anchor وكان `offset == maxScrollExtent`. لا يوجد
`tool_running_progress_indicator` في الجلسة الخاملة عند tail. في إعادة إنتاج
Show later نفسها ظهرت قبل الإصلاح ثلاثة `EventTile` منفردة بين مجموعات الأدوات؛
بعد الإصلاح أعاد الإسقاط مجموعة `tool_call_ubJL...` واحدة، وأثبت توسيعها وجود
30 child tool events متتابعة. بعد إزالة controls أُعيد فتح الجلسة من أول رسالة
دون tap؛ لم توجد مفاتيح `conversation_show_earlier/later`، ومع ذلك ظهرت تلقائيًا
مقاييس الصفحة التالية (`6 terminal runs` و`8 files modified`) خلال ثلاث ثوانٍ.
اختبار offline يثبت ثلاثة إخفاقات متتالية كحد لكل اتجاه، توقف الطلب الرابع، ثم
إعادة فتح الميزانية بعد recovery سلطوي. التُقطت لقطتان محليتان غير متتبعتين
للجلسة الخاملة وtail الجلسة النشطة.

### G8 — تكافؤ أهلية Edit/Retry بين live والـhistory

- [x] يثبت Agent رسالة root user وهويتها durable قبل نشر `user_message` الحي، ثم يبدأ model stream من الرسالة نفسها دون duplicate.
- [x] يتطابق live event والـhydration لنفس الرسالة في `request_id` و`message_id` و`turn_id` و`input_kind` و`replay_eligible`.
- [x] يظهر Edit/Retry ويعملان فور durable commit حتى أثناء التنفيذ؛ يظل Agent مالك Stop والـidle boundary والـsoft rewind.
- [x] لا يعرض Client Edit/Retry من anchored/partial history ما دام `hasNewerHistory=true`.
- [x] تغطي الاختبارات الإرسال الحي دون navigation، والـhydration parity، والـpartial-tail guard، ومسار daemon-backed الحقيقي.

#### قبول G8

- [x] Given رسالة root جديدة، when تُرسل، then يظهر Edit/Retry من live event دون تغيير المحادثة أو طلب history إضافي.
- [x] Given anchored page لها سجل أحدث، then لا تظهر إجراءات replay لأي root محملة حتى الوصول إلى authoritative tail.
- [x] Given Retry أثناء تنفيذ الوكيل، then يرسل Client أمر replay واحدًا ويتولى Agent وحده Stop ثم rewind وإعادة التنفيذ.

## معايير القبول

- [x] Given جلسة تحتوي 10,000 رسالة persistence، when تُفتح، then لا يقرأ Agent
  أو يرسل إلا الصفحة الأولى والـruntime tail metadata ضمن الحدود المركزية.
- [x] Given صفحة أولى، when يصعد المستخدم قرب الأعلى، then يبدأ طلب واحد للأقدم
  قبل الحافة وتبقى نفس الرسالة في نفس الموضع المرئي بعد prepend.
- [x] Given طلب أقدم جارٍ، when تصل أحداث live جديدة، then تظهر مرة واحدة في
  الذيل ولا تُحذف أو تتكرر عند اكتمال الصفحة.
- [x] Given تغير الجهاز أو الجلسة أو history revision أثناء الطلب، when تصل
  الاستجابة القديمة، then تُرفض دون تغيير العرض الحالي.
- [x] Given message واحدة تنتج reasoning وthought وعدة tool rows وfinal answer،
  when تقع عند حد الصفحة، then تبقى مجموعتها كاملة ويعيد تجميع الصفحات نفس
  التاريخ والترتيب دون duplicate.
- [x] Given compaction lifecycle أو route transition عند حد صفحتين، when تُحمل
  الصفحتان، then يظهر الحدث مرة واحدة في موضعه causal وبنفس event id.
- [x] Given cursor تالف أو تابع لجلسة أخرى أو revision قديم، when يُرسل، then
  يعيد Agent خطأ typed/fallback آمنًا ولا يكشف وجود جلسة أخرى.
- [x] Given فشل network أثناء load older، when ينتهي الطلب، then تبقى الصفحة
  الحالية والموضع دون control؛ وتتوقف إعادة المحاولة بعد ثلاثة إخفاقات متتالية
  لكل اتجاه حتى نجاح أو إعادة فتح الجلسة.
- [x] Given tail أقصر من viewport مع تاريخ أقدم، when تفتح الجلسة، then يجري
  auto-fill محدود فقط ثم يتوقف عند الامتلاء أو exhaustion أو الحد المركزي.
- [x] Given viewport anchor محفوظ في صفحة قديمة، when يعاد تشغيل Client، then
  يطلب anchored page ويعيد الموضع دون تحميل التاريخ كاملًا؛ anchor المفقود يعود
  إلى latest tail.
- [x] Local وcloud envelopes ينتجان نفس page semantics والهوية والترتيب والأخطاء.
- [x] لا نص عربي جديد في Client، ولا secrets أو payload content في logs.

## سيناريو النجاح النهائي

1. إنشاء fixture daemon مع جلسة طويلة تحتوي رسائل عادية وreasoning وأدوات
   وroute transition وcompaction lifecycle وحدود صفحات متعمدة.
2. تشغيل Client مرئي وفتح الجلسة؛ قياس الصفحة الأولى والـSQL/response bounds.
3. الصعود تدريجيًا حتى prefetch، والتأكد من ثبات الرسالة المرئية وعدم التكرار.
4. إبقاء older request معلقًا ثم إرسال حدث live وتبديل جلسة والعودة؛ التأكد من
   عزل النتيجة القديمة ومصالحة الحدث live.
5. حقن فشل ثم edge-intent retry محدود، وحقن cursor stale/no-progress، وإثبات عدم وجود loop.
6. حفظ anchor في صفحة قديمة ثم restart، وإثبات anchored restore والفallback بعد
   حذف/compaction للـanchor.
7. تكرار الفحص في نافذة compact وكبيرة، مع keyboard وtrackpad/mouse، ثم جمع
   لقطات sanitized ونتائج الاختبارات والقياسات.

## تعريف الإنجاز

- [x] R0 وG1–G7 مغلقة بأدلة مرتبطة بكل بوابة وتحديث نسبة المتبقي عند الإغلاق.
- [x] SQL والنقل والإسقاط وذاكرة Client والـfirst paint محدودة وقابلة للقياس.
- [x] الهوية والترتيب وlive/history parity وviewport recovery مثبتة آليًا وحيًا.
- [x] Agent/Client analyzers والاختبارات المركزة والكاملة وE2E المطلوبة تمر.
- [x] وثائق التقنية والمنتج وQA والعقود القريبة متسقة، وGraphify محدث.
- [x] لا commit أو push أو PR أو merge قبل موافقة المالك الصريحة.
