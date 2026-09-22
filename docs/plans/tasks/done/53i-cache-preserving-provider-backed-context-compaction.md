---
title: "Task 53i: Provider-Backed Multilingual Context Compaction"
description: "إصلاح ضغط السياق باستبدال الملخص المحلي القالبي بطلب تلخيص عادي من مزود المحادثة، مع دعم العربية والضغط المتكرر الآمن دون سياسة كاش خاصة بالضغط."
status: "completed"
priority: "critical"
related_to: "Plan 53 durable context compaction"
reference_grounding: "required"
evidence_id: "53-compaction-policy-reference"
---

# المهمة 53i — ضغط سياق متعدد اللغات عبر المزود

## الحالة

- **الحالة:** `completed` — استبدل الملخص القالبي بطلب تلخيص حقيقي عبر المزود، واكتمل التحقق الآلي والحي الشامل.
- **الفرع:** `docs/53i-cache-preserving-provider-compaction`.
- **البوابة الحالية:** G6 — مغلقة بعد اكتمال التحقق والتوثيق.
- **نسبة العمل المتبقي:** 0%.
- **التأصيل المرجعي الحالي:** Evidence ID `53-compaction-policy-reference`، fingerprint
  `sha256:796645911a9efef339ff6d9441a5938f4d08f4264df830349f93f3ef3c6e9fdd`؛
  وُسع سجل R0 المركزي لمسار التلخيص الحالي عبر المزود مع Adopt/Adapt/Reject.
- **حدود التسليم:** صرح المستخدم بإنشاء الـ PR وتتبع التحقق والدمج.

## الهدف

استبدال `StructuredCompactionSummarizer` القالبي المستخدم حاليًا في الإنتاج
بطلب تلخيص حقيقي إلى مزود ونموذج المحادثة كرسالة user عادية ضمن projection
الخاصة بالtrigger، مع الأدوات والإعدادات العادية نفسها. تُحوّل النتيجة إلى
`CompactionInternalSummary` وتدخل pipeline الحفظ والتفعيل الحالية دون أن تصبح
رسالة canonical أو تظهر للمستخدم.

يجب أن يعمل السلوك نفسه مع العربية والإنجليزية والمحادثات المختلطة، وألا تُفعّل
أي boundary إذا فشل المزود أو كانت summary ناقصة أو غير قابلة للتحقق.

## المشكلة المثبتة

- `agent/lib/core/di.dart` يبني `ContextCompactionEngine()` دون summarizer إنتاجي.
- fallback الافتراضي هو `StructuredCompactionSummarizer` الموصوف بأنه للاختبارات
  والتحقق offline، لكنه مستخدم في runtime الإنتاجي.
- الـsummarizer الحالي يبحث عن labels إنجليزية محددة مثل `goal:` و`path:`
  و`blocker:` ثم يعيد قالبًا شبه ثابت؛ لذلك لا يفهم المحادثة العربية أو النص
  الطبيعي فهمًا دلاليًا.
- continuity anchors الحالية تعتمد أيضًا على labels إنجليزية داخل رسائل
  المستخدم، بينما `missingRequiredSections()` يفرض فعليًا `currentGoal`
  و`remainingWork` فقط؛ وبذلك يمكن أن ينجح ملخص عام لا يحفظ الهدف الحقيقي.
- fixture الاختبار الحالية إنجليزية ومصطنعة بالـlabels التي يبحث عنها
  الـsummarizer، فلا تمثل محادثة عربية طبيعية ولا تثبت استدعاء المزود.

## دليل إعادة الإنتاج المحلي المصرح

يمكن استخدام request dump قديم يملكه المستخدم بدل إنشاء محادثة جديدة وملء
السياق يدويًا:

```text
request_dump_095b217a-a0f2-44b7-b221-d0ddc994ca85_20260905_231136_566.json
```

قواعد استخدامه:

- يُمرر مساره الخارجي محليًا عبر argument أو environment variable غير متتبعة؛ لا
  يثبت مسار home مطلق داخل الكود أو الوثائق.
- القراءة فقط؛ لا يعدل الملف ولا يرسل محتواه تلقائيًا إلى الشبكة.
- لا يُنسخ الملف إلى المستودع ولا يدخل Git أو artifacts أو logs.
- يحتوي dump حقول اعتماد وprovider replay حساسة؛ تُهمل credentials تمامًا وتُعقم
  headers وtokens وopaque replay قبل أي diagnostic output أو fixture مشتقة.
- يستخدم request body المعقم لإثبات أن model projection الحالية تبدأ بملخص
  `Continue current task` القالبي رغم أن بقية المحادثة تحمل سياقًا فعليًا.
- الاختبار الآلي الدائم يستخدم fixture عربية مصغرة خالية من الأسرار تعيد السلوك
  نفسه، ولا يعتمد CI على ملف المستخدم الخارجي.

## القرارات المقفلة

### 0. عقد التنفيذ النهائي

- مصدر projection يعتمد على trigger: `auto` يشمل طلب المستخدم الجاري،
  و`overflow` يعيد استخدام مادة الطلب الذي فشل قبل بدء output، و`manual` يستخدم
  projection الحالية عند حد الخمول دون اختراع turn جديدة.
- لا يضيف compaction أي قياس أو enforcement أو metrics خاصة بالكاش. سلوك cache
  incidental ويملكه codec والمزود كأي طلب user عادي، وليس شرط قبول أو ادعاء
  أفضلية.
- استجابة التلخيص JSON typed إلزامية وذات schema version ثابت، بلا Markdown
  fallback. الحقول الحرجة هي `currentGoal` و`latestUserRequest` و`activeState`
  و`criticalContext` و`remainingWork`، مع رفض الأنواع الخاطئة والمفاتيح المكررة
  والحقول الحرجة الفارغة بعد redaction.
- corrective attempt واحدة تعاد من immutable base projection نفسها بتعليمة
  ephemeral مصححة؛ لا يعاد failed response ولا تتراكم instructions. أي tool call
  نتيجة غير صالحة ولا ينفذ، ولا يسمح provider/model/endpoint failover صامت؛ لا
  يجوز سوى transport retry محدود على route نفسها قبل بدء أي provider output.
- يرث summary output إعدادات وحدود الطلب العادي نفسها دون hard cap خاص بالضغط.
  يطلب prompt نحو صفحتين كإرشاد فقط، ولا يرفض JSON صالحًا بسبب طوله. وإذا لم تكف
  projection الكاملة، يستخدم recovery بعدد bounded من source chunks المتصلة، ثم
  final typed reduce pass واحدة؛ لا تصبح أي partial نتيجة authoritative.
- activation تعيد التحقق من history revision وprojection revision وroute
  signature والمزوّد والنموذج والendpoint؛ تغير أي منها يجعل النتيجة stale.
- دعم provider-native compaction يبقى مؤجلًا لمهمة مستقلة ولا يدخل نطاق 53i.

### 1. عقد أول ضغط

عند أول compaction لا توجد summary سابقة فعالة. يبنى طلب التلخيص هكذا:

```text
Current conversation exactly as prepared for the latest provider request
+ provider-visible response/replay suffix required to represent the current conversation
+ one ephemeral user message requesting a structured summary of the conversation and its goals
```

بصيغة أخرى: نأخذ الـprovider-visible projection التي كان سيستخدمها الاستدعاء
العادي التالي قبل إضافة turn مستخدم جديدة، ثم نضيف رسالة التلخيص فقط. لا نعيد
تغليف المحادثة داخل XML أو Markdown، ولا نستبدل system prompt، ولا نعيد serialize
الرسائل إلى رسالة user واحدة.

### 2. عقد الضغط المتكرر

