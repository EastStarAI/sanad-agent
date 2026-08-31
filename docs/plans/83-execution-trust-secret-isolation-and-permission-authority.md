---
title: "Plan 83: Execution Trust, Permission Authority, and Secret Isolation"
description: "خطة مظلة لحماية أسرار سند، نقل سلطة الأذونات خارج Workspace، الحفاظ على بيئة المطور، وإضافة تنفيذ مباشر أو معزول واكتشاف اختياري لأدوات المضيف دون منح المستخدمين غير الموثوقين رؤية إضافية."
status: "pending"
priority: "critical"
reference_grounding: "evidence-83-terminal-secret-hardening"
reference_fingerprint: "sha256:1ae730d0393bdbfdf2e145c5b77ee7182edfe62b60092b0e4c642ca6905fe48c"
---

# Plan 83: ثقة التنفيذ وسلطة الأذونات وعزل الأسرار

## 1. الحالة والهدف

- **الحالة:** `pending` — التأصيل المرجعي مكتمل، والخطة جاهزة للمراجعة قبل بدء 83a.
- **الأولوية:** حرجة؛ السياسة الحالية تسمح لملف داخل Workspace بالتأثير في `full_access`، وتورث Shell بيئة الـdaemon كاملة، بينما مخازن Providers وMCP لا تستخدم جميعها مالك أسرار المصادقة الموحد.
- **النطاق:** Agent permission authority، secret stores، child-process environment، MCP stdio، execution backends، host capability discovery، Full Access confirmation، Client credential persistence، والاختبارات الأمنية والتوافقية.
- **أسلوب التنفيذ:** خطة مظلة تنجز عبر المهام `83a` إلى `83i` في `docs/plans/tasks/`.
- **قيد الحجم:** تستهدف كل مهمة فرعية 8–15 ملفًا. أي تجاوز يتطلب إعادة تقسيم المهمة وتحديث هذه الخطة قبل التنفيذ.

الهدف هو حماية الأسرار وسلطة المستخدم دون تحويل سند إلى وكيل عاجز:

```text
Owner opens a trusted Workspace
  -> Direct Developer execution by default
  -> inherited developer environment remains available
  -> Sanad-owned secrets and daemon/session internals are removed from children
  -> sensitive actions follow Default or explicitly confirmed Full Access policy

Owner or policy selects Protected execution
  -> required sandbox backend is resolved
  -> workspace/mount/network policy is enforced
  -> no silent fallback to host
  -> optional host discovery exists only when owner policy exposes its tool

Permission or secret persistence
  -> daemon-private authority under SANAD_HOME
  -> no model-writable Workspace file can widen authority
  -> typed secret references materialize only for their owning runtime
```

## 1.1 قرارات المستخدم المثبتة

