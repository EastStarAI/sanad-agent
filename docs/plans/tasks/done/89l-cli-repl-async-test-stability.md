---
title: "Task 89l: CLI Async Test Stability"
description: "إزالة الانتظار الزمني السباقي من اختبارات REPL وLocal Gateway واستبداله بانتظار أحداث WebSocket الحتمية بعد ظهور إخفاقات متقطعة في CI والقياس المحلي."
status: "completed"
current_gate: "Complete"
remaining_estimate: "0%"
priority: "high"
depends_on: "Task 89j; merged CLI implementation"
---

## الهدف

جعل اختبارات CLI وLocal Gateway غير المتزامنة حتمية تحت ضغط CI عبر انتظار أحداث WebSocket الفعلية بدل افتراض اكتمال الإرسال أو تنظيف الاتصال خلال مهلة ثابتة قصيرة.

## النطاق والقرارات المثبتة

- الإصلاح يخص test fixture والتزامن في الاختبارات؛ لا يغير سلوك REPL الإنتاجي.
- يعتمد الاختبار على stream للرسائل الصادرة ويشترك قبل بدء الفعل الذي يولد الرسالة، مع مهلة نهائية للتشخيص فقط.
- تشمل المعالجة كل waits المماثلة في مجموعة REPL E2E: `think`، ورد سؤال المستخدم، ورد صلاحية الأداة.
- ينتظر اختبار Local Gateway تنفيذ `removeLocalMember` الفعلي بدل الاكتفاء بدورة event loop واحدة بعد إغلاق socket.
- يعيد AOT smoke حذف مجلد Windows المؤقت ضمن حد معلوم، ولا يعلن النجاح أو يكتب marker قبل اكتمال التنظيف.
- يتحقق workflow من marker مستقل لأن `fvm` أعاد exit code ناجحًا رغم الاستثناء الداخلي على Windows.
- لا تُخفى الأعطال بزيادة `Future.delayed` أو بإعادة المحاولة داخل CI.

## البوابات

### G0 — التحقيق

- [x] استخراج سجلات المحاولات الثلاث للـrun `35048489543`.
- [x] إثبات أن المحاولتين الأولى والثانية فشلتا في الاختبار نفسه عند assertion وصول `think` بعد 50ms، وأن الثالثة نجحت دون تغيير المصدر.
- [x] تحديد sleeps المماثلة في مجموعة REPL E2E ومراجعة fixture المالكة.
- [x] قياس suite قبل/بعد CLI واكتشاف flake أقدم في cleanup لعضوية Local Gateway ظهر في النسختين.
- [x] تدقيق Windows AOT log وإثبات أن cleanup فشل مرتين بينما سجل `fvm` الخطوة ناجحة لغياب marker مستقل.
- [x] أثبت marker أنه يمنع النجاح الكاذب، ثم كشف التشخيص المحسّن السبب الأصلي: `SignalException` عند مراقبة `SIGTERM` غير المدعومة على Windows.
- [x] كشف CI النهائي sleep قديمًا في clarification ضمن `cli_integration_e2e_test.dart` بعد نجاح Windows.

### G1 — التنفيذ

- [x] إضافة stream حتمي للرسائل الصادرة إلى `MockWebSocket`.
- [x] استبدال انتظار `think` وردود permission بالأحداث الفعلية.
- [x] إزالة انتظار queue البالغ 20ms من اختبار `flush()` باستخدام controller متزامن داخل الاختبار.
- [x] إضافة observer اختبارية تنتظر إزالة عضو Local Gateway الفعلية بعد إغلاق socket.
- [x] إضافة bounded retry لتنظيف AOT واختبارات transient/persistent failure.
- [x] جعل مهلة AOT cold-start مستقلة ومحدودة بـ60 ثانية، وقتل child process عند تجاوزها مع stdout/stderr تشخيصيين.
- [x] احتواء `SignalException` المتزامنة أو الواردة عبر signal stream للإشارات غير المدعومة مع regression test، وتمرير الأخطاء الأخرى إلى Zone.
- [x] إضافة success marker وفحص shell مستقل لكل من Windows وUnix.
- [x] إزالة waits الزمنية التسعة من CLI integration واستبدالها بأحداث outbound/state حتمية.

### G2 — التحقق والتسليم

- [x] نجاح analyzer والاختبار المركّز.
- [x] نجاح سيناريو REPL الفاشل 30 مرة تحت 5 عمليات متوازية.
- [x] نجاح سيناريو Local Gateway الفاشل 30 مرة تحت 5 عمليات متوازية.
- [x] نجاح اختباري AOT cleanup للخطأ المؤقت والدائم.
- [x] نجاح AOT smoke المحلي الحقيقي وظهور marker بعد cleanup.
- [x] نجاح حزمة CLI وحزمة Agent الكاملة بعد regression test: 1764 passed، 13 skipped.
- [x] نجاح CLI integration: 19 passed، وضغط clarification: 30/30 عبر 5 عمليات.
- [x] تحديث Graphify وفتح PR مستقل.
- [x] نجاح Windows AOT cleanup وsuccess marker في Public CI من attempt 1 دون rerun.
- [x] نجاح Public CI النهائي على commit إزالة waits من attempt 1 دون rerun.

## معايير القبول

- [x] لا تعتمد سيناريوهات REPL E2E على sleep قبل فحص رسالة socket صادرة.
- [x] كل listener ينتظر الحدث يُثبت قبل بدء الفعل المولد له، فلا يفقد broadcast event.
- [x] timeout النهائي يفشل بتشخيص مباشر إذا لم تصل الرسالة، بدل assertion زمني مضلل.
- [x] cleanup العضوية المحلية ينتظر callback الإزالة الفعلي بعد إغلاق socket.
- [x] تنجح الاختبارات محليًا وفي Public CI دون rerun، بما فيها marker المستقل على Windows.

## Definition of Done

- [x] `fvm dart analyze` ينجح.
- [x] الاختبارات المركزة، CLI، وAgent تنجح بخرج bounded.
- [x] `git diff --check` و`graphify update .` ينجحان.
- [x] PR مستقل موثق بالأدلة؛ تغييره الإنتاجي الوحيد هو احتواء مراقبة الإشارات غير المدعومة على المنصة.
