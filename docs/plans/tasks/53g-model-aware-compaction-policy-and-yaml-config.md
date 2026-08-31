---
title: "Task 53g: Accurate Context Measurement, Model-Aware Compaction Policy, and YAML Config"
description: "تصحيح قياس ضغط السياق وترتيب أحداثه، ثم إضافة سياسة YAML مستقلة حسب النموذج لنافذة السياق وموعد الضغط وميزانية الذيل."
status: "in_review"
current_gate: "G5"
priority: "critical"
depends_on: "Task 53f"
evidence_id: "53-compaction-policy-reference"
evidence_fingerprint: "sha256:9e0846fec0f8ea1115addd4e34e1af2bbb5bf2b905486e8cd67610b12e5ae6da"
---

# Task 53g: صحة قياس السياق وسياسة الضغط حسب النموذج

## 1. الهدف

إزالة اختلاف أرقام ضغط السياق عن القياس الذي يعيده المزود، وإصلاح ترتيب حدث compaction بعد استعادة تاريخ المحادثة، ثم إتاحة ضبط نافذة السياق وسياسة الضغط بنسب مستقلة لكل نموذج من `$SANAD_HOME/config.yaml`.

صحة القياس وترتيب الـtimeline بوابتان سابقتان لتفعيل السياسة الجديدة؛ لا تُقبل إعدادات نسب تعمل فوق رقم معروف الخطأ.

## 2. العقد المثبت

```yaml
context:
  modelLimits:
    gpt-5.6-sol: 258000

compaction:
  threshold: 0.80
  targetRatio: 0.10

  models:
    gpt-5.6-sol:
      threshold: 0.85
      targetRatio: 0.08
```

- `context` و`compaction` مجالان منفصلان: الأول يحل نافذة النموذج، والثاني يقرر متى يضغط وكم يحتفظ من التاريخ الحديث.
- الملف canonical لهذه الإعدادات غير السرية هو `$SANAD_HOME/config.yaml` ويقرأ عند بدء daemon؛ يتطلب تغييره restart في هذا الإصدار.
- `context.modelLimits` افتراضيًا `{}`. المفتاح model id بعد normalization والمطابقة exact؛ لا wildcards ولا substring matching في هذه المهمة.
- عند غياب context override يكون ترتيب حل النافذة: metadata الحية من المزود، ثم model metadata الحالية، ثم fallback المزود الحالي.
- `compaction.threshold` افتراضيًا `0.80` من effective input window، و`compaction.targetRatio` افتراضيًا `0.10` لميزانية retained history الحديثة.
- `compaction.models` افتراضيًا `{}`. يستطيع كل نموذج تجاوز `threshold` أو `targetRatio` منفردًا، وكل مفتاح غائب يرث القيمة العامة.
- لا يوجد `thresholdTokens` في العقد العام أو داخل `models`: التحكم في هذه المرحلة نسبي فقط، مع بقاء output reservation وsafety buffer وoverflow recovery ضمانات داخلية غير قابلة للتعطيل.
- target هي ميزانية مستهدفة للذيل وليست وعدًا بأن إجمالي الطلب بعد الضغط يساوي النسبة نفسها؛ system/runtime prompts وtool schemas وsummary overhead تقاس وتعرض منفصلة.
- يزال `CONTEXT_LIMIT` من config وtemplate ومسار الحل. وجوده في `.env` قديم لا يؤثر ولا يتحول إلى override لكل النماذج.
- الأسرار تظل في SecretStore/Keychain ولا تنقل إلى YAML.

## 3. Gate G0 — إعادة الإنتاج وتثبيت حقيقة القياس والترتيب

