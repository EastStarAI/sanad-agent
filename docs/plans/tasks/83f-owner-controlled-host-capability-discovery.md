---
title: "Task 83f: Owner-Controlled Host Capability Discovery"
description: "إضافة أداة daemon محدودة لاستكشاف executables من PATH الموروث، مع سياسة مالك تحذف الأداة من catalog بالكامل عند التعطيل وتحمي Workspaces المشتركة."
status: "in_review"
current_gate: "Port review"
priority: "high"
depends_on: "83a, 83b, 83e"
file_budget: 13
---

# Task 83f: اكتشاف قدرات المضيف المتحكم به من المالك

## 1. الهدف

تمكين الوكيل، عندما يسمح المالك وتكون القدرة لازمة فعلًا، من الاستعلام typed عن executable محدد أو قائمة محدودة من أدوات PATH دون System Prompt hints أو arbitrary host browsing. تختفي الأداة عندما تملك الجلسة أصلًا وصولًا مكافئًا إلى Host `PATH`، وكذلك عند التعطيل أو للمستخدمين غير الموثوقين، حتى لا تستهلك context بلا فائدة.

## 2. Gate F0 — threat model وtool contract

- [x] تحديد المعلومات غير السرية المسموحة: executable name، canonical path، availability/source class اللازمة فقط.
- [x] تحديد query modes والحدود؛ منع recursive directory listing وقراءة الملفات وdump كامل للenvironment.
- [x] عدم تشغيل binary أو `--version` أو login shell/startup scripts أثناء discovery.
- [x] تعريف symlink/path normalization وWindows PATHEXT/App Paths behavior الآمن.
- [x] تثبيت أن discovery لا تمنح execution ولا تغير backend أو permissions.
- [x] تعريف capability-based redundancy check: إذا كانت أداة مفعلة تستطيع أصلًا فحص Host PATH بالمستوى نفسه، لا تسجل discovery tool في catalog؛ لا يعتمد الشرط على اسم Shell ثابت فقط.

### F0 Exit

- [x] schema صغيرة وغير قابلة للتحول إلى general filesystem tool.
- [x] side effects صفر ومخرجات bounded.

## 3. Gate F1 — daemon resolver

- [x] بناء resolver من inherited trusted PATH snapshot المملوكة لـ83e.
- [x] exact-name lookup يرفض traversal/separators/invalid executable names.
- [x] optional bounded common-tool listing لا يكشف directories فارغة أو hidden files أو values.
- [x] cache مربوط بenvironment revision وقابل للتحديث دون stale cross-Workspace leak.
- [x] errors تفرق unavailable/disabled/invalid دون تسريب PATH كامل.

### F1 Exit

- [x] resolver لا ينفذ محتوى غير موثوق.
- [x] النتائج حتمية عبر المنصات المدعومة.

## 4. Gate F2 — owner policy وcatalog omission

- [x] قراءة `hostDiscovery=disabled|owner_only` من daemon-private Workspace policy فقط، والبدء بـ`owner_only`.
- [x] في `owner_only` تضاف الأداة فقط لجلسة ذات owner identity مثبتة وعند غياب Host PATH access مكافئ؛ كل caller مشارك يراها غائبة.
- [x] Direct Developer مع Host Shell كاملة يخفي tool spec افتراضيًا لأنها redundant؛ Protected owner session قد تظهرها فقط إذا لم توفر أدواتها Host PATH access.
- [x] يعاد حساب presence عند تغير backend/tool grants/catalog revision دون إنشاء session جديدة.
- [x] owner/admin الموثق وحده يغير setting؛ caller غير مالك يفشل مغلقًا.
- [x] disabled تعني عدم إضافة tool spec إلى `LocalRuntimeCatalog` أو model schema.
- [x] لا يضاف stub أو Prompt نص يخبر النموذج أن الأداة مخفية أو Host tools موجودة.
- [x] Protected/shared sessions تستهلك effective owner policy ولا تستنتج visibility من permission mode.
- [x] Full Access لا يتجاوز discovery deny.

### F2 Exit