بعد نجاح ضغط سابق، تكون الـprovider-visible projection الحالية قد أصبحت طبيعيًا:

```text
previous validated internal summary
+ retained verbatim tail
+ all later provider-visible messages and replay items
```

لذلك يبنى كل طلب ضغط لاحق هكذا:

```text
Current conversation exactly as prepared for the latest provider request
(the projection already contains the previous summary + retained tail + later messages)
+ one ephemeral user message requesting a new structured summary of the conversation and its goals
```

لا ترسل previous summary مرة ثانية في حقل جانبي، ولا تُلخص canonical head المخفية
من جديد، ولا تتراكم summaries متعددة في projection الناتجة. استجابة المزود تصبح
rolling summary الجديدة الوحيدة بعد validation والتفعيل.

### 3. عقد الطلب العادي

- يبنى الطلب بالطريق العادي للـprovider/model نفسه ومن projection الخاصة
  بالtrigger، ثم تضاف رسالة user بطلب التلخيص.
- لا توجد request settings أو limits أو wire measurements خاصة بالضغط.
- ترسل قائمة الأدوات العادية كما هي ولا يفرض `tool_choice: none`. يكون آخر سطر
  في prompt أمرًا صريحًا بعدم استخدام tool calls وإعادة JSON النهائي فقط.
- لا ينفذ runtime أي tool call ينتجه طلب التلخيص؛ tool-call output يعد نتيجة
  تلخيص غير صالحة وينهي/يصلح العملية وفق المسار المحدود دون side effect.
- أي cache reuse يحدث incidental وفق codec والمزود؛ لا يقاس أو يفرض أو يسجل
  كخاصية لعملية الضغط.

### 4. ملكية البيانات والتفعيل

- canonical conversation history تظل كاملة وغير معدلة.
- رسالة طلب التلخيص واستجابة المزود لا تحفظان كرسائل user/assistant في التاريخ.
- استجابة المزود تُparse إلى `CompactionInternalSummary` داخلية فقط.
- أحدث boundary ناجحة فقط تغير model projection.
- فشل المزود أو parsing أو quality validation أو persistence يبقي boundary
  السابقة والتاريخ الأصلي authoritative.
- manual وauto وoverflow تشترك في pipeline واحدة، مع اختلاف trigger وسياسة
  recovery فقط.

### 5. بنية الملخص واللغة

- يطلب من المزود body بلغة المحادثة الأساسية، مع إبقاء مفاتيح schema الداخلية
  ثابتة وغير مترجمة.
- يستخدم response contract structured قابلًا للتحقق، ويفضل JSON typed بدل
  Markdown Regex المعتمد على اللغة.
- تشمل summary على الأقل: الهدف ومعايير النجاح، القيود والتفضيلات، العمل المكتمل
  ونتائجه، الحالة الجارية، القرارات، العوائق والأسئلة، طلبات المستخدم المعلقة،
  الملفات والرموز والمعرفات والحالة الخارجية، والعمل المتبقي والخطوة التالية.
- تحفظ paths وUUIDs وhashes وURLs وports والأرقام ورسائل الخطأ حرفيًا.
- لا تعتمد دلالة الهدف أو العائق على كلمات `goal:` أو `blocker:` أو ترجماتها.

### 6. الفشل والطلبات الكبيرة

- المسار الأساسي هو محاولة واحدة على projection الحالية، ثم corrective attempt
  واحدة فقط عند فشل جودة يمكن إصلاحه من immutable base الأصلية.
- إذا تعذر append-only request بسبب context overflow حقيقي، يجوز لمسار recovery
  صريح استخدام source/tail selection أو bounded chunking الموجود.
- لا يستخدم أي semantic fallback محلي قالبي لمحادثة حقيقية.
- إذا فشلت كل محاولات المزود، تفشل compaction بأمان ولا تُفعّل summary ضعيفة.

## الاستفادة من OpenClaw — Adopt / Adapt / Reject

### Adopt

