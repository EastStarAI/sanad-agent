---
title: "Task 76: Bundled Product Skills Lifecycle"
description: "تضمين حزم مهارات مختارة من المصدر التطويري الواحد داخل ملف الوكيل التنفيذي، ثم تثبيتها وتحديثها وحذفها بأمان داخل SANAD_HOME."
status: "completed"
current_gate: "done"
priority: "high"
depends_on: "Existing SkillRegistry and Sanad Home boundary"
file_budget: 24
reference_grounding: "required"
evidence_id: "bundled-product-skills-v1"
design_contract: "docs/agent_engine/capability_runtime.md"
qa_contract: "docs/qa_maintenance/bundled_product_skills_qa.md"
remaining_estimate_percent: 0
---

# Task 76: Bundled Product Skills Lifecycle

## 1. الهدف

إتاحة مجموعة مختارة من المهارات العامة مع كل إصدار للوكيل مع الحفاظ على ملف
توزيع تنفيذي واحد. تبقى `.agents/skills/` المصدر الوحيد للمهارة في المستودع
لاستخدامها في تطوير Sanad وفي المنتج، ويختار manifest صريح المهارات التي تدخل
الإصدار. يستخرج الوكيل الحزم المختارة كاملة إلى `<SANAD_HOME>/skills/`، ويدير
تثبيتها وتحديثها وحذفها دون إتلاف مهارات المستخدم أو إبطاء التشغيل المعتاد.

المهارات الأولية المختارة:

- `skill-creator`
- `find-skills`
- `agent-browser` (المصدر الرسمي المرخّص؛ استُبعدت نسخة `agent-browser-automation`
  الوسيطة لغياب ترخيص إعادة توزيع واضح)

## 2. القرارات المثبتة

- [x] نفس مدير المهارات يعمل في binary منشور وفي تشغيل المصدر وبيئات التطوير.
- [x] الوجهة دائمًا `<SANAD_HOME>/skills/`؛ worktrees والاختبارات تستخدم Home
      المعزول الخاص بها ولا تكتب في Home المستخدم الأساسي.
- [x] `.agents/skills/` مصدر وحيد؛ لا توجد نسخة مصدرية ثانية لمهارات المنتج.
- [x] manifest اختياري يحدد ما يدخل المنتج بدل hardcode أسماء المهارات داخل
      منطق المدير.
- [x] تُضمّن شجرة كل مهارة كاملة، بما فيها references/scripts/assets/licenses،
      داخل executable واحد ثم تُستخرج وقت التشغيل.
- [x] التشغيل المعتاد يقرأ revision صغيرة فقط؛ المصالحة الكاملة لا تحدث إلا
      عند غياب/فساد الحالة أو تغير revision الحزمة المضمّنة.
- [x] المرحلة الحالية تربط install/update/remove بحزمة إصدار الوكيل، دون تنزيل
      runtime مباشر من GitHub.
- [x] لا تُستبدل أو تُحذف بصمت مهارة مدارة عدّلها المستخدم.

## 3. معايير القبول

- [x] يحتوي الإصدار النهائي للوكيل على ملف executable واحد ولا يحتاج ملفات
      مهارات جانبية أو اتصالًا بالشبكة عند التثبيت.
- [x] يبني generator حتمي الحزمة من المهارات المحددة فقط في manifest ويشمل كل
      الملفات والمسارات الآمنة وبصمات SHA-256 والبيانات اللازمة للصلاحيات.
- [x] ينجح أول تشغيل في تثبيت المهارات الثلاث كاملة داخل `SANAD_HOME/skills`.
- [x] يعمل السلوك نفسه من binary ومن المصدر، مع احترام Home المعزول للعملية.
- [x] يتخطى fast path المصالحة ومسح ملفات المهارات عندما تتطابق bundle revision.
- [x] يحدّث الإصدار الجديد المهارة المدارة غير المعدلة تحديثًا ذريًا وقابلًا
      للاستعادة عند فشل الكتابة أو الانقطاع.
- [x] يحافظ التحديث على المهارة المعدلة من المستخدم ولا يعيد تصنيفها كنسخة
      آمنة للاستبدال.
- [x] يحذف الإصدار الجديد المهارة التي أزيلت من الحزمة فقط إذا كانت مدارة وغير
      معدلة، ويحافظ على النسخة المعدلة كمهارة user-owned.
