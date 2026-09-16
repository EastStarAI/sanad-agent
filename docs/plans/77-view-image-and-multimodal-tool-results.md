---
title: "Plan 77: View Image, User Attachments, and Multimodal Tool Results"
description: "خطة تنفيذ مقفلة لإضافة view_image، مرفقات المستخدم، عرض الصور في المحادثة، ونتائج أدوات نصية/صورية آمنة محليًا وعن بُعد."
status: "in_progress"
priority: "high"
current_gate: "hosted-relay/G0"
remaining_estimate: "2%"
active_worktree: "77-hosted-attachment-media-relay"
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

## 3. طريقة التنفيذ المعتمدة

- ينفذ العمل كاملًا داخل Worktree `77-hosted-attachment-media-relay` فقط، مع بقاء فرع المستودع العام داخل الـsubmodule وفرع المستودع الخاص متطابقين مع سجل التقدم.
- تنفذ المهام بترتيب Task map أدناه دون فتح مسارات تنفيذ متوازية. داخل كل مهمة تنفذ البوابات بالترتيب المكتوب، ولا تبدأ بوابة قبل إغلاق سابقتها بالأدلة المطلوبة.
- عند إغلاق كل بوابة: تحدّث checklist و`current_gate` وسجل الأدلة ونسبة المتبقي داخل ملف المهمة نفسه قبل متابعة البوابة التالية.
- عند إغلاق كل مهمة: تحدّث حالتها إلى `complete`، ثم تحدّث checklist و`current_gate` و`remaining_estimate` وسجل التقدم في هذه الخطة، وتشغّل تحقق المهمة كاملًا، ثم تنشئ commit مركزًا وتدفع فرع المستودع المالك قبل الانتقال للمهمة التالية.
- إذا غيّرت مهمة عامة gitlink المستودع العام، يثبّت المستودع الخاص ذلك المؤشر في commit مركز ويدفع فرعه؛ لا تنشأ PR أثناء التنفيذ.
- تنفذ بوابات مهمة hosted relay الخاصة `G0` إلى `G6` بالترتيب بعد `77g1` وقبل بدء `77g2`، لأن `77g2` بوابة التكافؤ البعيد ولا يمكن إغلاقها قبل اكتمال capability الخاصة.
- بعد اكتمال جميع المهام والبوابات الآلية، ينفذ الاختبار التفاعلي النهائي محليًا وعن بُعد وتوثق أدلته. إنشاء PR مؤجل حتى اكتمال الخطة كلها ونجاح هذا الاختبار.
- أي عائق يغيّر الحالة إلى `blocked` في ملف المهمة والخطة مع السبب والأثر ونسبة المتبقي؛ لا يُتجاوز ترتيب التنفيذ بصمت.

## 4. ترتيب المهام

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

### 4.1 Task map

1. [x] [77a1 — Core Result Model](tasks/77a1-core-tool-result-model.md)
2. [x] [77a2 — Text Tool Migration A](tasks/77a2-text-tool-migration-a.md)
3. [x] [77a3 — Text Tool Migration B](tasks/77a3-text-tool-migration-b.md)
4. [x] [77a4 — Text Tool Migration C](tasks/77a4-text-tool-migration-c.md)
5. [x] [77a5 — Coordinator and Message Integration](tasks/77a5-tool-result-coordinator-integration.md)
6. [x] [77b1 — Image Policy Worker](tasks/77b1-image-policy-worker.md)
7. [x] [77b2 — Secure View Image Catalog](tasks/77b2-secure-view-image-catalog.md)
8. [x] [77c1 — Rich Provider Codecs](tasks/77c1-rich-provider-codecs.md)
9. [x] [77c2 — Adapter Capability and Fallback](tasks/77c2-adapter-capability-and-fallback.md)
10. [x] [77d1 — Atomic Result Durability](tasks/77d1-atomic-tool-result-durability.md)
11. [x] [77d2 — Binary Redaction and Pruning](tasks/77d2-binary-redaction-and-pruning.md)
12. [x] [77d3 — Daemon-backed View Image QA](tasks/77d3-view-image-integration-qa.md)
13. [x] [77e1 — Attachment Model and Policy](tasks/77e1-attachment-model-and-policy.md)
14. [x] [77e2 — Agent Attachment Store](tasks/77e2-agent-attachment-store.md)
15. [x] [77e3 — Attachment Admission and Model Projection](tasks/77e3-attachment-admission-and-model-projection.md)
16. [x] [77f1 — Composer Attachment UX](tasks/77f1-composer-attachment-ux.md)
17. [x] [77f2 — User Message Attachment and Edit UX](tasks/77f2-user-message-attachment-edit-ux.md)
18. [x] [77f3 — View Image Timeline Media](tasks/77f3-view-image-timeline-media.md)
19. [x] [77g1 — Local Attachment Integration QA](tasks/77g1-local-attachment-integration-qa.md)
20. [ ] [77g2 — Remote Attachment Integration QA](tasks/77g2-remote-attachment-integration-qa.md)

