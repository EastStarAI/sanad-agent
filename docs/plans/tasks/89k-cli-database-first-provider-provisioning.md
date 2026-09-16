---
title: "Task 89k: Database-First Provider Provisioning for CLI Automation"
description: "إضافة إعداد مزود غير تفاعلي وآمن للأتمتة يحفظ تعريف المزود في قاعدة الحالة واعتماداته في SecretStore دون إحياء مسار الاعتماد الضمني على مفاتيح بيئة التشغيل."
status: "planned"
current_gate: "G0 — Contract and reference alignment"
remaining_estimate: "100%"
priority: "high"
depends_on: "Task 89j; provider instance and SecretStore contracts"
reference_grounding: "required"
evidence_id: "89"
---

# Task 89k: إعداد مزود Database-First لأتمتة CLI

## الهدف

تمكين المطور من تثبيت Sanad Agent في جهاز نظيف أو GitHub Actions، ثم إعداد مزود بصورة غير تفاعلية وتشغيل `sanad run --standalone` باستخدام ملاك المزود الحاليين، دون Flutter Client ودون الرجوع إلى اختيار المزود أو اعتماداته ضمنيًا من متغيرات بيئة عملية التشغيل.

## القرارات المثبتة والنطاق

- يبقى `ProviderInstanceRepository` وقاعدة `state.db` مصدر الحقيقة لتعريف المزود، البروتوكول، Base URL، النموذج الافتراضي، والحالة والاختيار الافتراضي.
- تبقى الأسرار خارج SQLite وفق عقد الأمان الحالي، وتحفظ عبر `ProviderCredentialService` و`SecretStore`. عبارة Database-first تعني أن تعريف المزود واختياره دائمان في قاعدة البيانات، لا أن قيمة السر توضع فيها.
- يضاف أمر إعداد غير تفاعلي يعيد استخدام `ProviderInstanceService` و`ProviderCredentialService`؛ لا يكتب `.env` القديم ولا ينشئ مسار إعداد مكررًا.
- لا تقبل قيمة السر في argv. يقبل الأمر السر من stdin أو قناة إدخال آمنة مكافئة، ولا يطبعه أو يسجله أو يعيده في JSON.
- في GitHub Actions يجوز ربط GitHub Secret بمتغير مؤقت في **خطوة الإعداد فقط** ثم تمريره عبر stdin. خطوة `sanad run` التالية لا ترث مفتاح المزود ولا تستخدمه للاكتشاف؛ تقرأ المزود من `state.db` والسر من `SecretStore`.
- يتطلب الإعداد غير التفاعلي template/protocol والنموذج صراحة، مع Base URL صريح للمزود المخصص، لمنع التخمين الصامت.
- OAuth التفاعلي خارج مسار API-key غير التفاعلي الأول، ما لم يوجد عقد token/import رسمي وآمن يمكن إعادة استخدامه دون نسخ منطق المصادقة.
- لا تضيف المهمة JSONL streaming أو Remote device routing أو تغيّر قفل ملكية runtime في 89j.

## بوابات التنفيذ

### G0 — العقد والتأصيل المرجعي

- [ ] تدقيق أوامر الإعداد الحالية وخدمات Provider Instance وCredential وSecretStore وتحديد API واحد لإعادة الاستخدام.
- [ ] مقارنة نمط الإعداد غير التفاعلي والـconfig pinning في حزمة الأدلة 89 دون استيراد fallback يعتمد ضمنيًا على env وقت التشغيل.
- [ ] تثبيت شكل الأمر، تحقق المدخلات، أكواد الخروج، وخطة rollback عند فشل حفظ metadata أو السر.

### G1 — الإعداد غير التفاعلي Database-First

- [ ] إضافة subcommand غير تفاعلي تحت `sanad setup` لإنشاء أو تحديث Provider Instance وتحديد النموذج والافتراضي.
- [ ] قراءة API key من stdin/قناة آمنة فقط وحفظه عبر `ProviderCredentialService` و`SecretStore`.
- [ ] جعل العملية idempotent بمعرّف/اسم واضح، ومنع duplicate instances أو التحديث الجزئي غير القابل للاستعادة.
- [ ] ضمان عدم كتابة السر إلى argv أو stdout/stderr أو logs أو `state.db` أو `.env`.
- [ ] إعادة envelope/exit codes قابلة للأتمتة دون كشف بيانات حساسة.

### G2 — تشغيل CI من الحالة المحفوظة

- [ ] إثبات أن `sanad run --standalone` على Home جديد يختار Provider Instance المحفوظ ويقرأ سره من SecretStore دون مفاتيح مزود في بيئة عملية التشغيل.
- [ ] إثبات أن غياب metadata أو السر يفشل برسالة قابلة للإجراء ولا يعود إلى legacy env discovery.
- [ ] ضمان أن الأدوات والعمليات الأبناء لا تستقبل أسرار المزود.
- [ ] الحفاظ على قفل runtime وstdout JSON والمهلة والإلغاء من 89j دون تغيير.

### G3 — وثائق واختبارات المطور الخارجي

- [ ] إضافة مثال GitHub Actions يعمل داخل أي مستودع باستخدام installer العام و`--no-login` وHome/State مؤقتين.
- [ ] جعل خطوة provisioning منفصلة عن خطوة التشغيل، وحصر GitHub Secret في خطوة provisioning.
- [ ] إضافة Process/E2E test على Home مؤقت يثبت provision ثم run من الملف التنفيذي الفعلي دون env credential في خطوة run.
- [ ] تغطية إعادة التشغيل، idempotency، الإدخال الناقص، فشل SecretStore، ومنع تسرب السر.
- [ ] تحديث README ودليل المستخدم والعقد التقني و`docs/llms.txt` عند الحاجة.

## معايير القبول

- [ ] على runner نظيف، يثبت المطور Sanad بالأداة العامة، يجهز مزودًا دون prompt، ثم ينفذ One-shot ناجحًا من الحالة المحفوظة.
- [ ] يحتوي `state.db` تعريف المزود واختياره ولا يحتوي قيمة الاعتماد السرية.
- [ ] يحتوي SecretStore الاعتماد وفق عقده الحالي، ولا تعتمد خطوة التشغيل على `OPENAI_API_KEY` أو `LLM_API_KEY` أو نظائرهما.
- [ ] لا يظهر السر في process arguments أو stdout/stderr أو logs أو JSON أو بيئة الأدوات.
- [ ] تكرار provisioning بنفس الهوية يحدث السجل المقصود دون إنشاء duplicates أو ترك حالة جزئية.
- [ ] مثال GitHub Actions قابل للنسخ إلى مستودع خارجي ولا يعتمد على `.github/actions/setup-fvm` أو checkout لمصدر Sanad.

## Definition of Done

- [ ] `fvm dart analyze` والاختبارات المركزة وحزمة CLI ذات الصلة تنجح بمخرجات bounded.
- [ ] Process/AOT smoke يثبتان provisioning ثم التشغيل من Home مؤقت ومعزول.
- [ ] التوثيق يشرح بوضوح فصل metadata في SQLite عن الأسرار في SecretStore.
- [ ] `git diff --check` و`graphify update .` ينجحان.
- [ ] لا Commit أو Push أو إغلاق للمهمة دون أدلة القبول وموافقة المستخدم المناسبة.
