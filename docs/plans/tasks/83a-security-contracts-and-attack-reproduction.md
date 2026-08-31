---
title: "Task 83a: Security Contracts and Attack Reproduction"
description: "تثبيت نموذج الثقة والأنواع وحدود الملكية وإضافة اختبارات فاشلة تعيد إنتاج self-authorization وتسريب البيئة قبل تعديل التنفيذ."
status: "pending"
current_gate: "A0"
priority: "critical"
depends_on: "Approved Plan 83"
file_budget: 12
---

# Task 83a: عقود الأمان وإعادة إنتاج الهجمات

## 1. الهدف

تثبيت vocabulary وحدود الملكية بين permissions، secrets، process environment، execution backends، host discovery، والـClient قبل أي migration أو refactor، مع اختبارات تعيد إنتاج الأخطار الحالية دون تقديم حل جزئي متضارب.

## 2. Gate A0 — تدقيق أسطح التنفيذ والسلطة

- [ ] حصر كل `Process.start/run` ومسارات MCP/browser/helper/installer التي قد ترث بيئة الـdaemon.
- [ ] حصر كل قراءة وكتابة لـWorkspace policy وكل bypass يعتمد `full_access` أو durable allow.
- [ ] حصر مخازن Agent auth وProvider وMCP وClient auth، وصيغة كل legacy source.
- [ ] حصر أوامر protocol التي تغير policy وهوية caller المتاحة محليًا وسحابيًا.
- [ ] إثبات حدود Workspace UUID والمسار canonical وإعادة التسمية/النقل.
- [ ] توثيق أين يستطيع مستخدم غير مالك التأثير في session أو Workspace اليوم.

### A0 Exit

- [ ] لا يوجد child spawn أو policy mutation مجهول الملكية.
- [ ] توجد خريطة مصدر/مالك/مستهلك لكل secret class.

## 3. Gate A1 — أنواع وعقود المصدر

- [ ] تعريف `ExecutionMode` بقيم `direct|protected` أو مكافئ provider-neutral.
- [ ] تعريف `HostDiscoveryPolicy` بقيم `disabled|owner_only` وdefault `owner_only` كسقف سماح، مع غياب tool عند عدم ثبوت owner identity أو عندما توفر capability أخرى وصولًا مكافئًا إلى Host `PATH`.
- [ ] تعريف `ChildProcessPurpose` و`EnvironmentSource` و`SecretOwner` أو عقود مكافئة تمنع Map غير مصنفة.
- [ ] فصل inherited operator environment عن request/tool overrides.
- [ ] تثبيت أن `PermissionMode` وexecution/discovery policy daemon-authoritative وليست Workspace metadata.
- [ ] تثبيت precedence: owner required policy > workspace policy > session/once > content.
- [ ] منع types من حمل raw secret values أو Flutter fields.

### A1 Exit

- [ ] 83b–83g تعتمد عقودًا ثابتة دون circular dependencies.
- [ ] لا يملك protocol أو UI قرار التنفيذ أو secret materialization.

## 4. Gate A2 — اختبارات إعادة الإنتاج

- [ ] اختبار يثبت أن Workspace-local `settings.json` الحالي يستطيع تقديم `full_access` دون قرار جهاز موثوق، ثم يوسم كاختبار يجب قلبه في 83b.
- [ ] اختبار يثبت أن Shell الحالي يرث Sanad/provider secret من `Platform.environment`، ثم يوسم كاختبار يجب قلبه في 83e.
- [ ] اختبار يثبت أن بيئة مطور سليمة تشمل PATH وSDK/cache/helper values اللازمة، ليمنع الإصلاح من حذفها.
- [ ] اختبار يثبت أن MCP secret لا ينبغي أن يصل إلى Shell sibling.
- [ ] اختبار contract يثبت أن discovery disabled أو redundant بسبب Host PATH access تعني غياب tool spec، لا denial stub.
- [ ] عدم استخدام live credentials أو SANAD_HOME الحقيقي في أي fixture.

### A2 Exit

- [ ] توجد negative reproductions وpositive compatibility fixtures مع ownership واضح.
- [ ] الاختبارات لا تعتمد على منصب مستخدم حقيقي أو شبكة خارجية.

## 5. Gate A3 — توثيق وتصميم التنفيذ

- [ ] تحديث technical design بحدود الثقة المعتمدة ومصفوفة Direct/Protected × Default/Full Access.
- [ ] تحديث QA matrix الأولية وربط كل invariant بمهمة مالكة.
- [ ] تثبيت no-permission-migration وAgent-secret-migration وClient-no-migration.
- [ ] مراجعة file budgets والاعتماديات الفعلية للمهام 83b–83i.

### A3 Exit / Definition of Done

- [ ] نموذج التهديد والأنواع والاختبارات الفاشلة المعروفة معتمدة.
- [ ] لا يوجد implementation جزئي يغيّر behavior للمستخدم.
- [ ] يمكن بدء 83b–83e بالتوازي.

## 6. سيناريو النجاح

تستطيع الاختبارات بناء Workspace مؤقتة تحوي policy مزورة وبيئة daemon تحوي Sanad secret وبيئة مطور سليمة، وتثبت الأخطار الحالية والقدرات الواجب الحفاظ عليها. تكون الأنواع source-neutral، وتعرف المهام اللاحقة بالضبط أي اختبار تقلبه من fail إلى pass.

## 7. خارج النطاق

- DB schema النهائية أو migration.
- secret-store writes.
- Client secure-storage dependency.
- sandbox provisioning أو UI.

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
