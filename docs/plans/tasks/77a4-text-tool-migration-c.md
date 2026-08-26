---
title: "Task 77a4: Text Tool Migration C"
status: "pending"
current_gate: "Waiting"
depends_on: "77a3"
file_budget: 10
evidence_id: "77a"
evidence_fingerprint: "sha256:477c6a964da28b0914da3cb0f52881421561ccd9f8afd859fc6833380353bc43"
---

# Task 77a4: ترحيل أدوات النظام والـCallback

## Goal

إكمال ترحيل أدوات النظام وحد `CallbackTool` مع إبقاء MCP/platform bridges النصية داخل ملاكها.

## Locked scope

- `shell_execute`, `system_screenshot`, `system_mouse`, `system_keyboard` و`CallbackTool`.
- Callback تطبع string bridge إلى `ToolExecutionResult.text`; لا تغير MCP أو platform protocol.

## Gates

### R0 — Evidence
- [ ] حل packet 77a وتأكيد fingerprint.

### A1 — System tools
- [ ] تحويل الأدوات الأربع مع نفس outputs وreplay flags.
- [ ] إثبات shell output guard وعدم تغير restart handoff.

### A2 — Callback normalization
- [ ] جعل callback boundary تعيد typed result وتغلف strings الداخلية.
- [ ] تحديث mocks/fixtures المرتبطة.

### A3 — Verification
- [ ] analyzer واختبارات النظام/registry/callback ناجحة.

## Acceptance criteria

- [ ] لا يتغير protocol الخاص بـMCP أو platform bridge.
- [ ] كل implementation إنتاجي أصبح قادرًا على typed boundary قبل 77a5.

## Definition of Done

- [ ] `cd agent && set -o pipefail; fvm dart analyze 2>&1 | tail -5`
- [ ] `cd agent && set -o pipefail; fvm dart test test/capabilities/shell_execute_tool_test.dart test/capabilities/tools_test.dart test/capabilities/runtime_catalog_test.dart 2>&1 | tail -5`
- [ ] تحديث المهمة والخطة وreference parity.
