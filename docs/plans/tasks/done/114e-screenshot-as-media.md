---
title: "Task 114e: Screenshot as Media (Agent + Client)"
status: "done"
priority: "high"
depends_on: "none"
current_gate: "closed (live acceptance r1 and r2 recorded)"
remaining_estimate: "0%"
---

# Task 114e: أداة سكرين شوت كوسائط — إرسال المحتوى للنموذج وعرضه في الواجهة

## Goal

تعمل `system_screenshot` مثل `view_image`: تُرسل صورة اللقطة إلى النموذج كوسائط، وتُعرض اللقطة في الواجهة بنفس بطاقة وسائط `view_image` (مصغّرة + lightbox)، مع إبقاء النص الوصفي الحالي.

## Current state (مثبت من الكود)

- `agent/lib/capabilities/tools/system/screenshot_tool.dart` يعيد نصًا + مسار حفظ فقط (`ToolExecutionResult.text`)؛ لا كتلة صورة.
- بوابة الإسقاط `ViewImageMediaMetadata.project` في `agent/lib/core/models/view_image_media_metadata.dart` تقبل `view_image` فقط؛ والعميل في `client/lib/features/conversations/presentation/widgets/event_tile.dart` يفرع على `toolName == 'view_image'` فقط.
- إسقاط كتل الصور لأي أداة موجود مسبقًا على سلك النموذج (`ToolResultWireCodec` عام) — لا يحتاج تغييرًا جوهريًا.

## Locked scope

### الوكيل

- `ScreenshotTool.executeResult` يعيد `ToolExecutionResult` يحمل `ToolImageBlock` (نوع/أبعاد تُشتق بفك ترميز البايتات عبر حزمة `image` المتاحة؛ الصيغ المسموحة `image/jpeg`/`image/png`/`image/webp`) + نص وصفي مستقر (يبقى حفظ `Downloads/AgentScreenshots` وسطر المسار للرجوع).
- توسيع بوابة `ViewImageMediaMetadata.project` لقبول `system_screenshot` مع الحفاظ على اشتقاق `mediaId` الحالي (sessionId + toolCallId + index) و`availability`/الأبعاد/النوع.
- تأكيد عمل الاسترجاع عبر hosted relay (`ViewImageMediaProjection.resolve`) لنتائج `system_screenshot` دون تغييرات إضافية.

### العميل

- توسيع فرع العرض في `event_tile.dart` ليغطي `system_screenshot` بنفس بطاقة الوسائط والـlightbox (تعميم الشرط على وجود وسائط بدل الاسم الصريح حيث أمكن)، مع الإبقاء على حالة "قيد التنفيذ" ورسالة الخطأ الحاليتين.
- `system_screenshot` في مجموعة أدوات يحمل وسائط → يدخل معرض 114d عند توفره.

### السلك

- لا تغيير مطلوب: كتلة الصورة تُسقط تلقائيًا لكل أداة (صور للنماذج الداعمة). تُضاف اختبارات تثبيت: وصول الصورة على سلك محول واحد على الأقل، وسلوك النماذج غير الداعمة للصور يبقى آمنًا.

## Gates

### R0 — Grounding
- [x] مراجعة `ScreenshotTool` الحالي، `ToolImageBlock`، بوابة الإسقاط، مسار hosted relay، وفرع العرض في العميل.
- [x] تثبيت أن إسقاط كتل الصور على السلك عام لكل الأدوات (لا بوابة باسم الأداة).

### G1 — Agent
- [x] إعادة `ToolImageBlock` + نص وصفي من الأداة (فك الأبعاد/النوع).
- [x] توسيع بوابة الإسقاط + اختبار وحدة: النتيجة تحمل كتلة صورة؛ الإسقاط يعيد `available` بالأبعاد الصحيحة.
- [x] اختبار: استرجاع الوسائط عبر hosted relay لنتيجة `system_screenshot`.

### G2 — Client
- [x] عرض بطاقة الوسائط لحدث `system_screenshot` + اختبار ويدجت.
- [x] حالات القيد: قيد التنفيذ/خطأ كما هي.

### G3 — Wire pinning & live acceptance
- [x] اختبار محول: صورة اللقطة تصل على سلك النموذج (كجزء صورة) لصيغة آمنة.
- [x] تحقق حي: تنفيذ أداة سكرين شوت في جلسة حية → اللقطة تظهر في الواجهة وتُستعرض بالـlightbox. — tests-only by user decision: `COMPUTER_USE` is off on the Test Homes, so `system_screenshot` is not registered.
- [x] تحديث docs الأداة/الوسائط ذات الصلة.

## Acceptance criteria

- [x] استدعاء `system_screenshot` يُنتج في الواجهة بطاقة وسائط كاملة (مصغّرة + lightbox) بدل عرض نصي عام.
- [x] النموذج الداعم للصور يستقبل محتوى اللقطة على السلك؛ والنماذج غير الداعمة لا تنكسر.
- [x] يبقى حفظ اللقطة في `Downloads/AgentScreenshots` والنص الوصفي.

## Definition of Done