- [x] حفظ reproduction للحالة المرصودة: سند يعرض قبل الضغط `463K` مقابل `359K` من المزود، وبعده `116K` مقابل `82K`، دون تخزين محتوى المحادثة أو أسرارها في fixture.
- [x] تتبع كل منتج ومستهلك لـprovider-reported input usage وestimated request pressure وcontext-window denominator وبطاقة حدث الضغط.
- [x] إثبات مساهمة مكونات التقدير كل على حدة: history، system prompt، runtime context، tool schemas، media، reasoning، وprovider replay state.
- [x] التحقق لكل protocol من الحقول التي تصل فعلًا إلى wire، ومنع عد `content` وprovider replay البديل له مرتين أو عد reasoning/state لا يرسله adapter.
- [x] إعادة إنتاج عيب history hydration المؤكد الذي يضع حدث compaction أسفل رد النموذج بدل موضعه السببي الصحيح.
- [x] تحديد مالك ترتيب الدمج بين canonical messages وcompaction lifecycle rows، وعدم إصلاح العيب بفرز عرضي داخل widget يخفي خطأ المصدر.
- [x] تحديث evidence packet/run record إذا بقيت مصفوفة القرار فيها تصف السياسة السابقة، مع إبقاء التفاصيل الخاصة بالمشاريع المرجعية خارج الملفات المتتبعة.
- [x] إضافة اختبارات regression تفشل على السلوك الحالي للقياس والترتيب قبل تعديل الإنتاج.

### G0 Exit

- [x] يوجد تفسير رقمي موثق لفارق القياس، وليس مجرد تغيير معامل `charsPerToken`.
- [x] يوجد تفسير واحد مثبت لترتيب الحدث الخاطئ في live history مقابل rehydrated history.

## 4. Gate G1 — قياس موثوق ومتصالح مع المزود

- [x] جعل `input_tokens` أو context usage الصريحة من آخر استجابة المزود على نفس route/model هي baseline الموثوقة، دون جمع billing totals أو output/reasoning tokens معها.
- [x] قياس الضغط المتوقع من آخر snapshot موثوقة مع تقدير الرسائل والحمولة الجديدة التي لم تشملها فقط؛ لا يعاد تقدير التاريخ المؤكد كاملًا.
- [x] عدم إعادة استخدام snapshot بعد model/route/protocol/config revision switch أو بعد boundary غيّرت الإسقاط الذي قيس عليه.
- [x] عند غياب usage موثوقة، يقدّر adapter الحمولة الفعلية التي سيبعثها على wire، لا كائنات `Message` العامة؛ ويظل القياس موسومًا `estimated`.
- [x] استخدام القياس الأفضل المتاح فعليًا في preflight وداخل tool loop بدل إبقاء `confirmedInputTokens` metadata غير مؤثرة في القرار.
- [x] بعد أول provider response تلي compaction، مصالحة after-compaction metric مع الرقم المؤكد وحفظ provenance دون تغيير canonical history أو boundary.
- [x] لا تعرض الواجهة رقمًا تقديريًا كأنه حقيقة: تعرض `Estimated` حتى المصالحة، ثم `Provider confirmed` عند توفر القياس.
- [x] تسجيل component totals وmeasurement kind وroute identity بصورة bounded وآمنة تكفي للتشخيص دون payloads أو أسرار.

### G1 Exit

- [x] الرقم المؤكد في سند يساوي provider input usage لنفس model invocation.
- [x] أي فرق متبقٍ يقتصر على tail أضيف بعد آخر snapshot ويظهر صراحة كتقدير، مع اختبار يثبت تقلصه عند وصول القياس التالي.
- [x] لا يقرر auto-compaction اعتمادًا على aggregate usage أو تقدير كامل يعارض snapshot موثوقة متاحة.

## 5. Gate G2 — ترتيب compaction lifecycle في الـtimeline

- [x] تثبيت causal ordering key مشترك لرسائل المحادثة وأحداث compaction عند البث والتخزين والاسترجاع.
- [x] يظهر started/completed أو failed بعد الرسالة/الخطوة التي سببت الضغط وقبل أول model output يستخدم الإسقاط المضغوط.
- [x] يحافظ reload وrestart وhistory pagination على الموضع نفسه دون نقل الحدث أسفل الرد النهائي.
- [x] تبقى انتقالات compaction الواحدة logical event واحدة، ولا تنشئ retry أو hydration أحداث نجاح مكررة.
- [x] تغطي الاختبارات manual وauto وoverflow، وcompleted وfailed، وlive stream مقابل history hydration.

### G2 Exit

- [x] ترتيب الحدث متطابق قبل reload وبعده في daemon-backed verification.
- [x] لا يعتمد الإصلاح على timestamp منخفض الدقة أو ترتيب إدراج قاعدة البيانات وحده عند تساوي القيم.

