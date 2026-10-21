---
title: "Task 114c: Inline-Edit Image Previews for Existing Attachments"
status: "in_review"
priority: "high"
depends_on: "none"
current_gate: "G3 (live acceptance)"
remaining_estimate: "15%"
---

# Task 114c: معاينة الصور للمرفقات الموجودة في وضع تعديل الرسالة

## Goal

عند فتح وضع تعديل رسالة تحتوي صورة، يعرض شريط مرفقات التعديل مصغّرة الصورة الموجودة فعليًا (بدل أيقونة عامة)، بنفس سلوك المرفقات الجديدة التي تعمل حاليًا.

## Root cause (مثبت من الكود)

- `InlineEditAttachment.existing` في `client/lib/features/conversations/presentation/widgets/user_message_tile.dart` يُنشئ مرفقًا بلا `bytes`، وشريط التعديل `_buildEditAttachmentRail` يعرض `Image.memory` فقط عند وجود `bytes`؛ المرفقات الجديدة تعمل لأن بايتاتها محلية بعد الاختيار.

## Locked scope

- تحميل مصغّرات المرفقات الموجودة (صور فقط) داخل شريط التعديل عبر `UserAttachmentMediaLoader.loadAttachment` نفسه المستخدم في عرض رسائل المستخدم.
- تمرير الحمّل و`sessionId` من `brain_activity_view.dart` (يوجد `attachmentMediaLoader` أصلًا لبطاقة الرسالة) إلى مسار التعديل.
- سلوك مطلوب: تحميل غير متزامن مع إلغاء عند الإغلاق؛ فشل التحميل → أيقونة fallback (السلوك الحالي) مع إمكانية إعادة المحاولة حيث تنطبق؛ المرفق الجديد والملفات غير الصورية بلا تغيير.
- الحفاظ على المفاتيح الحالية (`inline_edit_attachment_*`, `inline_edit_attachment_rail`) وعدم تغيير التخطيط العام للشريط.

## Gates

### R0 — Grounding
- [x] تأكيد مسار البايتات: `InlineEditAttachment.existing` بلا bytes مقابل مسار عرض رسالة المستخدم الذي يحمّل بنجاح.
- [x] مراجعة `_UserAttachmentCard` كنمط مرجعي للتحميل/الإلغاء/الفشل.

### G1 — Implementation
- [x] تحميل مصغّرات المرفقات الموجودة في شريط التعديل عبر الحمّل الممرَّر.
- [x] حالات: تحميل/جاهز/فشل→fallback، مع إلغاء عند التدمير.

### G2 — Tests
- [x] اختبار ويدجت بحمّل وهمي: مرفق صورة موجود → مصغّرة تُعرض (كانت أيقونة قبل الإصلاح).
- [x] فشل التحميل → fallback دون كسر الشريط؛ المرفق الجديد كما هو.

### G3 — Live acceptance & docs
- [ ] تحقق حي: تعديل رسالة بصورة → المعاينة تظهر؛ إضافة صورة جديدة → كما هي.
- [x] تحديث docs تعديل الرسائل ذات الصلة.

## Acceptance criteria

- [ ] فتح تعديل رسالة تحتوي صورة يعرض معاينتها الصحيحة دون أخطاء.
- [ ] لا انحدار في إزالة/إضافة المرفقات داخل وضع التعديل ولا في الإرسال.

## Definition of Done

- [x] `fvm flutter analyze` ناجح.
- [x] focused widget tests ناجحة.
- [ ] تحقق حي موثق.
- [x] تحديث docs ذات الصلة.
- [x] `graphify update .` ناجح.
- [x] تحديث gate ونسبة المتبقي.

## Progress log

### 2026-10-21 — WIP completed on the SRP base (`d5ea67aa`)
- Source: WIP `08ebedf0`. The existing attachment now travels on `InlineEditAttachment.attachment`, and `_InlineEditAttachmentThumbnail` loads it through the same `UserAttachmentMediaLoader` and session as the bubble. `sessionId` is passed from `BrainActivityView` through `EventTile`. Loading shows a spinner; failure falls back to the image icon, and tapping it retries; dispose cancels. Keys `inline_edit_attachment_*` and `inline_edit_attachment_rail` are unchanged.
- Defects found in the WIP and repaired (`user_message_tile.dart`):
  1. `userAttachment` synthesized a `UserMessageAttachment` with a placeholder `sha256`, a guessed MIME, and `mediaId = id` when no canonical reference existed. Removed: only the canonical reference is ever requested.
  2. An unavailable existing attachment was still requested. Now it keeps the icon and sends no request. Regression added.
  3. `didUpdateWidget` reloaded when the loader instance changed, so a parent rebuild issued another Agent request (violating render/request independence). Now it reloads only for a different id, media id, bytes, or session. Regression "rebuild with a new loader instance does not refetch" (red without the fix).
- WIP tests updated to build edit items through `InlineEditAttachment.existing` with a canonical attachment.
- Docs: `docs/product/message_edit_retry_ux.md`.
- Verification on `feat/114-port`: agent and client analyzers report no issues; full agent suite 3,038 passed / 14 skipped; full client suite 1,810 passed / 1 skipped (`-j 4`); daemon E2E media and attachment-relay suites pass with `--concurrency=1`; `graphify update .` run.
- Not verified: live edit of a message with an image (preview visible, adding a new image unchanged, save path).
