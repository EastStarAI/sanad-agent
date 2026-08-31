---
title: "Task 83i: Security Integration and Developer Compatibility QA"
description: "إثبات end-to-end أن الأسرار والسلطة معزولة وأن Direct Developer لا يفقد أدواته، مع اختبارات multi-user وProtected وmigration وdesktop secure storage."
status: "pending"
current_gate: "Waiting"
priority: "critical"
depends_on: "83b, 83c, 83d, 83e, 83f, 83g, 83h"
file_budget: 15
---

# Task 83i: تكامل الأمان وتوافق المطور

## 1. الهدف

إغلاق Plan 83 بأدلة آلية وحية تربط كل threat وقرار acceptance بسلوك runtime الحقيقي، مع وزن متساوٍ لاختبارات المنع واختبارات بقاء قدرات المستخدم والمطور.

## 2. Gate I0 — static and ownership audit

- [ ] البحث يثبت عدم وجود production `...Platform.environment` raw spawn خارج الاستثناءات المعتمدة.
- [ ] البحث يثبت عدم قراءة Workspace-local permission fields كسلطة.
- [ ] البحث يثبت عدم بقاء Provider/MCP plaintext legacy owners بعد migration path activation.
- [ ] Client native auth لا يكتب access/refresh tokens إلى preferences.
- [ ] tool catalog لا يحتوي Host discovery عند disabled policy أو عند وجود capability أخرى توفر Host PATH access مكافئًا.
- [ ] docs لا تدعي encryption للLinux owner-file أو containment لـDirect Host.

### I0 Exit

- [ ] كل استثناء مسجل بowner وسبب واختبار.

## 3. Gate I1 — attack matrix

- [ ] malicious repository يحمل `.sanad/settings.json` بـfull_access/allow ولا يغير daemon policy.
- [ ] model command يحاول قراءة Provider/MCP/Gateway secrets من environment ويفشل.
- [ ] MCP server A لا يحصل على secret B أو Provider/Gateway secret.
- [ ] request يحاول override PATH/loader/Git/package manager/trust roots ويرفض دون طباعة values.
- [ ] non-owner يحاول تفعيل Direct/Full Access/Host discovery ويرفض.
- [ ] Full Access يحاول تجاوز required Protected أو discovery deny ويرفض.
- [ ] Protected escape attempts عبر traversal/symlink/bind/socket/network/process tree تفشل ضمن backend claim.
- [ ] `.env` raw file read لا يعيد credential إلى model-visible result أو logs.

### I1 Exit

- [ ] كل هجوم له pass/fail آلي ودليل redacted.

## 4. Gate I2 — developer parity matrix

- [ ] Direct Developer يشغل fixtures ممثلة لـFlutter/FVM وAndroid/Java وNode/package manager وPython/Git/SSH/Docker/cloud CLI.
- [ ] inherited PATH وSDK/cache/helper/proxy/CA behavior لا يتراجع.
- [ ] project build/test يستطيع استهلاك `.env` دون عرض القيمة في timeline.
- [ ] Host discovery في Protected owner session بلا بديل يجد executable محددًا دون تشغيله؛ Direct Host access أو disabled policy يخفي tool schema.
- [ ] Default approvals وFull Access لا يغيران tool availability أو backend placement ضمنيًا.
- [ ] Windows native invocation/PATHEXT وmacOS/Linux shell semantics مغطاة.

### I2 Exit

- [ ] لا يوجد إصلاح أمني أغلق workflow مشروع مثبت.
- [ ] أي platform gap ظاهر ومقرر، لا failure صامت.

## 5. Gate I3 — persistence, migration, and recovery

- [ ] permission DB restart/relocation/concurrency/revision tests.
- [ ] Provider/MCP migration success/partial/failure/retry/idempotence/legacy deletion tests.
- [ ] Linux Secret Service unavailable/locked وowner-file Headless paths.
- [ ] Client secure-store success/failure/logout وlegacy re-login دون migration.
- [ ] same-session Direct↔Protected switch وno-auto-replay بعد failure.
- [ ] daemon crash/restart لا يحول stale policy أو secret backend أو queued work إلى authority أوسع.

### I3 Exit

- [ ] recovery تفشل مغلقة وتحافظ على data دون split-brain.

## 6. Gate I4 — daemon-backed and visual acceptance

- [ ] authenticated local-daemon E2E للأذونات والpolicy events وmode switching.
- [ ] cloud/remote owner versus non-owner route حيث يمكن إثبات identity؛ ما لا يمكن إثباته يفشل مغلقًا.
- [ ] real Protected backend test على كل منصة/runner معلنة مدعومة، لا mocks فقط.
- [ ] visible Client verification لـFull Access dialog وWorkspace controls وre-login flow.
- [ ] logs bounded وتخلو من secrets/raw env/permission arguments.

### I4 Exit

- [ ] live/history/reconnect UI parity مثبتة.
- [ ] no silent host fallback أو hidden capability escalation.

## 7. Gate I5 — final audit and documentation

- [ ] إعادة فتح evidence packet ومقارنة كل Adopt/Adapt obligation: satisfied/deviated/not applicable.
- [ ] تحديث technical/product/operations/QA pages و`docs/llms.txt`.
- [ ] تحديث Plan 83 dashboard ونسبة المتبقي وسجل كل Gate.
- [ ] تشغيل analyzers/full fast suites وE2E المطلوبة بمخرجات bounded.
- [ ] تسجيل known limitations بدقة، خاصة Direct same-account boundary وLinux owner-file.

### I5 Exit / Definition of Done

- [ ] كل معايير قبول Plan 83 مرتبطة بدليل ناجح.
- [ ] security negative وdeveloper positive suites ناجحتان.
- [ ] لا وثائق متناقضة أو ملفات خطة قديمة نشطة.
- [ ] الخطة جاهزة للمراجعة/PR دون commit أوpush تلقائي.

## 8. سيناريو النجاح

يمر مستودع خبيث وبيئة daemon محشوة بأسرار ومستخدم مشارك وProtected sandbox وDirect developer toolchain عبر matrix واحدة: لا self-authorization أو secret leakage، ولا اختفاء لأدوات المطور في Direct، وتبقى كل escalation بقرار مالك durable وواضح.

## 9. خارج النطاق

- إضافة سياسة جديدة أثناء QA.
- اعتبار mock container دليل isolation نهائي.
- commit/push/merge دون إذن المستخدم.

## 10. سجل التقدم

```text
Date:
Gate/status:
Files changed:
Verification:
Visual evidence:
Findings:
Remaining work percentage:
Next gate:
```
