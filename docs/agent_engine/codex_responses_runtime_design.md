---
title: "Codex Responses Runtime Design"
description: "تصميم codec وحالة الاستمرارية والبث والاستكمال لمحول Codex Responses في Sanad."
---

# Codex Responses Runtime Design

## الهدف

يوحّد هذا العقد سلوك `CodexResponsesAdapter` في الطلبات المتزامنة والمتدفقة،
ويفصل النص المرئي عن reasoning القابل للعرض وعن بيانات الاستمرارية opaque.
يستخدم المحول `store: false` مع إعادة عناصر الحالة الضرورية من history بدل
الاعتماد على `previous_response_id`.

## الأساس المشترك

- يحمل `Message.reasoning` ملخص التفكير أو commentary القابل للعرض فقط.
- تحمل `Message.providerState` عناصر reasoning المشفرة وعناصر assistant message
  الآمنة لإعادة الإرسال.
- يحمل `ToolCall.providerState` response item ID الخاص باستدعاء الأداة.
- يُشتق issuer من provider instance ونمط البروتوكول والـendpoint المطبّع.
- يحفظ `AgentRunner` الرسائل state-only وسبب النهاية typed عبر restart.
- إزالة replay state عملية صريحة ولا تستخدم قيمة وهمية.

## اكتشاف النماذج

يختلف catalog الخاص بمسار ChatGPT Codex OAuth عن صيغة OpenAI العامة. يبني
`CodexModelsService` طلب `/models` مع `client_version` وBearer access token، ثم
يقرأ `models[].slug` بدل `data[].id`. يستبعد `visibility` بالقيم `hide` أو
`hidden`، ويرتب النماذج حسب `priority` ثم `slug`، ويزيل التكرار.

تستخدم `ModelOptionsService` و`CodexResponsesAdapter.getAvailableModels()` هذه
الخدمة نفسها حتى تتطابق نتيجة `model.options` مع نتيجة `model.refresh`. تطبق
الخدمة aliases الخاصة بالتوافق الأمامي وفق مرجع Hermes بعد نجاح catalog الحي،
بينما يبقى fallback الثابت مسؤولية provider profile عند فشل الطلب أو التحليل.
يحتفظ model cache كذلك بـ`context_window` التي يعيدها catalog لنفس instance.
عند التنفيذ يمرر `AgentRuntimeService` lookup مرتبطًا بهوية instance ومراجعات
الإعداد والاعتماد إلى المحول؛ لذلك تتقدم نافذة catalog الحية على metadata العامة
دون أي شرط باسم النموذج، مع بقاء override الصريح في `config.yaml` أعلى أولوية.
لا يؤثر هذا العقد في اكتشاف نماذج بقية OpenAI-compatible providers.

## Request codec

ينشئ codec payload واحدًا لمساري sync وstream مع `stream: true` دائمًا لأن
Codex Responses لا يقبل هذا المسار دون البث. يستهلك sync أحداث SSE داخليًا حتى
الحدث النهائي، بينما يصدر stream deltas أثناء التجميع. يرسل الطلب
`store: false`، ويطلب `reasoning.encrypted_content`، ويحوّل `thinkingMode` إلى reasoning
effort، ويمرر `max_output_tokens` عند وجوده.

يعيد codec عناصر reasoning المشفرة فقط عند تطابق namespace وissuer. يستخدم
معرّفات reasoning محليًا لمنع التكرار ثم يحذفها من wire لأن التخزين معطل. يعيد
عناصر assistant message بالحقول الآمنة `id`, `status`, `phase`، ثم استدعاءات
الأدوات ونتائجها بترتيب history. إذا كانت رسالة assistant تحتوي reasoning فقط،
يضيف عنصر assistant فارغًا بعدها للمحافظة على صحة تسلسل Responses items.

قبل الشبكة يتحقق preflight من النموذج والتعليمات وأشكال input ومعرفات الأدوات
ومعاملاتها ونتائجها وتعريفات tools، ويرفض أي شكل غير مدعوم بدل تصحيحه بصمت.

## Response normalizer

يقرأ normalizer كل output items وكل أجزاء النص بالترتيب، ويجمع reasoning summary
المرئي، ويحفظ encrypted reasoning منفصلًا. يحفظ عناصر assistant message الآمنة،
ويحوّل `function_call` و`custom_tool_call` إلى `ToolCall` مع call ID حتمي عند
غيابه وresponse item ID داخل provider state.

تُطبّع usage وحالة response والأخطاء وسبب النهاية. طلب الأدوات له الأولوية،
بينما حالات `queued`, `in_progress`, `incomplete`، وcommentary بلا final answer،
وreasoning-only، وتسرب صيغة tool call كنص تُصنف `incomplete`. حالات
`failed` و`cancelled` تُرفع كأخطاء مزود ولا تُعرض كإجابة ناجحة.

## SSE accumulator

يقرأ parser أسطر SSE مع الاحتفاظ ببقايا network chunks، ويجمع output items
وtext/reasoning deltas وfunction argument deltas وusage والأحداث النهائية.
الأحداث `response.completed`, `response.incomplete`, `response.failed`,
`response.cancelled` هي مصدر الحالة النهائية. تمر النتيجة المجمعة إلى نفس
normalizer المستخدم في sync، وبذلك لا يوجد عقد استجابة ثانٍ لمسار stream.

## الاستكمال والتعافي من replay المرفوض

يملك `ResponseContinuationCoordinator` ميزانية دورية مستقلة عن network retry.
عندما يحفظ `AgentRunner` ردًا بسبب `finishReason.incomplete`، يعيد بناء التاريخ
من الرسالة المحفوظة ويطلب الاستكمال بحد أقصى ثلاث مرات. لا تستهلك tool calls أو
أخطاء النقل هذه الميزانية، وتبقى الاستجابة الأخيرة مصنفة `incomplete` إذا انتهى
الحد دون جواب نهائي. steering المنتظر له الأولوية على الاستكمال التلقائي.

إذا أعاد endpoint خطأ `invalid_encrypted_content`، يحوله adapter إلى
`ProviderStateRejectedException` فقط عندما يثبت payload أن encrypted reasoning
أُعيد إرساله. يسمح المنسق بمحاولة fallback واحدة للدور: يمسح runner مفتاح
`reasoning_items` فقط من الرسائل التي يطابق namespace وissuer فيها الخطأ، ويبقي
`message_items` والنص وحالة issuers الأخرى، ثم يحفظ التاريخ المنقح قبل إعادة
الطلب. أي رفض تالٍ يمر إلى مسار runtime recovery العادي مع خطأ HTTP الأصلي.

توجد فروق endpoints داخل `CodexResponsesPolicy`. تعقيم enum التي تحتوي `/`
يطبق على xAI Responses فقط، بينما يبقى codec وعقد runner مشتركين وغير مرتبطين
بمزود بعينه.

دعم multimodal يحتاج توسيع `Message.content` على مستوى المحرك، ولذلك لا يدخل
ضمن codec النصي الحالي. كما تبقى أدوات المزود المدمجة خارج العقد العام حتى
تضاف عبر policy مستقلة واختبارات wire خاصة بها.
