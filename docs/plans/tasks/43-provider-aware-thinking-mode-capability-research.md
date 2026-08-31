---
title: "Provider-Aware Thinking Mode Capability"
description: "خطة مبنية على أدلة تنفيذية لتوفير تحكم ديناميكي في التفكير بحسب provider instance والنموذج والبروتوكول، مع منع التجاهل الصامت والتحقق من payload النهائي."
status: "review complete"
scope: "agent llm adapters, provider runtime, canonical protocol, client composer"
evidence_id: "43"
evidence_fingerprint: "sha256:ee2edb165e9df40967f05dfd8b7997c80524d31a44fb38a0441a4c7a5a5f44e5"
---

# Task 43: Provider-Aware Thinking Mode Capability

## 1. حالة المهمة

اكتملت مرحلة البحث المقارن على ثلاثة مشاريع مرجعية عاملة ومثبتة revisions،
وتحوّلت نتائجها إلى قرار معماري وخطة تنفيذية. لم يُستخدم بحث الويب أو توثيق
المزودين الخارجي في تأسيس هذه الخطة بناءً على قرار المنتج؛ لذلك لا يُعلن دعم
أي mapping لا يثبته evidence packet واختبار Sanad خاص بالـrequest body.

الخطة معتمدة للتنفيذ والمراجعة البوابية في الورك تري
`.agent/worktrees/43-provider-aware-thinking-mode`. حزمة الأدلة `43` أُعيد
تحديثها في 2026-08-29 والـresolver يعيد `ready`.

## 2. خلاصة البحث

### 2.1 النتائج المشتركة

1. التحكم في التفكير ليس capability عامة للمزود ولا للبروتوكول؛ بل هو نتيجة
   تركيب:

   ```text
   provider instance
   + effective protocol/adapter policy
   + normalized model
   + model metadata or live capability evidence
   ```

2. قدرة النموذج على إنتاج reasoning لا تثبت وجود تحكم في مستواه. لذلك لا يصلح
   `supports_reasoning: true` وحده لإظهار selector.
3. لا يوجد wire shape موحد حتى بين endpoints المتوافقة مع OpenAI. الأنماط
   التنفيذية المثبتة تشمل:
   - top-level effort؛
   - nested reasoning object؛
   - thinking toggle؛
   - token budget؛
   - thinking level؛
   - adaptive mode؛
   - model variant؛
   - أو ترك الحقل غائبًا لاستخدام provider default.
4. `off` الصريح ليس مرادفًا لغياب القيمة. بعض المسارات تفعل التفكير افتراضيًا
   ولا توقفه إلا قيمة native صريحة، بينما مسارات أخرى ترفض payload التعطيل
   ويجب أن يُترك قرارها الافتراضي دون حقل.
5. الخيار الصريح غير المدعوم يجب أن يُرفض قبل HTTP request، أو يُصحح وفق
   policy معلنة ومحددة للنموذج. التجاهل الصامت غير مقبول.
6. الخيارات الصالحة يجب أن تُحسب لكل model وتصل إلى الواجهة مع model snapshot،
   لا أن تُعلن كقائمة ثابتة في device capabilities.
7. تطابق sync وstream يتحقق باستخدام request builder/policy مشتركة، ثم مقارنة
   payload النهائي بعد استبعاد مفاتيح streaming فقط.
8. القيمة الغائبة تعني provider/model default، ولا تعني `balanced` ضمنيًا.
9. عند تبديل provider/model أو استعادة session يجب إعادة التحقق من الاختيار
   المخزن؛ ولا يجوز إبقاء قيمة غير صالحة ثم إسقاطها داخل adapter.
10. مصادر capability قد تكون metadata ثابتة أو provider policy أو probe حيًا.
    فشل probe المؤقت يجب أن ينتج `unknown`، لا `unsupported` دائمًا.

### 2.2 مقارنة الأنماط المرجعية

| النمط المرجعي | vocabulary | مالك capability | مالك translation | سلوك القيمة غير الصالحة | الاستفادة في Sanad |
|---|---|---|---|---|---|
| Model variants | IDs خاصة بكل model مثل effort أو adaptive/max | variants مولدة ومندمجة مع model catalog | protocol lowerer | explicit unavailable variant يسبب typed resolution error | اعتماد descriptor ديناميكي لكل model |
| Canonical level + provider hooks | enum موحد مع aliases | provider runtime hooks + model checks | wrappers تعدّل final payload | رفض القيمة أو downgrade واضح وفق model policy | اعتماد validation مركزي وprovider hooks |
| Canonical enabled/effort + profiles | حالة تشغيل وقيمة effort | per-model config + profile + live probes | provider profile يقسم top-level عن nested body | omission للـdefault، warning للقيمة الغريبة، gating للنموذج | اعتماد policy profile وترجمة native typed |

