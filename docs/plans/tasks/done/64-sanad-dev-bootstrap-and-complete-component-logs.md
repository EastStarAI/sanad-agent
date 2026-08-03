---
title: "Task 64: sanad-dev Bootstrap and Complete Component Logs"
description: "تهيئة تطوير متعددة المنصات من أمر واحد، وتثبيت sanad-dev للمستخدم، والتقاط stdout/stderr الكامل للـAgent وكل Client مع توزيع صحيح للطرفيات."
status: "completed"
current_gate: "Complete — implementation, automated verification, and live smoke finished"
priority: "high"
depends_on: "Task 63 component runtime controls and managed launcher ownership"
file_budget: 30
design_contract: "docs/technical/sanad_dev_runtime_ownership.md"
qa_contract: "docs/qa_maintenance/sanad_dev_runtime_ownership_qa.md"
---

# Task 64: sanad-dev Bootstrap and Complete Component Logs

## 1. الهدف

جعل أول تجربة للمطور تبدأ من أمر واحد في جذر المستودع:

```bash
scripts/sanad-dev
```

يتحقق bootstrap من المتطلبات، يثبت FVM وFlutter SDK المثبتة للمشروع عند الحاجة،
يحل اعتماديات Agent وClient، يثبت shim باسم `sanad-dev` للمستخدم، ثم يبدأ runtime
مدارة. بعد ذلك يستطيع المطور استخدام `sanad-dev` من الطرفيات الجديدة.

وفي التشغيل، يجب أن تلتقط launcher المخرجات الحقيقية لكل process، بما يشمل
`stdout` و`stderr` و`print` وstack traces وأخطاء Flutter build/runtime، لا سجلات
`package:logging` فقط. تعرض الطرفية الحالية Agent، وتفتح نافذة مستقلة لكل Client.

## 2. نتائج التدقيق الحالية

- `scripts/sanad-dev` هو Bash wrapper يستدعي `fvm dart`؛ لذلك لا يستطيع Dart CLI
  الحالية تثبيت FVM عند غيابها.
- لا يوجد entry point مكافئ معتمد لـPowerShell.
- Client history يأتي من `clientLogs` التي يملؤها `Logger.root` فقط. وضع follow
  يرى VM stdout/stderr بعد الاشتراك، لكنه لا يعيد المخرجات السابقة ولا Flutter
  tool/native build output.
- Agent `/logs` وWebSocket يعرضان `agentLogs` التي يملؤها `Logger.root` فقط؛
  `print` وstderr والأخطاء غير المعالجة خارج هذا المسار لا تظهر.
- `run all` الحالي يعطي Flutter الطرفية الحالية ويفتح Agent log sidecar؛ المطلوب
  هو العكس.

## 3. القرارات المعمارية المقترحة للمراجعة

### 3.1 فصل Bootstrap عن Runtime CLI

- يبقى `scripts/sanad_dev.dart` هو Runtime CLI المشتركة بعد جاهزية FVM.
- `scripts/sanad-dev` يملك bootstrap على macOS/Linux.
- يضاف entry point لـWindows PowerShell مع shim مناسب لاستدعاء `sanad-dev`.
- غياب arguments يعني `setup` ثم `run all`. يبقى `sanad-dev run` متوافقًا.
- يضاف `sanad-dev setup` و`sanad-dev setup --force` لإصلاح البيئة دون تشغيل.

### 3.2 سياسة التثبيت

- لا `sudo` ولا تعديل system-wide افتراضيًا.
- تثبيت FVM يكون user-scoped ومن مصدر رسمي مثبت، مع version/checksum verification
  عندما يكون التنزيل binary مباشرًا.
- تثبيت Flutter يتم عبر `fvm install` وفق نسخة المستودع المثبتة.
- dependency setup يشغل `fvm dart pub get` للـAgent و`fvm flutter pub get`
  للـClient.
