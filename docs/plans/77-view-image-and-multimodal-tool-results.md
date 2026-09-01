---
title: "Plan 77: View Image, User Attachments, and Multimodal Tool Results"
description: "خطة تنفيذ مقفلة لإضافة view_image، مرفقات المستخدم، عرض الصور في المحادثة، ونتائج أدوات نصية/صورية آمنة محليًا وعن بُعد."
status: "pending"
priority: "high"
current_gate: "77a1"
reference_grounding: "ready; resolve the owning evidence packet before each child task"
---

# Plan 77: View Image ومرفقات المحادثة ونتائج الأدوات متعددة الوسائط

## 1. الهدف والحالة

الخطة جاهزة لبدء `77a1`. التنفيذ ينتج حد أداة typed، وأداة `view_image` محلية آمنة، ومرفقات مستخدم لا تصل bytes الخاصة بها تلقائيًا إلى النموذج، وعرضًا قابلًا للفتح للصور داخل المحادثة، مع تكافؤ محلي/بعيد واستعادة لا تعيد فتح الملف بعد اكتمال الأداة.

يشمل النطاق: لصق الصور، السحب والإفلات، File Picker، زر `+` في يسار الـcomposer بجوار Permission Mode، صور وبطاقات الملفات داخل رسالة المستخدم، استعادة المرفقات في Edit & Retry، ونقل الملفات إلى وكيل بعيد عبر hosted capability متوافقة.

خارج النطاق: إرسال مرفق المستخدم مباشرةً كـprovider image input، URL/data URI من المستخدم، OCR، animated/multi-frame images، recursive remote-folder upload، thumbnails للمجلدات، تغيير `system_screenshot`، أو اختراع امتداد غير قياسي لـOpenAI Chat.

## 2. القرارات المقفلة

### 2.1 نتيجة الأداة والرسائل

- `core/models` يملك `ToolExecutionResult` وكتل `ToolTextBlock` و`ToolImageBlock` لأنها تعبر capabilities وengine وpersistence وadapters.
- `BaseTool.execute` يعيد `Future<ToolExecutionResult>`؛ constructor نصية تحافظ على مخرجات الأدوات الحالية.
- النتيجة تحمل `schemaVersion=1` وblocks مرتبة و`isError` و`errorCode` اختياريًا. كل نتيجة تحمل text block غير فارغة، و`displayText` projection حتمي.
- `Message.toolResult` تخص `role=tool` وتبقى authoritative مع `content=displayText`. الرسائل القديمة text-only تظل قابلة للقراءة بلا migration جدولي.
- رسالة المستخدم تحمل attachments typed مرتبة منفصلة عن النص؛ التاريخ والـEdit يعيدان metadata الآمنة ولا يضعان bytes أو مسارًا خارجيًا مطلقًا في الحدث العام.

### 2.2 أداة `view_image`

```text
view_image(path, detail=auto)
detail = low | auto | high | original
```

- الأداة read-only و`restart_replay_safe=true` وتقبل ملفًا محليًا واحدًا. تظهر عندما توجد Workspace أو مرفقات جلسة معتمدة؛ تغيب فقط عندما لا يوجد أي source scope صالح.
- المسار النسبي يحل من workspace. الهدف canonical الخارجي يحتاج موافقة `view_image` أو `full_access` قبل قراءة bytes، باستثناء attachment path يملكه الوكيل وله grant محدود للجلسة الناتجة من إرفاق المستخدم الصريح.
- PNG وJPEG وWebP الثابتة فقط؛ magic bytes هي الحقيقة. animated/multi-frame ترفض في v1.
- decode/resize/encode تعمل في worker isolate بحد تزامن `2` وtimeout `15s` دون temp files.

### 2.3 سياسة الصور المركزية

| الحد | القيمة |
|---|---:|
| `view_image` source bytes | 20 MiB |
| decoded pixels | 40,000,000 |
| hard longest edge | 7,900 px |
| base64 payload per image | 4 MiB ASCII |
| rich images per tool batch | 4 |
| aggregate base64 per tool batch | 12 MiB |

