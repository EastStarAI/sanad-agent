---
title: "Task 67: Desktop Client–Agent Installation, Update, and Connection Lifecycle"
description: "إغلاق دورة Windows وmacOS من اكتشاف تحديث الواجهة حتى تنزيل الوكيل والتحقق منه وتثبيته وتشغيله والاتصال به، مع مسار Linux يدوي محدود واختبارات منصة قبل النشر."
status: "in_review"
current_gate: "Task 67B / Gate E complete — pull request review; Gate F not authorized"
priority: "critical"
depends_on: "Public Windows release and update architecture"
file_budget: 24
design_contract: "docs/technical/update_architecture.md"
qa_contract: "docs/qa_maintenance/windows_release_clean_machine.md"
---

# Task 67: Desktop Client–Agent Installation, Update, and Connection Lifecycle

## 1. المشكلة

أثبتت تجربة مستخدم حقيقية على نسخة Windows المنشورة أن الواجهة تنزّل وكيل
Sanad حتى `100%` ثم تعرض:

> Failed to prepare agent components. Please check your internet connection.

الاتصال بالإنترنت ليس سبب الفشل. ملف الوكيل المنشور معلن في manifest الرسمي
بالنوع `unsigned+github-attestation` وفق سياسة Windows الحالية، بينما كل من
`VerifiedAgentBootstrapInstaller` و`AgentUpdateService` يستدعيان تحققاً يشترط
أن تكون حالة Authenticode هي `Valid`. لذلك يُرفض الملف بعد اكتمال تنزيله
والتحقق الأولي منه.

الإصلاح الموضعي لمرحلة bootstrap غير كافٍ؛ التدقيق كشف أن الدورة الكاملة
تحتوي أيضاً على الفجوات التالية:

1. محدّث الوكيل اللاحق يستخدم شرط Authenticode المتعارض نفسه.
2. `tag` الذي تمرره الواجهة لا يحدد artifact فعلياً؛ bootstrap والتحديث يستهلكان
   `releases/latest` دون إثبات مطابقته لنسخة الواجهة.
3. الواجهة تقارن نسخة الوكيل بالمساواة، بينما محدّث الوكيل يملك semantics
   مختلفة وقد يعيد نجاح `up_to_date` عند وجود mismatch لا يستطيع إصلاحه.
4. تحديث وكيل Windows يُبلّغ عن staging قبل إثبات اكتمال الاستبدال وتشغيل النسخة
   الجديدة، ونتيجة جدولة عملية الاستبدال المنفصلة ليست gate ملزمة.
5. rollback في script الاستبدال يعيد الملف القديم لكنه لا يضمن إعادة تشغيل
   الخدمة القديمة.
6. الواجهة تنتظر مدة ثابتة قصيرة بعد التحديث بدلاً من polling محدود يثبت health
   والنسخة النهائية.
7. محاولة اتصال محلية فاشلة يمكن أن تبقى ممثلة بـfuture مكتملة دون مسار retry
   واضح للدورة نفسها.
8. رسالة الفشل الحالية تختزل كل أخطاء manifest/verification/filesystem/service/
   health/authentication في خطأ إنترنت مضلل.
9. إضافة interactive check صريحة عند startup سببت نافذة `up to date` عند كل
   فتح. قرار المالك المثبت هو العودة إلى consent-based scheduled checks الأصلية،
   مع manual interactive check منفصلة في Settings.
10. التطبيق لا يملك listener لحدث `before-quit-for-update` الذي يصدره WinSparkle،
    فلا توجد handoff مثبتة تغلق الواجهة بأمان قبل تشغيل المثبت.
11. مسار الإصدار يسمح بغياب Authenticode لـ`1.0.0` فقط؛ أي إصدار إصلاحي جديد
    يطلب شهادة غير متاحة حالياً.
12. لا يوجد اختبار Windows end-to-end دائم يثبت دورة Client-driven bootstrap
    والتحديث والاتصال الفعليين.

---

## 2. الهدف

تنفيذ دورة Desktop مشتركة لـWindows وmacOS بدلاً من إنشاء إصلاح Windows
منفصل يتكرر لاحقاً. تبقى سياسات الثقة والاستبدال والخدمة خاصة بالمنصة، لكن
اختيار النسخة والـmanifest والنتائج typed وانتظار health وإعادة الاتصال تكون
عقداً مشتركاً. Windows هي بوابة الخلل والإصدار الحرجة، وmacOS تملك بوابة
regression فعلية تحمي مسار Developer ID/notarization وlaunchd/Sparkle.

تسليم إصدار إصلاحي جديد يثبت سيناريو Windows التالي كاملاً:

1. تفتح نسخة Client قديمة منشورة.
2. تكتشف Stable Appcast الجديدة وتعرض للمستخدم تحديث الواجهة.
3. يقبل المستخدم التحديث، فتغلق الواجهة بأمان ويكتمل تثبيت Client الجديدة.
4. عند الفتح، إذا لم يوجد وكيل محلي، تنزّل الواجهة وكيل الإصدار المتوافق، تتحقق
   منه، تثبته كـScheduled Task للمستخدم، تشغله، وتنتظر health مصادقاً ثم تتصل
   عبر WebSocket المحلي.
5. إذا وجد وكيل أقدم، تطلب الواجهة من الوكيل تحديث نفسه إلى النسخة المتوافقة،
   وتنتظر الاستبدال وإعادة التشغيل والاتصال.
6. إذا فشل الاستبدال، تعود النسخة السابقة وتُشغّل، ويظهر فشل قابل للتشخيص دون
   ترك الجهاز بلا وكيل عامل.
