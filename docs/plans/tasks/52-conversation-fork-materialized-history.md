---
title: "Task 52: Conversation Fork with Materialized History"
description: "إنشاء fork مستقل من أي final answer دائمة عبر نسخ ذري لتاريخ المحادثة حتى نقطة الاختيار مع lineage وتسمية متسلسلة."
status: "completed"
current_gate: "complete"
review_remaining: "0%"
priority: "high"
scope: "Sanad agent session persistence/protocol and Flutter conversation timeline/navigation"
depends_on: "Task 51 stable message/turn identity and active-history contract, Task 35 terminal-state consistency"
coordinates_with: "Task 47 session history pagination, Task 44 background session titles"
---

# Task 52: Conversation Fork with Materialized History

## 1. المشكلة

يحتاج المستخدم إلى بدء مسار جديد من إجابة نهائية سابقة دون تغيير المحادثة
الأصلية. يجب ألا يعتمد fork على الرسائل المحملة حاليًا في Flutter أو ينسخ
الرسالة المختارة وحدها، وألا يعيد تنفيذ tools حدثت قبل نقطة الفرع.

المعمارية المعتمدة هي **materialized copy**: ينشئ daemon جلسة جديدة وينسخ
السجلات النشطة من بداية المصدر حتى `final answer` المختارة داخل معاملة واحدة.
لا تستخدم الجلسة الجديدة message rows مشتركة مع الأصل، وتبقى الجلستان مستقلتين
تمامًا بعد نجاح العملية.

## 2. الهدف

1. إظهار زر `Fork` أسفل كل `final answer` دائمة وقابلة للتحديد بهوية ثابتة.
2. إنشاء جلسة جديدة من كامل prefix حتى الإجابة المختارة، شاملًا reasoning،
   tool calls/results، metadata، وprovider state اللازم لاستكمال السياق.
3. تنفيذ إنشاء الجلسة والنسخ وتخصيص اسم الفرع داخل معاملة DB واحدة بلا جلسة
   جزئية أو نسخ best-effort.
4. إبقاء الجلسة الأصلية قابلة للاستمرار وعدم تعديل رسائلها أو حالتها.
5. فتح الجلسة الجديدة مباشرة أمام المستخدم بعد نجاح daemon، مع استقلال كامل
   لكل الرسائل والجولات اللاحقة.
6. حفظ lineage ونقطة fork مع بقاء الفرع صالحًا إذا حُذفت الجلسة الأصلية.
7. إظهار حدث `Conversation forked` في نهاية timeline للفرع بنفس شكل حدث
   compaction، دون إدخاله ضمن رسائل النموذج أو إرساله إلى LLM.
8. وضع الفرع الجديد أعلى قائمة المحادثات، وفتحه مباشرة، ثم تمرير timeline إلى
   الأسفل بعد hydration حتى يكون حدث fork ظاهرًا للمستخدم.

## 3. قرارات التصميم الملزمة

### 3.1 نقطة الـFork

- الهدف يجب أن يكون canonical `final_answer` دائمة، terminal، ونشطة، وتحمل
  `message_id + turn_id` ثابتين.
- يرسل client هوية الهدف فقط؛ daemon يقرأ prefix من قاعدة البيانات ولا يثق
  بقائمة الرسائل المحملة أو paginated في الواجهة.
- يشمل prefix كل السجلات النشطة من بداية الجلسة حتى نهاية الـturn المالكة
  للإجابة المحددة inclusive، وليس final answer وحدها.
- لا تُنسخ queued inputs أو pending steers أو execution snapshots أو partial
  events الواقعة بعد الإجابة المختارة.
- إذا لم تعد الإجابة نشطة أو لم تكن terminal، يفشل الأمر بنتيجة typed دون
  إنشاء جلسة.

### 3.2 نموذج التخزين والاستقلال

- ينشئ fork صف session جديدًا وصفوف messages جديدة بهويات جديدة.
- تحتفظ الرسائل المنسوخة بهويتها الأصلية في حقل lineage اختياري مثل
  `origin_message_id`، لكن لا تشارك الصف نفسه مع المصدر.
