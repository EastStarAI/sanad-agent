---
title: "Task 50b: Provider Request Interruption and Watchdogs"
description: "جعل اتصالات المزود قابلة للقطع بالـrun cancellation أثناء connect/send/SSE مع timeouts مرحلية ومنع retry بعد user stop."
status: "complete"
current_gate: "closed"
priority: "critical"
depends_on: "50a"
file_budget: 14
reference_grounding: "required"
evidence_id: "50b"
design_contract: "docs/technical/run_cancellation_and_process_ownership.md"
---

# Task 50b: Provider Request Interruption and Watchdogs

## 1. الهدف

قطع طلب المزود فورًا عند Stop سواء كان معلقًا قبل headers أو أثناء stream، دون إغلاق طلبات جلسات أخرى أو تصنيف الإلغاء كفشل شبكة قابل لإعادة المحاولة.

### قاعدة التسليم

- التنفيذ داخل worktree معزول على فرع تجميعي `feat/plan-50-run-cancellation`.
- لا دمج على `main` حتى اكتمال Plan 50 بالكامل (50a–50f) والتحقق النهائي.

## Gate R0 — External Reference Grounding

- [x] حل `evidence_id` عبر workflow التأصيل الخارجي والتحقق من freshness.
- [x] قراءة implementations والاختبارات الإلزامية وتسجيل مصفوفة
      `Adopt / Adapt / Reject` محلية ومحايدة المصدر.
- [x] تحويل القرارات المقبولة إلى invariants واختبارات صريحة لهذه المهمة.
- [x] عند غياب الحزمة أو قدمها، تشغيل authoring/refresh حتى تصبح `ready`.
- [x] عدم بدء B0 قبل `ready`؛ لا تسجل `blocked` إلا لمانع غير قابل للتعافي.

### R0 Exit

- [x] سجل التأصيل يحمل fingerprint والرموز والاختبارات المتحققة والقرارات.
- [x] لا يحتوي أي ملف متتبع هوية المصدر الخارجي أو مساره؛ يبقى العقد سلوكيًا.

## 2. Gate B0 — Transport ownership contract

- [x] تحديد request-owned cancel handle يستهلك `RunCancellationScope` من options.
- [x] منع إغلاق HTTP client مشتركة بين runs.
- [x] تعريف exception/result typed للإلغاء اليدوي منفصل عن timeout/network.
- [x] تثبيت مراحل watchdog: connect/headers، first byte، stream idle، وtotal الاختيارية.

### B0 Exit

- [x] كل adapter تستطيع قطع requestًا دون التأثير على غيرها.
- [x] قيم watchdog مركزية وقابلة للتهيئة وليست literals موزعة.

## 3. Gate B1 — OpenAI-compatible وCodex Responses

- [x] قطع `send` المعلقة عند cancellation.
- [x] قطع SSE byte stream عند cancellation أو stream-idle timeout.
- [x] ضمان إغلاق transport في success/error/cancel paths.
- [x] منع request dump أو accumulated response المتأخر من تغيير run الملغاة.
- [x] الحفاظ على provider state semantics في Codex Responses.

### B1 Exit

- [x] fake transport قبل headers وأثناء SSE ينتهي فور Stop.
- [x] cancellation لا تتحول إلى retry أو runtime network notice.

## 4. Gate B2 — Anthropic-compatible وOllama

- [x] تطبيق نفس transport contract دون تكرار منطق cancellation.
- [x] توحيد parsing behavior الحالي مع إغلاق stream الآمن.
- [x] التأكد من أن inherited/overridden paths كلها تستهلك scope.

### B2 Exit

- [x] جميع adapters الإنتاجية تتبع العقد نفسه.
- [x] adapter لا تدعم الإلغاء لا يمكن تسجيلها صامتًا كproduction-ready.

## 5. Gate B3 — Recovery/rate-limit integration

- [x] دمج cancel token الحالي للـrate-limit مع scope الموحدة أو تفويضه لها.
- [x] منع auto retry/failover بعد `userStop`.
- [x] إبقاء network retry المشروع مستقلًا عن cancellation.
- [x] رفض أي progress متأخر لا تملكه run الحالية.

### B3 Exit

- [x] user stop لا يولد provider recovery notice جديدة.
- [x] rate-limit waits القديمة لا تستأنف run ملغاة.

## 6. Gate B4 — التحقق والتوثيق

- [x] اختبارات send لا تنتهي، headers بلا body، stream يتوقف، وlate chunk.
- [x] اختبار عزل طلبين متوازيين وإلغاء أحدهما فقط.
- [x] اختبارات adapters الحالية وprovider-state تمر دون تراجع.
- [x] تحديث engine contract وprovider/runtime QA.

### B4 Exit / Definition of Done

- [x] Stop يقطع كل provider path إنتاجية دون انتظار server response.
- [x] لا leak لاتصال ولا retry/failover بعد user cancellation.
- [x] Reference parity audit يثبت أن التنفيذ والاختبارات يحققان كل قرار
      `Adopt/Adapt` مسجل، أو يعيد أي deviation إلى تصميم المهمة.
- [x] المهمة داخل file budget.

## 7. الملفات المتوقعة

- `agent/lib/engine/adapters/llm_request_options.dart`
- transport/cancellation helper جديد تحت `agent/lib/engine/adapters/`
- `agent/lib/engine/adapters/base_openai_adapter.dart`
- `agent/lib/engine/adapters/codex_responses_adapter.dart`
- `agent/lib/engine/adapters/base_anthropic_adapter.dart`
- `agent/lib/engine/adapters/ollama_adapter.dart`
- `agent/lib/engine/adapters/rate_limited_llm_adapter.dart`
- اختبارات adapters المركزة (3–4 ملفات)
- `agent/lib/engine/AGENTS.md`
- `docs/technical/provider_protocol.md`
- ملف المهمة والخطة الأم

## 8. سيناريو نجاح

يبدأ طلبان لمزودين أو جلستين؛ الأول لا يعيد headers والثاني يبث طبيعيًا. إلغاء الأول يقطع اتصاله داخل deadline، ولا يغلق الثاني، ولا ينشئ retry أو failover أو notice جديدة للأول.

## 9. سجل التقدم

```text
Date: 2026-08-29
Gate/status: complete / closed
Files changed: ProviderRequestTransport + watchdogs + cancelled exception;
  BaseOpenAI/Anthropic/Codex/Ollama + RateLimitedLLMAdapter + AgentRunner;
  tests; engine AGENTS; provider_protocol; plan/task docs
Verification: fvm dart analyze clean; provider_request_transport +
  llm_request_options + run_cancellation_scope + adapters_test (50) passed
Findings: none blocking
Next gate: 50c
```
