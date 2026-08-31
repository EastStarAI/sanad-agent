---
title: "Plan 53: Durable Goal-Preserving Context Compaction and Command UX"
description: "خطة مظلة لاستبدال نموذج الضغط التجريبي بضغط سياق ذري يحفظ الهدف والتاريخ، مع auto-compaction وأمر /compact حقيقي وتجربة timeline قابلة للاستعادة."
status: "in_review"
priority: "critical"
---

# Plan 53: ضغط السياق الدائم والمحافظ على هدف المحادثة

> Live regression repair (2026-08-30): a Codex Responses request exposed a
> retained-tail split inside a parallel tool batch and reuse of `compaction_id`
> as the transport `event_id`. The selector now retains the owning assistant
> batch, projection hydration rejects already-persisted unsafe boundaries, and
> lifecycle transitions use distinct transport ids while retaining one logical
> compaction identity. Focused regression coverage is recorded in Task 53f and
> `docs/qa_maintenance/context_compaction_qa.md`.

## 1. الحالة والهدف

- الحالة: `in_review` — مهام 53a–53g مغلقة بدليل؛ اكتمل القياس المتصالح مع المزود وترتيب history وسياسة model-aware وإعدادات YAML، وتبقى المراجعة البشرية النهائية فقط.
- الأولوية: حرجة؛ أي تلخيص ناقص قد يجعل الوكيل ينسى الهدف أو يعيد آثار أدوات أو يتابع من حالة قديمة.
- النطاق: Sanad Agent engine، session persistence، run orchestration، provider failure recovery، canonical protocol، slash-command discovery، Flutter composer، conversation timeline، والاختبارات التكاملية.
- أسلوب التنفيذ: خطة مظلة تنجز عبر المهام `53a` إلى `53g` في `docs/plans/tasks/`.
- قيد الحجم: تستهدف كل مهمة فرعية 8–15 ملفًا. أي تجاوز يتطلب إعادة تقسيم المهمة وتحديث هذه الخطة قبل التنفيذ.

الهدف هو استبدال `ContextEngine` التجريبي بعملية compaction من الدرجة الأولى:

```text
request pressure detected أو /compact accepted
  -> claim one session compaction boundary
  -> freeze the eligible history snapshot
  -> preserve deterministic continuity anchors
  -> prune old heavy tool/media payloads in the model projection only
  -> summarize the old head and retain a recent verbatim tail
  -> validate goal/state/remaining-work coverage
  -> atomically activate the successful boundary
  -> rebuild the next model request from persisted state
  -> drain queued user messages in FIFO order
```

لا تحذف العملية التاريخ الأصلي ولا تغير `session_id`. ما يتغير هو projection السياق المرسل إلى النموذج، بينما تبقى timeline الكاملة للمستخدم قابلة للعرض والاستعادة والتدقيق.

## 1.1 قرارات المستخدم المثبتة

1. يزال المسار القديم `ContextEngine` لأنه كان للاختبار فقط، ولا يجب الحفاظ على توافق داخلي معه.
2. تزال slash commands الوهمية المعلنة حاليًا ضمن قدرات الجهاز.
3. `/compact` هو أول slash command حقيقي، ولا يقبل arguments في الإصدار الأول.
4. slash command صالحة فقط عندما تكون أول token في composer؛ Enter ينفذها كأمر runtime ولا يرسلها كرسالة مستخدم.
5. skills تظل tokens مستقلة يمكن إدراجها في أي موضع داخل رسالة المستخدم. يجب ألا يخلط parser أو UI بينها وبين slash commands. يمتد العقد مستقبلًا إلى file mentions دون تغيير semantics الخاصة بالأوامر.
6. manual `/compact` لا يبدأ أثناء run نشطة. يعاد typed busy outcome وتبقى المسودة قابلة للتعديل.
7. أثناء compaction جارية، تقبل رسائل المستخدم العادية كعمل queued دائم، ثم تدخل التنفيذ فور انتهاء compaction وبترتيب FIFO.
8. timeline تعرض حدثًا centered أفقيًا يميز manual عن auto compaction، مع circular indicator أثناء التنفيذ وsuccess check عند النجاح وحالة فشل terminal واضحة.
9. hover على desktop أو click/tap على mobile يفتح تفاصيل متعددة الأسطر بنفس سلوك تفاصيل `context_usage_indicator.dart`، دون إظهار نص summary الداخلي.

## 1.2 قاعدة إدارة التقدم

