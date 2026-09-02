---
title: "Task 50c: Tool Cancellation and Shell Process Trees"
description: "تمرير run cancellation إلى الأدوات وقتل shell process tree المملوكة بالكامل مع نتائج user-cancelled منفصلة عن timeout."
status: "complete"
current_gate: "C4 complete"
priority: "critical"
depends_on: "50a"
file_budget: 14
reference_grounding: "required"
evidence_id: "50c"
design_contract: "docs/technical/run_cancellation_and_process_ownership.md"
---

# Task 50c: Tool Cancellation and Shell Process Trees

## 1. الهدف

جعل tool execution قابلة للإلغاء التعاوني، وتوفير process-tree controller عبر المنصات يضمن عدم بقاء `git`, hooks، أو grandchildren بعد Stop أو timeout.

## Gate R0 — External Reference Grounding

- [ ] حل `evidence_id` عبر workflow التأصيل الخارجي والتحقق من freshness.
- [ ] قراءة implementations والاختبارات الإلزامية وتسجيل مصفوفة
      `Adopt / Adapt / Reject` محلية ومحايدة المصدر.
- [ ] تحويل القرارات المقبولة إلى invariants واختبارات صريحة لهذه المهمة.
- [ ] عند غياب الحزمة أو قدمها، تشغيل authoring/refresh حتى تصبح `ready`.
- [ ] عدم بدء C0 قبل `ready`؛ لا تسجل `blocked` إلا لمانع غير قابل للتعافي.

### R0 Exit

- [ ] سجل التأصيل يحمل fingerprint والرموز والاختبارات المتحققة والقرارات.
- [ ] لا يحتوي أي ملف متتبع هوية المصدر الخارجي أو مساره؛ يبقى العقد سلوكيًا.

## 2. Gate C0 — Tool cancellation contract

- [ ] توسيع `ToolContext` بهوية run وcancellation scope.
- [ ] تعريف capability تبين هل الأداة cooperative cancellable أم لا.
- [ ] تحديد outcome typed يفرق `cancelled`, `timedOut`, و`failed`.
- [ ] منع coordinator من اعتبار race وحدها تحريرًا للمورد.
- [ ] إبقاء process controller منفصلة عن مالك lifecycle: foreground run تسجل
      termination cleanup، ويمكن تحرير التسجيل فقط بعد اكتمال طبيعي أو claim
      ناجحة من مالك خارجي مستقبلي.

### C0 Exit

- [ ] كل tool تبدأ تملك registration/cleanup path واضحًا.
- [ ] الأدوات غير القابلة للإلغاء معلنة ولا تمر بصمت.

## 3. Gate C1 — ToolExecutionCoordinator integration

- [ ] تمرير scope في المسارات sequential وparallel.
- [ ] تسجيل currently-executing tool calls قبل التنفيذ وإغلاقها terminally بعد cancellation.
- [ ] منع checkpoint أو result متأخرة من run ملغاة.
- [ ] ضمان أن cancellation لا ترسل tool output إلى provider القديمة.
- [ ] إغلاق publication gate synchronously عند invalidation حتى لا تبث progress
      تصل أثناء TERM grace، مع إبقاء stdout/stderr drains الداخلية فعالة.

### C1 Exit

- [ ] fake hanging tool تنتهي cancellation الخاصة بها داخل deadline.
- [ ] إلغاء tool واحدة لا يفسد checkpoint لأدوات completed في الدفعة.
- [ ] output المتأخرة تُستهلك داخليًا بلا conversation/provider update.

## 4. Gate C2 — Cross-platform process tree controller

- [ ] إضافة abstraction تملك process group/tree منذ لحظة spawn.
- [ ] فصل handle الخاصة بالعملية عن cancellation registration حتى يمكن إعادة
      استخدام controller دون إضافة BackgroundTaskManager داخل Plan 50.
- [ ] POSIX: إنشاء command كقائد process group مملوكة قبل بدء side effects، ثم
      إنهاء المجموعة بـTERM فـKILL بعد grace period والتحقق من exit.
- [ ] Windows: إلحاق العملية بـJob Object ذات kill-on-close قبل تركها تعمل، مع
      `taskkill /T /F` كـfallback موثق لا كملكية أساسية صامتة.
- [ ] حفظ process fingerprint تضم PID ووقت البدء وهوية group/job، والتحقق منها
      قبل cleanup متأخرة لمنع قتل PID أعيد استخدامها.
- [ ] استخدام PPID tree walk للتشخيص/fallback فقط؛ لا تعتمد السلامة عليه وحده
      لأنه قد يسابق fork جديدًا أو reparenting.