- تحفظ النسخة content، roles، tool identity/pairs، reasoning، finish state،
  provider state، metadata، وترتيب العرض/السياق بصورة lossless.
- يبدأ الفرع في حالة `idle` بلا active run أو work item أو queue من المصدر.
- تنفذ العملية بمعاملة واحدة ويفضل نسخ DB-native set-based؛ أي فشل يعيد rollback
  للجلسة والرسائل والاسم معًا.
- لا يعاد تنفيذ أي tool أثناء الإنشاء؛ المنسوخ هو التاريخ الدائم فقط.

### 3.3 Lineage والحذف

- لكل شجرة فروع `lineage_id` ثابت مستقل عن عمر أي session row.
- تحفظ الجلسة الجديدة `parent_session_id`, `forked_from_message_id`,
  `forked_from_turn_id`, و`fork_sequence`.
- حذف الأصل لا يحذف الفروع ولا رسائلها؛ علاقة الأب تستخدم `SET NULL` أو عقدًا
  مكافئًا، بينما يبقى `lineage_id` وبيانات نقطة الفرع محفوظين.
- حذف فرع لا يؤثر على الأصل أو الأشقاء أو عداد lineage المستخدم سابقًا.

### 3.4 التسمية

- اسم أول fork هو `(1) <base session title>` ثم `(2) ...` وهكذا.
- العداد فريد ومتزايد على مستوى `lineage_id` كله، بما في ذلك branch-from-branch.
- تخصيص الرقم ذري ومحمي بقيد uniqueness أو retry منظم لمنع اسمين بالرقم نفسه.
- يحفظ base title كبيانات lineage/branch واضحة؛ لا يعتمد النظام على regex قد
  يزيل بادئة كتبها المستخدم بنفسه.
- يستخدم fork اسم الجلسة الحالية المنظّم عند الإنشاء، ولا يغير اسم المصدر.

### 3.5 فتح الفرع وتجربة الفشل

- يظهر زر Fork فقط عندما تكون الإجابة دائمة وهوية الهدف متاحة.
- الضغط المتكرر أثناء الطلب معطل، ويحمل الأمر `request_id` لجعله idempotent.
- بعد نجاح daemon يضيف client الجلسة إلى cache/sidebar ويعرضها مباشرة.
- إذا نجح الإنشاء وفشل navigation محليًا، تبقى الجلسة الجديدة محفوظة وقابلة
  للفتح من sidebar؛ لا يعاد fork تلقائيًا.
- فشل daemon قبل commit يبقي المستخدم في الأصل ولا يظهر جلسة وهمية.

## 4. بوابة التنفيذ

- [x] اعتماد schema للـlineage، نقطة fork، sequence، وorigin identities.
- [x] اعتماد تعريف prefix canonical وحد الـturn inclusive.
- [x] حسم حقول session التي تُنسخ وحقول runtime التي تبدأ فارغة.
- [x] توثيق command/result ونتائج الفشل وidempotency قبل تعديل الواجهة.
- [x] تحديد سلوك العناوين بعد rename دون الاعتماد على تحليل النص وحده.
- [x] إثبات أن التنفيذ يقرأ التاريخ server-side ولا يعتمد على pagination client.

## 5. النطاق المرحلي

### Gate A — Persistence and lineage schema

- [x] إضافة `lineage_id`, parent/fork target metadata، وfork sequence للجلسات.
- [x] إضافة origin identity للرسائل المنسوخة عند الحاجة للتدقيق.
- [x] تعريف قيود وفهارس lineage والعداد ونقطة الهدف.
- [x] migration للجلسات الحالية يجعل كل جلسة قائمة root lineage مستقلة.
- [x] تثبيت delete behavior بحيث لا يوجد cascade من الأصل إلى الفرع.

#### Gate A Exit

- [x] يمكن حذف parent مع بقاء child قابلة للقراءة والاستمرار.
- [x] branch-from-branch يحتفظ بنفس lineage ويخصص sequence جديدة صحيحة.

### Gate B — Atomic daemon fork command

- [x] إضافة command canonical مثل `session.fork` بهوية المصدر والـfinal target
      و`request_id` idempotent.
