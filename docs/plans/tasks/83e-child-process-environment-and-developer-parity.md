---
title: "Task 83e: Child Process Environment and Developer Parity"
description: "إنشاء سلطة مركزية لبيئات العمليات تفصل inherited operator context عن overrides وتحجب أسرار سند دون كسر أدوات وSDKs المطور."
status: "in_review"
current_gate: "Port review"
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

- [ ] fixtures لـFlutter/FVM، Android SDK/NDK/AVD، Java، Node/npm، Python project venv، Git/SSH agent، Docker context، cloud CLI selectors، package caches، proxies، وCA roots.
- [x] اختبارات command discovery من inherited PATH على Unix/Windows.
- [ ] اختبار أن daemon venv markers لا تفسد project venv مع إبقاء executable discovery.
- [ ] اختبار explicit owner grant لمتغير مشروع مشروع دون فتح Sanad secrets.
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

## Port Record (2026-10-21, branch `feat/83-port`)

The 2026-10-15 progress log above was written on `feat/task-83-secret-isolation-and-terminal-hardening` and is superseded. That work was re-reviewed against this task file while porting onto the post-Task-110 owners; no checkbox is trusted without the evidence below.

- **Ported:** `ChildProcessSecurityContract` and `ProcessEnvironmentPolicy`; `DirectExecutionBackend` builds every shell child environment through it.
- **Defects fixed:**
  - Credential names were a hand-written list that missed most registry providers (`KIMI_API_KEY`, `ZAI_API_KEY`, `NVIDIA_API_KEY`, ...) and `SERPER_API_KEY`. They are now derived from `ProviderRegistry.profiles` plus `Config` credentials.
  - Every `SANAD_DEV_*` marker was stripped, which broke `sanad-dev restart agent` from `shell_execute` (it needs the launcher id, runtime nonce, and `SANAD_HOME`). These routing markers are kept.
  - `VIRTUAL_ENV` was stripped unconditionally without the positive test the gate required; it is usually the developer's own venv and is kept.
  - Override rejection did not cover proxies, extra CA roots, `GIT_EXEC_PATH`/`GIT_CONFIG_*`, or the `LD_`/`DYLD_`/`SANAD_` prefixes.
  - `explicitGrants` had no owner source and is not ported.
- **Open:** real toolchain runs (Flutter/FVM, Android, Java) are not part of the automated suite; parity is proved by environment preservation tests.
- **Evidence:** `execution_isolation_test.dart` (real `env` child, override rejection with value-free logs, registry coverage).

## Port Record, Round 2 (2026-10-21)

- **B1, CRITICAL, fixed:** `Process.start(environment: ...)` defaults to `includeParentEnvironment: true`, so Dart merged the daemon environment back into the policy map and every provider key reached a shell child; the unit test injected a fake environment and missed it. `DirectExecutionBackend` and the new `StrictStdioClientTransport` (MCP) spawn with `includeParentEnvironment: false`; the MCP allowlist gained the Windows system variables, locale, proxy and CA keys. Evidence: real daemon E2E `e2e_test/shell_environment_isolation_e2e_test.dart` and spawned MCP probe `test/capabilities/mcp_stdio_environment_test.dart` (red logs `temp/83/r2-b1-red-*.log`).
- **B4:** added `GIT_CONFIG_COUNT`, `GIT_CONFIG_KEY_*`/`GIT_CONFIG_VALUE_*`, `GIT_CONFIG_PARAMETERS`, `GIT_PROXY_COMMAND`, `JAVA_TOOL_OPTIONS`, `PYTHONHOME`, `NODE_PATH`, `ZDOTDIR` to the override contract.

## Port Record, Round 3 (2026-10-21, live r1 follow-ups)

- **S5 (not a defect):** a Direct shell inherits the operator environment, including other tools' credentials, `SANAD_HOME` and `SANAD_DEV_*`, minus only Sanad-read credentials; the design page says so plainly.
