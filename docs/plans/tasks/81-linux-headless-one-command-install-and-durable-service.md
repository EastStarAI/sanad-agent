# المهمة 81 — تثبيت Linux بضغطة واحدة وخدمة دائمة على Desktop وHeadless

## الحالة

- **الحالة:** قيد التنفيذ داخل worktree معزولة.
- **البوابة الحالية:** G8 — PR #120 قيد CI والمراجعة المحمية.
- **نسبة العمل المتبقي:** 8% حتى اكتمال المراجعة ثم بوابة الإصدار G9.
- **G0 الاكتشاف والقرارات:** مكتملة.
- **الإصدار المرجعي الحالي:** Sanad Agent `1.0.6`.
- **حدود التسليم:** لا commit أو push أو PR أو نشر إصدار دون موافقة صريحة من
  المالك عند البوابة المخصصة.

## الهدف

جعل أمر **Add Device** الواحد الذي يولده Sanad Client يثبت Sanad Agent ويقترنه
ويشغله بصورة دائمة على Linux Desktop وLinux Headless دون flags خاصة بالخادم،
ودون إعداد يدوي لـD-Bus أو Secret Service أو linger، ثم يعلن النجاح فقط عندما
تكون الخدمة سليمة والجهاز متصلاً فعلياً بالـGateway وظاهراً Online.

يجب أن يظل الجهاز متصلاً بعد إغلاق SSH وبعد إعادة تشغيل النظام، وأن تعمل دورة
logout/uninstall/reinstall/upgrade/rollback دون ترك اعتماد أو باينري أو وحدة
خدمة في حالة جزئية.

## سياق الحادثة المثبت

أُنشئت آلة Ubuntu 22.04 x64 نظيفة بمواصفات `e2-micro` وذاكرة تقارب 1 GB لاختبار
الإصدار `1.0.6`. الآلة وبياناتها تجريبية ولا توجد عليها بيانات مهمة. أظهرت
التجربة الوقائع التالية:

1. كان رابط `https://sanad.eaststarai.com/install.sh` يعيد 404؛ أُصلحت مهمة
   Production المستقلة وأصبح الرابط يعمل الآن. **هذا الرابط خارج نطاق هذه
   المهمة ويجب الحفاظ عليه، لا استبداله في واجهة Add Device.**
2. صيغة `curl | bash` أخفت فشل curl لأن shell الأخير خرج بنجاح.
3. وصل المثبّت إلى `sanad login --token` ثم فشل بـ
   `AgentSecretStoreUnavailable` لغياب جلسة Linux Secret Service على الخادم.
4. إنشاء D-Bus وgnome-keyring مؤقتاً أثبت أن pairing وGateway registration
   يعملان، لكن الاعتماد لم يبقَ قابلاً للقراءة بعد انتهاء الجلسة، فلم يستمر
   الجهاز Online.
5. `sanad service install` أنشأ user unit ثم فشل لأن `systemctl --user` لم يجد
   user bus أو `XDG_RUNTIME_DIR`. محاولة `loginctl enable-linger` لم تنجح على
   بيئة Google OS Login.
6. rollback حذف الباينري لكنه ترك Sanad Home ووحدة service جزئية، ثم أعلن أن
   rollback اكتمل.
7. `sanad service status` اعتبر وجود ملف الوحدة تثبيتاً ناجحاً وأظهر State
   فارغة عند فشل systemctl.
8. `sanad daemon --help` شغّل daemon فعلياً وترك عملية تحجز المنفذ المحلي.
9. `AuthManager` يكتب `pending_device_token` في `auth.json` رغم كتابته في مخزن
   الأسرار، بما يناقض فصل Device Credentials عن JSON.
10. المثبّت يعلن أن الجهاز سيظهر Online بعد نجاح أمر service فقط، دون فحص صحة
    daemon أو اكتمال cloud registration.
11. الاختبارات الحالية تعتمد بدرجة كبيرة على حراس نصية ولا تغطي clean
    headless install أو reboot أو rollback الحقيقي.

أي pairing token استُخدم أثناء التشخيص السابق يُعامل كمستهلك/مكشوف ولا يُعاد
استخدامه. يجب طلب أمر Add Device جديد عند كل تجربة pairing حقيقية، وعدم تسجيل
قيمته في المهمة أو logs أو screenshots أو أوامر محفوظة.

## أدلة المراجع ونتيجة المقارنة

راجعت مرحلة الاكتشاف ثلاثة مشاريع مرجعية محلية. الأسماء والمسارات والمقارنات
التفصيلية تبقى في دليل محلي غير متعقب؛ هذه المهمة تثبت فقط النتائج المحايدة
للمصدر:

