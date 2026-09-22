---
title: "Task 67: sanad-dev Runtime Ownership and Background Usability Failures"
description: "سجل مشكلات قابل لإعادة الإنتاج لفشل تشغيل sanad-dev في الخلفية، وتصنيف ownership، والتنظيف، والتحكم في runtime."
status: "completed"
current_gate: "complete"
review_remaining: "0%"
priority: "high"
scope: "scripts/sanad_dev runtime launch, discovery, ownership, doctor, logs, restart, and stop behavior"
depends_on: "current sanad-dev launcher lease and worktree runtime contracts"
coordinates_with: "Task 54 background process supervision"
---

# Task 67: sanad-dev Runtime Ownership and Background Usability Failures

## 1. الهدف

تسجيل المشكلات التي ظهرت أثناء تشغيل runtime معزولة من worktree عبر
`sanad-dev`، دون اعتماد حل أو تغيير معماري في هذه المهمة. يجب أن تصبح كل مشكلة
أدناه قابلة لإعادة الإنتاج آليًا قبل بدء الإصلاح اللاحق.

## 2. سياق الحادثة

- worktree: `51-52-replay-and-fork`
- الوضع المطلوب: `--driver --no-cloud`
- Sanad Home المطلوب: `<explicit-test-home>`
- كانت runtime أخرى من worktree مختلفة تعمل بالتوازي.
- أرقام المنافذ وPIDs المذكورة في الأدلة أمثلة من الحادثة وليست قيمًا ثابتة.

## 3. سجل المشكلات

### P1 — التشغيل المباشر في الخلفية ينتهي بصمت

**إعادة الإنتاج**

```text
sanad-dev run --driver --no-cloud --home <home> &
```

**الفعلي**

- يعود shell بلا output ولا خطأ.
- لا تبقى Agent أو Client حية.
- يعيد `sanad-dev status` حالة `not started`.
- لا توجد رسالة تشرح أن بيئة shell المؤقتة أو غياب TTY أنهى التشغيل.

**المتوقع**

- إما تشغيل detached مدعوم يبقى حيًا، أو رفض واضح قبل الإطلاق يشرح الطريقة
  الرسمية البسيطة للتشغيل في الخلفية.

### P2 — التشغيل غير التفاعلي قد يفشل بلا أي log

**إعادة الإنتاج**

```text
nohup sanad-dev run --driver --no-cloud --home <home> ... &
```

**الفعلي**

- تنتهي العملية سريعًا.
- قد يبقى ملف الإخراج فارغًا.
- لا يسجل `sanad-dev` سبب الخروج أو المرحلة التي فشلت.

**المتوقع**

- كل خروج قبل اكتمال Agent وClient يسجل سببًا وexit status ومرحلة startup.

### P3 — EOF في terminal قد يترك Agent orphaned

**إعادة الإنتاج**

- تشغيل `sanad-dev run` داخل pseudo-terminal يتلقى EOF بعد بدء Agent وقبل
  اكتمال Client.

**الفعلي**

- يخرج launcher.
- تبقى Agent أو hot-restart supervisor حية.
- يصنف status runtime لاحقًا `orphaned` أو `manual`.
- لا توجد عملية cleanup تلقائية للـchild التي بدأها launcher غير المكتمل.

**المتوقع**

- خروج launcher أثناء startup ينهي كل العمليات التي أنشأها، أو يحول الملكية
  إلى سجل durable واضح يمكن التحكم به طبيعيًا.

### P4 — إيقاف child لا يوقف hot-restart supervisor

**الفعلي**

- إنهاء daemon child التي تستمع على المنفذ يؤدي إلى إعادة spawn منها.
- تبقى طبقات `fvm dart run` وDart supervisor حية بعد اختفاء launcher.
- يتطلب التنظيف اليدوي تتبع شجرة parent ثم إنهاء supervisor الأعلى.

**المتوقع**

- `sanad-dev` يعرف process group كاملًا وينهيه كوحدة واحدة دون تتبع PID يدوي.