7. في الإصدارات اللاحقة تتكرر الدورة آلياً عند اختلاف نسخة الوكيل المطلوبة،
   دون تنزيل أحدث نسخة عشوائياً أو downgrade صامت.

وعلى macOS تثبت المهمة الدورة المقابلة باستخدام المسارات الأصلية للمنصة:
Sparkle لتحديث Client، وDeveloper ID/notarization للتحقق، وlaunchd لتثبيت وتشغيل
Agent، ثم authenticated health وWebSocket وإعادة الاتصال بعد تحديث Agent. لا
تُنسخ PowerShell/WinSparkle/Scheduled Task semantics إلى macOS.

لا يعني "آلياً" تثبيت Client الجديدة دون موافقة المستخدم؛ Sparkle/WinSparkle
تنفذ الفحص المجدول في الخلفية بعد موافقة المستخدم ولا تعرض نافذة إلا عند وجود
تحديث. الفحص التفاعلي الصريح متاح من **Settings → General → Check for Updates**،
ثم تنفذ handoff الآمنة عند قبول المستخدم. تحديث الوكيل
المحلي بعد تشغيل Client الجديدة يجوز أن يكون تلقائياً لأنه مكوّن runtime تابع
لنسخة الواجهة، مع حالة مرئية وrollback.

---

## 3. القرارات المثبتة

### 3.1 سياسة Windows غير الموقّع المؤقتة

قرار المالك المعتمد:

- **كل إصدارات Windows، وليس `1.0.0` فقط، تبقى غير موقعة Authenticode مؤقتاً
  إلى حين الحصول على شهادة مناسبة.**
- لا يجوز ربط السماح برقم نسخة بعينه.
- Agent Windows يجب أن يعلن النوع الدقيق المعتمد مثل
  `unsigned+github-attestation`.
- Client Windows يبقى غير موقع Authenticode، بينما تحديثه عبر Appcast يحتفظ
  بتوقيع WinSparkle DSA الإلزامي.
- تبقى بوابات المستودع الرسمي، manifest schema/repository/tag، الرابط canonical،
  الحجم، SHA-256، SBOM، GitHub build provenance/attestation، والإفصاح عن غياب
  publisher identity.
- runtime لا يدّعي أنه تحقق محلياً من GitHub attestation إذا كان التحقق الفعلي
  يتم في release pipeline؛ يجب التفريق في الكود والوثائق بين runtime checksum
  verification وrelease provenance verification.
- عند توفر Authenticode مستقبلاً تُنفذ مهمة انتقال صريحة تغيّر policy المركزية
  إلى signed-only، وتمنع قبول النوع unsigned للنسخ الجديدة. لا تُقبل النسخ
  الموقعة وغير الموقعة معاً بصمت بعد الانتقال.

### 3.2 ملكية التحقق

- لا تستدعي bootstrap أو updater دالة تعتمد `operatingSystem` فقط ثم تستنتج
  policy ناقصة.
- يجب أن يستقبل مالك trust metadata الخاصة بالـartifact، بما فيها
  `signatureType`، ويطبق سياسة platform/component المركزية نفسها على:
  1. أول تثبيت من Client؛
  2. تحديث Agent الذاتي؛
  3. اختبارات عقد الإصدار.
- أي `signature_type` مجهول أو فارغ يفشل مغلقاً.
- الحجم وSHA-256 والرابط canonical شروط مستقلة لا يسقطها السماح بغياب
  Authenticode.

### 3.3 تطابق Client وAgent

- كل Stable release لهذه الدورة ينشر Client وAgent بهوية إصدار واحدة.
- Client تمرر النسخة المطلوبة صراحة إلى daemon update endpoint.
- manifest المحمّلة يجب أن تطابق النسخة المطلوبة قبل تنزيل artifact؛ `latest`
  يجوز أن يكون discovery URL فقط، وليس إذناً بتحميل نسخة مختلفة.
- bootstrap يرفض manifest لا تطابق نسخة Client المتوقعة.
- الوكيل الأقدم يجوز ترقيته فقط إلى النسخة المطلوبة.
- لا تنفذ الواجهة downgrade تلقائياً لوكيل أحدث. تعرض حالة compatibility واضحة
  وتطلب تحديث Client أو مسار recovery مناسب.
- النجاح يعني أن health النهائية أبلغت النسخة المطلوبة، لا مجرد أن download أو
  staging اكتمل.

### 3.4 دورة الاستبدال على Windows

- لا يوقف daemon نفسه ما لم تُقبل جدولة detached replacement بنجاح.
- الاستبدال يحفظ backup، يستبدل الملف، ويبدأ Scheduled Task/الخدمة.
- عند فشل تشغيل الجديد، يستعيد القديم **ويعيد تشغيله** قبل إنهاء عملية
  الاستبدال.
- Client تستخدم polling محدوداً مع backoff على health المصادق، وتقبل النجاح فقط
  عند ظهور النسخة المطلوبة.
- إذا عادت النسخة القديمة بعد rollback، تصنف النتيجة كفشل update مع runtime
  مستعادة، لا نجاحاً.
- timeout لا يتحول مباشرة إلى حذف أو force kill؛ تظل النتيجة قابلة لإعادة
  الفحص والمحاولة.

### 3.5 دورة تحديث Client

- packaged Windows/macOS Client تهيئ الفحص التلقائي المجدول الذي يملكه
  Sparkle/WinSparkle ولا تستدعي interactive check عند startup؛ لا تظهر نافذة
  `up to date` عند فتح التطبيق.
- **Settings → General → Check for Updates** يطلب الفحص التفاعلي يدويًا، ويجوز
  لهذا المسار الذي بدأه المستخدم عرض نتيجة عدم وجود تحديث.
