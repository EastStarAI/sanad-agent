---
title: "Task 114c: Inline-Edit Image Previews for Existing Attachments"
status: "done"
priority: "high"
depends_on: "none"
current_gate: "closed (live acceptance r1 and r2 recorded)"
remaining_estimate: "0%"
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
- [x] تحقق حي: تعديل رسالة بصورة → المعاينة تظهر؛ إضافة صورة جديدة → كما هي. — preview r1 S8, r2 D1/C8; adding a new image uses the native picker only, so it is tests-only.
- [x] تحديث docs تعديل الرسائل ذات الصلة.

## Acceptance criteria

- [x] فتح تعديل رسالة تحتوي صورة يعرض معاينتها الصحيحة دون أخطاء. — r1 S8, r2.
- [x] لا انحدار في إزالة/إضافة المرفقات داخل وضع التعديل ولا في الإرسال. — remove + send r1 S8 and r2 C8; add is tests-only.

## Definition of Done

- [x] `fvm flutter analyze` ناجح.
- [x] focused widget tests ناجحة.
- [x] تحقق حي موثق. — see the live acceptance log below.
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

### 2026-10-21 — live acceptance r1 and r2 (coordinator, Test Homes 2 and 3)
- r1 on `389caede`: S8 partial. The inline editor showed the existing image thumbnail ("Ready · existing") and removing it then sending worked, but the editor showed a file token as a raw Markdown link with its path (D1, fixed in round 5).
- r2 on `571844f6`: D1 passes. The editor shows icon+name chips, and an unchanged save keeps the exact link text (`cmp` identical). C8 passes: removing the image keeps the file chips. A remote message's editor shows two image thumbnails and a PDF chip with the PDF icon.
- Tests-only: adding an image in the editor (native picker only; the editor takes no paste or drop) and the inline-edit attachment error.