تفاصيل أسماء المشاريع ومساراتها ورموزها واختباراتها محفوظة في evidence packet
المحلي المرتبط بـ`evidence_id`، وليست جزءًا من عقد Sanad المتتبع.

## 3. مصفوفة protocol × model capability × request shape

المصفوفة التالية تحدد أصناف policy المطلوب تمثيلها. لا تعني أن كل صف مدعوم
تلقائيًا؛ يصبح الصف `supported` فقط عند وجود policy وfixture واختبار Sanad.

| protocol/route | capability الخاصة بالنموذج | native request shape | قاعدة Sanad |
|---|---|---|---|
| OpenAI Chat Completions | مجموعة effort محددة للنموذج | `reasoning_effort` في المستوى الأعلى | تُرسل قيمة موجودة في descriptor فقط |
| OpenAI Responses/Codex | مجموعة effort محددة للنموذج | `reasoning: {effort, summary}` | تبقى منفصلة عن Chat وتستخدم codec واحدة للمسارين |
| Anthropic Messages — manual | token budget | `thinking: {type: enabled, budget_tokens: N}` | تحويل mode إلى budget يحتاج جدول model مثبتًا |
| Anthropic Messages — adaptive | adaptive + effort subset | adaptive thinking مع output/effort control منفصل، أو omission حسب route | model policy تختار manual أو adaptive؛ لا يُفترض دعم off |
| Google-compatible — budget | budget رقمي وقواعد zero/max خاصة بالنموذج | `thinkingConfig.thinkingBudget` مع nesting/casing خاص بالroute | metadata تحدد budget؛ الصفر قد يكون off أو invalid |
| Google-compatible — level | enum خاص بالنموذج | `thinkingConfig.thinkingLevel` | تُعرض المجموعة الفرعية الفعلية فقط |
| Aggregator route | capability تتبع upstream model | nested reasoning أو budget أو استثناء خاص | profile الخاص بالaggregator يُركب مع upstream model policy |
| Toggle/effort route | toggle وeffort متنافيان | أحدهما فقط: `thinking` أو effort | policy تمنع وجودهما معًا |
| Local model server | capability حية لكل model | boolean/level/effort وفق API الفعلي | probe حي؛ سياسة local منفصلة عن cloud-compatible |
| Custom compatible endpoint | غير معروفة افتراضيًا | غير معروف | `unknown`/لا selector حتى وجود metadata موثوقة أو profile صريح |

## 4. تشخيص Sanad الحالي

### 4.1 المسار الصحيح الموجود

اختيار الواجهة ينتقل بالفعل عبر:

```text
composer
→ canonical thinking_mode
→ AgentTurnRequest
→ AgentRunner / TurnRouteState
→ LLMRequestOptions.thinkingMode
→ adapter
```

كما أن Sanad يملك أساسًا مناسبًا للبناء عليه:

- provider instances مستقرة الهوية؛
- protocol فعال لكل instance؛
- model cache مع revisions؛
- model snapshots تصل إلى client model picker؛
- request options immutable؛
- OpenAI وCodex يملكان builder مشتركة بين sync وstream؛
- route changes وsession persistence موجودة بالفعل.

### 4.2 الفجوات المؤكدة

- device capabilities تعلن دائمًا `fast | balanced | deep`.
- `ModelOption.supportsReasoning` boolean ولا يصف نوع التحكم أو قيمه.
- client composer يقرأ القائمة العامة بدل capability للنموذج الفعال.
- OpenAI-compatible يطبق mapping عامًا بمجرد اكتشاف reasoning.
- Codex يقبل vocabulary أوسع دون model-specific validation.
- Anthropic وOllama يتلقيان `thinkingMode` لكن لا يترجمانه.
- fallback/current metadata قد تعرف أن النموذج reasoning دون معرفة controls.
- لا توجد typed error تمنع provider call عندما يكون اختيار المستخدم غير مدعوم.
- الاختيار المخزن غير مربوط بالroute/capability revision التي تحققت منه.

## 5. القرار المعماري

### 5.1 الملكية

يوزع الحل المسؤوليات كالتالي:

1. **Provider runtime** يملك اكتشاف capability الفعلية وتجميعها لكل
   `(provider instance, protocol, model)`.
2. **Model metadata/live probe** يقدمان facts فقط: reasoning output، الخيارات
   الأصلية أو capability الحية، freshness، ومصدر البيانات.
3. **Provider thinking policy** يقرر:
   - هل التحكم مدعوم؟
   - ما الخيارات الصالحة؟
   - ما provider default؟
   - هل explicit off صالح؟
   - كيف تتحول selection إلى directive native typed؟
4. **Adapter/codec** يضع directive في JSON النهائي الخاص ببروتوكوله، ولا يخمن
   capability ولا يقرر fallback.
5. **Client** يعرض descriptor فقط ولا ينشئ قائمة أو mapping محليًا.

### 5.2 الأنواع المقترحة

