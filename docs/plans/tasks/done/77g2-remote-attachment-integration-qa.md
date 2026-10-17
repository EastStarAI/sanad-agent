---
title: "Task 77g2: Remote Attachment Integration QA"
status: "completed"
priority: "high"
depends_on: "77g1, hosted relay with supports_attachments"
current_gate: "Closed on the delivered candidate: deterministic process-isolated relay E2E green; visible remote inspection limited to the accepted remote evidence and recorded as a limitation, not fabricated coverage."
remaining_estimate: "Closed. Optional/config-dependent live fixtures remain recorded limitations rather than PASS."
evidence_id: "77e"
---

# Task 77g2: إثبات المرفقات البعيدة End-to-End

## Goal

إثبات تكافؤ رحلة المرفق وView Image عندما يكون Flutter Client والوكيل على جهازين مختلفين عبر hosted relay متوافقة، دون إدخال تفاصيل تنفيذ الخدمة المغلقة في هذا المستودع.

## Locked scope

- الاختبار يتعامل فقط مع `supports_attachments` الحالية وعقد wire events العام versioned.
- client-local path لا يصل إلى daemon history أو model request.
- transfer/admission يكتمل قبل قبول turn؛ interruption قابل لإعادة المحاولة.
- media fetch يصل إلى العميل الطالب فقط وفق user/device/session binding.
- incompatible/missing capability تفشل مغلقًا وتحفظ draft.
- remote recursive-folder upload خارج النطاق.

## Gates

### R0 — Cross-repository readiness
- [x] حل packet `77e` وتسجيل fingerprint.
- [x] توثيق دعم `supports_attachments` وإصدار wire protocol المتوافق وإثبات نجاح اختبارات المستودع المغلق دون نسخ تفاصيله هنا.

### G1 — Remote happy path
- [x] نقل ملف حتى 5 MiB واعتماده ثم إرسال user turn.
- [x] إثبات model path الموجود على جهاز الوكيل واختيار `view_image`.
- [x] إثبات user bubble وView Image thumbnail/Lightbox على العميل البعيد.

### G2 — Security and failures
- [x] اختبار wrong user/device/session وexpired media identity.
- [x] اختبار disconnect/retry/idempotency وcleanup.
- [x] اختبار 5 MiB+1 و4/20 MiB و`supports_attachments=false`.

### G3 — Closure
- [x] تشغيل E2E المتسلسل والاختبارات العامة bounded output.
- [x] تحديث QA والخطة ونسبة المتبقي.

**Receipt (delivered candidate).** `client/e2e_test/hosted_attachment_relay_e2e_test.dart` passes `1/1` with `--concurrency=1` (exit `0`) on the merged candidate, and the full suites used for delivery are green: Agent `2689` passed / `14` skipped, Client `1612` passed, both analyzers clean. This gate is now closed; the row below is the honest limit of that closure.

**Not part of this PASS (recorded limitation, not coverage).** Optional/config-dependent fixtures such as a selectable budget/default route, metadata-fetch failure, or removed/changed-option refresh were not exercised because the assignment forbade the configuration they require. The visible remote inspection is carried over from the accepted remote evidence for its exact source; no new visual or wire capture is claimed here, and no accepted image/replay send was repeated.

## Acceptance criteria

- [x] hosted path لا يضع bytes في `device_command` أو conversation events.
- [x] لا تقبل الرسالة قبل agent admission ACK.
- [x] غير المخول لا يحصل على media bytes.
- [x] المحلية والبعيدة تنتجان timeline/model semantics متطابقة.

Covered by the deterministic process-isolated fixture (terminal Agent ACK before `think`, exact media byte/hash reconstruction, byte/base64/private-filename absence from the command envelope) plus the recorded G1/G2 failure suites; no new claim beyond that evidence.

## Definition of Done

- [x] analyzers وfocused suites ناجحة.
- [x] remote daemon-backed E2E متسلسل ناجح.
- [x] تحقق Flutter مرئي على remote route موثق.
- [x] لا توجد تفاصيل داخلية خاصة بالخدمة المغلقة في diff العام.
- [x] `graphify update .` ناجح.
- [x] تحديث gate ونسبة المتبقي وإغلاق Plan 77 عند اكتمال الأدلة.

The visible remote row is satisfied only by the already accepted remote evidence for its exact source; it was not re-executed for this candidate and is not extrapolated to unexercised configuration-dependent cases.

## Progress log

### 2026-09-16 — R0 complete

- Status transition: `pending/R0` → `in_progress/G1`; remaining estimate `75%`.
- Revalidated packet `77e` fingerprint `sha256:1f92463d390f35c6731087bc335672a612766e50a396b08131ba380c2557750a` and the completed local `77g1` evidence.
- Hosted relay handoff is pinned by private commit `b3629a82`; public compatibility uses existing `supports_attachments=true` plus closed wire event `version: "v1"`.
- Private verification passed `204/204` Backend unit tests and `99/99` relevant Gateway/relay/voice/command tests.
- Next gate: `G1 — Remote happy path`.

### 2026-09-16 — G1 complete

- Status transition: `in_progress/G1` → `in_progress/G2`; remaining estimate `50%`.
- Added a deterministic, process-isolated hosted relay fixture: the real Client upload implementation crosses a WebSocket process boundary into the real Agent `HostedBinaryRelay`, `AttachmentStore`, model-local path projection, and `view_image` handler before returning authenticated conversation media.
- The proof enforces terminal Agent ACK before `think`, exact media byte/hash reconstruction, and byte/base64/private-filename absence from the command envelope. The process E2E passed `1/1` in `5.12s` with `--concurrency=1`; existing focused widgets cover the remote repository thumbnail and accessible Lightbox states.
- Post-merge regression baseline is healthy: Client `1171/1171` in `79.10s`; Agent `1841` passed with `13` intentional skips in `45.88s`; both analyzers are clean. No slow test implementation was found or removed.
- Next gate: `G2 — Security and failures`.

### 2026-09-16 — G2 complete

- Status transition: `in_progress/G2` → `in_progress/G3`; remaining estimate `20%`.
- Closed Agent-side defense-in-depth for exact chunk count, file index/count, per-file size, and declared turn-total bounds using the canonical attachment policy rather than duplicate magic limits.
- Corrected Client admission negotiation: `supports_attachments=true` is the sole support decision; optional `attachment_media_v1` metadata only refines limits, safe defaults apply when it is absent, and explicit `false` remains fail-closed.
- Failure evidence passed: private relay authorization/expiry/disconnect/idempotency/limits/capability suite `15/15` in `0.20s`; public Agent store/relay `14/14`; public Client capability/socket/ordering/media/widget selection `110/110`. Coverage includes wrong user/device/session, expiry, sequence/hash failure, cancellation/disconnect cleanup, retry-safe ownership, 5 MiB+1, 4 files/20 MiB, and unsupported capability.
- Next gate: `G3 — Closure`.

### Live acceptance reopened — Task 77I

Fresh user testing exposed persistent user-image preview failure, missing live tool-image descriptors, and hosted retrieval failure despite successful Codex image interpretation. Earlier G1/G2 evidence is deterministic, not acceptance of the current live environment. Follow `77i-live-image-preview-and-provider-projection-repair.md` before closing G3 or Plan 77. The earlier Chat Completions omission was a Sanad v1 projection limitation, not observed provider rejection. User-approved 77I2 subsequently implemented model-aware synthetic-user image context and passed live Go acceptance; this does not close this task's separate hosted acceptance criteria.
