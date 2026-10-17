---
title: "Task 77a3: Text Tool Migration B"
status: "complete"
current_gate: "complete"
remaining_estimate: "0%"
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
- [x] حل packet 77a وتأكيد fingerprint.

### A1 — Handler migration
- [x] تحويل handlers الخمسة إلى constructors النصية.
- [x] إبقاء error wording/path policy/replay flags ثابتة.

### A2 — Runtime compatibility
- [x] تحديث fixtures المتأثرة فقط.
- [x] إثبات أن `LocalRuntimeCatalog` وpermission suspension لا تتغيران.

### A3 — Verification
- [x] analyzer واختبارات workspace tools المركزة ناجحة.

## Acceptance criteria

- [x] كل نتيجة workspace text تطابق baseline الحالية.
- [x] لا يدخل block غير نصية في أي handler بهذه الدفعة.

## Definition of Done

- [x] `cd agent && set -o pipefail; fvm dart analyze 2>&1 | tail -5`
- [x] `cd agent && set -o pipefail; fvm dart test test/capabilities/file_read_handler_test.dart test/capabilities/file_edit_handler_test.dart test/capabilities/search_handlers_test.dart test/capabilities/runtime_catalog_test.dart 2>&1 | tail -5`
- [x] تحديث المهمة والخطة وreference parity.

## Progress log

### 2026-09-14 — R0 complete

- Status transition: `pending/Waiting` → `in_progress/A1`.
- Resolver: `status=ready`, task `77a`.
- Evidence fingerprint matched: `sha256:477c6a964da28b0914da3cb0f52881421561ccd9f8afd859fc6833380353bc43`.
- Interface finding: workspace handlers feed the current string callback boundary in `LocalRuntimeCatalog`; each migration will retain `execute` as an exact text projection over typed `executeResult`, without catalog or permission changes.
- Remaining estimate: `75%`.
- Next gate: `A1 — Handler migration`.

### 2026-09-14 — A1 complete

- Status transition: `A1` → `A2`.
- Implementation: all five scoped handlers now construct text-only `ToolExecutionResult` values through `executeResult`; legacy `execute` returns their exact `displayText` projection.
- Preserved: path resolution, thrown exception wording/types, encoded JSON text, and runtime-catalog metadata.
- Focused verification: 2 typed-handler tests passed, including all five handlers and exact read projection.
- Remaining estimate: `45%`.
- Next gate: `A2 — Runtime compatibility`.

### 2026-09-14 — A2 complete

- Status transition: `A2` → `A3`.
- Fixtures: one focused typed-result fixture was added; existing handler/catalog fixtures remain authoritative for text and runtime behavior.
- Verification: 37 workspace and runtime-catalog tests passed, including external-path approval, full-access, denial, and suspended checkpoint behavior.
- Catalog diff: none; tool specs and restart replay flags remain unchanged.
- Remaining estimate: `20%`.
- Next gate: `A3 — Verification`.

### 2026-09-14 — A3 and task complete

- Status transition: `A3` → `complete`.
- Verification: analyzer clean; 39 focused handler/catalog tests passed; `git diff --check` passed; Graphify rebuilt.
- Runtime contract: typed handler authority and temporary textual catalog projection are documented in the closest `AGENTS.md`.
- Reference parity: all packet obligations for this text-only batch are satisfied.
- File budget: 9 files, below the ceiling of 10.
- Remaining estimate: `0%`.
- Next task: `77a4 — Text Tool Migration C`.