```dart
enum ThinkingCapabilityStatus { supported, unsupported, unknown }

enum ThinkingControlKind {
  effort,
  toggle,
  tokenBudget,
  level,
  adaptive,
  modelVariant,
}

class ThinkingControlOption {
  final String id;          // stable source-neutral selection id
  final String label;       // English UI label
  final bool isOff;
  final bool isProviderDefault;
}

class ThinkingControlDescriptor {
  final ThinkingCapabilityStatus status;
  final ThinkingControlKind? kind;
  final List<ThinkingControlOption> options;
  final String? defaultOptionId; // null = provider/model default by omission
  final String capabilityRevision;
  final String source; // profile | model_metadata | live
  final DateTime? observedAt;
}
```

لا يحمل descriptor أي request JSON. الترجمة الداخلية تنتج union مغلقة مثل:

```dart
sealed class NativeThinkingDirective {}
class UseProviderDefault extends NativeThinkingDirective {}
class OpenAiEffortDirective extends NativeThinkingDirective { ... }
class ResponsesReasoningDirective extends NativeThinkingDirective { ... }
class AnthropicBudgetDirective extends NativeThinkingDirective { ... }
class GoogleBudgetDirective extends NativeThinkingDirective { ... }
class GoogleLevelDirective extends NativeThinkingDirective { ... }
class ThinkingToggleDirective extends NativeThinkingDirective { ... }
```

هذا يمنع تمرير map غير typed عبر المحرك ويجعل adapter هو المالك الوحيد لوضع
الحقول في wire payload.

### 5.3 registry المقترحة

تُضاف واجهة source-neutral:

```dart
abstract interface class ProviderThinkingPolicy {
  ThinkingControlDescriptor resolveCapability(ThinkingPolicyContext context);
  NativeThinkingDirective resolveDirective(
    ThinkingPolicyContext context,
    String? selectionId,
  );
}
```

ويحتوي `ThinkingPolicyContext` على:

- provider instance ID؛
- template/profile ID؛
- effective protocol/api mode؛
- normalized model ID؛
- model metadata؛
- live capability evidence؛
- capability revision/freshness.

`ProviderProfile` يحدد `thinkingPolicyId` فقط. لا توضع condition ladders حسب
أسماء المزودين داخل `AgentRunner` أو `BaseOpenAIAdapter`.

## 6. عقد capability والبروتوكول

### 6.1 device capabilities

تبقى device capabilities متاحة دون provider setup، لكنها لا تكون مصدر الخيارات.
التحول الإضافي المتوافق خلفيًا:

```json
{
  "supports_thinking_mode_change": true,
  "thinking_mode_source": "model"
}
```

- يمكن إبقاء `thinking_modes_list` مؤقتًا للتوافق، لكن تصبح فارغة ولا يستخدمها
  العميل الجديد.
- لا تعني `supports_thinking_mode_change` أن كل model يدعم selector؛ بل إن
  الجهاز يفهم العقد الديناميكي.

### 6.2 model snapshot

يمتد كل model في `model.snapshot_result` إلى:

```json
{
  "id": "model-id",
  "name": "Model",
  "supports_reasoning_output": true,
  "thinking_control": {
    "status": "supported",
    "kind": "effort",
    "options": [
      {"id": "low", "label": "Low", "is_off": false},
      {"id": "medium", "label": "Medium", "is_off": false},
      {"id": "high", "label": "High", "is_off": false}
    ],
    "default_option_id": null,
    "capability_revision": "opaque-revision",
    "source": "profile"
  }
}
```

الحالات:

- `supported`: تعرض الواجهة الخيارات الواردة فقط.
- `unsupported`: تخفي الواجهة selector.
- `unknown`: لا تسمح باختيار قيمة جديدة، وتعرض حالة unavailable/refresh عند
  الحاجة بدل افتراض الدعم.

### 6.3 active route capability

لمنع اعتماد composer على model picker cache قديمة، تُضاف capability الفعالة إلى
route/session snapshot أو event مخصص مرتبط بـ:

```text
provider_instance_id
model
route_revision
thinking_control
```

ولا يطبق العميل descriptor إذا لم تطابق route الحالية.

## 7. عقد validation وfallback

### 7.1 عند إرسال turn

قبل إنشاء provider request:

1. يحل runtime route الفعالة.
2. يحل descriptor حديثة أو cache صالحة revisions.
3. إذا كان selection غائبًا، ينتج `UseProviderDefault`.
4. إذا كان selection موجودًا ومتاحًا، ينتج native directive.
5. إذا كان `unsupported` أو `unknown` أو option ID غير موجود:
   - لا يستدعى adapter HTTP؛
   - يصدر خطأ typed قابل للعرض؛
   - يبقى draft/turn قابلًا للتصحيح؛
   - لا تتحول الحالة إلى provider failure أو rate limit.

### 7.2 عند تبديل provider/model

بعد commit لتغيير route وقبل تأكيد thinking preference:

- إن كان الاختيار نفسه صالحًا في descriptor الجديدة، يُحفظ.
- إن لم يكن صالحًا، يُمسح إلى provider default وتصدر confirmation/correction
  واضحة تحتوي reason مثل `thinking_option_unavailable_for_route`.
- downgrade مسموح فقط إذا أعلنت policy alias محددًا، مثل legacy migration؛ لا
  يوجد nearest-value guessing.

### 7.3 legacy values

القيم `fast | balanced | deep` تصبح aliases انتقالية:

- `fast → low` فقط إذا كان `low` متاحًا؛
- `balanced | normal → medium` فقط إذا كان `medium` متاحًا؛
- `deep → high` فقط إذا كان `high` متاحًا؛
- خلاف ذلك تُمسح إلى provider default مع correction مرئية.

لا تُعرض aliases القديمة في snapshots الجديدة.

## 8. استراتيجية persistence

الاختيار المخزن يمثل user intent مرتبطًا بالroute، وليس native wire value:

```text
thinking_selection_id
thinking_provider_instance_id
thinking_model_id
thinking_capability_revision
```

القواعد:

- `thinking_selection_id = null` يعني provider default.
- لا تُخزن token budgets أو request fragments إلا إذا كانت option ID موثقة
  وثابتة داخل policy للنموذج.
- session restore يعيد resolution قبل السماح بأول model call.
- auto-failover يعيد validation ضمن route mutation نفسها.
- queued/running work يحصل على الاختيار المصحح مع route atomically حتى لا
  تختلف request المستأنفة عن session snapshot.
- Task 39 يبقى مالك إصلاح عرض/استعادة قيمة العميل؛ Task 43 يحدد صحة القيمة
  والعقد الديناميكي فقط.

## 9. Gates التنفيذ

### Gate R0 — Evidence lock واختيارات الدعم

**الهدف:** تثبيت نطاق mappings الأولى قبل الكود.

- [x] إنشاء evidence packet لثلاثة مشاريع عاملة.
- [x] تسجيل revisions وlicenses والملفات والاختبارات المفحوصة.
- [x] إنتاج Adopt/Adapt/Reject ومصفوفة wire shapes.
- [x] اعتماد هذه الخطة من المستخدم.
- [x] تحديد provider/model policies التي ستدخل الإصدار الأول؛ أي حالة ملتبسة
      تبقى `unknown` ولا تؤخر البنية العامة.

**قائمة الإصدار الأول المغلقة (policy ids):**

| policy id | نطاق القالب / الـroute | ملاحظة |
|---|---|---|
| `openai_chat_effort` | قالب `openai` فقط (`thinkingPolicyId` صريح) | لا يُشتق تلقائيًا لكل `chat_completions` |
| `codex_responses_effort` | `apiMode: codex_responses` | Responses shape منفصل |
| `anthropic_thinking` | `apiMode: anthropic_messages` | manual/adaptive حسب كتالوج النموذج |
| `aggregator_upstream` | OpenRouter (`thinkingPolicyId` صريح) | يركّب مع upstream model policy |
| `google_thinking` | Gemini (`thinkingPolicyId` صريح) | budget/level حسب النموذج |
| `deepseek_thinking` | DeepSeek (`thinkingPolicyId` صريح) | فقط نماذج fixture مثبتة؛ غير ذلك unsupported/unknown داخل السياسة |
| `ollama_live` | `apiMode: ollama` | probe حي؛ فشل مؤقت → `unknown` |
| `unknown` | custom وجميع المسارات الملتبسة | fail-closed؛ لا selector تخميني |

Toggle/effort المتنافي (Kimi/Moonshot وأشباهه) لا يدخل الإصدار الأول كـpolicy
عامة حتى يوجد `thinkingPolicyId` مخصص وfixture Sanad؛ حتى ذلك يبقى خارج
القائمة المغلقة أعلاه أو fail-closed.

**DoD:** resolver يعيد `ready`، والخطة معتمدة، وقائمة الإصدار الأول مغلقة.

### Gate A — Typed domain وpolicy registry

**الهدف:** فصل capability عن request JSON.

- [x] إضافة أنواع descriptor/options/status/directives.
- [x] إضافة `ProviderThinkingPolicy` وregistry.
- [x] إضافة policy افتراضية fail-closed ترجع `unknown` للcustom/unknown route.
- [x] إضافة `thinkingPolicyId` أو seam مكافئة إلى provider profile.
- [x] إبقاء runner provider-neutral.

**اختبارات:**

- [x] supported/unsupported/unknown؛
- [x] unknown custom endpoint؛
- [x] option ordering/default/off semantics؛
- [x] policy lookup حسب profile + protocol؛
- [x] لا raw maps في directive boundary.

**DoD:** كل route تحصل على policy صريحة أو fail-closed policy، ولا يتغير wire
payload بعد.

### Gate B — Model capability assembly and cache

