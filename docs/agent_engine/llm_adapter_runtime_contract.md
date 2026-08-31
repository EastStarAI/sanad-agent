---
title: "LLM Adapter Runtime Contract"
description: "عقد خيارات طلب النموذج، reasoning القابل للعرض، وحالة المزود اللازمة للاستكمال."
---

# LLM Adapter Runtime Contract

## حدود البيانات

يفصل محرك Sanad بين ثلاث طبقات في استجابة النموذج:

1. `content`: الجواب الموجه للمستخدم.
2. `reasoning`: ملخص التفكير أو commentary القابل للعرض. لا يحتوي بيانات
   بروتوكول opaque ولا يُستخدم تلقائيًا لإعادة بناء طلب المزود.
3. `providerState`: بيانات opaque وnamespaced يحتفظ بها adapter لاستمرارية
   البروتوكول، مثل encrypted reasoning items أو response item identifiers.

يحمل `finishReason` حالة النهاية الموحّدة: جواب نهائي، طلب أدوات، رد غير مكتمل،
حد طول، فشل، إلغاء، أو حالة غير معروفة. لا يستنتج المحرك اكتمال الدور من وجود
نص وحده. يعيد adapter السبب في `AgentResponse`، ثم يثبته `AgentRunner` على
assistant `Message` المحفوظة حتى يبقى متاحًا بعد restart. القيم الغائبة أو
المستقبلية غير المعروفة تُقرأ كـ`unknown` للتوافق مع التاريخ القديم.

## خيارات الطلب

`LLMRequestOptions` هو سياق عابر لكل model call ويحتوي هوية الجلسة والطلب،
اختياريًا `thinkingMode` كـselection id للمسار، و`thinkingDirective` typed من
سياسة التفكير بعد التحقق المركزي (Task 43)، بالإضافة إلى timeout وحد output.
لا يحتفظ adapter بهذه القيم بين الطلبات، ولا تُخزن داخل history.

كل استدعاء لاحق داخل tool loop يستخدم الخيارات نفسها للدور ما لم يغيّر runtime
route أو إعدادات الدور صراحةً. لا يخمن adapter القدرة من
`supportsReasoning`/`supportsReasoningOutput` وحده؛ وضع الحقول السلكية يتم فقط
من `NativeThinkingDirective` عبر wire codecs الخاصة بالسياسة.

## Adapter Reasoning Parity

| Adapter family | Structured reasoning | Tagged fallback | Streaming separation |
|---|---|---|---|
| OpenAI-compatible | `reasoning_content`, `reasoning`, details summaries | Yes | reasoning callback منفصل |
| Anthropic Messages | `thinking` blocks و`thinking_delta` | Yes للـcompatible endpoints | reasoning callback منفصل |
| Ollama Chat | `message.thinking` | Yes | reasoning callback منفصل |
| Codex Responses | reasoning summary items والدلالات commentary/analysis | ليس مطلوبًا | codec/accumulator يصدران reasoning delta مستقلًا |

كل adapter يعيد التفكير المرئي في `Message.reasoning` فقط. يستهلك
`AgentRunner` العقد نفسه دون branch حسب المزود، ثم يحوله `SessionTurnExecutor`
إلى استجابة reasoning مستقلة ويصدر protocol translator نوع
`reasoning_stream`. wrappers مثل rate limiting تمرر `AgentResponse` دون تعديل.

## OpenAI-compatible Chat Completions

يبني `BaseOpenAIAdapter` payload الأساسي مرة واحدة لمساري sync وstream؛ يضيف
مسار stream فقط `stream` و`stream_options`. تُطبَّق سياسة التفكير حسب
`ProviderProfile.effectiveThinkingPolicyId` عبر codecs typed:

- `openai_chat_effort` → `OpenAiThinkingWireCodec` يضع `reasoning_effort` فقط
  عند وجود `OpenAiEffortDirective`.
- `aggregator_upstream` / `google_thinking` / `deepseek_thinking` → codecs
  العائلة المقابلة (nested `reasoning` أو `thinking_config` أو toggle XOR
  effort).
- `unknown` أو `UseProviderDefault` → لا يُضاف حقل تفكير.

القيم `fast`/`balanced`/`deep` aliases ترحيلية فقط في طبقة التحقق المركزية؛ لا
تُعرض في snapshots الجديدة ولا يترجمها adapter مباشرة. يستخدم حد المخرجات الحديث
`max_completion_tokens` لأنه يشمل النص المرئي وreasoning tokens.