1. التنفيذ الافتراضي للـWorkspace الموثوقة التي يفتحها المالك هو **Direct Developer**، وليس Container محدودًا.
2. Direct Developer يحافظ على `PATH` وبيئة التطوير الموروثة وأدوات النظام وSDKs وcredential helpers؛ لا تستخدم Shell allowlist صغيرة.
3. وضع **Protected** غير افتراضي، ويصبح إلزاميًا فقط عندما تفرضه سياسة المالك أو أصل/دور غير موثوق. لا يسقط إلى Host تلقائيًا عند غياب backend.
4. تغيير وضع التنفيذ يتم من إعدادات Workspace المملوكة ثم تطبق المحادثة نفسها الوضع الجديد على التنفيذ التالي. لا يلزم فتح جلسة جديدة، ولا يعاد أمر سابق تلقائيًا.
5. `Full Access` يظل وضع أذونات مستقلًا عن مكان التنفيذ. الانتقال إليه يعرض رسالة تأكيد مرة واحدة؛ لا يظهر تحذير دائم بعد القبول.
6. `Full Access` يعني عدم السؤال قبل كل عملية ضمن وضع التنفيذ الحالي. لا يستطيع تجاوز Protected الإلزامي أو سياسة منع Host discovery.
7. نوع الإذن، grants الدائمة، ووضع التنفيذ تحفظ داخل قاعدة بيانات الـAgent تحت `SANAD_HOME` ومفتاح Workspace UUID، لا داخل `<workspace>/.sanad/settings.json`.
8. لا توجد هجرة للأذونات القديمة. حقول الأذونات القديمة داخل Workspace تُتجاهل، ويبدأ كل Workspace بسياسة `default` نظيفة يعيد المالك ضبطها عند الحاجة.
9. اكتشاف أدوات المضيف لا يعتمد على System Prompt أو تعليمات مخفية. يملكه daemon عبر أداة typed مستقلة وقابلة للتعطيل من المالك.
10. سياسة Host discovery في هذا الإصدار هي `disabled|owner_only`. القيمة الافتراضية `owner_only` ليست أمرًا بإظهار الأداة دائمًا، بل سقف سماح: لا تظهر إلا لجلسة ثبت أن caller فيها مالك الجهاز/Workspace **وعندما لا تملك الأدوات المتاحة في تلك الجلسة أصلًا وصولًا مكافئًا إلى Host `PATH`**. لذلك تختفي عادةً في Direct Developer عندما تستطيع Shell فحص المسار مباشرة، وتظهر فقط عندما تضيف قدرة لازمة غير متاحة، مثل جلسة Protected للمالك. تختفي عن كل مستخدم مشارك، ويستطيع المالك اختيار `disabled` لإخفائها عن جلساته أيضًا؛ لا يوجد وضع يتيحها تلقائيًا لكل أعضاء Workspace.
11. عند تعطيل Host discovery، أو غياب owner identity، أو وجود capability أخرى تمنح وصولًا مكافئًا إلى Host `PATH`، تختفي الأداة من capability catalog. لا يضاف schema زائد يستهلك السياق، ولا يستطيع مستخدم Workspace غير الموثوق تصفح Host inventory عبر هذه القناة.
12. لا يضاف زر أو رابط سياقي لفتح Workspace Execution Mode بعد فشل أداة. الإعداد يبقى في صفحة/تحكم Workspace الطبيعية، والنتائج لا تروّج لتجاوز سياسة المالك.
13. ملفات `.env` التابعة للمشروع لا تُحظر عن تشغيل المشروع. تُحجب قيمها عن القراءة الموجهة للنموذج، بينما تستطيع العملية داخل وضع التنفيذ المختار استهلاكها.
14. أسرار Agent الخاصة بالمصادقة وProviders وMCP تستخدم سياسة `AgentSecretStore` الموحدة: macOS Keychain، Windows DPAPI، Linux Secret Service، وLinux owner-only fallback للـHeadless عند غياب Secret Service.
15. هجرة Providers وMCP مطلوبة: لا يحذف المصدر القديم إلا بعد كتابة وقراءة تحقق كاملة في المالك الجديد.
16. Client native credentials تنتقل إلى secure-storage abstraction مثل `flutter_secure_storage` بعد إثبات دعم المنصات. لا تهاجر أسرار Client القديمة؛ يسجل المستخدم الدخول مرة أخرى.
17. Linux owner-file fallback حماية بحدود حساب النظام و`0700/0600` وatomic writes، وليس تشفيرًا عند السكون، ولا توصف الوثائق بخلاف ذلك.

## 1.2 الفصل بين المرجع وقرار سند

| المجال | ما ثبت في المشاريع المرجعية | قرار سند |
|---|---|---|
| Host environment | الحفاظ على البيئة الموروثة مع حذف أسرار مملوكة ومتغيرات تشغيل خطرة، والفصل بين inherited values وrequest overrides | Direct Developer يحافظ على البيئة الموروثة؛ يمنع أسرار سند وحقن overrides السلطوية مركزيًا |
| Sandbox | Backends اختيارية، required modes تفشل مغلقة، وHost elevation منفصلة عن tool policy | Direct افتراضي للمالك؛ Protected اختياري/مفروض بالسياسة؛ لا fallback ولا session rotation |
| `.env` | مرجع يحظر file read ويقر بإمكان Shell، وآخر ينقح model-visible read | تنقيح القراءة الموجهة للنموذج مع السماح لاستهلاك المشروع داخل backend |
| Secrets | Secret references/runtime scoping مع إقرار أن بعض المخازن owner-only plaintext | إعادة استخدام `AgentSecretStore` الموجود بدل إنشاء نظام ثالث، مع هجرة Providers/MCP |
| Tool availability | المرجع يملك explain/config أو executable fallbacks | أداة Host discovery مستقلة وقابلة للإزالة من catalog؛ لا تعليمات Prompt ولا رابط تصعيد تلقائي |
| Permission authority | المرجعان لا يمنحان ملف مشروع عادي سلطة توسيع Host access | قاعدة Agent خاصة مرتبطة بـWorkspace UUID، دون هجرة grants من Workspace |