كل مهمة لها سقف ملفات مستقل لا يتجاوز `10`. لا يعمل فرعان بالتوازي على Message أو coordinator أو conversation cache schema أو ملفات الخطة نفسها. `77g2` لا يبدأ قبل اكتمال capability المقابلة واختبارها في المستودع المغلق.

## 5. بوابات القبول الكلية

- [ ] الأدوات النصية تحافظ على النص والأخطاء والـreplay الحالية بعد التحويل typed.
- [ ] `view_image` تطبق authorization قبل قراءة bytes وتعيد نتائج صورية للمزودات المدعومة.
- [ ] زر `+` في يسار composer بجوار Permission Mode يفتح File Picker؛ paste/drop/picker تستخدم pipeline واحدة.
- [ ] أي ملف فوق 5 MiB أو الرسالة فوق 4 ملفات/20 MiB ترفض قبل قبول turn، محليًا وعن بُعد.
- [x] user bubble وEdit يعرضان attachments بالترتيب، وEdit لا يعيد رفع المرفقات الموجودة.
- [ ] النموذج لا يستقبل attachment bytes تلقائيًا؛ يرى النص ومسارات agent-owned ويقرر الأدوات.
- [ ] remote client path لا يعبر إلى تاريخ الوكيل أو النموذج، والرسالة تنتظر staging ACK.
- [ ] حدث `View Image` يعرض thumbnail قابلة للضغط محليًا وعن بُعد دون base64/path عام.
- [ ] restart يستخدم snapshot المحفوظة مرة واحدة حتى لو تغير المصدر أو حذف.
- [ ] logs/events/dumps/history العامة لا تكشف bytes أو private paths.
- [ ] hosted capability القديمة/الغائبة تفشل مغلقًا دون fallback داخل command JSON.
- [ ] daemon-backed fixtures تثبت pixels، edit، expiry، interruption، وعزل user/device/session.

## 6. إدارة التقدم

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

### 2026-09-14 — 77a1 complete

- Task/Gate: `77a1/A3`.
- Status transition: `77a1 in_progress` → `complete`; plan advances to `77a2/R0`.
- Owner/worktree: public repository in `77-hosted-attachment-media-relay`.
- Files changed: core result/message models, generated JSON, public export, focused tests, owning contract/design, task, and plan.
- Verification evidence: build runner passed; analyzer clean; 13 focused tests passed; legacy model regression included in the earlier 18-test gate; Graphify rebuilt.
- Documentation/contracts updated: `agent/lib/core/AGENTS.md`, technical multimodal design, task 77a1, and this plan.
- Evidence fingerprint: `sha256:477c6a964da28b0914da3cb0f52881421561ccd9f8afd859fc6833380353bc43`; post-implementation parity satisfied.
- Open findings: none blocking.
- Remaining estimate: `95%`.
- Next task: `77a2 — Text Tool Migration A`.

### 2026-09-14 — 77a2 complete

- Task/Gate: `77a2/A3`.
- Status transition: `77a2 in_progress` → `complete`; plan advances to `77a3/R0`.
- Owner/worktree: public repository in `77-hosted-attachment-media-relay`.
- Files changed: transitional base boundary, four migrated tools, two focused test files, capability-tools contract, task, and plan.
- Verification evidence: analyzer clean; 11 focused tests and 8 existing evolution regressions passed; Graphify rebuilt.
- Documentation/contracts updated: capability-tools contract, task 77a2, and this plan.
- Evidence fingerprint: `sha256:477c6a964da28b0914da3cb0f52881421561ccd9f8afd859fc6833380353bc43`; post-implementation parity satisfied.
- Open findings: bridge removal remains intentionally owned by `77a5`.
- Remaining estimate: `90%`.
- Next task: `77a3 — Text Tool Migration B`.