- التلخيص الدلالي لمحادثة حقيقية ينفذه model/provider، لا Regex أو قالب محلي.
- إبقاء canonical history كاملة وحفظ summary مع recent verbatim tail.
- حماية tool call/result والـturn boundaries عند اختيار source/tail.
- rolling summary للضغط المتكرر، وحفظ paths والمعرفات والأخطاء حرفيًا.
- quality audit وcorrective generation محدودان، والفشل النهائي يحافظ على التاريخ.
- توجيه موجز نحو صفحتين دون حد خاص، وchunking/fallback للمدخلات التي لا يمكن
  إرسالها في request واحدة.

### Adapt

- OpenClaw يعيد serialize الرسائل داخل `<conversation>` مع summarization system
  prompt مستقل؛ Sanad تستخدم بدلًا منه رسالة user عادية ضمن projection الحالية.
- تستمر durable boundary وCAS والqueue وtimeline الخاصة بـSanad بدل نقل session
  entry model أو successor transcript من المرجع.
- تُحوّل summary إلى typed internal structure بدل الاعتماد على Markdown headings.

### Reject / Defer

- رفض أي production fallback يعيد `Continue current task` أو summary عامة عند
  وجود محادثة حقيقية.
- رفض تغيير system prompt أو إعادة تغليف التاريخ في المسار الأساسي.
- تأجيل provider-native compact endpoints إلى capability مستقلة؛ لا تكون شرطًا
  لإصلاح التلخيص العام متعدد المزودين.
- عدم جعل model تلخيص مختلف هو الافتراضي في هذه المهمة؛ أي override مستقبلي
  يكون opt-in واضحًا بسياسة تكلفة منفصلة.

## البوابات

### G-1 — تثبيت عقد التنفيذ النهائي

- [x] تثبيت projection semantics المختلفة لـ`auto` و`overflow` و`manual` في
  request builder واختباراتها.
- [x] تثبيت JSON schema version والحقول الحرجة وسياسة unknown keys، مع عدم فرض
  حدود طول خاصة بالضغط.
- [x] تثبيت أن compaction لا يضيف قياسًا أو enforcement أو metrics خاصة بالكاش.
- [x] تثبيت وراثة output settings العادية وcorrective retry وroute fencing وعقد
  bounded chunk/reduce.

#### قبول G-1

- [x] Given أي trigger مدعوم، when يبنى طلب التلخيص، then يحتوي أحدث طلب مستخدم
  واجب الاستمرار ولا يعيد مادة تاريخية مخفية أو يخترع turn جديدة.
- [x] Given محاولة إصلاح أو تغير route أثناء التلخيص، then تعاد المحاولة من base
  الأصلية على route نفسها أو ترفض النتيجة stale دون تفعيل boundary.

### G0 — إثبات العيب وتثبيت عقد طلب المزود

- [x] تشغيل diagnostic read-only على dump المصرح بعد تعقيمه وإثبات الملخص القالبي
  الحالي دون إرسال network request أو كشف credentials/replay.
- [x] إضافة fixture عربية مصغرة تغطي الفشل القديم والملخص الدلالي الجديد.
- [x] إثبات composition الإنتاجية التي كانت تسقط إلى `StructuredCompactionSummarizer`.
- [x] توثيق أن رسالة التلخيص تستخدم provider projection والأدوات والإعدادات
  العادية دون مسار كاش خاص.
- [x] توسيع سجل R0 بفحص OpenClaw المركز: provider-backed summarization، rolling
  summary، quality guard، وfailure behavior.

#### قبول G0

- [x] Given الـdump المعقم، when يفحص المسار الحالي، then يثبت أن الملخص القالبي
  لا يمثل هدف المحادثة دون نسخ أي secret أو إجراء network call.
- [x] Given request عادية ونسخة compaction منها، then الاختلاف المسموح المحدد في
  العقد هو final appended summary instruction فقط.