**الهدف:** حساب descriptor لكل model وربطها بالcache revisions.

- [x] توسيع `ModelOption` أو إنشاء DTO مستقل لـthinking control.
- [x] تركيب profile facts + model metadata + live probe.
- [x] فصل `supportsReasoningOutput` عن `thinkingControl`.
- [x] إضافة `capabilityRevision`, source, freshness.
- [x] الحفاظ على `unknown` عند فشل probe المؤقت.
- [x] تحديث serialization/deserialization في provider model cache.

**اختبارات:**

- [x] cache roundtrip؛
- [x] config/credential revision invalidation؛
- [x] transient probe failure ≠ unsupported؛
- [x] stale live evidence؛
- [x] Ollama/local capability probe fixture دون افتراض name pattern.

**DoD:** model snapshot الداخلي يصف خيارات كل model بدقة ولا يعتمد على boolean
واحد.

### Gate C — Canonical protocol and client model

**الهدف:** إيصال capability الديناميكية إلى الواجهة.

- [x] إضافة `thinking_mode_source: model` إلى device capability.
- [x] إضافة `thinking_control` إلى model snapshot والroute/session snapshot.
- [x] تحديث DTOs في العميل مع parsing متوافق خلفيًا.
- [x] عدم استخدام `thinking_modes_list` في العميل الجديد.
- [x] توثيق protocol في `docs/technical/provider_protocol.md`.

**اختبارات:**

- [x] agent serialization؛
- [x] client parsing لكل status؛
- [x] old agent payload fallback؛
- [x] route revision تمنع تطبيق descriptor قديمة.

**DoD:** client يستطيع معرفة الخيارات الصحيحة للنموذج الفعال دون hardcoding.

### Gate D — Central validation and persistence

**الهدف:** منع silent ignore وربط الاختيار بالroute.

- [x] إضافة resolver مركزي للاختيار الفعال.
- [x] إضافة typed unsupported/stale error قبل adapter call.
- [x] توسيع persistence بالroute binding وcapability revision.
- [x] revalidation عند model/provider switch وrestore/failover.
- [x] correction event عند clearing/downgrade المعلن.
- [x] migration للقيم legacy.

**اختبارات:**

- [x] explicit valid selection؛
- [x] explicit unsupported selection يرسل صفر HTTP requests؛
- [x] null يستخدم provider default؛
- [x] switch valid→invalid؛
- [x] restore بعد تغير capability revision؛
- [x] auto-failover وqueued work؛
- [x] legacy aliases المتاحة وغير المتاحة.

**DoD:** لا توجد قيمة مخزنة تصل adapter دون validation حديثة، ولا يحدث silent
fallback.

### Gate E — OpenAI Chat and Responses policies

**الهدف:** نقل السلوك الحالي من mapping عام إلى policies مثبتة.

- [x] OpenAI Chat directive → top-level `reasoning_effort`.
- [x] Responses/Codex directive → `reasoning.{effort,summary}`.
- [x] model-specific effort subsets؛ لا passthrough مفتوح للقيم.
- [x] إزالة `_normalizeReasoningEffort` العامة بعد اكتمال migration.
- [x] إبقاء encrypted reasoning/state contracts دون تغيير.

**اختبارات request-body:**

- [x] low/medium/high وأي tier إضافي مثبت لكل model fixture؛
- [x] unsupported tier يرسل صفر requests (عبر Gate D resolver)؛
- [x] sync/stream parity؛
- [x] Chat لا يحمل Responses shape والعكس؛
- [x] wrapper forwarding يحافظ على resolved options نفسها.

**DoD:** لا يعتمد OpenAI-compatible العام على `supportsReasoning` لإرسال effort.

### Gate F — Anthropic policy

**الهدف:** دعم manual/adaptive دون خلطهما.

- [x] manual budget options بجداول model مثبتة فقط.
- [x] adaptive descriptor منفصل عن manual budget.
- [x] explicit off يظهر فقط إذا أثبتته policy.
- [x] shared body builder لمساري sync وstream؛ لا نسخ بناء request الحالي.
- [x] الحفاظ على tool/reasoning replay contracts الخاصة بالبروتوكول.

**اختبارات request-body:**

- [x] budget lowering الصحيح؛
- [x] adaptive/manual mutual exclusion؛
- [x] missing budget validation؛
- [x] unsupported off؛
- [x] sync/stream parity؛
- [x] tool continuation لا يفقد controls المطلوبة.

**DoD:** Anthropic لا يتجاهل selection ولا يرسل manual shape إلى adaptive model.

### Gate G — Aggregator, Gemini, DeepSeek/Kimi, and local policies

**الهدف:** إضافة كل عائلة كوحدة مستقلة، لا توسيع generic adapter.

ترتيب التنفيذ:

- [x] Aggregator profile مع upstream-model policy (`aggregator_upstream` → OpenRouter nested `reasoning` + Anthropic/OpenAI capability delegation).
- [x] Gemini budget/level policies مع route nesting.
- [x] Toggle/effort mutual-exclusion policies.
- [x] Local live-capability policy (`ollama_live`).
- [x] DeepSeek فقط بعد حسم route/model fixture؛ يبقى `unknown` قبل ذلك.

**اختبارات request-body لكل policy:**

- [x] exact nesting/casing (Ollama `think`, OpenAI, Anthropic)؛
- [x] model-specific option subsets (Ollama gpt-oss)؛
- [x] zero/off semantics (Ollama off → `think: false`)؛
- [x] token-budget يحظى بالأولوية ولا يستبدل بـeffort؛
- [x] conflicting controls never coexist (Anthropic manual vs adaptive)؛
- [x] unsupported model يرسل صفر controls وصفر request عند explicit selection؛
- [x] sync/stream parity (Ollama/OpenAI/Anthropic).

**DoD:** كل mapping له policy وfixture واختبار نهائي، ولا توجد branch عامة حسب
اسم model داخل runner.

### Gate H — Client composer behavior

**الهدف:** عرض الاختيارات الصحيحة فقط.

- [x] `supported`: إظهار options المرتبة من daemon.
- [x] `unsupported`: إخفاء thinking chip.
- [x] `unknown`: تعطيل الاختيار وعرض unavailable/refresh state عند الحاجة.
- [x] route change يعيد بناء القائمة ويزيل selection المصححة بعد confirmation.
- [x] لا fallback محلي إلى `balanced` عند قائمة فارغة.
- [x] جميع نصوص UI بالإنجليزية.

**اختبارات widget/state:**

- [x] supported option list (resolver unit tests)؛
- [x] unsupported hidden؛
- [x] unknown disabled؛
- [x] route switch stale descriptor؛
- [x] correction event؛
- [x] backward-compatible old payload.

**DoD:** لا يستطيع المستخدم اختيار قيمة لا يعلنها النموذج الفعال.

### Gate I — End-to-end proof and audit

**الهدف:** إثبات المسار الكامل ومراجعة الالتزامات المرجعية.

- [x] E2E باستخدام deterministic fixture provider يلتقط final payload:

  ```text
  composer selection
  → canonical thinking_mode
  → turn admission
  → runner options
  → policy resolution
  → adapter payload
  ```

- [x] E2E ثانٍ لاختيار unsupported يثبت عدم استدعاء provider.
- [x] اختبار restart/model-switch revalidation عبر daemon الحقيقي إذا تطلب تغيير
      persistence ذلك.
- [x] إعادة فتح evidence run وتقييم كل Adopt/Adapt item كـ`satisfied`, `deviated`,
      أو `not applicable`.
- [x] تحديث Graphify بعد تعديل الكود.

**Evidence audit (Gate R0 → Gate I closure):**

| المرجع | القرار | الحالة | ملاحظة |
|---|---|---|---|
| Model variants — descriptor ديناميكي لكل model | Adopt | satisfied | `ThinkingControlDescriptor` + model cache/snapshot |
| Model variants — typed resolution error للقيمة غير المتاحة | Adopt | satisfied | `ThinkingSelectionException` قبل HTTP |
| Canonical level + provider hooks — validation مركزي | Adopt | satisfied | `ThinkingSelectionResolver` + `ProviderThinkingPolicy` |
| Canonical level + provider hooks — provider wrappers | Adopt | satisfied | typed wire codecs لكل policy |
| Canonical enabled/effort + profiles — per-model config | Adopt | satisfied | catalogs + assembler + cache revisions |
| Canonical enabled/effort + profiles — omission = provider default | Adopt | satisfied | `null` selection → لا حقل wire |
| OpenAI Chat `reasoning_effort` | Adopt | satisfied | Gate E + `thinking_mode_gate_i_e2e_test.dart` I.1 |
| OpenAI Responses `reasoning.{effort,summary}` | Adopt | satisfied | Codex codec + adapter tests |
| Anthropic manual/adaptive/off | Adopt | satisfied | Gate F policy + wire codec |
| Google budget/level nesting | Adopt | satisfied | Gate G `google_thinking` |
| Aggregator upstream composition | Adapt | satisfied | `aggregator_upstream` delegates upstream policy |
| Toggle/effort mutual exclusion | Adapt | satisfied | `toggle_effort_thinking_wire_codec` |
| Local Ollama live probe | Adapt | satisfied | `/api/show` metadata probe |
| Custom/unknown endpoint fail-closed | Adopt | satisfied | `unknown_thinking_policy` |
| Silent ignore للقيمة غير الصالحة | Reject | satisfied (avoided) | fail-closed + correction events |
| Model-name heuristics وحدها | Reject | satisfied (avoided) | catalog/probe/metadata only |
| Static device `thinking_modes_list` في client جديد | Reject | satisfied (avoided) | `thinking_mode_source: model` |

**E2E coverage:**

