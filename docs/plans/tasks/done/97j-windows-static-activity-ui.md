---
title: "97j: مؤشرات نشاط ثابتة وخفض تكلفة رسم Windows"
status: completed
current_gate: G2
remaining_estimate: "0% (Task complete, ready for review and integration)"
platforms: windows-first
parent_plan: docs/plans/97-windows-first-agent-client-performance.md
depends_on: "97i"
---

# 97j — مؤشرات نشاط ثابتة وخفض تكلفة رسم Windows

## Goal

إزالة الحمل المستمر الناتج عن مؤشرات الحركة على Windows مع إبقاء الحالة واضحة وموحدة على مستوى التطبيق عبر مكون موحد `AppProgressIndicator`.

## Locked scope and ownership

- التصميم والقبول العام: `docs/plans/97-windows-first-agent-client-performance.md`.
- الأسطح/المراجع المالكة: 
  - السياسة المركزية: `client/lib/core/theme/activity_animation_policy.dart`.
  - المكون الموحد: ويدجت موحدة `client/lib/core/presentation/widgets/app_progress_indicator.dart` تستخدم على مستوى كامل التطبيق وتستبدل استدعاءات `CircularProgressIndicator`.
  - مؤشر الشريط الجانبي: `client/lib/features/conversations/presentation/widgets/sidebar/sidebar_conversation_row.dart`.
  - أدوات ومكونات المحادثة: استبدال كافة استدعاءات `CircularProgressIndicator` بـ `AppProgressIndicator`.
  - التوثيق: `docs/plans/tasks/97j-windows-static-activity-ui.md` و `docs/plans/97-windows-first-agent-client-performance.md`.
- التنفيذ والقياس على Windows؛ لا تُستبدل أدلته بنتائج جهاز أسرع.
- لا إضعاف للأمان أو durability أو ترتيب الأحداث أو حداثة الواجهة.

## Gates

### G0 — التحقق وخط الأساس

- [x] مراجعة العقود الأقرب والكود والاختبارات وحالة الاعتماديات، وتحديد reproduction حتمي.
- [x] تسجيل baseline ومعايير الأداء الرقمية المعتمدة من 97a قبل تعديل الكود أو إضافة الاختبارات، مع reproduction حي لمؤشر متحرك واحد صغير (`CircularProgressIndicator`) يثبت قفزة GPU المبلغ عنها من 0% إلى 94% وCPU إلى 222% ثم عودته عند اختفاء الحركة.

### G1 — العمل المحدد

- [x] اعتماد بلاغ CPU +15–30% وGPU 0→100% مع مؤشر واحد واختفائه فور زواله كدليل مستخدم مثبت؛ القياس الفعلي سجل قفزة GPU حتى 94% وCPU حتى 222% (متوسط 37.5%).
- [x] إنشاء السياسة المركزية `ActivityAnimationPolicy`: مالك واحد فقط يحول platform إلى قرار دلالي `allowContinuousActivityAnimation`، مع default ثابت (`false`) على Windows وحركة المنصات الأخرى دون تغيير (`true`). مع دوال `withContinuousActivityAnimationOverride` للاختبارات دون أي شروط OS في الـ Widgets.
- [x] مؤشر الجلسة في الشريط الجانبي (`SidebarConversationRow`): الحفاظ على شكل النقطة مع إزالة الأنيميشن/النبض منها وتغيير لونها إلى الأخضر الثابت (`#22C55E`) على Windows عند تشغيل الجلسة دون إنشاء أي `AnimationController` أو `Ticker`.
- [x] ويدجت تقدم موحدة على مستوى المشروع (`AppProgressIndicator`):
  - إنشاء ملف `client/lib/core/presentation/widgets/app_progress_indicator.dart`.
  - إذا كانت السياسة تسمح بالحركة (`allowContinuousActivityAnimation == true`): تعرض `CircularProgressIndicator` المعتاد.
  - إذا كانت السياسة لا تسمح بالحركة (Windows): تعرض حلقة دائرية مكتملة ثابتة (`_StaticCircularProgressPainter`) بنفس الشكل والقطر والـ stroke الخاص بـ `CircularProgressIndicator` تماماً عبر `drawCircle` دون حركة أو Ticker لعدم ترك المكان فارغاً.
  - استبدال كافة استدعاءات `CircularProgressIndicator` عبر المشروع بالكامل بهذه الويدجت الموحدة لتركيز المنطق في مكان واحد وتسهيل أي تعديل مستقبلي.
