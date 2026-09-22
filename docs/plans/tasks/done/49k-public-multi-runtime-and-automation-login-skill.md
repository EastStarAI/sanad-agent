---
title: "Task 49K: Public Multi-Runtime Development and Automated macOS Login Skill"
status: "completed"
current_gate: "Complete — all gates passed"
remaining_estimate: "0% — implementation, references, live verification, evaluation, and repository checks are complete"
---

# Task 49K — Public Multi-Runtime Development and Automated macOS Login Skill

## 1. الهدف

تطويرمهارة`Sanad Agentic Developer` للمساهمين فيالمستودع العام عبرمراجعprogressive
disclosure تشرح تشغيلعدةAgents وClients بصورةmanaged،وتوثيقmacOS login قابلة
للأتمتة تبدأمنClient الصحيحة عبر`sanad-dev ui`،وتقرأURL للمحاولة الحالية منDart VM
المحددة،ثم تكملPortal/provider flow فيمتصفح الأتمتة.

## 2. القرارات المقفلة والنطاق

- كلتعديل ينفذ داخلworktree الحالية وفيpublic submodule فقط:
  `sanad-agent/` منworkspace root.
- جمهورmulti-runtime reference هممطوروالـpublic repository؛Public Production client
  profile والـCloud connection هماالافتراضيان.
- يمنعذكرDocker أوCompose أوprivate repository أوprivate Backend/Portal endpoints أو
  server access فيمرجعmulti-runtime.
- لايوثقأيbackup/restore أونسخtokens أوجلساتlogin. مرجعlogin يملكfresh interactive
  sign-in فقط.
- يبقى`.agents/skills/sanad-agentic-developer/SKILL.md` مختصرًا،ويشير إلىملفات
  `references/` بدلحشرالإجراءاتالتفصيلية فيه.
- ينقل تعديل`Explicit non-primary Home rule` غيرالملتزم منprimary checkout إلى
  worktree؛كلأمرضدHome غيررئيسية يمرر`--home <absolute-path>` صراحة،وضبط
  `SANAD_HOME` وحده لايختارruntime للاكتشاف أوالملكية.
- لاتنقلإحالة`local-macos-auth-login.md` الخارجية وهي مكسورة؛ينشأالمرجع الفعلي أولًا
  داخلworktree ثمتضافالإحالة الصحيحة.
- واجهةmacOS تفتحauthorization URL فيمتصفحالمستخدم الافتراضي،وهوخارجسيطرة
  `agent-browser`. الإجراءالمعتمد يضغط`Sign in` عبر`sanad-dev ui`،ثم يحصل علىURL
  الخاصةبالمحاولة الحالية منDart VM للـClient نفسها،ويفتحها صراحة فيمتصفح الأتمتة.
- يمنعاعتماد`active browser tab` أوWeb Client origin أومحاولةقديمة كمصدرللرابط.
- URL مؤقتة وحساسة تشغيليًا:لاتدخلjournals أوruntime files أوdocs أوأدلة،وتلتقط في
  shell variable مؤقتة وتزال بعدفتحها.
- تعددClients فيمجموعة واحدة يستخدم`--client-instance <slot>`؛كلslot فريدة ضمن
  الجهاز والمجموعة. تعددAgents يستخدمmanaged groups معHomes مستقلة،وتستهدفكل
  مجموعةمنworkspace المالكة ومع`--home` الصريح عندالحاجة.
- لا`sanad-dev switch` ضمنهذهالمهمة.
- لاcommit أوpush أوPR أوmerge دونإذنالمالك.

## 3. دليل الجدوى الحي — مكتمل

- [x] تسجيلخروجmacOS Client الحالية عبر`sanad-dev ui` معبقاءLocal Gateway.
- [x] إثباتالحالة`Local Connected, Cloud Login to connect` بعدlogout.
- [x] بدءfresh login منProfile عبر`sanad-dev ui` والـVM المحددة.
- [x] إثباتأنقراءةمتصفحالمستخدم عبر`active tab` قدتختارWeb Client URL خاطئة عند
      وجودعدةChrome windows/tabs.