- [x] التحقق من أن المصدر والهدف ينتميان للجهاز/النطاق المصرح بهما.
- [x] تثبيت snapshot للـprefix حتى نهاية target turn داخل المعاملة.
- [x] إنشاء session والاسم ونسخ prefix losslessly في معاملة واحدة.
- [x] إنشاء message identities جديدة مع origin references وعدم نسخ runtime work.
- [x] إعادة result يحمل child session summary والlineage ونقطة fork.
- [x] تكرار command بنفس request identity يعيد النتيجة نفسها ولا ينشئ فرعًا آخر.

#### Gate B Exit

- [x] لا توجد جلسة جزئية عند فشل أي سجل أو قيد أو تخصيص اسم.
- [x] المصدر لا يتغير والفرع يبدأ `idle` ويمكن إرسال رسالة جديدة إليه.

### Gate C — Client timeline and navigation

- [x] إضافة `Fork` أسفل كل final answer مؤهلة، لا الأخيرة فقط.
- [x] تمرير target identity إلى daemon دون إرسال transcript من client.
- [x] منع الضغط المزدوج وعرض progress/failure غير هدّام في الرسالة المالكة.
- [x] بعد النجاح تحديث cache/sidebar واختيار child وفتح timeline الخاصة بها.
- [x] وضع child الجديدة أعلى sidebar ثم scroll إلى أسفل timeline بعد hydration
      لإظهار حدث fork النهائي.
- [x] إبقاء الأصل في cache وتاريخه دون أي optimistic truncation أو mutation.
- [x] التعامل مع final answers المحملة عبر pagination بنفس السلوك.

#### Gate C Exit

- [x] fork من إجابة قديمة يفتح child تحتوي prefix الصحيح فقط.
- [x] الرجوع إلى الأصل يعرض كامل تاريخه ويمكن متابعة العمل فيه بشكل مستقل.

### Gate D — History fidelity and continuation

- [x] التحقق من نسخ user/assistant/tool/reasoning/provider metadata دون فقد.
- [x] الحفاظ على tool call/result pairing وترتيب model steps داخل prefix.
- [x] استبعاد كل event بعد target final حتى لو كان محملًا في client.
- [x] إرسال turn جديدة في child لا يضيف أو يعدل أي سجل في parent والعكس.
- [x] reconnect/restart يعيدان lineage والفرع والتاريخ نفسه.

### Gate E — Verification and documentation

- [x] اختبارات DB للنسخ الذري، rollback، ترتيب prefix، والهويات الجديدة.
- [x] اختبارات lineage للأسماء المتزامنة، branch-from-branch، rename، وحذف parent.
- [x] اختبارات protocol للهدف غير الموجود/غير terminal/superseded وidempotency.
- [x] اختبارات fidelity تشمل reasoning وأدوات وprovider state وmetadata كبيرة.
- [x] اختبارات client widget لكل final answer، الضغط المزدوج، الفشل، والnavigation.
- [x] اختبار daemon-backed لجلسة بها عدة turns وfork من إجابة وسطية ثم استمرار
      parent وchild برسالتين مختلفتين.
- [x] تحديث وثائق product/technical/database/QA وفهارسها ذات الصلة.

## 6. Definition of Done

- [x] كل final answer دائمة ومؤهلة تعرض Fork.
- [x] child تحتوي كل التاريخ النشط حتى الإجابة المختارة فقط وبترتيب lossless.
- [x] الإنشاء والنسخ والاسم atomic ولا يتركون partial session.
- [x] parent وchild لا تشتركان في message rows وتستمران بصورة مستقلة.
- [x] الأسماء `(1)`, `(2)`, ... فريدة عبر lineage كاملة تحت التزامن.
- [x] حذف parent لا يحذف child، وحذف child لا يؤثر على أي جلسة أخرى.
- [x] لا تعتمد العملية على الرسائل المحملة في Flutter أو تعيد تنفيذ tools.
- [x] restart/reconnect/pagination لا تغير نقطة fork أو التاريخ المنسوخ.
- [x] حدث fork مشتق من lineage، مطابق بصريًا لحدث compaction، ولا يدخل رسائل LLM.
- [x] child تظهر أعلى القائمة، تُفتح تلقائيًا، ويظهر حدث fork بعد scroll للأسفل.
- [x] تحليلات agent/client والاختبارات المركزة والتكاملية المناسبة ناجحة.

