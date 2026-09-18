---
title: "Task 89d: Headless One-Shot and Unix Pipe Runner"
description: "بناء محرك التنفيذ الفوري غير التفاعلي `sanad run` و `-p` مع دعم كامل لخطوط أنابيب يونكس وخيارات الأتمتة `--quiet` و `--json`."
status: "completed"
current_gate: "Completed"
priority: "high"
depends_on: "Task 89b complete"
file_budget: 10
reference_grounding: "required"
evidence_id: "89d"
parallel_with: "Task 89c"
---

# Task 89d: Headless One-Shot and Unix Pipe Runner

## 1. الهدف

تمكين المطورين وخطوط الـ CI/CD والسكربتات من تنفيذ مهام ذكاء اصطناعي مباشرة عبر سطر الأوامر دون فتح محادثة تفاعلية، مع إنهاء العملية بمجرد اكتمال الدور وإرجاع رمز خروج مناسب (`exit code 0/1`).

## Gate A0 — Specifications

- [x] دعم الصياغات: `sanad run "<prompt>"` و `sanad -p "<prompt>"`.
- [x] اكتشاف وجود بيانات عبر `stdin` (Piped input): `cat logs.txt | sanad run "find errors"`.
- [x] دعم خيار `--quiet` (طباعة نص الرد النهائي فقط) وخيار `--json` (إخراج كائن JSON منظم للنتيجة وتفاصيل الأدوات).

## Gate A1 — Implementation

- [x] إنشاء جلسة مؤقتة أو استهداف جلسة محددة عبر `--session`.
- [x] إرسال حدث `think` عبر `LocalGatewayCliClient` ومراقبة اكتمال الدور `turnComplete`.
- [x] معالجة طلبات الأذونات في الوضع غير التفاعلي (رفض الأدوات غير المسموحة افتراضياً ما لم تكن السياسة `full_access`).
- [x] إرجاع رمز الخروج الصحيح (0 للنجاح، 1 للفشل أو أخطاء النموذج).

## Gate A2 — Verification (DoD)

- [x] اختبارات الأنابيب (Pipes) واختبارات الأتمتة في بيئات غير تفاعلية (Non-TTY).
- [x] التحقق من مخرجات `--json` وسلامة الـ schema.

## 2. Verification Evidence

- Analyzer: `fvm dart analyze` returned 0 errors and 0 warnings.
- Test Suite: `fvm dart test test/cli/run_command_test.dart` passed 13/13 tests:
  - `executes one-shot task and streams tokens in real time`
  - `supports one-shot execution via top-level -p flag`
  - `supports session targeting override via --session`
  - `concatenates prompt with piped input from stdin (e.g. cat file | sanad run "analyze")`
  - `uses piped input as prompt when no rest argument is provided`
  - `--quiet suppresses headers, tool logs, and outputs only the final assistant text`
  - `--json outputs structured JSON object with text, tool executions, and usage`
  - `rejects gated tool permission request under default restricted policy without blocking`
  - `auto-approves tool permission request when workspace-policy is full_access`
  - `returns exit code 1 when no prompt or piped input is provided`
  - `returns exit code 1 when server emits CliErrorEvent`
  - `returns exit code 1 and formatted JSON when server error occurs in --json mode`
  - `returns exit code 1 when connection is lost before turn completes`
- Overall CLI Suite: `fvm dart test test/cli/` passed 74/74 tests.
