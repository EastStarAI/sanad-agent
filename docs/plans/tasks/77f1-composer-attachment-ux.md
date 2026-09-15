---
title: "Task 77f1: Composer Attachment UX"
status: "complete"
priority: "high"
depends_on: "77e3"
current_gate: "complete"
remaining_estimate: "0%"
evidence_id: "77e"
evidence_fingerprint: "sha256:1f92463d390f35c6731087bc335672a612766e50a396b08131ba380c2557750a"
---

# Task 77f1: تجربة مرفقات Composer

## Goal

إضافة pipeline موحدة للصق والسحب وFile Picker مع زر `+` في يسار الـcomposer بجوار Permission Mode، وعرض attachment rail قابلة للإزالة وإعادة المحاولة.

## Locked scope

- زر `+` يقع على يسار Permission Mode selector ويفتح platform File Picker.
- paste image، drag/drop، والpicker تستخدم draft attachment controller واحدة.
- image tile تعرض thumbnail/name/size/status/remove؛ generic file card تعرض icon/name/size/status/remove.
- الحالات `validating|uploading|ready|failed`؛ Send يتعطل حتى ready.
- رفض فوري فوق 5 MiB أو فوق 4 ملفات/20 MiB، مع واجهة إنجليزية فقط.
- remote capability غير متاحة تعطل الإرفاق برسالة واضحة ولا تستخدم command fallback.

## Gates

### R0 — UX grounding
- [x] حل packet `77e` وتسجيل fingerprint.
- [x] مراجعة composer وPermission Mode وdraft ownership contracts.

### G1 — Entry points
- [x] إضافة زر `+` بالموقع والقابلية للوصول المطلوبة.
- [x] توحيد picker/paste/drop في controller/repository flow واحدة.
- [x] الحفاظ على keyboard focus والنص بعد كل إضافة/إزالة.

### G2 — Rail and state
- [x] إضافة responsive attachment rail والصور المصغرة/file cards.
- [x] عرض progress/failure/retry/remove دون optimistic sent row.
- [x] حفظ draft attachment state بعزل device/session.

### G3 — Tests and visual proof
- [x] widget tests للموقع والنقر والpicker/paste/drop والحدود.
- [x] responsive/accessibility tests وgolden عند ملاءمة البنية الحالية.
- [x] تحقق مرئي في تطبيق Flutter ظاهر قبل التسليم.

## Acceptance criteria

- [x] الضغط على `+` بجوار Permission Mode يفتح File Picker مرة واحدة.
- [x] المداخل الثلاثة تنتج نفس rail ونفس validation.
- [x] ملف 5 MiB يقبل و5 MiB+1 يرفض مع بقاء النص.
- [x] فشل remote upload يبقي attachment والنص قابلين لـRetry/Remove.

## Definition of Done

- [x] `fvm flutter analyze` ناجح.
- [x] focused widget/state tests ناجحة.
- [x] تحقق مرئي محلي موثق.
- [x] product/design/QA docs محدثة.
- [x] `graphify update .` ناجح.
- [x] تحديث gate ونسبة المتبقي.

## Progress log

### 2026-09-15 — R0 complete

- Status transition: `pending/R0` → `in_progress/G1`.
- Packet `77e` is ready at the pinned clean revisions.
- Confirmed `ConversationInputCubit` as the single transient controller, `ConversationCacheStore` as the device/session draft owner, and `ConversationBottomActions` as the position owner immediately left of Permission Mode.
- The existing client has `desktop_drop`; picker abstraction must remain injectable and platform-neutral rather than coupling presentation to transport. Capability parsing must consume `attachment_media_v1`, not legacy `supports_attachments` inference.
- Remaining estimate: `75%` for 77f1 and approximately `23%` for Plan 77.
- Next gate: `G1 — Entry points`.

### 2026-09-15 — G1 complete

- Status transition: `in_progress/G1` → `in_progress/G2`.
- Added one accessible `composer_add_attachment` picker control immediately left of Permission Mode; the picker is invoked once per press.
- Picker files, desktop drops, and focused image paste events now converge on `ConversationInputCubit.addDraftAttachment`; ordinary text paste remains untouched.
- The controller validates the negotiated `attachment_media_v1` limits and preserves composer text/focus. Focused analyzer for the four edited Dart files reports no errors (one unnecessary-import info was removed immediately).
- Remaining estimate: `50%` for 77f1 and approximately `22%` for Plan 77.
- Next gate: `G2 — Rail and state`.

### 2026-09-15 — G2 complete

- Status transition: `in_progress/G2` → `in_progress/G3`.
- Added a wrapping responsive rail with image thumbnails, generic-file icons, safe names, sizes, lifecycle labels, retry-on-failure, and removal; no sent message row is synthesized.
- Send eligibility now requires every retained draft attachment to be `ready`. Draft lists and errors are saved/restored by the combined device/session scope and remain intact across message-state emissions.
- Verification: full Client analyzer clean; focused controller suite 35/35 and existing composer regression suite 19/19 passed independently with explicit timeouts.
- Remaining estimate: `25%` for 77f1 and approximately `21%` for Plan 77.
- Next gate: `G3 — Tests and visual proof`.

### 2026-09-15 — G3 and task complete

- Status transition: `in_progress/G3` → `complete`; Plan 77 advances to `77f2/R0`.
- Added an injectable picker boundary and widget proof that the accessible `+` control is directly left of Permission Mode, invokes the picker exactly once, and preserves text/focus. Existing narrow-layout, keyboard, and lifecycle composer coverage remains green.
- Final verification: `fvm flutter analyze` clean; focused composer suite 20/20; full Client fast suite 1,155/1,155; visible isolated macOS Flutter runtime running from this worktree; Graphify 23,969 nodes/32,999 edges/864 communities; packet `77e` post-implementation parity satisfied.
- File budget: `10/10` tracked paths. No golden was added because this composer suite uses responsive structural assertions and has no owning golden baseline.
- Remaining estimate: `0%` for 77f1 and approximately `20%` for Plan 77.
- Next task: `77f2`, gate `R0`.