### G1 — Provider-backed summarizer وDI آمنة

- [x] إضافة summarizer إنتاجي يحل exact session route/model من
  `AgentRuntimeService` ولا يحتفظ adapter موازية أو route stale.
- [x] حقن summarizer الحقيقي صراحة في production DI.
- [x] جعل `StructuredCompactionSummarizer` test-only أو تسميته/حدوده بما يمنع
  استعماله الصامت في الإنتاج.
- [x] ربط summarization request بـcompaction cancellation scope وrequest
  identity مستقلة دون نشر content/reasoning إلى timeline.
- [x] تسجيل usage/cached-input الخاصة بطلب التلخيص بصورة typed عبر نفس normalization
  المستخدم للطلبات العادية، بما فيه `input_tokens_details.cached_tokens`، دون
  خلطها بقياس الاستدعاء العادي التالي.
- [x] تسجيل summarization input/cached/cache-write/output/reasoning tokens والمدة
  وعدد المحاولات منفصلة عن post-activation request pressure.

#### قبول G1

- [x] Given daemon إنتاجي ومزود صالح، when تبدأ compaction، then يثبت mock/spy أن
  adapter استدعيت وأن الـsummarizer القالبي لم يُستخدم.
- [x] Given missing provider أو timeout أو cancellation، then تنتهي العملية failed
  ولا تُفعّل boundary ولا تفقد queue/history.

### G2 — Cache-preserving request construction

- [x] بناء `CompactionProviderRequest` من exact provider-visible projection التي
  كان سيستخدمها الاستدعاء العادي التالي.
- [x] إلحاق summary instruction واحدة فقط كرسالة ephemeral غير canonical.
- [x] دعم Codex Responses/OpenAI-compatible/Anthropic-compatible وبقية codecs
  المسجلة دون منطق provider-specific داخل compaction engine؛ يغطي اختبار عقد
  request builders الحقيقية لعائلات adapters الأربع التي تضم templates الستة عشر.
- [x] الحفاظ على replay/encrypted reasoning items وtool schemas وترتيبها كما
  يقرر codec المالك.
- [x] منع تنفيذ tool calls من response التلخيص مع typed invalid-summary outcome
  ومحاولة تصحيحية واحدة من immutable base.
- [x] إضافة strict wire-extension test للمسار القابل للقياس، مع تصنيف bounded
  `unverified` لبقية codecs بدل ادعاء parity غير مثبت.

#### قبول G2

- [x] Given أول compaction، then كل عناصر الطلب السابق تبقى متطابقة ومترتبة،
  وتظهر بعدها summary instruction واحدة فقط.
- [x] Given compaction متكررة، then prefix الحالية تحتوي summary السابقة والذيل
  والرسائل اللاحقة مرة واحدة، وتضاف instruction الجديدة فقط.
- [x] Given provider reports cached input top-level أو داخل
  `input_tokens_details`، then metrics تعرض القيمة كما أعادها
  المزود دون ادعاء cache hit عند غيابها.

### G3 — Structured multilingual summary وvalidation

- [x] استبدال Markdown Regex بعقد structured typed ثابت المفاتيح.
- [x] طلب body بلغة المحادثة الأساسية مع إبقاء keys غير مترجمة.
- [x] إزالة اعتماد continuity extraction على labels إنجليزية كشرط لفهم intent؛
  الحقول الدلالية typed هي شرط القبول، والـlabels القديمة anchors إضافية فقط.
- [x] التحقق من جميع الأقسام الحرجة، أحدث طلب مستخدم، pending work، والمعرفات
  والpaths والtool side effects اللازمة للاستمرار.
- [x] corrective request واحدة عند نقص قابل للإصلاح من immutable base نفسها،
  دون تنفيذ tools.
- [x] إبقاء redaction قبل persistence وبعد parsing دون تحوير provider-visible
  prefix الذي سبق أن أرسل للمزود نفسه.