- Appcast Stable فقط هي المصدر الافتراضي؛ RC لا تظهر لمستخدم Stable.
- WinSparkle DSA verification تبقى إلزامية.
- عند `before-quit-for-update` تنفذ الواجهة shutdown handoff محدودة: flush لحالة
  Client التي تملكها، إغلاق الموارد، ثم إنهاء العملية حتى يستطيع المثبت استبدال
  الملفات.
- فشل Appcast أو انقطاع الشبكة لا يمنع فتح Client أو استخدام وكيل مثبت صالح.

### 3.6 دورة التثبيت الأول

الترتيب الملزم:

1. fetch وvalidate manifest المطلوبة؛
2. اختيار Windows x64 Agent العام المطابق؛
3. تنزيل إلى staged path؛
4. تحقق الحجم وSHA-256 وسياسة trust المعتمدة؛
5. atomic move مع backup/cleanup؛
6. تسجيل Scheduled Task idempotently؛
7. تشغيلها؛
8. polling لـauthenticated `/health` حتى النسخة المطلوبة؛
9. اتصال WebSocket محلي مصادق؛
10. نجاح onboarding والانتقال إلى provider readiness.

إعادة المحاولة بعد فشل جزئي لا تعيد تنزيل artifact صالح بلا ضرورة، ولا تنشئ
service registrations مكررة، ولا تحذف Sanad Home أو الهوية أو provider state.

### 3.7 حدود المنصات وقرار Linux

- **Windows:** تنفيذ واختبار الدورة الكاملة، بما فيها unsigned policy وWinSparkle
  وScheduled Task وPowerShell replacement وrollback وreboot.
- **macOS:** يشمله التصميم والتنفيذ المشترك والدورة الكاملة باستخدام Sparkle
  وDeveloper ID/notarization وlaunchd، مع regression حقيقية على جهاز macOS.
- **Linux:** لا يضاف updater تلقائي للـClient ولا package replacement في هذه
  المهمة. الحل المحدود الآن هو إظهار فعل user-initiated واضح باسم
  `Check for Updates` يعيد استخدام manifest الرسمية ويفتح artifact/Release
  الرسمية في المتصفح، مع توثيق أن تنزيل/استبدال Client وإعادة تشغيلها يدوي.
  لا background polling ولا تنزيل صامت ولا افتراض package manager.
- تحديث Agent المثبت يظل ضمن العقد المشترك عندما تدعمه runtime الحالية، لكن
  لا يُستخدم لتقديم ادعاء بأن Linux Client نفسها تتحدث تلقائياً.
- أي auto-update حقيقية لـLinux عبر AppImage/deb/rpm/package manager تؤجل إلى
  مهمة مستقلة تحدد format والملكية والrollback والتوقيع لكل distribution.

---

## 4. النطاق غير المشمول

- إصلاح فتح Client تلقائياً بعد المثبت؛ يؤجل حتى وصول installer log.
- الحصول على شهادة Authenticode أو ادعاء publisher identity غير موجودة.
- التحديث الصامت لـClient دون موافقة المستخدم.
- بناء auto-update أو package installer لـLinux؛ يقتصر Linux على المسار اليدوي
  المحدد في 3.7.
- تغيير Android/iOS أو cloud device update semantics أو تحديث Agent على أجهزة
  بعيدة من Client.
- نشر Release قبل اكتمال بوابتي macOS وWindows وموافقة المستخدم.

---

## 5. تقسيم التنفيذ الإلزامي بين الجهازين

### Task 67A — الجهاز الحالي macOS

تنفذ الجلسة الأولى على الجهاز الحالي فقط، وتشمل:

1. Gate A: تدقيق macOS وLinux وتثبيت مصفوفة ملكية المنصات.
2. Gate B: عقود trust/version المشتركة وسياسة Windows unsigned القابلة للاختبار
   دون ادعاء تحقق runtime على Windows.
3. Gate C: orchestration المشتركة، دورة macOS الفعلية، ومسار Linux اليدوي.
4. Gate D: الاختبارات الآلية المشتركة وبوابة macOS الحقيقية.

لا تنفذ Task 67A اختبارات WinSparkle/NSIS/Scheduled Task/PowerShell/Defender/
SmartScreen الحقيقية، ولا تعتبر mocks بديلاً عنها. يجوز تعديل الكود المشترك أو
Windows adapters عندما يلزم التصميم، لكن لا تُغلق نتائج Windows قبل Task 67B.

### Human Handoff Gate — توقف إلزامي بعد 67A

بعد إغلاق 67A يجب على الجلسة، بالترتيب:

1. تشغيل تحقق macOS والمشترك وتسجيل النتائج.
2. تحديث هذه الخطة والوثائق بنتيجة 67A والعناصر الباقية لـWindows.
3. مراجعة diff، ثم commit وpush كل نتائج 67A إلى فرع التنفيذ.
4. إثبات أن working tree نظيفة وتسجيل اسم الفرع وcommit SHA الكامل.
5. تقديم ملخص عربي للمستخدم: الملفات، الاختبارات، دورة macOS، مسار Linux،
   المخاطر المتبقية، وأعمال 67B الدقيقة.
6. تقديم أوامر checkout/pull ونص استكمال قابل للنسخ لجهاز Windows.
7. **التوقف وعدم بدء 67B أو النشر.** لا تكفي موافقة بدء 67A لتفويض Windows.

لا تبدأ Task 67B إلا بعد مراجعة المستخدم لنتائج 67A وإصداره أمراً جديداً صريحاً
على جهاز Windows يحدد الفرع/commit المطلوبين.

### Task 67B — جهاز Windows جديد

