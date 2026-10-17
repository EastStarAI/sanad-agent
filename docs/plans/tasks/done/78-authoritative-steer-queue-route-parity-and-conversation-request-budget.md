---
title: "المهمة 78: الترتيب السببي وتطابق البث والتاريخ لأحداث تبديل المزود وتفريع المحادثة"
description: "إصلاح الترتيب السببي وموضع إشارات تبديل المزود (Route Transition) وحدث تفريع الجلسة (Fork Marker) بين البث والتاريخ والصفحات، وضمان التطابق الكامل دون قفزات أو اختفاء."
status: "completed"
current_gate: "البوابة E — التحقق الشامل والتوثيق (مكتملة)"
priority: "high"
depends_on: "Task 31 authoritative execution snapshots, Task 52 session fork, Task 87 authoritative conversation identity and ordering"
file_budget: 12
design_contract: "docs/technical/agent_interface_runtime.md"
qa_contract: "docs/qa_maintenance/conversation_event_parity_qa.md"
remaining_estimate_percent: 0
---

# المهمة 78: الترتيب السببي وتطابق البث والتاريخ لأحداث تبديل المزود وتفريع المحادثة

> [!NOTE]
> **نطاق ومسؤولية المهمة:**
> تقتصر هذه المهمة حصرياً على حل مشكلة اختلال الترتيب السببي وغياب التطابق بين البث الحي (Live) وتاريخ المحادثة (History Hydration) للحدثين الإرشاديين (`EventKind.informational`):
> 1. إشارات تبديل المزود (`session_route_transition`).
> 2. حدث تفريع الجلسة (`session.forked`).
> (باقي المسائل المتعلقة بالـ Steer والطابور والـ Compaction أُنجزت ومملوكة للمهام 87 و106).

---

## 1. المشكلات المستهدفة

1. **انزياح حدث تفريع المحادثة (`session.forked`) إلى ذيل التاريخ:**
   - عند تفريع جلسة ثم إرسال رسائل أو أدوار جديدة فيها، يُحقن حدث `session.forked` في أقصى نهاية تاريخ المحادثة بعد الرسائل الجديدة بدلاً من أن يثبت بعد الرسالة التي فُرعت منها (`forked_from_message_id`).
   - عند تجزئة التاريخ (Pagination)، يُضاف الحدث بشكل أعمى إلى الصفحة الحالية حتى لو لم تكن تحوي نقطة التفريع الأصلية، ويختفي عند تصفح الصفحة الحاوية للنقطة.
   - يعتمد العميل في الواجهة على افتراض خاطئ بأن الحدث في ذيل القائمة (`last`) لضبط موضع التمرير، مما يكسر التمرير بمجرد وجود رسائل لاحقة.

2. **الترتيب الخاطئ واختفاء إشارات تبديل المزود (`session_route_transition`):**
   - في التاريخ، يتم إدراج الحدث استناداً إلى `request_id` فقط، ونظراً لأن رسالة المستخدم هي الوحيدة التي تحمله، يُحقن إشعار الـ Failover مباشرة بعد رسالة المستخدم بدلاً من الأداة المتعثرة التي حدث عندها التبديل.
   - عند غياب `request_id`، يُقارن التوقيت الحقيقي للحدث بتوقيتات التاريخ المصطنعة فيوضع في مكان عشوائي.
   - في صفحات التاريخ غير الذيلية (`!isTailPage`)، يُسقط الحدث تماماً ويختفي عند التمرير لأعلى.
   - يتجاهل التاريخ انتقالات المزود الناتجة عن المستخدم (`user`) أو الاستعادة (`recovery`) ويحصرها بـ `autoFailover`.
   - يظهر الحدث أثناء البث الحي في موضعه الصحيح بعد الأداة، لكنه يقفز عند إعادة فتح المحادثة أو تحديثها ليظهر قبل الأداة أو يختفي تماماً (Live vs History Parity Failure).

---

## 2. نتائج الاستكشاف البرمجي المثبتة