### 2026-09-14 — 77a3 complete

- Task/Gate: `77a3/A3`.
- Status transition: `77a3 in_progress` → `complete`; plan advances to `77a4/R0`.
- Owner/worktree: public repository in `77-hosted-attachment-media-relay`.
- Files changed: five workspace handlers, focused typed-result test, capability-runtime contract, task, and plan.
- Verification evidence: analyzer clean; 39 workspace/runtime tests passed; Graphify rebuilt.
- Documentation/contracts updated: runtime contract, task 77a3, and this plan.
- Evidence fingerprint: `sha256:477c6a964da28b0914da3cb0f52881421561ccd9f8afd859fc6833380353bc43`; post-implementation parity satisfied.
- Open findings: none; catalog callback cutover remains outside this scoped batch.
- Remaining estimate: `84%`.
- Next task: `77a4 — Text Tool Migration C`.

### 2026-09-14 — 77a4 complete

- Task/Gate: `77a4/A3`.
- Status transition: `77a4 in_progress` → `complete`; plan advances to `77a5/R0`.
- Owner/worktree: public repository in `77-hosted-attachment-media-relay`.
- Files changed: four system tools, callback boundary, two focused test files, capability-tools contract, task, and plan.
- Verification evidence: analyzer clean; 28 tests passed with 2 platform-specific skips; Graphify rebuilt.
- Documentation/contracts updated: tools contract, task 77a4, and this plan.
- Evidence fingerprint: `sha256:477c6a964da28b0914da3cb0f52881421561ccd9f8afd859fc6833380353bc43`; post-implementation parity satisfied.
- Open findings: rich callback protocol cutover remains explicitly outside this task; MCP/platform protocols are unchanged.
- Remaining estimate: `78%`.
- Next task: `77a5 — Coordinator and Message Integration`.

### 2026-09-14 — 77a5 complete

- Task/Gate: `77a5/A3`.
- Status transition: `77a5 in_progress` → `complete`; plan advances to `77b1/R0`.
- Owner/worktree: public repository in `77-hosted-attachment-media-relay`.
- Files changed: base boundary, coordinator, runner callback/history integration, three focused test files, two owning contracts, task, and plan.
- Verification evidence: analyzer clean; 210 tests passed with 5 platform-specific skips; Graphify rebuilt.
- Documentation/contracts updated: capability-tools contract, engine-runtime contract, task 77a5, and this plan.
- Evidence fingerprint: `sha256:477c6a964da28b0914da3cb0f52881421561ccd9f8afd859fc6833380353bc43`; post-implementation parity satisfied.
- Open findings: concrete text projections remain for non-engine compatibility; engine execution is typed and missing typed implementations fail closed.
- Remaining estimate: `70%`.
- Next task: `77b1 — Image Policy Worker`.

### 2026-09-14 — 77b1 complete

- Task/Gate: `77b1/B3`.
- Status transition: `77b1 in_progress` → `complete`; plan advances to `77b2/R0`.
- Owner/worktree: public repository in `77-hosted-attachment-media-relay`.
- Files changed: dependency/lock, central image policy, isolate worker, two focused test files, capability contract, technical design, task, and plan (10 tracked paths).
- Verification evidence: analyzer clean; 8 focused tests passed; Graphify rebuilt.
- Documentation/contracts updated: capabilities contract, multimodal technical design, task 77b1, and this plan.
- Evidence fingerprint: `sha256:649b8758bdef850c34646defccb7fa1e87a55791873bc7337d05502b564761ad`; post-implementation parity satisfied without deviation.
- Open findings: none; path authorization remains intentionally owned by `77b2`.
- Remaining estimate: `65%`.
- Next task: `77b2 — Secure View Image Catalog`.

### 2026-09-14 — 77b2 complete

