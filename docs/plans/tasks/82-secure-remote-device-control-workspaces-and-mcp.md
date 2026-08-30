# المهمة 82 — التحكم الآمن بالجهاز البعيد واستعادة Workspaces وMCP

## الحالة

- **الحالة:** G0–G9 مغلقة. التنفيذ والمراجعة والتحقق الحي مكتملة، وصرّح المالك
  بتجهيز PR وإضافة التصنيفات المطلوبة ودمجه بعد نجاح GitHub Actions.
- **الفرع:** `feat/task-82-remote-device-control`.
- **البوابة الحالية:** مكتملة؛ التسليم عبر PR مفوض صراحةً.
- **نسبة العمل المتبقي:** 0%.
- **حدود التسليم:** لا إصدار؛ commit/push/PR/protected labels/squash merge
  مفوضة صراحةً بعد مراجعة المالك.
- **سجل التقدم:**
  - G0 أُغلق. التحقق المركّز:
    `cd agent && fvm dart test test/interfaces/server_sanad_gateway_platform_security_test.dart`
    → workspace + MCP cloud rejection، و`list_workspaces` مسموح.
  - G1 أُغلق دون إضافة أي `supports_remote_*` إلى capabilities. كل جهاز
    Online يدعم الأوامر typed. التحقق المركّز:
    `cd agent && fvm dart test test/interfaces/runtime/device_command_admission_test.dart test/interfaces/server_sanad_gateway_platform_security_test.dart`
    → 24 tests passed؛
    `cd client && fvm flutter test test/unit/services/device_command_client_test.dart`
    → 2 tests passed.
  - G2 أُغلق. Check/apply/restart يعملان عبر `DeviceControlCommandHandler` و
    `AgentUpdateService`/`DaemonRestartCoordinator` دون مفاتيح capabilities.
    الأزرار تظهر لكل جهاز Online عبر `DeviceCommandClient`. التحقق المركّز:
    `cd agent && fvm dart test test/interfaces/platforms/sanad_gateway/handlers/device_control_command_handler_test.dart test/interfaces/server_sanad_gateway_platform_security_test.dart`
    → passed؛
    `cd client && fvm flutter test test/unit/services/device_control_client_test.dart`
    → 3 tests passed.
  - G3 أُغلق. managed root عبر `SanadHomeBootstrap`، إنشاء name-based تحت
    `SANAD_HOME/workspaces`، browse مقيّد، وpreview token للحذف/النقل.
    التحقق المركّز:
    `cd agent && fvm dart test test/interfaces/local_workspace_runtime_service_test.dart test/interfaces/platforms/sanad_gateway/handlers/workspace_command_handler_test.dart test/interfaces/server_sanad_gateway_platform_security_test.dart test/core/sanad_home/sanad_home_bootstrap_test.dart test/interfaces/runtime/device_command_admission_test.dart`
    → 73 tests passed؛
    `cd client && fvm flutter test test/unit/services/device_conversation_commands_test.dart test/widget/conversation_input_panel_rebuild_test.dart`
    → 60 tests passed.
  - G4 أُغلق. Cloud MCP يُقبل بدون session ما عدا `replace_mcp_config`.
    Save/delete/Advanced save/STDIO inspect/OAuth complete تحتاج revision
    fingerprint وتذكرة تأكيد. Nested `secrets` تُنقَّح في logs. لا مسار
    `/api/mcp`. التحقق المركّز:
    `cd agent && fvm dart test test/interfaces/server_sanad_gateway_platform_security_test.dart test/interfaces/platforms/sanad_gateway/handlers/workspace_command_handler_test.dart test/core/secrets_redactor_test.dart test/capabilities/mcp_configuration_test.dart test/capabilities/mcp_runtime_manager_test.dart`
    → 52 tests passed؛
    `cd agent && fvm dart test test/capabilities/mcp_oauth_service_test.dart test/interfaces/runtime/device_command_admission_test.dart`
    → 15 tests passed؛
    `cd client && fvm flutter test test/unit/services/mcp_runtime_client_test.dart test/unit/services/sanad_socket_service_test.dart`
    → 36 tests passed.
  - G5 أُغلق. Overview check/update/restart وworkspace create/browser من G2/G3؛
    MCP Settings تعطّل الإضافة على الجهاز Offline وتعيد snapshot عند فشل الحذف
    بدل تكرار العملية. التحقق المركّز:
    `cd client && fvm flutter test test/features/mcp/mcp_server_management_screen_test.dart test/features/mcp/mcp_server_form_test.dart test/unit/services/device_control_client_test.dart`
    → 14 tests passed.
  - G6 أُغلق. سجلات FINE تُنقَّح عبر `redactForLog`؛ canaries وfail-injection
    وE2E restart/reconnect مع بقاء workspace/MCP. التحقق المركّز:
    `cd agent && fvm dart analyze` → 0 errors (3 infos pre-existing)؛
    `cd client && fvm flutter analyze` → No issues found؛
    focused Agent auth/admission/restart/workspace/MCP/canary tests → passed؛
    `cd agent && fvm dart test` → 1283 passed, 12 skipped؛
    `cd client && fvm flutter test` → 1119 passed, 1 skipped؛
    `cd agent && fvm dart test e2e_test/remote_device_control_e2e_test.dart --concurrency=1`
    → 1 passed؛
    `git diff --check` → clean؛
    `graphify update .` → 20678 nodes / 27774 edges.
  - الأدلة: `docs/technical/remote_device_control_protocol.md` و
    `docs/technical/remote_device_control_threat_model.md` و
    `docs/qa_maintenance/remote_device_control_qa.md`.
  - ملاحظات المالك في G9 نُفذت: حصر `local-agent` كهوية
    inventory فقط، إزالة Browse folders من Workspace Overview،
    وإضافة `workspace.remove` كحذف metadata-only يُبقي المسار
    والملفات والمحادثات. Agent analyze وClient analyze مرّا،
    والاختبارات المركزة مرّت. كما نجح التحقق الحي لإعادة تشغيل الوكيل
    المحلي: قُبل الأمر بهوية الجهاز الفعلية، خرج الوكيل برمز `0`، أعاده
    المشرف، ثم اتصل العميل به مجددًا دون `wrong_device`.
    التحقق النهائي: Agent/Client analyzers نظيفان، E2E مرّ (1 test)،
    `git diff --check` نظيف، و`graphify update .` حدّث الرسم إلى
    20753 nodes / 27867 edges.
  - أضيف اختيار **Force restart** الصريح بين Cancel وRestart بلون خطر.
    المسار الآمن يظل الافتراضي، ولا يرسل Client `force=true` إلا من زر الخطر؛
    كلا المسارين يستخدمان المشرف و`DaemonRestartCoordinator`. اختبارات
    admission/handler/coordinator وClient/widget المركزة مرّت (Agent: 35،
    Client: 5)، ثم مرّ التحليل والحزمتان الكاملتان وE2E restart/reconnect.
  - تحقق G7 بعد المراجعة استخدم Linux candidate مبنيًا من cache المحفوظ لمهمة
    81 وثبّته مع rollback copy دون تغيير Sanad Home. نجحت update check وإعادة
    التشغيل الآمنة والقسرية من Client، وعاد الجهاز Online في الحالتين. حذف
    سجل Workspace أبقى المجلد، كما نجح HTTP MCP inspect/save/delete عبر
    preview/confirmation ثم أزيل الـfixture والملفات المؤقتة. أضيفت مفاتيح
    تفاعلية وصفية لبطاقة MCP وزر Remove، وحُدثت مهارة Client Tester بقاعدة
    فحص المصدر وإضافة المفتاح ثم hot reload عندما لا يجد driver عنصرًا متوقعًا.