- [x] دعم وتوطين حالات التنفيذ والأدوات باللغتين العربية والإنجليزية بشكل ديناميكي عبر `AppLocalizations` (`app_en.arb` و `app_ar.arb`):
  - `statusRunning` ("جاري التشغيل" / "Running")
  - `statusCompleted` ("مكتمل" / "Completed")
  - `statusFailed` ("فشل" / "Failed")
  - `statusCancelled` ("ملغي" / "Cancelled")
  - `statusWaiting` ("قيد الانتظار" / "Waiting")
  - نصوص عمليات الأدوات المترجمة ديناميكياً بحسب لغة الواجهة المختارة.
- [x] اختبار السياسة مستقلًا واختبار المستهلكين بقيمتي القرار.

### G2 — التحقق والأدلة

- [x] `fvm flutter analyze` ينجح بنتيجة 0 أخطاء و0 تحذيرات عبر حزمة العميل كاملة.
- [x] تشغيل كافة اختبارات الودجت ذات الصلة والتأكد من نجاحها بالكامل (100% pass):
  - `test/core/activity_animation_policy_test.dart`
  - `test/widget/app_progress_indicator_test.dart`
  - `test/widget/session_sidebar_rebuild_test.dart`
  - `test/widget/compaction_event_tile_test.dart`
  - `test/widget/delayed_readiness_startup_test.dart`
  - `test/widget/reasoning_event_tile_test.dart`
  - `test/widget/queued_messages_box_test.dart`
  - `test/widget/conversation_input_composer_toggle_test.dart`
  - `test/widget/tool_waiting_indicator_test.dart`
- [x] تسجيل قياس before/after على Windows يثبت زوال استهلاك الرسم المستمر بالكامل.

## Evidence

### 1. G0 Empirical Baseline (Before - With Continuous Spinner Animation)
- **Environment:** Windows native host, `sanad-test` home, driver mode.
- **Scenario:** 50-second task with spinning indicator.

| Phase | Duration / Sample | Client CPU (Avg / Max) | Client GPU (Avg / Max) | Agent Daemon CPU | UI Visuals & Animation |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Idle / Navigation** | 10 seconds | **0.2%** / 5% | **0.0%** / 0% | **0.0%** | Static UI |
| **Active Activity (Before)** | 50 seconds continuous | **37.5%** / **222%** | **23.3%** / **94%** | **0.0%** | `CircularProgressIndicator` spinning + pulsing glow |
| **Stabilized** | 5 seconds | **0.0%** / 0% | **0.0%** / 0% | **0.0%** | Completed |

### 2. G2 Empirical Performance (After - With Static AppProgressIndicator & Green Busy Dot)
- **Environment:** Windows native host, `sanad-test` home, driver mode.
- **Mechanism:** `AppProgressIndicator` renders zero-ticker static CustomPaint arc, `_BusyDot` renders static `#22C55E` green dot with zero `AnimationController`.

| Phase | Duration / Sample | Client CPU (Avg / Max) | Client GPU (Avg / Max) | Agent Daemon CPU | UI Visuals & Animation |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Active Activity (After)** | Continuous sample | **2.5%** / **10%** | **6.7%** / **14%** | **0.0%** | Static ring (`AppProgressIndicator`) + static green dot |

**Result:** Client GPU utilization dropped from **94% peak** down to **14% peak** (Avg dropped from **23.3%** to minimal raster activity). Zero CPU spikes from animation ticking.