- كل مرحلة idempotent. stamp محلية تربط النتيجة بنسخة Flutter وملفي
  `pubspec.lock` ووجود package configs، ولا يعاد العمل المكلف بلا تغيير.
- أي تنزيل أو تعديل PATH يفشل برسالة واضحة ولا يبدأ runtime ناقصة.

### 3.3 PATH وملكية checkout

- POSIX shim يكون user-scoped، وWindows shim يضاف إلى User PATH.
- bootstrap لا يستبدل shim تشير إلى checkout أخرى بصمت؛ يعرض المصدر ويطلب قرارًا
  صريحًا أو `--force`.
- الاستدعاء داخل Git worktree يحافظ على caller-worktree discovery الحالية.
- الاستدعاء خارج Git يعود إلى checkout المالكة للـshim.
- تعديل PATH يؤثر في الطرفيات الجديدة؛ لا تدّعي الأداة أنها عدلت environment
  الخاصة بالـshell الأب، وتطبع خطوة refresh عند الحاجة.

### 3.4 سجل process موحد

- launcher تلتقط stdout/stderr من Agent ومن كل Flutter process منذ spawn وحتى
  الخروج، بما في ذلك build output قبل ظهور VM service.
- لكل مكوّن bounded journal منفصلة تحت runtime Home، بصلاحيات user-only، وهوية
  مرتبطة بالlauncher nonce والمكوّن/device/VM port.
- ملفات السجل ليست دليل liveness أو ownership؛ تبقى lease وprocess identity
  والhealth/VM discovery هي السلطة الوحيدة.
- managed `logs` يقرأ journal الحقيقية ويستخدمها لكل من history وfollow دون دمج
  endpoint ثانية تسبب duplication.
- manual runtimes تحتفظ بالـHTTP/VM-service paths الحالية كـfallback موضح.
- rotation وحدود الحجم/الأسطر تمنع نموًا غير محدود، مع cleanup عند تقادم runtime.
- لا تسجل الأداة environment أو secrets، وتحتفظ بسياسة truncation/redaction
  الحالية للمحتوى المعروف الحساس.

### 3.5 ملكية الطرفيات

| الأمر | الطرفية الحالية | نافذة إضافية |
|---|---|---|
| `run agent` | Agent stdout/stderr | لا شيء |
| `run client -d <id>` | Client stdout/stderr | لا شيء |
| `run all -d <id>` | Agent stdout/stderr | Client المحددة |
| إضافة Client إلى runtime قائمة | launcher الحالية تبقى للـAgent | نافذة Client جديدة |

- نافذة Client تنفذ surface قراءة تابعة للlauncher، ولا تملك Flutter process.
- كل Client إضافية لها watcher مستقلة تغلق عند خروجها.
- macOS وLinux وWindows تستخدم terminal adapters منفصلة.
- في CI/headless أو عند فشل terminal adapter، لا يفشل التشغيل؛ يطبع أمر logs
  محدودًا وقابلًا للنسخ.
- hot reload/restart/inspect تبقى عبر أوامر `sanad-dev` ولا تعتمد على stdin
  الأصلية لـFlutter.

### 3.6 سياسة الخدمات المستضافة لتطوير المصدر

اعتمد المالك قبل النشر العام أن مطور أومساهم `sanad-agent` هو مستخدم عادي
للخدمة المستضافة، وليس مطورًا ضمن مشروع Backend/Portal الخاص. لذلك تكون
السياسة الملزمة عند تنفيذ هذه المهمة:

- يشغّل `sanad-dev` الاتصال المحلي وCloud معًا افتراضيًا في primary checkout
  وكل clone مستقل وكل linked worktree دون استثناء.
- يستخدم التشغيل الافتراضي للمصدر خدمات Production العامة نفسها التي تستخدمها
  الإصدارات الرسمية:
  `https://api.sanad.eaststarai.com` و
  `https://portal.sanad.eaststarai.com`.
- يصبح `client/config/prod.json` profile الافتراضية للlauncher وVS Code
  والتشغيل اليدوي الموثق. لا يحمل مصطلح "development" معنى اختيار Backend
  تجريبي؛ هو وصف لبناء المصدر فقط.
