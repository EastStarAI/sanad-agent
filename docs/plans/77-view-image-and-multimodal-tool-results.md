---
title: "Plan 77: View Image and Multimodal Tool Results"
description: "خطة تنفيذ مقفلة لإضافة view_image ونتائج أدوات نصية/صورية آمنة ودائمة ومترجمة حسب بروتوكول المزود."
status: "pending"
priority: "high"
current_gate: "77a1"
reference_grounding: "ready; resolve the owning evidence packet before each child task"
---

# Plan 77: أداة View Image ونتائج الأدوات متعددة الوسائط

## 1. الهدف والحالة

الخطة مقفلة تصميميًا وجاهزة لبدء المهمة `77a1`. التنفيذ ينتج حد أداة typed، وأداة `view_image` محلية آمنة، وترجمة صورية للبروتوكولات التي تدعمها رسميًا، واستعادة لا تعيد فتح الملف بعد اكتمال الأداة.

خارج النطاق: صور رسائل المستخدم من Flutter، thumbnails في timeline، URL/data URI، OCR، batches داخل استدعاء واحد، animated/multi-frame images، تغيير `system_screenshot`، أو اختراع امتداد غير قياسي لـOpenAI Chat.

## 2. القرارات المقفلة

### 2.1 النوع والملكية

- `core/models` يملك `ToolExecutionResult` وكتل `ToolTextBlock` و`ToolImageBlock` لأنها تعبر capabilities وengine وpersistence وadapters.
- `BaseTool.execute` يعيد `Future<ToolExecutionResult>`؛ constructor نصية تحافظ على مخرجات الأدوات الحالية.
- النتيجة تحمل `schemaVersion=1` وblocks مرتبة و`isError` و`errorCode` اختياريًا. لا يوجد `details: Map` مفتوح في v1.
- `displayText` getter حتمي مشتق من text blocks، وليس حقيقة مخزنة مستقلة. كل نتيجة، بما فيها الخطأ، يجب أن تحمل text block غير فارغة.
- `Message` تحمل `toolResult` فقط لرسائل `role=tool`، وتبقي `content=displayText` للتوافق. عند وجود `toolResult` تكون هي authoritative ويجب أن يساوي `content` projection عند الإنشاء/الكتابة.
- الرسائل القديمة ذات `content` فقط تبقى قابلة للقراءة والكتابة دون migration جدولي.

### 2.2 أداة `view_image`

```text
view_image(path, detail=auto)
detail = low | auto | high | original
```

- الأداة workspace-required وread-only و`restart_replay_safe=true`، وتقبل ملفًا محليًا واحدًا.
- المسار النسبي يحل من workspace. الهدف canonical الخارجي يحتاج موافقة `view_image` أو `full_access` قبل قراءة bytes.
- PNG وJPEG وWebP الثابتة فقط؛ magic bytes هي الحقيقة، والامتداد advisory. animated/multi-frame ترفض في v1.
- مكتبة التنفيذ `image: ^4.9.1`. decode/resize/encode تعمل في worker isolate بحد تزامن `2` وtimeout `15s` دون temp files.

### 2.3 سياسة الصور المركزية

| الحد | القيمة |
|---|---:|
| input file bytes | 20 MiB |
| decoded pixels | 40,000,000 |
| hard longest edge | 7,900 px |
| base64 payload per image | 4 MiB ASCII، دون data-URL header |
| rich images per tool batch | 4 |
| aggregate base64 per tool batch | 12 MiB |

| detail | أقصى ضلع | السلوك |
|---|---:|---|
| `low` | 768 px | downscale فقط |
| `auto` | 2,048 px | downscale فقط |
| `high` | 4,096 px | downscale فقط |
| `original` | 7,900 px hard ceiling | يحفظ bytes/MIME الأصلية بعد التحقق، وإلا يفشل بلا resize |

- لا يحدث enlargement.
- `low/auto/high` تحفظ bytes الأصلية إن كانت ضمن البعد والميزانية؛ وإلا تعيد encode إلى JPEG quality 85 للصورة opaque أو PNG compression 6 للصورة ذات alpha.
- إذا بقي payload فوق 4 MiB بعد resize/encode تفشل `too_large`; لا توجد حلقة جودة غير محدودة.
- coordinator يقبل أول أربع صور ضمن 12 MiB حسب ترتيب tool calls؛ أي نتيجة لاحقة تتجاوز الميزانية تصبح typed error `batch_image_budget_exceeded` بلا image block.

### 2.4 البروتوكولات والـfallback