## 1.3 قاعدة إدارة التقدم

- الحالات المسموحة: `pending`, `in_progress`, `blocked`, `in_review`, `complete`.
- تعمل كل مهمة على Gate واحدة فقط في الوقت نفسه.
- لا تبدأ Gate لاحقة حتى تغلق Exit criteria للبوابة السابقة ويسجل دليل التحقق.
- لا تبدأ 83b–83f قبل اعتماد contracts في 83a.
- لا يبدأ 83g قبل ثبات permission authority وenvironment policy وhost discovery contracts في 83b و83e و83f.
- لا تبدأ 83h قبل ثبات daemon protocols في 83b و83g وعقد Client secret store في 83d.
- لا تبدأ 83i قبل اكتمال 83b–83h.
- كل مهمة تنفيذية تحدث أقرب `AGENTS.md` ووثائق technical/product/QA المالكة في الجلسة نفسها.
- لا توصف الخطة `complete` قبل إثبات عدم تسريب الأسرار وعدم كسر أدوات المطور وعدم إمكان self-authorization من Workspace.

## 1.4 لوحة التقدم

| المهمة | الحالة | Gate الحالية | سقف الملفات | شرط الانتقال |
|---|---|---|---:|---|
| 83a Security Contracts and Attack Reproduction | `pending` | A0 | 12 | اعتماد الخطة |
| 83b Daemon-Private Permission Authority | `pending` | Waiting | 15 | اكتمال 83a |
| 83c Unified Agent Secret Store and Migration | `pending` | Waiting | 15 | اكتمال 83a |
| 83d Native Client Secure Credential Storage | `pending` | Waiting | 12 | اكتمال 83a |
| 83e Child Process Environment and Developer Parity | `pending` | Waiting | 15 | اكتمال 83a |
| 83f Owner-Controlled Host Capability Discovery | `pending` | Waiting | 13 | اكتمال 83a و83b و83e contracts |
| 83g Direct and Protected Execution Backends | `pending` | Waiting | 15 | اكتمال 83b و83e و83f |
| 83h Full Access and Workspace Security UX | `pending` | Waiting | 15 | اكتمال 83b و83d و83g |
| 83i Security Integration and Developer Compatibility QA | `pending` | Waiting | 15 | اكتمال 83b–83h |

## 2. الوقائع المثبتة في سند الحالية

1. `ShellExecuteTool` يمرر `Platform.environment` كاملًا إلى العملية الفرعية، ثم يضيف markers خاصة بالجلسة وtool call.
2. Shell يبدأ داخل Workspace ويتحقق من `cwd`، لكن الأمر نفسه يعمل بنفس حساب النظام ويمكنه الوصول إلى مسارات أخرى يملكها الحساب.
3. `McpRuntimeManager` يملك allowlist أساسية أفضل من Shell، ثم يضيف environment المحلول من إعدادات server.
4. `SecureFileSecretStore` يحفظ Provider secrets في `provider_secrets.json` owner-only، ويصرح صراحة أنه غير مشفر عند السكون.
5. MCP secret references تعود إلى `mcp_secrets.json` owner-only داخل Sanad Home؛ لا تستخدم `AgentSecretStore` بعد.
6. `AgentSecretStore` موجود ويستخدم Keychain/DPAPI/Linux capability selection، مع owner-only fallback صالح للـHeadless.
7. `WorkspacePolicyStore` يقرأ `permissionMode` وallow/deny من `<workspace>/.sanad/settings.json`.
8. `PermissionManager` يعيد مباشرة عند `full_access` أو عند تطابق `permissions.allow`؛ الملف داخل root يستطيع الوكيل الكتابة فيه.
9. مستودع منسوخ يمكنه أن يصل مسبقًا بملف `.sanad/settings.json` يمنح `full_access`، دون إثبات أن المالك اختار هذا القرار على الجهاز الحالي.
10. `workspace.set_permission_mode` هو الأمر الصريح الوحيد لتغيير mode عبر البروتوكول، لكنه يكتب حاليًا إلى الملف غير السلطوي المقترح نقله.
11. Client يحتفظ بحالة إذن Workspace في projection محلية، ويستهلك daemon command/events، ما يسمح بإبقاء UI renderer بعد نقل المصدر.
12. Client authentication code يقرأ User access/refresh session من preferences الحالية، ولا توجد dependency مثبتة لـ`flutter_secure_storage` في الفرع المفحوص.
13. حماية Sanad Home الحالية تمنع symlinks/traversal وتفرض owner-only atomic writes، لكنها تعتبر process يعمل بنفس حساب النظام داخل trust boundary.