تبدأ الجلسة الثانية من commit 67A المرفوعة، وتشمل:

1. إعادة قراءة هذه الخطة والعقود والتحقق أن checkout تطابق SHA المسلّمة.
2. إكمال Windows adapters: WinSparkle quit handoff، NSIS، Scheduled Task،
   PowerShell replacement، rollback وإعادة تشغيل النسخة القديمة.
3. تشغيل analyzer/unit tests المتاحة على Windows ثم Gate E النظيفة كاملة.
4. إصلاح أي خلل Windows فعلي يظهر، وإعادة كل الاختبارات المتأثرة.
5. commit وpush نتائج 67B، ثم التوقف لمراجعة المستخدم قبل Gate F والنشر.

---

## Task 67A / Gate A — Complete Platform Audit and Approved Scope

- [x] تحديد سبب فشل 100% في bootstrap.
- [x] إثبات أن Agent updater يحمل التعارض نفسه.
- [x] تدقيق Client Appcast initialization وWinSparkle startup behavior.
- [x] تدقيق `before-quit-for-update` وعدم وجود listener في Client.
- [x] تدقيق version targeting والمقارنة الحالية.
- [x] تدقيق Windows detached replacement وrollback وانتظار health.
- [x] تدقيق service registration/start ومسار Local Gateway credential.
- [x] تدقيق الاختبارات الحالية وتحديد غياب Client-driven Windows E2E.
- [x] اعتماد المالك لسياسة unsigned لكل إصدارات Windows مؤقتاً.
- [x] اعتماد شمول Windows وmacOS في عقد Desktop، مع إبقاء semantics الأصلية
      لكل منصة.
- [x] اعتماد تأجيل Linux auto-update والاكتفاء بمسار manual check محدود.
- [x] تدقيق macOS bootstrap وSparkle quit/install handoff وlaunchd وAgent update
      وhealth/socket، وتسجيل أي فجوة فعلية قبل التعديل.
- [x] تدقيق Linux artifact selection ووجود نقطة UI مناسبة لفعل
      `Check for Updates` اليدوي دون بناء updater جديد.
- [x] تثبيت مصفوفة platform ownership النهائية في هذا الملف إذا كشف التدقيق
      اختلافاً عن القرارات أعلاه.

### A Exit

- [x] اكتمل تدقيق macOS وLinux بالمصدر والاختبارات ولم تبق افتراضات platform.
- [x] لا يوجد قرار policy مؤجل قبل بدء التصميم التنفيذي.
- [x] الإصلاح محدد كدورة Desktop كاملة وليس patch لرسالة الخطأ.

---

## Task 67A / Gate B — Shared Trust and Version Contract

- [x] تحويل تحقق platform artifact إلى API مركزية تعتمد artifact metadata
      وcomponent/platform، لا OS فقط.
- [x] قبول النوع unsigned المعتمد حصراً على Windows مع بقاء كل تحقق مستقل.
- [x] إبقاء macOS signed/notarized policy دون إضعاف.
- [x] إزالة كل شرط يربط unsigned policy بالنسخة `1.0.0` من Agent/Client build
      وrelease workflow.
- [x] جعل release contract والmanifest يرفضان signature types غير المعتمدة.
- [x] جعل bootstrap يثبت تطابق manifest version مع نسخة Client المطلوبة.
- [x] جعل daemon `/update` يستقبل target version ويتحقق منها قبل التنزيل.
- [x] تعريف نتائج typed تميز: network، manifest، unsupported target، trust،
      checksum، schedule، replacement، rollback، start، health، version، auth.
- [x] تحديث `docs/technical/update_architecture.md` و
      `docs/operations/release_and_signing.md` بسياسة unsigned المؤقتة وآلية
      الانتقال future signed-only.
- [x] تحديث أقرب `AGENTS.md` فقط إذا غيّر التنفيذ قانوناً دائماً أو جعل قانوناً
      حالياً stale؛ لا يُستخدم العقد كسجل تنفيذ.

### B Exit

- [x] bootstrap وAgent updater يستهلكان policy واحدة.
- [x] لا يوجد قبول عام لكل unsigned artifact؛ القبول مرتبط بنوع manifest معلوم
      وWindows component policy.
- [x] لا يمكن تنزيل نسخة تختلف عن target المطلوبة.
- [x] إصدار Windows جديد لا يحتاج PFX ما دامت policy المؤقتة فعالة.

---

## Task 67A / Gate C — Shared, macOS, and Linux Implementation

### C1. أول تثبيت

- [x] إعادة بناء orchestration كتسلسل typed قابل للاختبار.
- [x] ضمان idempotent service registration وعدم تكرار start بلا حاجة.
- [x] polling محدود للـhealth والنسخة بدلاً من مهلات ثابتة فقط.
- [x] إثبات WebSocket connection بعد health قبل إعلان النجاح.
- [x] السماح بإعادة محاولة كاملة بعد failure دون future محبوسة أو state قديمة.
- [x] عرض رسالة actionable خاصة بالمرحلة مع الاحتفاظ بتفاصيل آمنة في logs.

### C2. تحديث Agent مثبت — المشترك وmacOS

- [x] تمرير target version من Client إلى daemon.
- [x] رفض downgrade وlatest mismatch.
- [x] تنفيذ واستعادة atomic replacement على macOS مع إبقاء النسخة القديمة عند
      download/verification/replacement failure.
- [x] انتظار Client لعودة health بالنسخة المطلوبة ثم إعادة WebSocket connection.
- [x] إبقاء Windows replacement خلف adapter/نتيجة typed المتفق عليها، لكن تؤجل
      semantics الفعلية لـPowerShell/Scheduled Task وإثباتها إلى Task 67B.