- [x] لا يعيد الإصدار نفسه مهارة حذفها المستخدم عمدًا، وتبقى سياسة الإزالة
      والترقية غير ملتبسة عبر revisions.
- [x] كل كتابة وحذف يمر عبر Sanad Home boundary ويرفض traversal وsymlink وأي
      هدف ليس ابنًا صارمًا لمجلد skills.
- [x] فساد state/manifest أو فشل مزامنة مهارة لا يمنع بدء الوكيل، ولا يُسجل
      revision الجديدة قبل اكتمال المصالحة بنجاح.
- [x] يكتشف `SkillRegistry` مهارات المستخدم من `SANAD_HOME/skills` مع الحفاظ
      على precedence والتوافق المقصودين.
- [x] تُحفظ تراخيص ونسب المصادر الخارجية المطلوبة، وتثبت المهارات المستوردة
      عند revisions مراجعة وقابلة للتتبع.
- [x] تغطي الاختبارات install/update/remove، تعديلات وحذف المستخدم، fast path،
      الفشل والاستعادة، أمان المسارات، المصدر، وbinary مبني فعليًا.

## 4. بوابات التنفيذ

### Gate P0 — تثبيت النطاق والخطة

- [x] إنشاء worktree نظيفة من أحدث `origin/main` وفرع المهمة.
- [x] تثبيت مصدر واحد للمهارات وسياسة binary/source/SANAD_HOME.
- [x] تثبيت سياسة الأداء: revision fast path ثم reconciliation مشروطة.
- [x] تثبيت النطاق الأولي بثلاث مهارات وسياسة عدم الكتابة فوق تعديل المستخدم.
- [x] كتابة الهدف ومعايير القبول والبوابات وسجل التقدم.

#### P0 Exit

- [x] لا يتطلب بدء R0 قرار منتج إضافيًا.
- [x] الخطة تفصل source selection وbuild embedding وruntime reconciliation.

### Gate R0 — التأصيل المرجعي والأمن والتراخيص

- [x] إنشاء evidence packet محلية للمهمة وتثبيت revisions المرجعية.
- [x] قراءة implementation والاختبارات الإلزامية وتسجيل مصفوفة
      `Adopt / Adapt / Reject` محلية.
- [x] تثبيت invariants: manifest tracking، user modification protection، atomic
      replacement، strict-child deletion guard، crash recovery، وfast startup.
- [x] استنساخ مصادر المهارات الثلاثة عبر Git وفحص الشجرة الكاملة والتراخيص
      والملفات التنفيذية قبل نسخ أي محتوى.
- [x] تثبيت revision المصدر لكل مهارة وتجهيز مقارنة تطابق النسخة المستوردة.
- [x] إجراء فحص أولي لمحتوى المهارات والـscripts وعدم تشغيل كود المصدر الخارجي.

#### R0 Exit

- [x] evidence packet حالتها `ready` وسجل التنفيذ يحمل fingerprint.
- [x] لا يوجد تعارض ترخيص أو محتوى غير محسوم؛ استُبدلت المهارة الوسيطة غير
      المرخصة بالمهارة الرسمية المرخصة من المصدر الأصلي.
- [x] توجد مصفوفة ملفات ومصادر موثقة محليًا لكل مهارة.

### Gate A1 — استيراد المهارات وmanifest المنتج

- [x] إضافة الحزم الثلاث كاملة إلى `.agents/skills/` مع التراخيص والنسب المطلوبة.
- [x] إضافة manifest declarative يختار المهارات المضمنة فقط.
- [x] التحقق من أن مهارات التطوير الأخرى لا تدخل الحزمة.
- [x] إضافة validator يفشل عند اسم مكرر أو `SKILL.md` مفقود أو مسار غير آمن أو
      symlink أو ملف غير مدعوم.

#### A1 Exit

- [x] المصدر واحد ولا توجد نسخة مهارة مكررة داخل المستودع.
- [x] validator ينتج inventory حتمية للمهارات الثلاث وكل ملفاتها.

### Gate A2 — توليد حزمة مضمنة داخل executable واحد

- [x] إضافة generator وقت البناء يقرأ manifest ويحوّل الملفات المختارة إلى
      تمثيل Dart حتمي ومضغوط أو bounded مناسب للتضمين.