### P5 — status يناقض الأدلة الحية عند استخدام Home صريحة

**السياق**

```text
sanad-dev run --driver --no-cloud --home <explicit-test-home>
```

**الفعلي**

- logs تثبت بدء Agent، اتصال Client، وتحميل sessions.
- `lsof` يثبت أن منافذ Agent وVM Service تستمع.
- VM Driver يتصل ويقرأ الواجهة بنجاح.
- مع ذلك قد يعيد `sanad-dev status`:
  - `ownership conflict`
  - `runtime class: unverifiable`
  - `Agent PID: stopped`
  - Client واحدة ذات `launch profile incomplete`.

**المتوقع**

- status يطابق العمليات والمنافذ وlauncher identity وruntime nonce الفعلية.
- `--home` الصريحة لا تكسر تسجيل launch profile أو اكتشاف Agent.

### P6 — client من worktree الحالية تُعرض كأنها من worktree أخرى

**الفعلي**

- يفشل `sanad-dev logs client` برسالة عدم وجود client للـworktree الحالية.
- تسرد الرسالة نفسها VM port ومسار client الصحيحين تحت
  `Active instances in other worktrees`.

**المتوقع**

- مطابقة source path وworktree hash وlauncher id تصنف client تحت مالكها الصحيح.

### P7 — stop يرفض ولا يقدم cleanup قابلًا للتنفيذ

**الحالات المرصودة**

- `orphaned`: يرفض `sanad-dev stop` بسبب stale launcher lease.
- بعد `doctor --fix`: تصبح runtime `manual`، ثم يرفض `sanad-dev stop agent` لأن
  live launcher lease غير موجودة.
- `unverifiable`: يرفض stop بسبب incomplete client launch profile.

**الفعلي**

- `doctor` يصف الحالة لكن لا يقدم أمر target cleanup ناجحًا.
- `doctor --fix` قد يزيل stale record دون إيقاف process الحية.
- يبقى المستخدم مضطرًا إلى `lsof` و`ps` و`kill` اليدوية.

**المتوقع**

- لكل تصنيف غير managed مسار cleanup واحد واضح، محدود بالهدف، وآمن من قتل
  runtime تخص worktree أخرى.

### P8 — restart لا يجد Agent الموجودة على المنفذ المحدد

**الفعلي**

- محاولة restart للـAgent الحالية تفشل برسالة عدم وجود instance على منفذها.
- تعرض الرسالة instance من worktree أخرى فقط، رغم أن `lsof` يثبت listener
  للمنفذ المطلوب.

**المتوقع**

- التحديد الصريح بالمنفذ مع ownership evidence الصحيحة يجد الـAgent المقصودة،
  أو يعرض سبب رفض دقيقًا بدل الادعاء بأنها غير موجودة.

### P9 — الانتقال من `starting` إلى `managed` غير مستقر في status

**الفعلي**

- أثناء build/restart قد ينتقل status بين:
  `starting`، `orphaned`، `manual`، `unverifiable`، و`managed`.
- بعض هذه الحالات تظهر بينما launcher والعمليات ما زالت حية وتعمل طبيعيًا.
- polling في لحظة انتقالية قد يدفع المستخدم إلى cleanup خاطئ.

**المتوقع**

- startup/restart state machine تميز الحالة الانتقالية عن فقد الملكية الحقيقي،
  مع مهلة bounded قبل إعلان orphaned أو unverifiable.

### P10 — فشل startup لا يحافظ دائمًا على Home المطلوبة في التشخيص

**الفعلي**

- بعد فشل أمر background باستخدام `--home <explicit-test-home>`، قد
  يعرض status التالي worktree home الافتراضية لأن runtime لم تسجل أصلًا.
- لا يوضح output أن Home المعروضة هي fallback للتشخيص وليست Home الطلب الفاشل.

**المتوقع**

- يحتفظ سجل محاولة startup الفاشلة بخياراتها غير السرية، أو يميز بوضوح بين
  requested Home وresolved active Home وfallback Home.

