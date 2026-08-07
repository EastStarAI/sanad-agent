---
title: "Task 67: Desktop Client–Agent Installation, Update, and Connection Lifecycle"
description: "إغلاق دورة Windows وmacOS من اكتشاف تحديث الواجهة حتى تنزيل الوكيل والتحقق منه وتثبيته وتشغيله والاتصال به، مع مسار Linux يدوي محدود واختبارات منصة قبل النشر."
status: "ready"
current_gate: "Gate A — Complete macOS and Linux Platform Audit"
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
9. الواجهة تضبط Appcast ومدة WinSparkle، لكنها لا تطلب فحصاً مؤكداً عند startup؛
   WinSparkle يعطّل الفحص التلقائي افتراضياً في أول تشغيل ما لم يُفعّل أو يُطلب
   الفحص صراحة.
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

لا يعني "آلياً" تثبيت Client الجديدة دون موافقة المستخدم؛ المطلوب فحص startup
وعرض واجهة WinSparkle، ثم تنفيذ handoff الآمنة عند قبول المستخدم. تحديث الوكيل
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

- packaged Windows Client تطلب فحص update مرة واحدة في startup بطريقة لا تمنع
  رسم التطبيق ولا تكرر dialogs.
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
- نشر Release قبل اكتمال بوابة جهاز Windows الحقيقي.

---

## Gate A — Complete Platform Audit and Approved Scope

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
- [ ] تدقيق macOS bootstrap وSparkle quit/install handoff وlaunchd وAgent update
      وhealth/socket، وتسجيل أي فجوة فعلية قبل التعديل.
- [ ] تدقيق Linux artifact selection ووجود نقطة UI مناسبة لفعل
      `Check for Updates` اليدوي دون بناء updater جديد.
- [ ] تثبيت مصفوفة platform ownership النهائية في هذا الملف إذا كشف التدقيق
      اختلافاً عن القرارات أعلاه.

### A Exit

- [ ] اكتمل تدقيق macOS وLinux بالمصدر والاختبارات ولم تبق افتراضات platform.
- [ ] لا يوجد قرار policy مؤجل قبل بدء التصميم التنفيذي.
- [x] الإصلاح محدد كدورة Desktop كاملة وليس patch لرسالة الخطأ.

---

## Gate B — Shared Trust and Version Contract

- [ ] تحويل تحقق platform artifact إلى API مركزية تعتمد artifact metadata
      وcomponent/platform، لا OS فقط.
- [ ] قبول النوع unsigned المعتمد حصراً على Windows مع بقاء كل تحقق مستقل.
- [ ] إبقاء macOS signed/notarized policy دون إضعاف.
- [ ] إزالة كل شرط يربط unsigned policy بالنسخة `1.0.0` من Agent/Client build
      وrelease workflow.
- [ ] جعل release contract والmanifest يرفضان signature types غير المعتمدة.
- [ ] جعل bootstrap يثبت تطابق manifest version مع نسخة Client المطلوبة.
- [ ] جعل daemon `/update` يستقبل target version ويتحقق منها قبل التنزيل.
- [ ] تعريف نتائج typed تميز: network، manifest، unsupported target، trust،
      checksum، schedule، replacement، rollback، start، health، version، auth.
- [ ] تحديث `docs/technical/update_architecture.md` و
      `docs/operations/release_and_signing.md` بسياسة unsigned المؤقتة وآلية
      الانتقال future signed-only.
- [ ] تحديث أقرب `AGENTS.md` فقط إذا غيّر التنفيذ قانوناً دائماً أو جعل قانوناً
      حالياً stale؛ لا يُستخدم العقد كسجل تنفيذ.

### B Exit

- [ ] bootstrap وAgent updater يستهلكان policy واحدة.
- [ ] لا يوجد قبول عام لكل unsigned artifact؛ القبول مرتبط بنوع manifest معلوم
      وWindows component policy.
- [ ] لا يمكن تنزيل نسخة تختلف عن target المطلوبة.
- [ ] إصدار Windows جديد لا يحتاج PFX ما دامت policy المؤقتة فعالة.

---

## Gate C — Client–Agent Lifecycle Implementation

### C1. أول تثبيت

- [ ] إعادة بناء orchestration كتسلسل typed قابل للاختبار.
- [ ] ضمان idempotent service registration وعدم تكرار start بلا حاجة.
- [ ] polling محدود للـhealth والنسخة بدلاً من مهلات ثابتة فقط.
- [ ] إثبات WebSocket connection بعد health قبل إعلان النجاح.
- [ ] السماح بإعادة محاولة كاملة بعد failure دون future محبوسة أو state قديمة.
- [ ] عرض رسالة actionable خاصة بالمرحلة مع الاحتفاظ بتفاصيل آمنة في logs.