- `agent/test/engine/thinking_selection_agent_runner_test.dart` — runner-level supported/unsupported.
- `agent/e2e_test/thinking_mode_gate_i_e2e_test.dart` — daemon payload capture، unsupported skip، model-switch correction، restart revalidation.

**DoD:** E2E أخضر، audit بلا deviation غير مبرر، والتحليل والاختبارات المطلوبة
حسب blast radius ناجحة.

## 10. معايير القبول النهائية

1. لا تظهر قائمة thinking عامة غير مرتبطة بالنموذج.
2. لا يعني `supports_reasoning_output` تلقائيًا أن التحكم متاح.
3. كل explicit selection إما تصل إلى native payload الصحيح، أو تُرفض قبل HTTP،
   أو تُصحح بحدث واضح؛ لا silent ignore.
4. `null` يحافظ على provider default دون فرض `balanced`.
5. sync وstream متطابقان في كل الحقول غير الخاصة بالبث.
6. custom/unknown compatible endpoint لا يحصل على controls تخمينية.
7. model/provider switch وfailover وrestore لا تحتفظ بقيمة غير صالحة.
8. explicit off يُعامل كدلالة مستقلة عن omission.
9. client يعرض فقط options الصادرة من active route descriptor.
10. لكل policy مدعومة request-body tests وE2E واحد على الأقل للمسار الكامل.

## 11. الملفات المتوقعة في التنفيذ

### Agent

- `agent/lib/engine/adapters/provider_profile.dart`
- `agent/lib/engine/adapters/provider_registry.dart`
- `agent/lib/engine/adapters/llm_request_options.dart`
- provider thinking policy files الجديدة تحت `agent/lib/engine/adapters/`
- `agent/lib/engine/adapters/base_openai_adapter.dart`
- `agent/lib/engine/adapters/codex_responses_codec.dart`
- `agent/lib/engine/adapters/base_anthropic_adapter.dart`
- `agent/lib/engine/adapters/ollama_adapter.dart`
- `agent/lib/core/provider_runtime/provider_model_cache_service.dart`
- model capability assembly files تحت `agent/lib/core/provider_runtime/`
- `agent/lib/interfaces/platforms/sanad_gateway/capabilities.dart`
- `agent/lib/interfaces/platforms/sanad_gateway/capabilities_loader.dart`
- `agent/lib/interfaces/platforms/sanad_gateway/handlers/provider_command_handler.dart`
- route/session persistence owners بحسب Gate D.

### Client

- `client/lib/features/devices/domain/models/capability.dart`
- `client/lib/features/provider_setup/data/models/model_cache_snapshot_dto.dart`
- conversation composer thinking selector files.

### Documentation and tests

- `docs/agent_engine/llm_adapter_runtime_contract.md`
- `docs/technical/provider_protocol.md`
- QA matrix جديدة أو محدثة تحت `docs/qa_maintenance/`
- focused adapter/provider-runtime/protocol/client tests.

هذه قائمة blast radius متوقعة وليست إذنًا لتعديل كل ملف؛ يُحدد كل Gate أصغر
مجموعة لازمة بعد قراءة العقد المحلي الأقرب.

## 12. حدود التنفيذ

- لا mapping جديد بلا evidence مثبت واختبار Sanad.
- لا استخدام model-name heuristics وحدها لإعلان capability إذا توفر مصدر أدق.
- لا وضع provider-specific branching داخل `AgentRunner`.
- لا تسريب native request shape إلى client protocol.
- لا تعديل نطاق Task 39 الخاص باستعادة وعرض قيمة التفكير، إلا بقدر التكامل مع
  descriptor/correction contract الجديد.
- لا تشغيل كود أو tests للمشاريع المرجعية؛ هي مصادر قراءة غير موثوقة، والاختبار
  التنفيذي يتم داخل Sanad فقط.

## 13. سجل التقدم