## الهدف

تمكين مالك الحساب من إدارة جهاز Sanad بعيد بصورة عملية وآمنة من Client عبر
Sanad Gateway: فحص تحديث Agent البعيد وتطبيقه أو إعادة تشغيله restart آمنًا،
وإنشاء وإدارة مساحات عمل ضمن جذور محددة يملكها Agent، وإدارة إعدادات MCP
المنقحة دون كشف أسرار أو فتح تصفح عام لنظام الملفات أو تحويل واجهة الإعدادات
إلى قناة shell بعيدة.

## الدافع

أثبتت Task 81 أن Agent يمكن تثبيته وتشغيله بصورة دائمة على خادم Headless، لكن
ثلاث فجوات تمنع إدارته اليومية من Client:

1. زرا **Restart agent** وAgent update lifecycle يعملان حاليًا عبر Local Gateway؛
   لا يملك الجهاز البعيد أمرًا سحابيًا للفحص أو التحديث أو restart.
2. Agent البعيد لا يجري background update polling ولا يثبت إصدارًا جديدًا
   تلقائيًا؛ يلزم user-initiated check/apply موثق وقابل للrollback.
3. إنشاء Workspace وتصفح/تعديل مجلداتها موقوف عند cloud adapter بالخطأ المنظم
   `remote_workspace_management_disabled`، رغم بقاء المعالجات المشتركة.