- تخزين ملفي owner-only بـ`0700/0600` شائع وعملي في Headless Linux.
- الكتابة الآمنة تتطلب lock عابر للعمليات، وإنشاء ملف مؤقت خاص، و`fsync`، ثم
  atomic rename، مع منع symlinks.
- user systemd يحتاج capability probe فعلياً وlinger وbus صالحين؛ نجاح كتابة
  الوحدة لا يثبت نجاح التشغيل.
- system scope بديل ضروري عندما لا يمكن الاعتماد على user manager.
- تعريف الخدمة يحتاج rollback ذرياً وفحص health حقيقياً قبل إعلان النجاح.
- process detachment وPID files ليست بديلاً موثوقاً عن init manager يدعم reboot.

## القرارات المثبتة

### 1. نفس أمر التثبيت لكل Linux

- لا يوجد أمر أو flag خاص بـHeadless في الواجهة.
- يبقى رابط الأمر:
  `https://sanad.eaststarai.com/install.sh`.
- المثبّت يكتشف قدرات الجهاز ويختار مخزن الاعتماد ونطاق الخدمة تلقائياً.
- يظهر اختيار fallback كرسالة warning نظيفة في log/status فقط، ولا يطلب موافقة
  إضافية ولا يوقف التثبيت.

### 2. اختيار مخزن اعتماد Linux تلقائياً

- ينفذ المنتج capability probe حقيقياً لـSecret Service عبر write/read/delete
  لقيمة اختبار عشوائية غير صالحة للمصادقة.
- إذا نجح probe، يُستخدم `LinuxSecretServiceAgentSecretStore`.
- إذا غابت الجلسة أو فشل probe، يُستخدم مخزن ملفي owner-protected داخل
  `SANAD_HOME` تلقائياً.
- المخزن الملفي يستخدم `0700` للمجلد و`0600` للملف، وlock، وكتابة ذرية، وfsync،
  ورفض symlinks والمسارات غير الموثوقة.
- لا يُدّعى أن الملف مشفر إذا لم يكن مفتاح التشفير محمياً بصورة مستقلة. حماية
  هذا backend هي ملكية المستخدم وصلاحيات نظام الملفات.
- هوية backend المختار تحفظ كبيانات غير سرية ثابتة، حتى لا يتنقل كل تشغيل بين
  مخزنين مختلفين بصورة عشوائية.
- إذا أصبح Secret Service صالحاً لاحقاً، يجوز الترحيل التلقائي إليه فقط بعد
  write/read verification؛ تُحذف النسخة الملفية بعد نجاح التحقق، لا قبله.
- failure مؤقت لمخزن تم اختياره سابقاً لا يبيح قراءة مخزن آخر قديم أو دمج
  اعتمادات من هويتين.
- Device Credential والمفتاح الخاص وpending credential وأي pairing authority
  سرية لا تُكتب في `auth.json`.
- logout/uninstall/migration عمليات ذرية ومتحققة ولا تدعي النجاح إذا تعذر حذف
  الاعتماد.

### 3. اختيار مدير الخدمة تلقائياً

#### systemd user path

يُستخدم عندما يثبت probe أن user manager وbus صالحان، ويمكن تفعيل الخدمة
واستمرارها بعد logout/reboot. يجب فحص linger وتفعيله تلقائياً عند الحاجة، ثم
إعادة فحص socket و`systemctl --user` قبل اعتماد المسار.

#### systemd system path

إذا فشل user path، ينتقل المثبّت تلقائياً إلى system-level unit:

- عند التشغيل من مستخدم غير root مع sudo، تعمل الخدمة باسم المستخدم الأصلي.
- عند التشغيل عبر sudo، تُستخرج الهوية من `SUDO_USER` بعد التحقق منها.
- عند التشغيل مباشرة كـroot دون مستخدم أصلي، ينشئ المثبّت مستخدم خدمة غير مميز
  باسم ثابت ومسار Home/State مملوكاً له، ولا يشغّل Agent tools كـroot.
- الوحدة تحدد `User`, `Group`, `HOME`, `SANAD_HOME`, `WorkingDirectory` بصورة
  صريحة وآمنة.

#### OpenRC وغير systemd

- يكتشف المثبّت OpenRC ويوفر خدمة أصلية مكافئة تبدأ عند boot وتعيد التشغيل عند
  الفشل.
- أي init manager غير مدعوم يفشل في preflight قبل تنزيل/استبدال الباينري أو
  استهلاك pairing، ويطبع تشخيصاً واضحاً؛ لا يدعي نجاحاً ولا يترك تثبيتاً جزئياً.
- لا يُستخدم detached process كبديل صامت لا يضمن reboot.

### 4. عقد الوحدة ودورة الحياة

يجب أن تحقق الوحدة المكافئة لكل init manager:

- تشغيل Agent كمستخدم غير مميز؛
- `UMask=0077`؛
- restart عند الفشل مع delay محدود؛
- قتل مجموعة العمليات/cgroup عند الإيقاف؛
- مهلة إغلاق لا تقل عن مهلة checkpoint الآمن المعتمدة؛
- مسار عمل وSanad Home ثابتين؛
- logs نظيفة ومحدودة؛
- بدء تلقائي بعد reboot؛
- منع تعارض user/system/legacy units لنفس Sanad Home؛
- uninstall يوقف ويعطل ويحذف الوحدة التي يملكها التثبيت فقط.

### 5. المثبّت والمعاملة الذرية

- تعرض الواجهة صيغة POSIX المألوفة `curl -fsSL ... | bash` التي اعتمدها المالك
  لاتساق تجربة Sanad مع أدوات المطورين العالمية. يعرض `curl -f` فشل HTTP بوضوح،
  بينما تبقى ضمانات manifest/artifact والصحة والrollback داخل المثبّت؛ لا يدعي
  المنتج أن shell الأب سيحفظ exit status الخاص بـcurl دون `pipefail`.
- ينفذ المثبّت preflight لنظام التشغيل، المعمارية، init manager، صلاحيات
  الخدمة، مسارات Sanad Home، ومخزن الاعتماد قبل استهلاك pairing أو استبدال
  الباينري.
- يسجل snapshot للحالة السابقة: الباينري، نوع/حالة الوحدة، backend metadata،
  وحالة pairing التي يملكها نفس التشغيل.
- أي فشل يعيد الباينري والوحدة وحالة التشغيل السابقة، ويحذف فقط الملفات
  والاعتمادات التي أنشأتها المحاولة الحالية.
- لا يحذف Sanad Home أو workspaces أو بيانات مستخدم سابقة أثناء rollback أو
  upgrade.
- لا يطبع المثبّت التوكن أو المفتاح أو credential في stdout/stderr أو logs، ولا
  يمرر pairing token إلى Agent process arguments. يبقى creation token ظاهرًا في
  أمر bootstrap التقليدي ووسائط shell المؤقتة، وهو تنازل UX معتمد صراحةً.

### 6. نجاح قابل للتحقق

لا يطبع المثبّت نجاحاً قبل تحقق bounded من:

1. تسجيل وتمكين الخدمة؛
2. بقاء العملية Running؛
3. استجابة Local Gateway health مع نسخة الباينري الصحيحة؛
4. اكتمال pairing عند وجود pairing token؛
5. اتصال Cloud Gateway وتسجيل الجهاز؛
6. ظهور الحالة النهائية Online من المصدر السلطوي المتاح.

إذا لم تكتمل cloud visibility خلال المهلة، يحتفظ المثبّت بتشخيص bounded ويطبق
سياسة rollback المعتمدة بدلاً من طباعة نجاح مضلل.

### 7. CLI وتشخيص الخدمة

- `sanad daemon --help` و`sanad service --help` يعرضان المساعدة ولا يشغلان
  عملية ولا يفتحان منفذاً.
- الوسائط غير المعروفة تُرفض قبل دخول supervisor.
- `ServiceManager` يعيد نتيجة typed تحتوي installed/enabled/running/scope/
  backend/error بدلاً من bool أو stdout فارغ.
- `sanad service status` يميز بين Missing وInstalledStopped وRunning وFailed و
  ManagerUnavailable، ويعرض مخزن الاعتماد ونطاق الخدمة دون أسرار.
- رسائل الفشل تعرض السبب الفعلي المختصر، لا رسالة permissions عامة لكل الحالات.

## النطاق

### داخل النطاق

- `agent/lib/core/auth/` ومخزن الاعتماد والمهاجرة؛
- `agent/lib/core/setup/service_manager.dart` ونماذج نتائج الخدمة؛
- `agent/bin/` لأوامر login/service/help/status؛
- `scripts/install.sh` ومسار Linux فقط؛
- أمر POSIX الذي يولده Add Device واختباره في `client/`؛
- اختبارات الوحدة والتكامل وLinux clean-host؛
- وثائق المنتج والتقنية والعمليات وQA والإصدار؛
- بناء Linux x64 candidate واختباره على السيرفر الحالي ثم سيرفر جديد.

### خارج النطاق

- تغيير رابط Production أو إعداد Nginx؛ الرابط يعمل وتملكه مهمة خاصة مكتملة؛
- تغيير Backend/Gateway pairing protocol إلا إذا كشف الاختبار عيب توافق حقيقياً
  لا يمكن إصلاحه داخل Agent؛ عندها تتوقف المهمة ويُسجل handoff مستقل؛
