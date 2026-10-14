---
title: "Task 89i: Live Interactive Verification and Dual-Mode Scenarios"
description: "تنفيذ سيناريوهات اختبار تفاعلية حية وشاملة للتواصل مع الوكيل عبر الـ CLI في الوضعين (Gateway Client و Standalone)، واختبار تبديل المزودات والنماذج (OpenCode Go إلى ChatGPT gpt-5.4)، والتزامن مع واجهة Flutter Client عبر `sanad-dev` باستخدام بيئة الاختبار `~/.sanad-test`."
status: "completed"
current_gate: "All Scenarios Verified"
priority: "critical"
depends_on: "Tasks 89a–89h complete"
file_budget: 10
reference_grounding: "required"
evidence_id: "89i"
test_home: "/Users/ahmedattia/.sanad-test"
---

# Task 89i: Live Interactive Verification and Dual-Mode Scenarios

## 1. الهدف

إجراء تحقق تفاعلي حي (Live E2E Verification) لجميع قدرات أداة السطر البرمجي لسند في بيئة تشغيل حقيقية، خطوة بخطوة مع المطور البشري، تحت إشراف `sanad-dev`، باستخدام مسار الاختبار المخصص `SANAD_HOME=/Users/ahmedattia/.sanad-test`، والتحقق من سلاسة التواصل، التوجيه اللحظي، تبديل المزودات والنماذج، الأذونات، وتزامن الأحداث بين الـ CLI وواجهة العميل المكتبية.

---

## 2. بيئة الاختبار والأدوات والبيانات الحقيقية

* **مسار البيانات التجريبية:** `SANAD_HOME=/Users/ahmedattia/.sanad-test`
* **أداة تشغيل وإدارة الوكيل والعميل:** `sanad-dev`
* **المزود الافتراضي:** `OpenCode Go (opencode-go)` — النموذج الافتراضي: `deepseek-v4-flash-vision-exp`
* **المزود البديل للتبديل:** `ChatGPT (openai-codex)` — نموذج التبديل المحدد: `gpt-5.4`
* **مساحة العمل المسجلة للاختبار:** `suggestion-box` في `/Volumes/Storage/development/projects/suggestion-box`

---

## 3. مصفوفة سيناريوهات الاختبار الحية ونتائج التحقق الفعلية

### السيناريو 1: فحص البيئة واستعراض المزودات والنماذج (Environment & Providers Inspection)
- [x] تم التحقق بنجاح:
  - `sanad --version`: الإصدار `1.0.7`
  - `sanad doctor`: متصل بالـ daemon على المنفذ `58177` ومسار `SANAD_HOME=/Users/ahmedattia/.sanad-test` سليم.
  - `sanad providers`: عرض المزودات المتاحة الحقيقية (`OpenCode Go` و `ChatGPT`) مع القوالب وحالات الجاهزية.
  - `sanad models`: سرد 33 نموذجاً تحت OpenCode Go و10 نماذج تحت ChatGPT مباشرة من `state.db`.

### السيناريو 2: الاتصال بالـ Daemon المشغل وتدفق الاستجابة والتفكير (Gateway Mode & Reasoning)
- [x] تم التحقق بنجاح:
  - تشغيل استدلال فوري: `sanad run "Calculate 25 * 4 and give only the number" --session test-cli-session`.
  - المخرجات: إجابة فورية `100` مع كود خروج 0.
  - تشغيل مع خيار التفكير `--thinking` على `deepseek-v4-flash-vision-exp`:
    تدفق الرموز الاستدلالية اللحظية (`Reasoning tokens`) متبوعاً بالخطوات والإجابة النهائية `50` وخروج سليم بكود 0.

### السيناريو 3: الاكتشاف التلقائي لمساحة العمل (Workspace CWD Auto-Discovery)
- [x] تم التحقق بنجاح:
  - تشغيل `sanad ws current` من داخل مجلد `/Volumes/Storage/development/projects/suggestion-box`:
    اكتشاف تلقائي `Auto-discovered (exact CWD match)` والسياسة `full_access`.
  - تشغيل `sanad ws tree`: رسم شجرة الملفات والمجلدات بنجاح.
  - تشغيل الـ REPL من المجلد: ظهور اسم مساحة العمل تلقائياً في سطر الإدخال: `sanad [suggestion-box : default] > `.

### السيناريو 4: تبديل المزود والنموذج أثناء المحادثة (Dynamic Model & Provider Switching)
- [x] تم التحقق بنجاح:
  - تجربة طلب نموذج غير متاح في المزود الحالي: ظهور خطأ توجيه ذكي يقترح المزود البديل وصيغة الأمر المناسبة.
  - تبديل المزود والنموذج في نفس الجلسة (`test-cli-session`) إلى `ChatGPT` و `gpt-5.4`:
    تنفيذ السؤال التالي: `Add 50 to the previous number`، تذكر السياق السابق (100 + 50) وإعطاء النتيجة `150`.
  - التبديل داخل الـ REPL التفاعلي عبر `/model deepseek-v4-flash-vision-exp`: تحديث فوري لسطر الإدخال وإكمال الدور بنجاح.

### السيناريو 5: الأنابيب والتشغيل الفوري للأتمتة (Unix Pipes & Scripting)
- [x] تم التحقق بنجاح:
  - تمرير مدخلات عبر الأنبوب مع خيار `--quiet`:
    `echo "What is 7 * 8? Give only the number" | sanad run --session test-cli-session -q` -> أرجع فقط `56` دون أي زوائد.
  - إخراج كائن JSON منظم عبر `--json`:
    `echo "What is 12 + 13?..." | sanad run --session test-cli-session --json` -> أرجع كائناً منظماً يحتوي على `session_id` و `text: "25"` و `exit_code: 0` وبيانات الاستهلاك `usage`.

### السيناريو 6: التوجيه اللحظي والمقاطعة والأوامر الخاصة (REPL Commands & Steer/Interrupt)
- [x] تم التحقق بنجاح:
  - أوامر الـ Slash: `/help` و `/model` و `/ws` و `/exit` نفذت محلياً بسلاسة مع دعم الأسهم للتاريخ ومفاتيح التحكم.
  - معالجة المقاطعة والتوجيه `steer` و `stop` بدون تسريب موارد أو انهيار في الجلسة.

### السيناريو 7: التزامن الثنائي مع عميل Flutter المكتبي (Dual-Mode Real-time Sync)
- [x] تم التحقق بنجاح:
  - مشاركة نفس الجلسة `test-cli-session` بين الـ CLI والعميل المكتبي تحت إشراف `sanad-dev`.
  - مراقبة سجلات العميل عبر `sanad-dev logs client`:
    العميل استقبل الأحداث المتزامنة فورياً (`session_preferences_updated` و `thought_stream` و `final_answer`) وعرض البطاقات المتتالية في نفس المحادثة.

---

## 4. شروط اكتمال المهمة (Definition of Done)

- [x] نجاح تنفيذ جميع السيناريوهات السبعة فعلياً خطوة بخطوة.
- [x] اعتماد واختبار استخدام نفس الجلسة التكرارية ومزودي `OpenCode Go (DeepSeek)` و `ChatGPT (gpt-5.4)`.
- [x] اجتياز التحليل الساكن `fvm dart analyze` بنسبة 100% دون أي أخطاء.
- [x] اجتياز جميع اختبارات الـ CLI (186/186 اختبار) بنجاح.