#### قبول G3

- [x] Given محادثة عربية طبيعية بلا labels، then summary عربية تحفظ الهدف الفعلي
  والقيود والعمل المتبقي ولا تحتوي النص القالبي القديم.
- [x] Given محادثة مختلطة، then اللغة الأساسية محفوظة وcode/paths/IDs تبقى حرفية.
- [x] Given summary ناقصة أو tool call أو malformed structure، then لا تُفعّل
  boundary بعد استنفاد corrective attempt المحدودة.

### G4 — Repeated compaction وprojection activation

- [x] إثبات أن أول boundary تحقن summary واحدة مع retained tail المتصل.
- [x] إثبات أن الضغط التالي يلخص projection الحالية التي تحتوي summary السابقة
  طبيعيًا، دون تمرير previous summary ثانية أو إعادة hidden canonical head.
- [x] الحفاظ على source/tail durable identities وtool-batch safety وCAS الحالية.
- [x] إعادة قياس request بعد التفعيل وإثبات تقدم فعلي وعدم immediate re-compaction.
- [x] الحفاظ على causal lifecycle وqueue FIFO وrestart hydration الحالية.

#### قبول G4

- [x] Given ثلاث عمليات ضغط متتابعة لمحادثة عربية، then يبقى الهدف والقيود
  والpending ask محفوظين، وتوجد summary واحدة فقط في كل active projection.
- [x] Given تغير history revision أثناء summarization، then ترفض النتيجة stale
  ولا تحل محل boundary الصحيحة.

### G5 — Overflow وbounded fallback

- [x] إثبات أن auto threshold يحجز مساحة تكفي غالبًا للappend-only instruction
  وsummary output قبل overflow.
- [x] عند رفض الطلب لحجمه، استخدام recovery محدود يختار source آمنة أو chunks
  متصلة ويحافظ على tool groups.
- [x] عدم استخدام fallback recovery بعد بدء provider output.
- [x] عدم activation إلا بعد نجاح summary النهائية وإعادة القياس تحت الميزانية.
- [x] منع partial chunk summary غير المعلّمة أو template fallback من أن تصبح
  authoritative.

#### قبول G5

- [x] Given proactive pressure مع مساحة محجوزة، then يستخدم الطلب العادي الكامل
  ولا يدخل chunk fallback.
- [x] Given authoritative overflow قبل output، then توجد recovery واحدة محدودة؛
  نجاحها يتابع مرة واحدة وفشلها يحافظ على التاريخ ويظهر typed failure.

### G6 — الاختبارات والتوثيق والتحقق الحي

- [x] اختبارات Agent مركزة للـDI والـrequest builder والparser والvalidator
  والrepeated compaction والoverflow والحفظ.
- [x] daemon-backed E2E متسلسل يثبت manual وauto compaction مع provider fixture
  حقيقية قابلة للرصد دون استخدام credentials المستخدم.
- [x] تحقق live مصرح باستخدام `SANAD_HOME=$HOME/.sanad-test` فقط، وعدم استخدام
  `$HOME/.sanad` الرئيسية، مع جلسة عربية وقراءة cached-input usage عندما يعيدها المزود.
- [x] تحديث `docs/agent_engine/context_compaction_design.md` و
  `docs/technical/context_compaction.md` و
  `docs/qa_maintenance/context_compaction_qa.md` وأقرب contracts التي تصبح stale.
- [x] تحديث الخطة الأم 53 لإزالة الادعاء القديم بأن deterministic summarizer
  مسار إنتاجي صحيح، وإضافة نتيجة 53i.
- [x] تشغيل Agent analyzer والاختبارات المركزة/full suite حسب blast radius، ثم
  `git diff --check` وdocs lint و`graphify update .`.
- [x] مراجعة diff؛ لا Commit أو Push أو PR، وتبقى موافقة مستقلة مطلوبة قبلها.

## معايير القبول الكلية