| detail | أقصى ضلع | السلوك |
|---|---:|---|
| `low` | 768 px | downscale فقط |
| `auto` | 2,048 px | downscale فقط |
| `high` | 4,096 px | downscale فقط |
| `original` | 7,900 px hard ceiling | يحفظ bytes/MIME الأصلية بعد التحقق، وإلا يفشل بلا resize |

- لا يحدث enlargement. `low/auto/high` تحفظ bytes الأصلية إن كانت ضمن الميزانية؛ وإلا تعيد encode إلى JPEG quality 85 للصورة opaque أو PNG compression 6 للصورة ذات alpha.
- payload التي تبقى فوق 4 MiB تفشل `too_large`. coordinator يقبل أول أربع صور ضمن 12 MiB حسب ترتيب tool calls.

### 2.4 مرفقات المستخدم والتخزين

- المدخلات الثلاثة paste وdrag/drop وFile Picker تنتج `DraftAttachment` typed واحدة؛ لا يبني كل مدخل مسارًا مستقلًا.
- زر `+` يظهر في يسار الـcomposer بجوار منتقي Permission Mode، ويفتح File Picker المتاح على المنصة.
- الحد authoritative هو `5 MiB` لكل ملف مهما كان النوع، مع حد `4` ملفات و`20 MiB` إجماليًا في الرسالة. العميل يفشل مبكرًا، والوكيل يعيد التحقق قبل ACK.
- الاسم وMIME المعلن advisory؛ الوكيل ينظف الاسم، يتحقق من الحجم والـhash والمحتوى، ويكتب ذرّيًا إلى attachment store محمي داخل Sanad Home.
- صورة Clipboard بلا path تُmaterialize كمرفق. في الاتصال المحلي يمكن لملف موجود على جهاز الوكيل استخدام canonical path مع grant محدود للمرفق؛ في الاتصال البعيد تصبح bytes أولًا staged attachment على جهاز الوكيل.
- لا تدخل client-local paths في history أو model context البعيد. لا تُقبل رسالة المستخدم حتى يقر الوكيل كل مرفق ويعيد attachment identity/path صالحين.
- المرفق المعتمد يبقى ما دامت رسالة المستخدم موجودة، ويُحذف عند حذف الجلسة أو cleanup orphan حتمي. partial uploads تُحذف بعد cancel/timeout/failure.
- المجلد لا يُرفع recursively في v1. folder reference صالح فقط إذا كان المسار موجودًا أصلًا على جهاز الوكيل وتطبّق عليه workspace/path authorization المعتادة.

### 2.5 ما يراه النموذج

- المرفقات لا تتحول تلقائيًا إلى provider image/file parts.
- النموذج يستقبل نص المستخدم ثم projection محدودة ومرتبة تذكر الاسم والنوع والمسار الموجود على جهاز الوكيل، وتطلب استخدام `view_image` أو أداة الملف/التصفح المناسبة عند الحاجة.
- attachment bytes لا تدخل provider request إلا كنتيجة tool صريحة بعد أن يختار النموذج الأداة.
- text-only provider تطبق fallback الخاصة بنتيجة الأداة، لا fallback على مرفق المستخدم الخام.

### 2.6 تجربة Composer ورسالة المستخدم والتحرير

- attachment rail فوق حقل الكتابة تعرض image thumbnail أو file card مع الاسم والحجم والحالة وزر إزالة.
- حالات المرفق: validating، uploading، ready، failed. Send/Edit Save يتعطلان حتى تصبح جميع المرفقات ready؛ failure تبقي النص والمرفقات في draft مع Retry/Remove.
- user bubble تعرض المرفقات بالترتيب فوق النص: الصور في grid قابلة للفتح، والملفات كبطاقات آمنة. لا تعرض المسار الداخلي.
- الضغط على صورة يفتح Lightbox قابلًا للإغلاق ولوحة المفاتيح وscreen reader. الملف يستخدم preview آمنة إن كانت مدعومة وإلا تنزيلًا مصادقًا عليه.
- Edit يعيد النص والمرفقات الموجودة دون re-upload، ويسمح بالإضافة والإزالة. Cancel يعيد الرسالة الأصلية، وSave & Retry لا يغير التاريخ حتى تنجح المرفقات الجديدة وreplay admission.

