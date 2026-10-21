---
title: "Task 114d: Responsive view_image Gallery for Consecutive Results"
status: "in_review"
priority: "medium"
depends_on: "none"
current_gate: "G3 (live acceptance)"
remaining_estimate: "15%"
---

# Task 114d: معرض متجاوب لنتائج view_image المتتالية

## Goal

عند وجود أكثر من نتيجة `view_image` متتالية (داخل مجموعة أدوات)، تُعرض الصور في شبكة/Wrap متجاوبة يتغير عدد الصور في السطر الواحد حسب حجم الشاشة (جوال/سطح مكتب) بدل صورة واحدة في كل سطر.

## Current state (مثبت من الكود)

- كل حدث `view_image` يُرسم كـ `EventTile` منفصل داخل عمود جسم مجموعة الأدوات (`client/lib/features/conversations/presentation/widgets/tools/tool_group_tile.dart`)، وبطاقة الوسائط `_ViewImageToolTile` في `event_tile.dart` تحمل التحميل والـlightbox.

## Locked scope

- داخل جسم مجموعة الأدوات الموسّع: تجميع المقاطع المتتالية من الأحداث الحاملة لوسائط `view_image` في شبكة واحدة (Wrap + LayoutBuilder) بدل صفوف منفردة.
- التخطيط المتجاوب: عرض العنصر يُحسب من العرض المتاح — صيغة مثبتة: `columns = ((availableWidth + spacing) / (minItem + spacing)).floor().clamp(1, 4)` مع `minItem = 160` و`spacing = 8`، ثم `itemWidth = (availableWidth - spacing * (columns - 1)) / columns`؛ صورة واحدة تبقى بسلوكها الحالي.
- كل عنصر يحتفظ بسلوك البطاقة الحالي: تحميل مستقل، نسبة الأبعاد، حد أقصى للارتفاع 280، حالة "غير متاحة"، فتح الـlightbox الحالي بالنقر، ومفاتيحه (`view_image_thumbnail`, `view_image_lightbox`).
- الأحداث المنفردة خارج المجموعات تبقى كما هي؛ لا تغيير على الأدوات غير الحاملة لوسائط.
- يُراعى في التجميع أن أحداث `system_screenshot` الحاملة لوسائط (المهمة 114e) تدخل نفس المعرض عند توفره.

## Gates

### R0 — Grounding
- [x] مراجعة مسار العرض الحالي: `conversation_timeline_projection` (تجميع الأدوات المتتالية) + `tool_group_tile` (الجسم) + `_ViewImageToolTile`.
- [x] تثبيت صيغة التخطيط المتجاوب أعلاه.

### G1 — Implementation
- [x] مكوّن معرض وسائط متجاوب + دمج المقاطع المتتالية داخل جسم المجموعة.
- [x] الحفاظ على التحميل المستقل والـlightbox والمفاتيح لكل صورة.

### G2 — Tests
- [x] اختبارات ويدجت على عروض 320 / 600 / 1200: عدد الأعمدة المتوقع وعدم وجود سطر لكل صورة.
- [x] فتح الـlightbox لكل صورة؛ حالات التحميل/الخطأ؛ لا انحدار للمفاتيح.

### G3 — Live acceptance & docs
- [ ] تحقق حي: جلسة تُنتج 3+ نتائج `view_image` متتالية → شبكة متجاوبة عند تغيير حجم النافذة.
- [x] تحديث docs عرض الوسائط في المحادثة.

## Acceptance criteria

- [ ] 3 نتائج `view_image` متتالية تُعرض في شبكة، وعدد الصور بالسطر يتغير مع حجم الشاشة.
- [ ] لا انحدار في عرض نتيجة منفردة أو في أدوات أخرى.

## Definition of Done

- [x] `fvm flutter analyze` ناجح.
- [x] focused widget tests ناجحة.
- [ ] تحقق حي موثق.
- [x] تحديث docs ذات الصلة.
- [x] `graphify update .` ناجح.
- [x] تحديث gate ونسبة المتبقي.

## Progress log

### 2026-10-21 — WIP completed on the SRP base (`b51c2b55`)
- Source: WIP `6375134c`. The media card is extracted to `widgets/tools/view_image_tool_card.dart`. `ToolGroupTile` partitions consecutive media rows into `ResponsiveMediaGallery` using the pinned formula (`minItem = 160`, `spacing = 8`, 1 to 4 columns); a single media row and non-media tools keep `EventTile`. Child keys `tool-group-child:<id>`, `view_image_thumbnail`, and `view_image_lightbox` are preserved.
- Port: the `event_tile.dart` media branch conflicted with the reviewed 114e branch and was resolved through the shared rule below.
- Defects found in the WIP and repaired:
  1. `ResponsiveMediaGallery.isMediaToolEvent` was a third predicate that differed from the single-row branch. Fix: both use `rendersAsMediaCard` on `ViewImageMediaEvent` (a media tool row that is running, failed, `view_image`, or carries media metadata), so a completed text-only `system_screenshot` keeps its summary row and splits a run. Regression added (red without the fix).
  2. `ViewImageToolCard.didUpdateWidget` added a loader-instance reload trigger that main's tile never had (a rebuild-triggered fetch). Removed. Regression "rebuilding a gallery with a new loader instance does not refetch" (red without the fix).
