---
title: "Task 50d: Durable Terminal Tool Events"
description: "ضمان terminal event واحدة لكل أداة بدأت، وحفظ cancellation قبل idle مع عزل النتائج المتأخرة وتطابق history/live payloads."
status: "complete"
current_gate: "D3 complete"
priority: "critical"
depends_on: "50a, 50c"
file_budget: 14
reference_grounding: "required"
evidence_id: "50d"
design_contract: "docs/technical/run_cancellation_and_process_ownership.md"
---

# Task 50d: Durable Terminal Tool Events

## 1. الهدف

إغلاق lifecycle لكل tool call بدأت بنتيجة durable واحدة، وضمان أن Stop يحفظ ويبث `cancelled` قبل `stopped/idle` وأن history hydration تعيد الهوية والحالة نفسيهما.

## Gate R0 — External Reference Grounding

- [ ] حل `evidence_id` عبر workflow التأصيل الخارجي والتحقق من freshness.
- [ ] قراءة implementations والاختبارات الإلزامية وتسجيل مصفوفة
      `Adopt / Adapt / Reject` محلية ومحايدة المصدر.
- [ ] تحويل القرارات المقبولة إلى invariants واختبارات صريحة لهذه المهمة.
- [ ] عند غياب الحزمة أو قدمها، تشغيل authoring/refresh حتى تصبح `ready`.
- [ ] عدم بدء D0 قبل `ready`؛ لا تسجل `blocked` إلا لمانع غير قابل للتعافي.

### R0 Exit

- [ ] سجل التأصيل يحمل fingerprint والرموز والاختبارات المتحققة والقرارات.
- [ ] لا يحتوي أي ملف متتبع هوية المصدر الخارجي أو مساره؛ يبقى العقد سلوكيًا.

## 2. Gate D0 — Canonical terminal schema

- [ ] اعتماد `cancelled` كحالة terminal مستقلة عن `done/error`.
- [ ] تثبيت payload: session/run/model step/tool call IDs، reason، output، timestamps.
- [ ] تحديد ordering بين terminal tool events و`stopped` وexecution snapshot.
- [ ] تعريف idempotency key ومن يفوز في سباق cancel/timeout/result.
- [ ] ربط progress publication بالـrun owner وstop barrier نفسها؛ progress ليست
      مسارًا جانبيًا يستطيع تجاوز terminal precedence.

### D0 Exit

- [ ] live mapper وhistory query يملكان schema واحدة.
- [ ] terminal precedence موثقة ولا تعتمد على زمن وصول العميل.

## 3. Gate D1 — Durable terminalization transaction

- [ ] التقاط currently-executing tools عند stop barrier.
- [ ] حفظ cancelled outputs/checkpoints/work-item state ذريًا بقدر ملكية repository الحالية.
- [ ] تنفيذ terminal transition كـcompare-and-set محروس بـsession/run/generation
      والحالة غير النهائية؛ لا تعتمد الحماية على flag متطايرة وحدها.
- [ ] إصدار terminal events قبل نشر idle.
- [ ] ضمان terminal مرة واحدة عند repeated/multi-client Stop.

### D1 Exit

- [ ] daemon restart بعد stop يعيد tool status cancelled نفسها.
- [ ] لا تبقى currently-executing tool ids بعد نجاح terminalization.

## 4. Gate D2 — Late-result isolation

- [ ] رفض timeout أو result من run لم تعد مالكة.
- [ ] عدم استبدال cancelled بنتيجة error/done متأخرة.
- [ ] إعادة فحص owner والـterminal revision داخل آخر persistence boundary قبل
      commit للنتيجة الطبيعية، حتى إذا بدأت المعالجة قبل وصول Stop.
- [ ] رفض progress/output projection المتأخرة من run invalidated مع السماح
      للprocess controller باستكمال drain داخلي غير مرئي.
- [ ] عدم إرسال tool result الملغاة إلى provider continuation.
- [ ] إبقاء completed outputs السابقة سليمة.

### D2 Exit

- [ ] late result لا تغير history أو snapshot أو run أحدث.
- [ ] cancellation تبقى النتيجة المرئية والدائمة النهائية.

## 5. Gate D3 — Protocol/history verification

- [ ] اختبارات event ordering والهوية والـidempotency.
- [ ] اختبار history hydration بعد stop/restart.
- [ ] اختبار stop أثناء tool timeout race.
- [ ] اختبار نتيجة success تعود بعد تثبيت cancelled وقبل محاولة commit، وإثبات
      أن compare-and-set تخسر بلا event أو revision إضافية.
- [ ] اختبار output تصل بعد stop barrier وقبل process exit ولا تغير live/history.
- [ ] تحديث interfaces contract وcommunication/event parity docs.

### D3 Exit / Definition of Done

- [ ] كل tool_use لها terminal event واحدة حتى عند Stop.
- [ ] live/history payloads متطابقة دلاليًا.
- [ ] Reference parity audit يثبت أن التنفيذ والاختبارات يحققان كل قرار
      `Adopt/Adapt` مسجل، أو يعيد أي deviation إلى تصميم المهمة.
- [ ] المهمة داخل file budget.

## 6. الملفات المتوقعة

- `agent/lib/engine/runtime/tool_execution_coordinator.dart`
- `agent/lib/interfaces/runtime/session_run_orchestrator.dart`
- persisted runtime/checkpoint owner تحت `agent/lib/evolution/db/`
- `agent/lib/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart`
- `agent/lib/interfaces/platforms/sanad_gateway/handlers/session_query_handler.dart`
- اختبارات engine/interfaces/history المركزة (3–4 ملفات)
- `agent/lib/interfaces/AGENTS.md`
- `docs/technical/communication_protocols.md`
- `docs/qa_maintenance/conversation_event_parity_qa.md`
- ملف المهمة والخطة الأم

## 7. سيناريو نجاح

تبدأ shell tool ثم يصل Stop ويتزامن معه timeout متأخر. تحفظ وتبث `cancelled` مرة واحدة، يأتي `stopped` بعدها، تصبح الجلسة idle، ثم يعيد history query نفس tool call بهوية ونص cancellation نفسيهما.

## 8. سجل التقدم

```text
Date:
Gate/status:
Files changed:
Verification:
Findings:
Next gate:
```