### 2.7 حدث `View Image` والوسائط

- tool event يظهر بعنوان `View Image` وأسفله الصورة المصغرة، ثم metadata/status الآمنة عند الحاجة.
- الحدث يحمل `media_id` opaque وMIME والأبعاد واسمًا آمنًا، ولا يحمل base64 أو absolute path أو رابطًا عامًا.
- hydration تبدأ عند اقتراب الحدث من viewport؛ الضغط يفتح الصورة الكاملة في Lightbox.
- local client يجلب media من Local Gateway المصادق. remote client يستخدم hosted media capability مصادقًا عليها ومقيدة بالمستخدم والجهاز والجلسة والغرض والعمر.
- بعد pruning/expiry يبقى الحدث وتظهر `Image no longer available` بدل كسر timeline.

### 2.8 البروتوكولات والـfallback

- `LLMAdapter` يعلن `textOnly` أو `imageToolResults`. Codex Responses وAnthropic فقط `imageToolResults` في v1.
- OpenAI-compatible Chat وOllama وcustom وunknown/missing هي `textOnly`; لا تعتمد القدرة على model-name أو endpoint probing.
- Responses يستخدم `function_call_output.output` من `input_text`/`input_image`. Anthropic يستخدم nested text/image blocks داخل `tool_result`.
- text-only adapter ترسل `displayText` ثم marker واحد: `[Image omitted: active provider does not accept image tool results.]` بلا retry أو mutation للتاريخ.
- hosted attachment/media transport تعلن capability/version؛ client يخفي أو يعطل remote attachment actions عند غيابها ويفشل مغلقًا بدل تضمين bytes في `device_command`.
- تفاصيل تنفيذ hosted service ومكوناته الداخلية تملكها خطة المستودع المغلق فقط؛ هذا المستودع يثبت العقود العامة والـcompatibility behavior.

### 2.9 الاستدامة والتقادم

- tool images تخزن inline في `Message.toolResult` v1؛ attachment files تخزن في agent-owned protected store ويشير user message إلى identity typed.
- `SessionExecutionStateCoordinator` يملك transaction إلحاق tool Message وإزالة النسخة الغنية من checkpoint؛ لا تعاد قراءة path بعد اكتمال النتيجة.
- tool images تبقى في current/incomplete loop وآخر `3` completed assistant turns، ضمن `24 MiB` rich-history cap.
- marker التقليم: `[image data removed after model processing]`. persisted block تالفة تصبح `[image data unavailable: invalid persisted payload]` بلا re-execution.
- logs وevents وplugin notifications وrequest dumps لا تكشف base64 أو attachment bytes أو absolute private paths.

## 3. ترتيب المهام

```text
77a1 -> 77a2 -> 77a3 -> 77a4 -> 77a5
                                  |
                    +-------------+-------------+
                    v                           v
                  77b1                        77c1
                    |                           |
                  77b2                        77c2
                    +-------------+-------------+
                                  v
                    77d1 -> 77d2 -> 77d3
                                  |
                                77e1 -> 77e2 -> 77e3
                                                  |
                                      +-----------+-----------+
                                      v                       v
                                    77f1                    77f3
                                      |                       |
                                    77f2 <--------------------+
                                      |
                                    77g1 -> 77g2
```

### 3.1 Task map

