# المهمة 84 — Pagination لسجل رسائل المحادثة الطويلة

## الحالة

- **الحالة:** تنفيذ أولي متحقق لمسار tail/older من SQLite إلى Client والواجهة؛ البوابات المتقدمة ما زالت جزئية.
- **الفرع:** `docs/task-84-conversation-history-pagination`.
- **البوابة الحالية:** G7 — التحقق البصري ومراجعة التسليم.
- **نسبة العمل المتبقي:** 5%.
- **التأصيل المرجعي:** Evidence ID `84`، fingerprint
  `sha256:9aa23d0f3a0007890d9ef01643ee633ea618f5ca48704ad54492340d51df9e28`.
- **حدود التسليم:** لا commit أو push أو PR أو دمج دون موافقة صريحة من المالك.

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
- فتح جلسة idle ذات viewport anchor محفوظ يطلب صفحة تحتوي الحدث المستقر أو
  حوله، ثم يستعيد الموضع. إذا حُذف/دُمج anchor أو صار cursor غير صالح، يعود
  بأمان إلى أحدث tail دون crash أو شاشة فارغة.
- لا يلزم في الإصدار الأول حفظ كل الصفحات المحملة عبر restart؛ يبقى anchor
  المستقر هو عقد الاستعادة، ما لم يثبت القياس ضرورة cache محدود للصفحات.

### 6. تجربة التحميل والـscroll

- عند قرب المستخدم من أعلى timeline وبوجود نية صعود حقيقية، يبدأ prefetch قبل
  الوصول للحافة، مع coalescing لطلب واحد لكل cursor.
- يحتفظ prepend بأول حدث مرئي ثابت وإزاحته pixel بعد layout، فلا تقفز القراءة
  إلى أعلى أو أسفل.
- يتوفر زر English باسم **Show earlier** كمسار يدوي ولوحة مفاتيح وإعادة محاولة؛
  الضغط اليدوي يجوز أن يكشف بداية الصفحة الجديدة عمدًا.
- فشل التحميل يبقي السجل الحالي والموضع و`has_more` قابلين لإعادة المحاولة، لكنه
  يعطل auto-retry حتى نية صعود جديدة أو ضغط يدوي.
- إذا لم تملأ الصفحة الأولى viewport، يجوز auto-fill محدود لعدد صفحات/طلبات
  ثابت مركزيًا، ثم يظهر المسار اليدوي إن بقي سجل أقدم.
- `ListView`/sliver الكسول هو نقطة البداية. لا يضاف render-budget منفصل إلا إذا
  أثبت profiling أن widget construction ما زال غير محدود عمليًا.

## داخل النطاق

- استعلام SQLite محدود ومفهرس لأحدث/أقدم رسائل الجلسة؛
- typed cursor وعقد request/response مشترك للنقل المحلي والسحابي؛
- stable history event identity وتقسيم الصفحة قبل projection؛
- pagination state وprepend reconciliation داخل Client data/domain؛
- load-on-upward-intent، زر Show earlier، retry، viewport anchoring؛
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
- [x] إضافة زر **Show earlier** وحالات loading/error/retry بنصوص English فقط.
- [x] حفظ centered event anchor وإزاحته عبر prepend واستعادته بعد layout دون
  مزاحمة tail-follow owner.
- [x] auto-fill محدود بثلاث صفحات عندما لا تملأ الصفحة الأولى viewport.
- [x] ربط session switch والresize والcompact window وإغلاق inline edit بقواعد
  geometry غير stale.
- [x] widget tests للـscroll intent والزر والفشل وno-more والـpointer/keyboard
  accessibility؛ وتبقى modality اليدوية ضمن G7.
- [x] قياس lazy mounting على fixture من 1,000 event وعدم إضافة render budget
  لأن centered slivers لا تبني الصفوف البعيدة.

**دليل إغلاق G4 — مغلقة:** `brain_activity_view_scroll_test.dart` يثبت pixel
ثابتًا للحدث المرئي بعد prepend، عدم بناء بداية fixture من 1,000 event، زر
**Show earlier**، وauto-fill واحدًا دون loop. إصلاح تصنيف prepend يمنع الصفحات
الأقدم من أن تعامل كرسالة user/live جديدة أو تعيد tail-follow.

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

- [ ] تحديث `docs/technical/communication_protocols.md` بعقد cursor/page/error.
- [ ] تحديث `docs/technical/client_conversation_cache_schema.md` بملكية صفحات
  timeline منفصلة عن sidebar pagination.
- [ ] تحديث `docs/product/conversation_navigation_ux_spec.md` بسلوك Show earlier
  واستعادة الموضع.
- [ ] تحديث `docs/qa_maintenance/conversation_cache_recovery_qa.md` بمصفوفة long
  history والـraces والviewport.
