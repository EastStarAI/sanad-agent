---
title: "Task 89c: Workspace Auto-Discovery and Management CLI"
description: "بناء مجموعة أوامر `sanad ws` لإدارة مساحات العمل، وتفعيل الاكتشاف التلقائي لمساحة العمل بناءً على المجلد الحالي (CWD)."
status: "completed"
current_gate: "Completed"
priority: "high"
depends_on: "Task 89b complete"
file_budget: 12
reference_grounding: "required"
evidence_id: "89c"
parallel_with: "Task 89d"
---

# Task 89c: Workspace Auto-Discovery and Management CLI

## 1. الهدف

توفير تجربة مطور فائقة لمساحات العمل من الطرفية، تتيح ربط الـ CLI تلقائياً بمشروع العمل الحالي (`CWD`)، وإتاحة أوامر متكاملة لاستعراض، تبديل، إضافة، وفحص سياسات الأمان وشجرة ملفات مساحات العمل.

## Gate A0 — Invariants and Workflows

- [x] فحص المجلد الحالي `CWD`: إذا كان يقع ضمن مساحة عمل مسجلة في `LocalWorkspaceRuntimeService` يتم اختياره تلقائياً.
- [x] إذا لم يكن مسجلاً، توفير خيار التسجيل السريع (`sanad ws add .`).
- [x] ربط أوامر `sanad ws` بنقاط نهاية البوابة `WorkspaceCommandHandler`.

## Gate A1 — Workspace Commands Implementation

- [x] `sanad ws list`: جدول منسق يعرض (الاسم، المسار، السياسة الأمنية، علامة `*` للنشط).
- [x] `sanad ws current`: تفاصيل مساحة العمل الحالية وخوادم MCP المرتبطة بها.
- [x] `sanad ws switch <name|id>`: تبديل مساحة العمل النشطة في ملف الحالة المحلي.
- [x] `sanad ws add [path]`: تسجيل مجلد كود موجود.
- [x] `sanad ws create <name>`: إنشاء مجلد جديد ومساحة عمل.
- [x] `sanad ws tree [path]`: استدعاء `browseWorkspaceTree` وعرض الشجرة في الطرفية.
- [x] `sanad ws policy <default|full_access>`: تغيير سياسة الأمان وتنفيذ الأدوات.

## Gate A2 — Verification (DoD)

- [x] اختبارات الاكتشاف التلقائي عبر مجلدات متداخلة ومسارات نسبية ومطلقة.
- [x] اختبارات التفاعل مع سياسات الأمان والتأكد من انطباقها على الأدوات.

## Verification Evidence

- `agent/lib/cli/workspace/workspace_locator.dart`: Implemented `WorkspaceLocator` with path ancestry climbing, exact & nested folder detection, and resolution priority (explicit flag -> CWD match -> stored state).
- `agent/lib/cli/workspace/cli_workspace_state.dart`: Implemented `CliWorkspaceStateStore` for persisting active workspace to `SANAD_HOME/cli_state.json`.
- `agent/lib/cli/workspace/workspace_cli_service.dart`: Dual-mode unified service bridging `LocalGatewayCliClient` queries and offline in-process `LocalWorkspaceRuntimeService` fallback.
- `agent/lib/cli/runner/commands/workspace_command.dart`: Complete implementations of `list`, `current`, `switch`, `select`, `add`, `create`, `tree`, and `policy`.
- `agent/test/cli/workspace_command_test.dart`: 18 passing tests verifying locator precision, ancestry matching, state persistence, command formatting, tree rendering, policy transitions, and dual-mode dispatch.
- `fvm dart analyze`: Zero errors, zero warnings.
- `fvm dart test test/cli/workspace_command_test.dart`: 18/18 tests passed.
- `fvm dart test test/cli/`: 74/74 tests passed.