- [x] تضمين bundle revision وSHA-256 وقائمة الملفات وبيانات الصلاحيات اللازمة.
- [x] ربط generator بمسارات build/release الفعلية ومنع generated drift في CI.
- [x] إثبات أن `fvm dart compile exe` ينتج ملفًا واحدًا يعمل دون شجرة assets.

#### A2 Exit

- [x] البناء قابل لإعادة الإنتاج ولا يعتمد على الشبكة.
- [x] binary المنسوخ منفردًا يستطيع الوصول إلى الحزمة المضمّنة.

### Gate A3 — مدير install/update/remove الآمن

- [x] تنفيذ owner مستقل للمصالحة خارج entry-point composition.
- [x] حفظ state ذرية تحت Sanad Home تشمل bundle revision وملكية وبصمة الأصل
      وحالة حذف المستخدم اللازمة.
- [x] تنفيذ fresh install للحزمة متعددة الملفات.
- [x] تنفيذ update ذري مع backup/restore وعدم استبدال user-modified content.
- [x] تنفيذ remove للمدار غير المعدل فقط، وتحويل المعدل إلى user-owned.
- [x] حماية كل مسار ورفض absolute/traversal/symlink وأي حذف خارج skills.
- [x] عدم تسجيل revision الجديدة عند فشل جزئي، مع retry آمن في التشغيل التالي.

#### A3 Exit

- [x] جميع انتقالات lifecycle idempotent وقابلة للتعافي بعد الانقطاع.
- [x] لا توجد عملية حذف تستطيع الوصول إلى `SANAD_HOME` نفسه أو إخوته.

### Gate A4 — ربط startup والاكتشاف مع fast path

- [x] تشغيل نفس manager بعد `SanadHomeBootstrap.prepareAll()` في source وbinary.
- [x] جعل fast path مقارنة bounded لrevision دون enumeration أو hashing للشجرة.
- [x] احتواء أخطاء المصالحة مع warning نظيف واستمرار startup.
- [x] جعل user-scope lookup يقرأ `SANAD_HOME/skills` بدل الاعتماد غير الصحيح على
      `HOME` فقط، مع الحفاظ على precedence والتوافق المقصودين.
- [x] منع supervisor parent الخفيف من تكرار المصالحة التي يملكها child.

#### A4 Exit

- [x] التشغيل غير المتغير لا يقرأ محتوى أي مهارة ولا يحسب hash لها.
- [x] المصدر وbinary وworktree والاختبارات تختار Home الصحيحة بالطريقة نفسها.

### Gate A5 — التحقق الشامل والتوثيق

- [x] unit tests للstate codec/path validation والfast path، وفحص generator/manifest
      الحتمي ضمن CI وrelease؛ قررت المراجعة النهائية أن negative generator CLI
      fixtures إضافية غير لازمة لأن فروع الرفض مباشرة وdrift check مؤتمت.
- [x] filesystem tests للتثبيت والتحديث والحذف والتعديل والحذف اليدوي والتعارض.
- [x] failure/recovery coverage للنسخ المرحلي وbackup وحدود state المتقطعة؛ قررت
      المراجعة النهائية أن state-write fault injection إضافية ستكرر atomic-write
      boundary coverage دون فائدة تناسب كلفة injectable filesystem جديدة.
- [x] startup ownership مثبت بأن المصالحة بعد child bootstrap ولا ينفذها supervisor
      parent الخفيف، مع binary first/second-run smoke للـfast path.
- [x] compile binary ثم تشغيله من مجلد بلا source/assets مع `SANAD_HOME` مؤقت
      والتحقق من المهارات الثلاث وكل الملفات.
- [x] محاكاة حزمتين v1/v2 في الاختبارات لإثبات install/update/remove عمليًا.
- [x] تشغيل analyzer والاختبارات المركزة ثم full fast suite وفق blast radius.
- [x] تحديث design وQA وuser/product docs و`docs/llms.txt` عند إضافة صفحات جديدة.
- [x] تشغيل `graphify update .` ومراجعة diff النهائية والعقود، وإغلاق
      reference-parity audit في run record المحلية دون deviations.

#### A5 Exit / Definition of Done

- [x] جميع معايير القبول مؤشرة ومثبتة باختبارات.
- [x] لا secrets ولا absolute repository paths ولا network dependency في البناء
      أو التشغيل.
- [x] الاختبارات المعلنة تمر بمخرجات bounded وتظل حالة الخروج محفوظة.
- [x] PR تحتوي وصف القرار، التراخيص، تغييرات lifecycle، ونتائج التحقق الدقيقة.

