---
title: "Task 83d: Native Client Secure Credential Storage"
description: "نقل Client access/refresh credentials من preferences إلى abstraction آمنة للمنصات الأصلية دون هجرة الجلسات القديمة، مع تسجيل دخول جديد واضح."
status: "pending"
current_gate: "Waiting"
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
Date:
Gate/status:
Files changed:
Verification:
Findings:
Remaining work percentage:
Next gate:
```
