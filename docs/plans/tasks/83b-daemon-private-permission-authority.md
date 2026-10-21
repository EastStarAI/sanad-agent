---
title: "Task 83b: Daemon-Private Permission Authority"
description: "نقل permission mode وexecution/discovery policy وdurable grants إلى قاعدة Agent الخاصة وإلغاء أي سلطة لملفات Workspace دون هجرة الأذونات القديمة."
status: "in_review"
current_gate: "Port review"
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
- [ ] تحديد retention عند حذف Workspace وإعادة إضافتها بUUID جديدة/قديمة.

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

## Port Record (2026-10-21, branch `feat/83-port`)

The 2026-10-15 progress log above was written on `feat/task-83-secret-isolation-and-terminal-hardening` and is superseded. That work was re-reviewed against this task file while porting onto the post-Task-110 owners; no checkbox is trusted without the evidence below.

- **Ported:** `workspace_security_policies` (additive table created by `AgentStateDatabase`), `WorkspaceSecurityPolicyRepository`, and `WorkspacePolicyStore`; `PermissionManager`, the workspace handler, and `WorkspaceCliService` consume them. `SanadSettingsStore` no longer reads or writes policy.
- **Defects fixed:**
  - Path-keyed saves (every `PermissionManager` grant) inserted rows with an empty `workspace_id` primary key, so grants from different workspaces collided in one row. Policy is now keyed by registered UUID or `exec_root:` key only.
  - `getPolicyByPath` fallback let a new workspace UUID at a reused path inherit another workspace's grants, and an id lookup ignored path changes. Rows now apply only while their recorded root equals the current root.
  - `savePolicy` was read-then-write with an optional revision check: lost updates. Writes are a transaction with compare-and-swap on `revision`.
  - A static in-memory fallback store was process-wide shared state. Removed; without the state database reads return defaults and writes fail closed.
  - "Owner" was `!managed_remote`, a flag the cloud adapter adds only to filesystem commands, so every cloud `workspace.set_permission_mode` was treated as the owner. Authority now comes from the receiving transport.
  - Turn metadata `allow_all_tools` (and `permission_mode: full_access`) from any Gateway turn bypassed every approval. It is now honoured only on stamped `local_owner` turns, and `permission_mode` never grants.
  - The remote CLI relay could launder cloud authority into owner authority by running CLI commands over the loopback gateway. It now runs under its relay authority.
  - `WorkspaceCliService` fell back to a local write after a Gateway rejection. Rejections are now final.
  - Error envelopes echoed raw exception text. They now return typed codes.
- **Open:** retention when a workspace is removed leaves an orphan row that is never read (new registration gets a new UUID). Durable grants are still recorded from any responder of an explicit approval.
- **Evidence:** `workspace_security_policy_repository_test.dart` (11), `permission_manager_test.dart` (16), `workspace_command_handler_test.dart` (16), `command_authority_test.dart` (9), `sanad_bridge_test.dart` policy group.

## Port Record, Round 2 (2026-10-21)

- **A, trust decision:** cloud clients can widen policy, record durable grants and run remote CLI `--allow-all-tools`; a cloud `allow_all_tools` turn would be honoured, but no Client sends one (live r2 S3c: blocked by design, not a defect). Independent-review defects 3 (remote CLI `--allow-all-tools`) and 4 (a remote approver writing durable grants) are **accepted by the user decision** and are no longer defects.
- **B2, scope forgery fixed:** `WorkspacePolicyScope.fromMetadata` preferred the workspace map while tools ran in `execution_root`, so a mismatch or missing id applied the wrong policy or Direct defaults to a Protected workspace and skipped its deny list. Scope now comes only from the validated tool root via `resolveForRoot`; nested registered roots combine most restrictively; relocation keeps the policy with the workspace id instead of resetting it. Evidence: `workspace_policy_scope_test.dart` (red logs `temp/83/r2-b2-red*.log`).
- **B6, broadcast contents:** `workspace.policy_changed` and `get_policy` carry the full command allow/deny lists. Accepted with the cloud trusted; documented.
- **Downgrade note:** an older Agent on the same Home ignores the policy table and still honours a repository's `.sanad/settings.json` `full_access`.
- **Execution roots (user decision 2026-10-21):** roots are not restricted in Full Access. A remote-chosen root such as `$HOME` or `~/.sanad` gives approval-free file access in Full Access, which is accepted. Follow-up proposal only, no code: outside Full Access, require approval for a root that is not inside a registered workspace.

## Port Record, Round 3 (2026-10-21, live r1 follow-ups)

- **D4:** re-adding a removed folder never restored its policy (registration always mints a new id), but the removed workspace's row with grants and Full Access stayed in `state.db`. Workspace removal now deletes it in the same transaction (`SessionDB.state`); `exec_root:` rows are kept. Evidence: `test/interfaces/workspace_policy_removal_test.dart`.
- **D2:** `workspace.policy_changed` reached only the requester; it now goes through `GatewayManager.publishFamilyEvent` to every client (pre-existing on main). Evidence: gateway, handler and client watch tests.
- `sanad ws policy` shows execution mode and host discovery (read-only).

## Port Record, Round 4 (2026-10-21, live r2 follow-ups)

- **D5:** a recorded workspace grant raised the revision without a broadcast, so the next Full Access toggle failed as stale with no feedback. `WorkspacePolicyStore` now announces every revision change (modes and grants) once through `WorkspacePolicyAnnouncer`; the client retries a stale toggle once on a fresh read and otherwise shows a localized message. Rejections log their typed code.
- **D6:** user and policy denials raise `ToolPermissionDeniedException` and are recorded as `permission_denied`, carried on the live `tool_result`.
- **S3c:** blocked by design; no Client sends `allow_all_tools`. Docs corrected.

## Port Record, Round 5 (2026-10-21, live r3)

- **D6 reopened and fixed:** the round-4 test exercised a response shape the executor never produces. The live tool event, the durable resume path and `get_session_history` rows now all carry `errorCode` (`permission_denied` for a denial), and the client seam test uses the exact agent payloads.