## 6. Gate G3 — YAML schema وحل نافذة النموذج

- [x] تعريف types مركزية لـ`context.modelLimits` و`compaction` و`compaction.models` بالقيم الافتراضية المثبتة.
- [x] تحميل `$SANAD_HOME/config.yaml` عند startup دون ترحيل إعدادات المشروع غير المرتبطة.
- [x] استخدام defaults عند غياب الملف أو section أو key اختيارية، مع inheritance مستقل لكل مفتاح model override.
- [x] رفض YAML غير الصالحة، والمفاتيح غير المعروفة، والنسب خارج `(0, 1)`، والحدود غير الموجبة بخطأ config واضح وآمن.
- [x] إزالة `CONTEXT_LIMIT` من `AppConfig` و`.env` template وكل short-circuit يعتمد عليه.
- [x] تطبيق exact normalized model-id override من `context.modelLimits` قبل metadata الحالية، واختبار نموذجين بحدين مختلفين ونموذج بلا override.
- [x] رفض `thresholdTokens` و`modelThresholds` كمفاتيح غير معروفة بدل إبقاء مسارين متعارضين للسياسة الجديدة.

### G3 Exit

- [x] لا يستطيع إعداد عام واحد فرض نافذة واحدة على جميع النماذج.
- [x] النموذج غير المذكور يحتفظ بالنافذة الصحيحة الحالية، وإعدادات compaction لا تغير context-window resolution.
- [x] schema والdefaults والvalidation وrestart requirement موثقة ومغطاة باختبارات.

## 7. Gate G4 — Ratio trigger والذيل المتصل

- [x] حساب trigger من effective input window و`threshold` الخاصة بالنموذج أو `0.80` العامة، بعد output reservation وsafety buffer.
- [x] استخدام measurement contract من G1 قبل model invocation وداخل tool loop، مع بقاء overflow recovery الواحدة مستقلة.
- [x] اشتقاق retained-history target من effective input window و`targetRatio` الخاصة بالنموذج أو `0.10` العامة.
- [x] اختيار suffix من أحدث الرسائل إلى الخلف؛ إذا وقع الحد داخل turn، يدخل prefix الأقدم في summary ويبقى suffix الأحدث في الذيل.
- [x] لا توجد فجوة: كل model-visible message تدخل إما في summary source أو retained tail، مع بقاء canonical history كاملة وغير هدامة.
- [x] تبقى tool call/result groups ذرية، ويُعالج oversized tool/media payload داخل projection دون حذف السجل الأصلي.
- [x] تحفظ summary الطلب الحالي والقيود والقرارات والتقدم والمعرّفات، مع quality audit ومحاولة إصلاح واحدة bounded وفشل مغلق عند فقد continuity.
- [x] repeated compaction تعيد تلخيص summary السابقة والمصدر الأقدم دون تكرار أو إسقاط رسائل ودون تفعيل boundary غير صالحة.

### G4 Exit

- [x] اختبارات الحدود أسفل/عند/فوق threshold وتجاوزات نموذجين ناجحة.
- [x] سيناريو رسالة مستخدم يتبعها عدد كبير من الأدوات يثبت أن الجزء الأقدم لُخص والأحدث بقي، دون رسائل مفقودة أو tool pairs يتيمة.
- [x] القياس بعد الضغط يثبت أن retained history ضمن target، وأن إجمالي الطلب وoverhead معروضان منفصلين.

## 8. Gate G5 — التكامل والتوثيق والتحقق

- [x] تحديث وثائق agent engine والتشغيل وQA وأي `AGENTS.md` أصبحت عباراتها stale.
- [x] تحديث template/example آمن لـYAML دون أسرار أو `thresholdTokens`.
- [x] تشغيل analyzer والاختبارات المركزة للقياس والمصالحة والترتيب والloader/resolution/trigger/tail/repeated compaction.
- [x] تشغيل daemon-backed verification على provider usage حقيقية يثبت provider-confirmed parity قبل الضغط وبعده.
- [x] تشغيل live ثم reload verification يثبت موضع compaction event قبل model response في الحالتين.
- [x] التحقق من override لنموذج واحد وfallback لنموذج غير مذكور.
- [x] تحديث Graphify وتدقيق الروابط والمصطلحات وحالة الخطة الأم وسجل الأدلة.
- [x] نقل المهمة إلى `in_review` فقط بعد إغلاق G0–G5 بالأدلة.

