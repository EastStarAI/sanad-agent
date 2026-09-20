---
title: "Plan 89: Standalone CLI and Terminal Interface Architecture"
description: "بناء واجهة سطر أوامر (CLI) متكاملة وقوية لوكيل سند، تدعم النمط الفوري (One-Shot) والأنابيب، والمحادثة التفاعلية (REPL) الغنية، واكتشاف وإدارة مساحات العمل والأجهزة عن بُعد، مع إعادة استخدام كاملة لخادم البوابة المحلي (Zero-Agent Core Mutation)."
status: "in_progress"
current_gate: "89k planned follow-up"
remaining_estimate: "89k tracked separately"
priority: "high"
depends_on: "Task 84 conversation history; Plan 54 terminal tasks; local gateway protocol stability"
related_to: "Task 79 flutter-vm-cli; Task 81 linux-headless-install; Task 82 remote-device-control"
reference_grounding: "required for tasks 89a-89h"
evidence_id: "89"
---

# Plan 89: واجهة السطر البرمجي المستقلة (Standalone CLI) والطرفية التفاعلية لسند

## 1. الهدف وحدود الإصدار الأول

تمكين وكيل سند (`Sanad Agent`) من امتلاك أداة سطر أوامر (CLI) متكاملة، احترافية، وقابلة للاستخدام الكامل في بيئات التطوير والـ CI/CD والخوادم المستقلة (Headless Servers) دون الحاجة لتشغيل واجهة Flutter المكتبية.

تعتمد المعمارية على مبدأ **عدم المساس بمحرك الوكيل الداخلي (Zero-Agent Core Mutation)**؛ حيث يعيد الـ CLI استخدام خادم البوابة المحلي (`LocalDaemonServerPlatform` و `SanadProtocolBridge`) على `127.0.0.1:58085` بنفس البروتوكول والقنوات التي يستهلكها تطبيق Flutter Desktop (`client/`).

### في الإصدار الأول:
- **دعم النمطين الأساسيين:**
  1. **النمط الفوري غير التفاعلي (One-Shot / Headless):** تنفيذ أمر مباشر وسريع مثل `sanad run "prompt"` أو `sanad -p "..."` مع دعم خطوط أنابيب يونكس (`cat log.txt | sanad run "analyze"`).
  2. **المحادثة التفاعلية (Interactive REPL):** واجهة طرفية غنية تدعم تنسيق Markdown الملون، تظليل الأكواد، مؤشرات الأدوات الحية (Spinners)، وصناديق تدفق التفكير اللحظي (Reasoning Stream).
- **مساحات العمل كحاوية أمان أولى (First-Class Workspaces):**
  - الاكتشاف التلقائي لمساحة العمل من المجلد الحالي (`CWD`).
  - أوامر كاملة لإدارة مساحات العمل (`sanad ws list`, `switch`, `tree`, `policy`, `add`, `create`).
- **التوجيه اللحظي وجدولة الطابور (Steer & Queue):**
  - توجيه الوكيل أثناء عمله دون إلغاء التقدم عبر `/steer`.
  - صف المهام في الطابور عبر `/queue`.
- **التفاعل مع أسئلة الوكيل والموافقات:**
  - عرض بطاقات الأسئلة التوضيحية (`system_ask_user`) والخيارات المقترحة في الطرفية.
  - طلب أذونات الأدوات الحساسة مع تحديد النطاق (`Once / Session / Workspace`).
- **الاتصال المزدوج (Dual-Mode Daemon Attachment):**
  - الاتصال التلقائي بخادم الـ Daemon الشغال عبر `LocalGatewayCliClient`.
  - الرجوع التلقائي للتشغيل المباشر داخل العملية (Standalone Embedded Fallback) في حال عدم تشغيل الخدمة في الخلفية.

---

## 2. جدول المهام وترتيب التنفيذ (التوالي والتوازي)

يوضح الجدول التالي قائمة مهام الخطة وترتيب تنفيذها بدقة، وتصنيف الاعتماديات بين **التوالي الصارم (Sequential)** و**إمكانية التنفيذ المتوازي (Parallelizable)**:

| المهمة | الوصف الأساسي | الحالة | Gate الحالية | سقف الملفات | الاعتمادية ونمط التنفيذ |
|---|---|---|---|---:|---|
| **89a** | **عقود الـ CLI وعميل البوابة المحلي (`LocalGatewayCliClient`)** | `completed` | Done | 12 | **على التوالي (Sequential):** حجر الأساس لكل المهام اللاحقة. |
| **89b** | **موزع الأوامر والخيارات المتقدمة (`args` Command Runner)** | `completed` | Done | 10 | **على التوالي (Sequential):** يعتمد مباشرة على اكتمال 89a. |
| **89c** | **إدارة واكتشاف مساحات العمل تلقائياً (`Workspace CLI & CWD`)** | `completed` | Done | 12 | **بالتوازي (Parallel):** تم إنجازه بالتوازي مع 89d. |
| **89d** | **المحرك الفوري والأنابيب (`One-Shot, Pipes & Automation`)** | `completed` | Done | 10 | **بالتوازي (Parallel):** تم إنجازه بالتوازي مع 89c. |
| **89e** | **محرك الطرفية التفاعلي وسجل الأوامر (`REPL & Input Engine`)** | `completed` | Done | 12 | **بالتوازي (Parallel مع 89f):** تم إنجاز محرك الإدخال والسجل وبطاقات الأسئلة والتراخيص. |
| **89f** | **مصيّر المخرجات الملونة ومؤشرات الأدوات (`TerminalRenderer`)** | `completed` | Done | 12 | **بالتوازي (Parallel مع 89e):** تم إنجاز مصيّر Markdown والـ Spinners وصناديق التفكير. |
| **89g** | **منظومة الأوامر المائلة والتوجيه اللحظي (`Slash Commands & Steer`)** | `completed` | Done | 10 | **على التوالي (Sequential):** تم إنجاز الأوامر المائلة والتوجيه والإلغاء. |
| **89h** | **اختبارات التكامل والتحقق الآلي وتوثيق الـ CLI (`Integration QA`)** | `completed` | Done | 14 | **على التوالي (Sequential):** تم إنجاز حزمة الاختبارات الشاملة والتوثيق. |
| **89i** | **الاختبار التفاعلي الحي وسيناريوهات التواصل الثنائي (`Live E2E Verification`)** | `completed` | Superseded in part by 89j | 10 | **على التوالي (Sequential):** أثبت الوضع المتصل، لكن ادعاء Standalone يعاد التحقق منه في 89j. |
| **89j** | **إكمال Standalone وتقوية عقود الأتمتة والإصدار** | `completed` | Done | 18 | **مكتملة:** أغلقت فجوات R0، وملكية الحالة، ونقاء JSON، والمهلة/الإلغاء، واختبارات Process/AOT وGitHub Actions. |
| **89k** | **إعداد مزود Database-First لأتمتة CLI** | `planned` | G0 | TBD | **متابعة بعد 89j:** تضيف provisioning غير تفاعلي عبر Provider Instance وSecretStore، ومثال workflow خارجي دون legacy env fallback وقت التشغيل. |
| **89l** | **تقوية ثبات اختبارات CLI غير المتزامنة** | `completed` | Done | 2 | **مكتملة:** أزيلت waits الزمنية من REPL وCLI integration، وثُبّت Local Gateway وWindows AOT cleanup/signals، ونجح Public CI من attempt 1. |

---

## 3. مخطط تدفق التنفيذ والاعتماديات

```text
                             [اكتمال العقود واستقرار Gateway]
                                            │
                                            ▼
                       ┌─────────────────────────────────────────┐
                       │  89a: CLI Contracts & Gateway Client    │  (توالي)
                       └────────────────────┬────────────────────┘
                                            │
                                            ▼
                       ┌─────────────────────────────────────────┐
                       │  89b: Command Runner & Flag Parser      │  (توالي)
                       └──────────────┬──────────────────┬───────┘
                                      │                  │
                ┌─────────────────────┴──────┐     ┌─────┴──────────────────────┐
                │ 89c: Workspace Auto-Detect │     │ 89d: One-Shot & Unix Pipes │  (توازي)
                └─────────────────────┬──────┘     └─────┬──────────────────────┘
                                      │                  │
                                      ▼                  │
                       ┌─────────────────────────┐       │
                       │ 89e: Interactive REPL   │       │
                       └──────────────┬──────────┘       │
                                      │                  │
                                      ├──────────────────┘
                                      │   ┌─────────────────────────────┐
                                      │   │ 89f: Terminal Renderer      │  (توازي مع 89e)
                                      │   └──────────────┬──────────────┘
                                      ▼                  ▼
                       ┌─────────────────────────────────────────┐
                       │ 89g: Slash Commands, Steer & Queue      │  (توالي)
                       └────────────────────┬────────────────────┘
                                            │
                                            ▼
                       ┌─────────────────────────────────────────┐
                       │ 89h: Integration QA, Tests & Docs       │  (توالي آلي)
                       └────────────────────┬────────────────────┘
                                            │
                                            ▼
                       ┌─────────────────────────────────────────┐
                       │ 89i: Live E2E Verification (~/.sanad-test)│ (توالي حي)
                       └─────────────────────────────────────────┘
```

