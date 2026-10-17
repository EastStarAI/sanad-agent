---
title: "Task 77d1: Atomic Tool Result Durability"
status: "complete"
current_gate: "complete"
remaining_estimate: "0%"
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
- [x] حل packet 77d وقراءة recovery/history obligations.

### D1 — Checkpoint schema
- [x] typed v2 save/restore مع owner/run/generation validation.
- [x] redacted text output يبقى منفصلًا عن rich payload.

### D2 — Atomic promotion
- [x] append tool Message وإزالة v2 checkpoint copy في transaction واحدة.
- [x] crash قبل/بعد transaction ينتج نتيجة واحدة فقط.

### D3 — Recovery tests
- [x] changed/deleted file لا يعاد فتحه.
- [x] stale run وcorrupt payload يفشلان بأمان.

## Acceptance criteria

- [x] restart يستخدم snapshot المكتملة مرة واحدة.
- [x] لا توجد rich bytes في `completed_tool_outputs`.

## Definition of Done

- [x] `cd agent && set -o pipefail; fvm dart analyze 2>&1 | tail -5`
- [x] `cd agent && set -o pipefail; fvm dart test test/engine/continuation_checkpoint_coordinator_test.dart test/evolution/session_execution_state_coordinator_test.dart 2>&1 | tail -5`
- [x] تحديث runtime/evolution contracts والخطة وسجل parity.

## Progress log

### 2026-09-14 — R0 complete

- Status transition: `pending/Waiting` → `in_progress/D1`.
- Resolver: packet `77d` returned `ready` at the pinned fingerprint; mandatory recovery, rich/text projection, sanitation, pruning, and media-event sources/tests were re-inspected at the verified clean MIT-licensed revisions.
- Adopted separate rich durable content and bounded preview projections, single canonical promotion, restart reuse, and identity-preserving fail-closed corruption handling.
- Plan 77 closes the storage evidence gap in favor of bounded inline `Message.toolResult` JSON and a temporary typed v2 checkpoint copy; user attachment blobs remain a separate owner-protected store.
- Rejected base64 in `completed_tool_outputs`, replay from a changed source path, duplicate rich durable copies after promotion, and ambiguous stale-run recovery.
- Remaining estimate: `75%`.
- Next gate: `D1 — Checkpoint schema`.

### 2026-09-14 — D1 complete

- أضيف `completed_tool_results_v2` كغلاف inline بإصدار schema وهوية session/work item/run/generation/tool call، مع round-trip كامل للكتل المرتبة.
- بقي `completed_tool_outputs` إسقاطًا نصيًا مستقلًا يمر عبر redactor؛ لا تُنسخ إليه bytes/base64 الغنية.
- الاستعادة تتحقق من المالك، وتحافظ على legacy text-only، وتحول تلف payload إلى terminal unavailable marker بدل إعادة التنفيذ.
- Evidence: الاختبار المحدد مرّ ضمن 6 اختبارات، واختبار restart checkpoint القائم مرّ في 13 حالة.
- Remaining estimate: `50%`.
- Next gate: `D2 — Atomic promotion`.

### 2026-09-14 — D2 complete

- أصبح `SessionExecutionStateCoordinator` يثبت tool Message ويزيد history revision ويحذف suspended checkpoint ونسخة v2 ضمن transaction واحدة متحققة من المالك.
- ينفذ `ToolExecutionCoordinator` الترقية قبل callback الذاكرة، ويعيد حفظ النتيجة بعد batch guard كي تطابق الرسالة canonical.
- إعادة الاستدعاء بعد نجاح transaction تتحقق من نفس typed result ولا تضيف رسالة أو revision ثانية؛ owner/result mismatch يفشل مغلقًا.
- Evidence: اختبارات crash-before/crash-after exactly-once ناجحة ضمن الملف المحدد.
- Remaining estimate: `25%`.
- Next gate: `D3 — Recovery tests`.

### 2026-09-14 — D3 and task complete

- أثبتت الاختبارات أن source تغيّر ثم حُذف بعد checkpoint دون أن يعاد فتحه، وأن stored snapshot وحدها تُقبل للترقية.
- غُطيت stale owner وpayload التالف وlegacy text، مع exactly-once message/revision عند إعادة الترقية.
- Verification: analyzer الكامل نظيف؛ الاختباران المطلوبان نجحا في `6` حالات؛ restart checkpoint نجح في `13` حالة؛ AgentRunner نجح في `71` حالة.
- `graphify update .`: `23,712` nodes و`32,639` edges و`868` communities؛ تحذير zero-node لملفات البيانات معروف وغير حاجب.
- حُدث عقدا runtime/evolution والتصميم التقني والخطة وسجل parity؛ نطاق المهمة `10/10` ملفات tracked بعد تحديث الخطة العامة.
- Remaining estimate: `0%`.
- Next task: `77d2 — Binary Redaction and Pruning`, gate `R0`.

