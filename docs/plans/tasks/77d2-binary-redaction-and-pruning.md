---
title: "Task 77d2: Binary Redaction and Pruning"
status: "complete"
current_gate: "complete"
remaining_estimate: "0%"
depends_on: "77d1"
file_budget: 10
evidence_id: "77d"
evidence_fingerprint: "sha256:986ef702424054d5e8f905701deab8ea3d55ac84846bd4ed1f8deb1d2b66bf5d"
---

# Task 77d2: التنقيح والتقليم

## Goal

منع binary من أسطح التشخيص/الواجهات وتطبيق تقليم 3-turn/24-MiB الحتمي بعد assistant completion.

## Locked scope

- current/incomplete loop محمية.
- exact markers من العقد التقني.
- request dumper تنقح deep copy فقط؛ events/history query/plugins نصية.

## Gates

### R0 — Evidence
- [x] حل packet 77d وتأكيد fingerprint.

### D1 — Redaction
- [x] recursive typed-image/data-URI redaction مع MIME/size فقط.
- [x] event/log/plugin/history projections لا تستقبل rich blocks.

### D2 — Pruning
- [x] completed-turn index يحفظ آخر 3 ثم يطبق 24-MiB oldest-first.
- [x] transform idempotent وتحافظ على text/order/tool identity/error state.

### D3 — Verification
- [x] tests للحدود، current loop، corrupt marker، repeated pruning، وعدم mutation للطلب الحي.

## Acceptance criteria

- [x] بحث captures لا يجد base64 خارج canonical message/provider request المؤقتة.
- [x] pruning لا تنتج orphan tool result أو تكسر replay.

## Definition of Done

- [x] `cd agent && set -o pipefail; fvm dart analyze 2>&1 | tail -5`
- [x] `cd agent && set -o pipefail; fvm dart test test/engine/llm_request_dumper_test.dart test/engine/history_image_pruner_test.dart test/interfaces 2>&1 | tail -5`
- [x] تحديث QA/contracts والخطة وسجل parity.

## Progress log

### 2026-09-15 — R0 complete

- Status transition: `pending/Waiting` → `in_progress/D1`.
- Resolver: packet `77d` returned `ready` at the pinned fingerprint; mandatory rich/text projection, sanitation, completed-turn pruning, and media-event sources/tests were re-inspected at clean pinned MIT revisions.
- Adopted binary-free diagnostic/interface projections and completed-turn-aware pruning; adapted the reference behavior with Sanad's locked latest-three plus 24-MiB oldest-first cap.
- Rejected raw-message counting, live-request mutation, generic base64 previews, and whole-message deletion that could orphan tool pairs.
- Run record fixes exact source inspection, decisions, and test obligations in the ignored evidence store.
- Remaining estimate: `75%`.
- Next gate: `D1 — Redaction`.

### 2026-09-15 — D1 complete

- أصبح request dumper يبني deep copy وينقح canonical/Anthropic/Responses typed image blocks إلى MIME وdecoded byte count فقط.
- data URI وraw base64 لا يحتفظان بأي sample؛ malformed typed image يبقى metadata-only بقيمة size غير معروفة.
- بقيت tool events وplugins وhistory query على `Message.content`/`displayText` النصي، ولم يضف المسار أي rich serialization إليها.
- Evidence: `llm_request_dumper_test.dart` نجح في `13` حالة، وfocused analyzer نظيف، مع إثبات عدم mutation للطلب الحي.
- Remaining estimate: `50%`.
- Next gate: `D2 — Pruning`.

### 2026-09-15 — D2 complete

- أضيف transform مركزي نقي يفهرس completed assistant turns بدل عد الرسائل، ويحمي current/incomplete loop وآخر ثلاث دورات مكتملة.
- يستبدل الصور الأقدم بالعلامة الحرفية `[image data removed after model processing]` ثم يطبق سقف `24 MiB` oldest-first على الصور المكتملة فقط.
- يحافظ التحويل على block order والنصوص وtool-call identity وmetadata وtyped error، وتكراره لا يغير history ثانية ولا ينشئ orphan result.
- شُغّل بعد نجاح حفظ assistant في sync/stream، ولا يعيد الحفظ إلا عند تغير history؛ plugin tool notifications أصبحت text-only copies.
- Evidence: `history_image_pruner_test.dart` نجح في `5` حالات؛ المجموعة المركزة مع AgentRunner نجحت في `89` حالة.
- Remaining estimate: `25%`.
- Next gate: `D3 — Verification`.

### 2026-09-15 — D3 and task complete

- غطت الاختبارات حدود الثلاث دورات و24 MiB، current loop، oldest-first، corrupt marker، idempotency، deep-copy، وعدم تسرب payload samples.
- Verification: analyzer الكامل نظيف؛ اختبارات dumper/pruner نجحت في `18` حالة؛ `test/interfaces` نجح في `430` حالة مع `--concurrency=1` التزامًا بعزل اختبارات المنافذ.
- ظهر فشلان توقيتيان مستقلان في محاولتين أوسع داخل Local Gateway identity؛ نجح كل اختبار منفردًا ثم نجحت مجموعة interfaces كاملة تسلسليًا، فلا finding متعلق بالتغيير.
- `graphify update .`: `23,742` nodes و`32,676` edges و`849` communities؛ تحذير zero-node لملفات البيانات معروف وغير حاجب.
- حُدث عقد engine والتصميم التقني وQA والخطة وسجل parity؛ نطاق المهمة `10/10` ملفات tracked.
- Remaining estimate: `0%`.
- Next task: `77d3 — Daemon-backed View Image QA`, gate `R0`.