- تغيير macOS Keychain أو Windows DPAPI إلا لمنع regression في factory المشترك؛
- نشر إصدار قبل نجاح PR وصدور موافقة مستقلة؛
- الادعاء بدعم init manager لم يُختبر فعلياً.

## ترتيب التنفيذ الإلزامي

### G0 — الاكتشاف والقرارات — مكتملة

- [x] إعادة إنتاج فشل الرابط القديم، Secret Service، user systemd، rollback،
  status، help، والاتصال المؤقت بالGateway.
- [x] عرض المشكلات والحلول المختصرة على المالك.
- [x] مراجعة ثلاثة مشاريع مرجعية محلياً.
- [x] اعتماد الاختيار التلقائي لمخزن الاعتماد والخدمة دون أمر Headless خاص.
- [x] اعتماد الملف owner-protected fallback والتحذير في log فقط.
- [x] اعتماد دعم user/system systemd وOpenRC وفق capability detection.

### G1 — إنشاء worktree وتثبيت خط الأساس — مكتملة

- [x] قراءة `AGENTS.md` و`docs/llms.txt` وعقود Agent Core وSanad Home وCLI
  وClient وDevices الحاكمة لأول مساحات التغيير.
- [x] التحقق من أن worktree المعزولة موجودة في
  `.agent/worktrees/81-linux-headless-install` على الفرع
  `feat/task-81-linux-headless-install` دون تعديل `main`.
- [x] فحص حالة الفروع/worktrees وحصر التغييرات السابقة في وثائق المهمة 81
  ووصلة الفهرس وتحديث Task 68 المرتبط بها.
- [x] ربط البوابات باختبارات القبول المحددة أدناه وتثبيت الترتيب الإلزامي.
- [x] تسجيل baseline للإصدار `1.0.6`: نجحت اختبارات auth/secret-store/service
  الحالية (`19 passed, 6 skipped`)، ونجح اختبار Widget الحالي (`2 passed`)،
  ونجح `sh -n scripts/install.sh`.
- [x] إضافة regression tests قبل الإصلاح: اختبار عدم بقاء pairing/pending
  material في `auth.json` يفشل على غياب backend key، واختبار عقد أمر POSIX
  وshell quoting يفشل على الصيغة الحالية.
- [x] تحديث الحالة إلى G2 ونسبة المتبقي إلى 80%.

#### أدلة قبول G1

- [x] `git worktree list --porcelain` يربط المسار والفرع المخصصين بالمهمة.
- [x] الاختبارات القديمة تمر قبل تعديل المنتج، والاختبارات الجديدة تفشل للسببين
  المتوقعين لا بسبب عطل بيئي.
- [x] لا commit أو push أو runtime switch أو runtime stop تم تنفيذه.

### G2 — مخزن اعتماد Linux التلقائي — مكتملة محلياً

- [x] تصميم `LinuxAgentSecretBackend` وcapability probe عشوائي
  write/read/delete دون تسجيل قيمة الاختبار.
- [x] تنفيذ `LinuxOwnerFileAgentSecretStore` عبر `SanadHomeBootstrap`.
- [x] ضمان lock ثابت عابر للعمليات، وكتابة ذرية flushed، وصلاحيات `0700/0600`،
  ورفض symlinks والبيانات التالفة.
- [x] إزالة كتابة `pending_device_token` و`pairing_token` من `auth.json` ونقل
  pairing authority إلى مخزن الاعتماد.
- [x] تثبيت backend metadata ومنع fallback من Secret Service مختار إلى ملف stale.
- [x] تنفيذ ترحيل owner-file إلى Secret Service بعد probe وwrite/read verification
  لكل entry، مع إبقاء الملف والهوية القديمة عند فشل التحقق.
- [x] تنفيذ logout/delete/restart recovery وحماية الأصل عند فساد/فشل الكتابة.
- [x] إضافة اختبارات Secret Service available/unavailable، وowner-file
  concurrency/corruption/permissions/symlink، وsticky selection، وmigration
  success/failure، و`auth.json` leakage/restart.
- [x] تحديث عقود Core وSanad Home ووثائق authentication/protection وQA. يبقى
  وصف Task 68 للإصدار المنشور الحالي مقيداً بملاحظة handoff إلى Task 81 حتى
  تنجح بوابات السيرفر والإصدار، فلا يدعي المستودع أن السلوك نُشر مبكراً.
- [x] نجح `fvm dart analyze` ونجحت اختبارات auth/secret-store/device-auth/
  Sanad Home المركزة (`50 passed, 6 platform-skipped`).
- [x] تحديث الحالة إلى G3 ونسبة المتبقي إلى 65%.

#### أدلة قبول G2

