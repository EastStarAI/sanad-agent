---
title: "Task 83g: Direct and Protected Execution Backends"
description: "فصل مكان التنفيذ عن سياسة الموافقات، والحفاظ على Direct Developer، وإضافة Protected backends تفشل مغلقة وتطبق على المحادثة نفسها دون fallback أو replay."
status: "pending"
current_gate: "Waiting"
priority: "critical"
depends_on: "83b, 83e, 83f"
file_budget: 15
---

# Task 83g: Backends التنفيذ المباشر والمحمي

## 1. الهدف

تقديم abstraction واحدة لتنفيذ الأوامر تحافظ على lifecycle/cancellation/output الحالي، وتختار Direct Developer أو Protected من daemon policy دون خلط ذلك بـDefault/Full Access.

## 2. Gate G0 — backend contract وcapability matrix

- [ ] تعريف `ExecutionBackend` أو مكافئ بعمليات start/cancel/cleanup وworking directory وenvironment policy وtyped availability.
- [ ] تثبيت أن permission check يسبق backend execution وأن backend لا يملك grants.
- [ ] تصميم capability matrix لـmacOS/Linux/Windows وDocker/Podman/SSH أو backends المثبتة بعد التدقيق.
- [ ] تحديد required versus optional Protected behavior وعدم host fallback.
- [ ] تحديد workspace mapping وpath translation وprocess tree ownership.

### G0 Exit

- [ ] Direct وProtected يستهلكان نفس tool/result contract.
- [ ] لا backend يخمن owner policy.

## 3. Gate G1 — Direct Developer backend

- [ ] نقل process launch الحالي خلف backend دون تغيير host-native command semantics.
- [ ] استهلاك environment من 83e وpermission policy من 83b.
- [ ] الحفاظ على timeout/output bounds/cancellation/process-group cleanup/Windows scripts.
- [ ] cwd يبقى Workspace-relative في schema، مع canonical validation الحالية.
- [ ] لا يضيف discovery تلقائيًا؛ 83f tool مستقلة.

### G1 Exit

- [ ] behavior parity للاستخدام الحالي مع إغلاق environment leak.
- [ ] لا regression في build/test/tool execution.

## 4. Gate G2 — Protected provisioning وhardening

- [ ] اختيار backend حسب configured mode وقدرة المنصة، لا probing يغير policy بصمت.
- [ ] workspace mount/copy mode صريح وread/write semantics مثبتة.
- [ ] منع Sanad Home، credential roots، Docker socket، system roots، symlink escapes، وreserved targets.
- [ ] تطبيق no-new-privileges/capability drop/non-root حيث يدعم backend، مع PID/resource/tmpfs limits.
- [ ] network policy explicit؛ لا توصف blocked network بأنها حماية إذا backend لا يفرضها.
- [ ] environment يبدأ من minimal backend config وexplicit project grants، لا Host env dump.

### G2 Exit

- [ ] sandbox process لا يصل إلى Host secret roots في الاختبارات الفعلية.
- [ ] required backend unavailable يفشل typed ومغلقًا.

## 5. Gate G3 — same-session mode switching

- [ ] mode يقرأ من DB revision عند run admission/tool execution boundary المناسب.
- [ ] تغيير Workspace setting يطبق على التنفيذ التالي في session نفسها.
- [ ] command قيد التنفيذ يحتفظ بbackend owner حتى terminal cleanup؛ لا ينقل process حيًا.
- [ ] أمر فشل لا يعاد تلقائيًا بعد switch.
- [ ] stale run/generation لا ينفذ على backend أحدث أو أقدم خلاف snapshot authority.
- [ ] queue/resume/restart تحفظ backend identity اللازمة أو تعيد authorization بأمان.

### G3 Exit

- [ ] Direct→Protected وProtected→Direct يعملان دون session جديدة ودون replay.
- [ ] concurrent sessions لا تتبادل backend أو workspace state.

## 6. Gate G4 — الاختبارات والتوثيق

- [ ] Direct parity tests وProtected isolation/escape/network/process cleanup tests.
- [ ] daemon-backed E2E لـmode switch وrestart وrequired-unavailable.
- [ ] تحديث execution architecture وproduct behavior وQA.
- [ ] bounded analyzer/test evidence.

### G4 Exit / Definition of Done

- [ ] Direct هو default المثبت للمالك الموثوق.
- [ ] Protected حد فعلي عند توفر backend ولا يسقط إلى Host.
- [ ] permission mode مستقل في كل الاختبارات والprotocol projections.

## 7. سيناريو النجاح

في المحادثة نفسها يشغل المستخدم build عبر Direct Developer بأدوات Host. يغير Workspace إلى Protected؛ التنفيذ التالي يعمل داخل backend معزول ولا يرى Sanad Home. يعيد mode إلى Direct؛ الأمر التالي يعود للمضيف، ولا يعاد أي command سابق ولا تتغير permission mode تلقائيًا.

## 8. خارج النطاق

- واجهة mounts/images.
- automatic host tool suggestion.
- نقل process حي بين backends.
- OS-native sandbox parity غير المثبتة في G0.

## 9. سجل التقدم

```text
Date:
Gate/status:
Files changed:
Verification:
Findings:
Remaining work percentage:
Next gate:
```