## 7. سيناريو النجاح

تحتوي جلسة بعنوان `Refactor auth` على ثلاث جولات، وفي الجولة الثانية tool call
ونتيجة ثم final answer. يضغط المستخدم Fork أسفل إجابة الجولة الثانية. ينشئ
daemon داخل معاملة واحدة جلسة `(1) Refactor auth`، وينسخ كل السجلات النشطة حتى
نهاية الجولة الثانية inclusive بهويات جديدة، ويفتحها client. يرسل المستخدم
رسالة مختلفة في كل من parent وchild؛ لا يظهر أي تغيير متبادل بينهما. بعد حذف
parent وإعادة تشغيل التطبيق، تبقى child وتاريخها وlineage قابلة للفتح والاستمرار.

## 8. خارج النطاق

- shared-prefix/message graph أو deduplication بين الجلسات.
- Fork من user message أو reasoning أو partial/in-flight response.
- دمج فرعين أو إعادة مزامنتهما بعد الإنشاء.
- نسخ queued work أو pending steer أو حالة run من المصدر.
- تغيير سلوك Edit/Retry الذي تملكه Task 51.

## 9. الملفات والوثائق المتوقعة

- `agent/lib/evolution/db/`
- `agent/lib/interfaces/platforms/sanad_gateway/`
- `agent/lib/interfaces/runtime/`
- `client/lib/features/conversations/`
- اختبارات agent/client المركزة والتكاملية
- وثيقة product جديدة لتجربة Conversation Fork
- وثيقة technical جديدة لعقد Session Fork وlineage
- `docs/technical/agent_database_schema.md`
- وثيقة QA جديدة لمصفوفة fork والاستقلال

## 10. سجل التقدم

```text
Date: 2026-08-30
Gate/status: Gate E verified closed; Task 52 completed
Files changed:
  docs/qa_maintenance/conversation_fork_qa.md
    reject superseded_by_steer targets in the QA matrix
Verification:
  fvm dart test test/evolution/session_lineage_schema_test.dart
    test/interfaces/platforms/sanad_gateway/session_fork_command_handler_test.dart
    -> All tests passed (11)
  fvm dart test e2e_test/sanad_gateway_platform_e2e_test.dart
    --name "local daemon forks a middle final answer" --concurrency=1
    -> All tests passed (1)
  fvm flutter test test/widget/conversation_fork_event_tile_test.dart
    -> All tests passed (5)
  graphify update . -> Rebuilt
Findings:
  Product/technical/database/QA docs and llms/MOC indexes describe
  materialized fork, lineage, idle child, and parent/child independence.
  Protocol outcomes and daemon-backed E2E match: middle final answer
  forks into an independent child, then parent and child continue apart.
Next gate: none — Task 52 complete
```

### مراجعة 2026-08-31

```text
Gate/status: Gate A review closed; Gate B review next
Remaining: 80% (Gates B-E)
Finding repaired:
  Parent deletion detached child parent_session_id values before attempting the
  parent DELETE. A rejected DELETE therefore left the parent alive with partial
  lineage damage. Both statements now share a SQLite savepoint and roll back
  together on failure.
Documentation:
  Database schema and fork QA now require atomic parent-link detachment and
  preservation of all links when deletion is rejected.
Verification:
  fvm dart test test/evolution/session_lineage_schema_test.dart
    -> All tests passed (6)
  focused fvm dart analyze -> No issues found
  git diff --check -> passed
Next gate: Gate B — Atomic daemon fork command
```

```text
Gate/status: Gate B review closed; Gate C review next
Remaining: 60% (Gates C-E)
Finding repaired:
  fork_request_id previously returned an existing child without checking that
  source session and target identities matched the original command. Exact
  command retries now return already_exists; conflicting key reuse returns
  invalid_request without mutation.
Documentation:
  Fork protocol and QA bind idempotency to source + target identity.
Verification:
  focused lineage/service/handler tests -> All tests passed (26)
  focused fvm dart analyze -> No issues found
  git diff --check -> passed
Next gate: Gate C — Client timeline and navigation
```