- الحالات المسموحة: `pending`, `in_progress`, `blocked`, `in_review`, `complete`.
- تعمل كل مهمة على Gate واحدة فقط في الوقت نفسه.
- لا تبدأ Gate لاحقة حتى تغلق Exit criteria للبوابة السابقة ويسجل دليل التحقق.
- لا تبدأ 53d قبل ثبات عقدي 53b و53c؛ ولا تبدأ 53e قبل ثبات canonical command/event contract في 53d.
- أي تغيير في schema أو event vocabulary أو summary contract يحدث في الخطة الأم والمهام المتأثرة معًا.
- كل مهمة تنفيذية تحدث أقرب `AGENTS.md` ووثائق technical/product/QA المالكة للسلوك في الجلسة نفسها.
- لا توصف الخطة `complete` قبل نجاح 53f، ثم إغلاق 53g وإثبات سياسة الإعدادات الجديدة وإزالة `CONTEXT_LIMIT` العام.

## 1.3 لوحة التقدم

| المهمة | الحالة | Gate الحالية | سقف الملفات | شرط الانتقال |
|---|---|---|---:|---|
| 53a Prototype Retirement and Contracts | `complete` | — | 24 | 53b + 53c may start |
| 53b Durable Boundary and Projection | `complete` | — | 14 | B4 complete |
| 53c Goal-Preserving Engine | `complete` | — | 14 | C5 verified |
| 53d Auto Orchestration and Overflow Recovery | `complete` | — | 15 | D2/D7 + daemon E2E |
| 53e `/compact` and Timeline UX | `complete` | — | 15 | E2 lifecycle dedup |
| 53f Integration QA | `complete` | — | 12 | F5 verified |
| 53g Accurate Measurement, Timeline Order, and Model-Aware Policy | `in_review` | G5 complete | waived | Human review |

## 2. الوقائع المثبتة في Sanad الحالية

1. `ContextEngine` يقدر tokens بأربعة أحرف لكل token ويحسب message content وبعض tool arguments فقط.
2. الضغط يبدأ بعد تجاوز context limit كاملة دون output reservation أو safety buffer.
3. المحرك singleton مربوط بالـfallback adapter ولا يضمن exact per-turn provider/model route.
4. يحتفظ بآخر عشر رسائل حسب العدد، ويمكن أن يترك tail أكبر من النافذة أو يفصل tool call عن نتيجتها.
5. summary تحفظ كرسالة system إضافية، ما يناقض عقد system message الواحدة ويسمح بتراكم summaries عند الضغط المتكرر.
6. حفظ history اللاحق يستبدل صفوف messages القديمة بدل إنشاء boundary قابلة للتدقيق.
7. checkpoint يحفظ قبل الضغط بينما تغير العملية طول history دون تحديث turn indices أو resume length.
8. context overflow مصنف حاليًا كـfatal ولا يتحول إلى compaction recovery.
9. slash-command discovery يخلط أوامر ثابتة غير منفذة مع skills، والـclient يعامل الاختيارات كإدراج نصي لا dispatch لأمر typed.
10. الاختبارات الحالية لا تغطي persistence أو tool pairing أو repeated compaction أو restart أو provider overflow.

## 3. الاستفادة الملزمة من المشاريع المرجعية

### 3.1 ما يؤخذ من Hermes

- قياس ضغط request كاملة، بما فيها system prompt وtool schemas وmedia والحقول المخفية، مع provider usage الفعلية عندما تتوفر.
- احتساب effective input window بعد حجز output budget وsafety headroom.
- deterministic pruning لمخرجات الأدوات القديمة قبل semantic summarization، دون حذف الأصل المخزن.
- حماية recent tail بميزانية tokens مع حدود user/assistant/tool سليمة، لا بعدد رسائل ثابت.
- structured rolling summary تحافظ على goal، constraints، completed work، active state، decisions، blockers، files، pending asks، وremaining work.
- continuity anchors وprogress checks وcooldown وanti-thrashing وحد أقصى لمحاولات recovery.
- per-session exclusive compaction claim، وفصل قرار الضغط عن التلخيص عن mutation/persistence.
- اعتبار نجاح الضغط مثبتًا فقط عندما تصبح request التالية تحت الحد، لا عندما ينخفض عدد الرسائل.

### 3.2 ما يؤخذ من OpenCode V2