### C3. تحديث Client — المشترك وmacOS

- [x] تهيئة automatic scheduled checks دون استدعاء interactive check عند
      startup، مع إظهار نافذة فقط عندما يكتشف Sparkle/WinSparkle تحديثًا.
- [x] إتاحة manual interactive check من Settings على Windows/macOS مع إبقاء
      مسار Linux اليدوي.
- [x] منع RC feed من Stable Client.
- [x] الحفاظ على Sparkle handoff الأصلية على macOS وإصلاحها فقط إذا أثبت Gate A
      فجوة فعلية.
- [x] إزالة listener/resources المضافة عند dispose.
- [x] إبقاء manual check صالحاً وعدم تكرار dialogs المتزامنة.
- [x] إبقاء WinSparkle خلف platform adapter؛ إضافة Windows
      `before-quit-for-update` وإثبات quit/install handoff ملك Task 67B.

### C4. مسار Linux اليدوي المحدود

- [x] إضافة فعل `Check for Updates` ظاهر على Linux من سطح إعدادات مناسب.
- [x] إعادة استخدام manifest parsing واختيار Linux artifact العام الموجودين.
- [x] فتح الرابط الرسمي خارجياً بعد تأكيد وجود نسخة أحدث، دون تنزيل أو استبدال
      أو صلاحيات elevated داخل التطبيق.
- [x] عرض `up_to_date` أو فشل discovery بصورة غير مانعة للاستخدام.
- [x] توثيق خطوات الاستبدال اليدوي والحفاظ على Sanad Home في user guide.

### C Exit

- [x] على macOS كل نجاح منشور للواجهة يثبت النتيجة النهائية لا مجرد بدء عملية.
- [x] كل فشل مشترك/macOS يحدد المرحلة ويحافظ على آخر runtime صالحة متى أمكن.
- [x] Client macOS الجديدة تنهي الدورة سواء كان Agent مفقوداً أو أقدم.
- [x] Client/Agent المتطابقتان لا تعيدان update أو install بلا داعٍ.
- [x] Linux manual check مكتملة دون auto-install.
- [x] Windows adapters تبني وتملك عقوداً typed، لكن نتائج Windows الحقيقية تبقى
      مفتوحة بوضوح لـTask 67B.

---

## Task 67A / Gate D — Automated and macOS Verification

### D1. Shared contract and trust tests

- [x] Windows Agent `unsigned+github-attestation` ينجح بعد canonical URL/size/hash.
- [x] Windows Client update metadata تحتفظ بـWinSparkle DSA.
- [x] empty/unknown signature type يفشل.
- [x] Windows signed artifact لا يُقبل تلقائياً إن لم تطابق metadata policy
      المعلنة؛ الانتقال المستقبلي يحتاج قراراً صريحاً.
- [x] macOS invalid signature/notarization يفشل كما قبل.
- [x] wrong repository/tag/URL/version/architecture/size/SHA يفشل.

### D2. Bootstrap tests

- [x] download progress 100% يتبعه نجاح trust/install، لا false failure.
- [x] mismatch بين target وmanifest يمنع download.
- [x] فشل service registration/start/health/version/auth/socket يعيد النوع الصحيح.
- [x] retry بعد كل failure ممكن وidempotent.
- [x] existing executable يبقى عند verification failure.

### D3. Agent update tests

- [x] exact target upgrade ينجح.
- [x] latest مختلفة عن target تُرفض.
- [x] agent newer لا يتعرض لـdowngrade.
- [x] scheduling failure لا يوقف daemon.
- [x] replacement success يبدأ الجديد.
- [x] replacement/start failure يعيد القديم ويشغله.
- [x] concurrent/repeated update requests لا تتجاوز lock أو تفسد backup.

### D4. Client self-update and Linux manual-update tests

- [x] macOS/Windows startup تهيئ feed والجدولة دون interactive check.
- [x] manual check على macOS/Windows تستدعي native interactive API مرة واحدة.
- [x] source run لا يهيئ أو يفحص packaged update.
- [x] Appcast failure لا يمنع startup.
- [x] WinSparkle DSA/public key wiring يبقى موجوداً كعقد static على macOS/CI.
- [x] Sparkle EdDSA/feed contract يبقى صالحاً على macOS.
- [x] Linux لا تنفذ background check أو install، والفعل اليدوي لا يفتح رابطاً
      إلا لartifact رسمية أحدث مطابقة للمنصة.

### D5. Focused commands

ينفذ المنفذ الأوامر وفق الملفات الفعلية، باستخدام FVM وoutput محدود يحفظ exit
status. المسارات النهائية تُثبت في handoff ولا تبقى placeholders:

```bash
# release/contract
set -o pipefail; fvm dart analyze 2>&1 | tail -5

# agent/
set -o pipefail; fvm dart analyze 2>&1 | tail -5
set -o pipefail; fvm dart test test/core/update/release_manifest_test.dart 2>&1 | tail -5

# client/
set -o pipefail; fvm flutter analyze 2>&1 | tail -5
set -o pipefail; fvm flutter test test/unit/services/verified_agent_bootstrap_installer_test.dart test/unit/services/local_daemon_controller_test.dart test/unit/services/device_connection_coordinator_test.dart 2>&1 | tail -5
```

### D6. macOS Real-Machine Gate

على الجهاز الحالي وبـSanad Home اختبارية لا بيانات المستخدم:

1. تثبيت/تشغيل Client candidate الموقعة والمـnotarized.
2. إثبات Sparkle update من candidate أقدم إلى أحدث أو feed معزولة مماثلة للإنتاج.
3. إثبات missing-Agent bootstrap مع Developer ID/notarization verification.
4. إثبات launchd registration/start وauthenticated health وWebSocket.
5. إثبات Agent exact-target update وreconnect وبقاء Sanad Home.
6. إثبات rollback أو بقاء Agent القديمة عند verification/replacement failure
   دون إضعاف Gatekeeper.

### D Exit — إغلاق 67A والتوقف

- [x] تمر حالات trust/version/install/replacement/rollback/start/connect المشتركة
      ودورة macOS الفعلية.
- [x] تمر analyzers والاختبارات المركزة.
- [x] لا تتصل الاختبارات الآلية بـProduction ولا تستخدم Sanad Home للمستخدم.
- [x] يمر Linux manual check دون auto-install.
- [x] تبقى قائمة Windows native verification مفتوحة لـ67B ولا توصف بأنها ناجحة.
- [ ] تنفذ Human Handoff Gate: تحديث الخطة، commit، push، clean status، SHA،
      ملخص وأمر جهاز Windows. **مؤجل بأمر المالك: لا commit أو push قبل مراجعة
      الـdiff وإذن جديد صريح.**
- [x] **تتوقف الجلسة وتطلب مراجعة المستخدم؛ لا تبدأ Gate E.**

### نتيجة 67A على macOS — 2026-08-07

- أُغلقت Gates A–D برمجياً وعلى macOS 26 arm64 مع Sanad Home وlaunchd label
  وports اختبارية. لم تُوقف خدمة المستخدم ولم تُستخدم بياناته.
- مرّت analyzers والاختبارات المركزة. مرّت Client suite الكاملة: `910` نجاحاً
  وواحدة skipped. يبقى في Agent full suite فشلان baseline مثبتان أيضاً على plan
  branch: config precedence المتأثر ببيئة الجهاز، وfixture قديمة تستخدم
  `openai-codex/api_key` في daemon-backed E2E. لا يخصان diff 67A.
- نجحت Client build 1 → build 2 عبر Appcast loopback، Developer ID، Apple
  notarization، staple، Sparkle EdDSA، وإعادة التشغيل. أثبتت محاولة أولى بتوقيع
  سابق للـstaple أن Sparkle يرفض التوقيع غير المطابق fail-closed.
- كشف Gate D أن Agent الموقعة بـHardened Runtime كانت تُقتل دون entitlement
  Dart AOT. بعد إضافة entitlement ضيق نجح التنفيذ، notarization، والتحقق
  `codesign --test-requirement '=notarized'` للـCLI الخام.
- نجحت missing-Agent bootstrap الحقيقية، launchd install/start، authenticated
  health، WebSocket، older-to-target replacement، reconnect، الحفاظ على
  `auth.json` و`state.db`، وفشل start ثم rollback واستعادة health/socket.
- نُظفت كل موارد الاختبار المؤقتة. تبقى لـ67B حصراً WinSparkle quit/install،
  NSIS، Scheduled Task، detached PowerShell، rollback/start، reboot، Defender،
  وSmartScreen.

---

## Task 67B / Gate E — Windows Implementation and Real-Machine Gate

لا تبدأ هذه البوابة إلا على جهاز Windows وبعد Human Handoff Gate وأمر المستخدم
الصريح. هذه البوابة إلزامية ولا يمكن استبدالها بنجاح unit tests أو macOS
development. تستخدم Windows 11 x64 workstation/VM نظيفة مع Defender وSmartScreen
مفعّلين، وسجل أدلة لا يحتوي أسراراً.

### E0. Windows Native Implementation and Focused Verification

- [x] التحقق أن checkout تطابق branch وcommit SHA المسلّمتين من 67A.
- [x] تدقيق diff ونتائج 67A قبل تعديل Windows adapters.
- [x] إكمال WinSparkle scheduled background checks، manual Settings check،
      و`before-quit-for-update` handoff دون startup dialog عند عدم وجود تحديث.
- [x] إكمال NSIS upgrade behavior دون معالجة موضوع auto-launch المؤجل.
- [x] إكمال Scheduled Task install/start/status idempotently.
- [x] إكمال PowerShell detached replacement وعدم إيقاف daemon قبل نجاح الجدولة.
- [x] عند فشل الجديد: استعادة Agent القديمة وتشغيلها وإثبات health.
- [x] polling محدود للنسخة المطلوبة وWebSocket reconnect دون fixed two-second
      success assumption.
- [x] تشغيل analyzers والاختبارات المركزة على Windows وإصلاح أي platform failure.

### E1. ترقية مستخدم الإصدار الحالي

1. تثبيت Client العامة الحالية `1.0.0` بالطريقة الطبيعية.
2. إعادة إنتاج فشل bootstrap الحالي وتسجيل baseline غير حساس.
3. نشر candidate خاصة/RC جديدة وAppcast اختبارية معزولة أو profile candidate
   لا تغيّر Stable العامة قبل النجاح.
4. فتح Client القديمة وإثبات ظهور update prompt.
5. قبول التحديث وإثبات إغلاق Client واستبدالها ثم فتح النسخة الجديدة.
6. من onboarding اختيار Run Locally.
7. إثبات download، verification، install، Scheduled Task، start، authenticated
   health، النسخة، وWebSocket connection.
8. إكمال provider readiness أو الوصول إلى واجهتها دون اعتبار غياب provider
   فشلاً في Agent lifecycle.

### E2. تحديث Agent لاحق

1. تثبيت candidate pair أقدم صالح.
2. ترقية Client إلى candidate أحدث.
3. إثبات تحديث Agent تلقائياً إلى target المطابقة.
4. إثبات reconnect وإجراء local protocol request فعلي.
5. إعادة تشغيل Windows وإثبات أن Scheduled Task تشغّل النسخة الجديدة وأن
   Sanad Home بقيت.