### P11 — `sanad-dev ui` تعمل مع worktree واحدة فقط

**السياق**

- توجد runtimes متزامنة في worktrees مختلفة.
- كل runtime شُغلت باستخدام `sanad-dev run --driver` ولها VM Service وهوية
  worktree مستقلتان.

**الفعلي**

- تشغيل `--driver` في worktree قد يجعل `sanad-dev ui` ترفض العمل في worktree
  أخرى كانت تعمل مسبقًا.
- قد تظهر رسالة عدم وجود client للـworktree الحالية، أو تُصنف client الصحيحة
  ضمن worktree أخرى، أو تصبح launch profile غير قابلة للتحقق.
- عمليًا تصبح أوامر `snapshot/find/tap/enter-text/scroll/screenshot` متاحة
  لworktree واحدة فقط بدل دعم runtimes متوازية.
- تشغيل أو إعادة تشغيل driver في worktree قد يوقف أو يعطل قابلية التحكم في
  driver التابعة لworktree أخرى.

**المتوقع**

- كل worktree تملك driver وVM Service وسجل discovery مستقلًا.
- يستنتج `sanad-dev ui` runtime من worktree التي صدر منها الأمر، دون استخدام
  client أحدث أو global singleton مشترك.
- يمكن تنفيذ أوامر UI بالتوازي على worktrees متعددة دون إيقاف أو إبطال أو
  إعادة تصنيف أي driver أخرى.
- عند وجود غموض، يعرض الأمر قائمة runtimes المطابقة وأدلة الملكية ولا يغير
  حالة أي runtime.

## 4. نتيجة الفرز الحالية

| المشكلة | التصنيف | الدليل/الإجراء |
|---|---|---|
| P1 | عطل حالي قيد الإصلاح | أضيف `run --background` وhandshake؛ بقي اختبار shell مؤقت فعلي. |
| P2 | عطل حالي قيد الإصلاح | startup attempt مرحلية تمنع الفشل الصامت بعد بدء orchestration. |
| P3 | مُصلح ومثبت حيًا | SIGINT/SIGTERM/SIGHUP أثناء startup تسجل failure ثم تنظف الشجرة؛ SIGHUP بعد managed يمر عبر cleanup العادي. |
| P4 | مغطى قائمًا | `terminateSanadDevProcessTree` يتتبع supervisor والأطفال، مع اختبار ترتيب Unix قائم. |
| P5–P6 | مغطى قائمًا ويحتاج parity fixture | ownership الحالية تربط Home/source/workspace/launcher/nonce والاختبارات تثبت عزل worktree. |
| P7 | مُصلح آليًا | doctor يحافظ على lease أمام أي endpoint حية ويعرض next action محددة؛ target cleanup يعيد التحقق قبل الإشارة. |
| P8 | مغطى قائمًا ويحتاج regression صريح | selector يطابق workspace والport مع fail-closed ownership. |
| P9 | مُصلح آليًا | محاولة `starting` حديثة تعرض مرحلة انتقالية حتى ست دقائق؛ بعدها تعود ownership الحية للتصنيف الطبيعي. |
| P10 | مُصلح آليًا | locator الخاص بالworktree يستعيد requested/resolved Home بعد فشل Home صريحة. |
| P11 | مُصلح على مستوى الاختيار | `ui` يختار owned `driver_main.dart` فقط؛ بقي اختبار driverين فعليين بالتوازي. |

## 5. القرارات المقفلة ونطاق التنفيذ

- الأمر الرسمي المقفل للتشغيل الخلفي هو `sanad-dev run --background`؛ ينتظر
  handshake محدودًا حتى `managed` أو فشل مرحلي، ولا يُطلب من المستخدم تركيب
  `nohup` أو `screen` أو `script` يدويًا.
- launcher واحدة durable تبقى مالكة لكل process tree. لا يتحول Agent أو Client
  إلى manual runtime لمجرد انفصال الطرفية.