- Docs: `docs/technical/multimodal_tool_results_and_view_image.md`. Contract: `client/lib/features/conversations/presentation/AGENTS.md`.
- Verification on `feat/114-port`: agent and client analyzers report no issues; full agent suite 3,038 passed / 14 skipped; full client suite 1,810 passed / 1 skipped (`-j 4`); daemon E2E media and attachment-relay suites pass with `--concurrency=1`; `graphify update .` run.
- Not verified: a live session producing three or more consecutive `view_image` results while resizing the window.

## 114g addendum — lightbox navigation, download, and media byte cache (2026-10-21)

User additions in the 114 scope, delivered on `feat/114-port`.

### Decisions

- **Ends:** navigation stops at the first/last image (no wrap); the arrow at an end is disabled. A wrap would hide where a group ends, and the `n / total` counter already orients the user.
- **RTL:** previous/next follow reading direction. Previous sits at the start and next at the end, so in Arabic next is on the left; chevrons point outward on their side. ArrowLeft/ArrowRight move toward the arrow on the same physical side (ArrowLeft is next in RTL).
- **Single image:** no arrows and no counter; Download and Close remain.
- **Group membership:** a `ResponsiveMediaGallery` run, or the image attachments of one user message (file attachments are not members). Cards register their existing loads in a `LightboxGroup`; the lightbox never fetches.
- **Download:** desktop writes only into the platform Downloads directory (`path_provider.getDownloadsDirectory`) with exclusive creation, adding ` (n)` before the extension on a clash. Web uses a `cross_file` browser download. Mobile hides the button, because there is no user-visible Downloads folder or existing save/share path and no share dependency. Names come from the attachment safe name or `image-<yyyyMMdd-HHmmss>`, sanitized (separators, controls, Windows-reserved characters and names, bidi overrides), with the extension taken from the magic bytes.
- **macOS:** `com.apple.security.files.downloads.read-write` was missing and is now in both `DebugProfile.entitlements` and `Release.entitlements`. The Runner currently has `app-sandbox=false`, so the key only takes effect if sandboxing is enabled.
- **Reload root cause:** all images are `Image.memory` from byte loaders, so `cached_network_image` does not apply. Hosted (cloud device) media had no cache, and `ConversationMediaLoaderResolver` built a new hosted repository per resolve. The local repository had a small per-instance LRU (12 entries), and even a hit went through a new future, so a remounted tile painted one loading frame.
- **Fix:** one process-wide `ConversationMediaByteCache` (byte-bounded, `SANAD_CONVERSATION_MEDIA_CACHE_MB`, default 64) shared by the local and hosted repositories. Keys carry transport, device, session, kind, media id, and attachment SHA-256. Hits are synchronous (`cachedBytes` as `initialData`, `gaplessPlayback`); lightbox navigation and download reuse the same bytes.

### Verification

- `fvm flutter gen-l10n`, then `fvm flutter analyze`: no issues (`temp/114/114g-analyze.log`).
- Focused: new `test/widget/image_lightbox_test.dart` (12), `test/unit/conversations/image_download_saver_test.dart` (6), `test/unit/conversations/conversation_media_cache_test.dart` (8), with the existing media suites: 93 passed (`temp/114/114g-focused.log`).
- Full client suite with `-j 4`: 1,836 passed / 1 skipped (`temp/114/114g-client-full.log`).
- `fvm flutter build macos --debug` succeeded; the signed app carries the downloads entitlement (`temp/114/114g-macos-build.log`).
- Agent untouched; the agent suite was not run.

### Live scenarios still to run

1. Gallery of 3+ `view_image` results: open the middle image. The counter reads `2 / N`. `lightbox_next`/`lightbox_prev` move one image at a time; the arrow is disabled at each end. ArrowRight/ArrowLeft behave the same on desktop.
2. Arabic UI: the same gallery shows `lightbox_next` on the left; ArrowLeft advances.
3. Single image (standalone card or a one-image message): no `lightbox_prev`/`lightbox_next`/`lightbox_counter`.
4. User message with two images and a file: the lightbox spans only the two images, in message order.
5. Desktop download, twice for the same image: `~/Downloads` gets `<name>.png` then `<name> (1).png`; the message names each saved file in en and ar. The relay/agent logs show no media request during download.
6. Download from a cloud (hosted) device's image: same result, no new relay fetch.
7. Web build: Download triggers a browser download named after the image. Mobile build: no `lightbox_download`.
8. Reload regression: open a conversation with images (local and cloud device), switch to another conversation and back. The images appear immediately with no spinner and no new `/media/...` or relay request. The same holds when reopening the lightbox and scrolling a gallery out of view and back.