- [x] قراءة`AuthLoginChallenge.authUrl` الحالية مباشرةمنmacOS Dart VM المحددة عبر
      VM Service دونطباعةالقيمة.
- [x] فتحالرابط فيChrome automation profile وإكمالGoogle consent حتى
      `Authentication Complete`.
- [x] إثباتعودةmacOS إلى`Local Connected, Cloud Connected` وظهور
      `worktree_runtime_badge`.

**نتيجةالتجربة:**التسلسل صحيح،لكنالـheap-inspection script المؤقتة ليستواجهةمنتج.
يلزمأمرdriver رسمي ومختبر قبلتوثيقه فيالمهارة.

## 4. بوابات التنفيذ

### Gate K1 — أمرdriver-owned لاستخراجURL الحالية

- [x] مراجعة`driver_main.dart` و`flutter_driver_cli`/`sanad-dev ui` وتحديدأصغرboundary
      تعرضactive `AuthLoginChallenge.authUrl` فيdriver builds فقط.
- [x] إضافةservice extension/driver action مخصصة وأمرCLI باسم واضح مثل
      `sanad-dev ui auth-url`،دونإدخالالرابط فيwidget snapshots العامة.
- [x] ربطالأمر بالـVM المحددة ورفضغيابمحاولةنشطة أوURL غيرHTTP(S).
- [x] جعلالمخرجاتstdout-only للاستخدام الفوري؛لاjournal أوcache أوruntime metadata.
- [x] المحافظةعلىالسلوك الحالي للـClient غيرالمشغلة بـ`--driver` وللـProduction builds
      المعبأة.

**K1 Exit:**يمكن التقاطURL الحالية منClient driver المحددة بأمر`sanad-dev ui` رسمي
ودونفحصheap عام أوقراءةمتصفحالمستخدم.

### Gate K2 — اختبارات وعقودالأمر الجديد

- [x] اختبارنجاحURL الحالية وربطها بمحاولةlogin النشطة.
- [x] اختبارالفشل عندعدم وجودchallenge،URL غيرصالحة،أوVM غيرdriver.
- [x] اختبارالاستهداف مععدةClients ومنعfallback إلىClient أخرى.
- [x] إثباتعدم كتابةURL إلىmanaged journal أوruntime files.
- [x] تحديثأقرب`AGENTS.md` ووثائقdriver/runtime وQA عندتغيرالعقد.
- [x] تشغيلformat وanalyzers والاختباراتالمركزة ثمfull fast suites المناسبة بمخرجات
      bounded وفقعقدالمستودع.

**K2 Exit:**الأمرآمن،محددالملكية،ومغطى آليًا.

### Gate K3 — مرجعLocal macOS Authentication

- [x] إنشاء
      `.agents/skills/sanad-agentic-developer/references/local-macos-auth-login.md`.
- [x] توثيقpreflight:managed runtime،driver Client،VM الصحيحة،و`--home` الصريح.
- [x] توثيقlogout/login control عبر`sanad-dev ui` بدلmouse coordinates.
- [x] توثيقأنالمتصفح الذي تفتحهClient هوUser Browser وغيرمملوك للأتمتة.
- [x] توثيقcapturing للأمر الجديد فيمتغيرمؤقت،فتحه عبر`agent-browser`،ثم`unset`.
- [x] توثيقprovider/account/consent flow والتحقق من`Authentication Complete`.
- [x] توثيقعودةClient عبر`sanad-dev ui wait-for/snapshot` وbounded sanitized logs.
- [x] توثيقعدةClients:محاولةواحدةفيكلوقت،VM صريحة،وعدمإعادةاستخدامURL قديمة.
- [x] إضافةtroubleshooting للمهلة،challenge الملغاة،المتصفح الخاطئ،والـownership
      ambiguity دونحفظجلسات أوtokens.

**K3 Exit:**يمكنلوكيل جديد تنفيذfresh macOS login كاملة دونالاعتماد علىUser Browser
أوتسريبURL فيالأدلة.

### Gate K4 — مرجعPublic Multi-Runtime Development

- [x] إنشاء
      `.agents/skills/sanad-agentic-developer/references/public-multi-runtime-development.md`.