- فشل startup يُحفظ في سجل محاولة غير سري يضم المرحلة والسبب وexit status وHome
  المطلوبة/المحلولة، بينما تبقى journals للتشخيص وليست دليل ملكية.
- كل عمليات status/logs/restart/stop/ui تختار runtime أولًا بهوية worktree، ثم
  تتحقق من launcher id والnonce والHome والمنافذ؛ لا يوجد global latest-client.
- cleanup لا يقتل process بالمنفذ أو source path وحدهما، ولا يلمس runtime تخص
  worktree أخرى.
- لا تشمل المهمة تغيير daemon restart checkpoint أو بروتوكول source handoff إلا
  إذا أثبت اختبار regression أن العطل يقع في حد الملكية المشترك نفسه.

## 6. بوابات التنفيذ

### G0 — الفرز وإعادة الإنتاج الحتمية

- [x] إنشاء Worktree مستقلة من commit `1190346` دون نقل تغييرات Worktree المصدر غير الملتزم بها.
- [x] إثبات مرور baseline الحالي لاختبارات runtime context والownership/process selection (34 اختبارًا).
- [x] إضافة تحقق معزول يغطي shell طويل/قصير العمر، غياب TTY، وفقد terminal عبر SIGHUP أثناء startup دون لمس runtime المستخدم.
- [x] تصنيف P1–P11 إلى: عطل حالي، مغطى بإصلاح قائم، أو يحتاج regression إضافية.

### G1 — تشغيل خلفي رسمي وتشخيص startup

- [x] إضافة أمر خلفي بسيط مملوك لـ`sanad-dev` مع readiness/failure handshake محدود الزمن.
- [x] حفظ startup attempt آمن يميز requested Home وresolved Home وfallback التشخيصي.
- [x] ضمان أن كل خروج قبل managed يسجل المرحلة والسبب وexit status وينظف process tree كاملة.
- [x] توثيق الأمر وسلوك logs/status عند النجاح والفشل.

### G2 — استقرار الملكية والحالة والتنظيف

- [x] تثبيت state machine الانتقالية ومنع تصنيف `starting` مؤقتًا كـorphaned/manual/unverifiable.
- [x] مطابقة Home الصريحة وsource/worktree/launcher evidence في status/logs/restart/stop.
- [x] جعل doctor يعرض إجراء cleanup واحدًا آمنًا وقابلًا للتنفيذ لكل حالة قابلة للإصلاح.
- [x] إثبات إنهاء supervisor والأطفال كوحدة واحدة وعدم الإضرار بأي runtime أخرى.

### G3 — تعدد UI drivers

- [x] إزالة أي اختيار global/latest-client من مسار `sanad-dev ui`.
- [x] تغطية driver متزامنة في worktree اثنتين مع snapshot/find/screenshot وإعادة تشغيل إحداهما.
- [x] إثبات بقاء runtime الأخرى قابلة للتحكم ودون إعادة تصنيف.

### G4 — التحقق والتوثيق

- [x] تمرير analyzer والاختبارات المركزة مع output محدود.
- [x] تحديث وثائق التصميم وQA ومرجع CLI بما يطابق السلوك المنفذ.
- [x] تشغيل `graphify update .` ومراجعة diff النهائي.
- [x] تنفيذ تحقق runtime معزول فقط؛ تم كل stop بعد موافقة المستخدم الصريحة ولم يُستخدم switch.

### G5 — الكتابة البشرية والآلية في driver

- [x] تعطيل Flutter Driver text-entry emulation افتراضيًا حتى تبقى قناة نظام التشغيل فعالة.
- [x] إضافة Sanad VM extension لإدخال النص عبر `EditableTextState` دون استبدال `SystemChannels.textInput`.
- [x] جعل `sanad-dev ui enter-text` يفضل الامتداد الجديد مع fallback متوافق للإصدارات السابقة.
- [x] إثبات آلي وحي أن `enter-text` يغيّر قيمة `chat_input` إلى `Automated driver text works` ثم التحقق منها بـ`find`.
- [x] تشغيل Client مرئية بـ`--driver`؛ أكد المستخدم أن ضغطات الأحرف البشرية تُكتب طبيعيًا بعد نجاح الإدخال الآلي.
- [x] تحديث مواصفات Driver وQA ومهارة الاختبار وتشغيل analyzer والاختبارات وGraphify.