- durable compaction boundary لا تصبح authoritative إلا بعد summary ناجحة كاملة.
- إبقاء canonical history الأصلية وبناء model projection من أحدث boundary ناجحة.
- event lifecycle صريح: started ثم completed أو failed، مع manual/auto/overflow reason.
- قياس prospective request قبل الإرسال، لا الاعتماد على usage السابقة وحدها.
- reactive overflow recovery مرة واحدة فقط عندما لم يبدأ durable assistant output.
- إعادة بناء request من التخزين بعد activation بدل متابعة list متحولة في الذاكرة.
- manual وauto يستخدمان pipeline واحدة، مع اختلاف trigger والسياسة فقط.

### 3.3 ما لا ينقل

- لا ينقل session rotation من Hermes؛ هوية جلسة Sanad ثابتة.
- لا تنقل synthetic user continuation من OpenCode؛ continuation وqueue تظلان orchestration state لا transcript user text.
- لا يعتمد على rough estimate السابقة وحدها كما في OpenCode V1.
- لا يسمح deterministic fallback ضعيف بتفعيل boundary إذا فشل في continuity validation.
- لا تحفظ summary كرسالة system ثانية، ولا تخلط internal compaction metadata مع provider wire payload.
- لا يحذف أو يستبدل canonical messages القديمة كما يفعل نموذج Sanad التجريبي.

### 3.4 مرجع التنفيذ داخل المشاريع المفتوحة المصدر

الملفات التالية هي baseline البحثية التي تقارن بها Gates التصميم والتنفيذ والاختبارات، مع إعادة التحقق من المصدر عند بدء المهمة لأن المشاريع المرجعية قد تتغير:

**Hermes — جودة الضغط والحفاظ على الاستمرارية**

- `refrence_projects/hermes-agent/agent/context_engine.py`: عقد القياسات والقرار ودورة حياة الضغط.
- `refrence_projects/hermes-agent/agent/context_compressor.py`: pressure thresholds، tool pruning، head/tail selection، rolling structured summary، continuity/fallback behavior، وanti-thrashing.
- `refrence_projects/hermes-agent/agent/model_metadata.py`: full-request estimation وprovider/model context-window resolution.
- `refrence_projects/hermes-agent/agent/conversation_compression.py`: boundary orchestration، failure handling، وsession locking؛ يستفاد من orchestration دون نقل session rotation.
- `refrence_projects/hermes-agent/agent/hermes_state.py`: in-place archive/compaction transactions والlocks الدائمة.
- `refrence_projects/hermes-agent/tests/agent/test_context_compressor.py` و`test_compaction_anti_thrash.py`: invariants الخاصة بالهدف، الأدوات، repeated compaction، والفشل.

**OpenCode — boundary الدائمة وrequest recovery**

- `refrence_projects/opencode/packages/core/src/session/compaction.ts`: V2 prospective request budgeting، summary candidate، وStarted/Ended event lifecycle.
- `refrence_projects/opencode/packages/core/src/session/history.ts`: بناء history من أحدث compaction event ناجحة.
- `refrence_projects/opencode/packages/core/src/session/message-updater.ts`: عدم تفعيل Started event دون terminal completion.
- `refrence_projects/opencode/packages/core/src/session/runner/llm.ts`: overflow recovery الواحدة وعدم replay بعد partial provider output.
- `refrence_projects/opencode/packages/opencode/src/session/compaction.ts`: retained tail، anchored repeated summaries، tool/media truncation، وmanual/auto metadata في V1 الناضجة.
- `refrence_projects/opencode/packages/opencode/src/session/message-v2.ts`: failure-safe filtering الذي يبقي التاريخ كاملًا إذا لم تكتمل summary.
- `refrence_projects/opencode/packages/opencode/test/session/compaction.test.ts` و`packages/core/test/session-runner.test.ts`: interruption، repeated compaction، tail، overflow، وtool safety.

### 3.5 قرار سياسة 53g المثبت

