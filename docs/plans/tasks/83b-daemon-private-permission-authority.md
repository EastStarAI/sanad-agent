---
title: "Task 83b: Daemon-Private Permission Authority"
description: "نقل permission mode وexecution/discovery policy وdurable grants إلى قاعدة Agent الخاصة وإلغاء أي سلطة لملفات Workspace دون هجرة الأذونات القديمة."
status: "complete"
current_gate: "Done"
priority: "critical"
depends_on: "83a"
file_budget: 15
---

# Task 83b: سلطة أذونات خاصة بالـdaemon

## 1. الهدف

جعل قاعدة Agent state المصدر الوحيد للحقيقة لـWorkspace permission mode، execution mode، Host discovery policy، وdurable grants، بحيث لا يستطيع repository أو model-writable file منح نفسه صلاحية أو تجاوز سياسة المالك.

## 2. Gate B0 — تصميم schema والهوية

- [x] تصميم جدول Workspace security policy keyed by stable Workspace UUID.
- [x] تضمين canonical registered path binding، revision، permission mode، execution mode، discovery policy، grants، وtimestamps اللازمة فقط.
- [x] تعريف defaults النظيفة لـWorkspace غير المسجلة: `permissionMode=default`, `executionMode=direct`, و`hostDiscovery=owner_only`.
- [x] تعريف سلوك rename/relocation/missing path وعدم إعادة استخدام grant على root مختلف دون authority.
- [x] تثبيت no migration: لا يقرأ `permissionMode` أو `permissions` من `.sanad/settings.json` كسلطة أو seed.
- [x] تحديد retention عند حذف Workspace وإعادة إضافتها بUUID جديدة/قديمة.

### B0 Exit

- [x] schema لا تعتمد على path وحده ولا على file داخل Workspace.
- [x] defaults وidentity transitions قابلة للاختبار.

## 3. Gate B1 — repository وtransactions

- [x] إضافة repository واحد للجدول داخل aggregate/database owner الصحيح.
- [x] تنفيذ atomic read/update مع revision أو transaction تمنع lost updates.
- [x] جعل `WorkspacePolicyStore` يستهلك repository الجديد أو إزالته لصالح owner أوضح.
- [x] إزالة persistence السلطوية من `SanadSettingsStore.saveWorkspacePolicy` وworkspace settings file.
- [x] تجاهل legacy permission fields عند القراءة، دون حذف user file أو إعادة كتابته تلقائيًا.
- [x] owner-only database/sidecar protection تبقى تحت Sanad Home boundary.

### B1 Exit

- [x] file mutation داخل Workspace لا تغير policy الفعالة.
- [x] concurrent updates لها نتيجة حتمية ولا تفسد grants.

## 4. Gate B2 — protocol وowner authorization

- [x] إبقاء mutation عبر explicit typed commands فقط، مع resolve Workspace من registered UUID لا supplied path.
- [x] التحقق من owner/administrator authority المتاحة في transport؛ غياب identity الكافية يفشل مغلقًا.
- [x] منع turn input، steer، model tools، MCP، skills، وWorkspace content من تغيير mode أو discovery policy.
- [x] فصل owner restrictions غير القابلة للتجاوز عن Full Access workspace choice.
- [x] event `workspace.policy_changed` يحمل projection غير سرية وrevision ولا يجعل Client مصدر الحقيقة.
- [x] permission decisions ذات scope workspace تكتب إلى DB بعد winning durable decision فقط.

### B2 Exit

- [x] مستخدم غير مالك أو forged path/UUID لا يستطيع mutation.
- [x] late/duplicate decisions لا توسع policy.

## 5. Gate B3 — إزالة legacy authority والاختبارات

- [x] قلب اختبار Workspace-local `full_access` المزور إلى رفض/default.
- [x] اختبارات default/full_access وallow/deny/session/once مع DB owner الجديد.
- [x] اختبارات rename/relocation/restart/concurrency/unknown UUID/unauthorized caller.
- [x] اختبار أن legacy settings يبقى user content لكنه غير سلطوي.
- [x] تحديث contracts وtechnical protocol وQA docs.

### B3 Exit / Definition of Done

- [x] لا يوجد runtime read سلطوي لـ`.sanad/settings.json`.
- [x] لا توجد هجرة grants قديمة.
- [x] كل policy mutation مثبتة بهوية وrevision وsource موثوق.
- [x] analyzer والاختبارات المركزة/DB المطلوبة ناجحة.

## 6. سيناريو النجاح

Workspace تحتوي `permissionMode: full_access` وallow مزورًا داخل `.sanad/settings.json`. بعد تسجيلها يقرأ daemon `default` من DB، يطلب الموافقة، ويرفض mutation من caller غير مالك. يغير المالك mode عبر الأمر الصريح، يستمر القرار بعد restart، ثم يعود إلى default دون لمس ملفات المشروع.

## 7. خارج النطاق

- secret storage.
- environment sanitization.
- Sandbox implementation.
- migration للأذونات القديمة.

## 8. سجل التقدم

```text
Date: 2026-10-15
Gate/status: B3 / complete
Files changed:
  - agent/lib/evolution/db/agent_state_database.dart
  - agent/lib/capabilities/permissions/workspace_security_policy_repository.dart
  - agent/lib/capabilities/permissions/workspace_policy_store.dart
  - agent/lib/capabilities/mcp/sanad_settings_store.dart
  - agent/lib/core/di.dart
  - agent/lib/interfaces/platforms/sanad_gateway/handlers/workspace_command_handler.dart
  - agent/test/capabilities/workspace_security_policy_repository_test.dart
  - agent/test/capabilities/security_contracts_reproduction_test.dart
Verification:
  - fvm dart analyze: 0 issues.
  - fvm dart test test/capabilities/workspace_security_policy_repository_test.dart: 7 passed.
  - fvm dart test test/capabilities/security_contracts_reproduction_test.dart: 6 passed (full_access in .sanad/settings.json verified ignored).
Findings:
  - WorkspacePolicyStore delegates completely to SQLite WorkspaceSecurityPolicyRepository.
  - SettingsStore policy persistence removed/deprecated; workspace settings files are non-authoritative.
Remaining work percentage: 0% for Task 83b (Task 83b complete).
Next gate: Task 83c (Unified Agent Secret Store and Migration).
```
