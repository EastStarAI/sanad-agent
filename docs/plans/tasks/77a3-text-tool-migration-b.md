---
title: "Task 77a3: Text Tool Migration B"
status: "pending"
current_gate: "Waiting"
depends_on: "77a2"
file_budget: 10
evidence_id: "77a"
evidence_fingerprint: "sha256:477c6a964da28b0914da3cb0f52881421561ccd9f8afd859fc6833380353bc43"
---

# Task 77a3: ترحيل أدوات Workspace النصية

## Goal

ترحيل handlers القراءة/الكتابة/التعديل والبحث إلى النتيجة typed مع بقاء catalog behavior والنصوص كما هي.

## Locked scope

- `file_read`, `file_write`, `file_edit`, `search_glob`, و`search_grep` فقط.
- لا image logic ولا catalog registration جديدة.

## Gates

### R0 — Evidence
- [ ] حل packet 77a وتأكيد fingerprint.

### A1 — Handler migration
- [ ] تحويل handlers الخمسة إلى constructors النصية.
- [ ] إبقاء error wording/path policy/replay flags ثابتة.

### A2 — Runtime compatibility
- [ ] تحديث fixtures المتأثرة فقط.
- [ ] إثبات أن `LocalRuntimeCatalog` وpermission suspension لا تتغيران.

### A3 — Verification
- [ ] analyzer واختبارات workspace tools المركزة ناجحة.

## Acceptance criteria

- [ ] كل نتيجة workspace text تطابق baseline الحالية.
- [ ] لا يدخل block غير نصية في أي handler بهذه الدفعة.

## Definition of Done

- [ ] `cd agent && set -o pipefail; fvm dart analyze 2>&1 | tail -5`
- [ ] `cd agent && set -o pipefail; fvm dart test test/capabilities/file_read_handler_test.dart test/capabilities/file_edit_handler_test.dart test/capabilities/search_handlers_test.dart test/capabilities/runtime_catalog_test.dart 2>&1 | tail -5`
- [ ] تحديث المهمة والخطة وreference parity.