- دليل المقارنة المثبت: `evidence_id: 53-compaction-policy-reference`، بالبصمة `sha256:9e0846fec0f8ea1115addd4e34e1af2bbb5bf2b905486e8cd67610b12e5ae6da`.
- يفصل `context.modelLimits` نافذة النموذج عن `compaction.models` التي ترث أو تتجاوز نسب trigger وretained tail؛ لا يملك أي منهما إعدادات الآخر.
- تصبح provider-reported input usage مرجع القياس عند توفرها، ويقدّر النظام فقط الذيل الذي لم تشمله آخر snapshot موثوقة على route/model نفسها؛ لا يعرض التقدير كرقم مؤكد.
- نسبة التشغيل العامة `0.80` وretained-history target العامة `0.10` قرارا منتج مثبتان لهذه المرحلة، مع overrides exact لكل نموذج.
- يحذف `thresholdTokens` و`modelThresholds` من العقد الجديد؛ السياسة العامة نسبية، وoverrides المجموعة تحت `compaction.models`.
- اختيار الذيل suffix متصل من الأحدث إلى الخلف دون فجوات، مع إبقاء tool call/result groups ذرية وإدخال prefix الأقدم في summary عندما يقع الحد داخل turn.
- حدث compaction يملك ترتيبًا سببيًا ثابتًا: بعد السبب وقبل model output الذي استخدم الإسقاط المضغوط، بنفس الموضع في live stream وبعد history hydration.
- يؤجل اختبار نسب متعددة، والضغط الخاص بالمزود، وأي tuning تكيفي إلى مرحلة لاحقة.

## 4. قرارات التصميم الحاكمة

### 4.1 ثلاثة مصادر منفصلة للحقيقة

```text
Canonical conversation history
  كامل وغير هدّام، ويغذي timeline والتدقيق والاستعادة

Compaction boundaries
  lifecycle + summary + source range + retained-tail range + metrics

Active model projection
  current system/runtime context + latest successful summary + verbatim tail + later messages
```

- timeline لا تستخدم active model projection كبديل للتاريخ الكامل.
- summary داخلية ولا تظهر كنص للمستخدم ولا كرسالة system تاريخية.
- أحدث boundary ناجحة فقط هي التي تقطع model projection. started أو failed لا يغيران السياق النشط.

### 4.2 ذرية وملكية العملية

- لكل compaction هوية مستقلة مرتبطة بـ`session_id` وبسبب `manual|auto|overflow` وبـsnapshot revision ثابتة.
- لا تعمل عمليتا compaction للجلسة نفسها بالتوازي.
- activation تقارن snapshot/history revision قبل commit؛ ظهور boundary أحدث أو تغير غير مؤهل يؤدي إلى stale outcome بلا mutation.
- الرسائل المقبولة أثناء compaction لا تدخل snapshot الجاري تلخيصه. تحفظ في queue ثم تصرف بعد terminal compaction outcome.
- persistence failure لا يسمح بإرسال request مبنية على summary غير محفوظة.

### 4.3 معيار الحفاظ على الهدف

قبل التلخيص تستخرج continuity anchors typed من الجزء الجاري ضغطه ومن state الحالية، وتشمل على الأقل:

- هدف المستخدم الحالي وsuccess criteria.
- القيود والتفضيلات والقرارات التي ما زالت سارية.
- ما اكتمل وما نتج عنه، بما فيه side effects المهمة.
- الحالة الجارية الدقيقة وما لم يكتمل بعد.
- آخر pending user asks والأسئلة المفتوحة.
- الملفات والمسارات والرموز والمعرفات والقيم الضرورية للاستمرار.
- نتائج الأدوات أو الأخطاء أو blockers التي تغير القرار التالي.
- الخطوة التالية المتوقعة إذا كانت مثبتة في السياق.

لا تفعل boundary إلا إذا احتوت summary على الأقسام المطلوبة ونجحت coverage validation للـanchors الحرجة. عند الفشل تعاد محاولة repair واحدة بمدخلات محدودة؛ وبعدها تبقى boundary السابقة والتاريخ الأصلي authoritative.

### 4.4 الضغط المتكرر

- previous summary تدخل كـhistorical anchor منفصلة، لا كرسالة محادثة عادية.
- summary الجديدة تدمج السابقة مع span الجديد وتزيل الحقائق التي أصبحت stale مع الاحتفاظ بالأهداف غير المنجزة.
- لا تتراكم summaries متعددة داخل model projection.
- retained tail تحفظ verbatim قدر الإمكان، ويمنع القطع داخل tool batch أو model step أو user turn المالكة له.

### 4.5 حدود الضغط التلقائي

- يبنى pressure snapshot من exact active route وrequest material النهائي المتوقع.
- provider-confirmed input usage إشارة تحقق قوية لكنها ليست المصدر الوحيد للقرار.
- threshold تحجز أكبر output budget مطلوب مع safety buffer مركزي قابل للاختبار.
- يعاد الفحص قبل كل model invocation داخل tool loop وبعد إضافة tool results.
- provider overflow لا يدخل network retry. إذا لم يبدأ provider output، يسمح بضغط ثم إعادة الطلب مرة واحدة. إذا بدأ reasoning أو content أو tool state، لا يعاد الطلب تلقائيًا.

