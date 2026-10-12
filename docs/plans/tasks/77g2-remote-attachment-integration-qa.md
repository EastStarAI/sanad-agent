---
title: "Task 77g2: Remote Attachment Integration QA"
status: "in_progress"
priority: "high"
depends_on: "77g1, hosted relay with supports_attachments"
current_gate: "G3"
remaining_estimate: "20%"
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
- [ ] تشغيل E2E المتسلسل والاختبارات العامة bounded output.
- [ ] تحديث QA والخطة ونسبة المتبقي.

## Acceptance criteria

- [ ] hosted path لا يضع bytes في `device_command` أو conversation events.
- [ ] لا تقبل الرسالة قبل agent admission ACK.
- [ ] غير المخول لا يحصل على media bytes.
- [ ] المحلية والبعيدة تنتجان timeline/model semantics متطابقة.

## Definition of Done

- [ ] analyzers وfocused suites ناجحة.
- [ ] remote daemon-backed E2E متسلسل ناجح.
- [ ] تحقق Flutter مرئي على remote route موثق.
- [ ] لا توجد تفاصيل داخلية خاصة بالخدمة المغلقة في diff العام.
- [ ] `graphify update .` ناجح.
- [ ] تحديث gate ونسبة المتبقي وإغلاق Plan 77 عند اكتمال الأدلة.

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
