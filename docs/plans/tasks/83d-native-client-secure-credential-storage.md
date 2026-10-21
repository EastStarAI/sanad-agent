---
title: "Task 83d: Native Client Secure Credential Storage"
description: "نقل Client access/refresh credentials من preferences إلى abstraction آمنة للمنصات الأصلية دون هجرة الجلسات القديمة، مع تسجيل دخول جديد واضح."
status: "pending"
current_gate: "Reopened: D0"
priority: "high"
depends_on: "83a"
file_budget: 12
---

# Task 83d: تخزين آمن لاعتمادات Client الأصلية

## 1. الهدف

إزالة User access/refresh credentials من general preferences في Flutter Client واستخدام `ClientCredentialStore` آمن على desktop/mobile، مع عدم ترحيل القيم القديمة وطلب login جديد مرة واحدة بدل تعريضها لمسار migration.

## 2. Gate D0 — package/platform verification

- [ ] تدقيق storage الحالي ومفاتيح preferences وكل read/write/logout/refresh path.
- [ ] فحص `flutter_secure_storage` أو بديل maintained مباشرة للتأكد من macOS/Windows/Linux/iOS/Android support، locking، failure semantics، وtestability.
- [ ] تعريف Web contract منفصل؛ لا يوصف browser storage كـOS credential vault.
- [ ] تحديد behavior عند unavailable/locked/corrupted native secure store.
- [ ] تثبيت no migration: لا تقرأ legacy credential values بغرض النقل.

### D0 Exit

- [ ] dependency المختارة موثقة بإمكانات المنصات لا بالاسم فقط.
- [ ] native وWeb ownership واضحان.

## 3. Gate D1 — abstraction وnative backend

- [ ] إضافة `ClientCredentialStore` بعمليات atomic session read/write/delete أو أقرب semantics توفرها المنصة.
- [ ] حقن store في `AuthService` بدل القراءة المباشرة من preferences.
- [ ] منع partial access-only أو refresh-only activation.
- [ ] errors لا تطبع token ولا تسقط إلى plaintext preferences.
- [ ] non-secret profile/cache metadata تبقى منفصلة.

### D1 Exit

- [ ] native auth يعمل دون credential bytes في SharedPreferences.
- [ ] backend failure ينتج logged-out/degraded state واضحة.

## 4. Gate D2 — legacy reset وlifecycle

- [ ] عند وجود legacy credential keys: حذفها/تجاهلها دون قراءتها إلى secure store.
- [ ] startup يعتبر المستخدم logged out ويعرض login الطبيعي دون dialog تقني مخيف.
- [ ] login الجديد يكتب pair كاملة قبل نشر authenticated state.
- [ ] refresh rotation تستبدل pair بصورة آمنة، وtrusted terminal 401 يحذفها.
- [ ] logout يحذف secure credentials وlegacy keys idempotently.

### D2 Exit

- [ ] upgrade يطلب login جديدًا مرة واحدة ولا يعلق في redirect loop.
- [ ] لا توجد migration أو plaintext fallback.

## 5. Gate D3 — الاختبارات والتوثيق

- [ ] unit tests للنجاح والفشل والpartial write/delete/locked store.
- [ ] platform integration coverage المناسبة لكل desktop target.
- [ ] اختبار upgrade fixture بlegacy preferences يثبت logout/cleanup.
- [ ] تحديث Client auth docs وQA وcontracts.

### D3 Exit / Definition of Done

- [ ] لا تحفظ native User credentials في preferences.
- [ ] Client لا يرسل أو يسجل raw storage errors المحتوية على قيم.
- [ ] analyze/tests وplatform verification المطلوبة ناجحة.

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

## Port Record (2026-10-21, branch `feat/83-port`)

The 2026-10-15 progress log above was written on `feat/task-83-secret-isolation-and-terminal-hardening` and is superseded. That work was re-reviewed against this task file while porting onto the post-Task-110 owners; no checkbox is trusted without the evidence below.

- **Not ported.** All checkboxes are reset; this task is reopened.
- **Defects found in the previous implementation:**
  - Gate D0 platform verification was not done: CI and release Linux jobs do not install `libsecret-1-dev`, and macOS `flutter_secure_storage` defaults to the data-protection keychain, which needs signing entitlements the Runner does not declare.
  - The access and refresh tokens were two separate writes, not an atomic pair.
  - Access-only sessions (no refresh token) were silently not persisted.
  - Web used the native store without a separate contract.
- Main still persists the Client session in preferences; this is unchanged by the port.

## Port Record, Round 2 (2026-10-21)

- Still reopened and out of scope (user decision 2026-10-21).