### 4.6 `/compact` وcomposer grammar

- الأمر في الإصدار الأول هو exact `/compact` فقط بلا arguments أو trailing user text.
- runtime command query تعمل عند index صفر فقط. skills/file mentions تستخدم query/token pipeline منفصلة وتبقى صالحة في أي موضع.
- Enter مع exact slash token ينفذ command؛ Enter مع رسالة عادية يرسل message؛ ولا يوجد fallback يحول command غير صالحة إلى user message بصمت.
- manual compaction تقبل فقط عندما session idle ولا توجد compaction أخرى.
- أثناء compaction يبقى composer متاحًا للرسائل العادية، وتدخل الرسائل المقبولة queue الدائمة ثم تنفذ FIFO بعد terminal outcome.

### 4.7 timeline والتفاصيل

الأوصاف الإنجليزية المعتمدة:

```text
Context compacting
Auto context compacting
Context compacted
Auto context compacted
Context compaction failed
Auto context compaction failed
```

- الحدث centered أفقيًا بين divider lines خفيفة.
- in-progress يستخدم circular indicator، success يستخدم check mark، والفشل يستخدم error indicator terminal.
- التفاصيل لا تكشف summary. تتضمن عند توفرها: trigger، status، provider/model، context window، before/after request tokens، reclaimed tokens أو ratio، summarized range، retained-tail tokens، started/completed time، duration، ومحاولة recovery.
- live event وhistory hydration يعيدان نفس الهوية والحالة والتفاصيل.
- interaction يعيد استخدام سلوك hover/tap/focus متعدد الأسطر الخاص بمؤشر context usage، مع component مشترك عند ثبوت أن الاستخراج لا يخلط ownership.

## 5. نموذج الحالة المستهدف

```text
CompactionOperation
  identity: compactionId + sessionId + sourceRevision
  trigger: manual | auto | overflow
  state: started | completed | failed
  sourceRange + retainedTailRange
  route: providerInstanceId + modelId
  metrics: contextWindow + before + after + reclaimed + duration
  summary: internal/redacted/validated
  failure: typed/redacted

Session execution
  idle
    -> compacting
      -> idle + drain queued work
      -> blocked only when overflow leaves no safe request path
```

قواعد queue:

- `/compact` أثناء run عادية يعاد `session_busy` ولا يوضع في queue.
- `/compact` أثناء compaction يعاد `compaction_in_progress` idempotently.
- user message عادية أثناء compaction تقبل كqueued work مع request identity المعتادة.
- نجاح compaction يثبت projection أولًا ثم يدفع أقدم queued message.
- فشل manual compaction يعيد session إلى idle ويصرف queue على التاريخ الأصلي ما لم يوجد overflow authoritative يمنع request آمنة.
- فشل auto/overflow compaction لا يترك queue صامتة؛ ينتقل إلى outcome قابلة للتحكم أو يصرفها عندما ما زال original request صالحًا.

## 6. ترتيب التنفيذ

```text
                    53a Contracts + Prototype Retirement
                                   |
                     +-------------+-------------+
                     |                           |
                     v                           v
          53b Durable Boundary          53c Compaction Engine
                     |                           |
                     +-------------+-------------+
                                   |
                                   v
                 53d Auto Orchestration + Overflow Recovery
                                   |
                                   v
                    53e /compact + Timeline UX
                                   |
                                   v
                       53f Integration QA
                                   |
                                   v
             53g Accurate Measurement + Timeline Order + Policy
```

- 53b و53c يمكن تنفيذهما بالتوازي بعد اعتماد types وحدود الملكية في 53a.
- 53d هو أول موضع يوصل المحرك بالـAgentRunner والـSessionRunOrchestrator والـprovider failure path.
- 53e يستهلك command/event contract المثبت ولا يعيد تنفيذ compaction policy في Flutter.
- 53f لا يضيف سياسة جديدة؛ يعالج findings ويثبت النظام الحقيقي.
- 53g يبدأ بإصلاح measurement provenance وترتيب lifecycle في التاريخ، ثم يضيف طبقة الإعداد والسياسة المتفق عليها دون توسيعها إلى ترحيل شامل لإعدادات المشروع.

