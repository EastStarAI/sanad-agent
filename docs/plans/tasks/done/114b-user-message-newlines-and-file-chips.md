---
title: "Task 114b: User-Message Newlines and File Reference Chips"
status: "done"
priority: "high"
depends_on: "none"
current_gate: "closed (live acceptance r1 and r2 recorded)"
remaining_estimate: "0%"
---

# Task 114b: عرض رسالة المستخدم — إظهار أسطر Shift+Enter + شرائح مراجع الملفات

## Goal

إصلاح إخفاء الأسطر التي يضيفها المستخدم بـ Shift+Enter في سجل المحادثة، وعرض روابط مراجع الملفات (`file://`) داخل رسالة المستخدم كشريحة (أيقونة نوع الملف + الاسم) بدل رابط نصي، دون أي تنقّل فعلي.

## Root cause (مثبت من الكود)

- `MarkdownBody` في `client/lib/features/conversations/presentation/widgets/user_message_tile.dart` لا يمرر `softLineBreak`؛ القيمة الافتراضية في `flutter_markdown_plus` هي `false` فتُستبدل فواصل السطر المفردة (`\n`) بمسافة → تختفي أسطر Shift+Enter.

## Locked scope

- تمرير `softLineBreak: true` لعرض نص رسالة المستخدم فقط (لا تُغيَّر عروض ردود المساعد).
- التحقق من أن منطق الطي "Read more" (حساب الأسطر عبر TextPainter) لا ينحدر مع الأسطر المتعددة، وتعديله إن لزم.
- builder مخصص في markdown لعناصر الروابط ذات المخطط `file://` داخل رسالة المستخدم:
  - تُعرض كشريحة: `FileExtensionIcon` (`client/lib/shared/widgets/file_extension_icon.dart`) + اسم الملف، بمحاذاة start داخل نص الرسالة.
  - بلا تنقّل: لا يُستدعى `openExternalUrl` لروابط `file://` (أي نقرة لا تفتح شيئًا)؛ يمكن إضافة tooltip بالمسار الكامل.
  - الروابط العادية (`https` وغيره) تبقى بسلوكها الحالي.
- لا تغيير على نص الرسالة المُخزَّن أو المُرسَل؛ التغيير عرضٌ فقط.

## Gates

### R0 — Grounding
- [x] تأكيد السبب الجذري (softLineBreak) على عيّنة رسالة فعلية متعددة الأسطر.
- [x] مراجعة builders الحالية في `user_message_tile.dart` و`MarkdownStyleHelper`.

### G1 — Newline fix
- [x] `softLineBreak: true` + التحقق من الطي "Read more".
- [x] اختبار ويدجت: رسالة بسطرين (Shift+Enter) تُعرض على سطرين؛ رسالة سطر واحد دون تغيير.

### G2 — File chips
- [x] builder للروابط `file://` كشريحة أيقونة+اسم دون تنقّل.
- [x] اختبارات ويدجت: شريحة تظهر لمرجع ملف؛ رابط https يبقى رابطًا؛ لا استدعاء لفتح خارجي.

### G3 — Live acceptance & docs
- [x] تحقق حي: إرسال رسالة بأسطر Shift+Enter ومرجع ملف، وفحص السجل. — r1 S7.
- [x] تحديث docs عرض المحادثة ذات الصلة.

## Acceptance criteria

- [x] أي سطر يُضاف بـ Shift+Enter يظهر كسطر فعلي في رسالة المستخدم بسجل المحادثة. — r1 S7 (newlines entered by the driver; the physical Shift+Enter keystroke is covered by tests).
- [x] مرجع الملف يظهر كشريحة أيقونة+اسم في رسالة المستخدم ولا يظهر المسار كنص. — r1 S6, S7.
- [x] لا انحدار في الطي/النسخ/تحديد النص. — r1 S6 copy returns the exact link; S7 "Read more" count 0.

## Definition of Done

- [x] `fvm flutter analyze` ناجح.
- [x] focused widget tests ناجحة.
- [x] تحقق حي موثق. — see the live acceptance log below.
- [x] تحديث docs ذات الصلة.
- [x] `graphify update .` ناجح.
- [x] تحديث gate ونسبة المتبقي.

## Progress log

### 2026-10-18 — implemented, independently reviewed, committed (`812acf89`, merged `73b78bf1`)
- Implementer (`agy`): `softLineBreak: true` for the user-message body; `UserMessageLinkBuilder` + inert `UserMessageFileChip` (icon + name, full-path tooltip, no navigation); 13 tests passing; analyze clean.
- Reviewer (`sanad`, `--thinking-mode max`): verdict `accepted-with-repairs` — strengthened the copy test to capture the real `Clipboard.setData` payload, added 5 regressions (pixel line-break proof, fenced code unaffected, percent-encoded chip name + decoded tooltip, multiple chips + https, RTL/Arabic chip), fixed an analyzer failure, updated `docs/product/client_interface.md`; suite 13→18 passing.
- Flagged deviation (kept, revertible in `UserMessageLinkBuilder`): non-file links now render primary+underlined (previously plain).
- Pre-existing follow-up (not repaired, out of scope): the collapsed-line measure counts raw markdown, so several long file tokens can show "Read more" although chips render compactly.
- Remaining: live acceptance (send a Shift+Enter + file-reference message and inspect the history), frozen suites at integration, delivery.

### 2026-10-21 — ported to the SRP base and re-reviewed (`11ec07a9`)
- Port: applied cleanly onto `adc128ec`.
- Defects found in review and repaired:
  1. `user_message_tile.dart` `UserMessageLinkBuilder`: the chip and ordinary links were returned as non-`Text` widgets. `flutter_markdown_plus` lays those out as separate `Wrap` children, so a long paragraph broke around every link or chip. Ordinary links were also restyled (primary, underlined), contrary to the locked scope that they keep their current behavior. Fix: both are returned as `Text.rich` (a `WidgetSpan` chip; a recognizer-backed `TextSpan` in the stylesheet's own link style), so they merge into the paragraph. Regression: "file chips and links stay inline" (one `Wrap` with one merged child); link tests now tap through the span.
  2. Same file: "Read more" was decided on raw Markdown, so short messages with a few long `file:///` URIs collapsed spuriously. The earlier review deferred this as pre-existing, but 114a makes such tokens routine. Fix: `measurableText` counts a file reference by its displayed name (through `FileReferenceLink.pattern`). Regression: "long file reference URIs do not trigger Read more" (red without the fix).
- Docs: `docs/product/client_interface.md` states inline flow, unchanged link style, and the measure rule.
- Verification on `feat/114-port`: agent and client analyzers report no issues; full agent suite 3,038 passed / 14 skipped; full client suite 1,810 passed / 1 skipped (`-j 4`); daemon E2E media and attachment-relay suites pass with `--concurrency=1`; `graphify update .` run.
- Not verified: live send of a Shift+Enter message with file references and history inspection.

### 2026-10-21 — live acceptance r1 and r2 (coordinator, Test Homes 2 and 3)
- r1 on `389caede`: S7 passes. A four-line message with two file links and a URL with parentheses renders as real lines, with inline icon+name chips and no raw path. S6: Copy returns the exact pinned link form.
- r2 on `571844f6`: sent HEIC file cards use the image icon and PDF cards the PDF icon (file type icons, 114j).
