---
title: "Task 83f: Owner-Controlled Host Capability Discovery"
description: "إضافة أداة daemon محدودة لاستكشاف executables من PATH الموروث، مع سياسة مالك تحذف الأداة من catalog بالكامل عند التعطيل وتحمي Workspaces المشتركة."
status: "pending"
current_gate: "Waiting"
priority: "high"
depends_on: "83a, 83b, 83e"
file_budget: 13
---

# Task 83f: اكتشاف قدرات المضيف المتحكم به من المالك

## 1. الهدف

تمكين الوكيل، عندما يسمح المالك وتكون القدرة لازمة فعلًا، من الاستعلام typed عن executable محدد أو قائمة محدودة من أدوات PATH دون System Prompt hints أو arbitrary host browsing. تختفي الأداة عندما تملك الجلسة أصلًا وصولًا مكافئًا إلى Host `PATH`، وكذلك عند التعطيل أو للمستخدمين غير الموثوقين، حتى لا تستهلك context بلا فائدة.

## 2. Gate F0 — threat model وtool contract

- [ ] تحديد المعلومات غير السرية المسموحة: executable name، canonical path، availability/source class اللازمة فقط.
- [ ] تحديد query modes والحدود؛ منع recursive directory listing وقراءة الملفات وdump كامل للenvironment.
- [ ] عدم تشغيل binary أو `--version` أو login shell/startup scripts أثناء discovery.
- [ ] تعريف symlink/path normalization وWindows PATHEXT/App Paths behavior الآمن.
- [ ] تثبيت أن discovery لا تمنح execution ولا تغير backend أو permissions.
- [ ] تعريف capability-based redundancy check: إذا كانت أداة مفعلة تستطيع أصلًا فحص Host PATH بالمستوى نفسه، لا تسجل discovery tool في catalog؛ لا يعتمد الشرط على اسم Shell ثابت فقط.

### F0 Exit

- [ ] schema صغيرة وغير قابلة للتحول إلى general filesystem tool.
- [ ] side effects صفر ومخرجات bounded.

## 3. Gate F1 — daemon resolver

- [ ] بناء resolver من inherited trusted PATH snapshot المملوكة لـ83e.
- [ ] exact-name lookup يرفض traversal/separators/invalid executable names.
- [ ] optional bounded common-tool listing لا يكشف directories فارغة أو hidden files أو values.
- [ ] cache مربوط بenvironment revision وقابل للتحديث دون stale cross-Workspace leak.
- [ ] errors تفرق unavailable/disabled/invalid دون تسريب PATH كامل.

### F1 Exit

- [ ] resolver لا ينفذ محتوى غير موثوق.
- [ ] النتائج حتمية عبر المنصات المدعومة.

## 4. Gate F2 — owner policy وcatalog omission

- [ ] قراءة `hostDiscovery=disabled|owner_only` من daemon-private Workspace policy فقط، والبدء بـ`owner_only`.
- [ ] في `owner_only` تضاف الأداة فقط لجلسة ذات owner identity مثبتة وعند غياب Host PATH access مكافئ؛ كل caller مشارك يراها غائبة.
- [ ] Direct Developer مع Host Shell كاملة يخفي tool spec افتراضيًا لأنها redundant؛ Protected owner session قد تظهرها فقط إذا لم توفر أدواتها Host PATH access.
- [ ] يعاد حساب presence عند تغير backend/tool grants/catalog revision دون إنشاء session جديدة.
- [ ] owner/admin الموثق وحده يغير setting؛ caller غير مالك يفشل مغلقًا.
- [ ] disabled تعني عدم إضافة tool spec إلى `LocalRuntimeCatalog` أو model schema.
- [ ] لا يضاف stub أو Prompt نص يخبر النموذج أن الأداة مخفية أو Host tools موجودة.
- [ ] Protected/shared sessions تستهلك effective owner policy ولا تستنتج visibility من permission mode.
- [ ] Full Access لا يتجاوز discovery deny.

### F2 Exit

- [ ] مستخدم Workspace غير موثوق لا يستطيع رؤية أو استنتاج Host inventory عبر capability runtime.
- [ ] toggle يعاد في turn catalog التالية دون session جديدة.

## 5. Gate F3 — tests والتوثيق

- [ ] اختبارات enabled exact lookup وbounded list وinvalid name/symlink/Windows extension.
- [ ] اختبارات disabled tool absence من query/direct catalogs وprompt snapshot.
- [ ] اختبارات redundancy: Direct Host PATH access يخفي schema، وProtected owner بلا وصول مكافئ يظهرها، وإضافة capability مكافئة تخفيها مجددًا.
- [ ] اختبارات owner/non-owner mutation وFull Access precedence.
- [ ] اختبار أن discovery output لا يحتوي PATH raw أو environment values.
- [ ] تحديث capability docs وsecurity QA دون إضافة UI shortcut.

### F3 Exit / Definition of Done

- [ ] discovery اختيارية بالكامل وowner-controlled ومشروطة بالحاجة الفعلية.
- [ ] لا تظهر في catalog عندما يستطيع الوكيل اكتشاف Host PATH بأداة أخرى، فلا تستهلك tool schema/context بلا فائدة.
- [ ] لا تعليمات System Prompt ولا زر سياقي لتجاوز policy.
- [ ] الأداة لا توسع filesystem أو execution authority.

## 6. سيناريو النجاح

تبدأ Workspace بـ`owner_only`. في Direct Developer تخفي الـcatalog الأداة لأن Host Shell تستطيع فحص PATH أصلًا. ينتقل المالك إلى Protected حيث لا توجد قدرة مكافئة؛ تظهر الأداة ويستطيع سؤال resolver عن `flutter` والحصول على executable canonical غير سري. يعطل المالك الميزة فتختفي في turn التالية، ولا يستطيع مستخدم مشارك أو Full Access إعادة تفعيلها.

## 7. خارج النطاق

- تشغيل الأدوات أو قياس versions.
- UI لإدارة mounts/images.
- اقتراح التحويل إلى Direct بعد failure.
- inventory لكل التطبيقات أو الملفات المثبتة.

## 8. سجل التقدم

```text
Date:
Gate/status:
Files changed:
Verification:
Findings:
Remaining work percentage:
Next gate:
```