### G5 Exit / Definition of Done

- [x] كل معايير 53g في الخطة الأم مغلقة بدليل.
- [x] سند لا يقدم estimate على أنه provider-confirmed usage ولا يعيد إنتاج الفوارق غير المفسرة المرصودة.
- [x] حدث الضغط يحتفظ بموضعه السببي الصحيح في live timeline وبعد استرجاع التاريخ.
- [x] YAML هي المصدر canonical للسياسة، و`.env` لا يحتوي `CONTEXT_LIMIT`، والسياسة العامة 80%/10% مع overrides اختيارية لكل نموذج.
- [x] حالة Goal مستقبلية يمكن حقنها خارج transcript بعد compaction؛ لا تنفذ هذه المهمة `/goal` ولا تلخص canonical goal state داخل summary باعتبارها مالكه الوحيد.

## 9. الملفات المتوقعة

- measurement وprovider usage normalization تحت `agent/lib/engine/`
- compaction pressure/tail policy تحت `agent/lib/engine/context/`
- lifecycle persistence/query ordering تحت الوحدات المالكة في `agent/lib/evolution/` و`agent/lib/interfaces/`
- config types/loader تحت `agent/lib/core/`
- model metadata/context-window resolution في provider adapters المالكة
- client timeline mapping/rendering إذا أثبت G0 أن الخطأ يقع فيها
- agent/client tests المركزة وdaemon-backed fixture
- `docs/agent_engine/context_compaction_design.md`
- وثائق التشغيل وQA وMOC المالكة
- ملف المهمة والخطة الأم

أُلغي سقف 15 ملفًا لهذه المهمة بتفويض مباشر من المستخدم في 2026-08-31. يظل نطاق 53g نفسه هو القيد الحاكم، ولا يبرر هذا الإعفاء تغييرات خارج القياس والترتيب وسياسة الضغط ووثائقها واختباراتها المالكة.

## 10. خارج النطاق

- ترحيل شامل لكل إعدادات `.env` إلى YAML.
- نقل secrets من SecretStore/Keychain.
- hot reload أو UI لتحرير الإعدادات.
- provider-native compaction أو نسب تكيفية تلقائيًا.
- benchmarking لعدة نسب أو تغيير defaults دون قرار جديد.
- wildcards أو aliases أو substring matching لأسماء النماذج.
- تنفيذ `/goal`؛ المطلوب فقط عدم إغلاق مسار دمجها لاحقًا.

## 11. سجل التقدم

```text
Date: 2026-08-31 (live auto-compaction regression remediation)
Gate/status: G1 remediation verified; G5 awaits user-controlled live continuation; PR merge paused pending confirmation
Observed: session e3d620d1-5d59-46e0-9f71-656516c11ff2 attempted Auto compaction three times at revisions 573/577/581 and failed each activation as persistenceFailed; provider usage was 260537/400000 (65%) before the first attempt
Root causes: durable ranges incorrectly required every integer between global AUTOINCREMENT endpoints; a full Codex JSON chars/4 estimate (~316924) replaced valid provider usage and crossed the 315904 threshold; failed Auto attempts had no active-run breaker and the completion cooldown branch was unreachable
Remediation: session-ordered endpoint ranges accept numeric gaps; adapter-owned wire fingerprints preserve provider-confirmed usage and estimate only a strict appended suffix; daemon restart rebuilds the exact historical wire prefix behind the latest route-matching persisted assistant usage before restoring that baseline; one failed Auto attempt opens a per-run breaker while manual/new-run attempts remain eligible; activation failure detail records the terminal repository outcome
Evidence: agent analyzer clean; focused engine/adapter/evolution tests include 260537 confirmed + 1200 suffix => 261737 below threshold, restart restoration of an 83200 baseline + 500 suffix plus stale-route rejection, gapped ids [1,5,6,7], one failed Auto lifecycle across two preflight calls, and persisted activation_outcome diagnostics; full agent suite 1374 passed / 12 skipped; isolated daemon E2E 3/3; wiki lint succeeds with zero violations; Graphify 21698 nodes / 29481 edges
Safety: the affected conversation was inspected read-only, remained idle, and was never resumed or used for verification; the worktree daemon restarted healthy on port 58139 with the corrected source
Next: restart the worktree daemon with the restoration fix, then obtain user-controlled natural continuation evidence; no manual compact and no merge until the live Auto path is confirmed
```