1. **في الوكيل (`agent`):**
   - `agent/lib/interfaces/platforms/sanad_gateway/handlers/session_query_handler.dart`:
     - السطر 608: `historyMessages.add(...)` يحقن `session.forked` في نهاية القائمة متجاهلاً موضع `session.forkedFromMessageId`.
     - السطور 628–692: حصر إدراج `session_route_transition` بـ `lastMatch` لـ `request_id`، ومقارنة التوقيت المصطنع، وإسقاط الحدث في السطر 673 إذا لم يكن في صفحة الذيل، وحصر المصادر في السطر 631 بـ `autoFailover`.

2. **في العميل (`client`):**
   - `client/lib/features/conversations/presentation/screens/brain_activity_view.dart`:
     - السطر 555: `_timelineItems.last.events.any((e) => e.metadata?['informational_kind'] == 'session_fork')` يفترض وجود الحدث في آخر عنصر بالجدول الزمني.
   - `client/lib/features/conversations/domain/stores/canonical_timeline_reconciler.dart`:
     - غياب قواعد مطابقة سببية لأحداث `EventKind.informational` في `matches` و `mergeAuthoritativeSlice`.

---

## 3. القرارات المعمارية الملزمة

1. **التثبيت السببي لحدث التفريع:**
   - يوضع حدث `session.forked` مباشرة بعد الرسالة المطابقة لـ `forked_from_message_id` (أو دورة `forked_from_turn_id`).
   - لا يُدرج الحدث إلا في الصفحة التي تحتوي نقطة التفريع؛ إذا لم تكن النقطة ضمن نطاق الصفحة الحالية لا يُحقن الحدث في تلك الصفحة.
   - في العميل، يُفحص الحدث في أي موضع بالجدول الزمني لضبط التمرير والارتكاز الأولي.

2. **التثبيت السببي لحدث تبديل المزود:**
   - يُربط انتقال المسار بالخطوة/الأداة السببية التي دعت إلى التحويل أو الدورة المعنية، وتُزال مقارنة التوقيتات المصطنعة.
   - إتاحة ظهور كافة مصادر الانتقال المشروعة (`autoFailover`, `user`, `recovery`).
   - الحفاظ على بقاء الحدث في موضعه السببي حتى عند التصفح والـ pagination.

3. **تطابق البث الحي والتاريخ (Parity):**
   - ضمان تطابق معرف الحدث (`id`) وموضعه النسبي بين البث المباشر وعمليات المصالحة عبر `CanonicalTimelineReconciler`.

---

## 4. معايير القبول (Acceptance Criteria)

- [x] جلسة مفرّعة تحتوي رسائل جديدة لاحقة تعرض حدث `Conversation forked` مباشرة بعد الرسالة المفرّع منها، وليس في نهاية المحادثة.
- [x] عند تصفح صفحات تاريخ متعددة لجلسة مفرّعة، يظهر حدث الـ fork فقط في الصفحة المحتوية لنقطة التفريع.
- [x] فتح جلسة مفرّعة بها رسائل لاحقة يضبط موضع التمرير الأولي بشكل صحيح عند علامة الـ fork دون قفزات عشوائية.
- [x] إشارة تبديل المزود تظهر بعد الأداة أو الخطوة المتعثرة live وتظل في الموضع نفسه تماماً بعد إعادة تحميل التاريخ.
- [x] إشارات تبديل المزود لا تختفي عند تصفح صفحات التاريخ السابقة (pagination).
- [x] إشارات الانتقال الناتجة عن المستخدم (`user`) أو الاستعادة تظهر في التاريخ وفق السياسة المعتمدة.
- [x] اجتياز كافة اختبارات الوكيل والعميل والتحليل الثابت (`analyze`) دون أخطاء.

---

## 5. بوابات التنفيذ (Execution Gates)