- `LLMAdapter` يعلن capability مغلقة: `textOnly` أو `imageToolResults`، وكل wrapper يفوضها حرفيًا.
- Codex Responses وAnthropic فقط `imageToolResults` في v1. E2E fixture قد تعلنها للاختبار.
- OpenAI-compatible Chat وOllama وcustom وunknown/missing هي `textOnly` في v1؛ لا تعتمد القدرة على model-name أو endpoint probing.
- Responses يستخدم `function_call_output.output` من `input_text`/`input_image`. `original` يرسل wire `detail=high` مع bytes الأصلية.
- Anthropic يستخدم nested text/image blocks داخل `tool_result` ويحافظ على `tool_use_id`; لا يملك wire detail.
- text-only adapter ترسل `displayText` ثم marker واحد: `[Image omitted: active provider does not accept image tool results.]` بلا base64 وبلا mutation للتاريخ.
- fallback degradation محلية وليست network failure، ولا تطلق retry/failover. انتقال failover إلى adapter نصية يطبق projection نفسها على الطلب الجديد.
- تظل `view_image` في catalog متى وجد workspace للحفاظ على ثبات catalog؛ نجاح الرؤية مضمون فقط للمسارات المعلنة `imageToolResults`.

### 2.5 الاستدامة والتقادم

- v1 تخزن base64 inline في `Message.toolResult` داخل JSON الحالي؛ لا blob table أو ملف جانبي.
- checkpoint يستخدم `completed_tool_results_v2` typed حتى يثبت tool Message. `completed_tool_outputs` يبقى text/redacted فقط.
- `SessionExecutionStateCoordinator` يملك transaction إلحاق tool Message وإزالة النسخة الغنية من checkpoint؛ لا تعاد قراءة path بعد اكتمال النتيجة.
- الصور تبقى في current/incomplete tool loop وآخر `3` completed assistant turns.
- بعد حفظ assistant completion: تقلم الصور الأقدم أولًا، ثم الأقدم داخل النافذة إذا تجاوز مجموع rich history `24 MiB` base64، مع حماية current/incomplete loop.
- marker التقليم الثابت: `[image data removed after model processing]`.
- persisted block تالفة تتحول إلى `[image data unavailable: invalid persisted payload]` بلا re-execution.
- events وlogs وplugin notifications وhistory query تعرض text/status فقط. request dump تنقح base64/data URI recursively دون تغيير الطلب الحي.

## 3. ترتيب المهام

```text
77a1 -> 77a2 -> 77a3 -> 77a4 -> 77a5
                                  |
                             +----+----+
                             v         v
                           77b1      77c1
                             |         |
                           77b2      77c2
                             +----+----+
                                  v
                                77d1 -> 77d2 -> 77d3
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
12. [77d3 — Daemon-backed Integration QA](tasks/77d3-view-image-integration-qa.md)

كل مهمة لها سقف ملفات مستقل لا يتجاوز `10`، وتنفذ في worktree مالكة واحدة. لا يعمل فرعان بالتوازي على `Message` أو coordinator أو ملفات الخطة نفسها.

## 4. بوابات القبول الكلية

- [ ] الأدوات النصية تحافظ على النص والأخطاء والـreplay الحالية بعد التحويل typed.
- [ ] `view_image` تظهر فقط مع workspace وتطبق authorization قبل قراءة bytes.
- [ ] PNG/JPEG/WebP ثابتة تعبر السياسة؛ الملفات المخادعة/التالفة/المتحركة/فوق الحدود تفشل محليًا.
- [ ] Responses وAnthropic يريان pixels مع هوية tool call الأصلية.
- [ ] OpenAI Chat/Ollama/custom لا تستقبل binary وتستخدم fallback الحتمية بلا retry.
- [ ] restart بعد tool completion يستخدم snapshot المحفوظة مرة واحدة حتى لو تغير الملف أو حذف.
- [ ] checkpoint/history لا تحتفظان بنسختين غنيتين بعد transaction.
- [ ] logs/events/dumps/history query لا تكشف base64.
- [ ] تقليم 3-turn/24-MiB حتمي ويحمي الجولة غير المكتملة.
- [ ] daemon-backed fixture تجيب عن معلومة موجودة في pixels فقط.
- [ ] analyzer والاختبارات المركزة والـE2E المتسلسلة المطلوبة ناجحة.

## 5. إدارة التقدم

- الحالات: `pending`, `in_progress`, `blocked`, `in_review`, `complete`.
- يحل المنفذ evidence packet الخاصة بعائلة المهمة قبل Gate 0؛ تغير fingerprint يعيدها إلى refresh.
- لا تغلق مهمة بلا تحديث سجل gate والأوامر والملفات والعقود المتأثرة.
- لا تصبح الخطة `complete` قبل إغلاق `77d3` وإثبات الرؤية والاستعادة والتنقيح.

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
Next task:
```
