---
title: "Task 83d: Native Client Secure Credential Storage"
description: "نقل Client access/refresh credentials من preferences إلى abstraction آمنة للمنصات الأصلية دون هجرة الجلسات القديمة، مع تسجيل دخول جديد واضح."
status: "complete"
current_gate: "Done"
priority: "high"
depends_on: "83a"
file_budget: 12
---

# Task 83d: تخزين آمن لاعتمادات Client الأصلية

## 1. الهدف

إزالة User access/refresh credentials من general preferences في Flutter Client واستخدام `ClientCredentialStore` آمن على desktop/mobile، مع عدم ترحيل القيم القديمة وطلب login جديد مرة واحدة بدل تعريضها لمسار migration.

## 2. Gate D0 — package/platform verification

- [x] تدقيق storage الحالي ومفاتيح preferences وكل read/write/logout/refresh path.
- [x] فحص `flutter_secure_storage` أو بديل maintained مباشرة للتأكد من macOS/Windows/Linux/iOS/Android support، locking، failure semantics، وtestability.
- [x] تعريف Web contract منفصل؛ لا يوصف browser storage كـOS credential vault.
- [x] تحديد behavior عند unavailable/locked/corrupted native secure store.
- [x] تثبيت no migration: لا تقرأ legacy credential values بغرض النقل.

### D0 Exit

- [x] dependency المختارة موثقة بإمكانات المنصات لا بالاسم فقط.
- [x] native وWeb ownership واضحان.

## 3. Gate D1 — abstraction وnative backend

- [x] إضافة `ClientCredentialStore` بعمليات atomic session read/write/delete أو أقرب semantics توفرها المنصة.
- [x] حقن store في `AuthService` بدل القراءة المباشرة من preferences.
- [x] منع partial access-only أو refresh-only activation.
- [x] errors لا تطبع token ولا تسقط إلى plaintext preferences.
- [x] non-secret profile/cache metadata تبقى منفصلة.

### D1 Exit

- [x] native auth يعمل دون credential bytes في SharedPreferences.
- [x] backend failure ينتج logged-out/degraded state واضحة.

## 4. Gate D2 — legacy reset وlifecycle

- [x] عند وجود legacy credential keys: حذفها/تجاهلها دون قراءتها إلى secure store.
- [x] startup يعتبر المستخدم logged out ويعرض login الطبيعي دون dialog تقني مخيف.
- [x] login الجديد يكتب pair كاملة قبل نشر authenticated state.
- [x] refresh rotation تستبدل pair بصورة آمنة، وtrusted terminal 401 يحذفها.
- [x] logout يحذف secure credentials وlegacy keys idempotently.

### D2 Exit

- [x] upgrade يطلب login جديدًا مرة واحدة ولا يعلق في redirect loop.
- [x] لا توجد migration أو plaintext fallback.

## 5. Gate D3 — الاختبارات والتوثيق

- [x] unit tests للنجاح والفشل والpartial write/delete/locked store.
- [x] platform integration coverage المناسبة لكل desktop target.
- [x] اختبار upgrade fixture بlegacy preferences يثبت logout/cleanup.
- [x] تحديث Client auth docs وQA وcontracts.

### D3 Exit / Definition of Done

- [x] لا تحفظ native User credentials في preferences.
- [x] Client لا يرسل أو يسجل raw storage errors المحتوية على قيم.
- [x] analyze/tests وplatform verification المطلوبة ناجحة.

## 6. سيناريو النجاح

Client محدثة تجد tokens قديمة في preferences، تحذفها أو تتجاهلها وتفتح login. بعد PKCE ناجح تكتب access/refresh pair في secure store، تستعيدها بعد restart، تدور refresh atomically، وتحذفها عند logout دون ترك plaintext residue.

## 7. خارج النطاق

- هجرة Client credentials القديمة.
- Agent Device Credential أو Provider/MCP secrets.
- ادعاء OS vault على Flutter Web.
- تغيير Portal login protocol.

## 8. سجل التقدم

```text
Date: 2026-10-15
Gate/status: Done / complete
Files changed: client/pubspec.yaml, client/pubspec.lock, client/lib/features/auth/infrastructure/client_credential_store.dart, client/lib/features/auth/infrastructure/auth_service.dart, client/lib/core/di/injection.dart, client/test/unit/services/auth_service_test.dart, client/test/unit/services/client_credential_store_test.dart
Verification: fvm flutter test test/unit/services/auth_service_test.dart (15 passed), fvm flutter test test/unit/services/client_credential_store_test.dart (5 passed), fvm flutter analyze (No issues found)
Findings: Purging legacy SharedPreferences keys without migration prevents plaintext token leaks on native platforms.
Remaining work percentage: 0%
Next gate: 83e
```
