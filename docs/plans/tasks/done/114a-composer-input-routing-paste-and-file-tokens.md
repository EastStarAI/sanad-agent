---
title: "Task 114a: Composer Input Routing, Paste Repair, and File Path Tokens"
status: "done"
priority: "high"
depends_on: "none"
current_gate: "closed (live acceptance r1 and r2 recorded)"
remaining_estimate: "0%"
evidence_id: "114-input-media"
evidence_fingerprint: "sha256:4372c21c241d96d7b56042f56f93b79b5a851f9914bcb72305a2191332612f0e"
---

# Task 114a: مدخل الرسائل — توجيه موحّد للصق والإفلات وزر الإرفاق + إصلاح اللصق + توكنات الملفات

## Goal

توحيد سلوك المداخل الثلاثة (لصق، إفلات، زر `+`) وفق مصفوفة توجيه واحدة، إصلاح فشل لصق الصور بالكيبورد على macOS، تمثيل الملفات غير الصورية على الوكيل المحلي كتوكنات مسار صديقة للمستخدم تُصدَّر بصيغة `[name](file:///…)` عند الإرسال، وإصلاح محاذاة شريط المرفقات إلى بداية السطر.

## Locked scope

### مصفوفة التوجيه الواحدة (لصق/إفلات/زر +)

- صورة بصيغة آمنة للمزود (`image/png`, `image/jpeg`, `image/webp`, `image/gif`) وحجم ≤ 5 MiB → مرفق عبر المسار الحالي.
- صورة بصيغة آمنة وحجم > 5 MiB على وكيل نفس الجهاز → توكن مسار (بلا رفض)؛ على وكيل بعيد → رفض واضح بواجهة المرفقات الحالية.
- صورة بصيغة غير آمنة (HEIC/TIFF/BMP/SVG/…) → توكن مسار على وكيل نفس الجهاز؛ على وكيل بعيد → مرفق (ويُعالج على السلك كمرجع ملف — انظر 114f).
- ملف غير صورة على وكيل نفس الجهاز → توكن مسار.
- ملف غير صورة على وكيل بعيد → مرفق (≤ 5 MiB؛ فوقها رفض واضح).
- غياب قدرة المرفقات على وكيل نفس الجهاز: صورة آمنة ≤ 5 MiB تهبط إلى توكن مسار بدل الفشل.
- لا حد لعدد التوكنات.

### تمييز المحلي/البعيد

- يُستخدم `DeviceConfig.isLocalCandidate` (تطابق `hardwareId`) وليس `isLocalReachable` (الاتصال بالسوكيت).
- الجوال يُعتبر دائمًا بعيدًا. غياب/جهل الهوية العتادية = بعيد (افتراضي آمن).

### إصلاح اللصق

- التشخيص أولًا: تحديد المرحلة الفاشلة فعليًا على macOS (التقاط الحدث مقابل قراءة الحافظة مقابل القبول) بأدوات تشخيص مؤقتة في تشغيل تطويري.
- الإصلاح المقترح: اعتراض مقصود لـ Cmd/Ctrl+V على مستوى المدخل (Shortcuts/Actions) يفحص الحافظة للصور والملفات ثم يمرر `PasteTextIntent` للنص؛ لا يُعتمد على مسار `ClipboardEvents` المعطّل خارج iOS/الويب.
- القراءة تقبل: بيانات صورة بكل الصيغ الشائعة + `file://` URLs (ملفات Finder) + عناصر متعددة، مع إزالة التكرار.
- لصق النص العادي يبقى دون تغيير.

### توحيد الإفلات

- حذف `DropTarget` القديم في `conversation_input_panel.dart` مع `_insertDroppedPaths` واستخدام `insertDroppedPathsAtSelection` الخام.
- `DropTarget` واحد يوجّه حسب المصفوفة، مع الحفاظ على حالة السحب البصرية الحالية؛ الدفعات المختلطة تُوجَّه عنصرًا بعنصر.

### توكنات مسارات الملفات

- تعميم `SlashCommandTextController` لدعم نوع توكن ملفات إلى جانب توكنات الأوامر: ماركر خاص + `WidgetSpan` يعرض `FileExtensionIcon` + اسم الملف (ودجت `client/lib/shared/widgets/file_extension_icon.dart`).
- التصدير عند الإرسال: `[<file name>](file:///<percent-encoded absolute path>)` عبر `Uri.file(...).toString()`.
- تنظيف الماركرات عند الحذف (منطق `_pruneMissingTokens` الحالي) + إعادة توكنة تلقائية لأنماط الروابط المعروفة عند استعادة المسودة في `_setComposerText` (عند تعذّرها يبقى النص صالحًا للإرسال).

### المحاذاة

- `Column` داخل `composerCard` في `conversation_input_composer.dart` يفتقد `crossAxisAlignment` فيرث `center` وتتمركز عناصر الشريط؛ الإصلاح إلى `CrossAxisAlignment.start`.

## Gates

