---
title: "Task 77d1: Atomic Tool Result Durability"
status: "pending"
current_gate: "Waiting"
depends_on: "77b2 and 77c2"
file_budget: 10
evidence_id: "77d"
evidence_fingerprint: "sha256:986ef702424054d5e8f905701deab8ea3d55ac84846bd4ed1f8deb1d2b66bf5d"
---

# Task 77d1: الاستدامة الذرية لنتيجة الأداة

## Goal

حفظ rich completed result واستعادتها ثم ترقيتها ذريًا من checkpoint إلى tool Message دون إعادة تنفيذ أو نسخة غنية دائمة ثانية.

## Locked scope

- inline `Message.toolResult`; checkpoint key=`completed_tool_results_v2`.
- `SessionExecutionStateCoordinator` يملك transaction الإلحاق والإزالة.
- legacy text checkpoint parser يبقى؛ malformed rich payload تصبح unavailable marker.

## Gates

### R0 — Evidence
- [ ] حل packet 77d وقراءة recovery/history obligations.

### D1 — Checkpoint schema
- [ ] typed v2 save/restore مع owner/run/generation validation.
- [ ] redacted text output يبقى منفصلًا عن rich payload.

### D2 — Atomic promotion
- [ ] append tool Message وإزالة v2 checkpoint copy في transaction واحدة.
- [ ] crash قبل/بعد transaction ينتج نتيجة واحدة فقط.

### D3 — Recovery tests
- [ ] changed/deleted file لا يعاد فتحه.
- [ ] stale run وcorrupt payload يفشلان بأمان.

## Acceptance criteria

- [ ] restart يستخدم snapshot المكتملة مرة واحدة.
- [ ] لا توجد rich bytes في `completed_tool_outputs`.

## Definition of Done

- [ ] `cd agent && set -o pipefail; fvm dart analyze 2>&1 | tail -5`
- [ ] `cd agent && set -o pipefail; fvm dart test test/engine/continuation_checkpoint_coordinator_test.dart test/evolution/session_execution_state_coordinator_test.dart 2>&1 | tail -5`
- [ ] تحديث runtime/evolution contracts والخطة وسجل parity.

