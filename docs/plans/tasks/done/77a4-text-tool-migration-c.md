---
title: "Task 77a4: Text Tool Migration C"
status: "complete"
current_gate: "complete"
remaining_estimate: "0%"
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
- [x] حل packet 77a وتأكيد fingerprint.

### A1 — System tools
- [x] تحويل الأدوات الأربع مع نفس outputs وreplay flags.
- [x] إثبات shell output guard وعدم تغير restart handoff.

### A2 — Callback normalization
- [x] جعل callback boundary تعيد typed result وتغلف strings الداخلية.
- [x] تحديث mocks/fixtures المرتبطة.

### A3 — Verification
- [x] analyzer واختبارات النظام/registry/callback ناجحة.

## Acceptance criteria

- [x] لا يتغير protocol الخاص بـMCP أو platform bridge.
- [x] كل implementation إنتاجي أصبح قادرًا على typed boundary قبل 77a5.

## Definition of Done

- [x] `cd agent && set -o pipefail; fvm dart analyze 2>&1 | tail -5`
- [x] `cd agent && set -o pipefail; fvm dart test test/capabilities/shell_execute_tool_test.dart test/capabilities/tools_test.dart test/capabilities/runtime_catalog_test.dart 2>&1 | tail -5`
- [x] تحديث المهمة والخطة وreference parity.

## Progress log

### 2026-09-14 — R0 complete

- Status transition: `pending/Waiting` → `in_progress/A1`.
- Resolver: `status=ready`, task `77a`.
- Evidence fingerprint matched: `sha256:477c6a964da28b0914da3cb0f52881421561ccd9f8afd859fc6833380353bc43`.
- Boundary decision: system tools own typed output; `CallbackTool` wraps its existing string callbacks without changing MCP/platform protocols; shell terminal state supplies error codes without output parsing.
- Remaining estimate: `75%`.
- Next gate: `A1 — System tools`.

### 2026-09-14 — A1 complete

- Status transition: `A1` → `A2`.
- Implementation: shell, screenshot, mouse, and keyboard now own typed text results; legacy `execute` is their exact projection.
- Shell invariants: encoded payload text, bounded stdout/stderr, progress snapshots, permission ordering, process ownership, cancellation, and restart handoff are unchanged.
- Typed errors: timeout is assigned `timedOut` from terminal state; other shell failures use `executionFailed`, with no string parsing.
- Verification: shell suite passed with 9 tests and 2 platform-specific skips.
- Remaining estimate: `45%`.
- Next gate: `A2 — Callback normalization`.

### 2026-09-14 — A2 complete

- Status transition: `A2` → `A3`.
- Implementation: `CallbackTool.executeResult` wraps the existing string callback result in typed text; `execute` projects it back exactly.
- Context/protocol compatibility: callback arguments and `ToolContext` are forwarded unchanged; MCP and platform callback implementations remain string-owned.
- Verification: 19 tools/runtime-catalog tests passed, including callback normalization and MCP/platform paths.
- Remaining estimate: `20%`.
- Next gate: `A3 — Verification`.

### 2026-09-14 — A3 and task complete

- Status transition: `A3` → `complete`.
- Verification: analyzer clean; 28 tests passed with 2 platform-specific skips; `git diff --check` passed; Graphify rebuilt.
- Contracts: callback normalization and shell typed error-state rules are recorded in the closest tools contract.
- Reference parity: all packet obligations for this text-only batch are satisfied.
- File budget: 10 files, at the declared ceiling.
- Remaining estimate: `0%`.
- Next task: `77a5 — Coordinator and Message Integration`.
