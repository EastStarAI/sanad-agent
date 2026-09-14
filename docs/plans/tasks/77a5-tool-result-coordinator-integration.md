---
title: "Task 77a5: Tool Result Coordinator Integration"
status: "complete"
current_gate: "complete"
remaining_estimate: "0%"
depends_on: "77a4"
file_budget: 10
evidence_id: "77a"
evidence_fingerprint: "sha256:477c6a964da28b0914da3cb0f52881421561ccd9f8afd859fc6833380353bc43"
---

# Task 77a5: دمج النتيجة في Coordinator

## Goal

إزالة الحد الانتقالي النصي وجعل coordinator/output guard/history callbacks تعمل على النتيجة typed مع projection نصية آمنة.

## Locked scope

- حذف `Future<String> execute` بعد إثبات عدم وجود implementation إنتاجية.
- text budget تطبق على text blocks؛ image count/base64 budgets مستقلة وبترتيب tool calls.
- events/plugins تحصل على `displayText` فقط.

## Gates

### R0 — Evidence
- [x] حل packet 77a وتأكيد fingerprint.

### A1 — Final boundary
- [x] جعل `BaseTool.executeResult` هو الحد typed الإلزامي وحذف bridge الانتقالية؛ بقي `execute` كإسقاط توافق غير مستخدم من engine ضمن سقف الملفات.
- [x] فحص source يثبت أن كل implementations الإنتاجية توفر الحد typed صراحة.

### A2 — Coordinator and guard
- [x] دعم sequential/parallel/error/batch typed results.
- [x] إلحاق `Message.toolResult` واحدة لكل tool-call id.
- [x] منع implicit `toString` والbinary في callbacks/checkpoint previews.

### A3 — Contracts and verification
- [x] تحديث capabilities/tools وengine/runtime contracts.
- [x] analyzer واختبارات coordinator والregistry والنصوص ناجحة.

## Acceptance criteria

- [x] لا يفترض حد الأداة أو coordinator أن النتيجة String.
- [x] text-only regression متطابقة، وimage budget لا تمر عبر character guard.

## Definition of Done

- [x] `cd agent && set -o pipefail; fvm dart analyze 2>&1 | tail -5`
- [x] `cd agent && set -o pipefail; fvm dart test test/capabilities test/engine/agent_runner_test.dart test/engine/tool_output_guard_test.dart test/interfaces/runtime/session_restart_checkpoint_test.dart 2>&1 | tail -12`
- [x] تحديث العقود والخطة وreference parity.

## Progress log

### 2026-09-14 — R0 complete

- Status transition: `pending/Waiting` → `in_progress/A1`.
- Resolver: `status=ready`, task `77a`; fingerprint matched `sha256:477c6a964da28b0914da3cb0f52881421561ccd9f8afd859fc6833380353bc43`.
- Source audit: nine production `BaseTool` implementations plus the base boundary currently expose legacy `Future<String> execute`; workspace handlers are outside this inheritance boundary.
- Design constraint: A1 must centralize the final typed boundary without consuming the task-wide 10-file ceiling needed by coordinator, tests, contracts, task, and plan; no budget exception is assumed.
- Semantic rule: typed `isError` is authoritative; forced/recovery strings are normalized explicitly; callbacks/checkpoints receive bounded `displayText` only.
- Remaining estimate: `75%`.
- Next gate: `A1 — Final boundary`.

### 2026-09-14 — A1 complete

- Status transition: `A1` → `A2`.
- Final boundary: the default string-to-typed bridge was removed; missing typed implementations fail closed.
- Compatibility decision: concrete legacy `execute` projections remain callable outside engine code to respect the 10-file ceiling, but are no longer an engine execution boundary.
- Source proof: all nine production tool implementations explicitly provide `executeResult`; workspace handlers are catalog internals rather than `BaseTool` implementations.
- Verification: analyzer clean. The auxiliary source listing used POSIX `grep` because `rg` is unavailable in this shell.
- Remaining estimate: `45%`.
- Next gate: `A2 — Coordinator and guard`.

### 2026-09-14 — A2 complete

- Status transition: `A2` → `A3`.
- Coordinator: sequential and parallel execution consume `executeResult`; typed error status remains authoritative and exceptions/forced/recovery outputs normalize explicitly.
- Guard: per-result and batch character budgets operate only on text blocks while preserving image blocks and block order.
- History: rich-capable runner callbacks append one `Message.toolResult` per tool-call id; compatibility callbacks receive bounded `displayText` only.
- Durability/events: checkpoints and events retain bounded text previews and explicit error metadata; binary blocks are not projected through them.
- Verification: analyzer clean; 71 agent-runner tests, 18 restart-checkpoint/tools tests, and the full 140-test capability/restart guard set passed in focused runs.
- Remaining estimate: `20%`.
- Next gate: `A3 — Contracts and verification`.

### 2026-09-14 — A3 and task complete

- Status transition: `A3` → `complete`.
- Contracts: capability-tools and engine-runtime contracts now define mandatory typed execution, text-only previews, rich history, and authoritative error status.
- Verification: analyzer clean; 210 tests passed with 5 platform-specific skips across capabilities, runner, guard, and restart suites; Graphify rebuilt.
- File budget: 10 files, at the declared ceiling.
- Reference parity: satisfied; the retained concrete text projections are outside engine execution and documented as the bounded adaptation.
- Remaining estimate: `0%`.
- Next task: `77b1 — Image Policy Worker`.
