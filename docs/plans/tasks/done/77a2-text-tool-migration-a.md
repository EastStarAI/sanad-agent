---
title: "Task 77a2: Text Tool Migration A"
status: "complete"
current_gate: "complete"
remaining_estimate: "0%"
depends_on: "77a1"
file_budget: 10
evidence_id: "77a"
evidence_fingerprint: "sha256:477c6a964da28b0914da3cb0f52881421561ccd9f8afd859fc6833380353bc43"
---

# Task 77a2: ترحيل أدوات النص — الدفعة A

## Goal

إضافة bridge انتقالية typed وترحيل أدوات الذاكرة والجدولة والتفويض دون تغيير النصوص.

## Locked scope

- تضيف `BaseTool.executeResult` default التي تغلف `execute` مؤقتًا.
- ترحل `delegate_task`, `memory`, `schedule_task`, و`list_scheduled_tasks` إلى typed result.
- لا يحذف `execute` القديم ولا يغير coordinator في هذه المهمة.

## Gates

### R0 — Evidence
- [x] حل packet 77a وتأكيد fingerprint.

### A1 — Transitional boundary
- [x] إضافة bridge موثقة ومحددة الإزالة في 77a5.
- [x] إضافة text constructor تحفظ النص byte-for-byte.

### A2 — Batch migration
- [x] ترحيل الأدوات الأربع واختبارات النجاح/الخطأ الحالية.
- [x] إثبات عدم تغير replay metadata أو schemas.

### A3 — Verification
- [x] analyzer والاختبارات المركزة ناجحة.
- [x] سجل الملفات ضمن السقف.

## Acceptance criteria

- [x] كل أداة في الدفعة تنتج نفس `displayText` السابقة.
- [x] الأدوات غير المرحلة تستمر عبر bridge ولا تكسر build.

## Definition of Done

- [x] `cd agent && set -o pipefail; fvm dart analyze 2>&1 | tail -5`
- [x] `cd agent && set -o pipefail; fvm dart test test/capabilities/memory_tool_test.dart test/capabilities/tools_test.dart 2>&1 | tail -5`
- [x] تحديث المهمة والخطة وreference parity.

## Progress log

### 2026-09-14 — R0 complete

- Status transition: `pending/Waiting` → `in_progress/A1`.
- Evidence: resolver returned `ready` for packet `77a` with the pinned fingerprint; the task-specific ignored run record captures the transition strategy.
- Open findings: no contradiction; bridge removal remains owned by `77a5`.
- Remaining estimate: `85%`.
- Next gate: `A1 — Transitional boundary`.

### 2026-09-14 — A1 complete

- Status transition: `A1` → `A2`.
- Files changed: transitional `BaseTool.executeResult` and focused bridge coverage.
- Verification: `fvm dart test test/capabilities/tools_test.dart` — 3 tests passed.
- Compatibility: an unported tool's exact legacy text, including trailing whitespace, is preserved.
- Remaining estimate: `60%`.
- Next gate: `A2 — Batch migration`.

### 2026-09-14 — A2 complete

- Status transition: `A2` → `A3`.
- Files changed: `delegate_task`, `memory`, `schedule_task`, and `list_scheduled_tasks` implementations plus focused tests.
- Verification: 11 focused capability tests and 8 existing evolution/delegation/scheduling regression tests passed.
- Compatibility: legacy text projections, schemas, context forwarding, and replay metadata are unchanged; typed failures use closed codes.
- Remaining estimate: `20%`.
- Next gate: `A3 — Verification`.

### 2026-09-14 — A3 and task complete

- Status transition: `A3` → `complete`.
- Documentation/contracts: capability-tools contract records typed authority, the temporary bridge, and 77a5 removal ownership; reference parity is satisfied.
- Verification: analyzer clean; 11 focused tests passed; 8 existing evolution regressions passed; `git diff --check` passed; Graphify rebuilt.
- File budget: 10 files, at the declared ceiling.
- Remaining estimate: `0%`.
- Next task: `77a3 — Text Tool Migration B`.