## 7. خطط المهام

1. [53a: Compaction Contracts and Prototype Retirement](tasks/53a-compaction-contracts-and-prototype-retirement.md)
2. [53b: Durable Compaction Boundary and Model Projection](tasks/53b-durable-compaction-boundary-and-model-projection.md)
3. [53c: Goal-Preserving Context Compaction Engine](tasks/53c-goal-preserving-context-compaction-engine.md)
4. [53d: Auto-Compaction Orchestration and Overflow Recovery](tasks/53d-auto-compaction-orchestration-and-overflow-recovery.md)
5. [53e: `/compact` Command and Compaction Timeline UX](tasks/53e-compact-command-and-compaction-timeline-ux.md)
6. [53f: Compaction Integration and Regression QA](tasks/53f-compaction-integration-and-regression-qa.md)
7. [53g: Accurate Context Measurement, Timeline Order, and Model-Aware Policy](tasks/53g-model-aware-compaction-policy-and-yaml-config.md)

## 8. التنسيق مع الخطط الحالية

- **Task 34:** قاعدة عدم recovery بعد partial provider output مشتركة، ولا تنشأ retry semantics منافسة.
- **Task 40:** latest provider input usage وexact context window يعاد استخدامهما كإشارة مؤكدة، دون استخدام accumulated usage أو جعل UI مصدر قرار الضغط.
- **Task 47:** pagination تعرض canonical history وأحداث compaction، ولا تقطع التاريخ عند model projection boundary.
- **Task 50:** إذا أصبح cancellation core متاحًا، تسجل summarizer request كمورد operation-scoped؛ لا تجعل Plan 53 Stop يعتمد على flag جديد خاص بها.
- **Task 51:** soft rewind أو supersession الأحدث يجب أن يبطل boundary مبنية على source revision قديمة أو يعيد تحديد projection بصورة ذرية.
- **Task 52:** fork يعيد ربط source/tail identities أو يبدأ دون inherited active boundary عندما لا يمكن mapping حتمي.

## 9. معايير القبول الكلية

- [x] أزيل `ContextEngine` التجريبي وكل استدعاء ووثيقة واختبار يصفه كميزة إنتاجية.
- [x] لا توجد slash commands وهمية في device capabilities أو composer suggestions.
- [x] `/compact` أول runtime slash command حقيقي، exact وبلا arguments، ولا يتحول إلى user message.
- [x] skills قابلة للإدراج في أي موضع ولا تتأثر بقيود slash command في بداية النص.
- [x] auto-compaction تسبق overflow بهامش output/safety وتعمل داخل tool loop.
- [x] summary تحافظ على goal، constraints، current state، decisions، files، blockers، pending asks، وremaining work عبر repeated compaction.
- [x] tool calls/results وmodel steps وuser turns لا تنفصل عند tail boundary.
- [x] التاريخ الأصلي لا يحذف، وأحدث boundary ناجحة فقط تغير model projection.
- [x] فشل أو إلغاء summarizer لا يفعل boundary ناقصة ولا يفقد الرسائل.
- [x] context overflow قبل أول provider output يسمح بضغط ثم retry واحدة؛ بعد partial output لا توجد إعادة شفافة.
- [x] compaction المتزامنة للجلسة نفسها تمنع ذريًا، ولا تتأثر Session B بعملية Session A.
- [x] رسالة تصل أثناء compaction تحفظ وتنفذ FIFO فور terminal outcome المناسب.
- [x] manual وauto events تظهر centered بحالات started/completed/failed وتستعاد بعد reload بالتفاصيل نفسها.
- [x] tooltip متعددة الأسطر تعمل بالhover وtap/focus ولا تكشف summary الداخلية.
- [x] تحليلات agent/client والاختبارات المركزة والكاملة وdaemon-backed E2E المطلوبة ناجحة.
- [x] يقرأ daemon إعدادات context/compaction غير السرية من `$SANAD_HOME/config.yaml` بالقيم الافتراضية المثبتة والتحقق الصارم.
- [x] يزال `CONTEXT_LIMIT` العام ولا تستطيع قيمة قديمة في `.env` فرض نافذة واحدة على كل النماذج.
- [x] يدعم `context.modelLimits` override صريحة لكل model، مع الرجوع إلى metadata الصحيحة الحالية عند غيابها.
- [x] يساوي provider-confirmed usage في سند القياس الذي أعاده المزود لنفس invocation، ويقتصر أي estimate على tail غير المقيسة ويظهر بهذه الصفة.
- [x] يحافظ حدث compaction على موضعه بين الرسالة المسببة وأول model output لاحق في live timeline وبعد reload/restart.
- [x] يبدأ الضغط افتراضيًا عند 80%، ويستهدف retained history بنسبة 10%، وترث `compaction.models` القيم العامة لكل مفتاح غائب دون `thresholdTokens`.
- [x] يقسم الضغط كل model-visible history دون فجوات إلى summary source وretained suffix متصل مع tool-pair safety.
- [x] تغلق 53g بالتحليل والاختبارات المركزة وتحديث وثائق التشغيل وGraphify والتحقق الحي المناسب.

