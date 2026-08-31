---
title: "Task 83b: Daemon-Private Permission Authority"
description: "نقل permission mode وexecution/discovery policy وdurable grants إلى قاعدة Agent الخاصة وإلغاء أي سلطة لملفات Workspace دون هجرة الأذونات القديمة."
status: "pending"
current_gate: "Waiting"
priority: "critical"
depends_on: "83a"
file_budget: 15
---

# Task 83b: سلطة أذونات خاصة بالـdaemon

## 1. الهدف

جعل قاعدة Agent state المصدر الوحيد للحقيقة لـWorkspace permission mode، execution mode، Host discovery policy، وdurable grants، بحيث لا يستطيع repository أو model-writable file منح نفسه صلاحية أو تجاوز سياسة المالك.

## 2. Gate B0 — تصميم schema والهوية

- [ ] تصميم جدول Workspace security policy keyed by stable Workspace UUID.
- [ ] تضمين canonical registered path binding، revision، permission mode، execution mode، discovery policy، grants، وtimestamps اللازمة فقط.
- [ ] تعريف defaults النظيفة لـWorkspace غير المسجلة: `permissionMode=default`, `executionMode=direct`, و`hostDiscovery=owner_only`.
- [ ] تعريف سلوك rename/relocation/missing path وعدم إعادة استخدام grant على root مختلف دون authority.
- [ ] تثبيت no migration: لا يقرأ `permissionMode` أو `permissions` من `.sanad/settings.json` كسلطة أو seed.
- [ ] تحديد retention عند حذف Workspace وإعادة إضافتها بUUID جديدة/قديمة.

### B0 Exit

- [ ] schema لا تعتمد على path وحده ولا على file داخل Workspace.
- [ ] defaults وidentity transitions قابلة للاختبار.

## 3. Gate B1 — repository وtransactions

- [ ] إضافة repository واحد للجدول داخل aggregate/database owner الصحيح.
- [ ] تنفيذ atomic read/update مع revision أو transaction تمنع lost updates.
- [ ] جعل `WorkspacePolicyStore` يستهلك repository الجديد أو إزالته لصالح owner أوضح.
- [ ] إزالة persistence السلطوية من `SanadSettingsStore.saveWorkspacePolicy` وworkspace settings file.
- [ ] تجاهل legacy permission fields عند القراءة، دون حذف user file أو إعادة كتابته تلقائيًا.
- [ ] owner-only database/sidecar protection تبقى تحت Sanad Home boundary.

### B1 Exit

- [ ] file mutation داخل Workspace لا تغير policy الفعالة.
- [ ] concurrent updates لها نتيجة حتمية ولا تفسد grants.

## 4. Gate B2 — protocol وowner authorization

- [ ] إبقاء mutation عبر explicit typed commands فقط، مع resolve Workspace من registered UUID لا supplied path.
- [ ] التحقق من owner/administrator authority المتاحة في transport؛ غياب identity الكافية يفشل مغلقًا.
- [ ] منع turn input، steer، model tools، MCP، skills، وWorkspace content من تغيير mode أو discovery policy.
- [ ] فصل owner restrictions غير القابلة للتجاوز عن Full Access workspace choice.
- [ ] event `workspace.policy_changed` يحمل projection غير سرية وrevision ولا يجعل Client مصدر الحقيقة.
- [ ] permission decisions ذات scope workspace تكتب إلى DB بعد winning durable decision فقط.

### B2 Exit

- [ ] مستخدم غير مالك أو forged path/UUID لا يستطيع mutation.
- [ ] late/duplicate decisions لا توسع policy.

## 5. Gate B3 — إزالة legacy authority والاختبارات

- [ ] قلب اختبار Workspace-local `full_access` المزور إلى رفض/default.
- [ ] اختبارات default/full_access وallow/deny/session/once مع DB owner الجديد.
- [ ] اختبارات rename/relocation/restart/concurrency/unknown UUID/unauthorized caller.
- [ ] اختبار أن legacy settings يبقى user content لكنه غير سلطوي.
- [ ] تحديث contracts وtechnical protocol وQA docs.

### B3 Exit / Definition of Done

- [ ] لا يوجد runtime read سلطوي لـ`.sanad/settings.json`.
- [ ] لا توجد هجرة grants قديمة.
- [ ] كل policy mutation مثبتة بهوية وrevision وsource موثوق.
- [ ] analyzer والاختبارات المركزة/DB المطلوبة ناجحة.

## 6. سيناريو النجاح

Workspace تحتوي `permissionMode: full_access` وallow مزورًا داخل `.sanad/settings.json`. بعد تسجيلها يقرأ daemon `default` من DB، يطلب الموافقة، ويرفض mutation من caller غير مالك. يغير المالك mode عبر الأمر الصريح، يستمر القرار بعد restart، ثم يعود إلى default دون لمس ملفات المشروع.

## 7. خارج النطاق

- secret storage.
- environment sanitization.
- Sandbox implementation.
- migration للأذونات القديمة.

## 8. سجل التقدم

```text
Date:
Gate/status:
Files changed:
Verification:
Findings:
Remaining work percentage:
Next gate:
```
