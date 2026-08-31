---
title: "Task 83c: Unified Agent Secret Store and Migration"
description: "توحيد Agent auth وProvider وMCP secrets خلف AgentSecretStore مع references ونطاقات مستقلة وهجرة ذرية متحققة من الملفات القديمة."
status: "pending"
current_gate: "Waiting"
priority: "critical"
depends_on: "83a"
file_budget: 15
---

# Task 83c: مخزن أسرار Agent الموحد والهجرة

## 1. الهدف

استخدام سياسة `AgentSecretStore` الحالية لجميع أسرار Agent auth وProviders وMCP بدل owner-only JSON stores المتوازية، مع الحفاظ على macOS Keychain وWindows DPAPI وLinux Secret Service/Headless owner-file behavior، وهجرة لا تفقد البيانات.

## 2. Gate C0 — inventory وnamespace contract

- [ ] حصر مفاتيح Agent auth الحالية وProvider `SecretRecord` وMCP bearer/header/env/args/OAuth secrets.
- [ ] تصميم namespaces مستقلة تمنع collision أو list-through بين auth/provider/MCP owners.
- [ ] تعريف opaque reference format لا يكشف backend أو قيمة.
- [ ] تحديد metadata التي تبقى في DB/config وحالة `configured` غير السرية.
- [ ] تعريف async adaptation لأن Provider store الحالي synchronous بينما `AgentSecretStore` async.
- [ ] تثبيت أن Linux owner-file fallback ليس encryption وأن backend selection الحالية لا تتغير ضمنيًا.

### C0 Exit

- [ ] كل secret له owner/key/lifecycle/migration source محدد.
- [ ] لا يحتاج caller لمعرفة platform backend.

## 3. Gate C1 — Provider store

- [ ] استبدال `provider_secrets.json` بadapter/repository يستخدم `AgentSecretStore`.
- [ ] الحفاظ على instance UUID scoping وsummary/masking semantics.
- [ ] migration: lock legacy -> read -> write each target -> read/compare -> commit marker/reference -> delete legacy.
- [ ] failure يبقي legacy bytes usable ولا يعلن migration ناجحة.
- [ ] corrupted legacy backup لا يطبع raw payload.
- [ ] CLI والdaemon concurrent access لا يفقد updates.

### C1 Exit

- [ ] Provider runtime يعمل بعد restart من backend الجديد.
- [ ] legacy file يحذف فقط بعد verification الكامل.

## 4. Gate C2 — MCP store

- [ ] نقل bearer، secret headers/env/args، OAuth access/refresh/client secret إلى namespace MCP.
- [ ] config documents تبقى non-secret references فقط.
- [ ] server deletion/replacement لا يحذف secret خارج mutation صريحة ومتحققة.
- [ ] migration من `mcp_secrets.json` وlegacy inline MCP values idempotent وذرية.
- [ ] materialization يحدث عند owning MCP connection/launch فقط.
- [ ] snapshots/import/export/errors لا تكشف values أو reusable hashes.

### C2 Exit

- [ ] MCP server يحصل على أسراره وحده.
- [ ] Shell وProvider sibling لا يستطيعان resolution عبر public capability.

## 5. Gate C3 — platform/headless failure semantics

- [ ] macOS Keychain وWindows DPAPI tests تغطي namespace/read/write/delete والفشل.
- [ ] Linux selected Secret Service temporary failure يفشل مغلقًا ولا يسقط إلى owner-file.
- [ ] Linux owner-file Headless يستمر مع atomic lock/write و0600/0700 وعدم ادعاء encryption.
- [ ] owner-file إلى Secret Service migration الحالية تشمل namespaces الجديدة وتتحقق من كل قيمة.
- [ ] startup لا يتوقف بالكامل بسبب owner معطل غير مطلوب؛ capability المطلوبة تفشل typed دون plaintext fallback.

### C3 Exit

- [ ] نفس contract يعمل على desktop وHeadless.
- [ ] لا تدخل secrets arguments/URLs/logs/errors.

## 6. Gate C4 — التحقق والتوثيق

- [ ] اختبارات migration success/failure/partial/restart/concurrency/idempotence.
- [ ] اختبارات legacy deletion after verification فقط.
- [ ] تحديث provider وMCP وauth technical docs وQA matrices.
- [ ] تحديث أقرب contracts عند تغير storage ownership.

### C4 Exit / Definition of Done

- [ ] لا يبقى Provider/MCP plaintext store بعد migration ناجحة.
- [ ] فشل migration لا يفقد بيانات ولا ينتج split authority غامضة.
- [ ] كل backend موصوف بحدوده الحقيقية.
- [ ] analyzer والاختبارات المركزة والكاملة المطلوبة ناجحة.

## 7. سيناريو النجاح

ينطلق daemon بProvider وMCP legacy secrets. يكتب كل قيمة في backend المحدد للنظام، يقرأها للتحقق، يحول configs إلى references، ثم يحذف legacy files. عند حقن فشل في منتصف العملية تبقى المصادر القديمة سليمة ويستطيع restart إعادة المحاولة دون duplicate أو فقد.

## 8. خارج النطاق

- Client credentials.
- إعطاء project commands أسرارًا عامة.
- destination-bound egress proxy.
- تغيير Linux owner-file إلى encrypted file بلا key owner مستقل.

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
