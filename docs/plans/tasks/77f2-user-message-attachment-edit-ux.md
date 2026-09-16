---
title: "Task 77f2: User Message Attachment and Edit UX"
status: "complete"
priority: "high"
depends_on: "77f1, 77f3"
current_gate: "complete"
remaining_estimate: "0%"
tracked_file_budget: 25
evidence_id: "77e"
evidence_fingerprint: "sha256:1f92463d390f35c6731087bc335672a612766e50a396b08131ba380c2557750a"
---

# Task 77f2: عرض مرفقات رسالة المستخدم وتحريرها

## Goal

عرض الصور والملفات داخل user bubble واستعادة المرفقات بأمان في Edit & Retry دون إعادة رفع الموجود أو تغيير التاريخ عند فشل التعديل.

## Locked scope

- المرفقات تظهر بالترتيب فوق النص؛ images grid وgeneric file cards.
- الصورة تفتح Lightbox؛ الملف يفتح preview آمنة إن دعمت وإلا تنزيلًا مصادقًا عليه.
- لا تعرض البطاقة agent path أو media ticket أو storage identity الخام.
- Edit يعيد existing attachments كـready references دون re-upload، ويسمح remove/add.
- Cancel يعيد الأصل؛ Save & Retry ينتظر المرفقات الجديدة وreplay admission.
- attachment cleanup لا يحذف ملفًا ما زالت رسالة canonical تشير إليه.

## Gates

### R0 — Cache/edit ownership
- [x] حل packet `77e` وتسجيل fingerprint.
- [x] مراجعة conversation cache وmessage edit/retry contracts.

### G1 — Timeline projection
- [x] تمديد domain/cache mapper للمرفقات typed والlegacy history.
- [x] إضافة responsive image/file rendering وحالات unavailable.
- [x] إضافة Lightbox/preview semantics ولوحة المفاتيح.

### G2 — Inline edit
- [x] hydrate المرفقات الموجودة دون network upload.
- [x] دعم add/remove/retry مع transient edit draft معزول.
- [x] إبقاء canonical bubble دون تغيير حتى نجاح Save & Retry.

### G3 — Recovery and tests
- [x] widget/cache tests للlive/history parity وإعادة فتح التطبيق.
- [x] tests لـCancel، upload failure، stale edit، session/device switch.

## Acceptance criteria

- [x] الرسالة تعرض thumbnail/file cards ثم النص بنفس الترتيب حيًا وبعد hydration.
- [x] Edit يظهر المرفقات نفسها فورًا ولا يعيد رفعها.
- [x] إزالة/إضافة ثم Cancel لا تغير الرسالة أو التخزين.
- [x] Save failure يبقي وضع التحرير والأصل، والنجاح يعيد الجولة مرة واحدة.

## Definition of Done

- [x] `fvm flutter analyze` ناجح.
- [x] focused widget/cache/edit tests ناجحة.
- [x] تحقق مرئي ظاهر للرسالة وEdit وLightbox.
- [x] UX وQA docs محدثة.
- [x] `graphify update .` ناجح.
- [x] تحديث gate ونسبة المتبقي.

## Progress log

### 2026-09-16 — R0 complete

- Status transition: `pending/R0` → `in_progress/G1`.
- Resolved packet `77e` at fingerprint `sha256:1f92463d390f35c6731087bc335672a612766e50a396b08131ba380c2557750a`; verified `opencode=d2305d4a76e3b9ccbf0b98f2d137e49714a90dab` and `openclaw=2013a4be3f1164ebf9a59ca0aa45be56269d9b5f`.
- Confirmed the Client currently has no typed user-attachment projection in canonical events/cache and renders user text only. Existing inline edit owns text transiently, Cancel discards it, and replay keeps the canonical row unchanged until daemon acceptance.
- Locked a distinct attachment edit owner: existing references restore ready without upload; new additions remain transient; cache contains safe metadata only; cancellation/navigation/stale replay cannot leak into ordinary composer drafts or mutate canonical history.
- Evidence run: `refrence_projects/.sanad-evidence/runs/77f2-reference-grounding-2026-09-16.md`.
- Remaining estimate: `75%` for 77f2 and approximately `15%` for Plan 77.
- Next gate: `G1 — Timeline projection`.

