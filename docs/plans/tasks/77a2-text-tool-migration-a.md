---
title: "Task 77a2: Text Tool Migration A"
status: "pending"
current_gate: "Waiting"
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
- [ ] حل packet 77a وتأكيد fingerprint.

### A1 — Transitional boundary
- [ ] إضافة bridge موثقة ومحددة الإزالة في 77a5.
- [ ] إضافة text constructor تحفظ النص byte-for-byte.

### A2 — Batch migration
- [ ] ترحيل الأدوات الأربع واختبارات النجاح/الخطأ الحالية.
- [ ] إثبات عدم تغير replay metadata أو schemas.

### A3 — Verification
- [ ] analyzer والاختبارات المركزة ناجحة.
- [ ] سجل الملفات ضمن السقف.

## Acceptance criteria

- [ ] كل أداة في الدفعة تنتج نفس `displayText` السابقة.
- [ ] الأدوات غير المرحلة تستمر عبر bridge ولا تكسر build.

## Definition of Done

- [ ] `cd agent && set -o pipefail; fvm dart analyze 2>&1 | tail -5`
- [ ] `cd agent && set -o pipefail; fvm dart test test/capabilities/memory_tool_test.dart test/capabilities/tools_test.dart 2>&1 | tail -5`
- [ ] تحديث المهمة والخطة وreference parity.
