---
title: "Task 83e: Child Process Environment and Developer Parity"
description: "إنشاء سلطة مركزية لبيئات العمليات تفصل inherited operator context عن overrides وتحجب أسرار سند دون كسر أدوات وSDKs المطور."
status: "pending"
current_gate: "Waiting"
priority: "critical"
depends_on: "83a"
file_budget: 15
---

# Task 83e: بيئة العمليات وتكافؤ قدرات المطور

## 1. الهدف

إغلاق تسريب `Platform.environment` الخام إلى children مع الحفاظ على Direct Developer كبيئة عملية قريبة من terminal المستخدم، وعدم تطبيق allowlist MCP الضيقة على Shell العامة.

## 2. Gate E0 — تصنيف البيئة

- [ ] إنشاء taxonomy لـinherited operator، Sanad control-plane، provider، MCP owner، session markers، request overrides، وbackend-generated values.
- [ ] اشتقاق Sanad-owned names من registries/config owners قدر الإمكان بدل قائمة يدوية فقط.
- [ ] تعريف never-forward control-plane tier وpurpose-scoped grants.
- [ ] تعريف dangerous request override keys/prefixes مع rationale.
- [ ] تحديد inherited values التي تبقى للحفاظ على SDKs/helpers، وأي daemon-runtime markers تزال لمنع cross-project corruption.

### E0 Exit

- [ ] كل key source لها policy وسبب واختبار.
- [ ] suffix regex ليس المصدر الوحيد للحكم.

## 3. Gate E1 — `ProcessEnvironmentPolicy`

- [ ] إضافة service مركزي يأخذ child purpose وinherited env وtyped overrides وexplicit grants.
- [ ] الحفاظ على inherited `PATH` وعدم قبول request-scoped PATH replacement.
- [ ] إزالة Sanad/provider/gateway/local-token/session secrets من general Shell.
- [ ] منع model/request overrides للloader hooks وcompiler wrappers وGit/package-manager pivots وcredential/trust roots حسب contract.
- [ ] diagnostics تسمي key/reason فقط ولا تعرض value.
- [ ] منع call sites من `...Platform.environment` المباشر عبر tests/guardrail search.

### E1 Exit

- [ ] Shell لا ترى Sanad-owned secrets.
- [ ] inherited developer context يبقى متاحًا.

## 4. Gate E2 — ربط spawn surfaces

- [ ] ربط Shell foreground/background/PTY paths بالpolicy نفسها.
- [ ] ربط MCP/helper/browser/installer child purposes دون توحيد سياساتها قسرًا.
- [ ] إبقاء reserved restart/session markers بأقل payload وpurpose محدد.
- [ ] cleanup/cancellation/process-tree behavior لا يتراجع.
- [ ] Windows case-insensitive env names وPATHEXT/COMSPEC/location values مدعومة.

### E2 Exit

- [ ] كل production spawn يمر بالowner المركزي أو يملك استثناء موثقًا لا يحمل model input.
- [ ] لا يوجد sibling drift بين foreground/background.

## 5. Gate E3 — Developer Capability Parity

- [ ] fixtures لـFlutter/FVM، Android SDK/NDK/AVD، Java، Node/npm، Python project venv، Git/SSH agent، Docker context، cloud CLI selectors، package caches، proxies، وCA roots.
- [ ] اختبارات command discovery من inherited PATH على Unix/Windows.
- [ ] اختبار أن daemon venv markers لا تفسد project venv مع إبقاء executable discovery.
- [ ] اختبار explicit owner grant لمتغير مشروع مشروع دون فتح Sanad secrets.
- [ ] أي متغير محجوب مشروعًا يعيد diagnostic قابلة للفهم، لا `command not found` زائفة بسبب PATH حذف.

### E3 Exit

- [ ] positive compatibility suite وnegative leakage suite ناجحتان.
- [ ] لا تحتاج المشاريع العادية إلى إعادة تعريف بيئتها يدويًا.

## 6. Gate E4 — التوثيق والتحقق

- [ ] تحديث capability/runtime technical design وsecurity QA.
- [ ] توثيق inherited versus override trust بدقة.
- [ ] analyzer والاختبارات المركزة والكاملة حسب blast radius.

### E4 Exit / Definition of Done

- [ ] لا يرث general child أسرار سند.
- [ ] Direct Developer يحتفظ بأدوات المستخدم وبيئته العملية.
- [ ] لا يوجد global tiny allowlist لـShell.

## 7. سيناريو النجاح

Daemon environment تحتوي Provider key وGateway token وPATH مخصصًا وAndroid/Java/Docker/SSH settings. Shell child لا ترى أسرار سند، لكنها تشغل الأدوات من PATH وتقرأ SDK/helper settings الموروثة. محاولة model override لـPATH أو loader hook ترفض مع key/reason دون value.

## 8. خارج النطاق

- Host filesystem isolation.
- permission DB.
- Client secure storage.
- Host inventory UI.

## 9. سجل التقدم

```text
Date:
Gate/status:
Files changed:
Verification:
Findings:
Remaining work percentage:
Next gate:
```