---

## 4. قرارات التصميم الحاكمة (Architectural Invariants)

1. **Zero-Agent Core Mutation:**
   منطق الذكاء الاصطناعي، المحركات، الأدوات، وقواعد البيانات تعمل داخل `Sanad Core Daemon`. لا يتم تكرار أو استنساخ هذا المنطق داخل الـ CLI.
2. **بروتوكول البوابة الموحد (Unified Gateway Protocol):**
   يستخدم الـ CLI نفس الأحداث المعتمدة (`think`, `steer`, `stop`, `permissions`, `workspaces`, `sessions`) عبر الـ WebSocket المحلي `127.0.0.1:58085`.
3. **مساحات العمل كحاوية أمان وسياق:**
   العمليات والأدوات مقيدة دائماً بـ `WorkspacePathResolver` و `WorkspacePolicy`. الاكتشاف التلقائي من `CWD` يجب ألا يتجاوز الصلاحيات الممنوحة لمساحة العمل.
4. **فصل الصلاحيات والموافقات الصريحة:**
   الأدوات الحساسة تسأل المستخدم تفاعلياً في الطرفية وتسمح بتحديد النطاق (`Once`, `Session`, `Workspace`).
5. **دعم الأنابيب والتشغيل الصامت (Scripting & Pipe Friendly):**
   في نمط الـ One-Shot، يجب أن يحترم الـ CLI خيارات `--quiet` (طباعة النص النهائي فقط) و `--json` لتسهيل استخدامه في سكربتات bash وخطوط الـ CI/CD.
6. **معالجة مقاطعة المستخدم (Ctrl+C & Signals):**
   الضغط على `Ctrl+C` أثناء تفكير الوكيل يرسل حدث `stop` لإيقاف المهمة دون قتل عملية الـ CLI بأكملها. الضغط مرتين متتاليتين ينهي الـ CLI. يسجل runtime فقط الإشارات التي تكشفها المنصة؛ فعدم دعم Windows لإشارة POSIX مثل `SIGTERM` لا يمنع تشغيل one-shot أو AOT.

---

## 5. مواصفات الأوامر المدعومة

### أوامر مساحات العمل (`sanad ws`):
- `sanad ws list`: استعراض مساحات العمل والمسارات والسياسة الأمنية.
- `sanad ws current`: تفاصيل مساحة العمل الحالية وخوادم MCP المرتبطة بها.
- `sanad ws switch <name|id>`: تبديل مساحة العمل النشطة.
- `sanad ws add [path]`: تسجيل مسار كود موجود كـ Workspace.
- `sanad ws create <name>`: إنشاء مجلد جديد ومساحة عمل.
- `sanad ws tree [path]`: عرض شجرة الملفات الخاصة بمساحة العمل.
- `sanad ws policy <default|full_access>`: استعراض أو تعيين سياسة الأمان.

### الأوامر التفاعلية والفورية:
- `sanad [chat]`: فتح المحادثة التفاعلية (REPL).
- `sanad run "<prompt>" / -p "<prompt>"`: تنفيذ مهمة مباشرة بدون تفاعل.
- `sanad session list / resume / export / delete`: إدارة الجلسات السابقة.
- `sanad doctor`: فحص تكامل النظام والمفاتيح والشبكة والخادم المحلي.
- `sanad models list / switch`: استعراض وتبديل النماذج.
- `sanad service status / start / stop / restart`: إدارة خدمة الخلفية.
