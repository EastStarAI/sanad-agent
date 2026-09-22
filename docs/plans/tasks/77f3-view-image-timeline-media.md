---
title: "Task 77f3: View Image Timeline Media"
status: "pending"
priority: "high"
depends_on: "77d3, 77e3"
current_gate: "R0"
remaining_estimate: "100%"
evidence_id: "77e"
---

# Task 77f3: وسائط حدث View Image في Timeline

## Goal

إضافة projection آمنة لنتيجة `view_image` وعرض حدث بعنوان `View Image` وأسفله thumbnail قابلة للضغط محليًا وعن بُعد دون bytes أو paths في event/history payload.

## Locked scope

- event يحمل `media_id` opaque وsafe name وMIME والأبعاد والحالة فقط.
- title المرئي هو `View Image`؛ thumbnail أسفله وتفتح Lightbox.
- hydration كسولة قرب viewport، مع cancellation عند disposal/session switch.
- local fetch عبر Local Gateway المصادق؛ remote fetch عبر capability العامة المتوافقة.
- media identity مقيدة بالuser/device/session/purpose ولا تتحول إلى public URL.
- expiry/pruning يعرض `Image no longer available` ويحافظ على بقية tool row.

## Gates

### R0 — Media contract
- [ ] حل packet `77e` وتسجيل fingerprint.
- [ ] تثبيت binary-free event/history schema وcapability behavior.

### G1 — Agent projection and retrieval
- [ ] إنتاج media identity من canonical tool result دون نسخ غير محدودة.
- [ ] إضافة authenticated local retrieval مع range/size/content headers الآمنة.
- [ ] منع cross-session/device access وتسجيل bytes.

### G2 — Client rendering
- [ ] إضافة View Image event renderer والthumbnail/unavailable states.
- [ ] إضافة viewport hydration/cache bounds وLightbox accessibility.
- [ ] توحيد live/history/reconnect projection.

### G3 — Tests
- [ ] agent interface tests للمصادقة والعزل والexpiry.
- [ ] Flutter widget/cache tests للتحميل والضغط والإلغاء والتاريخ.

## Acceptance criteria

- [ ] الحدث يعرض `View Image` ثم الصورة، والضغط يفتحها كاملة.
- [ ] event/history JSON لا يحتوي base64 أو absolute path أو reusable URL.
- [ ] client غير مخول أو session خاطئة لا تستقبل byte واحدة.
- [ ] pruning/expiry يحول الصورة إلى unavailable state دون كسر timeline.

## Definition of Done

- [ ] analyzer للـAgent والـClient ناجح.
- [ ] focused interface/widget tests ناجحة.
- [ ] تحقق مرئي ظاهر محليًا وعن بُعد عند توفر fixture.
- [ ] communication/design/QA docs محدثة.
- [ ] `graphify update .` ناجح.
- [ ] تحديث gate ونسبة المتبقي.
