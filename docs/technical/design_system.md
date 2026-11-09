---
title: "مواصفات نظام التصميم والمكونات المرئية للمشاريع"
description: "توثيق شامل للألوان، الخطوط، الهيكل البنائي والواجهات التفاعلية المشتركة لمشاريع Sanad (التطبيق الرئيسي، صفحة الهبوط، ولوحة التحكم)."
---

# مواصفات نظام التصميم والمكونات المرئية (Design System & UI Spec)

<div dir="rtl" style="text-align: right; direction: rtl;">

تحدد هذه الوثيقة معايير **نظام التصميم الموحد (Design System)** المعتمد في مشاريع منظومة Sanad (تطبيق الواجهة الرئيسي Client، صفحة الهبوط Landing Page، ولوحة التحكم Admin Panel). تهدف هذه الوثيقة لتوحيد الهوية البصرية وتسهيل مشاركة المكونات وعناصر التصميم عبر المشاريع المختلفة.

---

## 1. الثوابت البصرية الأساسية (Global Design Tokens)

### أ. نظام الألوان (Color Schemes)
تتشارك جميع المشاريع نفس لوحة الألوان الأساسية لتقديم تجربة بصرية موحدة واحترافية:

* **اللون الرئيسي (Primary):** `0xFF60A5FA` (أزرق Sanad المعتمد) للمؤشرات النشطة، الأزرار التفاعلية، وروابط التنقل الأساسية، مع `0xFF0A0A0A` للمحتوى فوق اللون الرئيسي عند الحاجة إلى التباين. يجب أن تستهلك الواجهات هذه القيم عبر tokens الثيم، لا عبر قيم محلية مكررة.
* **اللون الثانوي (Secondary):** `0xFF03DAC6` (كحلي/تركواز مائل للخضرة) للشارات والوسوم الجانبية (مثل شارة الاتصال المحلي).
* **الخلفيات والأسطح (Surfaces):**
  * **الوضع الداكن (Dark Mode):**
    * خلفية التطبيق والمواقع العامة: `0xFF1E1E1E` (رمادي داكن مطفأ).
    * أسطح النوافذ والقائمة الجانبية والكروت: `0xFF171717` (رمادي فحمي عميق).
    * العناصر النشطة أو التي يُمرر الماوس فوقها: `0xFF252525`.
  * **الوضع الفاتح (Light Mode):**
    * خلفية التطبيق العامة وأسطح النوافذ: `Colors.white`.
    * أسطح الحاويات الجانبية والخلفيات البديلة: `0xFFF5F5F5`.
* **الحدود والفواصل (Outline):** `0xFF2D2D2D` للوضع الداكن، و `0xFFE0E0E0` للوضع الفاتح لإنشاء حدود رفيعة ومحددة.
* **ألوان الأكواد والتمييز (Accent colors):** لون كهرماني دافئ دلالي مخصص لعرض الكود البرمجي وسياقات التمييز الفني (`0xFFE5C07B` للداكن / `0xFFB58900` للفاتح).
* **خلفيات بوابة Sanad:** تستخدم الأسطح الداكنة المعتمدة مع توهج أزرق
  منخفض الشدة مشتق من Primary. الألوان الدلالية، مثل أخضر النجاح، تبقى داخل
  عناصر الحالة ولا تستخدم كتدرج لخلفية الصفحة.

### ب. الخطوط (Typography)
* The Client interface uses the font the user selects in Settings, and Cairo is the default for a profile with no saved choice. Widget code never names a font family: the selected family is resolved once from the theme, or through `AppTypography` in `client/lib/core/theme/app_typography.dart` for styles built by hand.
* Code, diffs, terminals, paths, commands, and raw JSON stay monospace through the single `AppTypography.mono` constant; machine-readable text never follows the user's app font.
* No Apple-provided font may be bundled in the Client — interface text and icons use Flutter-authored font assets only (iOS-style glyphs come from `CupertinoIcons`), because an embedded system typeface fails App Store validation as `ITMS-91182` (enforced from 2027-10-01), and `client/test/guards/no_apple_font_bundle_guard_test.dart` fails on any dependency, lock entry, asset name, or build manifest that carries one.
* Headline, body, and small control text keep their Material sizes and weights (11 to 13 px with `w500` or `w600` for list and button text); only the family follows the selection.
* The former Georgia serif accent on New Task headlines is retired: those headlines are interface text and follow the selected font.

