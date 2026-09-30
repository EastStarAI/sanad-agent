---
title: "Task 50e: Client Stop and Tool Event Parity"
description: "عرض tool cancellation فورًا في Flutter، ودمجها idempotently مع stopped/history ومنع spinner أو late timeout من استبدالها."
status: "complete"
current_gate: "E3 complete"
priority: "high"
depends_on: "50d"
file_budget: 14
reference_grounding: "required"
evidence_id: "50e"
design_contract: "docs/technical/run_cancellation_and_process_ownership.md"
---

# Task 50e: Client Stop and Tool Event Parity

## 1. الهدف

جعل live conversation projection تغلق كل tool جارية عند terminal cancellation، مع fallback دفاعي عند `stopped` وتطابق كامل بعد navigation أو reload.

## Gate R0 — External Reference Grounding

- [ ] حل `evidence_id` عبر workflow التأصيل الخارجي والتحقق من freshness.
- [ ] قراءة implementations والاختبارات الإلزامية وتسجيل مصفوفة
      `Adopt / Adapt / Reject` محلية ومحايدة المصدر.
- [ ] تحويل القرارات المقبولة إلى invariants واختبارات صريحة لهذه المهمة.
- [ ] عند غياب الحزمة أو قدمها، تشغيل authoring/refresh حتى تصبح `ready`.
- [ ] عدم بدء E0 قبل `ready`؛ لا تسجل `blocked` إلا لمانع غير قابل للتعافي.

### R0 Exit

- [ ] سجل التأصيل يحمل fingerprint والرموز والاختبارات المتحققة والقرارات.
- [ ] لا يحتوي أي ملف متتبع هوية المصدر الخارجي أو مساره؛ يبقى العقد سلوكيًا.

## 2. Gate E0 — Projection contract

- [ ] إضافة `cancelled` إلى domain status وترتيب terminal precedence.
- [ ] تثبيت merge key باستخدام toolCallId/runId/modelStepId دون تخمين نصي.
- [ ] تحديد سلوك late done/error/timeout بعد cancelled.
- [ ] اعتماد النص والعرض المرئي الإنجليزيين لحالة cancellation.

### E0 Exit

- [ ] model/store تستطيع تمثيل cancellation دون تحويلها إلى generic error.
- [ ] terminal status لا تعود إلى running.

## 3. Gate E1 — Live terminal events

- [ ] map payload الجديدة إلى canonical event.
- [ ] دمج tool_use وterminal result بالهوية نفسها.
- [ ] تحديث event tile لإظهار cancelled بوضوح ومن دون spinner.
- [ ] الحفاظ على output الجزئية المسموح بها مع سبب الإلغاء.

### E1 Exit

- [ ] terminal event تحدث الأداة فورًا دون navigation.
- [ ] لا يظهر timeout إذا كانت cancelled هي النتيجة authoritative.

## 4. Gate E2 — Defensive stopped reconciliation

- [ ] عند `stopped(runId)` إنهاء أي tool running لنفس run فقط إذا فقد terminal event.
- [ ] عدم لمس tool تخص run أخرى أو جلسة أخرى.
- [ ] دمج terminal event اللاحقة idempotently مع fallback.
- [ ] مزامنة execution snapshot وmessage projection دون جعل UI مصدر الحقيقة للجلسة.

### E2 Exit

- [ ] فقد terminal packet لا يترك spinner دائمًا.
- [ ] وصول packet لاحقًا لا يخلق duplicate event أو flicker.

## 5. Gate E3 — History/reload parity and verification

- [ ] اختبار live cancellation ثم navigation والعودة.
- [ ] اختبار reload/history hydration والـstatus/output نفسها.
- [ ] اختبار stopped fallback وlate timeout suppression.
- [ ] تحديث feature contract وproduct/QA docs.

### E3 Exit / Definition of Done

- [ ] ما يراه المستخدم live يطابق ما يراه بعد إعادة جلب history.
- [ ] لا تبقى tool running بعد stopped لنفس run.
- [ ] Reference parity audit يثبت أن التنفيذ والاختبارات يحققان كل قرار
      `Adopt/Adapt` مسجل، أو يعيد أي deviation إلى تصميم المهمة.
- [ ] المهمة داخل file budget.

## 6. الملفات المتوقعة

- `client/lib/features/conversations/domain/models/canonical_event.dart`
- `client/lib/features/conversations/data/mappers/device_event_mapper.dart`
- `client/lib/features/conversations/data/transport/conversation_event_handler.dart`
- `client/lib/features/conversations/domain/stores/conversation_state.dart`
- `client/lib/features/conversations/domain/stores/device_conversation_store.dart`
- `client/lib/features/conversations/presentation/widgets/event_tile.dart`
- اختبارات mapper/handler/store/widget المركزة (3–4 ملفات)
- `client/lib/features/AGENTS.md`
- `docs/product/message_edit_retry_ux.md` أو الوثيقة المالكة الأقرب
- `docs/qa_maintenance/conversation_event_parity_qa.md`
- ملف المهمة والخطة الأم

## 7. سيناريو نجاح

تظهر shell tool بحالة running، ثم تصل cancellation وstopped. تتحول فورًا إلى cancelled بلا spinner. بعد فتح محادثة أخرى والعودة أو إعادة تشغيل العميل تظل الحالة والنص والهوية نفسها، ولا تستبدلها timeout متأخرة.

## 8. سجل التقدم

```text
Date:
Gate/status:
Files changed:
Verification:
Findings:
Next gate:
```
