---
title: "Task 77a1: Core Tool Result Model"
status: "complete"
current_gate: "complete"
remaining_estimate: "0%"
depends_on: "Approved Plan 77"
file_budget: 10
evidence_id: "77a"
evidence_fingerprint: "sha256:477c6a964da28b0914da3cb0f52881421561ccd9f8afd859fc6833380353bc43"
design_contract: "docs/technical/multimodal_tool_results_and_view_image.md"
---

# Task 77a1: نموذج نتيجة الأداة في Core

## Goal

إضافة النموذج serialized المقفل ودمجه اختياريًا في `Message` دون تغيير حد تنفيذ الأدوات الحالي بعد.

## Locked scope

- الأنواع في `agent/lib/core/models/`، schema version 1، blocks sealed، وprojection مشتقة.
- `Message.toolResult` لرسالة tool فقط؛ typed payload authoritative وlegacy content يبقى صالحًا.
- لا `dynamic details` ولا provider/workspace logic.

## Gates

### R0 — Evidence
- [x] resolver يعيد fingerprint المثبت ويقرأ packet 77a.

### A1 — Types
- [x] إضافة result/block/detail/error enums والتحقق من MIME/base64/dimensions/version.
- [x] منع نتيجة بلا text block ومنع `content` المتعارضة.

### A2 — Message JSON
- [x] إضافة `toolResult` وcopyWith/generated JSON.
- [x] إثبات legacy content-only parsing وtyped round trip وترتيب blocks.

### A3 — Contract and verification
- [x] تحديث `agent/lib/core/AGENTS.md` لعقد الرسالة الغنية.
- [x] تشغيل generator ثم analyzer والاختبارات المركزة.

## Acceptance criteria

- [x] malformed typed payload تفشل قبل persistence.
- [x] legacy Message تعود دون تغيير وظيفي.
- [x] `displayText` لا تخزن كحقيقة ثانية.

## Definition of Done

- [x] `cd agent && fvm dart run build_runner build --delete-conflicting-outputs`
- [x] `cd agent && set -o pipefail; fvm dart analyze 2>&1 | tail -5`
- [x] `cd agent && set -o pipefail; fvm dart test test/core/models/tool_execution_result_test.dart test/core/models/message_test.dart 2>&1 | tail -5`
- [x] تحديث الخطة وسجل gate وreference parity.

## Expected files

`agent/lib/core/models/tool_execution_result.dart`, `message.dart`, generated JSON, focused tests, `agent/lib/core/AGENTS.md`, والوثائق المالكة.

## Progress log

### 2026-09-14 — R0 complete

- Status transition: `pending` → `in_progress`; `R0` → `A1`.
- Evidence: resolver returned `ready` for packet `77a` with the pinned fingerprint after restoring the ignored worktree-local evidence store.
- Inspection: mandatory source, tests, governing contracts, and MIT licenses were read directly; the ignored run record contains the Adopt/Adapt/Reject audit.
- Open findings: no contradiction; byte-level image policy and provider translation remain in their later owning tasks.
- Remaining estimate: `90%`.
- Next gate: `A1 — Types`.

### 2026-09-14 — A1 complete

- Status transition: `A1` → `A2`.
- Files changed: `agent/lib/core/models/tool_execution_result.dart`, `agent/test/core/models/tool_execution_result_test.dart`.
- Verification: `fvm dart test test/core/models/tool_execution_result_test.dart` — 7 tests passed.
- Contract result: schema v1, sealed ordered blocks, closed detail/error values, canonical base64 and MIME/dimension validation, immutable blocks, and derived-only `displayText`.
- Remaining estimate: `60%`.
- Next gate: `A2 — Message JSON`.

### 2026-09-14 — A2 complete

- Status transition: `A2` → `A3`.
- Files changed: `agent/lib/core/models/message.dart`, generated JSON, public export, and focused message tests.
- Verification: build runner completed; focused result/message/legacy model suites passed 18 tests.
- Compatibility: content-only tool messages still parse unchanged; typed tool results remain authoritative and reject role/content divergence.
- Remaining estimate: `25%`.
- Next gate: `A3 — Contract and verification`.

### 2026-09-14 — A3 and task complete

- Status transition: `A3` → `complete`.
- Documentation/contracts: core runtime contract and multimodal technical design updated; reference-parity audit reports every adopted/adapted obligation satisfied.
- Verification: build runner succeeded; analyzer reported no issues; 13 focused tests passed; `git diff --check` passed; Graphify rebuilt successfully.
- File budget: 10 task files, at the declared ceiling.
- Open findings: none blocking; tool execution migration remains owned by `77a2`–`77a5`.
- Remaining estimate: `0%`.
- Next task: `77a2 — Text Tool Migration A`.