```text
Date: 2026-08-31 (live continuation follow-up)
Gate/status: G1 remediation reopened; merge remains paused
Observed: natural continuation correctly skipped Auto before the first provider request (provider confirmed 263069), but the next preflight fell back to a 321741 full estimate and completed Auto early
Root cause: the volatile system prompt read provider identity from response metrics; it changed from configured `openai` before the first request to response label `openai-codex` afterward, invalidating the otherwise strict wire prefix
Remediation: system prompt provider identity now comes from the resolved route template and remains stable across response-metrics updates; focused regression asserts byte-identical system content before and after a different metrics provider label
Safety: the single early compaction completed successfully and subsequent provider-confirmed requests are approximately 43–44K; no retry loop or activation failure occurred
Next: load the stable-prefix fix after the affected turn reaches a safe boundary, then perform a bounded live continuation check; do not merge before confirmation
```

```text
Date: 2026-08-31 (post-compaction continuation crash)
Gate/status: G1/G2 remediation reopened; affected session is blocked and must not be retried before restart with the fix
Observed: after several successful post-compaction tool loops, projection threw `newest completed boundary references conflicting message row ids`; daemon stayed healthy but the turn terminated blocked
Root cause: Stop/resume recovery legitimately rewrote the retained-tail suffix, preserving tail start 29464162 but replacing obsolete tail end 29464270 with higher row ids; validity treated the missing old end as corruption
Remediation: retained-tail start is the durable split anchor; when it survives and the old end is replaced, projection emits summary plus every current row from the start onward. Summarized-source partial rewrites and missing tail start still fail closed
Next: focused/full verification, restart Agent at the blocked safe boundary, then user-controlled Retry/continuation validation; merge remains paused
Evidence: agent analyzer clean; full fast suite 1377 passed / 12 skipped; focused projection/pressure suite includes stable provider prefix and retained-tail end rewrite coverage
```

```text
Date: 2026-08-31 (delivery follow-up)
Gate/status: G5 remains complete / in_review
UI: desktop double-click on the conversation title opens the same capability-gated Rename Session dialog as the row menu; focused sidebar suite 21/21, client analyzer, and live driver verification pass
Docs: added missing frontmatter to the Plan 50 regression matrix and both Linux service lifecycle pages, added the missing tracked docs/llms.txt entry without disturbing curated recent entries, and docs wiki lint now succeeds with zero errors; generated docs/llms-full.txt remains untracked by contract
Regression closeout: isolated AgentRunner tests intentionally omit AgentRuntimeService, so compaction preflight/overflow now fail closed in that harness; full agent suite 1365 passed / 12 skipped and full client suite 1150 passed / 1 skipped
CI repair: seven Linux-only failures shared one root cause—new compaction tests relied on leaked Sanad Home preparation. Each owning test now prepares and cleans a temporary home explicitly; focused repair bundle 7/7 and analyzer pass
Context indicator polish: removed the redundant `Measurement: Provider confirmed` line from the compact context-window tooltip and semantics; provider provenance remains available on the compaction event where it explains reconciliation
```

```text
Date: 2026-08-31 (user-facing metric polish)
Gate/status: G5 remains complete / in_review
Decision: keep the 58506 pre-confirmation estimate only in persistence for diagnostics; once 40829 is confirmed, omit the superseded estimate from the card and recompute displayed reclaimed usage as 358886 - 40829 = 318057 (88.6%), retaining Estimated provenance because before-usage is estimated
UI cleanup: remove redundant Type: Auto while retaining Trigger: Auto, since Trigger also carries the distinct overflow-recovery case
Evidence: focused widget suite 8/8 and client analyzer clean; hot-restarted live card shows Trigger once, Provider confirmed after 40829, Estimated reclaimed 318057, and no 58506/Pre-confirmation/Type line
```