### C2. تحديث Agent مثبت

- [ ] تمرير target version من Client إلى daemon.
- [ ] رفض downgrade وlatest mismatch.
- [ ] عدم إيقاف daemon إن فشلت جدولة replacement.
- [ ] إعادة تشغيل backup عند rollback.
- [ ] انتظار Client لعودة health بالنسخة المطلوبة ثم إعادة WebSocket connection.
- [ ] إبقاء Agent القديم عاملاً عند download/verification/scheduling failure.

### C3. تحديث Client على Windows وmacOS

- [ ] تنفيذ startup update check مرة واحدة دون حجب startup.
- [ ] منع RC feed من Stable Client.
- [ ] على Windows إضافة listener لـ`before-quit-for-update` وshutdown handoff
      آمنة؛ على macOS الحفاظ على Sparkle handoff الأصلية وإصلاحها فقط إذا أثبت
      Gate A فجوة مماثلة.
- [ ] إزالة listener/resources المضافة عند dispose.
- [ ] إبقاء manual check صالحاً وعدم تكرار dialogs المتزامنة.
- [ ] عدم توحيد WinSparkle DSA وSparkle EdDSA أو quit semantics قسراً؛ يشتركان
      في orchestration فقط وتبقى platform adapter مالكة للتفاصيل.

### C4. مسار Linux اليدوي المحدود

- [ ] إضافة فعل `Check for Updates` ظاهر على Linux من سطح إعدادات مناسب.
- [ ] إعادة استخدام manifest parsing واختيار Linux artifact العام الموجودين.
- [ ] فتح الرابط الرسمي خارجياً بعد تأكيد وجود نسخة أحدث، دون تنزيل أو استبدال
      أو صلاحيات elevated داخل التطبيق.
- [ ] عرض `up_to_date` أو فشل discovery بصورة غير مانعة للاستخدام.
- [ ] توثيق خطوات الاستبدال اليدوي والحفاظ على Sanad Home في user guide.

### C Exit

- [ ] كل نجاح منشور للواجهة يثبت النتيجة النهائية لا مجرد بدء عملية.
- [ ] كل فشل يحدد المرحلة ويحافظ على آخر runtime صالحة متى أمكن.
- [ ] Client الجديدة تنهي الدورة سواء كان Agent مفقوداً أو أقدم.
- [ ] Client/Agent المتطابقتان لا تعيدان update أو install بلا داعٍ.

---

## Gate D — Automated Verification

### D1. Shared contract and trust tests

- [ ] Windows Agent `unsigned+github-attestation` ينجح بعد canonical URL/size/hash.
- [ ] Windows Client update metadata تحتفظ بـWinSparkle DSA.
- [ ] empty/unknown signature type يفشل.
- [ ] Windows signed artifact لا يُقبل تلقائياً إن لم تطابق metadata policy
      المعلنة؛ الانتقال المستقبلي يحتاج قراراً صريحاً.
- [ ] macOS invalid signature/notarization يفشل كما قبل.
- [ ] wrong repository/tag/URL/version/architecture/size/SHA يفشل.

### D2. Bootstrap tests

- [ ] download progress 100% يتبعه نجاح trust/install، لا false failure.
- [ ] mismatch بين target وmanifest يمنع download.
- [ ] فشل service registration/start/health/version/auth/socket يعيد النوع الصحيح.
- [ ] retry بعد كل failure ممكن وidempotent.
- [ ] existing executable يبقى عند verification failure.

### D3. Agent update tests

- [ ] exact target upgrade ينجح.
- [ ] latest مختلفة عن target تُرفض.
- [ ] agent newer لا يتعرض لـdowngrade.
- [ ] scheduling failure لا يوقف daemon.
- [ ] replacement success يبدأ الجديد.
- [ ] replacement/start failure يعيد القديم ويشغله.
- [ ] concurrent/repeated update requests لا تتجاوز lock أو تفسد backup.

### D4. Client self-update and Linux manual-update tests

- [ ] Windows وmacOS startup ينفذان check واحدة فقط بعد feed initialization.
- [ ] source run لا يفحص packaged update.
- [ ] Appcast failure لا يمنع startup.
- [ ] Windows `before-quit-for-update` ينفذ shutdown handoff مرة واحدة.
- [ ] WinSparkle DSA/public key wiring يبقى موجوداً في Windows binary contract.
- [ ] Sparkle EdDSA/feed contract يبقى صالحاً على macOS.
- [ ] Linux لا تنفذ background check أو install، والفعل اليدوي لا يفتح رابطاً
      إلا لartifact رسمية أحدث مطابقة للمنصة.

