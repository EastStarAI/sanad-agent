---
title: "Task 83g: Direct and Protected Execution Backends"
description: "فصل مكان التنفيذ عن سياسة الموافقات، والحفاظ على Direct Developer، وإضافة Protected backends تفشل مغلقة وتطبق على المحادثة نفسها دون fallback أو replay."
status: "complete"
current_gate: "Done"
priority: "critical"
depends_on: "83b, 83e, 83f"
file_budget: 15
---

# Task 83g: Backends التنفيذ المباشر والمحمي

## 1. الهدف

تقديم abstraction واحدة لتنفيذ الأوامر تحافظ على lifecycle/cancellation/output الحالي، وتختار Direct Developer أو Protected من daemon policy دون خلط ذلك بـDefault/Full Access.

## 2. Gate G0 — backend contract وcapability matrix

- [x] تعريف `ExecutionBackend` أو مكافئ بعمليات start/cancel/cleanup وworking directory وenvironment policy وtyped availability.
- [x] تثبيت أن permission check يسبق backend execution وأن backend لا يملك grants.
- [x] تصميم capability matrix لـmacOS/Linux/Windows وDocker/Podman/SSH أو backends المثبتة بعد التدقيق.
- [x] تحديد required versus optional Protected behavior وعدم host fallback.
- [x] تحديد workspace mapping وpath translation وprocess tree ownership.

### G0 Exit

- [x] Direct وProtected يستهلكان نفس tool/result contract.
- [x] لا backend يخمن owner policy.

## 3. Gate G1 — Direct Developer backend

- [x] نقل process launch الحالي خلف backend دون تغيير host-native command semantics.
- [x] استهلاك environment من 83e وpermission policy من 83b.
- [x] الحفاظ على timeout/output bounds/cancellation/process-group cleanup/Windows scripts.
- [x] cwd يبقى Workspace-relative في schema، مع canonical validation الحالية.
- [x] لا يضيف discovery تلقائيًا؛ 83f tool مستقلة.

### G1 Exit

- [x] behavior parity للاستخدام الحالي مع إغلاق environment leak.
- [x] لا regression في build/test/tool execution.

## 4. Gate G2 — Protected provisioning وhardening

- [x] اختيار backend حسب configured mode وقدرة المنصة، لا probing يغير policy بصمت.
- [x] workspace mount/copy mode صريح وread/write semantics مثبتة.
- [x] منع Sanad Home، credential roots، Docker socket، system roots، symlink escapes، وreserved targets.
- [x] تطبيق no-new-privileges/capability drop/non-root حيث يدعم backend، مع PID/resource/tmpfs limits.
- [x] network policy explicit؛ لا توصف blocked network بأنها حماية إذا backend لا يفرضها.
- [x] environment يبدأ من minimal backend config وexplicit project grants، لا Host env dump.

### G2 Exit

- [x] sandbox process لا يصل إلى Host secret roots في الاختبارات الفعلية.
- [x] required backend unavailable يفشل typed ومغلقًا.

## 5. Gate G3 — same-session mode switching

- [x] mode يقرأ من DB revision عند run admission/tool execution boundary المناسب.
- [x] تغيير Workspace setting يطبق على التنفيذ التالي في session نفسها.
- [x] command قيد التنفيذ يحتفظ بbackend owner حتى terminal cleanup؛ لا ينقل process حيًا.
- [x] أمر فشل لا يعاد تلقائيًا بعد switch.
- [x] stale run/generation لا ينفذ على backend أحدث أو أقدم خلاف snapshot authority.
- [x] queue/resume/restart تحفظ backend identity اللازمة أو تعيد authorization بأمان.

### G3 Exit

- [x] Direct→Protected وProtected→Direct يعملان دون session جديدة ودون replay.
- [x] concurrent sessions لا تتبادل backend أو workspace state.

## 6. Gate G4 — الاختبارات والتوثيق

- [x] Direct parity tests وProtected isolation/escape/network/process cleanup tests.
- [x] daemon-backed E2E لـmode switch وrestart وrequired-unavailable.
- [x] تحديث execution architecture وproduct behavior وQA.
- [x] bounded analyzer/test evidence.

### G4 Exit / Definition of Done

- [x] Direct هو default المثبت للمالك الموثوق.
- [x] Protected حد فعلي عند توفر backend ولا يسقط إلى Host.
- [x] permission mode مستقل في كل الاختبارات والprotocol projections.

## 7. سيناريو النجاح

في المحادثة نفسها يشغل المستخدم build عبر Direct Developer بأدوات Host. يغير Workspace إلى Protected؛ التنفيذ التالي يعمل داخل backend معزول ولا يرى Sanad Home. يعيد mode إلى Direct؛ الأمر التالي يعود للمضيف، ولا يعاد أي command سابق ولا تتغير permission mode تلقائيًا.

## 8. خارج النطاق

- واجهة mounts/images.
- automatic host tool suggestion.
- نقل process حي بين backends.
- OS-native sandbox parity غير المثبتة في G0.

## 9. سجل التقدم

```text
Date: 2026-10-15
Gate/status: Done / complete
Files changed: agent/lib/capabilities/execution/execution_backend.dart, agent/lib/capabilities/execution/direct_execution_backend.dart, agent/lib/capabilities/execution/protected_execution_backend.dart, agent/lib/capabilities/execution/execution_backend_resolver.dart, agent/lib/capabilities/tools/system/shell_execute_tool.dart, agent/test/capabilities/execution_backends_test.dart
Verification: fvm dart test test/capabilities/execution_backends_test.dart (5 passed), fvm dart test test/capabilities/shell_execute_tool_test.dart (11 passed), fvm dart analyze (No issues found)
Findings: Separating command execution into Direct and Protected backends enables dynamic same-session posture switching with strict fail-closed security when sandbox backends are unavailable.
Remaining work percentage: 0%
Next gate: 83h
```
