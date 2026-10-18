---
title: "Task 77d3: View Image Integration QA"
status: "complete"
current_gate: "Complete"
remaining_estimate: "0%"
depends_on: "77d2"
file_budget: 10
evidence_id: "77d"
evidence_fingerprint: "sha256:986ef702424054d5e8f905701deab8ea3d55ac84846bd4ed1f8deb1d2b66bf5d"
---

# Task 77d3: إثبات التكامل Daemon-backed

## Goal

إغلاق مسار `view_image` المحلي باختبار daemon مع provider fixture يرى pixels، واختبار restart/approval/fallback/history parity الحقيقي، مع بقاء Plan 77 مفتوحة لمهام المرفقات والـhosted relay اللاحقة.

## Locked scope

- fixture صريحة `imageToolResults` وصورة deterministic لا تكشف path/prompt إجابتها.
- E2E فقط هي المتسلسلة بسبب المنافذ؛ fast suites تبقى parallel.
- لا provider حي أو SANAD_HOME المستخدم.

## Gates

### R0 — Evidence
- [x] حل packet 77d وتحديث run record النهائي.

### D1 — Fixture and live flow
- [x] provider تطلب `view_image` ثم تتحقق من image bytes وتجيب من pixels.
- [x] external allow/deny/full-access وtext-only fallback تمر عبر daemon.

### D2 — Restart and history
- [x] restart بعد tool completion مع حذف source يكمل من snapshot بلا re-execution.
- [x] reload/history query تعرض text/status بلا binary.

### D3 — Closure
- [x] analyzer، focused/full fast scope اللازمة، وE2E ناجحة.
- [x] إغلاق acceptance الخاصة بمسار `view_image` في الخطة وQA وتحديث docs/llms/contracts؛ لا تُغلق Plan 77 قبل 77g2.

## Acceptance criteria

- [x] الإجابة البصرية لا يمكن اشتقاقها من اسم الملف أو prompt.
- [x] tool call/result identity واحدة عبر restart.
- [x] لا binary leak في captures النهائية.

## Definition of Done

- [x] `cd agent && set -o pipefail; fvm dart analyze 2>&1 | tail -5`
- [x] `cd agent && set -o pipefail; fvm dart test test/capabilities test/engine test/interfaces 2>&1 | tail -5`
- [x] `cd agent && set -o pipefail; fvm dart test e2e_test/view_image_tool_e2e_test.dart --concurrency=1 2>&1 | tail -5`
- [x] reference parity audit مكتمل، وتبقى الخطة `in_progress` حتى اكتمال 77g2.

## Progress log

### 2026-09-15 — R0 complete

- Status transition: `pending/Waiting` → `in_progress/D1`.
- Resolver: packet `77d` returned `ready` at the pinned fingerprint; mandatory rich/text, sanitation, pruning, and media-projection sources/tests remained clean at the pinned MIT revisions.
- Triage corrected a stale contradiction: 77d3 closes only the daemon-backed local `view_image` segment, while Plan 77 must remain open through 77e1–77g2 and the hosted relay gates.
- Adopted a real isolated daemon composition test and binary-free interface captures; rejected live credentials, primary Sanad Home, filename-derived visual answers, and handler-only proof.
- Remaining estimate: `75%`.
- Next gate: `D1 — Fixture and live flow`.

### 2026-09-15 — D1 complete

- Status transition: `in_progress/D1` → `in_progress/D2`.
- Added an isolated daemon-backed fixture scenario whose prompt and opaque filename contain no visual answer; the fixture decodes the returned image block and answers `PIXELS_MAGENTA` only after inspecting the center pixel.
- Verified workspace-local rich flow, canonical external-path denial, allow-once, persisted full-access bypass, and a separately launched text-only provider route.
- Event captures contain neither `dataBase64` nor recognizable PNG base64 prefixes.
- Verification: `fvm dart analyze` clean; `fvm dart test e2e_test/view_image_tool_e2e_test.dart --concurrency=1` passed `3/3` in 12 seconds.
- Remaining estimate: `45%`.
- Next gate: `D2 — Restart and history`.

### 2026-09-15 — D2 complete

- Status transition: `in_progress/D2` → `in_progress/D3`.
- The fixture pauses only after the provider receives the durably completed rich result; a forced controlled daemon restart then deletes the source and resumes through `session.runtime_retry` from the preserved `after_tool_result` checkpoint.
- The resumed answer remains pixel-derived, with exactly one assistant tool call and one matching result sharing `e2e-view-image-tool-call`; no re-execution occurs after source deletion.
- `session_history` exposes only redacted tool input plus text/status/identity and contains neither rich blocks nor PNG/base64 bytes. Runtime lifecycle logs no longer print tool arguments.
- Verification: analyzer clean and the focused restart E2E passed in 15 seconds.
- Remaining estimate: `20%`.
- Next gate: `D3 — Closure`.

### 2026-09-15 — D3 complete

- Status transition: `in_progress/D3` → `complete`; Plan 77 remains `in_progress` and advances to `77e1/R0`.
- Verification: analyzer clean; combined capabilities/engine/interfaces fast scope passed `894` tests with `5` skips in 16 seconds; sequential daemon E2E passed `4/4` in 27 seconds.
- Graphify rebuilt `23,798` nodes, `32,753` edges, and `859` communities.
- Post-implementation parity retained the pinned Hermes/OpenClaw revisions and all packet obligations without deviation; `docs/llms.txt` already indexes the owning design and QA pages, so no index mutation was needed.
- File budget: `10/10` tracked paths.
- Remaining estimate: `0%` for 77d3; approximately `40%` for Plan 77.
- Next task: `77e1 — Attachment Model and Policy`, gate `R0`.