- [x] `fvm dart analyze` (agent) و`fvm flutter analyze` (client) ناجحان.
- [x] focused tests على الجانبين ناجحة.
- [x] تحقق حي موثق. — tests-only by user decision (see the log below).
- [x] تحديث docs ذات الصلة.
- [x] `graphify update .` ناجح.
- [x] تحديث gate ونسبة المتبقي.

## Progress log

### 2026-10-18 — Implementation (delegated implementer)

Agent: `ScreenshotTool` returned a text-only result. Added `ToolImageBlock` projection, widened
`ViewImageMediaMetadata.project` to accept `system_screenshot`, extended the live translator and the
client media branch, added focused tests. Reported gates: agent analyze 0 issues, focused tests 13 passed.

### 2026-10-18 — Independent review and repair (delegated reviewer)

Reproduced every reported gate (agent analyze 0 issues; screenshot/projection suites exact counts;
client analyze 0 issues; client widget suite). Review verdict: **accepted-with-repairs**.

Defects found and repaired in the same worktree:

1. Non-vision/unknown routes broke the turn. The tool attached an image block unconditionally, while
   every adapter fails closed (`LocalImageCapabilityException`) when a pixel-bearing history entry targets
   a route whose image support is `unsupported`/`unknown`; the screenshot tool result stays in history, so
   the mandatory continuation request failed and kept failing for that session. The tool now attaches the
   capture only when the frozen turn route capability is `supported` and otherwise returns the summary
   text plus an explicit note (same fail-closed rule `view_image` already enforced through
   `ToolContext.imageSupport`).
2. Unbounded/wrong capture handling. The previous revision decoded in-process, bypassed the shared image
   policy (20 MiB input, 4 MiB base64, pixel/edge limits, killable isolate, animated rejection) and threw
   on unsupported or undecodable bytes, losing the `Downloads/AgentScreenshots` save. The capture is now
   projected through `ImageWorker` with `detail: auto`, the backup copy is written first and always, and
   unsupported/oversized/corrupt/timeout captures degrade to a text-only success result.
3. Media event raced durable persistence. `system_screenshot` published its media completion event before
   the tool result was appended and persisted, unlike `view_image`; a live client fetch could resolve
   against missing history and stick on `Image unavailable`. Media-bearing tools now share one deferred
   publication predicate in `ToolExecutionCoordinator` (batch, parallel, and single-tool/resume paths).
4. Client text-only capture surface. A completed `system_screenshot` without media metadata rendered
   `Image unavailable` and hid the summary and saved path. Such rows now keep the regular tool
   presentation; a present-but-rejected or pruned media map retains the neutral unavailable surface.

Docs and contracts updated: `docs/technical/multimodal_tool_results_and_view_image.md`,
`agent/lib/capabilities/AGENTS.md`, `agent/lib/engine/runtime/AGENTS.md`,
`client/lib/features/conversations/AGENTS.md`, `client/lib/features/conversations/presentation/AGENTS.md`.

Verification (this worktree): `fvm dart analyze` 0 issues; `fvm flutter analyze` 0 issues;
full agent suite 2777 passed / 14 skipped; full client suite 1620 passed; focused media suites green with
red/green evidence collected for every added regression. Remaining: orchestrator live acceptance run
(screenshot tool execution in a live session with the media tile and lightbox) and the commit itself.

### 2026-10-21 — ported to the SRP base and re-reviewed (`8a0553ef`)
- Port: applied cleanly onto `adc128ec` (`ToolExecutionCoordinator` already owned tool events before Task 110).
- Defects found in review and repaired:
  1. The media tool set (`view_image`, `system_screenshot`) was hard-coded at three agent sites (metadata projection, coordinator, gateway translator) and four client sites (`event_tile.dart` twice, `brain_activity_view.dart` twice). Fix: `ViewImageMediaMetadata.mediaToolNames` / `isMediaTool` (agent) and `mediaToolNames` / `isMediaToolName` / `isMediaToolEvent` on `ViewImageMediaEvent` (client).
  2. `tool_execution_coordinator.dart` `_executeSequential`: the deferred-result completion path still deferred only `view_image`, so a deferred `system_screenshot` would emit there and again after persistence. Fix: uses `_defersMediaEvent`. Today only the `sanad_dev_switch` deferred kind exists, so the path is unreachable for a screenshot; no dedicated regression.
- Observations, not changed (pre-existing): the backup copy is always named `.jpg` whatever the captured format; the `imagePaht` typo is kept as stable summary text.
- Verification on `feat/114-port`: agent and client analyzers report no issues; full agent suite 3,038 passed / 14 skipped; full client suite 1,810 passed / 1 skipped (`-j 4`); daemon E2E media and attachment-relay suites pass with `--concurrency=1`; `graphify update .` run.
- Not verified: a live `system_screenshot` on a vision route (thumbnail, lightbox), on a non-vision route (text-only row), and through the hosted relay.

### 2026-10-21 — live acceptance r1 and r2 (coordinator, Test Homes 2 and 3)
- r1 on `389caede`: S10 not run live. The Test Homes run with `COMPUTER_USE=false`, so the agent does not register `system_screenshot`; enabling it also exposes the mouse and keyboard tools and needs macOS Screen Recording. By user decision this task is verified by its agent and client tests only.