### البوابة A — تثبيت العقود وإعادة الإنتاج باختبارات فاشلة
- [x] كتابة اختبارات فاشلة في الوكيل تؤكد:
  - انزياح `session.forked` إلى نهاية التاريخ عند وجود رسائل لاحقة في الجلسة المفرّعة (`agent/test/interfaces/session_informational_event_order_test.dart`).
  - ظهور `session.forked` في صفحات لا تحوي نقطة التفريع.
  - إدراج `session_route_transition` مباشرة بعد رسالة المستخدم بدلاً من الأداة الفاشلة، واختفاؤه في الصفحات غير الذيلية واستبعاد مصادر `user`.
- [x] كتابة اختبارات فاشلة في العميل تؤكد:
  - عدم تطابق وازدواج إشارة التحويل بين Live و History (`client/test/unit/stores/canonical_timeline_reconciler_test.dart`).
  - ازدواج حدث التفريع عند اختلاف المعرفات بين Live و History.

### البوابة B — التثبيت السببي لحدث التفريع (`session.forked`)
- [x] تعديل `session_query_handler.dart` للبحث عن موضع `forked_from_message_id` في رسائل الصفحة وإدراج الحدث بعدها مباشرة.
- [x] منع إدراج الحدث في الصفحات التي لا تتضمن `forked_from_message_id`.
- [x] تحديث `brain_activity_view.dart` للارتكاز على علامة التفريع في أي موضع بالجدول الزمني.

### البوابة C — التثبيت السببي لحدث تبديل المزود (`session_route_transition`)
- [x] تحديث `session_query_handler.dart` ليربط التحويل بالخطوة/الأداة السببية بدلاً من حصرها بـ `request_id` على رسالة المستخدم.
- [x] إزالة مقارنة التوقيت الحقيقي بالتوقيت المصطنع لصفوف التاريخ.
- [x] إدراج التحويلات في الصفحات المناسبة ومنع إسقاطها أثناء التصفح.
- [x] إدراج مصادر التحويل (`autoFailover`, `user`, `recovery`) في التاريخ.

### البوابة D — مصالحة العميل والتطابق التام (Live & History Parity)
- [x] ضبط `unified_device_mapper.dart` و `canonical_timeline_reconciler.dart` لضمان مصالحة متسقة لأحداث `EventKind.informational`.
- [x] التأكد من عدم تكرار الأحداث أو قفزها عند التنقل بين البث الحي وإعادة تحميل التاريخ.

### البوابة E — التحقق الشامل والتوثيق
- [x] تشغيل اختبارات Unit و Widget وتكامل الوكيل والعميل ذات الصلة بنجاح.
- [x] تشغيل `fvm dart analyze` في `agent` و `fvm flutter analyze` في `client`.
- [x] تحديث التوثيق الفني ومصفوفة الاختبارات المقابلة.

---

## 6. الملفات والمناطق المتوقعة

- `agent/lib/interfaces/platforms/sanad_gateway/handlers/session_query_handler.dart`
- `agent/test/interfaces/session_informational_event_order_test.dart`
- `client/lib/features/conversations/presentation/screens/brain_activity_view.dart`
- `client/lib/features/conversations/data/mappers/unified_device_mapper.dart`
- `client/lib/features/conversations/domain/stores/canonical_timeline_reconciler.dart`
- `client/test/widget/brain_activity_view_scroll_test.dart`
- `client/test/widget/conversation_fork_event_tile_test.dart`
- `client/test/unit/stores/canonical_timeline_reconciler_test.dart`

---

## 7. سجل التقدم

