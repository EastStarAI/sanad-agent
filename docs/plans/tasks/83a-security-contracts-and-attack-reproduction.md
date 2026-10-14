---
title: "Task 83a: Security Contracts and Attack Reproduction"
description: "تثبيت نموذج الثقة والأنواع وحدود الملكية وإضافة اختبارات فاشلة تعيد إنتاج self-authorization وتسريب البيئة قبل تعديل التنفيذ."
status: "complete"
current_gate: "Done"
priority: "critical"
depends_on: "Approved Plan 83"
file_budget: 12
---

# Task 83a: عقود الأمان وإعادة إنتاج الهجمات

## 1. الهدف

تثبيت vocabulary وحدود الملكية بين permissions، secrets، process environment، execution backends، host discovery، والـClient قبل أي migration أو refactor، مع اختبارات تعيد إنتاج الأخطار الحالية دون تقديم حل جزئي متضارب.

## 2. Gate A0 — تدقيق أسطح التنفيذ والسلطة

- [x] حصر كل `Process.start/run` ومسارات MCP/browser/helper/installer التي قد ترث بيئة الـdaemon.
- [x] حصر كل قراءة وكتابة لـWorkspace policy وكل bypass يعتمد `full_access` أو durable allow.
- [x] حصر مخازن Agent auth وProvider وMCP وClient auth، وصيغة كل legacy source.
- [x] حصر أوامر protocol التي تغير policy وهوية caller المتاحة محليًا وسحابيًا.
- [x] إثبات حدود Workspace UUID والمسار canonical وإعادة التسمية/النقل.
- [x] توثيق أين يستطيع مستخدم غير مالك التأثير في session أو Workspace اليوم.

### A0 Exit

- [x] لا يوجد child spawn أو policy mutation مجهول الملكية.
- [x] توجد خريطة مصدر/مالك/مستهلك لكل secret class.

## 3. Gate A1 — أنواع وعقود المصدر

- [x] تعريف `ExecutionMode` بقيم `direct|protected` أو مكافئ provider-neutral.
- [x] تعريف `HostDiscoveryPolicy` بقيم `disabled|owner_only` وdefault `owner_only` كسقف سماح، مع غياب tool عند عدم ثبوت owner identity أو عندما توفر capability أخرى وصولًا مكافئًا إلى Host `PATH`.
- [x] تعريف `ChildProcessPurpose` و`EnvironmentSource` و`SecretOwner` أو عقود مكافئة تمنع Map غير مصنفة.
- [x] فصل inherited operator environment عن request/tool overrides.
- [x] تثبيت أن `PermissionMode` وexecution/discovery policy daemon-authoritative وليست Workspace metadata.
- [x] تثبيت precedence: owner required policy > workspace policy > session/once > content.
- [x] منع types من حمل raw secret values أو Flutter fields.

### A1 Exit

- [x] 83b–83g تعتمد عقودًا ثابتة دون circular dependencies.
- [x] لا يملك protocol أو UI قرار التنفيذ أو secret materialization.

## 4. Gate A2 — اختبارات إعادة الإنتاج

- [x] اختبار يثبت أن Workspace-local `settings.json` الحالي يستطيع تقديم `full_access` دون قرار جهاز موثوق، ثم يوسم كاختبار يجب قلبه في 83b.
- [x] اختبار يثبت أن Shell الحالي يرث Sanad/provider secret من `Platform.environment`، ثم يوسم كاختبار يجب قلبه في 83e.
- [x] اختبار يثبت أن بيئة مطور سليمة تشمل PATH وSDK/cache/helper values اللازمة، ليمنع الإصلاح من حذفها.
- [x] اختبار يثبت أن MCP secret لا ينبغي أن يصل إلى Shell sibling.
- [x] اختبار contract يثبت أن discovery disabled أو redundant بسبب Host PATH access تعني غياب tool spec، لا denial stub.
- [x] عدم استخدام live credentials أو SANAD_HOME الحقيقي في أي fixture.

### A2 Exit

- [x] توجد negative reproductions وpositive compatibility fixtures مع ownership واضح.
- [x] الاختبارات لا تعتمد على منصب مستخدم حقيقي أو شبكة خارجية.

## 5. Gate A3 — توثيق وتصميم التنفيذ

- [x] تحديث technical design بحدود الثقة المعتمدة ومصفوفة Direct/Protected × Default/Full Access.
- [x] تحديث QA matrix الأولية وربط كل invariant بمهمة مالكة.
- [x] تثبيت no-permission-migration وAgent-secret-migration وClient-no-migration.
- [x] مراجعة file budgets والاعتماديات الفعلية للمهام 83b–83i.

### A3 Exit / Definition of Done

- [x] نموذج التهديد والأنواع والاختبارات الفاشلة المعروفة معتمدة.
- [x] لا يوجد implementation جزئي يغيّر behavior للمستخدم.
- [x] يمكن بدء 83b–83e بالتوازي.

## 6. سيناريو النجاح

تستطيع الاختبارات بناء Workspace مؤقتة تحوي policy مزورة وبيئة daemon تحوي Sanad secret وبيئة مطور سليمة، وتثبت الأخطار الحالية والقدرات الواجب الحفاظ عليها. تكون الأنواع source-neutral، وتعرف المهام اللاحقة بالضبط أي اختبار تقلبه من fail إلى pass.

## 7. خارج النطاق

- DB schema النهائية أو migration.
- secret-store writes.
- Client secure-storage dependency.
- sandbox provisioning أو UI.

## 8. سجل التقدم

```text
Date: 2026-10-15
Gate/status: Done / complete
Files changed:
  - agent/lib/capabilities/permissions/execution_mode.dart
  - agent/lib/capabilities/permissions/host_discovery_policy.dart
  - agent/lib/capabilities/permissions/child_process_security_contract.dart
  - agent/lib/capabilities/permissions/workspace_security_policy.dart
  - agent/lib/capabilities/permissions/workspace_policy.dart
  - agent/lib/capabilities/permissions/AGENTS.md
  - agent/test/capabilities/security_contracts_reproduction_test.dart
Verification:
  - fvm dart analyze lib/capabilities/permissions test/capabilities/security_contracts_reproduction_test.dart (0 issues)
  - fvm dart test test/capabilities/security_contracts_reproduction_test.dart (6/6 passed)
  - fvm dart test test/capabilities/permission_manager_test.dart (10/10 passed)
Findings:
  - Reproduced self-authorization vulnerability: workspace .sanad/settings.json currently bypasses approval prompt (marked to flip in 83b).
  - Reproduced environment leakage: Platform.environment passes all secrets to child processes (marked to flip in 83e).
  - Validated clean developer environment preservation and MCP secret isolation.
  - Validated host discovery policy omission rules and authority precedence.
Remaining work percentage: 0% for Task 83a
Next gate: Task 83b (Gate B0)
```