4. إدارة MCP عن بُعد موقوفة بالخطأ المنظم
   `remote_mcp_management_disabled`، رغم أن الأدوات المعدة محليًا تعمل في
   المحادثات السحابية.

تحسينات المصادقة الأخيرة تفصل User credentials عن Device Credential وتربط Agent
بمفتاح P-256 وتمنع الأسرار من `auth.json`. هذه قاعدة ضرورية، لكنها لا تكفي وحدها
لإزالة الحراس: يجب أن تبقى صلاحيات المسارات والأسرار والتأكيدات والـrestart
مملوكة للـdaemon ومقيدة بالهدف والطلب.

## القرارات المثبتة

### 1. ملكية البروتوكول والتوجيه

- يستخدم Client `DeviceCommandClient` و`DeviceConnectionCoordinator` لكل العمليات؛
  لا تختار صفحات Settings أو Workspace أو MCP النقل مباشرة.
- كل طلب يحمل `device_id` مستهدفًا و`request_id` عشوائيًا، وكل نتيجة تعيد
  الارتباط نفسه.
- Sanad Gateway يثبت أن User يملك الجهاز قبل relay، والـAgent يقبل أوامر cloud
  فقط من اتصاله المسجل والمصادق. أي فجوة في hosted ownership توقف المهمة وتنتج
  handoff مستقلًا؛ لا تُعالج بثقة Client فقط.
- تبقى authority النهائية للـAgent: التحقق، preview، persistence، mutation،
  lifecycle، redaction، والنتيجة typed.
- لا تُزال قوائم الحظر دفعة واحدة. تُستبدل كل مجموعة بأمر typed ومسار admission
  واختبارات خاصة بها بعد اكتمال مالكها.

### 2. Remote Restart

- يضاف أمر canonical باسم مبدئي `device.runtime.restart` ونتيجة
  `device.runtime.restart.accepted` أو typed rejection.
- يعيد Agent acknowledgment إلى Client قبل بدء drain أو الخروج.
- يستخدم الأمر `DaemonRestartCoordinator` نفسه المستخدم في restart المحلي؛ لا
  ينشئ مسار kill/stop/start موازياً.
- واجهة المستخدم توفر safe restart فقط. `force` وقطع provider/tool النشط خارج
  النطاق ولا يظهران في Client.
- إذا لم يكن Agent تحت supervisor/service قادر على إعادته، يرفض الطلب قبل
  الخروج برسالة `service_unavailable`.
- حالات busy تعرض blockers وtimeout بصورة منقحة. لا تُسجل session content أو
  tool payload.
- ينتظر Client bounded تسلسل accepted ثم Offline ثم Online ثم تحديث حالة الجهاز؛
  انقطاع الاتصال وحده ليس نجاحًا.
- يظهر الزر لكل جهاز محلي أو بعيد Online. لا تُضاف مفاتيح capabilities لهذه
  الأوامر، ولا يُستدعى `LocalDaemonController` لجهاز cloud.

### 3. Remote Agent Update

- يضاف فحص typed باسم مبدئي `device.update.check` يعيد النسخة الحالية وأحدث
  Stable version وحالة `update_available/up_to_date/source_managed/unsupported`
  دون تنزيل artifact أو mutation.
- يضاف تطبيق typed باسم مبدئي `device.update.apply` يتطلب target version وmanifest
  revision/fingerprint وتأكيدًا صريحًا من المستخدم.
- يستخدم Agent `AgentUpdateService` المالك الحالي للاستبدال؛ لا يبني Client
  downloader/updater موازيًا ولا يمرر URL أو checksum من الواجهة كسلطة.
- يقبل Agent فقط manifest/artifact الرسميين وفق release trust policy، الحجم،
  SHA-256، المنصة، المعمارية، والنسخة. لا downgrade تلقائي ولا candidate URLs في
  أمر المنتج.