### 2026-09-16 — G1 complete

- Status transition: `in_progress/G1` → `in_progress/G2`.
- Added one binary-free public attachment projection for live user events and history rows; Client live/history mapping now converges on strict typed metadata and rejects private or unknown fields.
- Added exact session/device-scoped authenticated Local Gateway retrieval with size and SHA-256 revalidation, generic response filenames, `no-store`, and `nosniff`; tampered bytes and wrong scopes return no payload.
- Added ordered responsive image/file cards, unavailable states, cancellable bounded loading, accessible image Lightbox, safe bounded text preview, and authenticated save flow for unsupported file previews.
- Evidence: Agent focused analyzer clean; Local Gateway transport `23/23`; Client focused analyzer clean; user-message focused tests `6/6`, including live/history parity, route/scope/cache, cancellation, unavailable, Lightbox, and file preview.
- Tracked files at gate close: `12`; the user approved raising the task budget from `15` to `25` so G2 can cover the edit owner, replay transport, Agent admission, tests, and required documentation without architectural shortcuts.
- Remaining estimate: `50%` for 77f2 and approximately `12%` for Plan 77.
- Next gate: `G2 — Inline edit`.

### 2026-09-16 — G2 complete

- Status transition: `in_progress/G2` → `in_progress/G3`.
- Existing attachments hydrate immediately as ready references without Client download or upload; additions, removal, retry, picker errors, and navigation cancellation are owned by an isolated transient edit draft.
- Edit replay carries existing opaque references and new validated payloads through the private authenticated command only. The Agent clones existing bytes locally into distinct replay admission ownership, and failed staging is rolled back without deleting canonical payloads.
- The canonical bubble remains unchanged until daemon acceptance. Rejection preserves the editor and draft; acceptance clears the draft and dispatches exactly one replay.
- Evidence: Agent focused analyzer clean; replay handler `18/18`; attachment store `9/9`; Local Gateway transport `23/23`; Client conversation analyzer clean; focused widget suites `42/42`.
- Tracked files at gate close: `22/25`.
- Remaining estimate: `25%` for 77f2 and approximately `10%` for Plan 77.
- Next gate: `G3 — Recovery and tests`.

### 2026-09-16 — G3 complete

- Status transition: `in_progress/G3` → `complete`; Plan 77 advances to `77g1/R0`.
- Recovery and widget coverage proves live/history/cache parity, unavailable and preview/lightbox states, edit hydration/add/remove/retry, cancellation/reopen, failure retention, canonical-row stability, and session navigation isolation.
- Verification: Agent and Client full analyzers clean; Local Gateway `23/23`; replay handler `18/18`; attachment store `9/9`; Client focused widget suites `42/42`; `git diff --check` clean.
- Visible isolated macOS build succeeded. Driver inspection confirmed the conversation timeline and inline Edit Add/Send/Cancel layout at 1400×900; the runtime was stopped afterward. Lightbox/card states are additionally covered by focused widget rendering tests.
- `graphify update .` rebuilt `24,152` nodes, `33,294` edges, and `842` communities; HTML visualization was skipped by its configured 5,000-node limit.
- Updated the Agent and Client owning contracts plus the multimodal technical design. Evidence run: `refrence_projects/.sanad-evidence/runs/77f2-reference-grounding-2026-09-16.md`.
- Tracked file budget closed at `25/25`; no blocking findings. The known unrelated Agent monolithic-suite baseline was not used or claimed.
- Remaining estimate: `0%` for 77f2 and approximately `8%` for Plan 77.
- Next task: `77g1 — Local Attachment Integration QA`, gate `R0`.