- [ ] تحديث أقرب `AGENTS.md` فقط إذا أضاف التنفيذ قانونًا دائمًا جديدًا.
- [ ] تشغيل Client مرئي وفحص محادثة طويلة يدويًا: فتح، صعود، prefetch، retry،
  session switch، live append، restart، compact window؛ مع لقطات sanitized.
- [ ] مراجعة diff والأداء والوثائق ثم طلب موافقة مستقلة قبل commit/push/PR.

## معايير القبول

- [ ] Given جلسة تحتوي 10,000 رسالة persistence، when تُفتح، then لا يقرأ Agent
  أو يرسل إلا الصفحة الأولى والـruntime tail metadata ضمن الحدود المركزية.
- [ ] Given صفحة أولى، when يصعد المستخدم قرب الأعلى، then يبدأ طلب واحد للأقدم
  قبل الحافة وتبقى نفس الرسالة في نفس الموضع المرئي بعد prepend.
- [ ] Given طلب أقدم جارٍ، when تصل أحداث live جديدة، then تظهر مرة واحدة في
  الذيل ولا تُحذف أو تتكرر عند اكتمال الصفحة.
- [ ] Given تغير الجهاز أو الجلسة أو history revision أثناء الطلب، when تصل
  الاستجابة القديمة، then تُرفض دون تغيير العرض الحالي.
- [ ] Given message واحدة تنتج reasoning وthought وعدة tool rows وfinal answer،
  when تقع عند حد الصفحة، then تبقى مجموعتها كاملة ويعيد تجميع الصفحات نفس
  التاريخ والترتيب دون duplicate.
- [ ] Given compaction lifecycle أو route transition عند حد صفحتين، when تُحمل
  الصفحتان، then يظهر الحدث مرة واحدة في موضعه causal وبنفس event id.
- [ ] Given cursor تالف أو تابع لجلسة أخرى أو revision قديم، when يُرسل، then
  يعيد Agent خطأ typed/fallback آمنًا ولا يكشف وجود جلسة أخرى.
- [ ] Given فشل network أثناء load older، when ينتهي الطلب، then تبقى الصفحة
  الحالية والموضع ويظهر retry، ولا تتكرر الطلبات تلقائيًا بلا نية جديدة.
- [ ] Given tail أقصر من viewport مع تاريخ أقدم، when تفتح الجلسة، then يجري
  auto-fill محدود فقط ثم يتوقف عند الامتلاء أو exhaustion أو الحد المركزي.
- [ ] Given viewport anchor محفوظ في صفحة قديمة، when يعاد تشغيل Client، then
  يطلب anchored page ويعيد الموضع دون تحميل التاريخ كاملًا؛ anchor المفقود يعود
  إلى latest tail.
- [ ] Local وcloud envelopes ينتجان نفس page semantics والهوية والترتيب والأخطاء.
- [ ] لا نص عربي جديد في Client، ولا secrets أو payload content في logs.

## سيناريو النجاح النهائي

1. إنشاء fixture daemon مع جلسة طويلة تحتوي رسائل عادية وreasoning وأدوات
   وroute transition وcompaction lifecycle وحدود صفحات متعمدة.
2. تشغيل Client مرئي وفتح الجلسة؛ قياس الصفحة الأولى والـSQL/response bounds.
3. الصعود تدريجيًا حتى prefetch، والتأكد من ثبات الرسالة المرئية وعدم التكرار.
4. إبقاء older request معلقًا ثم إرسال حدث live وتبديل جلسة والعودة؛ التأكد من
   عزل النتيجة القديمة ومصالحة الحدث live.
5. حقن فشل ثم retry يدوي، وحقن cursor stale/no-progress، وإثبات عدم وجود loop.
6. حفظ anchor في صفحة قديمة ثم restart، وإثبات anchored restore والفallback بعد
   حذف/compaction للـanchor.
7. تكرار الفحص في نافذة compact وكبيرة، مع keyboard وtrackpad/mouse، ثم جمع
   لقطات sanitized ونتائج الاختبارات والقياسات.

## تعريف الإنجاز

- [ ] R0 وG1–G7 مغلقة بأدلة مرتبطة بكل بوابة وتحديث نسبة المتبقي عند الإغلاق.
- [ ] SQL والنقل والإسقاط وذاكرة Client والـfirst paint محدودة وقابلة للقياس.
- [ ] الهوية والترتيب وlive/history parity وviewport recovery مثبتة آليًا وحيًا.
- [ ] Agent/Client analyzers والاختبارات المركزة والكاملة وE2E المطلوبة تمر.
- [ ] وثائق التقنية والمنتج وQA والعقود القريبة متسقة، وGraphify محدث.
- [ ] لا commit أو push أو PR أو merge قبل موافقة المالك الصريحة.