- [x] لا تحتوي `auth.json` قيمة pairing أو pending credential أثناء pending
  pairing، وتستعاد الحالتان من backend المختار بعد restart.
- [x] metadata لا تحتوي secret، وفشل backend مثبت لا يقرأ backend آخر.
- [x] فشل migration verification يبقي owner-file bytes والهوية قابلة لإعادة
  المحاولة؛ النجاح وحده يحذفها.

### G3 — خدمة Linux متعددة البيئات — مكتملة محلياً

- [x] فصل service scope detection/generation/execution عن CLI presentation.
- [x] تنفيذ user systemd probe وlinger وbus readiness وإعادة الفحص.
- [x] تنفيذ system-level fallback تحت المستخدم الصحيح دون تشغيل tools كـroot.
- [x] تنفيذ root-direct dedicated-user lifecycle دون امتلاك ملفات مستخدم آخر.
- [x] تنفيذ OpenRC install/start/stop/restart/status/uninstall.
- [x] إضافة حقول restart/kill/timeout/umask/home والعمل والسجلات.
- [x] منع الوحدات المتعارضة وإدارة migration من الوحدة الحالية.
- [x] جعل تعريف الوحدة وعمليات استبداله transactional مع backup/restore.
- [x] تنفيذ typed status/error model ورسائل CLI المحددة.
- [x] إضافة اختبارات fake-process شاملة ومصفوفة Linux integration؛ يبقى تنفيذ
  الاختبارات على init managers حقيقية ضمن G6 وG7 قبل ادعاء دعم الإصدار.
- [x] إغلاق G3 بعد analyzer والاختبارات المركزة وتحديث نسبة المتبقي.

#### أدلة قبول G3

- [x] يفصل `LinuxServiceManager` اختيار backend وتوليد الوحدة والتنفيذ عن عرض
  `agent/bin/service.dart`، وتعيد العمليات `ServiceOperationResult` وحالة typed.
- [x] تغطي الاختبارات user systemd بعد bus/linger probe، وsystem fallback،
  وroot-direct dedicated user، وOpenRC، وlegacy migration، وrollback، ورفض
  uninstall لوحدة غير مملوكة، و`ManagerUnavailable`.
- [x] نجح analyzer المركز ونجح اختبار الخدمة المركز (`12 passed`) دون تشغيل
  runtime switch أو runtime stop أو commit أو push.
- [x] وثقت المعمارية ومصفوفة QA ودليلي المستخدم والمطور، وانتقلت المهمة إلى G4
  بنسبة متبقية 50%.

### G4 — المثبّت وCLI وفحص الصحة — مكتملة محلياً

- [x] تثبيت أمر Client المولد على صيغة `curl -fsSL ... | bash` المألوفة مع إبقاء
  الرابط الحالي وshell quoting للتوكن وفق قرار المالك النهائي.
- [x] إضافة tests لفشل manifest/artifact download، وtoken quoting، وعدم تسريب
  token إلى Agent arguments أو fake command logs.
- [x] تنفيذ preflight قبل mutation أو استهلاك pairing لنظام التشغيل والمعمارية
  وinit manager والصلاحيات وSanad Home وعقد manifest/artifact.
- [x] تنفيذ transaction/rollback لـclean install/reinstall/upgrade/failure مع
  استعادة الباينري وحالة التشغيل وإلغاء pairing المعلق واستعادة الاعتماد السابق.
- [x] إصلاح `daemon --help` و`service --help` والوسائط غير المعروفة قبل supervisor.
- [x] إضافة health/version/cloud-registration probe bounded ومصادق عليه محلياً.
- [x] عدم طباعة success قبل تحقق النسخة وcloud registration عند التثبيت المتصل.
- [x] توفير test-only candidate manifest/artifact path لا يعمل إلا مع
  `SANAD_INSTALL_ALLOW_TEST_URL=1` ولا يدخل في أمر المستخدم النهائي.
- [x] إضافة اختبارات rollback تحقن فشل download/auth/service/health وتثبت استعادة
  الحالة السابقة وعدم حذف Sanad Home.
- [x] تحديث دليل المستخدم وREADME وQA والإصدار، مع إبقاء نص الواجهة English.
- [x] إغلاق G4 بعد analyzer واختبارات Agent/Client المركزة وتحديث النسبة.

#### أدلة قبول G4

- [x] أمر POSIX المولد يستخدم `curl -fsSL ... | bash -s -- --pairing-token`
  المألوف مع quoting صحيح؛ المثبّت وحده يحول pairing authority إلى stdin عند
  استدعاء Agent، والرابط بقي `https://sanad.eaststarai.com/install.sh`.
- [x] يظل backup الخاص بالوحدة مفتوحاً حتى يفيد Local Gateway بالنسخة المتوقعة
  وبـ`cloud_registered=true` بعد `register_success` عند التثبيت المتصل.