```text
التاريخ: 2026-10-15
البوابة/الحالة: البوابة A — مكتملة (تم كتابة الاختبارات الفاشلة لإعادة إنتاج الخلل بدقة في الوكيل والعميل)
نسبة المتبقي: 75%
الملفات المعدلة: 
  - docs/plans/tasks/78-authoritative-steer-queue-route-parity-and-conversation-request-budget.md
  - agent/test/interfaces/session_informational_event_order_test.dart
  - client/test/unit/stores/canonical_timeline_reconciler_test.dart
التحقق: فشل الاختبارات الجديدة بنجاح مؤكداً وجود المشكلات المستهدفة
النتائج أو المخاطر: إعادة الإنتاج مؤكدة 100%، ننتقل مباشرة للبوابة B
البوابة التالية: البوابة B — التثبيت السببي لحدث التفريع (session.forked)

التاريخ: 2026-10-15
البوابة/الحالة: البوابة B — مكتملة (تم تثبيت حدث session.forked سببيًا ومنع ظهوره في غير صفحاته ودعم ارتكاز الواجهة عليه)
نسبة المتبقي: 50%
الملفات المعدلة:
  - agent/lib/interfaces/platforms/sanad_gateway/handlers/session_query_handler.dart
  - client/lib/features/conversations/presentation/screens/brain_activity_view.dart
  - client/test/widget/brain_activity_view_scroll_test.dart
  - docs/plans/tasks/78-authoritative-steer-queue-route-parity-and-conversation-request-budget.md
التحقق: نجاح كافة اختبارات التفريع في الوكيل والعميل (unit و widget و analyze)
النتائج أو المخاطر: تم حل انزياح التفريع واختلال التمرير بنجاح، ننتقل للبوابة C
البوابة التالية: البوابة C — التثبيت السببي لحدث تبديل المزود (session_route_transition)

التاريخ: 2026-10-15
البوابة/الحالة: البوابة C — مكتملة (تم تثبيت حدث تبديل المزود سببيًا بعد الأداة الفاشلة وحفظه في الصفحات المتعددة ودعم مصادر user و autoFailover و recovery)
نسبة المتبقي: 25%
الملفات المعدلة:
  - agent/lib/interfaces/platforms/sanad_gateway/handlers/session_query_handler.dart
  - agent/lib/evolution/db/session_db.dart
  - agent/lib/evolution/session_manager.dart
  - agent/test/interfaces/session_informational_event_order_test.dart
  - docs/plans/tasks/78-authoritative-steer-queue-route-parity-and-conversation-request-budget.md
التحقق: نجاح كافة اختبارات تبديل المزود السببية والتصفح والمصادر المتعددة واجتياز dart analyze دون أخطاء
النتائج أو المخاطر: الترتيب السببي لانتقال المزود متطابق تماماً في الوكيل، ننتقل للبوابة D الخاصة بمصالحة العميل
البوابة التالية: البوابة D — مصالحة العميل والتطابق التام (Live & History Parity)

التاريخ: 2026-10-15
البوابة/الحالة: البوابة D — مكتملة (تم ضبط مصالحة الأحداث الإرشادية في العميل وتوحيد معرفات التبديل والتفريع وضمان منع التكرار)
نسبة المتبقي: 10%
الملفات المعدلة:
  - client/lib/features/conversations/domain/stores/canonical_timeline_reconciler.dart
  - client/lib/features/conversations/data/mappers/unified_device_mapper.dart
  - client/lib/features/conversations/domain/models/session_route_snapshot.dart
  - client/test/unit/stores/canonical_timeline_reconciler_test.dart
التحقق: نجاح كافة اختبارات canonical_timeline_reconciler_test و brain_activity_view_scroll_test
النتائج أو المخاطر: تطابق تام بين البث الحي وإعادة تحميل التاريخ، لا تكرار في الجدول الزمني
البوابة التالية: البوابة E — التحقق الشامل والتوثيق

التاريخ: 2026-10-15
البوابة/الحالة: البوابة E — مكتملة (اجتياز كافة الفحوصات والتحليل الثابت وتحديث التوثيق الفني ومصفوفة QA)
نسبة المتبقي: 0%
الملفات المعدلة:
  - docs/qa_maintenance/conversation_event_parity_qa.md
  - docs/plans/tasks/78-authoritative-steer-queue-route-parity-and-conversation-request-budget.md
التحقق: اجتياز fvm dart analyze في agent و fvm flutter analyze في client بدون أي أخطاء، ونجاح كافة الاختبارات المباشرة والتابعة
النتائج أو المخاطر: المهمة 78 مكتملة بنسبة 100% وجاهزة للمراجعة
البوابة التالية: لا يوجد — المهمة مكتملة بالكامل
```