- تبقى `client/config/dev.json` وprocess-level endpoint overrides اختيارًا
  صريحًا لتطوير Backend/Portal أوتكامل داخلي مصرح به، ولا تظهر بوصفها مسار
  المساهم الخارجي أوالقيمة الافتراضية لأي أمر عام.
- يبقى `--no-cloud` المسار الصريح للتطوير المحلي فقط، مع اتصال Client مباشر
  بالـAgent المحلي دون Portal أوGateway مستضافين.
- لا تتصل unit أوwidget أوintegration أوE2E أوCI العادية بـProduction. تستخدم
  mocks/fixtures أوالمسار المحلي مع Cloud معطلًا. أي production cloud smoke
  يكون يدويًا وصريحًا ومحدودًا وغير هدّام، ولا يصبح required check على PR.
- لا تمنح شفرة المصدر أوprofile الإنتاج أي ثقة إضافية. يتعامل Backend مع كل
  Client/Agent، بما في ذلك builds معدلة من forks، كطرف غير موثوق، ويطبق
  المصادقة والتفويض وعزل المستخدم والتحقق من payload والحدود التشغيلية
  server-side.
- عزل Sanad Home في worktrees يبقى كما هو؛ تفعيل Cloud افتراضيًا لا يسمح
  بمشاركة credentials أوهوية أوحالة قابلة للكتابة بين worktrees.

## 4. النطاق غير المشمول

- كود Agent وClient الإنتاجي خارج نطاق هذه المهمة. تلتقط launcher مخرجاتهما عند
  مستوى process دون تعديل logger أو bootstrap أو runtime داخل التطبيقين. أي
  حاجة مكتشفة لتعديل production code تحت `agent/lib/` أو `client/lib/` توقف
  التنفيذ وتتطلب مراجعة نطاق وموافقة صريحة جديدة.
- يسمح بإضافة fixtures أو اختبارات تكامل تحت `agent/test/` أو `agent/e2e_test/`
  أو `client/test/` فقط لإثبات سلوك `sanad-dev`، ولا يجعل ذلك التطبيقين مالكي
  bootstrap أو component journals.
- لا تغيير في عقد pause/cancel أو recovery الخاص بـTask 63.
- لا استخدام للسجلات كدليل ownership أو process discovery.
- لا تثبيت provider credentials أو تسجيل دخول تلقائي.
- لا دعم package managers غير موثقة أو طلب صلاحيات administrator تلقائيًا.
- خلل `switch` الذي يعيد فشلًا مبكرًا ثم يكمل الانتقال يسجل ويصلح في مسار
  ownership/switch مستقل، ولا يخفى بتغيير logging.

## Gate A — Bootstrap contract and safe platform policy

- [x] اعتماد سياسة بيئة المساهمين: Production+Cloud افتراضيًا لكل checkout
  وclone وworktree، وDev اختيار داخلي صريح، والاختبارات الآلية بلا Production.
- [x] تثبيت contract للأوامر: no-args و`setup` و`setup --force` و`run`.
- [x] اختيار وتوثيق مصدر تثبيت FVM لكل منصة والتحقق من النسخة/checksum.
- [x] تعريف typed setup stages ونتائج success/skipped/failed.
- [x] تعريف PATH shim ownership، checkout replacement، وshell refresh behavior.
- [x] فصل platform/process/filesystem adapters حتى تكون الاختبارات hermetic.

### A Exit

- [x] لا يبدأ runtime قبل اكتمال كل المتطلبات.
- [x] لا يحتاج المسار الافتراضي sudo أو administrator.
- [x] قرار Windows قابل للتنفيذ في CI وليس وصفًا نظريًا فقط.

## Gate B — Idempotent cross-platform setup

- [x] جعل `client/config/prod.json` config الافتراضية في Runtime CLI ونص المساعدة
  وVS Code launch، مع استمرار Cloud افتراضيًا لكل primary/clone/worktree.