1. [77a1 — Core Result Model](tasks/77a1-core-tool-result-model.md)
2. [77a2 — Text Tool Migration A](tasks/77a2-text-tool-migration-a.md)
3. [77a3 — Text Tool Migration B](tasks/77a3-text-tool-migration-b.md)
4. [77a4 — Text Tool Migration C](tasks/77a4-text-tool-migration-c.md)
5. [77a5 — Coordinator and Message Integration](tasks/77a5-tool-result-coordinator-integration.md)
6. [77b1 — Image Policy Worker](tasks/77b1-image-policy-worker.md)
7. [77b2 — Secure View Image Catalog](tasks/77b2-secure-view-image-catalog.md)
8. [77c1 — Rich Provider Codecs](tasks/77c1-rich-provider-codecs.md)
9. [77c2 — Adapter Capability and Fallback](tasks/77c2-adapter-capability-and-fallback.md)
10. [77d1 — Atomic Result Durability](tasks/77d1-atomic-tool-result-durability.md)
11. [77d2 — Binary Redaction and Pruning](tasks/77d2-binary-redaction-and-pruning.md)
12. [77d3 — Daemon-backed View Image QA](tasks/77d3-view-image-integration-qa.md)
13. [77e1 — Attachment Model and Policy](tasks/77e1-attachment-model-and-policy.md)
14. [77e2 — Agent Attachment Store](tasks/77e2-agent-attachment-store.md)
15. [77e3 — Attachment Admission and Model Projection](tasks/77e3-attachment-admission-and-model-projection.md)
16. [77f1 — Composer Attachment UX](tasks/77f1-composer-attachment-ux.md)
17. [77f2 — User Message Attachment and Edit UX](tasks/77f2-user-message-attachment-edit-ux.md)
18. [77f3 — View Image Timeline Media](tasks/77f3-view-image-timeline-media.md)
19. [77g1 — Local Attachment Integration QA](tasks/77g1-local-attachment-integration-qa.md)
20. [77g2 — Remote Attachment Integration QA](tasks/77g2-remote-attachment-integration-qa.md)

كل مهمة لها سقف ملفات مستقل لا يتجاوز `10`. لا يعمل فرعان بالتوازي على Message أو coordinator أو conversation cache schema أو ملفات الخطة نفسها. `77g2` لا يبدأ قبل اكتمال capability المقابلة واختبارها في المستودع المغلق.

## 4. بوابات القبول الكلية

- [ ] الأدوات النصية تحافظ على النص والأخطاء والـreplay الحالية بعد التحويل typed.
- [ ] `view_image` تطبق authorization قبل قراءة bytes وتعيد نتائج صورية للمزودات المدعومة.
- [ ] زر `+` في يسار composer بجوار Permission Mode يفتح File Picker؛ paste/drop/picker تستخدم pipeline واحدة.
- [ ] أي ملف فوق 5 MiB أو الرسالة فوق 4 ملفات/20 MiB ترفض قبل قبول turn، محليًا وعن بُعد.
- [ ] user bubble وEdit يعرضان attachments بالترتيب، وEdit لا يعيد رفع المرفقات الموجودة.
- [ ] النموذج لا يستقبل attachment bytes تلقائيًا؛ يرى النص ومسارات agent-owned ويقرر الأدوات.
- [ ] remote client path لا يعبر إلى تاريخ الوكيل أو النموذج، والرسالة تنتظر staging ACK.
- [ ] حدث `View Image` يعرض thumbnail قابلة للضغط محليًا وعن بُعد دون base64/path عام.
- [ ] restart يستخدم snapshot المحفوظة مرة واحدة حتى لو تغير المصدر أو حذف.
- [ ] logs/events/dumps/history العامة لا تكشف bytes أو private paths.
- [ ] hosted capability القديمة/الغائبة تفشل مغلقًا دون fallback داخل command JSON.
- [ ] daemon-backed fixtures تثبت pixels، edit، expiry، interruption، وعزل user/device/session.

## 5. إدارة التقدم

- الحالات: `pending`, `in_progress`, `blocked`, `in_review`, `complete`.
- يحل المنفذ evidence packet الخاصة بعائلة المهمة قبل Gate R0؛ `77e*` و`77f*` و`77g*` تستخدم packet `77e` حتى تنشأ packet أضيق.
- لا تغلق مهمة بلا تحديث gate والأوامر والملفات والعقود المتأثرة ونسبة المتبقي.
- لا تصبح الخطة `complete` قبل `77g2` وإثبات التكافؤ المحلي/البعيد والرؤية والاستعادة والتنقيح.

```text
Date:
Task/Gate:
Status transition:
Owner/worktree:
Files changed:
Verification evidence:
Documentation/contracts updated:
Evidence fingerprint:
Open findings:
Remaining estimate:
Next task:
```