### Gate A6 — تسليم Pull Request جاهزة للدمج

- [x] مراجعة status/diff وعدم وجود ملفات مؤقتة أو تغييرات خارج النطاق.
- [x] عرض نتائج التحقق النهائية والحصول على إذن المستخدم قبل commit/push.
- [x] بعد الإذن: commit مركزة، push، وإنشاء PR بوصف ومعايير تحقق كاملة.
- [x] فحص checks بأسلوب polling محدود دون watch وإصلاح أي فشل متعلق بالمهمة.

#### A6 Exit

- [x] PR مفتوحة، checks المطلوبة خضراء، ولا توجد ملاحظات دمج غير معالجة.

## 5. تصميم الحالة المبدئي

يحتفظ مدير المهارات بملف state صغير وآمن تحت `SANAD_HOME/skills`. يحمل على
الأقل schema version وbundle revision، ولكل مهارة: المعرّف، مسار التثبيت، بصمة
النسخة الأصلية التي ثُبتت، وحالة lifecycle اللازمة للتمييز بين managed،
user-modified/user-owned، وuser-deleted. تفاصيل schema النهائية تُثبت في R0/A3
وتوثق في design contract قبل اعتماد التنفيذ.

## 6. خارج النطاق

- متجر مهارات بعيد أو تحديث مستقل عبر الشبكة.
- واجهة Client لإدارة المهارات أو حل التعارضات.
- تشغيل scripts المرفقة أثناء التثبيت.
- تنزيل المهارات من GitHub عند تشغيل المستخدم.
- إعادة كتابة محتوى المهارات الخارجية لتغيير سلوكها دون مراجعة مستقلة.

## 7. الملفات المتوقعة

- `.agents/skills/skill-creator/**`
- `.agents/skills/find-skills/**`
- `.agents/skills/agent-browser-automation/**`
- manifest منتج تحت owner البناء المناسب
- generator وأدوات validation تحت `agent/tool/` أو `scripts/` حسب ownership
- generated embedded bundle تحت `agent/lib/` وفق سياسة generated outputs
- manager/state models تحت `agent/lib/capabilities/skills/`
- ربط composition محدود في `agent/bin/sanad_agent.dart`
- اختبارات unit/integration وbinary release verification
- `docs/agent_engine/capability_runtime.md`
- `docs/qa_maintenance/bundled_product_skills_qa.md`
- `docs/operations/user_guide.md`
- أقرب `AGENTS.md` فقط إذا تغير invariant دائم أو أصبح نص قائم stale

## 8. سجل التقدم

```text
Date: 2026-08-12
Gate/status: A6 complete; explicit merge approval received for PR #90
Estimated remaining: 0%
Files changed: three imported skill trees; selective manifest/generator/generated Dart; lifecycle manager; Sanad Home directory primitives; startup/registry integration; focused tests; CI/release smoke; design/product/user/QA docs; task and llms index.
Verification: branch safely rebased from two commits behind to exact origin/main with all work restored and no conflicts; evidence ready at sha256:8833b7e3364dcb22b3a7fc1c44738d6163bae245442f1a5932b0cfe8d5c96246; mandatory reference files match pinned Git objects; imported source/license and executable-mode inventories match exactly; generator check passes for 3 skills/22 files at revision 552d526934cebf9b68ad326e77e3d28082d95d251591ee7046fa57ebc1dcdfb0; analyzer clean; 30 focused tests pass; prior full agent suite passed 1119 with 4 skipped; prior standalone binary 13,648,016 bytes extracted 23 files and second-run fast path; docs lint, graphify update, workflow YAML, diff check, and secret/path/network review pass.
Findings: reference-parity audit has no deviations; official Apache-2.0 agent-browser replaces the unlicensed intermediary derivative; source and binary use one manager and active SANAD_HOME; unchanged starts do not traverse skills; user edits/deletion/collisions survive; unchanged removed skills are deleted safely. Additional negative generator fixtures and direct state-write fault injection were reviewed and rejected as duplicative relative to their harness cost.
Remaining: none for implementation or verification; explicit merge approval received. Worktree and branch cleanup remain forbidden until a separate explicit post-merge instruction.
Next gate: squash merge PR #90, verify the landed commit, and retain the worktree and branches.
```