### R0 — UX grounding
- [x] حل packet `114-input-media` وتسجيل fingerprint.
- [x] مراجعة composer الحالي (drop/paste/rail)، وحدة التوكنات، أعلام محلية الجهاز، وتدفق إرسال المرفقات.

### G1 — Paste capture repair
- [x] توثيق المرحلة الفاشلة فعليًا على macOS بتشخيص مؤقت (السببان: مراقب NSEvent الأصلي يحجب Cmd+V + مسار fallback معطّل/أحادي الصيغة).
- [x] تنفيذ الالتقاط الموثوق (صورة/ملفات/متعدد) مع إبقاء لصق النص.
- [x] تحقق حي: لصق لقطة شاشة → مرفق؛ لصق ملف Finder → مسار حسب المصفوفة؛ لصق نص → كما هو. (يملكه المنسّق) — live r1 S1 pass.

### G2 — Unified routing & drop unification
- [x] دالة توجيه واحدة تُستخدم من اللصق والإفلات وزر `+`.
- [x] حذف `DropTarget` القديم والاستخدام الخام لإدراج المسارات.
- [x] واجهة أخطاء واضحة للرفض (بعيد > 5 MiB) وبقاء النص والمرفقات سليمة.

### G3 — File path tokens
- [x] تعميم وحدة التوكنات + عرض الأيقونة والاسم + صيغة التصدير المثبتة.
- [x] استعادة المسودات بإعادة التوكنة + تنظيف الماركرات.
- [x] اختبارات وحدة/ويدجت: إدراج/تصدير/حذف/استعادة + غياب أي مسار خام في الواجهة.

### G4 — Alignment, integration & live acceptance
- [x] محاذاة الشريط إلى start + تحديث/إضافة اختبارات.
- [x] اختبارات تكامل للمداخل الثلاثة (مصفوفة كاملة: صورة/غير آمنة/ملف/محلي/بعيد).
- [x] تحقق حي موثق على macOS (لصق، إفلات، زر +، محاذاة) + تحديث docs المدخل. (التحقق الحي يملكه المنسّق؛ تحديث docs المدخل قيد المراجعة) — paste, drop, and alignment live (r1 S1, S3, S12; r2 C3); the `+` picker is tests-only (not drivable).

## Acceptance criteria

- [x] لصق صورة (لقطة شاشة) عبر Cmd+V يُنتج مرفقًا على macOS. — r1 S1.
- [x] لصق ملف منسوخ من Finder على وكيل نفس الجهاز يُنتج توكن مسار؛ وعلى وكيل بعيد يُنتج مرفقًا (≤ 5 MiB) أو رفضًا واضحًا. — r1 S1, S2; r2 attachment error.
- [x] إفلات `.md` على وكيل نفس الجهاز يُنتج توكنًا، وإفلات `.png` يُنتج مرفقًا، وكلاهما بنفس نتيجة اللصق وزر `+`. — drop/paste parity r2 C3; `+` tests-only.
- [x] التوكن يعرض أيقونة نوع الملف والاسم، ويُصدَّر عند الإرسال بصيغة `[name](file:///…)` دون حد عدد. — r1 S6.
- [x] لا يوجد أي مسار مطلق يظهر كنص خام في المدخل أو سجل المحادثة. — r1 S6/S7; inline editor fixed by D1, r2 pass.
- [x] شريط المرفقات يبدأ من بداية السطر (start) وليس متمركزًا. — r1 S12.

## Definition of Done

- [x] `fvm flutter analyze` ناجح.
- [x] focused unit/widget tests ناجحة (توجيه، توكنات، محاذاة، لصق).
- [x] تحقق حي موثق على macOS. — see the live acceptance log below.
- [x] تحديث docs المدخل/المرفقات ذات الصلة.
- [x] `graphify update .` ناجح.
- [x] تحديث gate ونسبة المتبقي.

## Progress log

### 2026-10-18 — implemented, independently reviewed, committed (`f37e380f`, merged `4f6f1c43`)
- Implementer (`agy`): root cause in two stages — (1) `client/macos/Runner/MainFlutterWindow.swift` native `NSEvent` monitor intercepted Cmd+V and returned `nil` for non-string clipboards, suppressing the event before Flutter; (2) the composer fallback used iOS-only `ClipboardEvents` and checked `Formats.png` only. Repairs: native monitor + dead channels removed; `ComposerPasteIntent` via `Shortcuts`/`Actions` reading `fileUri` + 10 image formats with `PasteTextIntent` fallback; `ComposerInputRouter` unified matrix for paste/drop/picker; token controller generalized (`FileExtensionIcon` + `[name](file:///…)` export + draft re-tokenization); `crossAxisAlignment.start`.
- Reviewer (`sanad`, `--thinking-mode max`): verdict `accepted-with-repairs` — no production defect found; added 3 red/green regressions (real Cmd+V keystroke through `Shortcuts`, drop/paste parity, no raw-path assertions); GATE A reproduced (75 passed); extra blast-radius 62 passed; `fvm flutter build macos --debug` exit 0 (Swift change compiles); red proofs collected.
- Residual notes: live macOS acceptance (screenshot paste, Finder file paste, multi-item clipboard) remains orchestrator-owned; `composer_text_editing.dart` + its test are now dead code (cleanup candidate); `macos/Podfile.lock` staleness is pre-existing on `main` (unrelated).
- Remaining: live acceptance, composer docs touch-up, frozen suites at integration, delivery.