ترتيب استخراج التفكير المرئي هو `reasoning_content` ثم `reasoning` ثم
`reasoning_details`. عند غياب الحقول المنظمة، يستخدم parser مشترك كتل
`<thought>` و`<think>` و`<reasoning>` و`<thinking>` و`[THOUGHT]`، حتى إذا
انقسمت العلامات بين network chunks. وإذا انتهى stream قبل وسم الإغلاق، يبقى
الجزء المفتوح reasoning ولا يتحول إلى جواب. يجب فصل الناتج عن `content` في
sync وstream وألا تتسرب الوسوم إلى الجواب النهائي.

إذا أعاد endpoint `reasoning_details` اللازمة لاستمرار tool loop، تُحفظ داخل
`LLMProviderState` بالـnamespace `openai_chat_completions`. لا يعيد builder هذه
التفاصيل إلا إذا تطابق issuer المكوّن من provider instance والبروتوكول وbase
URL المطبّع مع الاتصال الحالي. تغيير endpoint لنفس instance يبطل replay. لا تُستخدم
`Message.reasoning` لإعادة بناء wire state.

يحوّل adapter أسباب نهاية Chat Completions إلى `LLMFinishReason`: `stop`،
`tool_calls`/`function_call`، `length`، حالات الفشل، والإلغاء. معاملات الأدوات
يجب أن تكون JSON object صالحًا؛ الرد المشوه يفشل ولا يتحول إلى استدعاء بمعاملات
فارغة.

## Anthropic Messages

يبني `BaseAnthropicAdapter` system prompt وmessages والأدوات وحدود المخرجات من
request builder واحدة لمساري sync وstream. يتحول `maxOutputTokens` إلى
`max_tokens`، ويطبق `LLMRequestOptions.timeout` على إنشاء طلب HTTP في المسارين،
ثم يغلق العميل الذي أنشأه adapter بعد اكتمال الاستجابة أو فشلها.

تطبع history إلى عقد Anthropic قبل الإرسال: تدمج نتائج الأدوات المتتالية داخل
رسالة user واحدة تحتوي عدة `tool_result` blocks، وتحذف `tool_use` اليتيمة التي
ليس لها result مطابق، وتدمج الرسائل المتجاورة ذات الدور نفسه للمحافظة على
التناوب المطلوب. يطبع `stop_reason` إلى `LLMFinishReason` في sync وstream، وتتحول
أحداث الخطأ داخل SSE إلى `LlmHttpException` حتى يملك runtime تصنيف التعافي.

تتحول كتل Anthropic `thinking` في الرد المتزامن وأحداث `thinking_delta` في SSE
إلى `Message.reasoning` فقط، بينما تبقى كتل `text` و`text_delta` داخل
`Message.content`. تستخدم endpoints المتوافقة التي تعيد reasoning داخل text
نفس parser الاحتياطي المشترك، ولا تُعرض `signature_delta` أو الكتل المحجوبة كنص.

## Ollama Chat

يفضل `OllamaAdapter` حقل `message.thinking` المنظم في sync وstream ويضعه في
`Message.reasoning`. إذا لم يقدمه endpoint، يفصل parser المشترك كتل reasoning
النصية المتدفقة عبر حدود chunks. يظل `message.content` جوابًا عاديًا، وتبقى
tool calls وusage مستقلة عن السطحين.

## Codex Responses

يفصل `CodexResponsesAdapter` النقل عن `CodexResponsesCodec` وعن
`CodexResponsesSseAccumulator`. تتطلب Codex Responses `stream: true` لكل طلب؛
لذلك يبني codec payload متدفقًا في مساري sync وstream. يستهلك sync أحداث SSE
داخليًا ويعيد `AgentResponse` مكتملة، بينما يصدر stream deltas للمتصل. يمرر
المساران التجميع النهائي إلى normalizer واحدة.

يستخدم الطلب `store: false` ويطلب `reasoning.encrypted_content` صراحةً. يطبق
`OpenAiThinkingWireCodec.applyResponsesReasoning` توجيه
`ResponsesReasoningDirective` إلى `reasoning.{effort,summary}` عند توفره، وإلا
يُبقى ملخص المزود الافتراضي دون تخمين. يُرسل `max_output_tokens` عند وجوده.
يعيد codec encrypted reasoning وعناصر assistant message الآمنة فقط عند
تطابق issuer. تستخدم reasoning IDs لمنع التكرار محليًا ثم تحذف من wire، بينما
تحفظ حقول assistant `id`, `status`, `phase` الآمنة للمحافظة على الاستمرارية.