- Task/Gate: `77b2/B3`.
- Status transition: `77b2 in_progress` → `complete`; plan advances to `77c1/R0`.
- Owner/worktree: public repository in `77-hosted-attachment-media-relay`.
- Files changed: runtime catalog, secure image handler, two focused test files, capability contract, technical design, QA guide, task, and plan (9 tracked paths).
- Verification evidence: analyzer clean; 30 focused catalog/handler/permission tests passed; Graphify rebuilt.
- Documentation/contracts updated: capabilities contract, multimodal design, View Image QA, task 77b2, and this plan.
- Evidence fingerprint: `sha256:649b8758bdef850c34646defccb7fa1e87a55791873bc7337d05502b564761ad`; post-implementation parity satisfied without deviation.
- Open findings: daemon attachment storage will supply the session resolver in `77e2`; its default is an empty fail-closed scope.
- Remaining estimate: `60%`.
- Next task: `77c1 — Rich Provider Codecs`.

### 2026-09-14 — 77c1 complete

- Task/Gate: `77c1/C3`.
- Status transition: `77c1 in_progress` → `complete`; plan advances to `77c2/R0`.
- Owner/worktree: public repository in `77-hosted-attachment-media-relay`.
- Files changed: shared rich-result wire codec, Responses and Anthropic adapters, two focused request-capture test files, adapter contract, technical design, task, and plan (9 tracked paths).
- Verification evidence: analyzer clean; 61 focused adapter tests passed; exact sync/stream captures passed; Graphify rebuilt 23,656 nodes and 32,536 edges.
- Documentation/contracts updated: adapter contract, multimodal technical design, task 77c1, this plan, and ignored run evidence.
- Evidence fingerprint: `sha256:2af004c77e76f850df9ab9b0abe23409cdcf470ecd3831c08cfc62c66823f85c`; post-implementation parity satisfied without deviation.
- Open findings: none; text-only capability/fallback projection remains intentionally owned by `77c2`.
- Remaining estimate: `57%`.
- Next task: `77c2 — Adapter Capability and Fallback`.

### 2026-09-14 — 77c2 complete

- Task/Gate: `77c2/C3`.
- Status transition: `77c2 in_progress` → `complete`; plan advances to `77d1/R0`.
- Owner/worktree: public repository in `77-hosted-attachment-media-relay`.
- Files changed: closed media-capability contract and fallback projection, two rich adapters, configurable E2E fixture, delegating rate-limit wrapper, OpenAI-compatible request builder, focused adapter test, adapter contract, task, and plan (10 tracked paths).
- Verification evidence: analyzer clean; 51 adapter-directory tests passed; rich-to-text sync/stream route captures proved identity, one marker, no base64, and immutable canonical history; Graphify rebuilt 23,673 nodes and 32,575 edges.
- Documentation/contracts updated: adapter contract, task 77c2, this plan, and ignored parity evidence; the owning multimodal design already specified the implemented locked behavior without change.
- Evidence fingerprint: `sha256:2af004c77e76f850df9ab9b0abe23409cdcf470ecd3831c08cfc62c66823f85c`; post-implementation parity satisfied without deviation.
- Open findings: none.
- Remaining estimate: `54%`.
- Next task: `77d1 — Atomic Result Durability`.

### 2026-09-14 — 77d1 complete

- Task/Gate: `77d1/D3`.
- Status transition: `77d1 in_progress` → `complete`; plan advances to `77d2/R0`.
- Owner/worktree: public repository in `77-hosted-attachment-media-relay`.
- Files changed: typed v2 checkpoint schema/restore, tool execution integration, atomic evolution promotion, two focused test files, two leaf contracts, owning technical design, task, and plan (`10/10` tracked paths).
- Verification evidence: analyzer clean; 6 required tests, 13 restart-checkpoint tests, and 71 AgentRunner tests passed; changed/deleted source, stale owner, corrupt payload, legacy text, redacted output, and crash-before/after exactly-once behavior covered; Graphify rebuilt 23,712 nodes and 32,639 edges.
- Documentation/contracts updated: engine-runtime and evolution-runtime contracts, owning multimodal design, task 77d1, this plan, and ignored post-implementation parity record.
- Evidence fingerprint: `sha256:986ef702424054d5e8f905701deab8ea3d55ac84846bd4ed1f8deb1d2b66bf5d`; post-implementation parity satisfied without deviation.
- Open findings: none.
- Remaining estimate: `50%`.
- Next task: `77d2 — Binary Redaction and Pruning`, gate `R0`.

### 2026-09-15 — 77d2 complete