- [x] إبقاء `--config config/dev.json` أوendpoint overrides مسارًا صريحًا
  فقط، دون توجيه المساهم العام إليه في Quick Start.
- [x] إضافة اختبارات hermetic تثبت اختيار Production افتراضيًا، واحترام
  `--no-cloud` والـconfig override، وعدم إجراء أي اتصال شبكي حقيقي.
- [x] تنفيذ POSIX bootstrap لـmacOS/Linux.
- [x] تنفيذ PowerShell bootstrap وshim لـWindows.
- [x] تثبيت/اكتشاف FVM ثم Flutter SDK المثبتة للمستودع.
- [x] dependency setup مستقل للـAgent والـClient.
- [x] stamp invalidation عند تغير Flutter pin أو `pubspec.lock`.
- [x] progress output نظيف وواضح، مع `--verbose` للتفاصيل الكاملة عند الفشل.
- [x] no-args يكمل إلى `run all`، و`setup` يتوقف بعد التجهيز.

### B Exit

- [x] fresh-home test يثبت ترتيب المراحل كاملًا.
- [x] second-run test يثبت skip للمراحل السليمة.
- [x] failure في أي مرحلة يمنع المراحل التابعة وبدء runtime.
- [x] PATH collision لا يستبدل checkout أخرى بلا `--force`.

## Gate C — Complete component process journals

- [x] إضافة bounded journal abstraction مشتركة للـAgent والClients.
- [x] التقاط stdout/stderr منذ `Process.start` دون فقد boot/build output.
- [x] تمييز source stream والمكوّن دون كسر النص والـANSI الضروريين.
- [x] rotation وpermissions وcleanup محدودة ومختبرة.
- [x] `logs -n` يعيد آخر N أسطر من السجل الكامل.
- [x] `logs -f` يعيد التاريخ المحدود ثم live bytes بلا gap أو duplication.
- [x] restart وsource switch يحتفظان بسطح logs مستمر مع حدود واضحة بين الأجيال.
- [x] manual-runtime fallback لا يدعي اكتمال process logs غير المتاحة.

### C Exit

- [x] Client test يثبت ظهور logger و`print` وstderr وuncaught stack وFlutter build
  output في الترتيب نفسه.
- [x] Agent test يثبت ظهور logger و`print` وstderr وuncaught stack في التاريخ
  والبث الحي.
- [x] crash قبل health/VM readiness يبقى ظاهرًا بعد خروج process.

## Gate D — Terminal ownership and platform adapters

- [x] طباعة Agent output في الطرفية الحالية عند `run all`.
- [x] فتح watcher منفصلة لكل Client دون نقل ownership خارج launcher.
- [x] إضافة client `--wait` حتى تبدأ نافذة logs قبل VM readiness.
- [x] macOS adapter لا يعتمد إلا على terminal capability المعلنة.
- [x] Linux adapter يختار terminal مدعومة أو يفشل إلى fallback بلا mutation.
- [x] Windows adapter يستخدم PowerShell/Windows Terminal مع quoting آمن.
- [x] headless/CI لا يفتح GUI ولا يترك reconnect loop دائمة.

### D Exit

- [x] `run all` يثبت Agent-current وClient-sidecar على المنصات المدعومة.
- [x] Client ثانية تفتح watcher ثانية ولا تؤثر في الأولى أو Agent.
- [x] إغلاق Client يغلق watcher التابعة فقط.
- [x] فشل فتح terminal لا يغير process ownership أو نجاح runtime.

## Gate E — Integration, documentation, and release confidence

- [x] تحديث README الإنجليزية والعربية ودليل المطور وعقود runtime/hosted
  services لتوضيح أن مطور المصدر يستخدم Production كـuser عادي، وأن Dev
  مملوكة لتكامل Backend/Portal الداخلي فقط.