## 10. مخاطر وحواجزها

- **نسيان الهدف:** structured continuity anchors + validation + عدم activation عند failure.
- **summary hallucination:** preserve verbatim identifiers، source-range metadata، anchor coverage، وrecent tail غير ملخصة.
- **ضغط متكرر يدهور المعرفة:** rolling summary واحدة، stale-fact reconciliation، واختبارات متعددة boundaries.
- **فصل tool history:** boundary selection على logical groups، مع sanitation قبل provider request.
- **request ما زالت كبيرة:** re-measure بعد compaction، bounded passes، وعدم اعتبار انخفاض message count نجاحًا.
- **تضخم القياس المحلي:** آخر provider-confirmed snapshot على route/model نفسها + تقدير wire-aware للذيل غير المقيسة فقط + provenance ظاهر.
- **race مع رسالة جديدة:** frozen source revision + durable queue + activation CAS.
- **تلوث timeline:** internal summary منفصلة عن user-visible event وعن system prompt.
- **انحراف ترتيب timeline بعد hydration:** causal ordering key ثابت ومختبر بين الرسائل وأحداث lifecycle، لا فرز widget أو timestamp وحده.
- **provider mismatch:** exact turn route يملك context limit وsummarizer invocation والmetrics.
- **تسريب أسرار:** redaction قبل summarization وبعدها، وعدم إرسال metadata الداخلية على wire.
- **UI optimistic drift:** daemon event lifecycle هو المصدر؛ client يعرض projection ولا يخمن completion.

## 11. خارج النطاق

- arguments أو focus topic أو preview/dry-run لأمر `/compact` في الإصدار الأول.
- file mentions نفسها؛ الخطة تثبت فقط grammar تسمح بإضافتها لاحقًا دون كسر skills أو slash commands.
- إظهار أو تحرير summary الداخلية للمستخدم.
- حذف التاريخ الأصلي لتقليل حجم قاعدة البيانات.
- تغيير long-term memory أو جعل compaction تكتب `MEMORY.md` تلقائيًا.
- provider-native compaction الخاصة بخدمة خارجية ما لم يثبت أن المزود يملك canonical context غير الموجود محليًا.
- semantic branching أو fork؛ التنسيق فقط مع Task 52.
- ترحيل جميع إعدادات `.env` غير المرتبطة بالـcontext/compaction إلى YAML أو إضافة واجهة إعدادات لها.
- benchmarking لنسب متعددة أو tuning ديناميكي حسب حجم نافذة النموذج في 53g.

## 12. سجل التقدم والتسليم

```text
Date: 2026-08-31 (delivery follow-up)
Task/Gate: 53g / G5 complete; in_review unchanged
Status: desktop session-title double-click now invokes the existing capability-gated rename dialog; sidebar tests and live driver verification pass. The three previously reported wiki-lint errors are fixed and docs lint succeeds.
Verification: full agent suite 1365 passed / 12 skipped; full client suite 1150 passed / 1 skipped. The isolated DelegateTaskTool test now preserves its no-AgentRuntimeService contract by skipping compaction setup in that harness.
```

```text
Date: 2026-08-31 (Task 53g final UI metric audit)
Task/Gate: 53g / G5 complete; in_review unchanged
Status: reconciled cards suppress the superseded after-estimate, recompute reclaimed usage against provider-confirmed after-usage, and expose one non-redundant Trigger field. Live verification after hot restart shows 40829 confirmed after and 318057 estimated reclaimed, with no 58506 or duplicate Type line.
```