- Source/FVM runtime يعيد `source_managed` ولا ينفذ Git أو FVM عن بُعد.
- يرسل Agent نتيجة staged/accepted قبل restart، ثم يستخدم service/supervisor-safe
  lifecycle. يثبت Client النجاح فقط بعد عودة Online وإعلان النسخة المستهدفة؛
  download أو disconnect وحدهما ليسا نجاحًا.
- فشل replacement/start/health يعيد rollback typed ويحافظ على Sanad Home
  والاعتمادات وWorkspaces وMCP configuration.
- لا يوجد unattended background auto-update في هذه المهمة. الفحص والتطبيق
  user-initiated من Settings؛ أي سياسة scheduled auto-update تحتاج مهمة مستقلة
  وخيار opt-in وmaintenance window.

### 4. Remote Workspace الآمن

- يستعيد المنتج **إنشاء Workspace جديدة** أولًا داخل managed root ثابت:
  `SANAD_HOME/workspaces`. يرسل Client اسمًا ووصفًا لا absolute path، والـAgent
  ينشئ المسار canonical تحت هذا الجذر.
- لا يسمح cloud browsing بتصفح `/` أو كامل user Home أو `SANAD_HOME`. الجذور
  المرئية هي managed workspace root وجذور Workspaces المسجلة فقط.
- لا تُعرض ملفات Sanad الداخلية أو credentials أو provider/MCP secrets ضمن أي
  شجرة حتى لو تداخلت الإعدادات بصورة غير صحيحة.
- browse/create-folder/rename-folder/delete-folder تعمل فقط داخل Workspace root
  محددة وبعد canonicalization ورفض traversal/null bytes/symlinks/root targets.
- الحذف recursive والنقل/relocate يحتاجان preview من Agent يحتوي summary منقحًا
  وrevision/confirmation token قصير العمر لمرة واحدة. لا يقبل Agent تأكيدًا stale
  أو لجهاز/مسار/عملية مختلفة.
- اختيار arbitrary existing host directory عن بُعد خارج النطاق الأول. يمكن
  إضافته لاحقًا فقط عبر allow-root grant صريح من داخل المضيف أو سياسة operator؛
  User authentication وحدها لا تفتح Home كاملًا.
- Workspaces الموجودة تظل قابلة للاستخدام في المحادثات كما هي، ولا يغير هذا
  المشروع session/workspace identity أو stable UUID.

### 5. Remote MCP Management

- يستعيد list وinspect وtest وadd/edit/delete وimport/advanced preview وOAuth
  تدريجيًا عبر handlers الحالية بعد إضافة admission السحابي المقيد.
- snapshot لا يعيد bearer tokens أو custom secret headers أو secret environment/
  arguments أو OAuth access/refresh/client secrets. يعيد references opaque أو
  `configured=true` فقط وفق العقد الحالي.
- القيم السرية تعبر payload typed إلى Agent ولا تدخل logs أو errors أو Backend
  persistence. إذا كان relay الحالي لا يضمن عدم التخزين/التسجيل، تتوقف بوابة MCP
  السرية حتى إصلاح hosted boundary.
- save/delete/replace وبدء STDIO executable تحتاج preview/revision fingerprint
  وتأكيد UI صريح. root-document replacement العام يبقى مرفوضًا.
- STDIO يستخدم executable+arguments دون shell، مع validation الحالي وحدود timeout
  وتنظيف child processes. لا يضاف حقل raw command line.
- HTTP/SSE endpoints تخضع لعقد transport الحالي وSSRF/headers validation، ولا
  يُسمح pseudo-headers أو CR/LF أو Host/Content-Length overrides.
- Device وWorkspace scopes يبقيان منفصلين، وWorkspace definition تتغلب على Device
  definition بالاسم canonical فقط كما في العقد الحالي.
- OAuth يبقى daemon-owned مع PKCE وflow IDs وtimeouts؛ Client لا يستقبل token.
- تشغيل MCP tools من محادثة cloud يبقى تحت `PermissionManager` ولا يحصل على
  bypass بسبب أن الإعداد أُنشئ عن بُعد.

### 6. UX والتأكيدات

