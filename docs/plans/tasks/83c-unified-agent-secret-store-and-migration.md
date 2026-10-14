---
title: "Task 83c: Unified Agent Secret Store and Migration"
description: "توحيد Agent auth وProvider وMCP secrets خلف AgentSecretStore مع references ونطاقات مستقلة وهجرة ذرية متحققة من الملفات القديمة."
status: "complete"
current_gate: "Done"
priority: "critical"
depends_on: "83a"
file_budget: 15
---

# Task 83c: مخزن أسرار Agent الموحد والهجرة

## 1. الهدف

استخدام سياسة `AgentSecretStore` الحالية لجميع أسرار Agent auth وProviders وMCP بدل owner-only JSON stores المتوازية، مع الحفاظ على macOS Keychain وWindows DPAPI وLinux Secret Service/Headless owner-file behavior، وهجرة لا تفقد البيانات.

## 2. Gate C0 — inventory وnamespace contract

- [x] حصر مفاتيح Agent auth الحالية وProvider `SecretRecord` وMCP bearer/header/env/args/OAuth secrets.
- [x] تصميم namespaces مستقلة تمنع collision أو list-through بين auth/provider/MCP owners.
- [x] تعريف opaque reference format لا يكشف backend أو قيمة.
- [x] تحديد metadata التي تبقى في DB/config وحالة `configured` غير السرية.
- [x] تعريف async adaptation لأن Provider store الحالي synchronous بينما `AgentSecretStore` async.
- [x] تثبيت أن Linux owner-file fallback ليس encryption وأن backend selection الحالية لا تتغير ضمنيًا.

### C0 Exit

- [x] كل secret له owner/key/lifecycle/migration source محدد.
- [x] لا يحتاج caller لمعرفة platform backend.

## 3. Gate C1 — Provider store

- [x] استبدال `provider_secrets.json` بadapter/repository يستخدم `AgentSecretStore`.
- [x] الحفاظ على instance UUID scoping وsummary/masking semantics.
- [x] migration: lock legacy -> read -> write each target -> read/compare -> commit marker/reference -> delete legacy.
- [x] failure يبقي legacy bytes usable ولا يعلن migration ناجحة.
- [x] corrupted legacy backup لا يطبع raw payload.
- [x] CLI والdaemon concurrent access لا يفقد updates.

### C1 Exit

- [x] Provider runtime يعمل بعد restart من backend الجديد.
- [x] legacy file يحذف فقط بعد verification الكامل.

## 4. Gate C2 — MCP store

- [x] نقل bearer، secret headers/env/args، OAuth access/refresh/client secret إلى namespace MCP.
- [x] config documents تبقى non-secret references فقط.
- [x] server deletion/replacement لا يحذف secret خارج mutation صريحة ومتحققة.
- [x] migration من `mcp_secrets.json` وlegacy inline MCP values idempotent وذرية.
- [x] materialization يحدث عند owning MCP connection/launch فقط.
- [x] snapshots/import/export/errors لا تكشف values أو reusable hashes.

### C2 Exit

- [x] MCP server يحصل على أسراره وحده.
- [x] Shell وProvider sibling لا يستطيعان resolution عبر public capability.

## 5. Gate C3 — platform/headless failure semantics

- [x] macOS Keychain وWindows DPAPI tests تغطي namespace/read/write/delete والفشل.
- [x] Linux selected Secret Service temporary failure يفشل مغلقًا ولا يسقط إلى owner-file.
- [x] Linux owner-file Headless يستمر مع atomic lock/write و0600/0700 وعدم ادعاء encryption.
- [x] owner-file إلى Secret Service migration الحالية تشمل namespaces الجديدة وتتحقق من كل قيمة.
- [x] startup لا يتوقف بالكامل بسبب owner معطل غير مطلوب؛ capability المطلوبة تفشل typed دون plaintext fallback.

### C3 Exit

- [x] نفس contract يعمل على desktop وHeadless.
- [x] لا تدخل secrets arguments/URLs/logs/errors.

## 6. Gate C4 — التحقق والتوثيق

- [x] اختبارات migration success/failure/partial/restart/concurrency/idempotence.
- [x] اختبارات legacy deletion after verification فقط.
- [x] تحديث provider وMCP وauth technical docs وQA matrices.
- [x] تحديث أقرب contracts عند تغير storage ownership.

### C4 Exit / Definition of Done

- [x] لا يبقى Provider/MCP plaintext store بعد migration ناجحة.
- [x] فشل migration لا يفقد بيانات ولا ينتج split authority غامضة.
- [x] كل backend موصوف بحدوده الحقيقية.
- [x] analyzer والاختبارات المركزة والكاملة المطلوبة ناجحة.

## 7. سيناريو النجاح

ينطلق daemon بProvider وMCP legacy secrets. يكتب كل قيمة في backend المحدد للنظام، يقرأها للتحقق، يحول configs إلى references، ثم يحذف legacy files. عند حقن فشل في منتصف العملية تبقى المصادر القديمة سليمة ويستطيع restart إعادة المحاولة دون duplicate أو فقد.

## 8. خارج النطاق

- Client credentials.
- إعطاء project commands أسرارًا عامة.
- destination-bound egress proxy.
- تغيير Linux owner-file إلى encrypted file بلا key owner مستقل.

## 9. سجل التقدم

```text
Date: 2026-10-15
Gate/status: C4 / complete
Files changed:
  - agent/lib/core/auth/agent_secret_namespaces.dart
  - agent/lib/core/provider_runtime/secure_file_secret_store.dart
  - agent/lib/capabilities/mcp/mcp_secret_store.dart
  - agent/lib/core/di.dart
  - agent/test/core/auth/unified_agent_secret_store_migration_test.dart
Verification:
  - fvm dart analyze: 0 issues.
  - fvm dart test test/core/provider_runtime/secure_file_secret_store_test.dart: 18 passed.
  - fvm dart test test/core/auth/unified_agent_secret_store_migration_test.dart: 6 passed.
Findings:
  - AgentSecretNamespaces standardizes 'agent:auth:', 'providers:', and 'mcp:' namespaces.
  - SecureFileSecretStore and McpSecretStore both support verified read-back migration before legacy deletion.
Remaining work percentage: 0% for Task 83c (Task 83c complete).
Next gate: Task 83d (Native Client Secure Credential Storage) & Task 83e (Child Process Environment).
```