- [ ] تطبيق `TERM -> bounded grace -> KILL -> verify` بنتيجة cleanup typed تبين
      exited، escalated، ownershipLost، أو failed.
- [ ] drain stdout/stderr وإنهاء cleanup دون deadlock.

### C2 Exit

- [ ] parent/child/grandchild كلها تختفي بعد cancel وtimeout.
- [ ] لا يبقى orphan ولا process تستهلك CPU بعد terminal result.
- [ ] PID fingerprint غير المطابقة تمنع kill وتنتج diagnostics آمنة.

## 5. Gate C3 — Shell outcomes and safety

- [ ] ربط user Stop مباشرة بالـprocess controller.
- [ ] إبقاء timeout آلية مستقلة تستخدم controller نفسها.
- [ ] إخراج `Command cancelled by user.` عند Stop، لا timeout message.
- [ ] توثيق cleanup failure مع process diagnostics من دون كشف secrets.

### C3 Exit

- [ ] `git commit` مع pre-commit child معلق ينتهي فور Stop.
- [ ] timeout وuser cancellation لا يتسابقان لإنتاج نتيجتين.

## 6. Gate C4 — التحقق والتوثيق

- [ ] unit tests للعملية البسيطة وشجرة متعددة المستويات وTERM-resistant child.
- [ ] اختبارات user stop, timeout, repeated cancel، وlate exit.
- [ ] اختبار child تكتب output أثناء TERM grace: لا progress متأخرة ولا pipe
      deadlock، وتبقى terminal cancellation هي النتيجة الوحيدة المنشورة.
- [ ] اختبارات exit أثناء grace، child يتفرع قرب الإلغاء، وPID-reuse guard
      بمضاعف اختبار آمن لا يستهدف عملية حقيقية غير مملوكة.
- [ ] تحديث capabilities contract وagent runtime/QA.
- [ ] مراجعة platform-specific skips وعدم تحويل unit suites كلها إلى sequential.

### C4 Exit / Definition of Done

- [ ] shell process tree تنتهي فعليًا قبل terminal success للحذف.
- [ ] ToolContext الجديدة لا تكسر الأدوات القائمة.
- [ ] كل process تبقى foreground وقابلة للإلغاء افتراضيًا ما لم تحرر registration
      صراحة؛ لا توجد background semantics ضمن هذه المهمة.
- [ ] Reference parity audit يثبت أن التنفيذ والاختبارات يحققان كل قرار
      `Adopt/Adapt` مسجل، أو يعيد أي deviation إلى تصميم المهمة.
- [ ] المهمة داخل file budget.

## 7. الملفات المتوقعة

- `agent/lib/capabilities/tools/base_tool.dart`
- `agent/lib/engine/runtime/tool_execution_coordinator.dart`
- `agent/lib/capabilities/tools/system/shell_execute_tool.dart`
- process-tree abstraction وimplementations تحت `agent/lib/capabilities/tools/system/` (2–3 ملفات)
- `agent/test/capabilities/shell_execute_tool_test.dart`
- اختبارات coordinator/cancellation المركزة (1–2 ملف)
- `agent/lib/capabilities/AGENTS.md`
- `agent/lib/engine/AGENTS.md`
- `docs/technical/agent_runtime.md`
- `docs/qa_maintenance/plan30_runtime_recovery_matrix.md`
- ملف المهمة والخطة الأم

## 8. سيناريو نجاح

تشغل الأداة command تنشئ child وgrandchild لا تنتهيان طبيعيًا. عند Stop تنتهي المجموعة كاملة، تسجل نتيجة cancelled واحدة، لا يبقى PID مملوك، ولا ينتظر المسار `timeout_ms` الأصلي.

سيناريو إضافي للعقد: تنتهي process طبيعية وتحرر cancellation registration، ثم
يصل Stop متأخر للـrun نفسها؛ لا يحاول controller قتل PID المنتهية أو المعاد
استخدامها. لا تنشئ هذه المهمة process خلفية فعلية.

سيناريو احتواء: يبدأ parent ثم ينشئ child مقاومة لـTERM وحفيدًا قرب لحظة Stop.
تستهدف الإشارات containment التي أنشأها Sanad لا snapshot PPID فقط، وتختفي
المجموعة بعد escalation، بينما ترفض محاولة cleanup لاحقة fingerprint مزيفة.

## 9. سجل التقدم

```text
Date:
Gate/status:
Files changed:
Verification:
Findings:
Next gate:
```