- [x] نجحت اختبارات auth/service/health/installer/CLI guard المركزة واختبار Widget،
  ونجح `sh -n scripts/install.sh` وAgent/Client analyzers المركزان.
- [x] انتقلت المهمة إلى G5 بنسبة متبقية 35% دون runtime switch أو runtime stop أو
  commit أو push.

### G5 — التحقق المحلي الكامل — مكتملة

- [x] في `agent/`: نجح `fvm dart analyze` بمخرجات محدودة مع حفظ exit status.
- [x] نجحت اختبارات auth/secret-store/service/CLI/installer المركزة (`38 passed`
  في التجميع النهائي، إضافة إلى مصفوفات G2 المركزة السابقة).
- [x] نجح full fast Agent suite (`1215 passed, 12 skipped`).
- [x] في `client/`: نجح `fvm flutter analyze` واختبار Widget (`3 passed`).
- [x] نجح `sh -n scripts/install.sh` واختبارات shell/guard الجديدة.
- [x] نجحت اختبارات fail injection وثبت غياب pairing token من Agent arguments
  ومن fake command logs والfixtures المتعقبة.
- [x] بُني Linux x64 candidate داخل Docker `linux/amd64` باستخدام FVM 3.47.0:
  `agent/build/sanad-linux-x64` (ignored build output).
- [x] تحقق ELF x86-64 وsmoke من مجلد بلا `pubspec.yaml`: Agent `1.0.6` على
  Linux؛ المرشح الحالي حجمه `14687264` bytes وSHA-256
  `9280bf3d6d466092dd413f8334933d6e280e2769dbb1c439803ec13cd31344c1`.
- [x] شُغل `graphify update .` ونجح `git diff --check`.
- [x] لم تبدأ تجربة السيرفر قبل نجاح كل تحقق محلي مطلوب.

#### أدلة قبول G5

- [x] Docker builder دائم باسم `sanad-task81-linux-builder` مع volume منفصل
  لـFVM وPUB cache؛ إعادة البناء الثانية استخدمت cache ولم تعد تنزيل Flutter.
- [x] يبني الـbuilder من نسخة مؤقتة داخل الحاوية كي لا يعيد كتابة
  `agent/.dart_tool/package_config.json` بمسارات Linux.
- [x] انتقلت المهمة إلى G6 بنسبة متبقية تقريبية 30% دون commit أو push أو PR.

### G6 — دورة الإصلاح على السيرفر التجريبي الحالي

- [x] استخدام الآلة التجريبية الحالية بعد فحص read-only لحالتها.
- [x] بيانات الآلة تجريبية؛ مُسحت Sanad Home والوحدات والبواقي والحزم
  التجريبية للبدء من baseline نظيف، مع عدم تسجيل project id أو IP أو tokens في
  المستودع.
- [x] إزالة D-Bus/keyring workarounds والملفات المؤقتة والوحدات والبواقي التي
  أنشأتها التجربة السابقة حتى يكون الاختبار Headless حقيقياً.
- [x] رفع Linux candidate وcandidate installer/harness المتحققين إلى السيرفر.
- [x] طلب Add Device command جديد من المالك عند نقطة pairing فقط؛ لا ينسخ
  المنفذ التوكن إلى ملف المهمة أو التقرير أو logs.
- [x] تنفيذ أمر واحد يختبر الاكتشاف التلقائي، file credential backend، الخدمة،
  health، pairing، وOnline.
- [x] التحقق من `service status` وbackend/scope دون كشف أسرار.
- [x] إغلاق SSH والتأكد من بقاء الجهاز Online.
- [x] إعادة تشغيل السيرفر ثم استخدام polling محدود بختم زمني وbreak عند الحالة
  النهائية لإثبات العودة Online دون تدخل.
- [x] تنفيذ طلب Agent حقيقي من Client قبل وبعد reboot.
- [x] اختبار logout/uninstall/reinstall/upgrade والrollback المحقون.
- [x] قياس RAM/disk/startup على `e2-micro`: قرابة 15 MB RSS و15 MB Sanad Home،
  وعودة الخدمة بعد reboot دون restarts أو warning/error journal entries.

#### نتيجة G6 ونقطة الاستئناف الآمنة

- المرشح `1.0.6` مثبت كـ`systemd-system` تحت مستخدم غير root، ومخزن الاعتماد
  `linux_owner_file`، والخدمة Running/Enabled بعد reboot وhealth يفيد
  `cloud_registered=true`.
- نجح طلب Client حقيقي قبل reboot وبعده، ثم نجح طلب آخر بعد clean
  logout/uninstall/reinstall وعودة الجهاز Online.