يجمع normalizer كل text parts وreasoning summaries، ويحفظ blobs المشفرة منفصلة
عن النص المرئي. يدعم `function_call` و`custom_tool_call`، ويرفض معاملات function
غير الصالحة، وينشئ call IDs حتمية عند غيابها، ويحفظ response item ID على
`ToolCall.providerState`.

يجمع SSE accumulator text/reasoning deltas وfunction argument deltas وoutput
items وusage والأحداث النهائية حتى عند انقسام JSON بين network chunks. تصنف
حالات response/item غير المكتملة وreasoning-only وcommentary-only وتسرب صيغة
الأداة كنص إلى `incomplete`. ترفع حالات failed/cancelled كأخطاء مزود بدل عرضها
كإجابة ناجحة.

في التشغيل المتدفق، يمرر `AgentRunner` كل reasoning delta مرئي إلى callback
مستقل تستخدمه طبقة الواجهات لإصدار `reasoning_stream`. لا تدخل هذه التحديثات في
stream النص النهائي ولا في `fullContent`. لذلك تظهر reasoning summaries أثناء
tool loop حتى عندما تكون رسالة commentary فارغة، بينما يبقى `final_answer`
مكوّنًا من output text النهائي فقط. ينطبق المسار نفسه على الاستكمال بعد restart
أو permission-gated tool call.

## الاستمرارية

Responses-compatible adapters تستخدم `store: false` وتعيد فقط provider state
المطلوبة من التاريخ. البيانات المختومة لمزود أو endpoint لا تعاد إلى issuer
مختلف. `previous_response_id` ليس جزءًا من العقد الحالي.

`AgentRunner` هو مالك history الوحيد. adapters تعيد البيانات فقط، والrunner
يدمجها في الرسالة النهائية ويحفظها دون إنشاء مصدر حالة موازٍ. وجود
`providerState` أو terminal `finishReason` سبب كافٍ لحفظ assistant message حتى
إن لم يوجد content أو reasoning مرئي. إزالة الحالة تستخدم
`copyWith(clearProviderState: true)` صراحةً كي يستطيع مسار التعافي تعطيل replay
دون وضع قيمة وهمية داخل state.

الاستكمال الدلالي مستقل عن إعادة محاولة الشبكة. يحتفظ runner بمنسق خاص بالدور
يسمح بثلاث continuations بعد ردود `incomplete` في sync وstream، مع إعادة التاريخ
المحفوظ في كل مرة. tool loop وsteering يستخدمان منسق الدور نفسه، لكنهما لا
يستهلكان عداد incomplete.

أخطاء الشبكة العابرة قبل أول حدث من stream تحصل على محاولتين تلقائيتين إضافيتين
بحد أقصى ثلاث محاولات إجمالية. تستخدم خدمة الاستعادة backoff قصيرًا متدرجًا مع
jitter، وينشئ adapter اتصال HTTP جديدًا للمحاولة التالية. ينتهي حق retry الشفاف
بمجرد وصول أي حدث من المزود، بما فيه reasoning أو metadata أو content أو حالة
أداة، لأن إعادة الطلب بعد إخراج مرئي أو stateful قد تكرر النص أو استدعاء الأداة.

يرفع adapter رفض encrypted replay كخطأ typed فقط إذا كان الطلب الفاشل قد حمل
reasoning مشفرًا فعلًا. يسمح runner بمحاولة واحدة، يمسح خلالها مفاتيح الحالة
المحددة للـnamespace والissuer المطابقين، ويحفظ المسح قبل retry. لا يمسح النص أو
عناصر assistant الآمنة أو حالة issuer آخر. إذا تكرر الرفض، يعود الخطأ إلى مصنف
runtime recovery ولا يبدأ fallback جديدًا.

تعيش فروق Responses endpoints في provider policy محلية. حاليًا تعقم policy
الخاصة بـxAI قيم enum التي تحتوي slash داخل tool schemas؛ لا يطبق هذا التحويل
على Codex أو بقية OpenAI-compatible adapters.