| التاريخ | البوابة | النتيجة | ملاحظات |
|---|---|---|---|
| 2026-08-29 | R0 | مغلق بعد إصلاح | `resolve_packet.sh 43` كان `refresh_required` (hermes+openclaw drift). حُدّثت pins والمسارات الإلزامية؛ fingerprint الجديد `sha256:ee2edb165e9df40967f05dfd8b7997c80524d31a44fb38a0441a4c7a5a5f44e5`؛ resolver=`ready`. أُغلقت قائمة سياسات الإصدار الأول. |
| 2026-08-30 | R0 | مراجعة بوابة: مغلق | أُعيد `resolve_packet.sh 43` → `status=ready`. البصمة تطابق frontmatter. Pins: opencode `d2305d4`، hermes `f52feed`، openclaw `2013a4b`. قائمة الإصدار الأول مغلقة في الخطة وفي سجل التشغيل. |
| 2026-08-30 | A | مراجعة بوابة: مغلق بعد إصلاح | الأنواع/registry/fail-closed/`thinkingPolicyId` وrunner محايد. أُزيلت حلقة placeholders الميتة. اختبارات descriptor تغطي off/default/unsupported. تحقق: analyze على ملفات البوابة نظيف؛ `provider_thinking_test.dart` 56/56. |
| 2026-08-30 | B | مراجعة بوابة: مغلق بعد إصلاح | assembler + cache enrichment + فصل reasoning output عن thinkingControl + probe_failed=unknown. أُضيفت اختبارات stale (TTL/observedAt/probe_failed/profile) وفحص probe دون name heuristic. تحقق: cache/stale/probe/model-cache 24/24. |
| 2026-08-30 | C | مراجعة بوابة: مغلق بعد إصلاح | `thinking_mode_source: model` يفرّغ `thinking_modes_list` في wire. DTOs العميل + session `thinking_control` + تجاهل descriptor عند اختلاف route revision. تحديث اختبار البروتوكول وE2E dual-connection. تحقق: agent 43 + client 23. |
| 2026-08-30 | D | مراجعة بوابة: مغلق بعد إصلاح | resolver fail-closed يمنع silent UseProviderDefault لاختيار صريح. إعادة تحقق عند تبديل المزود وليس النموذج فقط. mock `clearThinkingMode`. تحقق: selection/preference/sync/runner 15/15. |
| 2026-08-30 | E | مراجعة بوابة: مغلق بعد إصلاح | Chat `reasoning_effort` وResponses nested؛ لا `_normalizeReasoningEffort`. اختبار Codex يستخدم directive بدل `thinkingMode: deep`. تحقق: OpenAI/Codex focused 47/47. |
| 2026-08-30 | F | مراجعة بوابة: مغلق بعد تحقق | manual/adaptive/off + shared body builder + budget lowering. تحقق: Anthropic focused 25/25. |
| 2026-08-30 | G | مراجعة بوابة: مغلق بعد تحقق | aggregator/google/deepseek/ollama + XOR codec. Kimi يبقى `unknown`. تحقق: Gate G focused 29. |
| 2026-08-30 | H | مراجعة بوابة: مغلق بعد تحقق | `supported` يعرض options؛ `unsupported` يخفي؛ `unknown` يعطّل مع Unavailable؛ لا `balanced` مع source=model. تحقق: route/input/session cubit focused 19. |
| 2026-08-30 | I | مراجعة بوابة: مغلق بعد إصلاح | E2E I.1–I.4 أخضر (`--concurrency=1`) بعد ربط منافذ loopback الحرة بدل النطاق الضيق. runner 2/2. `moonshotai` على المجمع يبقى `unknown` وفق قفل R0. تدقيق الأدلة `43-audit-2026-08-30`. Graphify محدّث. analyze للعامل والعميل نظيف. |
| 2026-08-29 | A | مغلق بعد إصلاح | الأنواع/registry/fail-closed موجودة. أُصلح اشتقاق `chat_completions` العام إلى `unknown` مع opt-in صريح لـ`openai`. تحقق: `fvm dart analyze` نظيف؛ `provider_thinking_test.dart` 54/54. |
| 2026-08-29 | B | مغلق بعد تحقق | assembler + cache enrichment + فصل `supportsReasoningOutput`/`thinkingControl` + stale/probe-failed. تحقق: cache resolver/stale/model-cache tests 17/17. |
| 2026-08-29 | C | مغلق بعد تحقق | `thinking_mode_source: model`، `thinking_control` في snapshots، DTOs العميل، توثيق protocol. تحقق: agent 3 + client 19 اختبارات. |
| 2026-08-29 | D | مغلق بعد تحقق | resolver + typed errors + preference store + revalidator + sync failover/restore. تحقق: selection/preference/sync/runner tests 13/13. |
| 2026-08-29 | E | مغلق بعد تحقق | Chat `reasoning_effort` وResponses nested؛ لا `_normalizeReasoningEffort`؛ sync/stream parity. تحقق: OpenAI/Codex focused tests 29/29. |
| 2026-08-29 | F | مغلق بعد تحقق | manual/adaptive/off + shared body builder. تحقق: Anthropic focused tests 25/25. |
| 2026-08-29 | G | مغلق بعد تحقق | aggregator/google/deepseek/ollama + toggle XOR codec. Kimi يبقى `unknown` وفق قفل R0. تحقق: Gate G focused 30 + ollama probe. |
| 2026-08-29 | H | مغلق بعد إصلاح | إصلاح مسح `selectThinkingMode(null)` + `clearLastThinkingMode`؛ لا فرض `balanced` مع `thinking_mode_source=model`. تحقق: route + input cubit 45/45. |
| 2026-08-29 | I | مغلق بعد تحقق وإصلاح وثائق | E2E 4 + runner 2 أخضر؛ تحديث Graphify؛ تدقيق الأدلة بلا deviation؛ تحديث `llm_adapter_runtime_contract.md` وإضافة QA matrix. |