### 2026-10-21 — ported to the SRP base and re-reviewed (`2d6a33b3`, `27f51657`)
- Port: applied onto `adc128ec`; only the panel import conflicted (main had added the compaction formatter and localization imports). The uncommitted composer doc edit from the old 114a worktree was carried over and extended.
- Defects found in review and repaired:
  1. `composer_input_router.dart`: attachment bytes were read only through `dart:io` `File(path)`. Web blob paths and data-backed `XFile`s produced empty attachments (the picker test did not check bytes). Fix: `ComposerRoutableItem.readBytes` / `loadBytes()` reads from the originating `XFile` first. Regression: the picker test asserts bytes; `loadBytes` unit test.
  2. `conversation_input_composer.dart`: the Cmd/Ctrl+V shortcut fired for the whole composer subtree and the text fallback always pasted into the message field. Fix: `_ComposerPasteAction.isEnabled` requires message-field focus, so other fields keep their own paste. Regression: "Cmd+V while another composer control has focus never reads the clipboard" (red without the fix).
  3. `composer_input_router.dart`: a pasted image kept the clipboard's suggested extension even when another format was read (for example `photo.heic` delivered as PNG bytes), which misrouted it. Fix: `fromImageBytes` uses the read format's extension.
  4. `composer_input_router.dart`: `isSameMachineAgent` excluded mobile but not web. Fix: requires a desktop client (`!isMobile && isDesktop`).
  5. `slash_command_text_controller.dart`: exported links did not escape `[`/`]` in names, and `Uri.file` leaves `(`/`)` unencoded. Draft re-tokenization (`[^\s\)]+`) failed on such paths, so a restored draft showed raw Markdown. Fix: new single owner `presentation/utils/file_reference_link.dart` (format, parse, escape), used by the controller and the user-message measure. Regression: `file_reference_link_test.dart` (round trip, legacy unescaped parentheses, restore/export identity).
  6. Dead code removed: `presentation/utils/composer_text_editing.dart` (+ test) and `core/presentation/utils/external_paste_manager.dart`.
  7. Rejection copy duplicated between router and cubit: now shared `ConversationInputCubit` constants.
  8. `test/tool/app_web_startup_contract_test.dart` still required `AppPlatform.isMacOS` in `lib/app.dart` after the native paste channel was removed (the full suite failed; the earlier review ran focused suites only). The contract now asserts the invariant: `AppPlatform` branches, no `dart:io`, no direct `Platform.is*`.
- Contract: `client/AGENTS.md` composer law updated (router, token controller, `FileReferenceLink`, same-machine rule).
- `fvm flutter build macos --debug` succeeds (Swift monitor removal compiles).
- Verification on `feat/114-port`: agent and client analyzers report no issues; full agent suite 3,038 passed / 14 skipped; full client suite 1,810 passed / 1 skipped (`-j 4`); daemon E2E media and attachment-relay suites pass with `--concurrency=1`; `graphify update .` run.
- Not verified: live macOS paste (screenshot, Finder file, multi-item), drop and `+` on a real same-machine and remote agent, Windows/Linux keyboard paste, and real web drop (proved only by unit tests).

### 2026-10-21 — live acceptance r1 and r2 (coordinator, Test Homes 2 and 3)
- Method: real macOS pasteboard contents (`pbcopy`, PNG flavour, file URLs as Finder writes them) with Cmd+V and `desktop_drop` messages injected through the client VM service. These are not OS keystrokes or a real OS drag; the native `+` picker (`NSOpenPanel`) was not drivable.
- r1 on `389caede`: S1 (text, PNG, and Finder-file paste), S2 (remote), S4 (large PNG + HEIC drop), S5 (Cmd+V in another field stays there), S6 (bracketed names, draft restore, exact export), and S12 (rail at line start) pass; S3 (drop/paste parity) partial. Defects D2, D3, D4 and two minors (duplicate paste, HEIC icon) were found and fixed in round 5 (see the plan).
- r2 on `571844f6`: D2, D3, and D4 pass on ChatGPT `gpt-6-luna`, OpenRouter `gpt-4o-mini`, and OpenCode Go `deepseek-v4.1-flash`; duplicate-paste dedupe and the HEIC image icon pass; drop/paste parity passes locally and remotely (S3 re-check); the composer attachment error passes in en and ar with every clear path (×, remove, next add, text-only send, scope change).
- r2 also found that the r1 clipboard writer (JXA `writeObjects` then exit) sometimes left only the first file on the pasteboard, which likely explains part or all of the r1 D3 report.
- Tests-only: the native `+` picker, a real OS drag on macOS, Windows/Linux keyboard paste, real Web drop, and non-default device limits (the agent limits are compile-time constants).