- نجحت إعادة التثبيت/الترقية مع استعادة الاتصال السابق وفحص cloud health، ونجح
  rollback محقون بعد استبدال الباينري مع استعادة digest والخدمة والاعتماد وعدم
  بقاء ملف `.rollback`.
- أصلحت حلقة G6 خطأ اقتباس `WorkingDirectory` في systemd، وتنظيف enable symlink
  عند activation failure، وcompile-time version/smoke من خارج source tree.
- أُصلح cache القدرات الذي كان يخزن ردًا correlated بقيمة `null` كقدرات فارغة
  fresh؛ أثبت التحقق الحي بعد hot reload وانتقال Offline→Online أن Client أعاد
  `get_capabilities` للجهاز الصحيح واستلم model/thinking capabilities وظهرت
  القائمتان دون Client restart.
- أُغلقت G6 وانتقلت المهمة إلى G7 بنسبة متبقية تقريبية 15%.

#### حلقة الفشل الإلزامية

إذا فشل أي تحقق في G6:

1. التوقف عن إضافة workaround يدوي على السيرفر؛
2. جمع أقل log bounded يحدد أول invariant مكسور دون أسرار؛
3. إصلاح السبب في worktree محلياً؛
4. إضافة regression test أو fail-injection يغطيه؛
5. تشغيل analyzer والاختبارات المركزة محلياً؛
6. إعادة بناء Linux candidate؛
7. رفعه وتثبيته وإعادة نفس السيناريو على السيرفر؛
8. تكرار الدورة حتى نجاح السيناريو كاملاً.

لا تُغلق G6 من نجاح pairing لحظي؛ يلزم Online مستمر وreboot وطلب حقيقي.

### G7 — الاختبار النهائي على سيرفر جديد تماماً قبل PR

- [x] بعد نجاح G6، مراجعة diff والاختبارات أولاً.
- [x] حذف/إيقاف موارد الاختبار القديمة قبل إنشاء مورد ثانٍ إذا كان التداخل قد
  يتجاوز الاستخدام المجاني؛ لا تنشئ موردين دائمين متزامنين بلا حاجة.
- [x] إنشاء Ubuntu Linux x64 نظيف بالمواصفات الدنيا المستهدفة، مع automatic
  restart الافتراضي ودون `--no-restart-on-failure`.
- [x] لا تثبيت يدوي لـSecret Service أو D-Bus أو keyring أو linger أو وحدة Sanad
  قبل الاختبار.
- [x] تثبيت المرشح غير المنشور عبر candidate harness الآمن في أمر واحد مكافئ
  لمسار المستخدم النهائي.
- [x] استخدام pairing token جديد لمرة واحدة.
- [x] إثبات clean install، backend/service auto-detection، Online، طلب حقيقي،
  إغلاق SSH، reboot، وعودة Online.
- [x] إثبات عدم وجود secret في `auth.json` أو logs أو retained temp files.
- [x] إثبات uninstall ثم clean reinstall على نفس السيرفر.
- [x] حفظ دليل sanitized يحتوي الوقت، نسخة المرشح، digest، نظام التشغيل، شكل
  الآلة، والنتائج فقط؛ دون IP أو token أو credential أو محتوى مستخدم.
- [x] لا يبدأ PR ما لم تنجح هذه البوابة كاملة.

#### دليل G7 المنقح

- **الوقت:** 2026-08-29 UTC.
- **المرشح:** Sanad Agent `1.0.6`، Linux x64، الحجم `14687264` bytes، SHA-256
  `9280bf3d6d466092dd413f8334933d6e280e2769dbb1c439803ec13cd31344c1`.
- **المضيف:** Ubuntu 22.04.5 LTS x86_64، `e2-micro`، قرص 30 GB، وautomatic
  restart مفعّل.
- **baseline:** لا Sanad Home أو وحدة Sanad أو Secret Service أو keyring أو
  linger مسبق؛ systemd وsudo فقط من صورة النظام النظيفة.
- **النتيجة:** اختار المثبّت `linux_owner_file` و`systemd-user` تلقائياً، فعّل
  linger، وحافظ على `0700/0600`. نجح Online وطلب Client حقيقي وظهرت model/
  thinking controls دون restart.
- **الاستمرارية:** عاد الجهاز Online والخدمة Enabled/Running بعد reboot فعلي
  موثّق بتغير وقت الإقلاع، مع `NRestarts=0`، ثم نجح طلب Client آخر.
- **النظافة:** لا أسرار في `auth.json` أو process arguments أو journal، ولا
  retained installer temp files. نجح logout/uninstall وحذف الوحدة، ثم clean
  reinstall من baseline بلا Sanad Home وعاد Online مع الضوابط.