- Task/Gate: `77d2/D3`.
- Status transition: `77d2 in_progress` → `complete`; plan advances to `77d3/R0`.
- Owner/worktree: public repository in `77-hosted-attachment-media-relay`.
- Files changed: deep-copy request-dump sanitation, pure completed-turn image pruner, runner/plugin integration, focused dumper/pruner tests, engine contract, owning technical design and QA matrix, task, and plan (`10/10` tracked paths).
- Verification evidence: analyzer clean; 18 focused engine tests and 430 sequential interface tests passed; three-turn/24-MiB/current-loop/idempotency and typed-image/data-URI/raw-base64/non-mutation obligations covered; Graphify rebuilt 23,742 nodes and 32,676 edges.
- Two unrelated Local Gateway timing flakes seen in earlier broad attempts passed individually and disappeared in the complete sequential interface run.
- Evidence fingerprint: `sha256:986ef702424054d5e8f905701deab8ea3d55ac84846bd4ed1f8deb1d2b66bf5d`; post-implementation parity satisfied without deviation.
- Open findings: none.
- Remaining estimate: `45%`.
- Next task: `77d3 — Daemon-backed View Image QA`, gate `R0`.

### 2026-09-15 — 77d3 complete

- Task/Gate: `77d3/D3`.
- Status transition: `77d3 in_progress` → `complete`; plan advances to `77e1/R0` and remains open for attachments plus hosted relay.
- Owner/worktree: public repository in `77-hosted-attachment-media-relay`.
- Files changed: deterministic rich/text fixture route, daemon E2E, lifecycle/history path redaction, engine contract, owning technical design and QA matrix, task, and plan (`10/10` tracked paths).
- Verification evidence: analyzer clean; 894 capabilities/engine/interfaces tests passed with 5 skips; 4 sequential daemon E2E scenarios passed; Graphify rebuilt 23,798 nodes and 32,753 edges.
- Daemon proof covers pixel-derived answer, external deny/allow/full-access, text fallback, controlled restart after completed result, source deletion, one stable tool identity, and binary-free captures.
- Evidence fingerprint: `sha256:986ef702424054d5e8f905701deab8ea3d55ac84846bd4ed1f8deb1d2b66bf5d`; post-implementation parity satisfied without deviation.
- Open findings: none.
- Remaining estimate: `40%`.
- Next task: `77e1 — Attachment Model and Policy`, gate `R0`.

### 2026-09-15 — 77e1 complete

- Task/Gate: `77e1/G3`.
- Status transition: `77e1 in_progress` → `complete`; plan advances to `77e2/R0`.
- Owner/worktree: public repository in `77-hosted-attachment-media-relay`.
- Files changed: canonical attachment schema/policy, Message JSON integration, public export, focused tests, core contract, technical design, QA matrix, task, and plan (`10/10` tracked paths).
- Verification evidence: build runner passed; analyzer clean; 1,364 core/capabilities/engine/interfaces tests passed with 13 skips; Graphify rebuilt 23,845 nodes and 32,808 edges.
- Public projection preserves ordered safe metadata without Agent-local references or binary; limits are centrally locked at 5 MiB/file, 4 files, and 20 MiB/message.
- Evidence fingerprint: `sha256:1f92463d390f35c6731087bc335672a612766e50a396b08131ba380c2557750a`; post-implementation parity satisfied without deviation.
- Open findings: none.
- Remaining estimate: `35%`.
- Next task: `77e2 — Agent Attachment Store`, gate `R0`.

### 2026-09-15 — 77e2 complete

- Task/Gate: `77e2/G3`.
- Status transition: `77e2 in_progress` → `complete`; plan advances to `77e3/R0`.
- Owner/worktree: public repository in `77-hosted-attachment-media-relay`.
- Files changed: private attachment store/repository, state schema, DI and session deletion integration, focused tests, evolution contract, technical design, QA matrix, task, and plan (`10/10` tracked paths).
- Verification evidence: analyzer clean; 653 evolution/interfaces tests passed; Graphify rebuilt 23,900 nodes and 32,891 edges.
- Exact-session grants, receiver-verified content, owner-only staging/promotion, durable message ownership, and idempotent partial/orphan/session cleanup passed.
- Evidence fingerprint: `sha256:1f92463d390f35c6731087bc335672a612766e50a396b08131ba380c2557750a`; post-implementation parity satisfied without deviation.
- Open findings: none.
- Remaining estimate: `30%`.
- Next task: `77e3 — Attachment Admission and Model Projection`, gate `R0`.

