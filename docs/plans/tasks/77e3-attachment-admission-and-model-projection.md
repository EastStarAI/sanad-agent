---
title: "Task 77e3: Attachment Admission and Model Projection"
status: "complete"
priority: "high"
depends_on: "77e2"
current_gate: "Complete"
remaining_estimate: "0%"
evidence_id: "77e"
evidence_fingerprint: "sha256:1f92463d390f35c6731087bc335672a612766e50a396b08131ba380c2557750a"
---

# Task 77e3: قبول المرفقات وإسقاطها للنموذج

## Goal

تمديد canonical conversation command لقبول مراجع المرفقات المعتمدة، انتظار staging ACK قبل قبول turn، وإعطاء النموذج نص المستخدم ومسارات الوكيل فقط دون direct attachment bytes.

## Locked scope

- local/cloud routes تستخدم command contract واحدة بعد اكتمال admission.
- remote client-local path يرفض ولا يترجم إلى agent path.
- model projection مرتبة ومحدودة: safe name، kind، agent-local path، وإرشاد استخدام الأداة المناسبة.
- لا تنشأ provider image/file parts تلقائيًا من user attachments.
- hosted transport تستخدم `supports_attachments` الحالية مع wire protocol versioned؛ تفاصيل تنفيذ الخدمة المغلقة لا توثق هنا.
- غياب capability عن remote route يفشل مغلقًا ويحافظ على draft.

## Gates

### R0 — Protocol alignment
- [x] حل packet `77e` وتسجيل fingerprint.
- [x] تثبيت typed admission/request/ACK/error contract للمسارين.

### G1 — Runtime admission
- [x] التحقق من session/device/attachment ownership قبل قبول user turn.
- [x] جعل acceptance ذرية مع attachment references والرسالة.
- [x] ضمان idempotency عند ACK مفقودة أو retry.

### G2 — Prompt projection
- [x] بناء projection نصية حتمية بعد user text وبترتيب المرفقات.
- [x] منع bytes/data URI/client path من كل provider adapter request.
- [x] إبقاء اختيار `view_image`/read/list للنموذج.

### G3 — Capability and recovery
- [x] اعتماد `supports_attachments` الحالية ودعم attachment/media wire protocol versioned.
- [x] استعادة pending/failed admission كdraft قابل للمحاولة دون optimistic message كاذبة.

## Acceptance criteria

- [x] لا تظهر user message نهائية قبل اعتماد كل attachment.
- [x] provider fixture يثبت غياب bytes ووجود agent-local path ثم يختار `view_image`.
- [x] replay بنفس identity لا ينشئ ملفًا أو رسالة ثانية.
- [x] Gateway غير متوافق يعيد خطأ capability واضحًا ويحفظ draft.

## Definition of Done

- [x] analyzer واختبارات interface/runner/admission المركزة ناجحة.
- [x] daemon-backed contract test للمسارين مطلوب عند توفر hosted fixture. *(Local/hosted end-to-end execution remains owned by 77g1/private relay/77g2; no hosted fixture exists before that ordered gate.)*
- [x] communication/provider/design docs محدثة بالعقد العام فقط.
- [x] `graphify update .` ناجح.
- [x] تحديث gate ونسبة المتبقي.

## Locked protocol contract

- Capability: `attachment_media_v1` advertises ordered attachment references, upload admission, and authenticated media retrieval independently from provider vision support.
- Upload operations use typed create/write/commit/cancel requests and closed ACK/error results. Upload/request identity is idempotent; retry returns the prior terminal result and never promotes twice.
- Canonical `think` carries an ordered `attachment_ids` list only after all uploads commit. IDs are opaque Agent-owned references; filenames, paths, bytes, and base64 are forbidden in the turn command.
- The Agent resolves every ID against the exact session, reconstructs canonical metadata from its repository, and atomically persists that immutable ordered list with the user message before execution admission.
- Local and cloud transports map the same typed contract. A remote route lacking `attachment_media_v1` returns `attachment_capability_unavailable`; no optimistic user message is created, and the client retains its draft.

## Progress log

### 2026-09-15 — R0 complete

- Status transition: `pending/R0` → `in_progress/G1`.
- Packet `77e` remains ready at fingerprint `sha256:1f92463d390f35c6731087bc335672a612766e50a396b08131ba380c2557750a`.
- Reviewed canonical `think` translation, `AgentTurnRequest`, capability publication, runtime admission ownership, and the completed Agent attachment store.
- Locked one transport-neutral contract: typed upload ACK/errors, opaque ordered `attachment_ids` on `think`, exact-session repository resolution, atomic message ownership, and fail-closed capability behavior.
- Remaining estimate: `75%`.
- Next gate: `G1 — Runtime admission`.

### 2026-09-15 — G1 complete

- Replaced the impossible pre-existing-message promotion constraint with two-phase ownership: verified files become `staged` under exact session/request ownership, then the same state transaction persists the user message and claims every ordered attachment as `attached`.
- Canonical `think` accepts only up to four unique opaque `attachment_ids`; traversal-like, duplicate, non-string, and steer attachment lists fail closed.
- Runtime admission reloads authoritative metadata from `AttachmentStore`; request-id replay reuses the durable root and cannot create a second message or attachment row.
- Verification: Agent analyzer clean; attachment/admission suite 8/8; focused AgentRunner request-id replay test 1/1. No test process remained after the cancelled broad command.
- Remaining estimate: `50%` for 77e3 and approximately `28%` for Plan 77.
- Next gate: `G2 — Prompt projection`.

### 2026-09-15 — G2 complete

- Added a provider-only deterministic projection after plugin/compaction processing: original user text first, then ordered safe name/kind/canonical Agent path and explicit `view_image`/read/list guidance.
- Canonical history retains typed attachments, while the ephemeral provider copy clears attachment objects so adapters cannot synthesize direct image/file parts. Missing owned files project as unavailable without broadening access.
- `LocalRuntimeCatalog` now obtains exact attached paths from the session-owned store, enabling `view_image` without workspace/full-access authority.
- Focused projection/admission/store suite remains 8/8.
- Remaining estimate: `25%` for 77e3 and approximately `26%` for Plan 77.
- Next gate: `G3 — Capability and recovery`.

### 2026-09-15 — G3 complete

- Published `attachment_media_v1` with schema version, ordered-reference support, and policy-owned byte/count/aggregate limits.
- Staged verified files survive runtime restart under session/request ownership; raw interrupted partials are removed. A retry can reload staged metadata, while tools resolve attached rows only.
- Added migration from the unreleased message-required attachment table to two-phase staged/attached ownership.
- Verification: Agent analyzer clean; focused admission/store/capability/projection/recovery suite 9/9; AgentRunner replay test 1/1; Graphify 23,923 nodes, 32,930 edges, 854 communities. Reference revisions remained clean and parity matched packet `77e`.
- Hosted daemon proof is intentionally deferred to its ordered owners (`77g1`, private relay G0–G6, then `77g2`) because the hosted fixture does not exist before those gates.
- File budget: `10/10` tracked paths.
- Status transition: `in_progress/G3` → `complete`; remaining estimate `0%` for 77e3 and approximately `24%` for Plan 77.
- Next task: `77f1 — Composer Attachment UX`, gate `R0`.
