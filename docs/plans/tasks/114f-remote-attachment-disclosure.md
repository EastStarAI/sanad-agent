---
title: "Task 114f: Remote Attachment Disclosure on the Model Wire"
status: "in_review"
priority: "high"
depends_on: "none"
current_gate: "G3 (integration/live acceptance)"
remaining_estimate: "15%"
evidence_id: "114-input-media"
evidence_fingerprint: "sha256:4372c21c241d96d7b56042f56f93b79b5a851f9914bcb72305a2191332612f0e"
---

# Task 114f: إفصاح المرفقات البعيدة للنموذج على السلك

## Goal

سلك النموذج يجب أن يعرّف النموذج بالمرفقات غير الصورية (والصور بصيغ غير آمنة) الواردة من الوكيل البعيد عبر سطر مرجعي بمسار جانِب الوكيل + توجيه أدوات، وأن يقيّد أجزاء الصور إلى الصيغ الآمنة فقط — دون تسريب أي مسار من جهة العميل.

## Current state (مثبت من الكود)

- محولات السلك (`base_openai_adapter.dart` وأقرانه) تضيف أجزاء `image_url` للمرفقات الصورية فقط؛ الملفات غير الصورية **لا يصل عنها شيء إطلاقًا** (لا نص ولا مسار ولا ذكر).
- لا بوابة صيغ: أي `image/*` يُسقط كجزء صورة، ما قد يرفضه المزود للصيغ غير المدعومة.

## Locked scope

- helper مشترك واحد (يُستخدم من كل المحولات: OpenAI-compatible / Anthropic / Codex / Ollama) يبني، عند وجود مرفقات غير صورية في رسالة مستخدم، سطر/سطور مرجعية تُضاف إلى محتوى الرسالة الموجّه للنموذج:
  - الصيغة: `[<safe name>](file:///<agent-side absolute path>)` + جملة توجيه واحدة ثابتة (مثل: "استخدم أدواتك لقراءة هذا الملف؛ هو متاح على القرص.") — الصياغة النهائية إنجليزية وثابتة.
  - المسار = مسار الملف **داخل مخزن مرفقات الوكيل** (الجهة المستقبِلة)؛ يُمنع منعًا تامًا أي مسار من جهة العميل.
  - لا استخراج محتوى (يُؤجل كتحسين لاحق).
- بوابة صيغ الصور على السلك: فقط `image/png`/`image/jpeg`/`image/webp`/`image/gif` تُسقط كأجزاء صور؛ أي صيغة صورة أخرى تُعامل كملف (سطر مرجعي) ولا تُرسل كجزء صورة.
- بلا تغيير على المسارات المحلية (التوكنات نص عادي يصل عبر نص الرسالة أصلًا).
- حدود: طول السطر محدود؛ أسماء آمنة فقط؛ لا محتوى ملفات في الرسالة.

## Gates

### R0 — Grounding
- [x] حل packet `114-input-media` وتسجيل fingerprint.
- [x] تتبع مسار رسالة المستخدم الحالية على السلك في المحولات الأربعة وتحديد نقطة الإدراج المشتركة.
- [x] تحديد واجهة مخزن المرفقات لاشتقاق مسار الملف على جانب الوكيل.

### G1 — Shared wire helper
- [x] helper واحد يبني سطور الإفصاح (اسم آمن + مسار الوكيل + توجيه) بلا مسارات عميل.
- [x] بوابة الصيغ الآمنة لأجزاء الصور في كل المحولات.

### G2 — Tests
- [x] اختبارات محولات: مرفق غير صوري → السطر المرجعي حاضن بمسار الوكيل؛ صورة آمنة → أجزاء صورة بلا سطر؛ صيغة صورة غير آمنة → سطر مرجعي بلا جزء صورة.
- [x] تأكيد غياب أي مسار عميل في الحمولة الكاملة (بحث سلبي على النص).
- [x] عدم انحدار مسارات الصور الآمنة الحالية.

### G3 — Live/integration & docs
- [ ] تحقق تكاملي: جلسة على وكيل بعيد/محاكى بمرفق PDF → النموذج يرى السطر ويستطيع قراءة الملف بأدواته.
- [x] تحديث docs بروتوكول/سلك المرفقات ذات الصلة.

## Acceptance criteria

- [ ] رسالة مستخدم تحمل مرفق PDF من وكيل بعيد: سلك النموذج يحوي سطرًا مرجعيًا بمسار الوكيل + توجيه، وبلا أي مسار عميل.
- [ ] صورة PNG آمنة تُسقط كجزء صورة كما اليوم؛ HEIC لا يُسقط كجزء صورة أبدًا.
- [ ] لا انحدار على المحولات الأربعة (اختباراتها الخضراء).

## Definition of Done

- [x] `fvm dart analyze` ناجح.
- [x] focused agent tests ناجحة.
- [ ] تحقق تكاملي موثق.
- [x] تحديث docs ذات الصلة.
- [x] `graphify update .` ناجح.
- [x] تحديث gate ونسبة المتبقي.

## Progress log

### 2026-10-18 — implemented, independently reviewed, committed (`9c641c6f`)
- Implementer (`agy`): `user_attachment_wire_discloser.dart` + a 17-test disclosure suite; all four adapter families wired; store path via `AttachmentStore.resolveAttachmentPath` (fallback `<SANAD_STATE_HOME>/attachments/<id>/payload`).
- Reviewer (`sanad`, `--thinking-mode max`): verdict `accepted-with-repairs` — repaired a real client-path leak in the resolution fallback (red→green at discloser and OpenAI HTTP-body level), removed the `image/jpg` alias from the gate, hardened name sanitization/bounds; suite 17→24 passing; broad sweep 465 passed; analyzer clean; docs corrected to the percent-encoded `file://` URI form.
- Merged into `feat/114-input-files-and-media` (fast-forward).
- Remaining: live/integration acceptance (remote agent reading the disclosed file with tools), frozen suites at integration, delivery.

### 2026-10-21 — ported to the SRP base and re-reviewed (`aff1e56e`)
- Port: the image-only text projection inversion moved from `AgentRunner` to `runtime/runner_context_projector.dart` (the runner keeps its delegating test hook). Main's 116 projection had changed the OpenAI `_messageToWire` signature, so the attachment store is now passed explicitly. Anthropic reads it from `options`.
- Review: no behavioral defect found. Checked: one shared discloser across the OpenAI, Anthropic, Codex, and Ollama paths with no double disclosure; the store path is jailed to the agent store (no client path); the safe-format gate also drives `hasImages` and verified-attachment loading. The suite asserted only `contains`, so exactly-once assertions for the reference/guidance sentence were added in every adapter family.
- Observation, not changed: `engine/context/compaction_token_estimator.dart` (from 116) still counts every `image/*` attachment as an image. This over-estimates for disclosed exotic formats, which is the safe direction.
- Verification on `feat/114-port`: agent and client analyzers report no issues; full agent suite 3,038 passed / 14 skipped; full client suite 1,810 passed / 1 skipped (`-j 4`); daemon E2E media and attachment-relay suites pass with `--concurrency=1`; `graphify update .` run.
- Not verified: a session on a remote agent with a PDF attachment where the model reads the disclosed file with its tools.