### 2026-09-15 — 77e3 complete

- Task/Gate: `77e3/G3`; status advances to `77f1/R0`.
- Implemented two-phase staged/attached ownership, atomic user-message claim, ordered canonical IDs, deterministic provider-only path projection, attachment-scoped tool paths, capability publication, migration, and restart-safe staged recovery.
- Verification: analyzer clean; focused suite 9/9 plus AgentRunner replay 1/1; Graphify 23,923 nodes and 32,930 edges; reference parity clean.
- File budget: `10/10`; hosted execution proof remains in its required later gates, not bypassed.
- Remaining estimate: `24%`.
- Next task: `77f1 — Composer Attachment UX`, gate `R0`.

### 2026-09-15 — 77f1 G1 complete

- Task/Gate: `77f1/G1`; plan advances to `77f1/G2`.
- Added capability-gated picker, image-paste, and desktop-drop entry points through one transient draft controller while preserving focus and ordinary text paste.
- Focused analyzer found no errors; the sole import-info finding was removed before advancing.
- Remaining estimate: `22%`.
- Next gate: `77f1/G2 — Rail and state`.

### 2026-09-15 — 77f1 G2 complete

- Task/Gate: `77f1/G2`; plan advances to `77f1/G3`.
- Added responsive draft cards, lifecycle/retry/remove controls, ready-gated sending, and device/session-isolated restoration without an optimistic sent row.
- Verification: Client analyzer clean; focused controller 35/35 and composer regression 19/19 passed.
- Remaining estimate: `21%`.
- Next gate: `77f1/G3 — Tests and visual proof`.

### 2026-09-15 — 77f1 complete

- Task/Gate: `77f1/G3`; plan advances to `77f2/R0`.
- Delivered capability-gated picker/paste/drop admission, device/session-scoped immutable drafts, responsive lifecycle rail, ready-gated send, retry/remove, and an injectable picker test boundary.
- Verification: analyzer clean; focused composer 20/20; full Client fast suite 1,155/1,155; visible isolated Flutter runtime; Graphify 23,969 nodes/32,999 edges/864 communities; reference parity satisfied.
- File budget: `10/10`; open findings: none.
- Remaining estimate: `20%`.
- Next task: `77f2`, gate `R0`.

### 2026-09-15 — 77f3 R0 complete

- Task/Gate: `77f3/R0`; dependency-correct execution advances to `77f3/G1` before `77f2`.
- Packet `77e` resolved at the pinned fingerprint. The public media projection is binary/path/credential-free and retrieval is exact-scope authenticated before byte access.
- Local retrieval is owned by the authenticated loopback Gateway; hosted retrieval remains capability-gated for the later private relay gates. Client hydration is bounded, cancellable, and degrades to a stable unavailable state.
- Remaining estimate: `19%`.
- Next gate: `77f3/G1 — Agent projection and retrieval`.

### 2026-09-15 — 77f3 G1 complete

- Task/Gate: `77f3/G1`; plan advances to `77f3/G2`.
- Live/history projection now derives one opaque media identity without another durable image copy. The authenticated Local Gateway resolves bytes from exact session history and supports safe partial responses.
- Wrong device/session admission returns no bytes; public JSON contains metadata only. Focused analyzer clean and Local Gateway suite 22/22 passed sequentially.
- Remaining estimate: `18%`.
- Next gate: `77f3/G2 — Client rendering`.

### 2026-09-15 — 77f3 G2 complete

- Task/Gate: `77f3/G2`; plan advances to `77f3/G3`.
- Client live/history mapping now preserves one validated View Image media model. Local hydration is repository-owned, authenticated, bounded, coalesced, and cancellable; the timeline supplies stable unavailable/thumbnail states and an accessible Lightbox.
- Focused Client analyzer clean and mapper/repository/widget suite 14/14 passed; exceptional budget is 15/15 tracked files.
- Remaining estimate: `17%`.
- Next gate: `77f3/G3 — Tests`.

### 2026-09-16 — 77f3 complete

