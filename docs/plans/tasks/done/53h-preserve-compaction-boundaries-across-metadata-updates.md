---
title: "Task 53h: Preserve Compaction Boundaries Across Metadata Updates"
description: "منع تحديث metadata غير الدلالية من تغيير هويات رسائل المحادثة وإبطال حدود الضغط النشطة."
status: "complete"
current_gate: "complete"
priority: "critical"
depends_on: "Task 53g"
---

# Task 53h: ثبات حدود الضغط عند تحديث metadata

## Goal

منع auto-compaction المتكرر في المحادثات الطويلة عندما تتغير metadata لرسالة محفوظة بينما يبقى محتواها الدلالي كما هو.

## Locked decisions and scope

- `messages.id` يبقى ثابتًا عندما يكون الاختلاف الوحيد في top-level `metadata`، بما يطابق بصمة `CompactionMessageAnchor` الحالية.
- أي تغيير في الدور أو المحتوى أو tool calls/results أو reasoning أو provider state يظل تغييرًا دلاليًا ويعيد كتابة اللاحقة كما كان.
- لا تُعدّل بيانات محادثات المستخدم أو صفوف compaction التاريخية كجزء من الإصلاح.
- الإصلاح يخص ملكية التخزين والـmodel projection؛ لا يغير threshold أو target ratio أو نافذة النموذج.

## Gates

### H0 — Evidence and reproduction

- [x] إثبات أن المحادثة المتأثرة أعادت الضغط عند تقدير 1.09–1.15M token بعد نتائج مؤكدة 35–38K.
- [x] إثبات أن retained-tail anchors القديمة ما زالت موجودة دلاليًا تحت row ids جديدة.
- [x] ربط invalidation بمسار `SessionDB.replaceMessages` الذي يعيد كتابة اللاحقة عند تغير metadata.

### H1 — Persistence repair

- [x] تحديث metadata-only داخل الصف نفسه مع الحفاظ على `messages.id`.
- [x] إبقاء semantic suffix rewrite دون تغيير.
- [x] إضافة regression coverage لثبات أحدث compaction boundary ولإبطالها عند تغيير دلالي حقيقي.

### H2 — Verification and delivery

- [x] تشغيل formatter وanalyzer والاختبارات المركزة.
- [x] تحديث تصميم compaction ومصفوفة QA وعقد قاعدة البيانات.
- [x] تحديث Graphify ومراجعة diff.
- [x] تطبيق الإصلاح على runtime الحالي عبر restart آمن والتحقق من status والسجلات.

## Acceptance Criteria

- [x] Given an active completed boundary, when only message metadata changes, then the same row ids and active boundary remain in use.
- [x] Given an active completed boundary, when summarized message semantics change, then the old boundary is not reused.
- [x] A compacted request below threshold does not fall back to the full canonical transcript because of metadata persistence.

## Definition of Done

- [x] `fvm dart analyze` passes.
- [x] Focused persistence/projection and preflight compaction tests pass.
- [x] Relevant design and QA documentation is current.
- [x] `graphify update .` completes.
- [x] The managed main runtime restarts safely and remains healthy.