### ج. الاستجابة ونقاط التحول (Responsive Breakpoints)
* **نقاط التحول للأجهزة الذكية:**
  * **شاشات الهواتف:** أقل من `600` بكسل (تتحول القوائم الجانبية إلى Drawers، ويتم تنسيق عناصر صفحة الهبوط عموديًا).
  * **شاشات الأجهزة اللوحية:** بين `600` و `900` بكسل.
  * **شاشات أجهزة المكتب:** `900` بكسل فما فوق (واجهات متعددة اللوحات، قوائم جانبية ثابتة).
* **عرض المحتوى الأقصى (Max Content Width):** يقتصر عرض أعمدة المحتوى الطويل (مثل الشات والمقالات التوثيقية) على `760` إلى `780` بكسل لراحة العين أثناء القراءة الطويلة.

---

## 2. المكونات الهيكلية للواجهات (Layout Components)

### أ. التخطيط ثلاثي اللوحات (Three-Panel Layout)
يعتمد هيكل التطبيقات التفاعلية داخل المنظومة على التوزيع التالي:
1. **اللوحة اليسرى (Sidebar):** للتنقل بين مساحات العمل والجلسات (تتحول إلى Drawer على الهواتف).
2. **اللوحة الوسطى (Main View / Chat Area):** لعرض صلب المحتوى التفاعلي أو محتوى صفحة الهبوط.
3. **اللوحة اليمنى (Inspector / Context Panel):** اختيارية لعرض تفاصيل إضافية أو أدوات مساعدة دون تشتيت المستخدم.

### ب. شريط الحالة والبيانات السفلي (StatusBar)
شريط سفلي بارتفاع `24` بكسل مستوحى من بيئات المطورين:
* يعرض حالة الاتصال ببوابات الخدمة (المحلية والسحابية).
* يوفر تنبيهات ديناميكية بالألوان تعكس سلامة النظام والعمليات النشطة.

---

## 3. العناصر البصرية المشتركة (Shared Visual Widgets)

### أ. تأثيرات الزجاج شبه الشفاف (Glassmorphism)
تستخدم الواجهات التفاعلية وصفحات الهبوط لمسات بصرية زجاجية راقية:
* **المظهر:** خلفيات شبه شفافة وضبابية باستخدام فلاتر التمويه (`BackdropFilter` بقيمة تمويه تبدأ من `10.0`) مع حدود ناعمة ودائرية، وظلال خفيفة لإبراز العناصر العائمة فوق الخلفية الأساسية.

### ب. الشارات التوضيحية (Badges & Indicators)
* شارات دائرية ناعمة وخفيفة الزوايا لتوضيح الحالات البرمجية والبيئات (مثل شارة فرع العمل النشط، أو شارة الحالة المتصلة `online` الخضراء).

---

## 4. تطبيق وتوسيع نظام التصميم عبر المشاريع

| المشروع | كيفية تطبيق نظام التصميم فيه |
| :--- | :--- |
| **تطبيق الواجهة (Client)** | استخدام كامل عناصر التصميم الهيكلية (StatusBar, WorkspaceLayout, FloatingGlass) مع ربطها بالـ BLoC لإدارة الحالة. |
| **صفحة الهبوط (Landing Page)** | استخدام نفس خطوط النصوص (Georgia للعناوين و Sans-serif للمحتوى) ونفس لوحة الألوان والأزرار الزجاجية لخلق انطباع متطابق مع التطبيق. |
| **لوحة التحكم (Admin Panel)** | تطبيق نفس الهيكل ثلاثي اللوحات لجدولة المهام وإدارة الأجهزة مع استخدام الفواصل والمؤشرات البصرية المشتركة. |

</div>
