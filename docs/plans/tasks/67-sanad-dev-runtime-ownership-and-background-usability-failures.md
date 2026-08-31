---
title: "Task 67: sanad-dev Runtime Ownership and Background Usability Failures"
description: "سجل مشكلات قابل لإعادة الإنتاج لفشل تشغيل sanad-dev في الخلفية، وتصنيف ownership، والتنظيف، والتحكم في runtime."
status: "proposed"
current_gate: "problem inventory"
review_remaining: "100%"
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

## 4. مصفوفة إعادة الإنتاج المطلوبة

- [ ] تشغيل foreground من Terminal بشرية.
- [ ] تشغيل background من shell طويلة العمر.
- [ ] تشغيل background من shell مؤقتة تنتهي فورًا.
- [ ] startup مع وبدون TTY.
- [ ] startup مع worktree home الافتراضية.
- [ ] startup مع `--home` صريحة.
- [ ] runtime واحدة مقابل runtimes متوازية في worktrees مختلفة.
- [ ] تشغيل `--driver` في worktree اثنتين بالتزامن وتنفيذ `sanad-dev ui snapshot`
      و`find` و`screenshot` من كل worktree مع إثبات بقاء الأخرى قابلة للتحكم.
- [ ] إعادة تشغيل driver في worktree مع استمرار UI commands في الأخرى دون انقطاع.
- [ ] EOF أثناء بدء Agent وقبل Client.
- [ ] خروج Client أثناء startup وبعد managed.
- [ ] خروج Agent child مع بقاء supervisor.
- [ ] stale launcher record مع process حية وبدون process حية.

## 5. معايير القبول للإصلاح المستقبلي

- [ ] يوجد أمر رسمي واحد وبسيط لتشغيل runtime في الخلفية، أو خطأ صريح يحدد أن
      التشغيل attached فقط ويقدم البديل الرسمي.
- [ ] لا يفشل startup بصمت؛ كل فشل يحمل المرحلة والسبب وexit status.
- [ ] status لا يناقض listener/VM/launcher evidence بعد انتهاء مهلة startup.
- [ ] `--home` الصريحة تبقى جزءًا صحيحًا من runtime identity والتشخيص.
- [ ] logs/status/restart/stop تختار worktree نفسها بصورة متسقة.
- [ ] `sanad-dev ui` تدعم drivers متزامنة في worktrees متعددة، وتختار client
      المطابقة للcaller worktree دون تعطيل أو إيقاف أو إعادة تصنيف الأخريات.
- [ ] restart أو stop لdriver في worktree لا يقطع UI commands في أي worktree أخرى.
- [ ] stop ينظف process group المملوكة كاملة، بما فيها supervisors والأطفال.
- [ ] doctor يقدم إجراء cleanup آمنًا وقابلًا للتنفيذ لكل حالة غير managed.
- [ ] cleanup لا يوقف Agent أو Client تخص worktree أخرى.
- [ ] اختبارات آلية تغطي مصفوفة إعادة الإنتاج السابقة دون الاعتماد على PIDs أو
      منافذ ثابتة.
