---
title: "Partial Stream Recovery and Delivery Safety"
description: "استعادة انقطاع بث LLM بعد وصول أحداث جزئية دون تكرار النص أو تنفيذ الأدوات مرتين."
status: "planned"
scope: "agent engine and runtime interfaces"
depends_on: "Task 33 Gate F; Plan 50 Tasks 50a, 50b, and 50d"
related_to: "Plan 50 run-scoped cancellation and stop parity"
---

# Task 34: Partial Stream Recovery and Delivery Safety

## 1. المشكلة

يعالج runtime حاليًا انقطاع الشبكة تلقائيًا فقط قبل أول حدث من المزود. بعد وصول
reasoning أو content أو tool state يصبح retry الشفاف غير آمن، لأن إعادة الطلب
كاملًا قد تكرر نصًا ظهر للمستخدم، أو تدمج argument deltas من محاولتين، أو تنفذ
أداة ذات أثر جانبي مرتين.

يلزم مسار استعادة مستقل يميز بين انقطاع بث نصي، وانقطاع أثناء tool call جزئي،
وانقطاع بعد اكتمال tool call أو بدء تنفيذه. يجب أن تكون سلامة التسليم والتنفيذ
أهم من إخفاء خطأ الشبكة.

## 2. مبادئ التصميم

- كل محاولة stream لها هوية مستقلة وledger للأحداث التي وصلت وعُرضت وحُفظت.
- لا يدمج accumulator أحداث محاولتين؛ يبدأ كل retry بحالة تجميع جديدة.
- النص أو reasoning المعروض لا يعاد عرضه، ويُستأنف فقط بعد إثبات prefix مطابق.
- tool call الجزئي لا ينفذ. tool call المكتمل لا يعاد تنفيذه إذا بدأ أو اكتمل
  محليًا؛ checkpoint التنفيذ هو مصدر الحقيقة.
- لا يسمح retry التلقائي بعد أثر جانبي غامض. تتحول الحالة إلى blocked مع خيارات
  آمنة للمستخدم.
- تبقى network retry مستقلة عن semantic continuation وعن provider-state
  fallback وعن ميزانية context recovery.

## 2.1 حدود الملكية والتكامل مع Plan 50

تتكامل هذه المهمة مع
[Plan 50](../done/50-run-scoped-cancellation-and-stop-parity.md) دون أن تعيد تنفيذ
مسار الإلغاء الخاص بها:

- **Plan 50 تملك:** user Stop، `RunCancellationScope`، قطع اتصال المزود، إلغاء
  الأدوات والعمليات الفرعية، terminal tool events، وعزل النتائج المتأخرة من run
  ملغاة.
- **Task 34 تملك:** استعادة انقطاع stream غير المقصود، attempt ledger، مطابقة
  prefix، إعادة بناء accumulator، وتعليق الحالات الغامضة التي لا يمكن استكمالها
  بأمان.
- `userStop` ينتهي دائمًا إلى `cancelled` ولا يدخل retry أو failover أو partial
  stream recovery.
- network failure أو stream-idle timeout غير الناتج عن user Stop يدخل تصنيف
  Task 34 بعد أن يحرر transport المورد القديم.
- tool call جزئي عند user Stop يهمل ولا يستعاد. أما tool call جزئي بسبب انقطاع
  غير مقصود فيخضع لقواعد Gate C في هذه المهمة.
- tool بدأت أو اكتملت محليًا لا تعاد بسبب recovery؛ checkpoint وterminal event
  اللتان تثبتهما Plan 50 هما مصدر الحقيقة.

ترتيب الاعتماد المقصود:

```text
Task 33 Gate F
       +
Plan 50: 50a cancellation core + 50b provider interruption + 50d terminal events
       |
       v
Task 34 partial-stream recovery
```

## 3. النطاق المرحلي

### Gate A — تشخيص وتسلسل التسليم

- استهلاك هوية run وسبب الانتهاء وعقد terminal precedence المثبتة في Plan 50،
  وعدم إنشاء cancellation primitive أو Stop path موازية.
- تعريف حالات stream: لم يبدأ، reasoning/text جزئي، tool call جزئي، tool call
  مكتمل غير منفذ، tool قيد التنفيذ، ونتيجة محفوظة.
- إضافة attempt id وعدادات bytes/events مع logging نظيف بلا محتوى حساس.
- تثبيت حدود ما عرضته الواجهة وما حفظه history وما سجله checkpoint.

### Gate B — استعادة النص والتفكير الجزئي

- إعادة الطلب باتصال جديد وaccumulator جديد عند الانقطاع المؤقت.
- عدم بدء recovery إذا كان سبب إنهاء المحاولة `userStop` أو كانت run terminally
  cancelled.
- مقارنة prefix قبل إسقاط الأجزاء المكررة.
- إلغاء الاستعادة تلقائيًا عند اختلاف prefix أو terminal state.
- منع تكرار `thought_stream` و`final_answer` عبر gateway reconnect أو retry.

### Gate C — استعادة tool call الجزئي

- عدم تنفيذ arguments قبل اكتمالها والتحقق منها.
- إعادة بناء tool call من محاولة جديدة دون دمج JSON جزئي قديم.
- ربط tool call المكتمل بـcheckpoint حتمي قبل التنفيذ.
- احترام `cancelled` terminal status المثبتة في Plan 50 وعدم استبدالها بنتيجة
  retry أو timeout متأخرة.
- منع إعادة تنفيذ الأدوات غير idempotent بعد انقطاع أو restart.

### Gate D — التعليق والاستكمال اليدوي

- تحويل الحالات الغامضة إلى durable suspended work item.
- توفير Retry وChange Provider مع الحفاظ على route والطلب الأصليين.
- تفويض Stop إلى المسار authoritative في Plan 50 بدل إنشاء Stop خاص بالاستعادة.
- توضيح ما إذا كان النص قد عُرض أو كانت أداة قد بدأت قبل طلب قرار المستخدم.

## 4. معايير القبول

- انقطاع stream بعد reasoning لا يكرر reasoning المعروض.
- انقطاع stream بعد text جزئي لا يكرر prefix ولا يخلط محاولتين.
- انقطاع function arguments لا ينفذ JSON ناقصًا ولا يدمج deltas قديمة وجديدة.
- أداة مكتملة أو منفذة لا تنفذ مرتين بعد retry أو restart.
- اختلاف prefix أو حالة تنفيذ غامضة يوقف الاستعادة التلقائية بأمان.
- user Stop لا يبدأ partial recovery ولا retry أو failover، ويظل `cancelled`
  terminally في live events والتاريخ المستعاد.
- network/stream-idle interruption تحرر transport القديمة قبل فتح محاولة جديدة.
- نتيجة attempt متأخرة لا تستبدل cancellation ولا تغير run أحدث.
- اختبارات sync/stream وgateway delivery وrestart تغطي كل حد حالة.
- يظل خطأ ما قبل أول event خاضعًا لسياسة Task 33 Gate F المحدودة.

## 5. خارج النطاق

- تغيير payload أو schema الخاصة بالمزود دون حاجة مثبتة.
- إعادة تنفيذ `RunCancellationScope` أو provider/tool Stop أو terminal event
  persistence التي تملكها Plan 50.
- الاعتماد على `previous_response_id` مع `store: false`.
- إعادة تصميم بروتوكول الأدوات أو قاعدة بيانات الجلسات بالكامل.
- رفع retry budgets بصورة غير محدودة أو إعادة تنفيذ أثر جانبي على سبيل التخمين.