## 3. نموذج الثقة المستهدف

### 3.1 خمس هويات بيانات منفصلة

```text
Sanad control-plane secrets
  Agent identity, Gateway credentials, local tokens, provider credentials

Capability-owned secrets
  MCP server token/header/env/argument, selected provider request credential

Operator/developer environment
  PATH, SDK roots, caches, SSH agent, Docker/cloud selectors, proxies and CA roots

Workspace project data
  source, configs, project-owned .env and build artifacts

Permission authority
  owner decisions, execution posture, host discovery policy, durable grants
```

لا يعامل suffix مثل `TOKEN` أو `KEY` وحده كدليل ملكية. المصدر والمالك والغرض هي الأساس، مع patterns إضافية دفاعية فقط.

### 3.2 محوران مستقلان

```text
Execution posture: Direct Developer | Protected
Approval policy:   Default          | Full Access
```

- `Direct + Default`: الوضع الافتراضي للمالك؛ أدوات المضيف متاحة، والحساس يطلب موافقة.
- `Direct + Full Access`: Host كامل دون prompts متكررة بعد confirmation، مع بقاء أسرار سند غير محقونة.
- `Protected + Default`: عزل فعلي مع approvals داخل الحدود.
- `Protected + Full Access`: لا prompts داخل sandbox، لكنه لا يخرج إلى Host ولا يفتح discovery المحظور.

### 3.3 Authority hierarchy

```text
Owner/administrator policy in daemon-private database
  > required execution posture and discovery prohibition
  > workspace approval mode and durable grants
  > session and one-shot grants
  > workspace files, model output, skills, MCP output, turn payload
```

- deny أو required restriction العليا لا يستطيع Full Access تجاوزها.
- أي identity غير مثبتة كمالك لا تستطيع تغيير execution posture أو Host discovery policy.
- إذا لم يوفر transport هوية كافية لاتخاذ قرار مالك، يفشل mutation مغلقًا.

## 4. القرارات المعمارية الحاكمة

### 4.1 مخزن الأذونات

- يضاف owner واحد في قاعدة Agent state لسياسة Workspace، keyed by stable Workspace UUID.
- تربط القراءة UUID بالمسار canonical المسجل حاليًا لمنع path forgery وإعادة استخدام هوية على root آخر.
- المخزن يدعم `permissionMode`, `executionMode`, `hostDiscovery`, grants، revision، وtimestamps غير الحساسة.
- writes ذرية ومتفائلة بالrevision أو transactional لمنع lost updates.
- لا تقرأ سلطة من `.sanad/settings.json` ولا تهاجرها. القراءة الأولى لWorkspace غير موجودة تعيد defaults فقط.
- يمكن تنظيف حقول permission القديمة لاحقًا كـnon-authoritative hygiene، لكن وجودها أو تعديلها لا يغير runtime.

### 4.2 Full Access confirmation

- confirmation تظهر فقط عند انتقال `default -> full_access`.
- الرجوع إلى `default` لا يحتاج تحذيرًا.
- النص يشرح files، terminal، internet/connected tools، prompt injection، وإمكان الإيقاف.
- لا يستخدم النص ادعاء أن Full Access يفتح أسرار سند مباشرة؛ يوضح أن أوامر Host تعمل بصلاحيات حساب النظام وقد تصل إلى بيانات متاحة للحساب.
- التأكيد لا يغير execution posture ولا Host discovery policy ضمنيًا.

النص المستهدف، مع السماح بتحسين copy أثناء 83h:

```text
Turn on Full Access?

Full Access lets Sanad act in this workspace without asking before each operation. It may:

Access files and folders
Read, create, modify, upload, or delete files available to your user account.

Run terminal commands
Execute commands, install software, and change system or development settings.

Use the internet and connected tools
Access websites, send data, and use enabled tools and plugins.

Commands run with your operating-system account and may access sensitive files or credentials available to that account. Malicious instructions or prompt injection could cause data loss or exposure.

You can turn Full Access off at any time. Learn more

Cancel | Turn On
```

### 4.3 بيئة Direct Developer

- يبدأ من inherited daemon environment، لا allowlist صغيرة.
- يزيل Sanad-owned credentials وsession/control-plane markers التي لا يملكها child.
- يمنع request/model override من تغيير `PATH`, `HOME`, loader hooks، compiler/package-manager pivots، secret owner selectors، أو trust-store/proxy roots دون typed owner authorization.
- inherited operator values وrequest overrides فئتان مختلفتان ولا تدمجان قبل policy.
- تزال markers التي قد تربط child ببيئة Agent الداخلية إذا كان ذلك يكسر مشروع المستخدم، مثل active venv الخاصة بالdaemon، بعد اختبار إيجابي.
- تحافظ الاختبارات على Flutter/FVM/Android/Java/Node/Git/SSH/Docker/cloud CLI/package caches/proxies/CA behavior.

### 4.4 Host capability discovery

- لا يضاف أي System Prompt نص يخبر النموذج أن أداة ما موجودة على Host.
- يضاف daemon-owned typed tool محدود لاكتشاف executables من inherited trusted `PATH` أو query اسم محدد.
- لا ينفذ `--version` أو shell startup scripts لمجرد discovery، ولا يقرأ arbitrary files، ولا يعرض environment values.
- output يقتصر على معلومات غير سرية لازمة: name، canonical executable path، availability، وربما source class. لا يعرض بقية PATH أو directory listing غير محدود.
- policy هي `disabled|owner_only` وتبدأ `owner_only`. هذه policy سقف authorization وليست شرط presence: catalog builder يضيف tool spec فقط عندما تثبت session owner identity ولا توجد capability مفعلة تمنح وصولًا مكافئًا إلى Host `PATH`.
- في Direct Developer مع Host Shell قادرة على فحص PATH، تختفي discovery tool لأنها مكررة. إذا أضيفت لاحقًا أداة أخرى توفر الوصول المكافئ، يطبق عليها الشرط نفسه دون ربط القرار باسم Shell ثابت.
- `owner_only` لا يظهر للمستخدم المشارك حتى داخل Workspace نفسها، و`hostDiscovery=disabled` يحذف tool spec حتى لجلسة المالك. لا يوجد stub يخبر النموذج بوجود capability مخفية.
- مالك Workspace/Agent وحده يغير هذه السياسة. مستخدمون آخرون لا يستطيعون تفعيلها عبر المحادثة أو Workspace content.
- في Protected مع discovery disabled، لا توجد مقارنة تلقائية أو رسالة تقترح Host mode أو فتح settings.
- discovery لا يمنح التنفيذ؛ Direct/Protected وpermissions ما زالت مستقلة.

### 4.5 ملفات `.env`

- file read wrapper يصنف project env files ويمنع raw value projection إلى model context.
- الاختبارات والبناء والبرامج داخل backend تستطيع فتح الملف وفق filesystem boundary لذلك backend.
- لا تنسخ القيم إلى logs أو checkpoints أو permission payloads.
- `.env.example` وsource-shaped files تبقى قابلة للقراءة.
- استثناء user-approved reveal، إن أضيف، يكون typed ومحدودًا ولا يدخل هذه الخطة دون تحديث قرار المستخدم.

### 4.6 مخزن أسرار Agent الموحد

- `AgentSecretStore` يصبح backend المشترك لبيانات Agent auth وProvider credentials وMCP secrets مع namespaces مستقلة.
- Metadata/config تحتفظ opaque references وحالة `configured` فقط.
- materialization يحدث داخل daemon عند آخر owner boundary ممكنة.
- Shell العام لا يتلقى Provider/MCP secrets تلقائيًا.
- MCP stdio يتلقى فقط environment/headers/args السرية المملوكة لذلك server.
- migration للـProviders وMCP: read legacy -> write target -> read/compare -> commit references -> delete legacy. أي فشل يبقي legacy authoritative ولا ينتج نصف ترحيل.
- corrupted/partial stores تفشل برسالة typed دون طباعة bytes.