- كل النصوص في Client تبقى English.
- Device Overview يعرض **Check for updates** و**Update agent** و**Restart agent**
  لكل جهاز Online، مع version/result state وdialogs توضح أن update/restart قد
  ينتظر checkpoint وأن الاتصال سينقطع مؤقتًا. لا تعتمد الأزرار على مفاتيح
  `supports_remote_*` في capabilities.
- إنشاء Workspace عن بُعد يبدأ باسم داخل managed root، لا بحقل absolute path.
- Remote browser يعرض الجذر المسموح فقط مع breadcrumb لا يستطيع الصعود فوقه.
- MCP cards تبقى form-first وتعرض scope/transport/auth state/tool count منفصلة؛
  لا تعرض JSON خامًا أو قيمة سرية بعد الحفظ.
- كل mutation تعرض progress وtyped success/error، وتمنع double submit، وتتعامل مع
  lost-success بإعادة snapshot بدل تكرار destructive operation تلقائيًا.

## داخل النطاق

- canonical events/commands/results لـremote update/restart دون إضافة مفاتيح
  capabilities جديدة؛ كل جهاز Online يدعم هذه الأوامر؛
- إعادة استخدام `AgentUpdateService` و`DaemonRestartCoordinator` وservice/
  supervisor-safe replacement and exit؛
- managed remote Workspace creation والتصفح/المجلدات داخل allowed roots؛
- remote MCP management المنقح بكل من Device وWorkspace scopes؛
- Client Settings/Workspace/MCP UX؛
- cloud adapter admission بدل الحظر العام؛
- اختبارات Agent/Client والبروتوكول وlive verification على جهاز Task 81 البعيد؛
- تحديث وثائق التقنية والمنتج وQA والعقود القريبة.

## خارج النطاق

- fallback ضمني إلى force restart أو قتل process مباشر من Client؛
- unattended/scheduled Agent auto-update؛ التحديث في هذه المهمة user-initiated؛
- poweroff/reboot لنظام التشغيل أو إدارة system packages؛
- تصفح filesystem root أو user Home كاملًا عن بُعد؛
- arbitrary shell command أو raw MCP command line؛
- رفع/تنزيل ملفات عامة خارج Workspace roots؛
- تغيير pairing/auth protocol إلا إذا أثبت discovery فجوة ownership حقيقية؛
- نشر إصدار أو merge تلقائي؛
- إزالة permission prompts عن MCP tools أو filesystem tools.

## البوابات

### G0 — Threat model وhosted ownership

- [x] توثيق attacker/user/device/backend trust boundaries لكل capability.
- [x] إثبات أن hosted Gateway يربط User ownership بالـdevice المستهدف لكل relay.
- [x] إثبات أن sensitive MCP payloads لا تُحفظ أو تُسجل في hosted path، أو إنشاء
  blocker/handoff قبل استعادة secret mutations.
- [x] مراجعة الأوامر المحظورة الحالية والمعالجات retained واختبارات regression.
- [x] اعتماد managed workspace root وحدود browse والتأكيدات مع المالك.
- [x] ربط كل gate باختبارات قبول وفشل واضحة وتحديث نسبة المتبقي.

أدلة G0: `docs/technical/remote_device_control_threat_model.md`. الحظر الحالي
يغطي 6 أوامر workspace و14 أمر MCP. مسار المنتج هو relay Socket.IO وليس
`POST /api/mcp`. G1 يضيف رفض `device_id` غير المطابق على الـAgent.

### G1 — العقود والقبول المشتركة

- [x] إضافة typed command/result/error models دون parsing حسب أسماء UI.
- [x] عدم إضافة أي مفتاح capabilities لـremote update/restart/workspace/MCP؛
  كل جهاز Online يدعم هذه الأوامر دون فحص قدرات.
- [x] الحفاظ على request/device/session correlation عبر local/cloud envelopes.
- [x] إضافة authorization/admission tests للهدف الصحيح، wrong-device، offline،
  duplicate request، وstale confirmation.
- [x] تحديث عقود Agent Interfaces وClient Devices/Settings/MCP ووثائق البروتوكول.

### G2 — Remote Agent Update وRestart

- [x] تنفيذ `device.update.check` read-only عبر release manifest authority الحالية.
- [x] تنفيذ `device.update.apply` user-confirmed عبر `AgentUpdateService` مع exact
  target،trust verification،rollback،وtyped progress/result.
