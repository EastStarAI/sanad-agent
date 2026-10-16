---

title: "المرحلة الرابعة: إعداد الوكلاء المحليين وتحديث الواجهة"
description: "برمجة هيكل الوكلاء المخصصين الجدد (Logical Agents) داخل قاعدة البيانات المحلية للوكيل، وتعديل شريط التنقل الجانبي للواجهة لدعم الأجهزة المتعددة والربط الشجري للجلسات ومساحات العمل."
phase: 4
prd: "docs/product/prd_sanad_agent.md"
---
<div dir="rtl" style="direction: rtl; text-align: right;">

# المرحلة الرابعة: إعداد الوكلاء المحليين وتحديث الواجهة

> هذه المرحلة هي الخطوة الرابعة من التوجه الجديد للمشروع الموثق في **[وثيقة متطلبات المنتج (PRD)](../product/prd_sanad_agent.md)**. تهدف هذه المرحلة إلى بناء الكيان الأساسي للوكلاء المنطقيين المخصصين (Logical Agents) محلياً على أجهزة المستخدم، وتقديم واجهة الاستخدام النهائية التي تمكن المستخدم من إدارة أجهزته ووكلاءه محلياً وسحابياً.

---

## الهدف

برمجة وإعداد نظام الوكلاء المنطقيين المخصصين (Logical Agents) محلياً داخل قاعدة بيانات الوكيل (`sanad-agent`) وتحديث واجهة المستخدم (`sanad-client`) لدعم اختيار الأجهزة وعرض الهيكل الشجري للمساحات والجلسات.

---

## معايير القبول (Acceptance Criteria)

- [ ] تم إنشاء جدول الوكلاء المنطقيين بنجاح في قاعدة SQLite المحلية لـ `sanad-agent`.
- [ ] يمكن للمستخدم إنشاء وكيل مخصص محلياً وتخزينه بنجاح.
- [ ] واجهة المستخدم (`sanad-client`) تعرض الأجهزة المتاحة في درج جانبي (Devices Drawer) وتتيح للمستخدم التبديل بينها بشكل سلس.
- [ ] عند اختيار جهاز نشط، يتم تحديث شريط التنقل الجانبي ليظهر مساحات العمل والجلسات الخاصة بهذا الجهاز فقط.
- [ ] عند إنشاء جلسة محادثة جديدة، يتم ربطها بالوكيل المنطقي المختار وتخزين ذلك في قاعدة البيانات بنجاح.
- [ ] كود الواجهة وكود الوكيل ينجحان في البناء والتشغيل الكامل دون أي أخطاء.

---

## المكونات والتعديلات المقترحة

### ١. خادم الوكيل المحلي (`sanad-agent`)

#### [تعديل] [session_db.dart](../../../agent/lib/evolution/db/session_db.dart)

- **إنشاء جدول الوكلاء المنطقيين:**

  ```sql
  CREATE TABLE IF NOT EXISTS agents (
    agent_id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    system_prompt TEXT,
    model TEXT,
    tools TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
  );
  ```

- **إضافة حقل `agent_id` لجدول الجلسات:**
  - إضافة `ALTER TABLE sessions ADD COLUMN agent_id TEXT` كـ migration تلقائي في البداية لتحديث قواعد البيانات الحالية.
- **إضافة عمليات CRUD للوكلاء المنطقيين:**
  - `void saveAgent(AgentState agent)`
  - `AgentState? getAgent(String agentId)`
  - `List<AgentState> listAgents()`
  - `void deleteAgent(String agentId)`

#### [تعديل] [gateway_manager.dart](../../../agent/lib/interfaces/gateway_manager.dart)

- **معالجة الأحداث الجديدة للوكلاء المنطقيين:**
  - دعم استقبال أوامر: `get_agents`, `create_agent`, `update_agent`, `delete_agent` والرد بالبيانات المقابلة من `SessionDB`.
  - تحديث معالجة أمر `create_session` لحفظ حقل `agent_id` الممرر في الـ payload داخل قاعدة البيانات وربطه بالملف التعريفي للـ session.

#### [تعديل] [sanad_protocol_bridge.dart](../../../agent/lib/interfaces/platforms/sanad_gateway/sanad_protocol_bridge.dart)

- تحديث جسر التوجيه للتعرف على الأوامر الجديدة الخاصة بإدارة الوكلاء وتوزيعها بشكل مناسب.

---

### ٢. واجهة المستخدم الفلاتر (`sanad-client`)

#### [تعديل] [device_config.dart](../../../client/lib/features/agents/domain/models/device_config.dart)

- ربط معرّف المنصة الفعلي للـ Device بالـ SQLite لتخزين وتمرير `platform_type` بشكل صحيح.

#### [تعديل] [session.dart](../../../client/lib/features/conversations/domain/models/session.dart)

- إضافة حقل `agentId` للـ Session Model وتضمينه في دوال التحويل `fromJson` و `toJson`.

#### [تعديل] [session_sidebar.dart](../../../client/lib/features/conversations/presentation/widgets/session_sidebar.dart)

- **إنشاء درج الأجهزة الجانبي (Devices Drawer):**
  - بناء قائمة منبثقة أنيقة في الجزء العلوي للـ Sidebar تظهر الأجهزة المتاحة وحالات اتصالها.
  - المسار الحالي للاقتران: افتح Settings ثم زر `+` بجوار عنوان Devices في القائمة الجانبية للإعدادات لفتح إضافة جهاز.
- **شريط الوكلاء والجلسات الشجري:**
  - عرض قائمة بالوكلاء المحليين المتاحين على الجهاز لتحديد سياق المحادثات الحالي.
  - تعديل عرض شجرة المحادثات ليتم ترتيبها تتبعاً للوكيل المختار وتحت مساحات العمل النشطة للجهاز.

---

## خطة التحقق والتدقيق

### الاختبارات المؤتمتة

- كتابة اختبارات وحدة في `sanad-agent/test/` للتحقق من سلامة قراءة وكتابة وحذف الوكلاء المنطقيين في SQLite.
- تحديث اختبارات `sanad-client/test/` للتأكد من نجاح تصفية شجرة الجلسات عند تغيير الجهاز النشط.

</div>