### E3. Failure and rollback

- corrupted download/hash.
- target/manifest mismatch.
- interrupted download.
- فشل جدولة replacement.
- فشل تشغيل Agent الجديدة مع استعادة القديمة وتشغيلها.
- network unavailable مع بقاء Client وAgent الحالية قابلتين للاستخدام.
- تكرار المحاولة بعد عودة الشبكة.

### نتيجة Gate E الجارية على Windows — 2026-08-08

- أُغلق E0 برمجياً وعلى Windows 11 Pro x64 build 22621. صححت المراجعة
  `before-quit-for-update` ليكون Windows-only مع flush واحدة، وأضافت NSIS
  انتظار الإغلاق الآمن وfallback محصوراً بمسار التثبيت للنسخة العامة القديمة.
- أثبتت Scheduled Task معزولة حفظ Sanad Home وservice instance، وإعدادات
  restart، وعدم وجود execution limit. نجحت health المصادقة وWebSocket
  `get_capabilities` قبل وبعد تحديث Agent.
- نجح Agent `1.0.1` إلى `1.0.2`: لم تتوقف daemon قبل PowerShell acceptance
  marker، ثم سجلت `started` وعادت health/socket بالنسخة المطلوبة دون staged
  أو script متبقٍ.
- نجح فشل start والrollback: artifact `1.0.3` صحيحة الحجم/hash لكنها غير قابلة
  للتنفيذ، فاستُعيدت `1.0.2` وشُغلت وسُجل `rollback_completed`.
- مرّت target mismatch، hash corruption، truncated-size download، network
  unavailable مع بقاء runtime الحالية، ثم retry بعد عودة الشبكة.
- نجحت NSIS `1.0.1` إلى `1.0.2` في profile معزولة: exact-path shutdown، إزالة
  payload قديمة، Installed Apps metadata، والحفاظ على Sanad Home.
- أثبتت المراجعة التفاعلية ظهور WinSparkle `1.0.1` → `1.0.2` والتحقق من DSA،
  وإغلاق Client القديمة، وتشغيل NSIS، ثم SmartScreen بـ`Unknown publisher` دون
  UAC وفق سياسة Windows غير الموقعة الحالية.
- كشف startup النهائي سباقًا في إغلاق HTTP client قبل اكتمال قراءة health،
  وعدم اتساق fallback إلى runtime `SANAD_HOME`، وبقاء unauthenticated Desktop
  على Onboarding إذا أصبح Local Gateway ready بعد قرار المسار الأول. أضيفت
  إصلاحات واختبارات Windows لهذه الحدود.
- نجحت candidate النهائية `1.0.2+4`: لم يظهر dialog عند startup وهي up to date،
  وظهر **Settings → General → Check for Updates** وعمل الفحص التفاعلي كما هو
  متوقع. أظهر SmartScreen نص `Windows protected your PC` وسمح بالمتابعة عبر
  **More info → Run anyway**؛ لم يظهر UAC.
- نجح missing-Agent bootstrap من الواجهة إلى Agent `1.0.2` النهائية، ثم
  authenticated health وWebSocket ووصلت Client إلى Add Provider. عند التشغيل
  المباشر بعد التثبيت ظهرت console ثم صُغرت؛ قرر المالك تأجيل background
  launcher الحتمي إلى مهمة Windows لاحقة وعدم توسيع نطاق الإصدار الحالي.
- بعد reboot بدأت `SanadAgent-gate-e` من AtLogOn في الخلفية دون console ظاهرة،
  وأثبتت health `1.0.2` وWebSocket `register_success`/`get_capabilities`، ثم فتحت
  Client يدويًا واتصلت دون Run Local أو إعادة تنزيل مع بقاء Sanad Home.
- نُظفت Client/Agent/task/registry/feed/temp الخاصة بـGate E بموافقة صريحة، ولم
  تُمس `sanad-dev` أو User Sanad Home. أزيلت Scheduled Task قديمة باسم
  `SanadAgent` بعد إثبات أنها residue منفصلة كانت تشغل User Agent على `58085`؛
  لم يُحذف أي ملف من User Sanad Home.

### E Exit — إغلاق 67B والتوقف

- [x] تمر E0 وE1 وE2 وE3 على Windows 11 حقيقية/VM نظيفة.
- [x] Defender وSmartScreen لم يُعطلا.
- [x] لا يبقى partial task أو staged file غير مملوك أو Agent متوقفة.
- [x] الأدلة تسجل النسخ والنتائج دون tokens أو مسارات/بيانات شخصية غير لازمة.
- [x] تحديث `docs/qa_maintenance/windows_release_clean_machine.md` بنتيجة
      candidate الجديدة دون تحريف دليل `1.0.0` التاريخي.
- [x] commit وpush نتائج 67B على implementation branch؛ commit المثبت قبل دمج
      `main` هو `dda91b8e57a65ea7c5103db4031efe4ef183a75e`.
- [x] **التوقف وطلب مراجعة المستخدم؛ لا تبدأ Gate F ولا تنشر تلقائياً.**

---

## Final Gate F — Release Publication and Production Handoff

لا تبدأ قبل E Exit وموافقة جديدة صريحة من المستخدم على release candidate
والنشر. إكمال 67A أو 67B ليس تفويضاً للنشر.

- [x] رفع marketing version إلى `1.0.1` وbuild number إلى `2` بشكل متسق في
      release contract وAgent وClient ومصادر Windows installer الفعلية.