- [x] إثبات `source_managed` وعدم downgrade أو candidate URL injection.
- [x] تنفيذ restart handler يعيد accepted قبل drain ثم يستدعي
  `DaemonRestartCoordinator`.
- [x] رفض unsupervised/unsupported وforce وtimeout غير المحدود.
- [x] منع lost acknowledgment من التحول إلى restart مكرر تلقائيًا.
- [x] إضافة Client commands وحالات check/update/restart progress وانتظار
  Offline→Online والنسخة المستهدفة.
- [x] إظهار أزرار check/update/restart لكل جهاز Online محلي أو سحابي، مع dialogs
  ونتائج typed ومنع double-submit.
- [x] اختبارات no-update/update/rollback/source-managed وactive idle،active safe
  checkpoint،blocked timeout،concurrent restart،disconnect،reconnect،وservice
  unavailable.

### G3 — Managed Remote Workspaces

- [x] إنشاء managed root آمن عبر `SanadHomeBootstrap` دون symlink.
- [x] استبدال remote `create_workspace` path input بعقد name-based managed create.
- [x] تقييد browse بجذور managed/registered وإخفاء Sanad internal paths.
- [x] تفعيل create/rename/delete folder داخل root فقط مع canonical checks.
- [x] تنفيذ preview+one-time confirmation للحذف recursive وrelocate.
- [x] استعادة Client create/browser UX للجهاز البعيد دون native picker.
- [x] اختبارات traversal/symlink/race/root deletion/stale token/wrong device/
  concurrent mutation والـlost-success recovery.

### G4 — Remote MCP Management

- [x] فصل read-only list/inspect عن secret/destructive mutation admission.
- [x] إثبات redacted snapshots وعدم تسريب secrets في logs/errors/events/cache.
- [x] تفعيل form/test/preview/save/delete/import/advanced/OAuth حسب hosted evidence.
- [x] إضافة revision fingerprint وexplicit confirmation للعمليات الخطرة.
- [x] الحفاظ على no-shell STDIO وSSRF/header validation وbounded cleanup.
- [x] تحديث effective catalog بعد mutation دون restart ودون تغيير permissions.
- [x] اختبارات Device/Workspace precedence،secret replace/remove،OAuth expiry/
  cancel،process cleanup،malformed import،stale revision،وcloud/local parity.

### G5 — Client UX والتكامل

- [x] Check/Update/Restart buttons تعمل على الجهاز المحدد لا الجهاز المحلي افتراضيًا.
- [x] Remote Workspace create/browser يعمل ضمن الجذر المسموح ويعرض limits بوضوح.
- [x] MCP Settings تعمل للجهاز البعيد مع redaction والتأكيدات وحالات offline.
- [x] لا transport branching داخل presentation؛ كل routing عبر coordinator/client.
- [x] widget/unit tests للنوافذ والتأكيد وdouble-submit وreconnect/lost-success.
- [x] تحقق بصري في Client مرئي مع نصوص English فقط.

### G6 — التحقق المحلي والأمني الكامل

- [x] Agent وClient analyzers يمران.
- [x] focused auth/admission/restart/workspace/MCP tests تمر.
- [x] full fast Agent وClient suites تمر بسبب اتساع البروتوكول والواجهات.
- [x] daemon-backed E2E يثبت restart/reconnect وpersistent mutation boundaries.
- [x] secret canaries وlog scans وsymlink/race/fail-injection تمر.
- [x] Graphify update وdiff check والوثائق والعقود متسقة.

### G7 — التحقق الحي على جهاز Task 81 البعيد

- [x] فحص read-only لحالة الجهاز والخدمة قبل mutation.
- [x] Remote update check يعرض current/latest بدقة؛ candidate update معزول يثبت
  apply/restart/version health وrollback دون لمس Stable قبل بوابة الإصدار.
- [x] Remote safe restart من Client يعيد acknowledgment ثم Offline→Online وتعود
  capabilities والجلسات دون فقد عمل قابل للاستعادة.
- [x] Remote force restart لا يحدث إلا من زر الخطر الصريح، ثم يعيد المشرف
  تشغيل الخدمة وتعود Online دون استهداف الجهاز المحلي.
- [x] إنشاء managed Workspace من Client، إنشاء/rename/delete مجلد اختبار داخلها،
  وإثبات رفض الخروج فوق root.