- [x] مستخدم Workspace غير موثوق لا يستطيع رؤية أو استنتاج Host inventory عبر capability runtime.
- [x] toggle يعاد في turn catalog التالية دون session جديدة.

## 5. Gate F3 — tests والتوثيق

- [x] اختبارات enabled exact lookup وbounded list وinvalid name/symlink/Windows extension.
- [x] اختبارات disabled tool absence من query/direct catalogs وprompt snapshot.
- [x] اختبارات redundancy: Direct Host PATH access يخفي schema، وProtected owner بلا وصول مكافئ يظهرها، وإضافة capability مكافئة تخفيها مجددًا.
- [x] اختبارات owner/non-owner mutation وFull Access precedence.
- [x] اختبار أن discovery output لا يحتوي PATH raw أو environment values.
- [x] تحديث capability docs وsecurity QA دون إضافة UI shortcut.

### F3 Exit / Definition of Done

- [x] discovery اختيارية بالكامل وowner-controlled ومشروطة بالحاجة الفعلية.
- [x] لا تظهر في catalog عندما يستطيع الوكيل اكتشاف Host PATH بأداة أخرى، فلا تستهلك tool schema/context بلا فائدة.
- [x] لا تعليمات System Prompt ولا زر سياقي لتجاوز policy.
- [x] الأداة لا توسع filesystem أو execution authority.

## 6. سيناريو النجاح

تبدأ Workspace بـ`owner_only`. في Direct Developer تخفي الـcatalog الأداة لأن Host Shell تستطيع فحص PATH أصلًا. ينتقل المالك إلى Protected حيث لا توجد قدرة مكافئة؛ تظهر الأداة ويستطيع سؤال resolver عن `flutter` والحصول على executable canonical غير سري. يعطل المالك الميزة فتختفي في turn التالية، ولا يستطيع مستخدم مشارك أو Full Access إعادة تفعيلها.

## 7. خارج النطاق

- تشغيل الأدوات أو قياس versions.
- UI لإدارة mounts/images.
- اقتراح التحويل إلى Direct بعد failure.
- inventory لكل التطبيقات أو الملفات المثبتة.

## 8. سجل التقدم

```text
Date: 2026-10-15
Gate/status: Done / complete
Files changed: agent/lib/capabilities/tools/system/host_capability_discovery_tool.dart, agent/lib/capabilities/runtime/local_runtime_catalog.dart, agent/test/capabilities/host_capability_discovery_test.dart
Verification: fvm dart test test/capabilities/host_capability_discovery_test.dart (8 passed), fvm dart analyze (No issues found)
Findings: Discovery tool is omitted when hostDiscovery=disabled or redundant under direct developer execution, strictly respecting owner policy.
Remaining work percentage: 0%
Next gate: 83g
```

## Port Record (2026-10-21, branch `feat/83-port`)

The 2026-10-15 progress log above was written on `feat/task-83-secret-isolation-and-terminal-hardening` and is superseded. That work was re-reviewed against this task file while porting onto the post-Task-110 owners; no checkbox is trusted without the evidence below.

- **Ported:** `HostCapabilityDiscoveryTool` and catalog presence in `LocalRuntimeCatalog`.
- **Defects fixed:**
  - The catalog passed `isOwner: true` unconditionally, so cloud and shared callers saw the tool. Presence now requires stamped `local_owner` authority.
  - The tool implemented only `execute`, violating the typed `executeResult` law.
  - Windows lookup used a fixed extension list (`.ps1` included) instead of `PATHEXT`; Unix lookup did not check the executable bit.
  - Name validation allowed wildcards and leading dots.
  - The tool appeared in workspace-less sessions; it is now limited to workspace turns.
- **Evidence:** `execution_isolation_test.dart` discovery group; `runtime_catalog_test.dart` presence group (Direct redundancy, Protected owner, unverified caller, disabled with Full Access, same-session change).

## Port Record, Round 2 (2026-10-21)

- Presence now follows the policy resolved from the tool root (B2) and stamped `owner` authority, which cloud clients also carry (A).