- [ ] بناء validation-only full matrix من commit العام المقصود.
- [ ] التحقق من Agent/Client Windows unsigned disclosure وSHA/manifest/SBOM/
      attestations وWinSparkle DSA.
- [ ] إنشاء ومراجعة RC أو Draft وفق release workflow المحمية.
- [ ] نشر GitHub Release أولاً بكل Agent/Client assets والmanifest.
- [ ] نشر Appcast atomically بعد توفر Release assets، حتى لا تشير Client قديمة
      إلى installer أو Agent manifest غير متاح.
- [ ] فحص Appcast العامة والـmanifest وكل URLs/hashes بعد النشر.
- [ ] فتح Client `1.0.0` على جهاز Windows والتحقق من ظهور Stable update العامة.
- [ ] تنفيذ smoke أخير على Windows وmacOS: Client update ثم missing-Agent
      bootstrap ثم health/socket.
- [ ] التحقق من ظهور Linux manual check وفتحه الرابط الرسمي دون محاولة install.
- [ ] إبقاء rollback للـAppcast selector متاحاً إذا فشل public smoke.

### F Exit

- [ ] المستخدم المتأثر يستطيع فتح Client القديمة، تحديثها، ثم إكمال تثبيت الوكيل
      والاتصال به دون خطوات يدوية خارج الواجهة.
- [ ] إصدار لاحق مثبت في test يحدّث Agent أقدم تلقائياً ويستعيد الاتصال.
- [ ] لا توجد وثيقة تدعي Authenticode أو trusted publisher قبل توفر الشهادة.

---

## 6. معايير القبول النهائية

تُغلق المهمة فقط عند تحقق جميع الشروط:

1. لا يفشل Agent Windows الرسمي بعد 100% بسبب غياب Authenticode المعتمد مؤقتاً.
2. bootstrap وAgent updater يطبقان trust policy واحدة ولا يضعفان URL/size/hash.
3. Client القديمة تعرض تحديث Stable عند الفتح بصورة مثبتة على Windows.
4. قبول Client update يغلق التطبيق ويثبت النسخة الجديدة بنجاح.
5. Agent المفقودة تُنزّل وتثبت وتبدأ وتتصل من onboarding كاملة.
6. Agent الأقدم تُحدّث إلى target المطابقة وتعود health/socket تلقائياً.
7. mismatch أو Agent أحدث لا يؤديان إلى downgrade أو نجاح كاذب.
8. فشل Agent replacement يعيد النسخة القديمة ويشغّلها.
9. كل الأخطاء المهمة actionable ولا تُعرض كلها كفشل إنترنت.
10. Sanad Home والهوية والإعدادات تبقى عبر Client/Agent update وrollback/reboot.
11. تمر اختبارات shared contract وAgent وClient والتحقق الحقيقي على Windows 11.
12. تمر دورة macOS المقابلة على جهاز حقيقي دون إضعاف Developer ID/notarization
    أو Sparkle EdDSA أو launchd.
13. يملك Linux مسار `Check for Updates` يدوي واضح فقط، ولا يدعي التطبيق وجود
    auto-update أو rollback غير منفذين.
14. لا تُنشر Stable/Appcast قبل اكتمال بوابتي Windows وmacOS.
15. سياسة Windows الموثقة تقول بوضوح: unsigned مؤقتاً لكل الإصدارات، ثم
    signed-only عبر انتقال مستقبلي صريح عند توفر Authenticode.

---

## 7. Handoff لجلسات التنفيذ

### 7.1 بدء Task 67A على جهاز macOS الحالي

نقطة الدخول الموثقة هي:

- plan branch: `plan/67-desktop-client-agent-lifecycle`
- plan file: `docs/plans/tasks/67-desktop-client-agent-release-lifecycle.md`

بعد checkout للـplan branch، ينشئ المنفذ worktree/branch تنفيذ معزولة باسم واضح
مثل `task/67-desktop-client-agent-lifecycle` من commit الخطة الحالية. يقرأ
العقود الأقرب، يبدأ من Gate A، ثم ينفذ 67A فقط حتى D Exit.

أمر المستخدم للجلسة يجب أن يصرح صراحة:

> نفّذ Task 67A فقط من الخطة، على macOS الحالي. أكمل Gates A–D بما فيها دورة
> macOS ومسار Linux اليدوي، ثم حدّث الخطة، اعمل commit وpush، وقدّم SHA وأمر
> Windows، وتوقف لطلب مراجعتي. لا تبدأ Task 67B أو Gate E أو النشر.

### 7.2 التسليم المطلوب من macOS إلى Windows

يجب أن تتضمن إجابة 67A النهائية:

- implementation branch المرفوعة؛
- commit SHA الكامل الذي اجتاز 67A؛
- نتائج analyzer/tests وmacOS real-machine gate؛
- ملخص Linux manual update؛
- قائمة Windows-only المتبقية؛
- أوامر `git fetch` و`git checkout`/`switch` و`git pull --ff-only` لجهاز Windows؛
- نص استكمال 67B قابل للنسخ يتضمن SHA؛
- تأكيد أن الجلسة توقفت قبل Gate E.

### 7.3 بدء Task 67B على Windows

لا تستخدم plan branch القديمة إذا سلّمت 67A implementation branch أحدث. يبدأ
Windows من branch وSHA اللتين قدمتهما جلسة macOS، ويتحقق منهما قبل التعديل، ثم
ينفذ Gate E فقط. بعد E Exit يعمل commit/push ويتوقف للمراجعة. Gate F تحتاج
موافقة ثالثة مستقلة.

لا يعتبر اكتمال 67A أو 67B إذناً بالنشر أو دليلاً على اكتمال الدورة كلها.