- [x] إضافة MCP test server من Client البعيد، inspect/tools،ثم edit/delete مع
  إثبات redaction وعدم بقاء child/listener.
- [x] حذف سجل Workspace تجريبي من Client مع إثبات بقاء الدليل والملفات وعدم
  حذف المحادثات.
- [x] إثبات أن العمليات تستهدف الجهاز البعيد لا Agent المحلي.
- [x] جمع evidence sanitized دون IP/token/credential/user content.

### G8 — التوثيق والمراجعة والتسليم

- [x] تحديث `workspace_folder_mutation_protocol.md` من suspended إلى العقد الفعلي.
- [x] تحديث MCP architecture/QA وDevice settings وClient interface وrunbooks.
- [x] مراجعة threat model والـdiff وdependency/protected labels.
- [x] طلب موافقة مستقلة قبل commit/push/PR.
- [x] لم يحدث merge أو protected labels أو cleanup قبل التفويض؛ المالك صرّح
  بها بعد اكتمال المراجعة والتحقق، ولا يشمل التفويض أي إصدار.

### G9 — ملاحظات المالك ومراجعة الجودة

- [x] حصر `local-agent` في هوية المخزون الاصطناعية المركزية، ومنع
  استخدام النص لاستنتاج النقل المحلي أو إنشاء جهاز MCP وهمي.
- [x] إزالة **Browse folders** من Workspace Overview مع إبقاء browser
  dialog وأوامر daemon لميزة File Tree المستقبلية.
- [x] إضافة **Remove workspace** بتأكيد واضح، بحيث يحذف daemon سجل
  Workspace فقط ولا يحذف المسار أو محتوياته أو المحادثات.
- [x] إضافة **Force restart** صريح بين Cancel وRestart بلون أحمر، دون
  تحويل فشل restart الآمن تلقائيًا إلى force.
- [x] تحقق Agent/Client المركز، وتحديث العقود والوثائق وGraphify.
- [x] مراجعة G0–G8 بالترتيب، مع إصلاح النتائج الكبيرة والمتوسطة فقط.

## معايير القبول

- [x] Check for updates يعرض حالة الجهاز البعيد دون mutation، وUpdate agent
  يطبق artifact رسميًا موثقًا عبر Agent authority ويثبت النسخة بعد reconnect.
- [x] update failure يعيد الباينري والخدمة السابقين ولا يحذف Sanad Home أو
  الاعتمادات أو Workspaces/MCP configuration.
- [x] Restart agent من Device Overview يعيد الجهاز البعيد المحدد فقط بطريقة
  checkpoint-safe، ويثبت النجاح بعودة Online لا بمجرد disconnect.
- [x] تعرض الواجهة force restart كخيار خطر صريح فقط، ولا يخرج Agent غير
  supervised ولا يتحول restart الآمن إلى force تلقائيًا.
- [x] يستطيع المستخدم إنشاء Workspace بعيدة داخل managed root دون كتابة path.
- [x] لا يستطيع cloud user تصفح `/` أو Home أو Sanad secrets أو تجاوز Workspace
  root عبر traversal/symlink/race.
- [x] destructive workspace mutations تحتاج preview وتأكيدًا مرتبطًا بالعملية.
- [x] يستطيع المستخدم إدارة MCP Device/Workspace عن بُعد مع redacted snapshots.
- [x] لا يظهر أي MCP secret في response/log/cache/export، ولا يصل raw shell إلى
  process launcher.
- [x] كل request/result مرتبطان بالـdevice والـrequest الصحيحين، وwrong-device أو
  stale/duplicate/offline requests تفشل دون mutation.
- [x] local behavior وcloud-origin MCP tool execution لا يتراجعان.
- [x] الاختبارات المحلية وE2E والتحقق الحي على الخادم تمر قبل PR.

## تعريف الإنجاز

- [x] كل قرارات G0 مثبتة ولا توجد hosted security assumptions غير متحققة.
- [x] G1–G7 مكتملة بأدلة آلية وحية.
- [x] الكود والاختبارات والوثائق والعقود متسقة في نفس التسليم.
- [x] لا secrets أو private infrastructure identifiers في المستودع أو PR.
- [x] commit/push/PR/protected labels/squash merge لا تتم إلا بعد موافقة المالك؛
  الموافقة الصريحة موثقة، ولا إصدار ضمن هذه المهمة.