### 4.7 Client secure credentials

- يضاف `ClientCredentialStore` abstraction بدل القراءة المباشرة من preferences.
- native desktop/mobile backend يستخدم secure storage package بعد فحص دعم كل منصة وfailure semantics.
- Web يبقى ضمن browser security model ولا يوصف كـOS vault؛ يثبت له contract منفصل لا يضعف native stores.
- لا توجد migration من preferences. عند أول إصدار جديد، تزال/تتجاهل مفاتيح legacy، وتصبح الجلسة logged out، ويسجل المستخدم الدخول مرة أخرى.
- non-secret profile/cache metadata قد تبقى في preferences.

### 4.8 Protected execution

- `ExecutionBackend` أو عقد مكافئ يملك Direct وProtected دون تكرار process lifecycle.
- Protected backend selection capability-based؛ backends الأولى يمكن أن تشمل Docker/Podman/SSH وفق دعم المنصة المثبت.
- required Protected مع backend unavailable يعيد typed fail-closed outcome، ولا يشغل Host.
- workspace access وmounts وnetwork وUID/capabilities/no-new-privileges/PID/resource limits صريحة.
- لا يربط Docker socket أو Sanad Home أو credential roots داخل sandbox.
- تغيير mode في Workspace database يطبق على نفس session في التنفيذ التالي، مع generation/revision يمنع stale run من استخدام mode قديمة.

## 5. ترتيب التنفيذ

```text
                         83a Contracts + Reproduction
                                   |
          +------------+-----------+-----------+------------+
          |            |                       |            |
          v            v                       v            v
  83b Permissions  83c Agent Secrets    83d Client Store  83e Environment
          |            |                       |            |
          +------------+-----------+-----------+------------+
                                   |
                                   v
                         83f Host Discovery
                                   |
                                   v
                       83g Execution Backends
                                   |
                                   v
                   83h Full Access + Workspace UX
                                   |
                                   v
                    83i Integration / Security QA
```

- 83b–83e يمكن تنفيذها بالتوازي بعد تثبيت types والحدود في 83a.
- 83f يعتمد على owner policy من 83b وعلى inherited environment contract من 83e.
- 83g يستهلك السياسة ولا يملكها، ويستهلك discovery دون جعله شرطًا للتنفيذ.
- 83h يعرض daemon truth ولا يخزن authority أو credentials في Flutter state.
- 83i لا يضيف سياسة جديدة؛ يعيد findings إلى المهمة المالكة.

## 6. خطط المهام

1. [83a: Security Contracts and Attack Reproduction](tasks/83a-security-contracts-and-attack-reproduction.md)
2. [83b: Daemon-Private Permission Authority](tasks/83b-daemon-private-permission-authority.md)
3. [83c: Unified Agent Secret Store and Migration](tasks/83c-unified-agent-secret-store-and-migration.md)
4. [83d: Native Client Secure Credential Storage](tasks/83d-native-client-secure-credential-storage.md)
5. [83e: Child Process Environment and Developer Parity](tasks/83e-child-process-environment-and-developer-parity.md)
6. [83f: Owner-Controlled Host Capability Discovery](tasks/83f-owner-controlled-host-capability-discovery.md)
7. [83g: Direct and Protected Execution Backends](tasks/83g-direct-and-protected-execution-backends.md)
8. [83h: Full Access and Workspace Security UX](tasks/83h-full-access-and-workspace-security-ux.md)
9. [83i: Security Integration and Developer Compatibility QA](tasks/83i-security-integration-and-developer-compatibility-qa.md)

## 7. معايير القبول الكلية

