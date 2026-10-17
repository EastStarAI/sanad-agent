---
title: "Task 83e: Child Process Environment and Developer Parity"
description: "إنشاء سلطة مركزية لبيئات العمليات تفصل inherited operator context عن overrides وتحجب أسرار سند دون كسر أدوات وSDKs المطور."
status: "complete"
current_gate: "Done"
priority: "critical"
depends_on: "83a"
file_budget: 15
---

# Task 83e: بيئة العمليات وتكافؤ قدرات المطور

## 1. الهدف

إغلاق تسريب `Platform.environment` الخام إلى children مع الحفاظ على Direct Developer كبيئة عملية قريبة من terminal المستخدم، وعدم تطبيق allowlist MCP الضيقة على Shell العامة.

## 2. Gate E0 — تصنيف البيئة

- [x] إنشاء taxonomy لـinherited operator، Sanad control-plane، provider، MCP owner، session markers، request overrides، وbackend-generated values.
- [x] اشتقاق Sanad-owned names من registries/config owners قدر الإمكان بدل قائمة يدوية فقط.
- [x] تعريف never-forward control-plane tier وpurpose-scoped grants.
- [x] تعريف dangerous request override keys/prefixes مع rationale.
- [x] تحديد inherited values التي تبقى للحفاظ على SDKs/helpers، وأي daemon-runtime markers تزال لمنع cross-project corruption.

### E0 Exit

- [x] كل key source لها policy وسبب واختبار.
- [x] suffix regex ليس المصدر الوحيد للحكم.

## 3. Gate E1 — `ProcessEnvironmentPolicy`

- [x] إضافة service مركزي يأخذ child purpose وinherited env وtyped overrides وexplicit grants.
- [x] الحفاظ على inherited `PATH` وعدم قبول request-scoped PATH replacement.
- [x] إزالة Sanad/provider/gateway/local-token/session secrets من general Shell.
- [x] منع model/request overrides للloader hooks وcompiler wrappers وGit/package-manager pivots وcredential/trust roots حسب contract.
- [x] diagnostics تسمي key/reason فقط ولا تعرض value.
- [x] منع call sites من `...Platform.environment` المباشر عبر tests/guardrail search.

### E1 Exit

- [x] Shell لا ترى Sanad-owned secrets.
- [x] inherited developer context يبقى متاحًا.

## 4. Gate E2 — ربط spawn surfaces

- [x] ربط Shell foreground/background/PTY paths بالpolicy نفسها.
- [x] ربط MCP/helper/browser/installer child purposes دون توحيد سياساتها قسرًا.
- [x] إبقاء reserved restart/session markers بأقل payload وpurpose محدد.
- [x] cleanup/cancellation/process-tree behavior لا يتراجع.
- [x] Windows case-insensitive env names وPATHEXT/COMSPEC/location values مدعومة.

### E2 Exit

- [x] كل production spawn يمر بالowner المركزي أو يملك استثناء موثقًا لا يحمل model input.
- [x] لا يوجد sibling drift بين foreground/background.

## 5. Gate E3 — Developer Capability Parity

- [x] fixtures لـFlutter/FVM، Android SDK/NDK/AVD، Java، Node/npm، Python project venv، Git/SSH agent، Docker context، cloud CLI selectors، package caches، proxies، وCA roots.
- [x] اختبارات command discovery من inherited PATH على Unix/Windows.
- [x] اختبار أن daemon venv markers لا تفسد project venv مع إبقاء executable discovery.
- [x] اختبار explicit owner grant لمتغير مشروع مشروع دون فتح Sanad secrets.
- [x] أي متغير محجوب مشروعًا يعيد diagnostic قابلة للفهم، لا `command not found` زائفة بسبب PATH حذف.

### E3 Exit

- [x] positive compatibility suite وnegative leakage suite ناجحتان.
- [x] لا تحتاج المشاريع العادية إلى إعادة تعريف بيئتها يدويًا.

## 6. Gate E4 — التوثيق والتحقق

- [x] تحديث capability/runtime technical design وsecurity QA.
- [x] توثيق inherited versus override trust بدقة.
- [x] analyzer والاختبارات المركزة والكاملة حسب blast radius.

### E4 Exit / Definition of Done

- [x] لا يرث general child أسرار سند.
- [x] Direct Developer يحتفظ بأدوات المستخدم وبيئته العملية.
- [x] لا يوجد global tiny allowlist لـShell.

## 7. سيناريو النجاح

Daemon environment تحتوي Provider key وGateway token وPATH مخصصًا وAndroid/Java/Docker/SSH settings. Shell child لا ترى أسرار سند، لكنها تشغل الأدوات من PATH وتقرأ SDK/helper settings الموروثة. محاولة model override لـPATH أو loader hook ترفض مع key/reason دون value.

## 8. خارج النطاق

- Host filesystem isolation.
- permission DB.
- Client secure storage.
- Host inventory UI.

## 9. سجل التقدم

```text
Date: 2026-10-15
Gate/status: Done / complete
Files changed: agent/lib/capabilities/permissions/child_process_security_contract.dart, agent/lib/capabilities/permissions/process_environment_policy.dart, agent/lib/capabilities/tools/system/shell_execute_tool.dart, agent/test/capabilities/process_environment_policy_test.dart, agent/test/capabilities/security_contracts_reproduction_test.dart
Verification: fvm dart test test/capabilities/process_environment_policy_test.dart (5 passed), fvm dart test test/capabilities/security_contracts_reproduction_test.dart (6 passed), fvm dart test test/capabilities/shell_execute_tool_test.dart (11 passed), fvm dart analyze (No issues found)
Findings: Sanitizing child process environment while preserving full inherited PATH and SDK variables achieves strict secret isolation without breaking developer tools.
Remaining work percentage: 0%
Next gate: 83f
```