```text
Date: 2026-08-31 (Task 53g live-provider closeout)
Task/Gate: 53g / G5 complete; plan moved to in_review
Status: the first post-compaction provider response reconciles the completed event without changing its causal identity or boundary; live and reload UI show one full-width event, replace the provisional estimate with the confirmed value, and retain the estimate only in persistence for diagnostics.
Evidence: preserved fork 5e08cade-62ca-4854-b22f-e38d1eaeab87; compaction 38ff04e5-5a14-4898-9d7a-41ccec9c2d55; estimated before 358886; retained tail 38979; pre-confirmation estimate 58506; provider-confirmed after 40829.
Verification: agent/client analyzers clean; focused agent 72 passed; focused client 18 passed; daemon E2E 3/3; full client 1149 passed / 1 skipped; full agent 1364 passed / 12 skipped / 1 pre-existing unrelated DelegateTaskTool DI failure reproduced alone; Graphify 21674 nodes / 29429 edges.
```

```text
Date: 2026-08-31 (Task 53g implementation)
Task/Gate: 53g / G5 in progress
Status: G0–G4 complete; G5 code, docs, deterministic daemon E2E, analyzer, focused suites, and Graphify complete. External live-provider before/after parity remains.
Implementation: Codex wire-native estimate, trusted provider baseline plus suffix-only delta, strict model-aware SANAD_HOME/config.yaml, 80% trigger and 10% retained suffix, CONTEXT_LIMIT removal, exact overrides, provider-confirmed UI provenance.
Verification: agent/client analyzers clean; focused agent 108/108; focused client 8/8; daemon E2E 3/3; full agent 1362 passed / 12 skipped / 1 pre-existing unrelated DelegateTaskTool DI failure; Graphify updated to 21666 nodes / 29416 edges.
```

```text
Date: 2026-08-31 (independent remediation review)
Task/Gate: 53a→53f re-audited and closed in strict order
Status: Plan remains in_progress because 53g YAML/model-policy gates were explicitly excluded
Repairs: route/material-bound provider usage baseline; stable message row identities and safe tool groups; early durable compaction barrier; deterministic lifecycle transition identity; retained-tail causal history ordering; immutable terminal client state; responsive/accessibile timeline details.
Verification: agent analyzer clean; client analyzer clean; D0–D7 runtime bundle 143/143; client Plan 53 bundle 42/42; daemon E2E 3/3; full client 1147 passed / 1 skipped; full agent 1357 passed / 12 skipped / 1 unrelated DelegateTaskTool DI failure; Graphify 21624 nodes / 29364 edges.
53g carryover: no YAML/model policy implemented; adapter-native estimated wire measurement, post-compaction provider-confirmed provenance, and the remaining G2 pagination/overflow matrix stay pending.
```

```text
Date: 2026-08-31
Task/Gate: 53g planned / G0 pending
Status transition: in_review → in_progress
Decision: repair provider-usage measurement and hydrated event ordering first; YAML policy at $SANAD_HOME/config.yaml; separate context.modelLimits and compaction.models; remove CONTEXT_LIMIT and thresholdTokens; default trigger/target 0.80/0.10
Evidence: 53-compaction-policy-reference @ sha256:9e0846fec0f8ea1115addd4e34e1af2bbb5bf2b905486e8cd67610b12e5ae6da
Next: reproduce and quantify measurement drift and timeline-order regression in 53g G0, then proceed gate-by-gate through G5
```

```text
Date: 2026-08-31
Task/Gate: 53f live post-compaction regression
Status: repaired pending live follow-up verification
Finding: ordinary history persistence regenerated all messages.id values and preflight measured canonical rather than projected history, causing auto-compaction on every later message
Fix: stable unchanged-prefix IDs + projected preflight pressure + incremental repeated source range
Verification: 56 focused regressions pass; analyzer clean; affected live boundary repaired with all 516 referenced rows present; controlled runtime restart healthy
```

```text
Date: 2026-08-29
Task/Gate: 53a complete
Status transition: in_progress → complete; 53b/53c unblocked
Owner/worktree: feat/plan-53-context-compaction @ .agent/worktrees/53-context-compaction
Files changed: 24 (see 53a task file budget table)
Completed: prototype retirement, compaction domain types, technical design doc, contracts
Verification evidence: fvm dart analyze clean; 94 focused tests passed; no ContextEngine in agent/
Documentation updated: context_compaction.md, MOC.md, llms.txt, engine/plugins AGENTS.md, agent_runtime.md, provider_protocol.md
Open findings/blockers: none
Next gate/owner: 53b B0 + 53c C0 (parallel)
```