- [ ] ملف داخل Workspace، بما فيه `.sanad/settings.json`، لا يستطيع منح `full_access` أو durable allow أو تغيير execution/discovery policy.
- [ ] كل Workspace بلا policy خاصة يبدأ `Direct Developer + Default + owner_only discovery` وفق contract 83a، دون استيراد grants قديمة.
- [ ] Full Access confirmation تظهر عند التفعيل فقط، ولا يظهر banner دائم.
- [ ] تغيير Direct/Protected أو permission mode يطبق على المحادثة نفسها في التنفيذ التالي دون auto-replay.
- [ ] Direct Developer يكتشف ويشغل أدوات المطور الموروثة ولا يعتمد على allowlist بيئية صغيرة.
- [ ] model/request overrides لا تستطيع استبدال execution-control variables المحمية.
- [ ] Host discovery أداة typed لا Prompt instruction، وتختفي عندما يمنعها المالك أو عندما تملك الجلسة capability أخرى توفر وصولًا مكافئًا إلى Host `PATH`.
- [ ] مستخدم غير مالك لا يستطيع تفعيل discovery أو Direct أو Full Access عبر payload أو tool أو file mutation.
- [ ] Provider وMCP secrets تهاجر ذريًا إلى `AgentSecretStore` وتزال plaintext القديمة فقط بعد verification.
- [ ] Linux Headless يستمر عبر owner-only fallback دون ادعاء تشفير.
- [ ] Native Client credentials تستخدم secure storage؛ legacy session لا تهاجر ويطلب login جديدًا.
- [ ] project `.env` لا يدخل model output خامًا، بينما build/test/runtime consumption يستمر.
- [ ] Protected required يفشل مغلقًا ولا يربط Sanad Home أو credential roots أو Docker socket.
- [ ] لا يدخل أي secret أو raw environment value إلى logs أو errors أو snapshots أو permission cards.
- [ ] اختبارات security negative واختبارات developer positive تنجح على macOS/Linux/Windows بالنطاق المثبت.

## 8. المخاطر وحواجزها

- **تأمين يؤدي إلى وكيل عاجز:** Direct Developer default + inherited environment + parity matrix + no silent PATH stripping.
- **Workspace يمنح نفسه صلاحيات:** daemon-private DB + UUID/path binding + تجاهل legacy policy files.
- **مستخدم مشارك يكتشف Host:** owner-only discovery policy + catalog omission + no prompt hint/stub.
- **أداة مكررة تستهلك السياق:** availability check مبني على capabilities الفعلية؛ وجود Host PATH access مكافئ يحذف discovery schema من catalog.
- **Full Access يتجاوز عزلًا إلزاميًا:** فصل execution posture عن approval mode وdeny precedence.
- **هجرة أسرار تفقد login أو keys:** verified write/read before reference commit or source deletion.
- **Linux Headless بلا keyring:** preserve selected owner-file backend and document exact boundary.
- **Sandbox يخفي الأدوات:** لا يفعّل افتراضيًا للمالك؛ discovery منفصلة وقابلة للمنع؛ لا اقتراح تجاوز policy.
- **Prompt injection يطلب policy mutation:** explicit authenticated owner command only; model content has no authority.
- **Race عند تغيير mode:** revisioned policy snapshot bound to run admission؛ next execution rereads authoritative revision.
- **Client secure-store failure:** typed logged-out/degraded state without plaintext fallback.

## 9. خارج النطاق

- ترحيل أذونات Workspace القديمة أو الوثوق بأي `permissionMode` داخل المشروع.
- نافذة UI لإدارة Docker mounts أو image building في الإصدار الأول.
- زر سياقي يقترح فتح Execution Mode بعد command failure.
- inventory كامل لكل ملفات أو تطبيقات المضيف؛ discovery مقتصرة على executable capability contract.
- ضمان عزل أسرار حساب المستخدم تحت unrestricted Direct Host shell؛ هذا يحتاج OS boundary ويظل ضمن تحذير Full Access ونموذج الثقة.
- تشفير Linux owner-file fallback دون مصدر مفتاح مستقل.
- ترحيل Client access/refresh credentials القديمة.
- إعادة تشغيل أمر فشل تلقائيًا بعد تغيير backend أو permission mode.
- سياسات مؤسسات/فرق كاملة إذا لم يوفر transport الحالي هوية مالك قابلة للإثبات؛ mutation يفشل مغلقًا بدل اختراع role.

## 10. سجل التقدم والتسليم

```text
Date:
Task/Gate:
Status transition:
Owner/worktree:
Files changed:
Completed:
Verification evidence:
Documentation updated:
Open findings/blockers:
Remaining work percentage:
Next gate/owner:
```
