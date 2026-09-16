---
title: "Task 77g1: Local Attachment Integration QA"
status: "complete"
priority: "high"
depends_on: "77f2"
current_gate: "complete"
remaining_estimate: "0%"
tracked_file_budget: "unrestricted_by_user"
evidence_id: "77e"
evidence_fingerprint: "sha256:1f92463d390f35c6731087bc335672a612766e50a396b08131ba380c2557750a"
---

# Task 77g1: إثبات المرفقات المحلية End-to-End

## Goal

إثبات رحلة paste/picker/drop إلى agent staging ثم model path/tool choice ثم user bubble وView Image وEdit عبر Local Gateway حقيقي ومعزول.

## Locked scope

- E2E daemon يستخدم SANAD_STATE_HOME مؤقتًا وprovider fixture حتميًا.
- لا يستخدم provider المستخدم أو database/runtime الحية.
- fixture يثبت أن bytes لا تصل للنموذج قبل tool call، ثم يختار `view_image` ويجيب من pixels.
- يغطي 5 MiB boundaries والحدود الإجمالية، restart، edit، cleanup، وmedia expiry.
- الاختبار الذي يربط ports يعمل `--concurrency=1` فقط.

## Gates

### R0 — Scenario and fixture
- [x] حل packet `77e` وتسجيل fingerprint.
- [x] بناء fixtures صغيرة لا تكشف بيانات حقيقية.

### G1 — Happy paths
- [x] إثبات paste image وFile Picker وdrag/drop file.
- [x] إثبات user bubble وView Image thumbnail/Lightbox.
- [x] إثبات model path projection ثم tool choice.

### G2 — Failure/recovery
- [x] boundary tests لـ5 MiB و4/20 MiB.
- [x] interrupted admission يبقي draft وينظف partial.
- [x] restart/history/edit existing attachment دون re-upload.
- [x] session deletion وexpiry/unavailable behavior.

### G3 — Closure
- [x] تشغيل analyzer/focused suites/E2E bounded output.
- [x] تحديث QA وسجل الخطة ونسبة المتبقي.

## Acceptance criteria

- [x] لا توجد provider bytes قبل `view_image` call.
- [x] الرسالة لا تظهر sent قبل attachment ACK.
- [x] live/history/edit تعرض metadata والصورة نفسها دون private path.
- [x] كل failure يترك state قابلًا للفهم ولا يترك partial file.

## Definition of Done

- [x] Agent/Client analyzers ناجحان.
- [x] focused suites ناجحة.
- [x] daemon-backed E2E المتسلسل ناجح.
- [x] تحقق Flutter مرئي ظاهر موثق.
- [x] `graphify update .` ناجح.
- [x] تحديث gate ونسبة المتبقي.

## Progress log

### 2026-09-16 — R0 complete

- Status transition: `pending/R0` → `in_progress/G1`.
- Revalidated packet `77e` at `sha256:1f92463d390f35c6731087bc335672a612766e50a396b08131ba380c2557750a` and the pinned OpenCode/OpenClaw revisions.
- Locked an isolated real-daemon scenario using the existing deterministic provider and authenticated Local Gateway helper. No live provider, primary Sanad Home, user database, or real user file is permitted.
- Fixtures are generated at runtime: an opaque-name 2×2 magenta PNG, a tiny UTF-8 file, deterministic boundary streams, and an interrupted upload. Large binaries are not committed.
- The provider must first prove that it sees only text plus the bounded Agent-owned path projection, then choose `view_image` and derive `PIXELS_MAGENTA` from decoded pixels. Public captures must remain free of bytes/base64/private paths.
- Evidence run: `refrence_projects/.sanad-evidence/runs/77g1-reference-grounding-2026-09-16.md`.
- Remaining estimate: `75%` for 77g1 and approximately `6%` for Plan 77.
- Next gate: `G1 — Happy paths`.
- Triage found that composer drafts were UI-only and never crossed `sendMessage`; the user approved expanding this task from the default 10-file ceiling to `18` tracked files so the missing admission path is completed before claiming E2E QA.

### 2026-09-16 — G1 and G2 complete

- Status transition: `in_progress/G1` → `in_progress/G3`; remaining estimate `15%` for closure checks and visible Flutter evidence.
- Paste, picker, and drop now share one Client admission-before-send path. `attachment.admit` is private/authenticated, receiver-authoritative, and returns opaque ids before `think`; failure retains the draft and emits no turn.
- The daemon claims the same request atomically into durable history and makes staged exact-file grants available while building that initial turn's tool catalog. The deterministic provider sees text plus the Agent-owned projection, chooses `view_image`, and answers `PIXELS_MAGENTA` from pixels; public frames contain neither base64 nor private/source paths.
- Daemon-backed E2E passed `6/6` sequentially, including partial/hash/count/size rejection cleanup. Policy/store suites passed `20/20`, covering 5 MiB and 4/20 MiB boundaries, restart cleanup, unavailable ownership, and session deletion. Client admission tests passed `34/34`; existing conversation media/replay suites own bubble, Lightbox, history, and Edit without re-upload.
- Runtime triage required two additional lifecycle owners plus mandatory contract/QA documentation. The user removed the tracked-file ceiling rather than dropping safety coverage.
- Next gate: `G3 — Closure`.

### 2026-09-16 — 77g1 complete

- Status transition: `in_progress/G3` → `complete`; remaining estimate `0%`.
- Verification: full Agent/Client analyzers clean; daemon E2E `6/6`; Agent policy/store/replay `38/38`; Local Gateway transport `23/23` and security `16/16`; Client focused admission/data/cache/widgets `116/116`; `git diff --check` clean.
- Visible isolated macOS build produced a foreground `1400×900` window and `/tmp/77g1-visible-flutter.png`; the Client was stopped. Graphify completed at `24,182 / 33,342 / 874`.
- Contracts, QA runbook, plan, task, and evidence were updated. Open findings: none blocking.
- Next plan gate: private hosted attachment relay `G0`, before `77g2`.