### D5. Focused commands

ينفذ المنفذ الأوامر وفق الملفات الفعلية، باستخدام FVM وoutput محدود يحفظ exit
status. المسارات النهائية تُثبت في handoff ولا تبقى placeholders:

```bash
# release/contract
set -o pipefail; fvm dart analyze 2>&1 | tail -5
set -o pipefail; fvm dart test 2>&1 | tail -5

# agent/
set -o pipefail; fvm dart analyze 2>&1 | tail -5
set -o pipefail; fvm dart test <focused-update-tests> 2>&1 | tail -5

# client/
set -o pipefail; fvm flutter analyze 2>&1 | tail -5
set -o pipefail; fvm flutter test <focused-bootstrap-controller-updater-tests> 2>&1 | tail -5
```

### D Exit

- [ ] تمر كل حالات trust/version/install/replacement/rollback/start/connect.
- [ ] تمر analyzers والاختبارات المركزة.
- [ ] لا تتصل الاختبارات الآلية بـProduction ولا تستخدم Sanad Home للمستخدم.

---

## Gate E — Windows 11 Real-Machine Release Gate

هذه البوابة إلزامية ولا يمكن استبدالها بنجاح unit tests أو macOS development.
تستخدم Windows 11 x64 workstation/VM نظيفة مع Defender وSmartScreen مفعّلين،
وسجل أدلة لا يحتوي أسراراً.

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

### E4. macOS Real-Machine Regression Gate

على جهاز macOS مدعوم، وبـSanad Home اختبارية لا بيانات المستخدم:

1. تثبيت/تشغيل Client candidate الموقعة والمـnotarized.
2. إثبات Sparkle update من candidate أقدم إلى أحدث أو استخدام feed معزولة
   مماثلة للإنتاج.
3. إثبات missing-Agent bootstrap مع Developer ID/notarization verification.
4. إثبات launchd registration/start وauthenticated health وWebSocket.
5. إثبات Agent exact-target update وreconnect، ثم logout/login أو reboot مناسب
   يثبت بقاء الخدمة وSanad Home.
6. إثبات rollback أو بقاء Agent القديمة عند verification/replacement failure
   دون إضعاف Gatekeeper.

### E Exit

- [ ] تمر E1 وE2 وE3 على Windows 11 حقيقية/VM نظيفة.
- [ ] تمر E4 على جهاز macOS مدعوم؛ يجوز استخدام الجهاز الحالي بعد اكتمال
      التنفيذ على الفرع وقبل publication.
- [ ] Defender وSmartScreen لم يُعطلا.
- [ ] لا يبقى partial task أو staged file غير مملوك أو Agent متوقفة.
- [ ] الأدلة تسجل النسخ والنتائج دون tokens أو مسارات/بيانات شخصية غير لازمة.
- [ ] تحديث `docs/qa_maintenance/windows_release_clean_machine.md` بنتيجة
      candidate الجديدة دون تحريف دليل `1.0.0` التاريخي.

---

## Gate F — Release Publication and Production Handoff

لا تبدأ قبل E Exit.

- [ ] رفع marketing version وbuild number بشكل متسق في release contract وAgent
      وClient ومصادر Windows installer الفعلية.
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

## 5. معايير القبول النهائية

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

## 6. Handoff لجلسة التنفيذ

عند بدء جلسة جديدة، يقرأ المنفذ هذا الملف والعقود الأقرب لكل مساحة قبل التعديل،
ثم يبدأ من Gate A لإكمال تدقيق macOS وLinux، وبعد A Exit ينتقل إلى Gate B.
هذه مهمة واسعة وعالية المخاطر وتمس release/runtime؛ تُنفذ في
worktree معزولة وفق SOP المشروع، ولا تُنفذ مباشرة كتعديل سريع على النسخة
المنشورة.

تقسيم التنفيذ الموصى به:

1. إكمال macOS/Linux audit وتثبيت platform matrix؛
2. shared trust/version contract؛
3. Agent platform replacement/rollback؛
4. Desktop Client bootstrap/connect orchestration؛
5. WinSparkle/Sparkle startup/quit handoff ومسار Linux اليدوي؛
6. automated verification؛
7. Windows وmacOS real-machine gates؛
8. release candidate ثم publication.

لا يعتبر اكتمال أي جزء منفرد إذناً بالنشر أو دليلاً على اكتمال الدورة.