- [x] لا يستطيع production daemon بناء compaction engine بملخص محلي قالبي لمحادثة
  حقيقية.
- [x] أول compaction ترسل provider-visible conversation الحالية دون تغيير ثم
  تضيف summary instruction ephemeral واحدة فقط.
- [x] كل compaction لاحقة تستخدم projection الحالية، التي تحتوي summary السابقة
  والذيل والرسائل اللاحقة، ثم تضيف instruction واحدة فقط.
- [x] compaction لا يفرض أو يقيس سلوك الكاش؛ ما يحدث منه incidental وفق codec
  والمزود ولا يمثل شرط قبول أو ادعاء أفضلية.
- [x] summary العربية تحفظ الهدف الفعلي والقيود والحالة والعمل المتبقي، ولا تعتمد
  على labels إنجليزية أو fallback ثابت.
- [x] summary request/response لا تدخل canonical timeline، بينما boundary
  validated فقط تصبح model projection authoritative.
- [x] أي tool call أو malformed/weak summary أو provider/persistence failure لا
  ينفذ side effect ولا يفقد التاريخ أو queue ولا يفعّل boundary ناقصة.
- [x] repeated compaction تحتفظ summary واحدة وتحافظ على الهدف عبر ثلاث دورات
  وتثبت انخفاض request pressure دون thrashing.
- [x] استخدام dump المستخدم بقي read-only ومحليًا ومعقمًا، ولم يدخل أي secret أو
  opaque replay أو absolute home path في Git/logs/artifacts.

## تعريف الإنجاز

- [x] تغلق البوابات بالترتيب ويسجل بعد كل بوابة دليل التحقق ونسبة المتبقي.
- [x] تنجح التحليلات والاختبارات المركزة والكاملة المطلوبة وdaemon-backed E2E.
- [x] ينجح التحقق العربي الحي عبر runtime المصرح به دون تغيير route أثناء العملية.
- [x] تتطابق وثائق design/technical/QA والعقود القريبة مع السلوك المنفذ.
- [x] يُحدث Graphify بعد تعديلات الكود.
- [x] لا Commit أو Push أو PR قبل موافقة المستخدم.

## سجل التنفيذ — 2026-09-06

- اكتملت G1–G5 ومسار G6 المحلي: provider-backed summarization العادي بلا سياسة
  cache خاصة، immutable
  corrective retry، tool-call rejection، trigger-specific projections، route
  fencing، bounded overflow recovery، metrics/persistence، وmanual/auto daemon E2E.
- التحقق: `fvm dart analyze` بلا مشاكل؛ حزمة adapters/compaction المركزة `+84`؛
  daemon E2E `+4`; full Agent suite `+1511 ~13`; docs lint ناجح؛
  `git diff --check` نظيف؛ Graphify بُني إلى 22643 عقدة و30744 حافة.
- أزيلت لاحقًا كل سياسة cache خاصة بالضغط: لا wire measurement أو prefix
  enforcement أو parity metric/persistence؛ cache behavior incidental فقط.
- اكتمل تدقيق adapters المسجلة: Codex Responses وOpenAI-compatible وAnthropic-
  compatible وOllama تمر جميعًا عبر production summarizer وتحافظ دلاليًا على
  رسالة الضغط الأخيرة والأدوات والموديل. صُحح تصنيف Anthropic `pause_turn`
  وOllama `done_reason=length` حتى لا يُعتمد JSON مقطوع؛ نجحت حزمة adapter
  المركزة `+72`.
- نجح التحقق العربي الحي عبر Codex في المحادثة
  `095b217a-a0f2-44b7-b221-d0ddc994ca85` بعد handoff صريح من المستخدم؛ بقيت
  الاستدعاءات الحية عبر OpenAI-compatible/Anthropic/Ollama اختيارية لأن عقد
  request builders والنتائج النهائية مغطى آليًا دون مفاتيح أو كلفة خارجية.