- Task/Gate: `77f3/G3`; task is complete and the dependency-correct plan returns to `77f2/R0`.
- Agent exposes binary-free live/history metadata and authenticated exact-scope local retrieval without a second durable media copy. Client renders bounded thumbnails/unavailable state and an accessible Lightbox through a cancellable bounded repository.
- Verification: both analyzers clean; Agent changed-path suites `22/22` and `43/43`; Client focused `14/14` and full `1,159/1,159`; visible isolated macOS build; Graphify `24,059 / 33,140 / 849`; reference parity recorded. The unrelated failing Agent monolith baseline is documented in the task/evidence and is not claimed green.
- Remaining estimate: `16%`.
- Next task: `77f2`, gate `R0`.

### 2026-09-16 — 77f2 R0 complete

- Task/Gate: `77f2/R0`; plan advances to `77f2/G1`.
- Packet `77e` was revalidated at the locked fingerprint/revisions. Cache/edit review confirms no current typed user-attachment Client projection and locks safe metadata-only cache plus a distinct transient edit owner that cannot mutate canonical history before replay acceptance.
- Required evidence run records Adopt/Adapt/Reject decisions and the exact domain/cache/edit gaps.
- Remaining estimate: `15%`.
- Next gate: `77f2/G1 — Timeline projection`.

### 2026-09-16 — 77f2 complete

- Task/Gate: `77f2/G3`; task is complete and the plan advances to `77g1/R0`.
- Delivered strict binary-free live/history/cache attachment projection, authenticated exact-scope media retrieval with integrity revalidation, responsive image/file/unavailable rendering, accessible Lightbox and bounded preview/save flow, plus isolated inline attachment editing.
- Existing references hydrate without Client transfer and are cloned inside the Agent into distinct replay ownership; new bytes stay in the private authenticated replay command. Failed staging removes only unclaimed replacement payloads, and canonical history remains unchanged until acceptance.
- Verification: full Agent and Client analyzers clean; Agent Local Gateway `23/23`, replay `18/18`, store `9/9`; Client focused widgets `42/42`; visible isolated macOS build; Graphify `24,152 / 33,294 / 842`; `git diff --check` clean.
- Documentation/contracts updated: Agent Gateway contract, Client conversations contract, multimodal technical design, task, plan, and evidence run. File budget: `25/25`; open findings: none blocking.
- Evidence fingerprint: `sha256:1f92463d390f35c6731087bc335672a612766e50a396b08131ba380c2557750a`; post-implementation decisions remain aligned.
- Remaining estimate: `8%`.
- Next task: `77g1 — Local Attachment Integration QA`, gate `R0`.

### 2026-09-16 — 77g1 R0 complete

- Task/Gate: `77g1/R0`; plan advances to `77g1/G1`.
- Packet `77e` and pinned revisions were revalidated. The scenario adopts the existing isolated daemon/provider fixture and authenticated Local Gateway helper, with runtime-generated opaque image/text/boundary/interruption fixtures only.
- The mandatory proof sequence is locked: attachment ACK before sent state, binary-free provider input before tool choice, explicit `view_image`, pixel-derived answer, and binary/path-free public captures.
- Evidence run: `refrence_projects/.sanad-evidence/runs/77g1-reference-grounding-2026-09-16.md`.
- Remaining estimate: `6%`.
- Next gate: `77g1/G1 — Happy paths`.

### 2026-09-16 — 77g1 complete

- Task/Gate: `77g1/G3`; local integration QA is complete and the plan advances to private hosted relay `G0` before `77g2`.
- Delivered the previously missing initial attachment admission path: authenticated ACK precedes `think`, the same request owns atomic claim, failures retain Client drafts and remove staging, and unscoped turns receive an immediate exact-file `view_image` grant.
- Deterministic daemon proof derives `PIXELS_MAGENTA` from admitted pixels while provider input and public frames remain byte/base64/path-free. Paste, picker, and drop converge on the same ordered Client path.
- Verification: analyzers clean; daemon E2E `6/6`; Agent focused `38/38`, Gateway `23/23 + 16/16`; Client focused `116/116`; visible isolated macOS build; Graphify `24,182 / 33,342 / 874`; documentation and evidence complete.
- The user removed the task file ceiling after lifecycle fixes consumed the prior allowance; no safety coverage or mandatory contract documentation was dropped.
- Remaining estimate: `2%`.
- Next gate: private hosted attachment relay `G0`.