- [x] فحص المستودع العام لمنع أي Quick Start أوVS Code profile أوsanad-dev help
  من تقديم Dev بوصفها الوجهة الافتراضية للمساهم.
- [x] إثبات أن CI والاختبارات العادية تعمل مع Cloud معطلًا ولا ترسل traffic أو
  credentials أوبيانات fixtures إلى Production.
- [x] تشغيل analyzers والاختبارات المركزة ثم fast suites حسب blast radius.
- [x] إضافة matrix على macOS وLinux وWindows للbootstrap والquoting وPATH.
- [x] daemon/client-backed smoke: نفّذ المستخدم lifecycle stop/start بنفسه ثم
  شغّل `sanad-dev run --config config/dev.json`؛ أثبتت status والقراءات المحدودة
  Agent/Client journals وFlutter build output قبل VM readiness دون fallback.
- [x] تحديث `README.md` و`README.ar.md` إلى Quick Start مختصر من أمر واحد.
- [x] تحديث `docs/operations/developer_guide.md` بوصفه المرجع الأساسي.
- [x] تحديث design وQA contracts للسجل والterminal/bootstrap boundaries.
- [x] تحديث أقرب `AGENTS.md` فقط إذا تغير durable law فعليًا.
- [x] تشغيل `graphify update .` بعد تغييرات الكود.

### E Exit / Definition of Done

- [x] checkout جديدة قابلة للتجهيز والتشغيل من أمر واحد على المنصات الثلاث.
- [x] التشغيل الافتراضي في كل checkout/clone/worktree يفعّل Local+Cloud ويختار
  Production، بينما `--no-cloud` يمنع الاتصال المستضاف وDev لا تُختار ضمنيًا.
- [x] لا يتصل أي اختبار آلي أوrequired CI check بـProduction.
- [x] إعادة الأمر آمنة وسريعة ولا تعيد العمل غير اللازم.
- [x] `sanad-dev` متاح من طرفية جديدة دون صلاحيات مرتفعة.
- [x] Agent وClient logs تعرض process stdout/stderr كاملة تاريخيًا وحيًا.
- [x] الطرفية الحالية للـAgent، وكل Client لها sidecar مستقلة عند `run all`.
- [x] ownership والعزل وcomponent stop وrestart/reload/source switch لم تنتكس.
- [x] لا production diff تحت `agent/lib/` أو `client/lib/`؛ أي ضرورة لذلك أعادت
  المهمة إلى review قبل التنفيذ.
- [x] التنفيذ داخل file budget أو يراجع النطاق قبل تجاوزه.

## 5. الملفات المتوقعة

### Bootstrap وCLI

- `scripts/sanad-dev`
- PowerShell/shim entry points جديدة تحت `scripts/`
- `scripts/sanad_dev.dart`
- `scripts/sanad_dev/cli.dart`
- `scripts/sanad_dev/command_options.dart` إذا امتلك الثابت typed الافتراضي.
- `.vscode/launch.json`
- `client/config/prod.json` و`client/config/dev.json` بوصفهما environment profiles
  متتبعة؛ تبقى defaults مملوكة لـ`PublicServiceEndpoints` وتهيئة Agent الحالية،
  ولا تضيف المهمة نسخة جديدة من endpoint literals.
- bootstrap/platform/PATH helpers مركزة جديدة تحت `scripts/sanad_dev/`

### Runtime logs والطرفيات

- `scripts/sanad_dev/runtime_commands.dart`
- `scripts/sanad_dev/runtime_component_control.dart`
- `scripts/sanad_dev/developer_actions.dart`
- `scripts/sanad_dev/terminal_launcher.dart`
- component journal model/store مركزة جديدة تحت `scripts/sanad_dev/`
- لا production changes تحت `agent/lib/` أو `client/lib/`. تبقى app logger
  endpoints الحالية fallback للـmanual runtimes دون توسيعها في هذه المهمة.

### الاختبارات والتوثيق