- [x] شرحAgent واحد مععدةClients باستخدامdevices و`--client-instance` slots مستقلة.
- [x] شرحعدةmanaged Agent groups منworkspace واحدة باستخدامHomes مطلقة مستقلة،مع
      `--home` فيكلrun/status/logs/ui/restart/stop.
- [x] شرحعدةworktrees/workspaces والاستفادةمنالعزل التلقائي للمنافذ والـHome.
- [x] توثيقبدءكلgroup،إضافةClient،status،bounded logs،إيقافClient محددة،وإيقافgroup.
- [x] شرح`Cross-owned` و`Unverifiable` ورفضmutation عندالغموض.
- [x] إبقاءPublic Production profile والـCloud default دونprivate configuration أو
      hosted-server operations.
- [x] إحالةlogin إلىمرجعهاالمستقل فقط؛لا تكرارlogin أوsession persistence هنا.

**K4 Exit:**يستطيعPublic contributor تشغيلومراقبةعدةAgents/Clients ضمنworkspace
واحدة أوعدةworkspaces دونتداخل أومعرفةخاصة.

### Gate K5 — دمجالمهارة وتقييمها

- [x] نقلقاعدة`Explicit non-primary Home` الخارجية إلىنسخةworktree وإزالةالفراغ
      الزائد وصياغةالإحالة باختصار.
- [x] إضافةإحالتين واضحتين في`SKILL.md` تحددانمتى يقرأكلreference.
- [x] تحديثdescription فقطإذا حسّنtriggering لـmulti-runtime/login developer tasks
      دونتوسيعالمهارة خارجنطاقها.
- [x] إنشاء2–3 prompts واقعية تغطي:Agent واحد وعدةClients،عدةHomes فيworkspace
      واحدة،وmacOS login عبرautomation browser.
- [x] مراجعةالمخرجات مقابلنسخةالمهارة القديمة أوتنفيذتقييم نوعي مكافئ إنلميتوفر
      subagent benchmark runner فيالبيئة.
- [x] فحصالروابط والملفات،`git diff --check`،والتأكد منعدموجودDocker/private endpoints/
      credential persistence فيmulti-runtime reference.

**K5 Exit:**المهارة موجزة،مراجعها قابلةللاكتشاف،والأوامرالموثقة مثبتة بالتجربة
والاختبارات.

## 5. معايير القبول

- [x] `SKILL.md` لاتحملالتفاصيل؛توجهإلىمرجعlogin ومرجعmulti-runtime الصحيحين.
- [x] لايوجدرابط مكسور إلى`local-macos-auth-login.md`.
- [x] `sanad-dev ui auth-url` يعيدURL للمحاولةالحالية منالـVM المقصودة فقط ويفشل
      بوضوح دونchallenge نشطة.
- [x] تجربةlogout→fresh attempt→URL capture→automation browser→login→Client
      verification تنجح دوناستخدامUser Browser لإكمالالعملية.
- [x] مرجعmulti-runtime يغطيعدةAgents وClients فيworkspace واحدة أوعدةworkspaces.
- [x] مرجعmulti-runtime لايذكرDocker أوprivate code/endpoints أوserver access.
- [x] لايوثقأيملف طريقةحفظ/نسخ/استعادةtokens أوlogin sessions.
- [x] كلأمرلـHome غيررئيسية يمرر`--home <absolute-path>` صراحة.
- [x] analyzers والاختباراتالمركزة/full المطلوبة و`git diff --check` تنجح.
- [x] التعديلاتتبقى داخلworktree ولاcommit/push دونإذن.

## 6. Definition of Done

- [x] كودdriver و`sanad-dev ui` والاختبارات مكتملة.
- [x] عقود`AGENTS.md` والوثائق التقنية/QA محدثة فقطحيثتغيرlaw أوbehavior.
- [x] مرجعاالمهارة موجودان والروابط صالحة.
- [x] التجربةالحية النهائية مكررة بالأمرالرسمي،لاscript heap مؤقتة.
- [x] skill prompts راجعتprogressive disclosure وعدمخلطpublic/private workflows.
- [x] لاcredential أوtransaction URL فيtask أوdocs أوtracked files.
- [x] لاcommit أوpush أوPR أوmerge دونموافقةالمالك.