## 7. مصفوفة إعادة الإنتاج المطلوبة

- [x] تشغيل foreground من Terminal بشرية مع Agent-only managed ثم stop رسمي.
- [x] تشغيل background من shell طويلة العمر حتى اكتمال handshake.
- [x] تشغيل background من shell مؤقتة تنتهي فورًا.
- [x] startup مع وبدون TTY، مع فقد terminal/SIGHUP أثناء foreground startup.
- [x] startup مع worktree home الافتراضية.
- [x] startup مع `--home` صريحة.
- [x] runtime واحدة مقابل runtimes متوازية في worktrees مختلفة.
- [x] تشغيل `--driver` في worktree اثنتين بالتزامن وتنفيذ `sanad-dev ui snapshot`
      و`find` و`screenshot` من كل worktree مع إثبات بقاء الأخرى قابلة للتحكم.
- [x] إعادة تشغيل driver في worktree مع استمرار UI commands في الأخرى دون انقطاع.
- [x] فقد terminal/SIGHUP أثناء بدء Agent وقبل اكتمال Client.
- [x] خروج Client بعد managed مع بقاء Agent managed، ثم إعادة ضم Client.
- [x] خروج Agent managed مع بقاء Client managed، واختبارات process-tree تغطي supervisor/child.
- [x] stale launcher record مع process حية وبدون process حية عبر doctor predicate والاختبارات.

## 8. معايير القبول

- [x] يوجد أمر رسمي واحد وبسيط لتشغيل runtime في الخلفية، أو خطأ صريح يحدد أن
      التشغيل attached فقط ويقدم البديل الرسمي.
- [x] لا يفشل startup بصمت؛ كل فشل يحمل المرحلة والسبب وexit status.
- [x] status لا يناقض listener/VM/launcher evidence بعد انتهاء مهلة startup.
- [x] `--home` الصريحة تبقى جزءًا صحيحًا من runtime identity والتشخيص.
- [x] logs/status/restart/stop تختار worktree نفسها بصورة متسقة.
- [x] `sanad-dev ui` تدعم drivers متزامنة في worktrees متعددة، وتختار client
      المطابقة للcaller worktree دون تعطيل أو إيقاف أو إعادة تصنيف الأخريات.
- [x] restart أو stop لdriver في worktree لا يقطع UI commands في أي worktree أخرى.
- [x] stop ينظف process group المملوكة كاملة، بما فيها supervisors والأطفال.
- [x] doctor يقدم إجراء cleanup آمنًا وقابلًا للتنفيذ لكل حالة غير managed.
- [x] cleanup لا يوقف Agent أو Client تخص worktree أخرى.
- [x] اختبارات آلية مع تحقق حي معزول تغطي مصفوفة إعادة الإنتاج دون تثبيت PIDs أو
      منافذ في التنفيذ؛ أرقام الأدلة الحية مؤقتة فقط.

## 9. تعريف الاكتمال

- [x] كل معيار قبول مرتبط باختبار آلي أو دليل تحقق معزول محدد.
- [x] `fvm flutter analyze` يمر، وتمُر اختبارات `sanad-dev` المركزة على macOS
      مع بقاء مصفوفة CI العابرة للمنصات قابلة للتشغيل.
- [x] وثائق `docs/technical/` و`docs/qa_maintenance/` ومرجع CLI محدثة دون
      إنشاء عقد منافس في README.
- [x] لا توجد تغييرات غير لازمة في حدود restart أو source handoff.
- [x] Graphify محدث، والـdiff النهائي خالٍ من أسرار ومسارات مستخدم ثابتة.
- [x] لا commit أو push دون موافقة المستخدم.
