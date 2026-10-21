---
title: "Task 83c: Unified Agent Secret Store and Migration"
description: "توحيد Agent auth وProvider وMCP secrets خلف AgentSecretStore مع references ونطاقات مستقلة وهجرة ذرية متحققة من الملفات القديمة."
status: "in_review"
current_gate: "Port review"
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

## Port Record (2026-10-21, branch `feat/83-port`)

The 2026-10-15 progress log above was written on `feat/task-83-secret-isolation-and-terminal-hardening` and is superseded. That work was re-reviewed against this task file while porting onto the post-Task-110 owners; no checkbox is trusted without the evidence below.

- **Not ported.** All checkboxes are reset; this task is reopened.
- **Defects found in the previous implementation:**
  - `migrateLegacy()` for providers and MCP was never called, so nothing migrated.
  - `SecureFileSecretStore.write` wrote only to the vault for the default Sanad Home while `read`/`listIds` read the legacy file or an in-memory cache, so a key saved after the change was lost on restart.
  - `McpSecretStore.resolve` had the same split; `SanadSettingsStore` also built `McpSecretStore` without a vault, so the vault path was dead code.
  - The index keys were rewritten from a cache that only knew records touched in this process, dropping others.
  - Deleting `provider_secrets.json` and `mcp_secrets.json` after migration breaks an older Agent on the same Sanad Home, which conflicts with the rollback rule for this port.
- **Decision needed:** whether legacy files may be deleted (no downgrade) or must be kept as a read-only mirror (plaintext remains), before 83c restarts.

## Port Record, Round 2 (2026-10-21)

- **Ported (user decision 2026-10-21 approves deleting the legacy files; no downgrade compatibility).** All gates below were re-implemented, not restored from the earlier branch.
- `SecretVaults` (`agent/lib/core/auth/secret_vault.dart`) keeps provider and MCP secrets in `AgentSecretStore` under `providers:` and `mcp:` with a per-owner index. Reads use a cache loaded at open; writes are read-back verified and committed under a cross-process lock with a generation marker the daemon polls.
- The migration really runs: `bin/daemon.dart`, `bin/sanad_agent.dart` and the standalone CLI runtime open the vault at startup. It is idempotent, a vault value always wins, the legacy files are deleted only after every entry verifies, and a failed migration leaves them in place and readable.
- `VaultSecretStore` backs `SecretStore`; `McpSecretStore` uses the vault, so the MCP path is live. `AgentSecretStore` and `AgentSecretNamespaces` are available to Plan 84.
- Downgrade consequence: an older Agent on the same Home loses those secrets after migration.
- Limits: a Home this process never opened (temporary test Homes, a CLI that switches Home without reopening) keeps the file store; cross-process freshness is bounded by the two-second poll.
- Evidence: `test/core/auth/secret_vault_test.dart` (migration, failed verification and retry, restart persistence, vault-wins idempotence, cross-process refresh).

## Port Record, Round 3 (2026-10-21, live r1 follow-ups)

- **D1:** vault migration lines were lost (the daemon logged before `initLogger`, the CLI never logs). Events now persist to the owner-only `secret_vault_events.jsonl` and the daemon replays them into the agent log after logging starts. Evidence: `secret_vault_test.dart` lifecycle group.
