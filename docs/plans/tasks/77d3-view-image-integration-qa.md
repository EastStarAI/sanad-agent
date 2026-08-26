---
title: "Task 77d3: View Image Integration QA"
status: "pending"
current_gate: "Waiting"
depends_on: "77d2"
file_budget: 10
evidence_id: "77d"
evidence_fingerprint: "sha256:986ef702424054d5e8f905701deab8ea3d55ac84846bd4ed1f8deb1d2b66bf5d"
---

# Task 77d3: إثبات التكامل Daemon-backed

## Goal

إغلاق Plan 77 باختبار daemon مع provider fixture يرى pixels، واختبار restart/approval/fallback/history parity الحقيقي.

## Locked scope

- fixture صريحة `imageToolResults` وصورة deterministic لا تكشف path/prompt إجابتها.
- E2E فقط هي المتسلسلة بسبب المنافذ؛ fast suites تبقى parallel.
- لا provider حي أو SANAD_HOME المستخدم.

## Gates

### R0 — Evidence
- [ ] حل packet 77d وتحديث run record النهائي.

### D1 — Fixture and live flow
- [ ] provider تطلب `view_image` ثم تتحقق من image bytes وتجيب من pixels.
- [ ] external allow/deny/full-access وtext-only fallback تمر عبر daemon.

### D2 — Restart and history
- [ ] restart بعد tool completion مع حذف source يكمل من snapshot بلا re-execution.
- [ ] reload/history query تعرض text/status بلا binary.

### D3 — Closure
- [ ] analyzer، focused/full fast scope اللازمة، وE2E ناجحة.
- [ ] إغلاق كل acceptance في الخطة وQA وتحديث docs/llms/contracts.

## Acceptance criteria

- [ ] الإجابة البصرية لا يمكن اشتقاقها من اسم الملف أو prompt.
- [ ] tool call/result identity واحدة عبر restart.
- [ ] لا binary leak في captures النهائية.

## Definition of Done

- [ ] `cd agent && set -o pipefail; fvm dart analyze 2>&1 | tail -5`
- [ ] `cd agent && set -o pipefail; fvm dart test test/capabilities test/engine test/interfaces 2>&1 | tail -5`
- [ ] `cd agent && set -o pipefail; fvm dart test test/e2e/view_image_tool_e2e_test.dart --concurrency=1 2>&1 | tail -5`
- [ ] reference parity audit مكتمل والخطة `complete` فقط بعد حفظ الأدلة.