- **الخصوصية:** لا يتضمن الدليل IP أو project id أو token أو credential أو device
  identifiers أو محتوى مستخدم.

### G8 — مراجعة وتسليم Pull Request

- [x] تحديث المهمة والوثائق بنسبة المتبقي ونتائج البوابات.
- [x] مراجعة كل diff مقابل العقود وحدود الأمان وعدم وجود reference-specific
  details في الوثائق المتعقبة.
- [x] تشغيل analyzer والاختبارات المطلوبة وGraphify وdiff check نهائياً: Agent
  `1216 passed, 12 skipped` وClient `1103 passed, 1 skipped` مع نجاح analyzer.
- [x] استلام موافقة صريحة من المالك على commit وpush وPR بعد نجاح G7.
- [x] بعد الموافقة: أُنشئ commit داخل worktree ودُفع الفرع وأُنشئ PR #120 بشرح
  المشكلة والتصميم والاختبارات المحلية والسيرفرية والـclean-host evidence.
- [ ] لا merge تلقائي ولا تنظيف worktree قبل مراجعة المالك ونجاح CI.

### G9 — الإصدار والتحقق من Production

هذه البوابة تأتي بعد merge، وليست جزءاً من صلاحية إنشاء PR:

- [ ] اختيار رقم الإصدار وتحديث release metadata وفق عقد الإصدار.
- [ ] بناء والتحقق من Linux Agent artifact والmanifest والحجم وSHA-256
  والprovenance عبر workflow الرسمي.
- [ ] طلب موافقة مستقلة قبل نشر RC أوStable.
- [ ] بعد النشر، التحقق أن
  `https://downloads.sanad.eaststarai.com/install.sh` يطابق المصدر المنشور وأن
  `https://sanad.eaststarai.com/install.sh` يصل إليه بنجاح.
- [ ] تنظيف حالة Sanad على آلة اختبار مناسبة ثم تشغيل **أمر Add Device الفعلي
  من Production** دون candidate hook.
- [ ] إثبات Online وطلب حقيقي وreboot/reconnect على artifact المنشور.
- [ ] عند فشل artifact المنشور، لا ترقيع حي؛ إصلاح جديد عبر worktree وPR وإصدار
  تصحيحي.
- [ ] تحديث المهمة إلى 0% فقط بعد نجاح artifact المنشور والتحقق النهائي.

## معايير القبول

- [x] نفس أمر Add Device يعمل على Linux Desktop وUbuntu/Debian Headless دون
  flags خاصة بالخادم.
- [x] Secret Service يُستخدم تلقائياً عندما يكون صالحاً، وإلا يعمل owner-file
  backend تلقائياً مع warning فقط.
- [x] لا يوجد Device Credential أو private key أو pending credential داخل
  `auth.json`.
- [x] الخدمة المناسبة تُختار تلقائياً وتبقى بعد logout وreboot دون تشغيل Agent
  كـroot.
- [x] systemd user وsystemd system وOpenRC تملك اختبارات واضحة، ولا يُدعى دعم
  بيئة لم تُختبر.
- [x] `curl -f` يعرض فشل bootstrap HTTP بوضوح، وكل فشل manifest/artifact داخل
  المثبّت يخرج non-zero دون mutation أو نجاح مضلل.
- [x] لا يعلن المثبّت النجاح قبل health وpairing وGateway/Online verification.
- [x] rollback يعيد الباينري والوحدة والحالة السابقة ولا يترك unit بلا باينري.
- [x] `daemon --help` و`service --help` لا يشغلان daemon ولا يحجزان منفذاً.
- [x] status يعرض حالة typed مفيدة ولا يطبع فراغاً أو أسراراً.
- [x] السيناريو الكامل ينجح على السيرفر التجريبي ثم على سيرفر جديد تماماً قبل
  PR.
- [ ] artifact المنشور ينجح لاحقاً عبر رابط Production الفعلي.

## تعريف الإنجاز

- [x] كل بوابات G1–G7 ناجحة قبل PR.
- [x] الكود والاختبارات والوثائق والعقود متسقة، ولا تبقى عبارات Task 68 القديمة
  التي تصف Headless cloud بأنه مؤجل بعد أن يصبح مدعوماً فعلياً.
- [x] Agent وClient analyzers والاختبارات المركزة وfull fast suites تمر.
- [x] Linux x64 candidate وclean-server reboot evidence ناجحان.
- [x] لا أسرار أو معرفات بنية خاصة في المستودع أو تقارير التسليم.
- [x] commit/push/PR تم فقط بعد موافقة المالك.
- [ ] الإصدار نُشر فقط بعد merge وموافقة إصدار مستقلة.
- [ ] Production Add Device command نجح على artifact المنشور.
