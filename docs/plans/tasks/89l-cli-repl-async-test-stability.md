---
title: "Task 89l: CLI Async Test Stability"
description: "إزالة الانتظار الزمني السباقي من اختبارات REPL وLocal Gateway واستبداله بانتظار أحداث WebSocket الحتمية بعد ظهور إخفاقات متقطعة في CI والقياس المحلي."
status: "in_progress"
current_gate: "G2 — PR and Public CI"
remaining_estimate: "5%"
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
- لا تُخفى الأعطال بزيادة `Future.delayed` أو بإعادة المحاولة داخل CI.

## البوابات

### G0 — التحقيق

- [x] استخراج سجلات المحاولات الثلاث للـrun `35048489543`.
- [x] إثبات أن المحاولتين الأولى والثانية فشلتا في الاختبار نفسه عند assertion وصول `think` بعد 50ms، وأن الثالثة نجحت دون تغيير المصدر.
- [x] تحديد sleeps المماثلة في مجموعة REPL E2E ومراجعة fixture المالكة.
- [x] قياس suite قبل/بعد CLI واكتشاف flake أقدم في cleanup لعضوية Local Gateway ظهر في النسختين.

### G1 — التنفيذ

- [x] إضافة stream حتمي للرسائل الصادرة إلى `MockWebSocket`.
- [x] استبدال انتظار `think` وردود permission بالأحداث الفعلية.
- [x] إزالة انتظار queue البالغ 20ms من اختبار `flush()` باستخدام controller متزامن داخل الاختبار.
- [x] إضافة observer اختبارية تنتظر إزالة عضو Local Gateway الفعلية بعد إغلاق socket.

### G2 — التحقق والتسليم

- [x] نجاح analyzer والاختبار المركّز.
- [x] نجاح سيناريو REPL الفاشل 30 مرة تحت 5 عمليات متوازية.
- [x] نجاح سيناريو Local Gateway الفاشل 30 مرة تحت 5 عمليات متوازية.
- [x] نجاح حزمة CLI وحزمة Agent الكاملة.
- [ ] تحديث Graphify وفتح PR مستقل ومتابعة CI حتى الحالة النهائية.

## معايير القبول

- [x] لا تعتمد سيناريوهات REPL E2E على sleep قبل فحص رسالة socket صادرة.
- [x] كل listener ينتظر الحدث يُثبت قبل بدء الفعل المولد له، فلا يفقد broadcast event.
- [x] timeout النهائي يفشل بتشخيص مباشر إذا لم تصل الرسالة، بدل assertion زمني مضلل.
- [x] cleanup العضوية المحلية ينتظر callback الإزالة الفعلي بعد إغلاق socket.
- [ ] تنجح الاختبارات محليًا وفي Public CI دون rerun.

## Definition of Done

- [x] `fvm dart analyze` ينجح.
- [x] الاختبارات المركزة، CLI، وAgent تنجح بخرج bounded.
- [x] `git diff --check` و`graphify update .` ينجحان.
- [ ] PR مستقل موثق بالأدلة ولا يغير production behavior.