```text
Gate/status: Gate C review closed; Gate D review next
Remaining: 40% (Gates D-E)
Finding repaired:
  A daemon-accepted fork whose local navigation failed was converted into a
  generic failed result. The accepted result is now preserved with an explicit
  navigationFailed marker; the child remains listed and the UI directs the
  user to select it instead of implying creation failed.
Documentation:
  Product UX and QA distinguish committed creation from local navigation.
Verification:
  focused client flow/widget/command tests -> All tests passed (63)
  fvm flutter analyze -> No issues found
  git diff --check -> passed
Next gate: Gate D — History fidelity and continuation
```

```text
Gate/status: Gate D review closed; Gate E review next
Remaining: 20% (Gate E)
Finding repaired:
  Assistant text with finishReason=unknown was accepted as a fork target without
  durable terminal proof. Unknown-finish rows now fail closed unless a
  terminal_work_item_id proves completion.
Coverage retained:
  Lossless reasoning/tool/provider metadata copy, tool-pair id rewriting,
  post-target exclusion, independent continuation, and restart restoration.
Verification:
  session fork service tests -> All tests passed (15)
  focused fvm dart analyze -> No issues found
  git diff --check -> passed
Next gate: Gate E — Verification and documentation
```

```text
Gate/status: Gate E review closed; Task 52 complete
Remaining: 0%
Documentation:
  Product UX, session-fork protocol, database schema, QA matrix, MOCs, and
  llms.txt consistently cover materialized copy, lineage, atomicity,
  idempotency, terminal targeting, navigation recovery, and independence.
Verification:
  fvm dart analyze -> No issues found
  fvm flutter analyze -> No issues found
  focused agent fork tests -> All tests passed (27)
  focused client fork/flow/command tests -> All tests passed (63)
  fork daemon E2E --concurrency=1 -> All tests passed (1)
  full agent fast suite -> All tests passed (1246; 12 skipped)
  full client fast suite -> All tests passed (1117; 1 skipped)
  git diff --check -> passed
E2E fixture correction:
  Seeded final answers now carry finishReason=stop, matching the terminal-target
  contract instead of relying on ambiguous unknown-finish assistant text.
Next gate: none — Task 52 review complete
```

```text
Gate/status: fork timeline visibility implementation closed; live UI acceptance next
Remaining: 5% (visual acceptance blocked by an unverifiable existing client runtime)
Decisions implemented:
  The child owns one trailing history-only session.forked marker derived from
  lineage. It uses the context-compaction timeline-event layout and never enters
  persisted model messages or LLM projection.
  Fork commit time initializes authoritative child ordering, the child is
  inserted first and selected, and opening hydration aligns to the trailing
  marker even when an older viewport anchor exists.
Verification:
  focused agent fork handler tests -> All tests passed (6)
  focused client marker/scroll/sidebar tests -> All tests passed (70)
  fvm dart analyze -> No issues found
  fvm flutter analyze -> No issues found
  git diff --check -> passed
  graphify update . -> rebuilt
Blocker:
  sanad-dev status reports Agent stopped plus one unverifiable client with an
  incomplete launch profile. No stop or runtime switch was attempted.
Next gate: authorized runtime cleanup/start, then visible fork acceptance
```

```text
Gate/status: live UI acceptance closed; Task 52 complete
Remaining: 0%
Observed repair:
  A fork created by an older build retained copied user-message recency and
  appeared last inside its workspace. Startup now idempotently raises existing
  fork ordering recency to created_at while preserving copied message timestamps.
Visible evidence using the explicit test Sanad Home:
  (1) مشروع صندوق اقتراحات متكامل appeared as the first row directly below
  suggestion-box, before Exact LIVE_ALPHA Response.
  Conversation forked was visible at the hydrated timeline tail with the
  compaction-style marker layout.
Verification:
  session lineage schema tests -> All tests passed (7)
  focused client marker/scroll/sidebar tests -> All tests passed (70)
  agent/client analyzers -> No issues found
  git diff --check -> passed
  graphify update . -> rebuilt
Follow-up:
  sanad-dev launch/ownership/background failures are isolated in Task 67.
Next gate: none — Task 52 complete
```