- اختبارات bootstrap وPATH وplatform quoting تحت `client/test/unit/scripts/`
- اختبارات config/Cloud defaults وoverride بلا network حقيقية تحت
  `client/test/unit/scripts/`.
- اختبارات process journal وterminal lifecycle تحت `client/test/unit/scripts/`
- daemon/client-backed E2E محدود للمخرجات الحقيقية.
- `README.md`
- `README.ar.md`
- `docs/operations/developer_guide.md`
- `docs/technical/hosted_services_boundary.md`
- `docs/technical/sanad_dev_runtime_ownership.md`
- `docs/qa_maintenance/sanad_dev_runtime_ownership_qa.md`
- `AGENTS.md` و`client/lib/core/AGENTS.md` و`scripts/sanad_dev/AGENTS.md` فقط
  لتثبيت القوانين الدائمة المتغيرة.
- `.agents/skills/sanad-client-tester/SKILL.md` لتحديث SOP التشغيل والتحقق.

## 6. سيناريو النجاح

```text
fresh checkout
  scripts/sanad-dev
    [only missing work is shown]
    Installing verified FVM... ready
    Installing pinned Flutter SDK... ready
    Resolving Agent dependencies... ready
    Resolving Client dependencies... ready
    Installing sanad-dev command... ready
    Starting Agent...
    Building Client...

current terminal
  Agent logger output
  Agent print output
  Agent stderr and uncaught stack traces

Client sidecar
  Flutter build output
  Client logger/debugPrint output
  Client print output
  Client stderr and uncaught stack traces

new terminal
  sanad-dev status
  sanad-dev logs agent -n 50
  sanad-dev logs client -n 50
```

## 7. خطة التنفيذ الموصى بها

1. اعتماد Gate A قبل كتابة الكود، خصوصًا مصدر FVM وPATH policy.
2. تنفيذ A+B في worktree مستقلة مع mocks كاملة وعدم تعديل PATH الحقيقي أثناء
   الاختبارات.
3. تنفيذ C+D في worktree مستقلة بعد ثبات bootstrap contract.
4. دمج المسارين في Gate E وتشغيل smoke حي على macOS، مع Windows/Linux CI إلزامي.

اعتمد المالك الخطة وسياسة Production+Cloud، ونُفذت Gates داخل الـworktree الحالية
وفق طلبه دون commit أوpush أوsource switch أوstop.

## 8. Implementation evidence

- بقيت تغييرات production تحت `agent/lib/` و`client/lib/` عند صفر ملف.
- غطت الاختبارات hermetic: fresh/second/failure/collision bootstrap، typed stages،
  Production/Dev endpoint resolution بلا network، process crash history،
  stdout/stderr ordering، tail/follow cursors، rotation/redaction، terminal
  quoting وheadless fallback.
- تضيف Public CI matrix مستقلة على macOS وLinux وWindows لهذه الأسطح، ولا تبدأ
  runtime متصلة أوتجري Production smoke.
- نجح analyzer وكل `client/test/unit/scripts/`، ونجح فحص التوثيق والفهرسة.
  مرّ 863 اختبارًا من full Client fast suite؛ فشل guard واحد فقط لأن checkout
  المحلية تحتوي الملف ignored السابق `client/android/key.properties`. لم تلمس
  المهمة ملف التوقيع المحلي أوتحذفه.
- نفّذ المستخدم stop/start للـruntime بنفسه واختار Dev override لأن Production
  لم تُرفع بعد. بعد الإقلاع أثبتت `status` managed ownership، وأعادت القراءات
  المحدودة Agent journal وClient journal بما فيها `Launching` و`Building macOS`
  و`Syncing files` وDart VM Service دون هبوط إلى manual fallback.
- تحقق regression حي في 2026-08-03 من أن Flutter 3.41.9 الجاهزة لا تطبع
  `Installing Flutter 3.41.9`، وأن wrapper أجنبية تعيد التوجيه إلى worktree
  المستدعية، وأن `run client` يبدأ بآخر 50 سطرًا بدل إعادة كل journal المحتفظة.