```text
Date: 2026-08-31 (live-provider reconciliation verified)
Gate/status: G0–G5 complete; task moved to in_review
Evidence: preserved fork 5e08cade-62ca-4854-b22f-e38d1eaeab87 auto-compacted once; estimate before 358886, retained tail 38979, pre-confirmation after estimate 58506, and the first provider response confirmed 40829 input tokens
Reconciliation: operation 38ff04e5-5a14-4898-9d7a-41ccec9c2d55 stored the first confirmed value and republished the same completed event id; later responses cannot overwrite it; reload hydrated one event in the same causal position
UI: the separator spans the conversation width symmetrically; details label 40829 as Provider confirmed after and suppress the superseded 58506 estimate while persistence retains it for diagnostics
Verification: agent/client analyzers clean; focused agent 72 passed; focused client 18 passed; daemon E2E 3/3; full client 1149 passed / 1 skipped; full agent 1364 passed / 12 skipped / 1 pre-existing unrelated DelegateTaskTool DI failure reproduced alone; Graphify 21674 nodes / 29429 edges
Preservation: the original session and both test forks remain intact as explicitly requested; no commit or push was made
```

```text
Date: 2026-08-31 (live-provider gap reopened)
Gate/status: G1 reconciliation and G5 live parity reopened
Evidence: a forked 226-message session auto-compacted at an estimated 360404 tokens; the first post-compaction provider response reported 40830 tokens and the completed card remained at its immutable 58506 estimate
Root cause: the completed operation has no provider-confirmed after field or reconciliation mutation/broadcast; the card can therefore never advance from Estimated to Provider confirmed
Additional UI defect: the center label uses loose Flexible(flex: 8), leaving unallocated row width and visually shortening the divider on one side
Next: persist and broadcast first-response reconciliation, render both provenances without conflation, fix the full-width row, and repeat live/reload verification
```

```text
Date: 2026-08-31 (file-budget waiver)
Gate/status: G5 remains in progress
Decision: the user explicitly waived the 15-file cap for 53g; scope and gate exit criteria remain unchanged
Impact: no task split is required solely because the verified implementation touches more than 15 files
```

```text
Date: 2026-08-31 (53g implementation)
Gate/status: G0–G4 complete; G5 in progress
Implemented: codec-native Codex wire estimate, trusted provider baseline/suffix measurement, causal history proof, strict SANAD_HOME/config.yaml model policy, 80%/10% ratio trigger/tail, exact model overrides, legacy CONTEXT_LIMIT removal, safe YAML example, provider-confirmed UI label
Verification: agent/client analyzers clean; 108 focused agent tests and 8 focused client tests pass; daemon E2E 3/3; full agent fast suite 1362 passed, 12 skipped, one pre-existing unrelated DelegateTaskTool DI failure; Graphify updated to 21666 nodes / 29416 edges
Remaining: external live-provider before/after usage parity. Repository E2E policy forbids inheriting the user provider and requires the deterministic E2E provider, so the task remains G5/in_progress and is not moved to in_review.
```

```text
Date: 2026-08-31 (Plan 53a–53f independent remediation)
Gate/status: G0 remains pending; no YAML/model-policy gate started
Pre-landed evidence: provider input usage is now a route/material-bound baseline with suffix-only estimation and invalidation tests; compaction history now anchors at retained_tail_range.end; transition event ids are deterministic across live/history; daemon E2E proves live/restart causal order and one completed lifecycle when a later attempt fails.
Still required in 53g: the 463K/359K numeric reproduction, adapter-native wire estimation when trusted usage is absent, post-compaction provider-confirmed provenance/UI labeling, broader manual/auto/overflow + pagination G2 matrix, and every G3–G5 YAML/ratio/model-limit gate.
```

```text
Date: 2026-08-31
Gate/status: G0 pending
Decision: fix measurement and timeline ordering before policy; separate context.modelLimits from compaction.models; ratio-only 0.80/0.10 policy; remove CONTEXT_LIMIT and thresholdTokens; bounded suffix compaction with no transcript gaps
Evidence: 53-compaction-policy-reference @ sha256:9e0846fec0f8ea1115addd4e34e1af2bbb5bf2b905486e8cd67610b12e5ae6da
Next: reproduce and quantify provider-usage drift and history-ordering regression before production edits
```
